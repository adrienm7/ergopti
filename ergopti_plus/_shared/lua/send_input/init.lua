--- _shared/lua/send_input/init.lua

--- ==============================================================================
--- MODULE: Send Input Parameters
--- DESCRIPTION:
--- Parses the parameters of the send_text, send_key and send_shortcut actions
--- for the macOS and Linux drivers: the text to type, the key to press and the
--- modifiers-plus-key to press. The grammar is pinned by
--- _shared/tests/corpus/action_parameters/send_input_vectors.json, which the
--- Windows suite replays against infra/send_input_parameter.ahk too.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the caller passes the vocabulary it decoded from
---    _shared/modules/actions/send_keys.json, so this module needs neither a
---    JSON decoder nor a path resolver, and each driver keeps its own.
--- 2. Code points, not bytes: an emoji is one character of text on every
---    driver, and a value that is not valid UTF-8 is refused rather than typed
---    as mojibake.
--- 3. Only A to Z is lowered. Lua's string.lower works on bytes, and the Windows
---    driver lowers the same range, so the three drivers read one value alike.
--- ==============================================================================

local M = {}

--- The three parameter kinds this module parses.
M.KINDS = { text = true, key = true, shortcut = true }

--- @param text string
--- @return string text without leading and trailing ASCII whitespace.
local function trim(text)
	return (text:gsub("^[ \t\r\n\v\f]+", ""):gsub("[ \t\r\n\v\f]+$", ""))
end

--- @param text string
--- @return string text with A to Z lowered and every other byte kept.
local function ascii_lower(text)
	return (text:gsub("%u", function(c) return string.char(c:byte() + 32) end))
end

