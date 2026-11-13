--- platform/remap/tap_hold_file.lua

--- ==============================================================================
--- MODULE: Shared Tap-Hold File (macOS)
--- DESCRIPTION:
--- Binds the shared tap_hold.toml (_shared/tap_hold/data/SCHEMA.md) to the Karabiner
--- model keyboard/engine/runtime/config.lua merges: a read decodes the file, migrates
--- it in memory (_shared/tap_hold/data/migrations.toml) and translates it with
--- _shared/tap_hold/engine/shared_file.lua; a save writes back only the leaves the
--- model changed, stamped with the current version. The switch, the timings and
--- the key combinations are config.toml rows (read_config, config_rows). It also
--- carries an old config_karabiner.toml over once (import_legacy), before the
--- boot versions config.toml, whose v22 step moves those rows out of it.
---
--- FEATURES & RATIONALE:
--- 1. One home on every OS: macOS reads and writes the file Linux and Windows
---    read, under the catalogue's key ids, so a configuration carried between
---    machines works as it did (Cmd versus Ctrl aside).
--- 2. Shipped data is read once and validated: a context that cannot place a
---    key or a combination raises at the first read, never guesses.
--- 3. A file saved by a newer build, or with an unusable version stamp, is read
---    as it is and never written, as on Linux.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local Paths = require("core.fs.engine.paths")
local TomlCodec = require("core.text.engine.toml.codec")
local JsonCodec = require("core.fs.adapters.json_codec")
local SharedFile = require("tap_hold.engine.shared_file")
local Migrate = require("tap_hold.engine.migrate")
local KeyCatalog = require("tap_hold.engine.key_catalog")
local Outdated = require("settings.engine.migration.outdated")

local LOG = "karabiner"

-- The macOS column of the key catalogue, and of the legacy imports.
local PLATFORM = "hs"

local _DATA_DIR = (require("core.fs.engine.native_path").directory_prefix(debug.getinfo(1, "S").source:sub(2)) or "./") .. "data/"

local _context, _registry, _retired = nil, nil, nil





-- ===============================
-- ===============================
-- ======= 1/ Shipped data =======
-- ===============================
-- ===============================

