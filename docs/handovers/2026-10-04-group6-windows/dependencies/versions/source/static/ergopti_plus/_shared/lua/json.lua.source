--- _shared/lua/json.lua
---
--- Minimal pure-Lua JSON encoder/decoder shared across all Lua drivers.
--- No external dependencies — runs on Lua 5.1+, LuaJIT 2.x, and Lua 5.4.
---
--- Used by: Linux E2E harness (corpus vectors), Linux locale module
--- (fallback decoder), macOS locale module (fallback decoder), and any
--- future driver that needs to read _shared JSON data without an OS JSON lib.

-- Resolved here rather than assumed to be a global. LuaJIT has no utf8 table, and
-- a shared module cannot depend on its caller having installed the compat shim —
-- it does not know its callers. The decoder used to guard with `utf8 and … or
-- string.char(code)`, which looks safe and is not: string.char refuses anything
-- above 255 and truncates 128-255 to one byte, so every \uXXXX escape outside
-- ASCII decoded to the wrong character on the one interpreter this driver runs.
local utf8_lib = (type(utf8) == "table" and utf8.char) and utf8 or require("compat.utf8")

local M = {}

-- Explicit lossless values stay distinguishable without changing legacy tables.
local ARRAY_VALUES = setmetatable({}, { __mode = "k" })
local LOSSLESS_NULL = setmetatable({}, {
	__newindex = function() error("JSON null is immutable", 2) end,
	__metatable = false,
})

local function array_length(value)
	if type(value) ~= "table" or value == LOSSLESS_NULL then return nil end
	local count = 0
	for index in pairs(value) do
		if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then return nil end
		count = count + 1
	end
	for index = 1, count do if rawget(value, index) == nil then return nil end end
	return count
end

--- Reports whether a value retains an explicit JSON array identity.
--- @param value any
--- @return boolean
function M.is_array(value) return type(value) == "table" and ARRAY_VALUES[value] == true end

--- Reports whether a value is the explicit lossless JSON null token.
--- @param value any
--- @return boolean
function M.is_null(value) return value == LOSSLESS_NULL end

--- Copies dense values into an explicit JSON array, including an empty array.
--- @param values table Dense values to copy.
--- @return table array Detached outer array; child values retain their identities.
function M.array(values)
	local count = assert(array_length(values), "JSON arrays require dense numeric values")
	local array = {}
	for index = 1, count do array[index] = values[index] end
	ARRAY_VALUES[array] = true
	return array
end

-- What a lone UTF-16 surrogate decodes to: it names no character, and emitting
-- it as-is would produce bytes no UTF-8 reader accepts.
local REPLACEMENT_CHARACTER = 0xFFFD

