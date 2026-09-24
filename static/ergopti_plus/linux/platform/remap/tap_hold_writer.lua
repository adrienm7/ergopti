--- platform/remap/tap_hold_writer.lua

--- ==============================================================================
--- MODULE: Tap-Hold Writer (Linux)
--- DESCRIPTION:
--- Persists a tray change to the user's tap_hold.toml, then reloads the daemon's
--- tap-hold engine so the change is in force on the next keystroke.
---
--- FEATURES & RATIONALE:
--- 1. The Windows writer's rules, on the file all three drivers read: a tap is
---    an action id, "" (the key itself) or "none" (nothing); a hold is a
---    modifier, a layer or none, and choosing one removes the other; "native"
---    clears both; « Disable all » starts from no key at all
---    (inherit_defaults = false) so the shipped defaults do not come back.
--- 2. Only the keys the user changed are written: every other key keeps
---    inheriting the shared default.
--- 3. The file is decoded by the shared TOML codec, not by a line scanner, and
---    re-encoded with escaped strings. A file that does not parse is never
---    overwritten: the change is refused and the user's text stays as it was.
--- 4. Temporary file then rename, so a crash mid-write cannot leave a file that
---    parses to nothing.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TomlCodec = require("toml_codec")
local BasicString = require("toml_codec.basic_string")
local Engine = require("platform.remap.tap_hold_engine")

local LOG = "platform.remap.tap_hold_writer"

-- The Windows loader's bound for time_activation_seconds.
local MAX_THRESHOLD_SECONDS = 10

local HEADER = {
	"# tap_hold.toml — written by the Ergopti+ tray menu.",
	"#",
	"# Only the keys you changed are listed. Every other key keeps its value from",
	"# the shared defaults, which the driver lays under this file key by key.",
}


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

local _path = nil
local _reload = nil
local _is_tap_action = nil
local _is_hold_option = nil


-- =========================================
-- =========================================
-- ======= 2/ Reading and writing ==========
-- =========================================
-- =========================================

--- Reads the user's file.
--- @return table|nil document, string|nil err
local function read_document()
	local fh = io.open(_path, "r")
	if not fh then return {} end
	local text = fh:read("*a")
	fh:close()
	local parsed = TomlCodec.decode(text)
	if type(parsed) ~= "table" then return nil, "malformed" end
	return parsed
end

--- The TOML spelling of one scalar or array.
--- @param value any
--- @return string
local function encode_value(value)
	local kind = type(value)
	if kind == "string" then return '"' .. BasicString.escape_body(value) .. '"' end
	if kind == "boolean" then return tostring(value) end
	if kind == "number" then
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then return string.format("%d", value) end
		return string.format("%.10g", value)
	end
	if kind == "table" then
		local parts = {}
		for index, item in ipairs(value) do parts[index] = encode_value(item) end
		return "[" .. table.concat(parts, ", ") .. "]"
	end
	error("tap_hold.toml cannot hold a " .. kind, 0)
end

--- Whether a table is an array (its values are written inline).
local function is_array(value)
	return type(value) == "table" and (next(value) == nil and false or value[1] ~= nil)
end

--- A bare TOML key, or a quoted one when it is not bare.
local function encode_key(key)
	if key:match("^[%w_%-]+$") then return key end
	return '"' .. BasicString.escape_body(key) .. '"'
end