--- Reads a whole shipped file, raising when it is missing.
--- @param path string
--- @return string
local function read_shipped(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("cannot read shipped tap-hold data '" .. tostring(path) .. "': " .. tostring(err), 0) end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- Decodes a shipped TOML file, raising when it does not parse.
--- @param path string
--- @return table
local function shipped_toml(path)
	local decoded = TomlCodec.decode(read_shipped(path))
	if type(decoded) ~= "table" then error("shipped tap-hold data does not parse: " .. tostring(path), 0) end
	return decoded
end

--- Decodes a shipped JSON file, raising when it does not parse.
--- @param path string
--- @return table
local function shipped_json(path)
	local decoded = JsonCodec.decode(read_shipped(path))
	if type(decoded) ~= "table" then error("shipped tap-hold data does not parse: " .. tostring(path), 0) end
	return decoded
end

--- The translation context, built once from the shipped data.
--- @return table See shared_file.hs_context.
function M.context()
	if _context == nil then
		local defaults = shipped_toml(Paths.shared("tap_hold/data/defaults.toml"))
		local picker = defaults.tap_hold and defaults.tap_hold.hold_picker or {}
		local aliases = {}
		for _, field in ipairs({ "modifier_aliases", "left_modifier_aliases" }) do
			for alias, name in pairs(type(picker[field]) == "table" and picker[field] or {}) do aliases[alias] = name end
		end
		_retired = KeyCatalog.retired_delays(defaults)
		local catalogue_ids = {}
		for _, entry in ipairs(defaults.tap_hold.catalog.keys) do catalogue_ids[#catalogue_ids + 1] = entry.id end
		_context = SharedFile.hs_context(SharedFile.parse_spec(shipped_toml(Paths.shared("tap_hold/data/shared_file.toml"))), {
			catalogue = KeyCatalog.for_platform(defaults, PLATFORM),
			catalogue_ids = catalogue_ids,
			tap_hold_keys = shipped_json(_DATA_DIR .. "tap_hold_keys.json"),
			mod_combos = shipped_json(_DATA_DIR .. "mod_combos.json"),
			actions = shipped_json(_DATA_DIR .. "actions.json"),
			aliases = aliases,
			spellings = require("_generated.action_catalogue").tap_hold_spellings,
		})
	end
	return _context
end

--- The per-key delays earlier builds shipped, under the catalogue ids.
--- @return table See key_catalog.retired_delays.
function M.retired_delays()
	M.context()
	return _retired
end

--- The validated migration registry, read once.
--- @return table See migrate.parse_registry.
function M.registry()
	if _registry == nil then _registry = Migrate.load_registry(Paths.shared("tap_hold/data/migrations.toml")) end
	return _registry
end

--- The shared pair id of a macOS key combination.
--- @param combo_id string
--- @return string
function M.pair_of_combo(combo_id)
	local pair = M.context().pair_of_combo[combo_id]
	if not pair then error("macOS key combination '" .. tostring(combo_id) .. "' has no pair id", 0) end
	return pair
end

--- The file path of a Karabiner model path (see shared_file.file_segments).
--- @param segments table
--- @return table
function M.file_segments(segments)
	return SharedFile.file_segments(segments, M.context())
end

--- The macOS key combination of a shared pair id, nil when macOS has none.
--- @param pair string
--- @return string|nil
function M.combo_of_pair(pair)
	return M.context().combo_of_pair[pair]
end





-- ================================
-- ================================
-- ======= 2/ Read and save =======
-- ================================
-- ================================

--- The array test of one decoded document.
local function table_test(shapes)
	return function(value) return type(value) == "table" and not (shapes and shapes.arrays[value]) end
end

--- A model copy for the save's comparison: the tables are copied, arrays and
--- the sections the model does not own stay the same references.
local function snapshot(model, is_table)
	local function copy(value)
		if not is_table(value) then return value end
		local out = {}
		for key, child in pairs(value) do out[key] = copy(child) end
		return out
	end
	local out = {}
	for key, value in pairs(model) do out[key] = value end
	out.tap_holds, out.mod_combos = copy(model.tap_holds), copy(model.mod_combos)
	return out
end

--- Translates a decoded tap_hold.toml for the Karabiner model.
--- @param document table Decoded shared file, migrated in place.
--- @param shapes table|nil Its shape receipt.
--- @param path string The file, named by warnings.
--- @return table file `{ document, shapes, model, model_shapes, before, writable, detail }`.
function M.read(document, shapes, path)
	local is_table = table_test(shapes)
	local outcome, detail = Migrate.apply(document, M.registry(), M.retired_delays(), is_table)
	local writable = outcome == "migrated" or outcome == "current"
	if outcome == "newer" then
		Logger.warn(LOG, "'%s' was saved by a newer build (schema v%s); it is read as it is and never written.",
			path, tostring(detail))
	elseif outcome == "invalid" then
		Outdated.report_in_file(path, { Migrate.META_SECTION, Migrate.VERSION_KEY },
			tostring(detail) .. "; the file is read as it is and never written", Logger)
	end
	local model, notes = SharedFile.to_karabiner(document, M.context(), is_table)
	for _, note in ipairs(notes) do
		local segments = {}
		for segment in note.path:gmatch("[^%.]+") do segments[#segments + 1] = segment end
		Outdated.report_in_file(path, segments, note.detail, Logger)
	end
	local model_shapes = shapes and { arrays = shapes.arrays, numbers = {}, strings = {}, document = model } or nil
	return { document = document, shapes = shapes, model = model, model_shapes = model_shapes,
		before = snapshot(model, is_table), writable = writable, detail = outcome }
end

--- The config.toml that holds the manifest's tap-hold rows: the file beside
--- tap_hold.toml (settings/engine/paths.lua places ConfigTomlPath and
--- TapHoldConfigPath in the same driver folder; the macOS boot checks it).
--- @param tap_hold_path string The tap_hold.toml path.
--- @return string
function M.config_toml_path_for(tap_hold_path)
	return (require("core.fs.engine.native_path").directory_prefix(tap_hold_path) or "") .. "config.toml"
end

--- The config-owned part of the Karabiner model from a decoded config.toml
--- (see shared_file.config_to_karabiner); each leaf macOS cannot run is warned
--- once, naming config.toml.
--- @param document table Decoded config.toml; {} for an absent file.
--- @param shapes table|nil Its shape receipt.
--- @param path string The config.toml, named by warnings.
--- @return table part `{ tap_holds?, mod_combos? }`.
function M.read_config(document, shapes, path)
	local part, notes = SharedFile.config_to_karabiner(document, M.context(), table_test(shapes))
	for _, note in ipairs(notes) do
		local segments = {}
		for segment in note.path:gmatch("[^%.]+") do segments[#segments + 1] = segment end
		Outdated.report_in_file(path, segments, note.detail, Logger)
	end
	return part
end

--- The config.toml rows a save writes (see shared_file.config_rows).
--- @param before table What M.read_config() returned for the config.toml the save read.
--- @param model table The model the save produced.
--- @param shapes table|nil The shape receipt of the model's arrays.
--- @return table rows
function M.config_rows(before, model, shapes)
	return SharedFile.config_rows(before, model, M.context(), table_test(shapes))
end

--- Stamps a document with the current version.
local function stamp(document)
	if type(document[Migrate.META_SECTION]) ~= "table" then document[Migrate.META_SECTION] = {} end
	document[Migrate.META_SECTION][Migrate.VERSION_KEY] = M.registry().current
end

--- Whether two leaf values are the same, numbers by kind and sign too.
local function same_value(left, right)
	if type(left) == "number" and type(right) == "number" then
		local kind = math.type or function() return nil end
		return left == right and kind(left) == kind(right) and (left ~= 0 or 1 / left == 1 / right)
	end
	if type(left) ~= "table" or type(right) ~= "table" then return left == right end
	for key, value in pairs(left) do if not same_value(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end

--- The line edits (config_migrate record operations) that turn the decoded
--- source into the document a save produced: a changed leaf is deleted then
--- set, a table gone is deleted whole. Nil when one cannot be spelled so: a
--- leaf at the root, or an array that holds tables.
--- @param old table Decoded source.
--- @param new table The document to publish.
--- @param old_table function(value) -> boolean For the source.
--- @param new_table function(value) -> boolean For the document.
--- @return table|nil ops
local function edit_operations(old, new, old_table, new_table)
	local deletes, sets = {}, {}
	local function settable(value)
		if type(value) ~= "table" then return true end
		for _, item in pairs(value) do if type(item) == "table" then return false end end
		return true
	end
	local function walk(section, left, right)
		local keys = {}
		for key in pairs(left or {}) do keys[key] = true end
		for key in pairs(right or {}) do keys[key] = true end
		for key in pairs(keys) do
			local o, n = left and left[key], right and right[key]
			local path = section and (section .. "." .. key) or key
			local o_table, n_table = o ~= nil and old_table(o), n ~= nil and new_table(n)
			if o_table and n_table then
				if not walk(path, o, n) then return false end
			elseif not (o ~= nil and n ~= nil and not o_table and not n_table and same_value(o, n)) then
				if o_table then
					deletes[#deletes + 1] = { op = "delete", section = path }
				elseif o ~= nil then
					if section == nil then return false end
					deletes[#deletes + 1] = { op = "delete", section = section, key = key }
				end
				if n_table then
					if not walk(path, nil, n) then return false end
				elseif n ~= nil then
					if section == nil or not settable(n) then return false end
					sets[#sets + 1] = { op = "set_if_absent", section = section, key = key, value = n }
				end
			end
		end
		return true
	end
	if not walk(nil, old, new) then return nil end
	for _, op in ipairs(sets) do deletes[#deletes + 1] = op end
	return deletes
end

--- The source edited line by line into `document`, nil when the edit cannot be
--- spelled or does not read back as the document.
--- @param source string The exact bytes the save read.
--- @param document table The document to publish.
--- @param shapes table|nil Its shape receipt.
--- @return string|nil text
local function edited_source(source, document, shapes)
	local decoded_ok, old, old_shapes = pcall(TomlCodec.decode_with_shapes, source)
	if not decoded_ok or type(old) ~= "table" then return nil end
	local ops = edit_operations(old, document, table_test(old_shapes), table_test(shapes))
	if ops == nil then return nil end
	if #ops == 0 then return source end
	local plan = require("settings.engine.migration.migrate").plan_operations(source, ops)
	if plan.outcome ~= "migrated" and plan.outcome ~= "current" then return nil end
	local reread_ok, reread = pcall(TomlCodec.decode, plan.candidate)
	if not reread_ok or not same_value(reread, document) then return nil end
	return plan.candidate
end

--- The text a save publishes. Over a file it read, the save edits its exact
--- bytes line by line, so comments, order and another driver's spelling stay;
--- an edit that cannot be spelled so re-renders the file, and says so.
--- @param file table|nil What M.read() returned for the source, with
---   `source_text` its exact bytes; nil when the save starts from no file
---   (absent, explicit reset or backed-up repair).
--- @param model table The model the save produced.
--- @return string text
function M.encode(file, model)
	if file == nil then
		local document = SharedFile.new_file(model, M.context(), table_test(nil))
		stamp(document)
		return TomlCodec.encode(document)
	end
	if not file.writable then
		error("the tap-hold file was saved by a newer build or carries an unusable version (" .. tostring(file.detail) .. ")", 0)
	end
	SharedFile.apply_karabiner(file.document, file.before, model, M.context(), table_test(file.shapes))
	stamp(file.document)
	if type(file.source_text) == "string" then
		local edited = edited_source(file.source_text, file.document, file.shapes)
		if edited then return edited end
		Logger.warn(LOG, "The tap-hold change cannot be written line by line; the file is rewritten whole and its comments are not kept.")
	end
	if file.shapes then return TomlCodec.encode_with_shapes(file.document, file.shapes) end
	return TomlCodec.encode(file.document)
end

--- The text an explicit reset publishes over a file that parses: every leaf
--- macOS owns is the model's, every other driver's setting stays, with the
--- spelling of the reset's own read of the source.
--- @param document table Decoded source, edited in place.
--- @param shapes table The receipt of that same read.
--- @param model table The model the reset produced.
--- @return string text
function M.encode_reset(document, shapes, model)
	local is_table = table_test(shapes)
	local outcome, detail = Migrate.apply(document, M.registry(), M.retired_delays(), is_table)
	if outcome == "newer" or outcome == "invalid" then
		error("the tap-hold file was saved by a newer build or carries an unusable version (" .. tostring(detail) .. ")", 0)
	end
	SharedFile.drop_karabiner_owned(document, M.context(), is_table)
	SharedFile.apply_karabiner(document, {}, model, M.context(), is_table)
	stamp(document)
	return TomlCodec.encode_with_shapes(document, shapes)
end





-- ===========================
-- ===========================
-- ======= 3/ Old file =======
-- ===========================
-- ===========================

--- Carries an old config_karabiner.toml over into tap_hold.toml, once: only
--- while tap_hold.toml does not exist. The old file is renamed with the
--- registry's suffix after the new one is published, never deleted.
--- @param target string The tap_hold.toml path.
--- @param file_system table The FileSystem port (read_with_status, write_if_unchanged).
--- @return boolean ok False when the old file exists but cannot be carried over.
--- @return string outcome "imported", "none", "kept" (both files exist) or the refusal.
function M.import_legacy(target, file_system)
	local spec = M.registry().legacy_imports[PLATFORM]
	assert(spec and spec.translate == "karabiner", "the macOS legacy import is not declared")
	local legacy = (require("core.fs.engine.native_path").directory_prefix(target) or "") .. spec.source
	local raw, status = file_system.read_with_status(legacy)
	if status == "absent" then return true, "none" end
	if status ~= "ok" then
		Logger.error(LOG, "Cannot read the old '%s' — it is not carried over.", legacy)
		return false, "unreadable"
	end
	local _, target_status = file_system.read_with_status(target)
	if target_status ~= "absent" then
		Logger.warn(LOG, "Both '%s' and the old '%s' exist: the old one is left as it is and not read.", target, legacy)
		return true, "kept"
	end
	local ok, model, shapes = pcall(TomlCodec.decode_with_shapes, raw)
	if not ok or type(model) ~= "table" then
		Logger.error(LOG, "Cannot parse the old '%s' as TOML — it is not carried over; repair or remove it.", legacy)
		return false, "unparseable"
	end
	local built, document = pcall(SharedFile.from_karabiner, model, M.context(), table_test(shapes))
	if not built then
		Logger.error(LOG, "The old '%s' cannot be carried over: %s.", legacy, tostring(document))
		return false, "untranslatable"
	end
	stamp(document)
	-- The old file's receipts are keyed by table, so the sections carried by
	-- reference keep their arrays and their spelling.
	local text = TomlCodec.encode_with_shapes(document, { arrays = shapes.arrays, numbers = shapes.numbers,
		strings = shapes.strings, document = document })
	local written = file_system.write_if_unchanged(target, text, { status = "absent" })
	if written ~= true then
		Logger.error(LOG, "Cannot publish '%s' from the old '%s' — nothing was carried over.", target, legacy)
		return false, "unpublished"
	end
	local renamed, rename_err = os.rename(legacy, legacy .. spec.retired_suffix)
	if not renamed then
		Logger.error(LOG, "'%s' was carried over into '%s' but could not be renamed (%s); it is no longer read.",
			legacy, target, tostring(rename_err))
	end
	Logger.info(LOG, "Carried the old '%s' over into '%s'.", legacy, target)
	return true, "imported"
end

--- Test seam: forgets the cached shipped data.
function M._reset_for_test()
	_context, _registry, _retired = nil, nil, nil
end

return M
