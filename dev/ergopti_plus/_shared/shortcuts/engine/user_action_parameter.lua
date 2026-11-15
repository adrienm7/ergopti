--- _shared/shortcuts/engine/user_action_parameter.lua

--- ==============================================================================
--- MODULE: User Action Parameters
--- DESCRIPTION:
--- The per-binding values of the run_command, open_path and run_apple_shortcut
--- actions for the macOS and Linux drivers: which stored strings are valid, what
--- they hold once decoded, and the one canonical spelling each editor stores.
---
--- FEATURES & RATIONALE:
--- 1. One rule, pinned by
---    _shared/tests/corpus/action_parameters/user_action_vectors.json, which
---    both Lua suites replay through their gesture validators.
--- 2. Versioned JSON with a closed key set for the two kinds that carry options
---    (command, apple_shortcut): an unknown key or option is refused instead of
---    being dropped, so a value written by a newer editor never runs half-read.
--- 3. Syntax only: whether a path still exists or a shortcut is still in the
---    library depends on the machine, so each action checks it when it runs and
---    refuses with a named reason.
--- 4. The command text is user configuration: nothing here logs a value.
--- ==============================================================================

local Json = require("core.text.engine.json")
local Unicode = require("core.lifecycle.engine.compat.utf8")
local TextUtils = require("core.text.engine.utils_core")

local M = {}

--- The parameter kinds this module owns, as actions.toml names them.
M.KINDS = { command = true, path = true, apple_shortcut = true }

--- The only schema version a stored value may carry.
M.VERSION = 1

--- Longest command line a run_command binding stores (bytes).
M.MAX_COMMAND_BYTES = 4096

--- Longest path an open_path binding stores (bytes): macOS and Linux PATH_MAX.
M.MAX_OPEN_PATH_BYTES = 4096

--- Longest shortcut name, as the Apple Shortcuts owner bounds it.
M.MAX_SHORTCUT_NAME_BYTES = 4096

--- Longest stderr line a failure notice quotes (bytes).
M.NOTICE_LINE_BYTES = 200

--- How a command runs: hidden (its output captured) or in a new terminal window.
M.COMMAND_MODES = { hidden = true, terminal = true }

--- The locale keys of each kind's editor prompt and refusal, spelled in full
--- so the translation audit sees every one of them.
M.PROMPT_KEYS = {
	command = "dialog.gestures.param_command",
	path = "dialog.gestures.param_path",
	apple_shortcut = "dialog.gestures.param_apple_shortcut",
}
M.ERROR_KEYS = {
	command = "dialog.gestures.param_err_command",
	path = "dialog.gestures.param_err_path",
	apple_shortcut = "dialog.gestures.param_err_apple_shortcut",
}

--- What happens to a captured text output: nothing, typed, or copied.
M.OUTPUTS = { none = true, type = true, copy = true }

--- What a shortcut receives: nothing, or the current selection as text.
M.SHORTCUT_INPUTS = { none = true, selection = true }

-- The byte range of the C0 control characters, and DEL.
local LAST_CONTROL_BYTE = 31
local DELETE_BYTE = 127
local TAB_BYTE = 9
local LINE_FEED_BYTE = 10

--- Whether a string is valid UTF-8 without NUL, within a byte bound.
--- @param value any
--- @param maximum number
--- @return boolean
local function clean(value, maximum)
	return type(value) == "string" and value ~= "" and #value <= maximum
		and not value:find("%z") and Unicode.len(value) ~= nil
end

--- Whether a string holds a control character other than the allowed ones.
--- @param value string
--- @param allow_lines boolean True to admit tabs and line feeds (a script).
--- @return boolean
local function has_control(value, allow_lines)
	for index = 1, #value do
		local byte = value:byte(index)
		if byte <= LAST_CONTROL_BYTE or byte == DELETE_BYTE then
			if not allow_lines or (byte ~= TAB_BYTE and byte ~= LINE_FEED_BYTE) then return true end
		end
	end
	return false
end

--- Decodes a versioned JSON object whose keys are exactly `keys`.
--- @param value any
--- @param keys table Array of the required key names, version excluded.
--- @return table|nil data
local function decode_object(value, keys)
	if type(value) ~= "string" then return nil end
	local ok, data = pcall(Json.decode_lossless, value)
	if not ok or type(data) ~= "table" or Json.is_array(data) or Json.is_null(data) then return nil end
	local allowed = { version = true }
	for _, key in ipairs(keys) do allowed[key] = true end
	local count = 0
	for key in pairs(data) do
		if not allowed[key] then return nil end
		count = count + 1
	end
	if count ~= #keys + 1 or data.version ~= M.VERSION then return nil end
	return data
end

