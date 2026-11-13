--- tap_hold/engine/writer.lua

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
---    clears both. The scope restore and clear render through render_scope()
---    and publish through tap_hold/engine/scope.lua, never through commit().
---    The first-run wizard imports its checked keys through import_recommended(),
---    into the folder it configures, before the daemon restarts on it: it only
---    adds keys, refuses to overwrite one the user configured, and backs the
---    file up first.
--- 2. Only the keys the user changed are written: every other key keeps
---    inheriting the shared default.
--- 3. The file is decoded by the shared TOML codec, not by a line scanner, and
---    re-encoded with escaped strings. A file that does not parse is never
---    overwritten: the change is refused and the user's text stays as it was.
--- 4. Temporary file then rename, so a crash mid-write cannot leave a file that
---    parses to nothing.
--- 5. The switch and the two timings are manifest rows: set_enabled,
---    set_lone_tap_max_ms and set_one_shot_timeout_ms publish config.toml
---    `[tap_holds]` beside the file (maintainer decision of 2026-11-11), through
---    the shared config writer, then reload the engine.
--- 6. The layer comes with its key: a hold that enters Ergopti's recommended
---    layer creates the folder's layers.toml from it when there is none
---    (keymap.layer_preset), before the engine reloads. A key set to hold
---    the navigation layer in a folder without that file entered a layer
---    that binds no key. An existing file is the user's and stays; a change
---    that is not saved removes only the file it created. The folder is
---    named by init(): a writer bound to none touches no layer file.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local TomlCodec = require("core.text.engine.toml_codec")
local TomlWriter = require("core.text.engine.toml_codec.writer")
local BasicString = require("core.text.engine.toml_codec.basic_string")
local Engine = require("tap_hold.engine.engine")
local Manifest = require("menu.engine.manifest_reader")
local LayerPreset = require("layouts.engine.layers.preset")
local Shapes = require("tap_hold.engine.shapes")
local KeyCatalog = require("tap_hold.engine.key_catalog")
local Migration = require("tap_hold.engine.migration")
local Paths = require("core.fs.engine.paths")
local ConfigKeys = require("settings.engine.keys")
local LoneTap = require("tap_hold.engine.lone_tap")

local LOG = "tap_hold.engine.writer"

--- The user file's name in the configuration folder.
M.FILE_NAME = require("tap_hold.engine.shared_file").FILE_NAME

-- The bound of time_activation_seconds: the timing registry's.
local MAX_THRESHOLD_SECONDS = require("core.timing.engine.timings").ms("tap_hold", "max_activation_ms") / 1000

-- The per-key fields whose runtime meaning belongs to this writer. A delay is
-- only ever written when the user sets it: no key ships one.
local OWNED_KEY_FIELDS = { "tap_action", "hold_modifier", "hold_layer", "enabled", ConfigKeys.LEAF.TIME_ACTIVATION_SECONDS }

-- The macOS-only hold of the shared file (_shared/tap_hold/data/SCHEMA.md): a hold
-- chosen here replaces it, so every driver holds what the user just chose.
local FOREIGN_HOLD_FIELD = "hold_action"

