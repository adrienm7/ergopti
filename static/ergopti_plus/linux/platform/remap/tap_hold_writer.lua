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
---    clears both. The scope restore and clear render through render_scope()
---    and publish through infra/tap_hold_scope.lua, never through commit().
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
--- 5. The layer comes with its key: a hold that enters Ergopti's recommended
---    layer creates the folder's layers.toml from it when there is none
---    (keymap.layer_preset), before the engine reloads. A key set to hold
---    the navigation layer in a folder without that file entered a layer
---    that binds no key. An existing file is the user's and stays; a change
---    that is not saved removes only the file it created. The folder is
---    named by init(): a writer bound to none touches no layer file.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local TomlCodec = require("toml_codec")
local TomlWriter = require("toml_codec.writer")
local BasicString = require("toml_codec.basic_string")
local Engine = require("platform.remap.tap_hold_engine")
local Manifest = require("infra.manifest_reader")
local LayerPreset = require("keymap.layer_preset")

local LOG = "platform.remap.tap_hold_writer"

--- The user file's name in the configuration folder.
M.FILE_NAME = "tap_hold.toml"

-- The Windows loader's bound for time_activation_seconds.
local MAX_THRESHOLD_SECONDS = 10

-- The per-key fields whose runtime meaning belongs to this writer.
local OWNED_KEY_FIELDS = { "tap_action", "hold_modifier", "hold_layer", "enabled", "time_activation_seconds" }

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
local _canonical_hold = nil
local _layers = nil          -- { shared_root, config_dir, file_adapter } a layer hold imports into, or nil.
local _backup_sequence = 0    -- Keeps the wizard import's backups unique.


-- =========================================
-- =========================================
-- ======= 2/ Reading and writing ==========
-- =========================================
-- =========================================

--- Reads a tap_hold.toml; an absent file is an empty document.
--- @param path string
--- @return table|nil document, string|nil err, string|nil text The file's bytes.
local function read_document(path)
	local text, status, detail = TomlWriter.read_classified(path)
	if status == "absent" then return {} end
	if status ~= "ok" then return nil, detail end
	local parsed = TomlCodec.decode(text)
	if type(parsed) ~= "table" then return nil, "malformed" end
	return parsed, nil, text
end

--- Copies a file's bytes to a new backup beside it, then reads them back.
--- @param path string The file being replaced.
--- @param text string Its bytes.
--- @return string|nil backup The backup path, nil when it could not be made.
local function back_up(path, text)
	_backup_sequence = _backup_sequence + 1
	local backup = string.format("%s.tap_holds-%s-%d.bak", path, os.date("%Y%m%d-%H%M%S"), _backup_sequence)
	local existing = io.open(backup, "r")
	if existing then
		existing:close()
		return nil
	end
	local fh = io.open(backup, "w")
	if not fh then return nil end
	fh:write(text)
	fh:close()
	local check = io.open(backup, "r")
	local copied = check and check:read("*a")
	if check then check:close() end
	return copied == text and backup or nil
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

