--- infra/openstep_plist.lua

--- ==============================================================================
--- MODULE: OpenStep Property List Reader
--- DESCRIPTION:
--- Decodes the old-style (OpenStep) property list text that `defaults read`
--- prints for one preference key: arrays in parentheses, dictionaries in
--- braces, and strings, quoted or bare. Every value is a Lua string or table.
---
--- FEATURES & RATIONALE:
--- 1. No interpreter: the enabled input sources were read by a python3 script
---    at every boot, and /usr/bin/python3 runs whatever python3 the active
---    developer folder holds, x86_64 only on a Mac migrated from Intel, where
---    macOS then announced an Intel app (hardening-h-no-rosetta). The system's
---    own `defaults` prints this text, which Lua reads directly.
--- 2. Exact or nothing: a malformed document returns nil and the position of
---    the first unexpected character, never a partial value; is_array() tells
---    an empty array from an empty dictionary.
--- 3. The escapes `defaults` emits: \Uxxxx code units (surrogate pairs joined),
---    the C escapes and octal bytes below 128; raw UTF-8 passes through.
--- ==============================================================================

local M = {}

-- Characters a bare (unquoted) string may hold, as CFOldStylePList accepts them.
local BARE_CHARACTER = "[%w_%$%+/:%.%-]"

-- Arrays this reader built: an empty array and an empty dictionary are both an
-- empty Lua table, and a caller expecting a list must tell them apart.
local _arrays = setmetatable({}, { __mode = "k" })

-- Single-character escapes of a quoted string.
local SIMPLE_ESCAPES = {
	a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
	['"'] = '"', ["\\"] = "\\", ["'"] = "'",
}





-- =====================================
-- =====================================
-- ======= 1/ Scalars ==================
-- =====================================
-- =====================================

