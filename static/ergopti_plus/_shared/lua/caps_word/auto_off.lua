--- _shared/lua/caps_word/auto_off.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Policy (shared)
--- DESCRIPTION:
--- Decides what ends CapsWord on its own, from the [shortcuts.caps_word]
--- settings: a delay without a keystroke, the word delimiters of the hotstring
--- delimiter catalogue, and the pointer kinds of [shortcuts.caps_word.pointer].
--- Native drivers keep event detection, timers and the deactivation itself.
---
--- FEATURES & RATIONALE:
--- 1. One Catalogue: the delimiters are the hotstring catalogue's built-in
---    entries (keymap.terminators_catalogue, generated from
---    Terminators.spec.js). Their keys, characters, order, separators and labels
---    come from there, so no driver keeps a list of its own.
--- 2. One Rule per Event: a typed payload ends CapsWord when any of its
---    characters belongs to a checked delimiter; a native key binding asks by
---    the delimiter key it types; a pointer event asks by its declared kind.
--- 3. Fail Fast: compile() refuses a malformed value, an unknown delimiter or
---    an undeclared or missing pointer kind instead of guessing; asking about a
---    key or kind the settings never declared raises.
--- The AHK port is _shared/modules/features/caps_word_auto_off_policy.ahk; both
--- replay _shared/tests/corpus/caps_word/auto_off_vectors.json.
--- ==============================================================================

local M = {}

-- LuaJIT has no utf8 table: ask the shim for the same functions instead of
-- depending on a global the entry point may not have installed.
local utf8_lib = (type(utf8) == "table" and utf8.codes and utf8.char) and utf8 or require("compat.utf8")
local Catalogue = require("keymap.terminators_catalogue")

local MS_PER_SECOND = 1000

-- Built-in delimiter key -> its characters, from the generated catalogue only.
local CHARS_BY_KEY = {}
for _, def in ipairs(Catalogue) do
	if def.key then CHARS_BY_KEY[def.key] = def.chars end
end





-- ======================================
-- ======================================
-- ======= 1/ Settings Validation =======
-- ======================================
-- ======================================

--- Whether `key` names a built-in delimiter of the hotstring catalogue.
--- @param key any Candidate delimiter key.
--- @return boolean
function M.is_terminator_key(key)
	return type(key) == "string" and CHARS_BY_KEY[key] ~= nil
end