--- The file's complete text for `document`, as every tray change writes it.
--- @param document table
--- @return string
local function render_document(document)
	local out = {}
	for _, line in ipairs(HEADER) do out[#out + 1] = line end
	encode_table(out, document, "")
	return table.concat(out, "\n") .. "\n"
end

--- Replaces a tap_hold.toml with `document`.
--- @param path string
--- @param document table
--- @return boolean
local function write_document(path, document)
	local text = render_document(document)
	local tmp = path .. ".tmp"
	local fh, err = io.open(tmp, "w")
	if not fh then
		Logger.error(LOG, "Cannot write '%s' (%s) — the change was not saved.", tmp, tostring(err))
		return false
	end
	local write_ok, written, write_err = pcall(fh.write, fh, text)
	local close_ok, closed, close_err = pcall(fh.close, fh)
	-- Lua 5.1 returns true from file:write; later Lua returns that same file.
	local write_ack = write_ok and (written == true or written == fh)
	if not write_ack or not close_ok or closed ~= true then
		local removed, remove_err = os.remove(tmp)
		if not removed then
			Logger.error(LOG, "Cannot remove refused staging file '%s' (%s).", tmp, tostring(remove_err))
		end
		local detail = not write_ok and written or (not write_ack and write_err)
			or (not close_ok and closed) or close_err or "write or close acknowledgement refused"
		Logger.error(LOG, "Cannot complete staging file '%s' (%s) — the change was not saved.", tmp, tostring(detail))
		return false
	end
	local ok, rename_err = os.rename(tmp, path)
	if not ok then
		os.remove(tmp)
		Logger.error(LOG, "Cannot replace '%s' (%s) — the change was not saved.", path, tostring(rename_err))
		return false
	end
	return true
end

--- Reads, changes, writes and reloads: one tray change.
--- @param what string For the logs.
--- @param mutate function(document) Changes the decoded document in place.
--- @return boolean True when the change is saved and in force.
--- @return boolean saved True once the file holds the change, reloaded or not.
local function save_and_reload(what, mutate)
	if not _path then
		Logger.error(LOG, "Tap-hold writer used before init() — '%s' not saved.", what)
		return false, false
	end
	local document, err = read_document(_path)
	if not document then
		Logger.error(LOG, "'%s' is %s — '%s' refused rather than overwrite it.", _path, tostring(err), what)
		return false, false
	end
	mutate(document)
	if not write_document(_path, document) then return false, false end
	Logger.info(LOG, "Tap-hold change saved: %s.", what)
	if not _reload() then
		Logger.error(LOG, "Tap-hold change '%s' saved but the engine did not reload.", what)
		return false, true
	end
	return true, true
end

--- One tray change, as the public setters report it.
--- @param what string For the logs.
--- @param mutate function(document) Changes the decoded document in place.
--- @return boolean True when the change is saved and in force.
local function commit(what, mutate)
	local in_force = save_and_reload(what, mutate)
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

--- Removes only fields whose runtime meaning belongs to this writer, on every
--- key this engine knows and every key of the shipped preset.
--- @param tap_hold table
--- @param preset table key id -> fields of the shipped preset.
local function clear_owned_keys(tap_hold, preset)
	if tap_hold.keys == nil then return end
	if type(tap_hold.keys) ~= "table" then error("[tap_hold] keys is not a table", 0) end
	local owned = {}
	for key_id in pairs(Engine.KEY_CODES) do owned[key_id] = true end
	for key_id in pairs(preset) do owned[key_id] = true end
	for key_id in pairs(owned) do
		local entry = tap_hold.keys[key_id]
		if type(entry) == "table" then
			for _, field in ipairs(OWNED_KEY_FIELDS) do entry[field] = nil end
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
--- @param opts table { path, reload() -> boolean, is_tap_action(id) -> boolean,
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
	_path = opts.path
	_reload = opts.reload
	_is_tap_action = opts.is_tap_action
	_canonical_hold = opts.canonical_hold
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
	local layer, layer_err = import_layer(kind, canonical)
	if not layer then
		Logger.error(LOG, "set_hold: the recommended navigation layer cannot be imported (%s) — nothing written.",
			tostring(layer_err))
		return false
	end
	local in_force, saved = save_and_reload(key_id .. " hold = " .. kind .. ":" .. canonical, function(document)
		local entry = key_entry(document, key_id)
		entry.hold_modifier, entry.hold_layer, entry.enabled = nil, nil, nil
		if kind == "layer" then
			entry.hold_layer = canonical
		elseif kind == "modifier" then
			entry.hold_modifier = canonical
		else
			-- Empty, not absent: absent would inherit the default's hold.
			entry.hold_modifier = ""
		end
	end)
	-- A saved key keeps the layer it enters, even when the reload failed.
	if not saved then undo_layer(layer) end
	return in_force
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

--- Renders the tap-hold scope candidate without writing it: every owned field
--- is cleared, the manifest's master rows are applied, and a restore writes the
--- shipped preset explicitly instead of asking the loader to inherit it, so the
--- file says exactly what runs. Unknown sections and fields are preserved.
--- @param mode string "recommended" or "clear".
--- @param document table Decoded user document, consumed by this call.
--- @param rows table Manifest rows under tap_holds, routed by the transaction.
--- @param preset table key id -> fields of the shipped preset.
--- @return string candidate Complete file text.
function M.render_scope(mode, document, rows, preset)
	if mode ~= "recommended" and mode ~= "clear" then error("unknown tap-hold scope mode: " .. tostring(mode), 0) end
	if type(document) ~= "table" or type(rows) ~= "table" or type(preset) ~= "table" then
		error("tap-hold scope rendering requires a document, rows and the preset", 0)
	end
	if document.tap_hold ~= nil and type(document.tap_hold) ~= "table" then error("[tap_hold] is not a table", 0) end
	local tap_hold = section(document)
	tap_hold.inherit_defaults = nil
	clear_owned_keys(tap_hold, preset)
	for _, row in ipairs(rows) do
		if row.section ~= "tap_holds" or row.key ~= "enabled" then
			error("tap-hold scope row has no tap_hold.toml owner: " .. tostring(row.section) .. "." .. tostring(row.key), 0)
		end
		if row.delete then tap_hold.enabled = nil else tap_hold.enabled = row.value end
	end
	if mode == "recommended" then
		for key_id, fields in pairs(preset) do
			local entry = key_entry(document, key_id)
			for field, value in pairs(fields) do entry[field] = value end
		end
	end
	if next(tap_hold) == nil then document.tap_hold = nil end
	return render_document(document)
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
--- and switches the feature on ([tap_hold] enabled): the first-run wizard's
--- Tap-Holds answer. It only adds keys: a key holding the user's own setting
--- refuses the whole import, and every other key, section and field stays as it
--- was. The replaced file is backed up first. The wizard may configure another
--- folder than the running one and restarts the daemon on it, so the file is
--- named by the caller and no engine is reloaded here.
--- @param path string The tap_hold.toml of the folder being configured.
--- @param key_ids table The engine's key ids (KEY_CODES), at least one.
--- @param preset table key id -> fields of the shipped preset (loader.preset_keys).
--- @return boolean imported
--- @return string|nil err Why nothing was written.
--- @return string|nil backup The copy of the replaced file, nil for a new one.
function M.import_recommended(path, key_ids, preset)
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
	local document, err, text = read_document(path)
	if not document then
		Logger.error(LOG, "'%s' is %s — the import is refused rather than overwrite it.", path, tostring(err))
		return false, "'" .. path .. "' is " .. tostring(err)
	end
	-- A scalar where a table belongs is the user's text, not ours to replace.
	local tap_hold = document.tap_hold
	if (tap_hold ~= nil and type(tap_hold) ~= "table")
		or (type(tap_hold) == "table" and tap_hold.keys ~= nil and type(tap_hold.keys) ~= "table") then
		Logger.error(LOG, "[tap_hold] of '%s' is not a table of keys — the import is refused.", path)
		return false, "[tap_hold] of '" .. path .. "' is not a table of keys"
	end
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
	section(document).enabled = true
	for _, key_id in ipairs(key_ids) do
		local entry = key_entry(document, key_id)
		for _, field in ipairs(OWNED_KEY_FIELDS) do entry[field] = nil end
		for field, value in pairs(preset[key_id]) do entry[field] = value end
	end
	if not write_document(path, document) then
		return false, "'" .. path .. "' could not be written"
	end
	Logger.success(LOG, "Imported %d recommended tap-hold key(s) into '%s' (backup: %s).",
		#key_ids, path, tostring(backup or "none, the file is new"))
	return true, nil, backup
end

--- Whether the user's file names this key.
--- @param key_id string
--- @return boolean
function M.is_overridden(key_id)
	if not _path then return false end
	local document = read_document(_path)
	return type(document) == "table" and type(document.tap_hold) == "table"
		and type(document.tap_hold.keys) == "table" and type(document.tap_hold.keys[key_id]) == "table"
end

--- Test seam: forgets the initialisation.
function M._reset_for_test()
	_path, _reload, _is_tap_action, _canonical_hold = nil, nil, nil, nil
end

return M