-- The short escapes JSON defines; every other control character is \u00XX.
local CONTROL_ESCAPES = { ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

--- Quotes a string as JSON, escaping every character JSON forbids raw.
--- @param value string
--- @return string
function M.quote(value)
	local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("[%z\1-\31\127]", function(ch)
		return CONTROL_ESCAPES[ch] or string.format("\\u%04x", ch:byte())
	end)
	return '"' .. escaped .. '"'
end

-- ============================================================================
-- 1. JSON decoder (recursive descent)
-- ============================================================================

--- Decodes a JSON string into a Lua value.
--- Handles objects, arrays, strings, numbers, booleans, and null.
--- @param raw string JSON string.
--- @return any|nil Decoded Lua value, or nil on parse failure.
local function decode(raw, lossless)
	if type(raw) ~= "string" or raw == "" then return nil end
	local pos = 1

	local function skip_ws()
		while pos <= #raw do
			local c = raw:sub(pos, pos)
			if c == " " or c == "\t" or c == "\r" or c == "\n" then
				pos = pos + 1
			else
				return c
			end
		end
		return nil
	end

	local NULL = lossless and LOSSLESS_NULL or {}

	local parse_value  -- forward decl

	local function parse_string()
		if raw:sub(pos, pos) ~= '"' then return nil end
		pos = pos + 1
		local res = {}
		while pos <= #raw do
			local ch = raw:sub(pos, pos)
			pos = pos + 1
			if ch == '"' then return table.concat(res) end
			if ch == "\\" then
				local esc = raw:sub(pos, pos)
				pos = pos + 1
				if     esc == '"'  then res[#res + 1] = '"'
				elseif esc == "\\" then res[#res + 1] = "\\"
				elseif esc == "/"  then res[#res + 1] = "/"
				elseif esc == "b"  then res[#res + 1] = "\b"
				elseif esc == "f"  then res[#res + 1] = "\f"
				elseif esc == "n"  then res[#res + 1] = "\n"
				elseif esc == "r"  then res[#res + 1] = "\r"
				elseif esc == "t"  then res[#res + 1] = "\t"
				elseif esc == "u" then
					local hex = raw:sub(pos, pos + 3)
					if lossless and not hex:match("^%x%x%x%x$") then return nil end
					local code = tonumber(hex, 16)
					if not code then return nil end
					pos = pos + 4
					-- A character above the Basic Multilingual Plane arrives as a
					-- surrogate pair; each half alone is not a character.
					if code >= 0xD800 and code <= 0xDBFF then
						local low = raw:sub(pos, pos + 1) == "\\u" and tonumber(raw:sub(pos + 2, pos + 5), 16)
						if low and low >= 0xDC00 and low <= 0xDFFF then
							pos = pos + 6
							code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
						else
							if lossless then return nil end
							code = REPLACEMENT_CHARACTER
						end
					elseif code >= 0xDC00 and code <= 0xDFFF then
						if lossless then return nil end
						code = REPLACEMENT_CHARACTER
					end
					res[#res + 1] = utf8_lib.char(code)
				else
					if lossless then return nil end
					res[#res + 1] = esc
				end
			else
				if lossless and ch:byte() < 32 then return nil end
				res[#res + 1] = ch
			end
		end
		return nil
	end

	parse_value = function()
		local c = skip_ws()
		if not c then return nil end

		if c == "{" then
			pos = pos + 1
			local obj = {}
			if skip_ws() == "}" then pos = pos + 1; return obj end
			while true do
				if skip_ws() ~= '"' then return nil end
				local key = parse_string()
				if type(key) ~= "string" then return nil end
				if skip_ws() ~= ":" then return nil end
				pos = pos + 1
				local val = parse_value()
				if val == nil then return nil end
				if lossless and obj[key] ~= nil then return nil end
				obj[key] = (val == NULL) and nil or val
				local sep = skip_ws()
				if sep == "}" then pos = pos + 1; return obj end
				if sep ~= "," then return nil end
				pos = pos + 1
			end
		end

		if c == "[" then
			pos = pos + 1
			local arr = {}
			if lossless then ARRAY_VALUES[arr] = true end
			if skip_ws() == "]" then pos = pos + 1; return arr end
			while true do
				local val = parse_value()
				if val == nil then return nil end
				table.insert(arr, val == NULL and nil or val)
				local sep = skip_ws()
				if sep == "]" then pos = pos + 1; return arr end
				if sep ~= "," then return nil end
				pos = pos + 1
			end
		end

		if c == '"' then return parse_string() end

		if c == "t" and raw:sub(pos, pos + 3) == "true"  then pos = pos + 4; return true end
		if c == "f" and raw:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
		if c == "n" and raw:sub(pos, pos + 3) == "null"  then pos = pos + 4; return NULL end

		local s, e = raw:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
		if s == pos then
			pos = e + 1
			local token = raw:sub(s, e)
			local number = tonumber(token)
			if lossless then
				local mantissa, exponent = token:match("^(.-)[eE](.*)$")
				if exponent and not exponent:match("^[+-]?%d+$") then return nil end
				mantissa = mantissa or token
				if not (mantissa:match("^%-?0$") or mantissa:match("^%-?[1-9]%d*$")
					or mantissa:match("^%-?0%.%d+$") or mantissa:match("^%-?[1-9]%d*%.%d+$")) then return nil end
				if not number or number == math.huge or number == -math.huge then return nil end
			end
			return number
		end

		return nil
	end

	local ok, result = pcall(parse_value)
	if not ok then return nil end
	if result == nil or skip_ws() ~= nil then return nil end
	return result == NULL and nil or result
end

--- Decodes JSON with the established untagged-table behavior.
--- @param raw string
--- @return any|nil Decoded legacy value, or nil on failure.
function M.decode(raw) return decode(raw, false) end

--- Decodes explicit JSON identities without altering the default decoder.
--- Rejects malformed or ambiguous values instead of normalizing their content.
--- @param raw string
--- @return any|nil Tagged arrays/null and ordinary objects, or nil on failure.
function M.decode_lossless(raw) return decode(raw, true) end

-- ============================================================================
-- 2. JSON encoder
-- ============================================================================

--- Encodes a Lua value to a minimal JSON string.
--- Handles nil, boolean, number, string, and table.
--- @param val any Lua value.
--- @return string|nil JSON string, or nil on unsupported type.
function M.encode(val)
	if val == nil or val == LOSSLESS_NULL then return "null" end
	local t = type(val)
	if t == "boolean" then return val and "true" or "false" end
	if t == "number" then
		if val ~= val then return "null" end
		if val == math.huge or val == -math.huge then return "null" end
		return string.format("%.17g", val):gsub("%.%d+", function(frac)
			return (frac:gsub("0+$", ""))
		end):gsub("%.$", "")
	end
	if t == "string" then return M.quote(val) end
	if t == "table" then
		if ARRAY_VALUES[val] then
			local count = array_length(val)
			if not count then return nil end
			local parts = {}
			for index = 1, count do
				local encoded = M.encode(val[index])
				if encoded == nil then return nil end
				parts[index] = encoded
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local is_array = true
		local max_idx = 0
		for k in pairs(val) do
			if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then is_array = false; break end
			if k > max_idx then max_idx = k end
		end
		if is_array and max_idx > 0 then
			local parts = {}
			for i = 1, max_idx do
				parts[i] = M.encode(val[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, v in pairs(val) do
			if type(k) == "string" then
				parts[#parts + 1] = M.encode(k) .. ":" .. M.encode(v)
			end
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return nil
end

return M