-- The config.toml [tap_holds] fields of the lone modifier tap window and of
-- the one-shot timeout (the loader's).
local LONE_TAP_FIELD = require("tap_hold.engine.loader").LONE_TAP_FIELD
local ONE_SHOT_TIMEOUT_FIELD = require("tap_hold.engine.loader").ONE_SHOT_TIMEOUT_FIELD
-- The [tap_hold] leaves config.toml owns since config schema v22: a scope
-- render drops one a migration could not delete.
local CONFIG_OWNED_FIELDS = { "enabled", LONE_TAP_FIELD, ONE_SHOT_TIMEOUT_FIELD }

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
local _config_path = nil      -- The config.toml the switch and the timings are published to.
local _reload = nil
local _is_tap_action = nil
local _canonical_hold = nil
local _layers = nil          -- { shared_root, config_dir, file_adapter } a layer hold imports into, or nil.
local _backup_sequence = 0    -- Keeps the wizard import's backups unique.
local _retired = nil          -- The delays earlier builds shipped, read once by init().


-- =========================================
-- =========================================
-- ======= 2/ Reading and writing ==========
-- =========================================
-- =========================================

--- Reads a tap_hold.toml; an absent file is an empty document.
--- @param path string
--- @return table|nil document, string|nil err, string|nil text The file's bytes.
--- @return table|nil shapes Canonical array identities for this document.
local function read_document(path)
	local text, status, detail = TomlWriter.read_classified(path)
	if status == "absent" then return {}, nil, nil, { arrays = {} } end
	if status ~= "ok" then return nil, detail end
	local parsed, shapes = TomlCodec.decode_with_shapes(text)
	if type(parsed) ~= "table" then return nil, "malformed" end
	return parsed, nil, text, shapes
end

--- Copies a file's bytes to a new backup beside it, then reads them back.
--- @param path string The file being replaced.
--- @param text string Its bytes.
--- @return string|nil backup The backup path, nil when it could not be made.
local function back_up(path, text)
	_backup_sequence = _backup_sequence + 1
	local backup = string.format("%s.tap_holds-%s-%d.bak", path, os.date("%Y%m%d-%H%M%S"), _backup_sequence)
	local opened, fh, _, _, remove_owned, current_image = pcall(require("core.fs.engine.regular_file_writer").open, backup, "wx")
	if not opened or not fh then return nil end
	if type(remove_owned) ~= "function" or type(current_image) ~= "function" then
		pcall(fh.close, fh)
		if type(remove_owned) == "function" then pcall(remove_owned) end
		return nil
	end
	local wrote, result = pcall(fh.write, fh, text)
	local closed, close_result = pcall(fh.close, fh)
	if not wrote or (result ~= true and result ~= fh) or not closed or close_result ~= true then
		pcall(remove_owned)
		return nil
	end
	local checked, current = pcall(current_image, text)
	if not checked or current ~= true then return nil end
	return backup
end

--- The TOML spelling of one scalar or array.
--- @param value any
--- @return string
local function encode_value(value, shapes, owner, key)
	local kind = type(value)
	if kind == "string" then return '"' .. BasicString.escape_body(value) .. '"' end
	if kind == "boolean" then return tostring(value) end
	if kind == "number" then
		if shapes then return TomlCodec.encode_value_with_shapes(value, shapes, owner, key) end
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then return string.format("%d", value) end
		return string.format("%.10g", value)
	end
	if kind == "table" then
		if shapes then return TomlCodec.encode_value_with_shapes(value, shapes, owner, key) end
		return TomlCodec.encode_value(value)
	end
	error("tap_hold.toml cannot hold a " .. kind, 0)
end

--- Whether a table is an array (its values are written inline).
local function is_array(value, shapes)
	return type(value) == "table" and not Shapes.is_table(value, shapes)
end

--- A bare TOML key, or a quoted one when it is not bare.
local function encode_key(key)
	if key:match("^[%w_%-]+$") then return key end
	return '"' .. BasicString.escape_body(key) .. '"'
end

--- Appends one table and its sub-tables, sorted, under `path`.
local function encode_table(out, tbl, path, shapes)
	local scalars, tables = {}, {}
	for key, value in pairs(tbl) do
		if type(value) == "table" and not is_array(value, shapes) then
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
		out[#out + 1] = encode_key(key) .. " = " .. encode_value(tbl[key], shapes, tbl, key)
	end
	for _, key in ipairs(tables) do
		encode_table(out, tbl[key], path == "" and encode_key(key) or (path .. "." .. encode_key(key)), shapes)
	end
end

--- The file's complete text for `document`, as every tray change writes it.
--- @param document table
--- @return string
local function render_document(document, shapes)
	local out = {}
	for _, line in ipairs(HEADER) do out[#out + 1] = line end
	encode_table(out, document, "", shapes)
	return table.concat(out, "\n") .. "\n"
end

--- Requires an exact editor acknowledgement; legacy synchronous writers omit it.
--- @param guard function|nil
--- @return boolean
local function edit_current(guard)
	if guard == nil then return true end
	local ok, current = pcall(guard)
	if ok and current == true then return true end
	Logger.error(LOG, "Tap-hold editor is no longer current — nothing written.")
	return false
end

--- Replaces a tap_hold.toml only while its source and optional editor survive.
--- @param path string
--- @param document table
--- @return boolean
local function write_document(path, document, shapes, expected_source, guard)
	local text = render_document(document, shapes)
	if type(TomlCodec.decode(text)) ~= "table" then
		Logger.error(LOG, "'%s' rendered an invalid tap-hold candidate — nothing written.", path)
		return false
	end
	local tmp = path .. ".tmp"
	local opened, fh, err, _, remove_owned, current_image = pcall(require("core.fs.engine.regular_file_writer").open, tmp, "wx")
	if not opened or not fh or type(remove_owned) ~= "function" or type(current_image) ~= "function" then
		if opened and fh then
			pcall(fh.close, fh)
			if type(remove_owned) == "function" then pcall(remove_owned) end
		end
		Logger.error(LOG, "Cannot write '%s' (%s) — the change was not saved.", tmp, tostring(opened and err or fh))
		return false
	end
	local function discard()
		local called, removed, detail = pcall(remove_owned)
		if not called or removed ~= true then
			Logger.error(LOG, "Cannot remove refused staging file '%s' (%s).", tmp, tostring(called and detail or removed))
		end
	end
	local write_ok, written, write_err = pcall(fh.write, fh, text)
	local close_ok, closed, close_err = pcall(fh.close, fh)
	-- Lua 5.1 returns true from file:write; later Lua returns that same file.
	local write_ack = write_ok and (written == true or written == fh)
	if not write_ack or not close_ok or closed ~= true then
		discard()
		local detail = not write_ok and written or (not write_ack and write_err)
			or (not close_ok and closed) or close_err or "write or close acknowledgement refused"
		Logger.error(LOG, "Cannot complete staging file '%s' (%s) — the change was not saved.", tmp, tostring(detail))
		return false
	end
	local current, status = TomlWriter.read_classified(path)
	if expected_source and (status ~= expected_source.status
		or (status == "ok" and current ~= expected_source.content)) then
		discard()
		Logger.error(LOG, "'%s' changed before tap-hold publication — the source is preserved.", path)
		return false
	end
	if not edit_current(guard) then
		discard()
		return false
	end
	local checked, owned = pcall(current_image, text)
	if not checked or owned ~= true then
		Logger.error(LOG, "Tap-hold staging image is no longer owned — the change was not saved.")
		return false
	end
	local ok, rename_err = os.rename(tmp, path)
	if not ok then
		discard()
		Logger.error(LOG, "Cannot replace '%s' (%s) — the change was not saved.", path, tostring(rename_err))
		return false
	end
	return true
end

-- Defined with the document helpers below: every write migrates before it applies.
local migrate_document

--- Reads, changes, writes and reloads: one tray change.
--- @param what string For the logs.
--- @param mutate function(document, shapes) Changes the decoded document in place.
--- @return boolean True when the change is saved and in force.
--- @return boolean saved True once the file holds the change, reloaded or not.
local function save_and_reload(what, mutate, prepare, guard)
	if not _path then
		Logger.error(LOG, "Tap-hold writer used before init() — '%s' not saved.", what)
		return false, false
	end
	local path, reload = _path, _reload
	local function current()
		return _path == path and _reload == reload and edit_current(guard)
	end
	local document, err, text, shapes = read_document(path)
	if not document then
		Logger.error(LOG, "'%s' is %s — '%s' refused rather than overwrite it.", _path, tostring(err), what)
		return false, false
	end
	if guard ~= nil and not current() then return false, false end
	local changed, detail = pcall(function()
		migrate_document(document, shapes)
		mutate(document, shapes)
	end)
	if not changed then
		Logger.error(LOG, "Tap-hold change '%s' refused: %s.", what, tostring(detail))
		return false, false
	end
	if prepare and prepare() ~= true then return false, false end
	if not write_document(path, document, shapes, { status = text and "ok" or "absent", content = text }, guard ~= nil and current or nil) then return false, false end
	Logger.info(LOG, "Tap-hold change saved: %s.", what)
	local called, reloaded = pcall(reload)
	if not called or reloaded ~= true then
		Logger.error(LOG, "Tap-hold change '%s' saved but the engine did not reload.", what)
		return false, true
	end
	return true, true
end

--- One tray change, as the public setters report it.
--- @param what string For the logs.
--- @param mutate function(document, shapes) Changes the decoded document in place.
--- @return boolean True when the change is saved and in force.
local function commit(what, mutate, guard)
	local in_force = save_and_reload(what, mutate, nil, guard)
	return in_force
end

-- What import_layer() answers when a hold brings no layer file.
local NO_LAYER = { status = LayerPreset.KEPT }

--- Creates layers.toml from Ergopti's recommended layer when a hold enters
--- that layer and the bound folder has none.
--- @param kind string The hold's kind.
--- @param layer_id string The canonical layer id of a layer hold.
--- @return table|nil import What LayerPreset.import_if_absent() returned, NO_LAYER when nothing is due.
--- @return string|nil err Why the absent file could not be created.
local function import_layer(kind, layer_id)
	if kind ~= "layer" or not _layers then return NO_LAYER end
	local ok, import, err = pcall(function()
		if LayerPreset.read(_layers.shared_root, TomlCodec.decode).layer_id ~= layer_id then return NO_LAYER end
		return LayerPreset.import_if_absent({
			shared_root = _layers.shared_root, config_dir = _layers.config_dir,
			toml_decode = TomlCodec.decode, file_adapter = _layers.file_adapter,
		})
	end)
	if not ok then return nil, tostring(import) end
	if not import then return nil, err end
	if import.status == LayerPreset.IMPORTED then
		Logger.info(LOG, "Recommended navigation layer imported into '%s'.", import.path)
	end
	return import
end

--- Removes the layers.toml a change that was not saved created.
--- @param import table What import_layer() returned.
local function undo_layer(import)
	local undone, err = LayerPreset.undo(import, _layers and _layers.file_adapter or nil)
	if undone ~= true then
		Logger.error(LOG, "The navigation layer '%s' an unsaved hold change created could not be removed: %s.",
			tostring(import.path), tostring(err))
	end
end

--- The [tap_hold] table of a document, created when absent.
local function section(document, shapes)
	Shapes.require_table(document.tap_hold, shapes, "tap_hold")
	if document.tap_hold == nil then document.tap_hold = {} end
	return document.tap_hold
end

--- The [tap_hold.keys.<id>] table of a document, created when absent.
local function key_entry(document, key_id, shapes)
	local tap_hold = section(document, shapes)
	Shapes.require_table(tap_hold.keys, shapes, "tap_hold.keys")
	if tap_hold.keys == nil then tap_hold.keys = {} end
	Shapes.require_table(tap_hold.keys[key_id], shapes, "tap_hold.keys." .. key_id)
	if tap_hold.keys[key_id] == nil then tap_hold.keys[key_id] = {} end
	return tap_hold.keys[key_id]
end

--- The per-key delays earlier builds shipped, by key id: see
--- `[tap_hold.retired_delays]` in the shared defaults. Read once by init(), so a
--- write opens no file but its own.
--- @return table key id -> seconds
local function retired_delays()
	-- init() reads it; the wizard import runs without an init, so it reads on demand.
	if _retired == nil then
		_retired = KeyCatalog.load_retired_delays(Paths.shared("tap_hold/data/defaults.toml"), "linux")
	end
	return _retired
end

--- Brings a decoded document to the current file version in place (see
--- _shared/tap_hold/data/migrations.toml): the per-key delays earlier builds shipped
--- are removed once and the stamp is set, so every write publishes a stamped
--- file and every delay it keeps is the user's own. A current document is
--- untouched. A file saved by a newer build, or with an unreadable stamp, is
--- refused: this build never rewrites what it cannot version.
--- @param document table Decoded user document, edited in place.
--- @param shapes table|nil Canonical shape receipt of the document.
--- @return string outcome "migrated" or "current".
--- @return number from The version the document carried.
migrate_document = function(document, shapes)
	local outcome, detail = Migration.read_as_current(document, shapes, retired_delays())
	if outcome == "newer" then
		error("the file was saved by a newer build (schema v" .. tostring(detail) .. "); update before changing it", 0)
	end
	if outcome == "invalid" then error(tostring(detail), 0) end
	return outcome, detail
end

--- Removes only fields whose runtime meaning belongs to this writer, on every
--- key this engine knows and every key of the shipped preset.
--- @param tap_hold table
--- @param preset table key id -> fields of the shipped preset.
local function clear_owned_keys(tap_hold, preset, shapes)
	if tap_hold.keys == nil then return end
	Shapes.require_table(tap_hold.keys, shapes, "tap_hold.keys")
	local owned = {}
	for key_id in pairs(Engine.KEY_CODES) do owned[key_id] = true end
	for key_id in pairs(preset) do owned[key_id] = true end
	for key_id in pairs(owned) do
		local entry = tap_hold.keys[key_id]
		if Shapes.is_table(entry, shapes) then
			for _, field in ipairs(OWNED_KEY_FIELDS) do entry[field] = nil end
			entry[FOREIGN_HOLD_FIELD] = nil
			if next(entry) == nil then tap_hold.keys[key_id] = nil end
		end
	end
	if next(tap_hold.keys) == nil then tap_hold.keys = nil end
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
--- @param opts table { path, config_path|nil (the config.toml beside path by
---   default), reload() -> boolean, is_tap_action(id) -> boolean,
---   canonical_hold(kind, id) -> string|nil, string|nil,
---   layers = { shared_root, config_dir, file_adapter|nil } | nil }: the folder
---   whose layers.toml a hold entering the recommended layer creates when
---   absent; without it no layer file is touched.
function M.init(opts)
	if _path then error("tap-hold writer already initialised", 2) end
	if type(opts) ~= "table" or type(opts.path) ~= "string" or opts.path == "" then
		error("tap-hold writer requires a path", 2)
	end
	for _, name in ipairs({ "reload", "is_tap_action", "canonical_hold" }) do
		if type(opts[name]) ~= "function" then error("tap-hold writer requires " .. name, 2) end
	end
	if opts.layers ~= nil then
		if type(opts.layers) ~= "table" then error("tap-hold writer layers must be a table", 2) end
		for _, name in ipairs({ "shared_root", "config_dir" }) do
			if type(opts.layers[name]) ~= "string" or opts.layers[name] == "" then
				error("tap-hold writer layers require " .. name, 2)
			end
		end
		_layers = { shared_root = opts.layers.shared_root, config_dir = opts.layers.config_dir,
			file_adapter = opts.layers.file_adapter }
	end
	if opts.config_path ~= nil and (type(opts.config_path) ~= "string" or opts.config_path == "") then
		error("tap-hold writer config_path must be a path", 2)
	end
	retired_delays()
	_path = opts.path
	_config_path = opts.config_path or M.config_path_for(opts.path)
	_reload = opts.reload
	_is_tap_action = opts.is_tap_action
	_canonical_hold = opts.canonical_hold
end

--- Sets a key's tap: an action id, "" for the key itself, "none" for nothing.
--- @param key_id string
--- @param action string
--- @param guard function|nil Original deferred editor, strict true required.
--- @return boolean
function M.set_tap(key_id, action, guard)
	if not valid_key(key_id, "set_tap") then return false end
	if action ~= "" and action ~= "none" and not (type(action) == "string" and _is_tap_action(action)) then
		Logger.error(LOG, "set_tap: '%s' is not a tap action here — nothing written.", tostring(action))
		return false
	end
	return commit(key_id .. " tap = " .. (action == "" and "<native>" or action), function(document, shapes)
		local entry = key_entry(document, key_id, shapes)
		entry.tap_action = action
		entry.enabled = nil
	end, guard)
end

--- Sets a key's hold: kind "modifier" (id "ctrl", "ctrl+shift"…), "layer" (id
--- "nav") or "none". The id is written in the canonical form the loader
--- reads back, whatever spelling it came in.
--- @param key_id string
--- @param kind string
--- @param id string
--- @return boolean
function M.set_hold(key_id, kind, id)
	if not valid_key(key_id, "set_hold") then return false end
	local canonical, err = _canonical_hold(kind, id)
	if not canonical then
		Logger.error(LOG, "set_hold: '%s:%s' is not a hold option (%s) — nothing written.",
			tostring(kind), tostring(id), tostring(err))
		return false
	end
	local layer = nil
	local in_force, saved = save_and_reload(key_id .. " hold = " .. kind .. ":" .. canonical, function(document, shapes)
		local entry = key_entry(document, key_id, shapes)
		entry.hold_modifier, entry.hold_layer, entry.enabled = nil, nil, nil
		entry[FOREIGN_HOLD_FIELD] = nil
		if kind == "layer" then
			entry.hold_layer = canonical
		elseif kind == "modifier" then
			entry.hold_modifier = canonical
		else
			-- Empty, not absent: absent would inherit the default's hold.
			entry.hold_modifier = ""
		end
	end, function()
		local layer_err
		layer, layer_err = import_layer(kind, canonical)
		if not layer then
			Logger.error(LOG, "set_hold: the recommended navigation layer cannot be imported (%s) — nothing written.",
				tostring(layer_err))
			return false
		end
		return true
	end)
	-- A saved key keeps the layer it enters, even when the reload failed.
	if not saved and layer then undo_layer(layer) end
	return in_force
end

--- Makes a key itself again: its own key on a tap, no hold.
--- @param key_id string
--- @return boolean
function M.set_native(key_id)
	if not valid_key(key_id, "set_native") then return false end
	return commit(key_id .. " native", function(document, shapes)
		local entry = key_entry(document, key_id, shapes)
		entry.tap_action, entry.hold_modifier, entry.hold_layer, entry.enabled = "", "", nil, nil
		entry[FOREIGN_HOLD_FIELD] = nil
	end)
end

--- Sets a key's tap/hold threshold, in seconds; nil returns to the default.
--- @param key_id string
--- @param seconds number|nil
--- @param guard function|nil Original deferred editor, strict true required.
--- @return boolean
function M.set_threshold(key_id, seconds, guard)
	if not valid_key(key_id, "set_threshold") then return false end
	if seconds ~= nil and (type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 or seconds > MAX_THRESHOLD_SECONDS) then
		Logger.error(LOG, "set_threshold: %s s is outside 0..%d s — nothing written.",
			tostring(seconds), MAX_THRESHOLD_SECONDS)
		return false
	end
	return commit(key_id .. " threshold = " .. tostring(seconds or "<global>"), function(document, shapes)
		local entry = key_entry(document, key_id, shapes)
		entry.time_activation_seconds = seconds
		-- A key that follows the global delay and holds nothing else is not listed.
		if next(entry) == nil then document.tap_hold.keys[key_id] = nil end
		if next(document.tap_hold.keys) == nil then document.tap_hold.keys = nil end
	end, guard)
end

--- Sets the GLOBAL delay, in seconds: the delay of every key that has none of
--- its own. A key with a delay of its own keeps it. nil removes the setting, so
--- the timing registry's default applies again.
--- @param seconds number|nil
--- @param guard function|nil Original deferred editor, strict true required.
--- @return boolean
function M.set_global_threshold(seconds, guard)
	if seconds ~= nil and (type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0
		or seconds > MAX_THRESHOLD_SECONDS) then
		Logger.error(LOG, "set_global_threshold: %s s is outside 0..%d s — nothing written.",
			tostring(seconds), MAX_THRESHOLD_SECONDS)
		return false
	end
	return commit("global threshold = " .. tostring(seconds or "<default>"), function(document, shapes)
		section(document, shapes).time_activation_seconds = seconds
	end, guard)
end

--- The config.toml beside a tap_hold.toml (the loader's).
M.config_path_for = require("tap_hold.engine.loader").config_path_for

--- One change to config.toml [tap_holds], then the engine reload.
--- @param what string For the logs.
--- @param row table The batch operation `{ section, key, value | delete }`.
--- @param guard function|nil Original deferred editor, strict true required.
--- @return boolean True when the change is saved and in force.
local function commit_setting(what, row, guard)
	if not _path then
		Logger.error(LOG, "Tap-hold writer used before init() — '%s' not saved.", what)
		return false
	end
	local path, reload, config = _path, _reload, _config_path
	local content, status, detail = TomlWriter.read_classified(config)
	if status ~= "ok" and status ~= "absent" then
		Logger.error(LOG, "'%s' is unreadable (%s) — '%s' refused.", config, tostring(detail or status), what)
		return false
	end
	if not edit_current(guard) or _path ~= path or _reload ~= reload or _config_path ~= config then return false end
	local called, written, write_err = pcall(TomlWriter.batch_write, config, { row }, nil,
		{ status = status, content = content })
	if not called or written ~= true then
		Logger.error(LOG, "Tap-hold change '%s' was not saved to '%s': %s.", what, config,
			tostring(called and write_err or written))
		return false
	end
	Logger.info(LOG, "Tap-hold change saved: %s.", what)
	local reloaded_called, reloaded = pcall(reload)
	if not reloaded_called or reloaded ~= true then
		Logger.error(LOG, "Tap-hold change '%s' saved but the engine did not reload.", what)
		return false
	end
	return true
end

--- Sets how long a modifier key pressed alone still taps, in milliseconds
--- (config.toml [tap_holds] lone_modifier_tap_max_ms, a manifest row): 0 is the
--- strict tap-hold.
--- @param ms number 0 or a positive whole number of milliseconds.
--- @param guard function|nil Original deferred editor, strict true required.
--- @return boolean
function M.set_lone_tap_max_ms(ms, guard)
	if not pcall(LoneTap.validate, ms) then
		Logger.error(LOG, "set_lone_tap_max_ms: %s is not 0 or a whole number of milliseconds — nothing written.",
			tostring(ms))
		return false
	end
	return commit_setting("lone modifier tap window = " .. tostring(ms) .. " ms",
		Manifest.sparse_operation(ConfigKeys.KEY.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS, ms), guard)
end

--- Sets how long a one-shot Shift waits for its key, in milliseconds
--- (config.toml [tap_holds] sticky_timeout_ms). It has no manifest row: the
--- timing registry's default is written as an absence.
--- @param ms number A positive whole number of milliseconds.
--- @param guard function|nil Original deferred editor, strict true required.
--- @return boolean
function M.set_one_shot_timeout_ms(ms, guard)
	if not require("tap_hold.engine.loader").valid_one_shot_timeout_ms(ms) then
		Logger.error(LOG, "set_one_shot_timeout_ms: %s is not a positive whole number of milliseconds — nothing written.",
			tostring(ms))
		return false
	end
	local row = { section = ConfigKeys.KEY.TAP_HOLDS, key = ConfigKeys.LEAF.STICKY_TIMEOUT_MS }
	if ms == require("tap_hold.engine.loader").ONE_SHOT_TIMEOUT_DEFAULT_MS then row.delete = true else row.value = ms end
	return commit_setting("one-shot timeout = " .. tostring(ms) .. " ms", row, guard)
end

--- Switches the feature on or off (config.toml [tap_holds] enabled, a manifest row).
--- @param enabled boolean
--- @return boolean
function M.set_enabled(enabled)
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "set_enabled: a boolean is required — nothing written.")
		return false
	end
	return commit_setting("feature " .. (enabled and "on" or "off"),
		Manifest.sparse_operation(ConfigKeys.KEY.TAP_HOLDS_ENABLED, enabled))
end

--- Renders the tap-hold scope candidate without writing it: every owned field
--- is cleared and a restore writes the shipped preset explicitly instead of
--- asking the loader to inherit it, so the file says exactly what runs. The
--- manifest rows under tap_holds live in config.toml, published by the same
--- transaction: no row reaches this file. Unknown sections and fields are
--- preserved.
--- @param mode string "recommended" or "clear".
--- @param document table Decoded user document, consumed by this call.
--- @param rows table Rows routed to this file: always empty.
--- @param preset table key id -> fields of the shipped preset.
--- @param shapes table|nil Canonical receipt for the exact source document.
--- @return string candidate Complete file text.
function M.render_scope(mode, document, rows, preset, shapes)
	if mode ~= "recommended" and mode ~= "clear" then error("unknown tap-hold scope mode: " .. tostring(mode), 0) end
	if type(document) ~= "table" or type(rows) ~= "table" or type(preset) ~= "table" then
		error("tap-hold scope rendering requires a document, rows and the preset", 0)
	end
	migrate_document(document, shapes)
	local tap_hold = section(document, shapes)
	Shapes.require_table(tap_hold.keys, shapes, "tap_hold.keys")
	if mode == "recommended" then
		for key_id in pairs(preset) do
			Shapes.require_table(tap_hold.keys and tap_hold.keys[key_id], shapes, "tap_hold.keys." .. key_id)
		end
	end
	tap_hold.inherit_defaults = nil
	-- The recommendation sets no delay: the user's global one goes with the keys'.
	tap_hold.time_activation_seconds = nil
	-- A config.toml leaf a v22 move left here is no setting of this file.
	for _, field in ipairs(CONFIG_OWNED_FIELDS) do tap_hold[field] = nil end
	clear_owned_keys(tap_hold, preset, shapes)
	for _, row in ipairs(rows) do
		error("tap-hold scope row has no tap_hold.toml owner: " .. tostring(row.section) .. "." .. tostring(row.key), 0)
	end
	if mode == "recommended" then
		for key_id, fields in pairs(preset) do
			local entry = key_entry(document, key_id, shapes)
			for field, value in pairs(fields) do entry[field] = value end
		end
	end
	if next(tap_hold) == nil then document.tap_hold = nil end
	return render_document(document, shapes)
end

--- Whether a key's entry holds a setting of the user's: any owned field, unless
--- together they are exactly the shipped preset's (an explicit `enabled = true`
--- is the preset's too). A partial entry is the user's: whether it behaves as
--- the preset depends on inheritance, and the wizard never guesses.
--- @param entry any The key's table in the user's document.
--- @param fields table The key's preset fields.
--- @return boolean
local function customised(entry, fields)
	if type(entry) ~= "table" then return false end
	local owned = false
	for _, field in ipairs(OWNED_KEY_FIELDS) do
		if entry[field] ~= nil then owned = true end
	end
	if not owned then return false end
	for _, field in ipairs(OWNED_KEY_FIELDS) do
		local value, recommended = entry[field], fields[field]
		if field == "enabled" then value, recommended = value ~= false, recommended ~= false end
		if value ~= recommended then return true end
	end
	return false
end

--- Imports Ergopti's recommendation for the given keys into a tap_hold.toml
--- and switches the feature on (config.toml [tap_holds] enabled, beside it):
--- the first-run wizard's
--- Tap-Holds answer. It only adds keys: a key holding the user's own setting
--- refuses the whole import, and every other key, section and field stays as it
--- was. The replaced file is backed up first. The wizard may configure another
--- folder than the running one and restarts the daemon on it, so the file is
--- named by the caller and no engine is reloaded here.
--- @param path string The tap_hold.toml of the folder being configured.
--- @param key_ids table The engine's key ids (KEY_CODES), at least one.
--- @param preset table key id -> fields of the shipped preset (loader.preset_keys).
--- @param config_path string|nil The config.toml the switch is published to,
---   the one beside path by default.
--- @return boolean imported
--- @return string|nil err Why nothing was written.
--- @return string|nil backup The copy of the replaced file, nil for a new one.
function M.import_recommended(path, key_ids, preset, config_path)
	if type(path) ~= "string" or path == "" or type(key_ids) ~= "table" or #key_ids == 0
		or type(preset) ~= "table" then
		return false, "the import needs a file, at least one key and the shipped preset"
	end
	local seen = {}
	for _, key_id in ipairs(key_ids) do
		if type(key_id) ~= "string" or not Engine.KEY_CODES[key_id] then
			return false, "unknown tap-hold key '" .. tostring(key_id) .. "'"
		end
		if type(preset[key_id]) ~= "table" then
			return false, "the shipped preset recommends nothing for '" .. key_id .. "'"
		end
		if seen[key_id] then return false, "'" .. key_id .. "' is imported twice" end
		seen[key_id] = true
	end
	Logger.start(LOG, "Importing %d recommended tap-hold key(s) into '%s'…", #key_ids, path)
	local document, err, text, shapes = read_document(path)
	if not document then
		Logger.error(LOG, "'%s' is %s — the import is refused rather than overwrite it.", path, tostring(err))
		return false, "'" .. path .. "' is " .. tostring(err)
	end
	local tap_hold = document.tap_hold
	local admitted, admission_error = pcall(function()
		Shapes.require_table(tap_hold, shapes, "tap_hold")
		Shapes.require_table(tap_hold and tap_hold.keys, shapes, "tap_hold.keys")
		for _, key_id in ipairs(key_ids) do
			Shapes.require_table(tap_hold and tap_hold.keys and tap_hold.keys[key_id], shapes,
				"tap_hold.keys." .. key_id)
		end
	end)
	if not admitted then
		Logger.error(LOG, "Tap-hold import into '%s' refused: %s.", path, tostring(admission_error))
		return false, tostring(admission_error)
	end
	local migrated, migration_error = pcall(migrate_document, document, shapes)
	if not migrated then
		Logger.error(LOG, "Tap-hold import into '%s' refused: %s.", path, tostring(migration_error))
		return false, tostring(migration_error)
	end
	tap_hold = document.tap_hold
	local keys = type(tap_hold) == "table" and tap_hold.keys or {}
	for _, key_id in ipairs(key_ids) do
		if customised(keys[key_id], preset[key_id]) then
			Logger.error(LOG, "Tap-hold key '%s' of '%s' holds the user's own setting — the import is refused.",
				key_id, path)
			return false, "'" .. key_id .. "' holds the user's own setting"
		end
	end
	local backup = nil
	if text then
		backup = back_up(path, text)
		if not backup then
			Logger.error(LOG, "'%s' could not be backed up — the import is refused.", path)
			return false, "'" .. path .. "' could not be backed up"
		end
	end
	for _, key_id in ipairs(key_ids) do
		local entry = key_entry(document, key_id, shapes)
		for _, field in ipairs(OWNED_KEY_FIELDS) do entry[field] = nil end
		for field, value in pairs(preset[key_id]) do entry[field] = value end
	end
	if not write_document(path, document, shapes, { status = text and "ok" or "absent", content = text }) then
		return false, "'" .. path .. "' could not be written"
	end
	local config = config_path or M.config_path_for(path)
	local switched, switch_err = TomlWriter.batch_write(config,
		{ Manifest.sparse_operation(ConfigKeys.KEY.TAP_HOLDS_ENABLED, true) })
	if switched ~= true then
		Logger.error(LOG, "The tap-hold keys were imported into '%s' but '%s' could not switch them on: %s.",
			path, config, tostring(switch_err))
		return false, "'" .. config .. "' could not be written"
	end
	Logger.success(LOG, "Imported %d recommended tap-hold key(s) into '%s' (backup: %s).",
		#key_ids, path, tostring(backup or "none, the file is new"))
	return true, nil, backup
end

--- Migrates the user's file on disk to the current version, once, at boot: a
--- byte-exact backup first, then one atomic publication of the migrated bytes.
--- The edit is line-preserving (config_migrate.plan_operations, the editor of
--- the config.toml migrations): comments, order and formatting survive, only
--- the retired delay lines, emptied tables, the explicit_delays line and the
--- stamp change. A current or absent file is not written. A file this build
--- cannot version (newer, unreadable stamp, malformed, or whose edit cannot be
--- verified) is left untouched and ERROR logged; every later change to it is
--- refused by the writers.
--- @param path string The user's tap_hold.toml.
--- @return string status "absent", "current", "migrated", "newer", "invalid" or "failed".
--- @return string|nil detail The backup of a migrated file, or why it was refused.
function M.migrate_file(path)
	if type(path) ~= "string" or path == "" then error("tap-hold migration requires a path", 2) end
	Logger.start(LOG, "Checking the tap-hold file version of '%s'…", path)
	local document, err, text, shapes = read_document(path)
	if not document then
		Logger.error(LOG, "'%s' is %s — left untouched, not migrated.", path, tostring(err))
		return "failed", tostring(err)
	end
	if text == nil then
		Logger.success(LOG, "No tap-hold file at '%s' yet; nothing to migrate.", path)
		return "absent"
	end
	local outcome, detail, operations = Migration.file_operations(document, shapes, retired_delays())
	if outcome == "current" then
		Logger.success(LOG, "'%s' is at schema v%s; nothing to migrate.", path, tostring(detail))
		return "current"
	end
	if outcome ~= "migrated" then
		Logger.error(LOG, "'%s' cannot be migrated (%s: %s) — left untouched and never written.",
			path, outcome, tostring(detail))
		return outcome, tostring(detail)
	end
	local plan = require("settings.engine.migration.migrate").plan_operations(text, operations)
	if plan.outcome ~= "migrated" then
		Logger.error(LOG, "'%s' cannot be edited in place (%s) — left untouched and never written.",
			path, tostring(plan.detail or plan.outcome))
		return "failed", tostring(plan.detail or plan.outcome)
	end
	local backup = back_up(path, text)
	if not backup then
		Logger.error(LOG, "'%s' could not be backed up — not migrated.", path)
		return "failed", "'" .. path .. "' could not be backed up"
	end
	local published, publish_err = TomlWriter.publish_if_unchanged(path, plan.candidate, nil,
		{ status = "ok", content = text })
	if published ~= true then
		Logger.error(LOG, "'%s' could not be published (%s) — not migrated.", path, tostring(publish_err))
		return "failed", "'" .. path .. "' could not be written"
	end
	Logger.success(LOG, "Migrated '%s' from schema v%s to v%s; backup at '%s'.", path, tostring(detail),
		tostring(Migration.registry().current), backup)
	return "migrated", backup
end

--- Whether the user's file names this key.
--- @param key_id string
--- @return boolean
function M.is_overridden(key_id)
	if not _path then return false end
	local document, _, _, shapes = read_document(_path)
	return type(document) == "table" and Shapes.is_table(document.tap_hold, shapes)
		and Shapes.is_table(document.tap_hold.keys, shapes) and Shapes.is_table(document.tap_hold.keys[key_id], shapes)
end

--- Test seam: forgets the initialisation.
function M._reset_for_test()
	_path, _reload, _is_tap_action, _canonical_hold, _retired = nil, nil, nil, nil, nil
	_config_path = nil
end

return M