--- Splits UTF-8 text into code points.
--- @param text string
--- @return table|nil Array of { char = string, code = integer }, or nil when
---   the text is not valid UTF-8.
local function code_points(text)
	local out = {}
	local i, n = 1, #text
	while i <= n do
		local b = text:byte(i)
		local width, code
		if b < 0x80 then
			width, code = 1, b
		elseif b >= 0xC2 and b <= 0xDF then
			width, code = 2, b - 0xC0
		elseif b >= 0xE0 and b <= 0xEF then
			width, code = 3, b - 0xE0
		elseif b >= 0xF0 and b <= 0xF4 then
			width, code = 4, b - 0xF0
		else
			return nil
		end
		if i + width - 1 > n then return nil end
		for j = i + 1, i + width - 1 do
			local c = text:byte(j)
			if c < 0x80 or c > 0xBF then return nil end
			code = code * 64 + (c - 0x80)
		end
		-- Overlong forms and surrogates are not characters.
		if (width == 3 and (code < 0x800 or (code >= 0xD800 and code <= 0xDFFF)))
			or (width == 4 and (code < 0x10000 or code > 0x10FFFF)) then
			return nil
		end
		out[#out + 1] = { char = text:sub(i, i + width - 1), code = code }
		i = i + width
	end
	return out
end

--- @param code integer
--- @return boolean True for C0 and C1 control characters.
local function is_control(code)
	return code <= 0x1F or (code >= 0x7F and code <= 0x9F)
end

--- Finds the vocabulary entry an id or alias names.
--- @param entries table send_keys.json "keys" or "modifiers".
--- @param wanted string A lowered token.
--- @return table|nil
local function find_entry(entries, wanted)
	for _, entry in ipairs(entries) do
		if entry.id == wanted then return entry end
		for _, alias in ipairs(entry.aliases or {}) do
			if alias == wanted then return entry end
		end
	end
	return nil
end

--- Refuses a vocabulary that is not the decoded send_keys.json shape.
--- @param vocabulary any
local function require_vocabulary(vocabulary)
	if type(vocabulary) ~= "table" or type(vocabulary.keys) ~= "table"
		or type(vocabulary.modifiers) ~= "table"
		or type(vocabulary.text_max_code_points) ~= "number" then
		error("send_input: the vocabulary is not the decoded send_keys.json", 3)
	end
end

--- Parses a send_text value.
--- @param value any
--- @param vocabulary table Decoded send_keys.json.
--- @return table|nil { text, canonical }
function M.parse_text(value, vocabulary)
	require_vocabulary(vocabulary)
	if type(value) ~= "string" then return nil end
	local points = code_points(value)
	if not points or #points == 0 or #points > vocabulary.text_max_code_points then return nil end
	for _, point in ipairs(points) do
		if is_control(point.code) then return nil end
	end
	return { text = value, canonical = value }
end

--- Parses a send_key value, or the key part of a shortcut.
--- @param value any
--- @param vocabulary table Decoded send_keys.json.
--- @param lower_letter boolean|nil True inside a shortcut, where A names the key.
--- @return table|nil { named = id } or { char = string }, with canonical.
function M.parse_key(value, vocabulary, lower_letter)
	require_vocabulary(vocabulary)
	if type(value) ~= "string" then return nil end
	local wanted = trim(value)
	if wanted == "" then return nil end
	local entry = find_entry(vocabulary.keys, ascii_lower(wanted))
	if entry then return { named = entry.id, canonical = entry.id } end
	local points = code_points(wanted)
	if not points or #points ~= 1 or is_control(points[1].code) then return nil end
	local char = lower_letter and ascii_lower(wanted) or wanted
	return { char = char, canonical = char }
end

--- Parses a send_shortcut value.
--- @param value any
--- @param vocabulary table Decoded send_keys.json.
--- @return table|nil { mods = { id... } in vocabulary order, named|char, canonical }
function M.parse_shortcut(value, vocabulary)
	require_vocabulary(vocabulary)
	if type(value) ~= "string" then return nil end
	local wanted = trim(value)
	if wanted == "" then return nil end
	local key_token, mod_part
	if #wanted >= 2 and wanted:sub(-2) == "++" then
		key_token, mod_part = "+", wanted:sub(1, -3)
	else
		mod_part, key_token = wanted:match("^(.*)%+([^+]*)$")
		if not mod_part then return nil end
	end
	local held = {}
	for token in (mod_part .. "+"):gmatch("([^+]*)%+") do
		local entry = find_entry(vocabulary.modifiers, ascii_lower(trim(token)))
		if not entry or held[entry.id] then return nil end
		held[entry.id] = true
	end
	local key = M.parse_key(key_token, vocabulary, true)
	if not key then return nil end
	local mods, prefix = {}, ""
	for _, entry in ipairs(vocabulary.modifiers) do
		if held[entry.id] then
			mods[#mods + 1] = entry.id
			prefix = prefix .. entry.id .. "+"
		end
	end
	key.mods = mods
	key.canonical = prefix .. key.canonical
	return key
end

--- Parses a value of one of the three kinds.
--- @param kind string "text", "key" or "shortcut".
--- @param value any
--- @param vocabulary table Decoded send_keys.json.
--- @return table|nil
function M.parse(kind, value, vocabulary)
	if kind == "text" then return M.parse_text(value, vocabulary) end
	if kind == "key" then return M.parse_key(value, vocabulary) end
	if kind == "shortcut" then return M.parse_shortcut(value, vocabulary) end
	error("send_input: no parameter kind '" .. tostring(kind) .. "'", 2)
end

--- The named keys as one line for a prompt, the run of function keys collapsed
--- to its bounds ("f1…f20") so the list stays readable.
--- @param vocabulary table Decoded send_keys.json.
--- @return string
function M.describe_keys(vocabulary)
	require_vocabulary(vocabulary)
	local names, first, last = {}, nil, nil
	for _, entry in ipairs(vocabulary.keys) do
		if entry.id:match("^f%d+$") then
			first = first or entry.id
			last = entry.id
		else
			names[#names + 1] = entry.id
		end
	end
	-- U+2026 HORIZONTAL ELLIPSIS, spelled as bytes so the source stays ASCII.
	if first then names[#names + 1] = first .. "\226\128\166" .. last end
	return table.concat(names, ", ")
end

--- The vocabulary entry of a named key or a modifier id.
--- @param vocabulary table Decoded send_keys.json.
--- @param family string "keys" or "modifiers".
--- @param id string
--- @return table The entry.
function M.entry(vocabulary, family, id)
	require_vocabulary(vocabulary)
	local entry = find_entry(vocabulary[family] or {}, id)
	if not entry then error("send_input: no " .. tostring(family) .. " entry '" .. tostring(id) .. "'", 2) end
	return entry
end

return M