--- Encodes fields in a fixed key order, so one value has one spelling.
--- @param keys table Array of key names, version excluded.
--- @param fields table
--- @return string
local function encode_object(keys, fields)
	local parts = { '"version":' .. tostring(M.VERSION) }
	for _, key in ipairs(keys) do parts[#parts + 1] = Json.quote(key) .. ":" .. Json.quote(fields[key]) end
	return "{" .. table.concat(parts, ",") .. "}"
end

local COMMAND_KEYS = { "command", "mode", "output" }
local SHORTCUT_KEYS = { "id", "name", "input", "output" }

--- Whether a value is the canonical Shortcuts identifier syntax (a UUID).
--- @param value any
--- @return boolean
function M.is_shortcut_identifier(value)
	return type(value) == "string" and #value == 36
		and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

--- Decodes a run_command value.
--- @param value any
--- @return table|nil command { command, mode, output }
local function parse_command(value)
	local data = decode_object(value, COMMAND_KEYS)
	if not data or not clean(data.command, M.MAX_COMMAND_BYTES) or has_control(data.command, true)
		or not data.command:find("%S") then return nil end
	if not M.COMMAND_MODES[data.mode] or not M.OUTPUTS[data.output] then return nil end
	-- A terminal window shows the output itself: nothing is captured to type or copy
	if data.mode == "terminal" and data.output ~= "none" then return nil end
	return { command = data.command, mode = data.mode, output = data.output }
end

--- Decodes an open_path value: an absolute path, as the native picker returns it.
--- @param value any
--- @return table|nil path { path }
local function parse_path(value)
	if not clean(value, M.MAX_OPEN_PATH_BYTES) or value:sub(1, 1) ~= "/" or has_control(value, false) then return nil end
	for component in value:gmatch("[^/]+") do
		if component == "." or component == ".." then return nil end
	end
	return { path = value }
end

--- Decodes a run_apple_shortcut value.
--- @param value any
--- @return table|nil shortcut { id, name, input, output }
local function parse_shortcut(value)
	local data = decode_object(value, SHORTCUT_KEYS)
	if not data or not M.is_shortcut_identifier(data.id) then return nil end
	if not clean(data.name, M.MAX_SHORTCUT_NAME_BYTES) or has_control(data.name, false) then return nil end
	if not M.SHORTCUT_INPUTS[data.input] or not M.OUTPUTS[data.output] then return nil end
	return { id = data.id, name = data.name, input = data.input, output = data.output }
end

local PARSERS = { command = parse_command, path = parse_path, apple_shortcut = parse_shortcut }

--- Decodes one stored value of a kind this module owns.
--- @param kind string command, path or apple_shortcut.
--- @param value any The stored parameter.
--- @return table|nil fields Nil when the value is invalid.
function M.parse(kind, value)
	local parser = PARSERS[kind]
	if not parser then error("user_action_parameter: unknown kind '" .. tostring(kind) .. "'", 2) end
	return parser(value)
end

--- The canonical spelling of fields, valid or not: an editor hands an invalid
--- spelling to its validator, which refuses it with the parameter's own error.
--- @param kind string command, path or apple_shortcut.
--- @param fields table String fields of the kind.
--- @return string value
function M.spell(kind, fields)
	if type(fields) ~= "table" then error("user_action_parameter.spell: fields must be a table", 2) end
	for key, field in pairs(fields) do
		if type(field) ~= "string" then
			error("user_action_parameter.spell: field '" .. tostring(key) .. "' must be a string", 2)
		end
	end
	if kind == "command" then return encode_object(COMMAND_KEYS, fields) end
	if kind == "apple_shortcut" then return encode_object(SHORTCUT_KEYS, fields) end
	if kind == "path" then return tostring(fields.path) end
	error("user_action_parameter: unknown kind '" .. tostring(kind) .. "'", 2)
end

--- The canonical stored value of a kind, nil when it would not parse back.
--- @param kind string command, path or apple_shortcut.
--- @param fields table The decoded fields.
--- @return string|nil value
function M.encode(kind, fields)
	local value = M.spell(kind, fields)
	if not M.parse(kind, value) then return nil end
	return value
end

--- What a menu shows for a stored value in its label's brackets: nothing for
--- a command (its text may hold a secret and a menu is on screen), the last
--- component of a path, a shortcut's name.
--- @param kind string command, path or apple_shortcut.
--- @param value any The stored parameter.
--- @return string|nil text Nil when the label keeps its configurable marker.
function M.label_value(kind, value)
	local fields = M.parse(kind, value)
	if not fields or kind == "command" then return nil end
	if kind == "apple_shortcut" then return fields.name end
	return fields.path:match("([^/]+)/*$") or "/"
end

--- The first line of a process's error output, bounded, for a failure notice.
--- @param text any The captured stderr.
--- @param maximum number Longest line kept, in bytes.
--- @return string|nil line Nil when there is no non-blank line.
function M.first_line(text, maximum)
	if type(text) ~= "string" then return nil end
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local trimmed = TextUtils.trim(line)
		if trimmed ~= "" then
			if #trimmed <= maximum then return trimmed end
			-- Cut on a character boundary: a split UTF-8 sequence is not text
			local cut = trimmed:sub(1, maximum)
			while #cut > 0 and Unicode.len(cut) == nil do cut = cut:sub(1, -2) end
			return cut .. "…"
		end
	end
	return nil
end

return M