--- Appends one table and its sub-tables, sorted, under `path`.
local function encode_table(out, tbl, path)
	local scalars, tables = {}, {}
	for key, value in pairs(tbl) do
		if type(value) == "table" and not is_array(value) then
			tables[#tables + 1] = key
		else
			scalars[#scalars + 1] = key
		end
	end
	table.sort(scalars)
	table.sort(tables)
	if path ~= "" and (#scalars > 0 or #tables == 0) then
		out[#out + 1] = ""
		out[#out + 1] = "[" .. path .. "]"
	end
	for _, key in ipairs(scalars) do
		out[#out + 1] = encode_key(key) .. " = " .. encode_value(tbl[key])
	end
	for _, key in ipairs(tables) do
		encode_table(out, tbl[key], path == "" and encode_key(key) or (path .. "." .. encode_key(key)))
	end
end

--- Replaces the file with `document`.
--- @param document table
--- @return boolean
local function write_document(document)
	local out = {}
	for _, line in ipairs(HEADER) do out[#out + 1] = line end
	encode_table(out, document, "")
	local tmp = _path .. ".tmp"
	local fh, err = io.open(tmp, "w")
	if not fh then
		Logger.error(LOG, "Cannot write '%s' (%s) — the change was not saved.", tmp, tostring(err))
		return false
	end
	fh:write(table.concat(out, "\n") .. "\n")
	fh:close()
	local ok, rename_err = os.rename(tmp, _path)
	if not ok then
		os.remove(tmp)
		Logger.error(LOG, "Cannot replace '%s' (%s) — the change was not saved.", _path, tostring(rename_err))
		return false
	end
	return true
end

--- Reads, changes, writes and reloads: one tray change.
--- @param what string For the logs.
--- @param mutate function(document) Changes the decoded document in place.
--- @return boolean True when the change is saved and in force.
local function commit(what, mutate)
	if not _path then
		Logger.error(LOG, "Tap-hold writer used before init() — '%s' not saved.", what)
		return false
	end
	local document, err = read_document()
	if not document then
		Logger.error(LOG, "'%s' is %s — '%s' refused rather than overwrite it.", _path, tostring(err), what)
		return false
	end
	mutate(document)
	if not write_document(document) then return false end
	Logger.info(LOG, "Tap-hold change saved: %s.", what)
	if not _reload() then
		Logger.error(LOG, "Tap-hold change '%s' saved but the engine did not reload.", what)
		return false
	end
	return true
end

--- The [tap_hold] table of a document, created when absent.
local function section(document)
	if type(document.tap_hold) ~= "table" then document.tap_hold = {} end
	return document.tap_hold
end

--- The [tap_hold.keys.<id>] table of a document, created when absent.
local function key_entry(document, key_id)
	local tap_hold = section(document)
	if type(tap_hold.keys) ~= "table" then tap_hold.keys = {} end
	if type(tap_hold.keys[key_id]) ~= "table" then tap_hold.keys[key_id] = {} end
	return tap_hold.keys[key_id]
end

local function valid_key(key_id, caller)
	if type(key_id) == "string" and Engine.KEY_CODES[key_id] then return true end
	Logger.error(LOG, "%s: unknown tap-hold key '%s' — nothing written.", caller, tostring(key_id))
	return false
end


-- =========================================
-- =========================================
-- ======= 3/ Public API ===================
-- =========================================
-- =========================================

--- Binds the writer to the user's file and the engine's reload.
--- @param opts table { path, reload() -> boolean, is_tap_action(id) -> boolean,
---   is_hold_option(kind, id) -> boolean }
function M.init(opts)
	if _path then error("tap-hold writer already initialised", 2) end
	if type(opts) ~= "table" or type(opts.path) ~= "string" or opts.path == "" then
		error("tap-hold writer requires a path", 2)
	end
	for _, name in ipairs({ "reload", "is_tap_action", "is_hold_option" }) do
		if type(opts[name]) ~= "function" then error("tap-hold writer requires " .. name, 2) end
	end
	_path = opts.path
	_reload = opts.reload
	_is_tap_action = opts.is_tap_action
	_is_hold_option = opts.is_hold_option
end

--- Sets a key's tap: an action id, "" for the key itself, "none" for nothing.
--- @param key_id string
--- @param action string
--- @return boolean
function M.set_tap(key_id, action)
	if not valid_key(key_id, "set_tap") then return false end
	if action ~= "" and action ~= "none" and not (type(action) == "string" and _is_tap_action(action)) then
		Logger.error(LOG, "set_tap: '%s' is not a tap action here — nothing written.", tostring(action))
		return false
	end
	return commit(key_id .. " tap = " .. (action == "" and "<native>" or action), function(document)
		local entry = key_entry(document, key_id)
		entry.tap_action = action
		entry.enabled = nil
	end)
end

--- Sets a key's hold: kind "modifier" (id "ctrl", "ctrl+shift"…), "layer" (id
--- "nav") or "none".
--- @param key_id string
--- @param kind string
--- @param id string
--- @return boolean
function M.set_hold(key_id, kind, id)
	if not valid_key(key_id, "set_hold") then return false end
	if not _is_hold_option(kind, id) then
		Logger.error(LOG, "set_hold: '%s:%s' is not a hold option — nothing written.", tostring(kind), tostring(id))
		return false
	end
	return commit(key_id .. " hold = " .. kind .. ":" .. tostring(id), function(document)
		local entry = key_entry(document, key_id)
		entry.hold_modifier, entry.hold_layer, entry.enabled = nil, nil, nil
		if kind == "layer" then
			entry.hold_layer = id
		elseif kind == "modifier" then
			entry.hold_modifier = id
		else
			-- Empty, not absent: absent would inherit the default's hold.
			entry.hold_modifier = ""
		end
	end)
end

--- Makes a key itself again: its own key on a tap, no hold.
--- @param key_id string
--- @return boolean
function M.set_native(key_id)
	if not valid_key(key_id, "set_native") then return false end
	return commit(key_id .. " native", function(document)
		local entry = key_entry(document, key_id)
		entry.tap_action, entry.hold_modifier, entry.hold_layer, entry.enabled = "", "", nil, nil
	end)
end

--- Sets a key's tap/hold threshold, in seconds; nil returns to the default.
--- @param key_id string
--- @param seconds number|nil
--- @return boolean
function M.set_threshold(key_id, seconds)
	if not valid_key(key_id, "set_threshold") then return false end
	if seconds ~= nil and (type(seconds) ~= "number" or seconds <= 0 or seconds > MAX_THRESHOLD_SECONDS) then
		Logger.error(LOG, "set_threshold: %s s is outside 0..%d s — nothing written.",
			tostring(seconds), MAX_THRESHOLD_SECONDS)
		return false
	end
	return commit(key_id .. " threshold = " .. tostring(seconds or "<default>"), function(document)
		key_entry(document, key_id).time_activation_seconds = seconds
	end)
end

--- Switches the feature on or off in the file ([tap_hold] enabled).
--- @param enabled boolean
--- @return boolean
function M.set_enabled(enabled)
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "set_enabled: a boolean is required — nothing written.")
		return false
	end
	return commit("feature " .. (enabled and "on" or "off"), function(document)
		section(document).enabled = enabled
	end)
end

--- « Disable all »: no key at all, and the shipped defaults do not come back.
--- @return boolean
function M.disable_all()
	return commit("disable all", function(document)
		local tap_hold = section(document)
		tap_hold.keys = nil
		tap_hold.inherit_defaults = false
	end)
end

--- « Reset to defaults »: the user's file goes, every key is the shared default.
--- @return boolean
function M.reset_all()
	if not _path then
		Logger.error(LOG, "Tap-hold writer used before init() — reset not done.")
		return false
	end
	local ok, err = os.remove(_path)
	local probe = io.open(_path, "r")
	if probe then
		probe:close()
		Logger.error(LOG, "Cannot remove '%s' (%s) — the tap-holds were not reset.", _path, tostring(err))
		return false
	end
	Logger.info(LOG, "Tap-hold overrides %s — every key is the shared default.", ok and "removed" or "absent")
	return _reload()
end

--- Whether the user's file names this key.
--- @param key_id string
--- @return boolean
function M.is_overridden(key_id)
	if not _path then return false end
	local document = read_document()
	return type(document) == "table" and type(document.tap_hold) == "table"
		and type(document.tap_hold.keys) == "table" and type(document.tap_hold.keys[key_id]) == "table"
end

--- Test seam: forgets the initialisation.
function M._reset_for_test()
	_path, _reload, _is_tap_action, _is_hold_option = nil, nil, nil, nil
end

return M