--- Encodes one Unicode code point as UTF-8.
--- @param code integer Code point.
--- @return string|nil bytes, nil for a value outside Unicode.
local function utf8_bytes(code)
	if code < 0 or code > 0x10FFFF then return nil end
	if code < 0x80 then return string.char(code) end
	if code < 0x800 then
		return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
	end
	if code < 0x10000 then
		return string.char(0xE0 + math.floor(code / 0x1000),
			0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
	end
	return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
		0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

--- Reads a quoted string whose opening quote is at `pos`.
--- @param text string Document.
--- @param pos integer Index of the opening quote.
--- @return string|nil value
--- @return integer|string next_or_error Index after the closing quote, or the error.
local function read_quoted(text, pos)
	local parts = {}
	local index = pos + 1
	local pending_high = nil
	while true do
		local char = text:sub(index, index)
		if char == "" then return nil, "unterminated string at " .. pos end
		if char == '"' then
			if pending_high then return nil, "unpaired surrogate at " .. index end
			return table.concat(parts), index + 1
		end
		if char ~= "\\" then
			if pending_high then return nil, "unpaired surrogate at " .. index end
			parts[#parts + 1] = char
			index = index + 1
		else
			local escape = text:sub(index + 1, index + 1)
			if escape == "U" then
				local hex = text:match("^%x%x?%x?%x?", index + 2)
				if not hex then return nil, "invalid \\U escape at " .. index end
				local code = tonumber(hex, 16)
				index = index + 2 + #hex
				if code >= 0xD800 and code <= 0xDBFF then
					if pending_high then return nil, "unpaired surrogate at " .. index end
					pending_high = code
				else
					if code >= 0xDC00 and code <= 0xDFFF then
						if not pending_high then return nil, "unpaired surrogate at " .. index end
						code = 0x10000 + (pending_high - 0xD800) * 0x400 + (code - 0xDC00)
						pending_high = nil
					elseif pending_high then
						return nil, "unpaired surrogate at " .. index
					end
					parts[#parts + 1] = utf8_bytes(code)
				end
			elseif escape:match("^[0-7]$") then
				local octal = text:match("^[0-7][0-7]?[0-7]?", index + 1)
				local code = tonumber(octal, 8)
				-- Above 127 an octal escape is a NeXTSTEP-encoded byte, not Unicode.
				if code > 127 then return nil, "non-ASCII octal escape at " .. index end
				parts[#parts + 1] = string.char(code)
				index = index + 1 + #octal
			elseif SIMPLE_ESCAPES[escape] then
				if pending_high then return nil, "unpaired surrogate at " .. index end
				parts[#parts + 1] = SIMPLE_ESCAPES[escape]
				index = index + 2
			else
				return nil, "unknown escape at " .. index
			end
		end
	end
end





-- =====================================
-- =====================================
-- ======= 2/ Documents ================
-- =====================================
-- =====================================

--- Skips whitespace.
--- @param text string
--- @param pos integer
--- @return integer pos First non-space index.
local function skip_space(text, pos)
	return text:find("[^%s]", pos) or (#text + 1)
end

local read_value

--- Reads a dictionary whose opening brace is at `pos`.
--- @param text string
--- @param pos integer
--- @return table|nil value
--- @return integer|string next_or_error
local function read_dictionary(text, pos)
	local result = {}
	local index = skip_space(text, pos + 1)
	while text:sub(index, index) ~= "}" do
		local key, after_key = read_value(text, index)
		if type(key) ~= "string" then return nil, type(key) == "nil" and after_key or "non-string key at " .. index end
		index = skip_space(text, after_key)
		if text:sub(index, index) ~= "=" then return nil, "expected = at " .. index end
		local value, after_value = read_value(text, skip_space(text, index + 1))
		if value == nil then return nil, after_value end
		index = skip_space(text, after_value)
		if text:sub(index, index) ~= ";" then return nil, "expected ; at " .. index end
		result[key] = value
		index = skip_space(text, index + 1)
		if index > #text then return nil, "unterminated dictionary at " .. pos end
	end
	return result, index + 1
end

--- Reads an array whose opening parenthesis is at `pos`.
--- @param text string
--- @param pos integer
--- @return table|nil value
--- @return integer|string next_or_error
local function read_array(text, pos)
	local result = {}
	_arrays[result] = true
	local index = skip_space(text, pos + 1)
	while text:sub(index, index) ~= ")" do
		local value, after_value = read_value(text, index)
		if value == nil then return nil, after_value end
		result[#result + 1] = value
		index = skip_space(text, after_value)
		local separator = text:sub(index, index)
		if separator == "," then
			index = skip_space(text, index + 1)
		elseif separator ~= ")" then
			return nil, "expected , or ) at " .. index
		end
	end
	return result, index + 1
end

--- Reads one value starting at `pos` (no leading space).
--- @param text string
--- @param pos integer
--- @return any value
--- @return integer|string next_or_error
read_value = function(text, pos)
	local char = text:sub(pos, pos)
	if char == "{" then return read_dictionary(text, pos) end
	if char == "(" then return read_array(text, pos) end
	if char == '"' then return read_quoted(text, pos) end
	if char == "<" then
		local close = text:find(">", pos, true)
		if not close then return nil, "unterminated data at " .. pos end
		local hex = text:sub(pos + 1, close - 1):gsub("%s", "")
		if #hex % 2 ~= 0 or hex:find("%X") then return nil, "invalid data at " .. pos end
		return (hex:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end)), close + 1
	end
	local bare = text:match("^" .. BARE_CHARACTER .. "+", pos)
	if bare then return bare, pos + #bare end
	if char == "" then return nil, "unexpected end at " .. pos end
	return nil, "unexpected character at " .. pos
end

--- Reports whether a decoded table was an array (parentheses) in the document.
--- @param value any Value returned by decode().
--- @return boolean
function M.is_array(value)
	return type(value) == "table" and _arrays[value] == true
end

--- Decodes one old-style property list document.
--- @param text string Document, e.g. the output of `defaults read DOMAIN KEY`.
--- @return any value Table or string, nil when the document is malformed.
--- @return string|nil err Why it is malformed.
function M.decode(text)
	if type(text) ~= "string" then return nil, "document is not a string" end
	local start = skip_space(text, 1)
	if start > #text then return nil, "empty document" end
	local value, after = read_value(text, start)
	if value == nil then return nil, after end
	if skip_space(text, after) <= #text then return nil, "trailing content at " .. after end
	return value
end

return M