--- Validates the stored inactivity delay.
--- @param value any Candidate number of seconds (0 = never).
--- @return boolean valid
--- @return string|nil reason Stable refusal reason.
function M.validate_idle_timeout(value)
	if type(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
		return false, "invalid_idle_timeout"
	end
	return true
end

--- Validates the stored delimiter list.
--- @param value any Candidate array of delimiter keys.
--- @return boolean valid
--- @return string|nil reason Stable refusal reason.
function M.validate_terminators(value)
	if type(value) ~= "table" then return false, "invalid_terminators" end
	local count, seen = 0, {}
	for _ in pairs(value) do count = count + 1 end
	if count ~= #value then return false, "invalid_terminators" end
	for _, key in ipairs(value) do
		if not M.is_terminator_key(key) then return false, "unknown_terminator" end
		if seen[key] then return false, "duplicate_terminator" end
		seen[key] = true
	end
	return true
end

--- Compiles validated settings into an immutable-by-convention policy.
--- @param values table { idle_timeout_seconds, terminators, pointer }.
--- @param pointer_kinds table Dense array of the declared pointer kind ids.
--- @return table|nil policy
--- @return string|nil reason Stable refusal reason.
function M.compile(values, pointer_kinds)
	if type(values) ~= "table" then return nil, "invalid_settings" end
	if type(pointer_kinds) ~= "table" or #pointer_kinds == 0 then return nil, "invalid_pointer_kinds" end
	local idle_ok, idle_reason = M.validate_idle_timeout(values.idle_timeout_seconds)
	if not idle_ok then return nil, idle_reason end
	local list_ok, list_reason = M.validate_terminators(values.terminators)
	if not list_ok then return nil, list_reason end
	local pointer = values.pointer
	if type(pointer) ~= "table" then return nil, "invalid_pointer" end
	local declared, kinds = {}, {}
	for _, kind in ipairs(pointer_kinds) do
		if type(kind) ~= "string" or kind == "" or declared[kind] then return nil, "invalid_pointer_kinds" end
		declared[kind] = true
		if type(pointer[kind]) ~= "boolean" then return nil, "invalid_pointer" end
		kinds[kind] = pointer[kind]
	end
	for kind in pairs(pointer) do
		if not declared[kind] then return nil, "unknown_pointer_kind" end
	end
	local keys, chars = {}, {}
	for _, key in ipairs(values.terminators) do
		keys[key] = true
		for _, char in ipairs(CHARS_BY_KEY[key]) do chars[char] = true end
	end
	local seconds = values.idle_timeout_seconds
	return {
		idle_ms = seconds > 0 and math.floor(seconds * MS_PER_SECOND + 0.5) or nil,
		keys = keys,
		chars = chars,
		pointer = kinds,
	}
end





-- =====================================
-- =====================================
-- ======= 2/ Deactivation Rules =======
-- =====================================
-- =====================================

local function require_policy(policy)
	if type(policy) ~= "table" or type(policy.keys) ~= "table" or type(policy.chars) ~= "table"
		or type(policy.pointer) ~= "table" then
		error("caps_word.auto_off: a compiled policy is required", 3)
	end
end

--- Whether one typed payload ends CapsWord: any of its characters belongs to
--- a checked delimiter. A composed or multi-codepoint payload (a French
--- spaced punctuation carrier, an IME commit) is read character by character.
--- @param policy table Compiled policy.
--- @param text any Characters of one typed event.
--- @return boolean
function M.ends_on_text(policy, text)
	require_policy(policy)
	if type(text) ~= "string" or text == "" then return false end
	if policy.chars[text] then return true end
	local ok, ends = pcall(function()
		for _, codepoint in utf8_lib.codes(text) do
			if policy.chars[utf8_lib.char(codepoint)] then return true end
		end
		return false
	end)
	return ok and ends == true
end

--- Whether a native key the driver binds itself ends CapsWord, by the
--- delimiter key it types.
--- @param policy table Compiled policy.
--- @param key string Built-in delimiter key.
--- @return boolean
function M.ends_on_key(policy, key)
	require_policy(policy)
	if not M.is_terminator_key(key) then
		error("caps_word.auto_off: unknown delimiter key " .. tostring(key), 2)
	end
	return policy.keys[key] == true
end

--- Whether a pointer event of a declared kind ends CapsWord.
--- @param policy table Compiled policy.
--- @param kind string Declared pointer kind id.
--- @return boolean
function M.ends_on_pointer(policy, kind)
	require_policy(policy)
	local enabled = policy.pointer[kind]
	if type(enabled) ~= "boolean" then
		error("caps_word.auto_off: undeclared pointer kind " .. tostring(kind), 2)
	end
	return enabled
end

--- The inactivity delay in milliseconds, or nil when CapsWord never times out.
--- @param policy table Compiled policy.
--- @return number|nil
function M.idle_delay_ms(policy)
	require_policy(policy)
	return policy.idle_ms
end

--- Whether the delay has passed since the last keystroke.
--- @param policy table Compiled policy.
--- @param last_ms number Clock of the last keystroke (or the activation).
--- @param now_ms number Same clock, now.
--- @return boolean
function M.idle_expired(policy, last_ms, now_ms)
	require_policy(policy)
	if type(last_ms) ~= "number" or type(now_ms) ~= "number" then
		error("caps_word.auto_off: idle_expired needs two clock readings", 2)
	end
	return policy.idle_ms ~= nil and now_ms - last_ms >= policy.idle_ms
end





-- ===============================
-- ===============================
-- ======= 3/ Menu Helpers =======
-- ===============================
-- ===============================

--- The delimiter checkbox rows, in catalogue order with its separators.
--- @return table Dense array of { key, label_key } or { separator = true }.
function M.terminator_rows()
	local rows = {}
	for _, def in ipairs(Catalogue) do
		if def.key then
			rows[#rows + 1] = { key = def.key, label_key = def.label_key }
		elseif def.type == "separator" then
			rows[#rows + 1] = { separator = true }
		end
	end
	return rows
end

--- Returns the delimiter list with `key` checked or unchecked, in catalogue
--- order, so every driver stores the same array for the same choice.
--- @param list table Valid current delimiter list.
--- @param key string Built-in delimiter key.
--- @param checked boolean Wanted state.
--- @return table|nil list
--- @return string|nil reason Stable refusal reason.
function M.with_terminator(list, key, checked)
	local ok, reason = M.validate_terminators(list)
	if not ok then return nil, reason end
	if not M.is_terminator_key(key) then return nil, "unknown_terminator" end
	if type(checked) ~= "boolean" then return nil, "invalid_state" end
	local wanted = {}
	for _, current in ipairs(list) do wanted[current] = true end
	wanted[key] = checked or nil
	local out = {}
	for _, def in ipairs(Catalogue) do
		if def.key and wanted[def.key] then out[#out + 1] = def.key end
	end
	return out
end

return M
