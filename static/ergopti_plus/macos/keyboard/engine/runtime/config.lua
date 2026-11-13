--- keyboard/engine/runtime/config.lua

--- ==============================================================================
--- MODULE: Karabiner Config Loader and Persistence
--- DESCRIPTION:
--- Handles all data loading and user configuration persistence for the
--- Karabiner bridge: JSON data files (actions, keys, combos), default state
--- construction, and reading/writing the shared tap_hold.toml (the keys, the
--- global delay, the Karabiner integration) and the config.toml beside it (the
--- manifest rows: the Tap-Holds switch, the one-shot and lone-tap timings and
--- the key combinations, maintainer decision of 2026-11-11) through
--- platform/remap/tap_hold_file.lua, which translates both to and from the
--- Karabiner model this module merges (the layout config_karabiner.toml had).
---
--- FEATURES & RATIONALE:
--- 1. Driver-Local Data Files: keyboard/data/ hosts actions.json,
---    tap_hold_keys.json and mod_combos.json — single source of truth for
---    available actions and keys, loaded once at startup and on every layout change.
--- 2. Layout-Aware Actions: Actions with a "logical_char" field are resolved
---    to a physical key_code via modules.keymap.layout at load time, so the KE config
---    always references the correct physical key regardless of the OS layout.
--- 3. Sparse Persistence: save_user_config() writes only non-neutral leaves
---    and preserves every field it does not own; load_user_config() reads an
---    absent table, key, slot or timing as its neutral value and upgrades the
---    legacy bare-string combo shape.
--- 4. Corruption Safety: an unparseable tap_hold.toml is never silently
---    replaced. The read path falls back to defaults without touching the file
---    and the write path refuses to publish over it, so the user keeps a file
---    they can still repair by hand. Only an explicit reset overrides that.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("core.logger.engine.logger")
local Layout = require("layouts.engine.layout")
local Paths  = require("core.fs.engine.paths")
local i18n   = require("core.i18n.engine.i18n")
local KeyNames = require("platform.input.keycodes.key_names")
local StickyLabel = require("shortcuts.engine.actions.sticky_label")
local FileSystem = require("core.fs.adapters.file_system")
local JsonCodec  = require("core.fs.adapters.json_codec")

local Defaults = require("keyboard.engine.runtime.defaults")
local ActionCatalogue = require("keyboard.engine.runtime.action_catalogue")
local Manifest = require("menu.engine.manifest_reader")
local OutdatedEntries = require("settings.engine.migration.outdated")
local KePaths = require("keyboard.adapters.karabiner.ke_paths")
local TableUtil = require("core.text.engine.table_util")
local ConfigKeys = require("settings.engine.keys")
local TapHoldFile = require("platform.remap.tap_hold_file")
-- Resolved at use, as before: the shared writer binds its native admission when loaded.
local function writer() return require("core.text.engine.toml_codec.writer") end
-- Declared here, above the readers below: section 1 declares its own TomlCodec later.
local ConfigCodec = require("core.text.engine.toml.codec")

local LOG = "karabiner"

--- Hands a published config.toml to the preferences owner. The menus' scopes
--- check that config.toml still holds the bytes the preferences loaded, so a
--- remap save that rewrote its rows (the tap-hold switch, timings and
--- `[mod_combos]`) must move that acknowledged source along, or the next scope
--- of a global restore refuses. A path the preferences never loaded is not
--- theirs to follow.
--- @param path string The config.toml path.
--- @param previous table Exact classified bytes the publication replaced.
--- @param content string Published bytes.
local function adopt_config_publication(path, previous, content)
	local Preferences = require("settings.engine.preferences.preferences")
	if Preferences.source_snapshot(path) == nil then return end
	if Preferences.replace_source(path, previous, { status = "ok", content = content }) ~= true then
		Logger.warn(LOG, "The preferences did not adopt the tap-hold rows written to '%s'.", path)
	end
end

--- The config.toml that holds the manifest's tap-hold rows, beside tap_hold.toml
--- (platform/remap/tap_hold_file.lua owns the rule).
--- @param user_config_path string The tap_hold.toml path.
--- @return string
function M.config_toml_path_for(user_config_path)
	return TapHoldFile.config_toml_path_for(user_config_path)
end

-- The model leaves under [tap_holds] that config.toml keeps; every [mod_combos]
-- leaf is config.toml's too.
local CONFIG_TAP_HOLD_LEAVES = { enabled = true, sticky_timeout_ms = true, lone_modifier_tap_max_ms = true }

--- Whether a model path names a config.toml row.
--- @param segments table Model path segments.
--- @return boolean
local function config_owned(segments)
	return segments[1] == ConfigKeys.KEY.MOD_COMBOS
		or (segments[1] == ConfigKeys.KEY.TAP_HOLDS and CONFIG_TAP_HOLD_LEAVES[segments[2]] == true)
end

-- Outdated entries are named where the user finds them: the merge below works
-- on the Karabiner model, the files hold the shared layout and config.toml.
local Outdated = {
	report_in_file = function(path, segments, detail, logger)
		if config_owned(segments) then
			local file_segments = segments[1] == ConfigKeys.KEY.MOD_COMBOS and TapHoldFile.file_segments(segments) or segments
			return OutdatedEntries.report_in_file(M.config_toml_path_for(path), file_segments, detail, logger)
		end
		return OutdatedEntries.report_in_file(path, TapHoldFile.file_segments(segments), detail, logger)
	end,
}

--- One shape receipt for a model merged from tap_hold.toml and config.toml.
--- @param left table|nil
--- @param right table|nil
--- @return table|nil
local function merged_shapes(left, right)
	if left == nil and right == nil then return nil end
	local arrays = {}
	for _, receipt in ipairs({ left or {}, right or {} }) do
		for value, flag in pairs(receipt.arrays or {}) do arrays[value] = flag end
	end
	return { arrays = arrays, numbers = left and left.numbers or {}, strings = left and left.strings or {},
		document = left and left.document or nil }
end

--- Reads the config.toml beside tap_hold.toml for its tap-hold rows. A module
--- field, as _load_toml_file is, so a test can state both files' reads.
--- @param user_config_path string The tap_hold.toml path.
--- @return table|nil part What TapHoldFile.read_config() returns; nil when unsafe.
--- @return table source `{ path, status, content? }`, the exact same-read bytes.
--- @return table|nil shapes The shape receipt of config.toml.
function M._read_config_part(user_config_path)
	local path = M.config_toml_path_for(user_config_path)
	local raw, status = FileSystem.read_with_status(path)
	local source = { path = path, status = status, content = status == "ok" and raw or nil }
	if status == "absent" then return {}, source, nil end
	if status ~= "ok" then
		Logger.error(LOG, "Cannot read '%s' for the tap-hold rows; treating the remap settings as unavailable.", path)
		return nil, source
	end
	local ok, document, shapes = pcall(ConfigCodec.decode_with_shapes, raw)
	if not ok or type(document) ~= "table" then
		Logger.error(LOG, "Cannot parse '%s' as TOML — refusing the tap-hold rows it holds.", path)
		return nil, source
	end
	return TapHoldFile.read_config(document, shapes, path), source, shapes
end

--- A copy of a config part's value that keeps every decoded array itself: the
--- shape receipt names arrays by identity.
--- @param value any
--- @param shapes table|nil The config.toml shape receipt.
--- @return any
local function copy_part(value, shapes)
	if type(value) ~= "table" or (shapes and shapes.arrays[value]) then return value end
	local out = {}
	for key, item in pairs(value) do out[key] = copy_part(item, shapes) end
	return out
end

--- Lays the config.toml rows over a model read from tap_hold.toml. The model
--- gets copies: a save edits it and compares it with the part it read.
--- @param model table The Karabiner model, edited in place.
--- @param part table What M._read_config_part() returned, never edited here.
--- @param shapes table|nil The config.toml shape receipt.
local function overlay_config(model, part, shapes)
	if part[ConfigKeys.KEY.TAP_HOLDS] ~= nil then
		if model.tap_holds == nil then model.tap_holds = {} end
		if type(model.tap_holds) == "table" then
			for leaf, value in pairs(part[ConfigKeys.KEY.TAP_HOLDS]) do model.tap_holds[leaf] = copy_part(value, shapes) end
		end
	end
	model.mod_combos = copy_part(part[ConfigKeys.KEY.MOD_COMBOS], shapes)
end


local TAP_HOLD_TIMEOUT_MS_DEFAULT       = Defaults.tap_hold_timeout_ms
local TAP_HOLD_MAX_TIMEOUT_MS           = Defaults.tap_hold_max_timeout_ms
local LoneTap = require("tap_hold.engine.lone_tap")
-- How long a modifier key pressed alone still taps: the manifest's
-- tap_holds.lone_modifier_tap_max_ms (0 = the strict tap-hold).
M.LONE_MODIFIER_TAP_MAX_MS_DEFAULT = LoneTap.validate(
	Manifest.default_for(ConfigKeys.KEY.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS))
local STICKY_TIMEOUT_MS_DEFAULT         = Defaults.sticky_timeout_ms
local SIMULTANEOUS_THRESHOLD_MS_DEFAULT = Defaults.simultaneous_threshold_ms
local COMBO_SYMMETRIC_DEFAULT           = Defaults.combo_symmetric
local OUTDATED_BINDING_REASON = "a binding is a table of actions; the neutral one is used"
local OUTDATED_ARRAY_REASON = "a remap dictionary is not an array; the neutral state is used"

--- Reads one timing leaf without treating obsolete data as a file failure.
--- @return number value The existing numeric policy or the canonical default.
--- @return boolean outdated True when the raw leaf must survive ordinary saves.
local function timing_leaf(section, key, default, path, section_name)
	if section[key] == nil then return default, false end
	-- The global delay has SCHEMA.md's bound, read wherever this leaf is.
	local maximum = section_name == ConfigKeys.KEY.TAP_HOLDS and key == "timeout_ms" and TAP_HOLD_MAX_TIMEOUT_MS or nil
	local called, value = pcall(tonumber, section[key])
	if called and require("core.text.engine.number_policy").within_timer_ceiling(value)
		and value > 0 and value % 1 == 0 and (maximum == nil or value <= maximum) then return value, false end
	Outdated.report_in_file(path, { section_name, key }, maximum == nil
		and "a timing is a finite positive whole number of milliseconds; the canonical default is used"
		or string.format("a delay is a positive whole number of milliseconds up to %d; the canonical default is used",
			maximum), Logger)
	return default, true
end

--- Reads the lone modifier tap window, where 0 (the strict tap-hold) is a
--- choice, not an absent value; a negative or fractional window is obsolete.
--- @return number value The existing window or the canonical default.
--- @return boolean outdated True when the raw leaf must survive ordinary saves.
local function lone_tap_leaf(section, key, default, path, section_name)
	if section[key] == nil then return default, false end
	local valid, value = pcall(LoneTap.validate, section[key])
	if valid then return value, false end
	Outdated.report_in_file(path, { section_name, key },
		"a lone modifier tap window is 0 or a positive whole number of milliseconds; the canonical default is used",
		Logger)
	return default, true
end

--- Reads one Boolean leaf without treating obsolete data as a file failure.
--- @return boolean|nil value Its owning default when the source is obsolete.
--- @return boolean outdated
local function boolean_leaf(section, key, default, path, section_name, detail)
	if section[key] == nil then return default, false end
	if type(section[key]) == "boolean" then return section[key], false end
	Outdated.report_in_file(path, { section_name, key }, detail, Logger)
	return default, true
end

--- Reads the combination switch; its absent state keeps combinations on.
--- @return boolean|nil value
--- @return boolean outdated
local function combinations_enabled(section, path)
	return boolean_leaf(section, "enabled", nil, path, ConfigKeys.KEY.MOD_COMBOS,
		"a combination switch is boolean; its absent state is used")
end

--- Reads the tap-hold switch with its manifest-owned neutral value.
--- @return boolean value
--- @return boolean outdated
local function tap_holds_switch(section, path)
	return boolean_leaf(section, "enabled", Manifest.default_for(ConfigKeys.KEY.TAP_HOLDS_ENABLED), path, ConfigKeys.KEY.TAP_HOLDS,
		"a tap-hold switch is boolean; the neutral state is used")
end

--- Reads combination symmetry with its shared native default.
--- @return boolean value
--- @return boolean outdated
local function combinations_symmetric(section, path)
	return boolean_leaf(section, "symmetric", COMBO_SYMMETRIC_DEFAULT, path, ConfigKeys.KEY.MOD_COMBOS,
		"a combination symmetry switch is boolean; the canonical default is used")
end

--- « Ergopti uses Karabiner »: `[karabiner] integration_enabled` in
--- tap_hold.toml. On by default; off means no lease worker, no guardian
--- registration and no ErgoptiPlus rule left in karabiner.json. Karabiner
--- itself is never touched.
M.INTEGRATION_ENABLED_DEFAULT = true
local INTEGRATION_SECTION = "karabiner"
local INTEGRATION_KEY = "integration_enabled"
--- Hidden `[karabiner] runtime`: which Karabiner runtime the generated rules
--- target (ADR 011). `owned` (the absent default, the maintainer's decision for
--- the release after 1.0.9) is the Ergopti background runtime and its own
--- complete configuration; `shared` is the official application and the user's
--- karabiner.json, kept as a hand-written fallback until shared mode is retired.
--- It is deliberately not a menu row and not in the shared manifest. A value
--- that is not one of the two names refuses the whole file, like a corrupt one,
--- because a typo must not silently select the other runtime.
M.RUNTIME_DEFAULT = KePaths.RUNTIME_OWNED
local RUNTIME_KEY = "runtime"

--- Hidden `[karabiner] close_other_instances`: whether the owned runtime may ask
--- an official Karabiner-Elements that is running to quit (ADR 011, decision 3).
--- It is the user's consent: `true` (the absent default, as the maintainer
--- decided) lets the owned runtime close it, `false` makes the owned runtime
--- report `other_karabiner_running` instead, so Ergopti's runtime never runs
--- beside theirs. It is the Tap-Holds row « close other Karabiner apps while
--- Ergopti is running » on an owned boot; a value that is not a boolean refuses
--- the file. It is written only once it differs from the default or is already
--- in the file.
M.CLOSE_OTHER_INSTANCES_DEFAULT = true
local CLOSE_OTHER_KEY = "close_other_instances"
-- Builds before 2026-09-22 defaulted to off and wrote `[karabiner] enabled =
-- false` on first launch; later builds ignored it. It is not the user's
-- answer to the switch, so it is ignored and retained until explicit cleanup.
local LEGACY_INTEGRATION_KEY = "enabled"

--- Reports the retired preference without interpreting it as integration consent.
--- @param integration table|nil Parsed Karabiner section.
--- @param path string Owning configuration file.
local function report_retired_integration(integration, path)
	if type(integration) == "table" and integration[LEGACY_INTEGRATION_KEY] ~= nil then
		Outdated.report_in_file(path, { INTEGRATION_SECTION, LEGACY_INTEGRATION_KEY },
			"the retired integration key is ignored; integration_enabled owns consent", Logger)
	end
end





-- ====================================
-- ====================================
-- ======= 1/ JSON Data Loaders =======
-- ====================================
-- ====================================

--- Loads and parses a JSON file. Logs an error and returns nil on any failure.
--- @param path string Absolute path to the JSON file.
--- @return table|nil Decoded table, or nil.
local TomlCodec = require("core.text.engine.toml.codec")

--- Load a TOML user-config file.
--- Returns the decoded table on success, nil when the file is genuinely absent,
--- and a classified error when an existing path is unsafe or cannot be decoded
--- (so callers can distinguish first-launch from corruption). The optional
--- third result binds admission to these exact native-read bytes and route.
--- @param path string Native settings path.
--- @return table|nil data Parsed model when safe.
--- @return string|nil err Existing classified read or parse failure.
--- @return table|nil source Exact same-read path/status/raw receipt when admitted.
--- @return table|nil shapes Canonical parser identities for array dictionary admission.
function M._load_toml_file(path)
	local raw, read_status = FileSystem.read_with_status(path)
	if read_status ~= "ok" then
		if read_status == "absent" then return nil, "absent", { path = path, status = "absent" } end
		Logger.error(LOG, "Cannot read Karabiner user config; treating it as unavailable "
			.. "(failure content withheld).")
		return nil, "read_error"
	end
	local ok, data, shapes = pcall(TomlCodec.decode_with_shapes, raw)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Cannot parse '%s' as TOML — refusing to silently reset user config.", path)
		return nil, "parse_error"
	end
	local file = TapHoldFile.read(data, shapes, path)
	return file.model, nil, { path = path, status = "ok", content = raw }, file.model_shapes
end

local function load_json_file(path)
	local fh = io.open(path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open file '%s'.", path)
		return nil
	end
	local raw = fh:read("*a")
	fh:close()
	-- A tree: the catalogues are resolved for the layout in place, and two
	-- equal entries must not move together.
	local data, decode_err = JsonCodec.decode(raw)
	if type(data) ~= "table" then
		Logger.error(LOG, "Cannot decode JSON from '%s': %s.", path, tostring(decode_err or data))
		return nil
	end
	return data
end

--- Appends the full shared modifier × key matrix used by gesture and tap-hold
--- action pickers. Each label names its modifiers and its key from the shared
--- key name table in the user's language (« Cmd + Maj + Entrée »); they used to
--- keep the catalogue's English names in every locale.
-- Decoded once. The shared modifier-chord catalogue is a file on disk that does
-- not change while the driver runs, and this whole function re-ran on EVERY
-- layout change — re-reading and re-decoding the JSON to rebuild the same 673
-- action tables. Declared above the function that reads it.
local _chord_catalogue = nil

--- Replaces the hardcoded French label of any action that also exists in the one
--- action registry with its translated one.
---
--- This catalogue's entries and the rows of _shared/shortcuts/data/actions/actions.toml
--- are now ONE namespace: the 18 that always overlapped, plus the 32 merged on
--- 2026-08-03, plus 4 that turned out to be Karabiner spellings of an action the
--- registry already carried (`return`≡`enter`, `delete_fwd`≡`delete`, `cmd_tab`
--- and `alt_tab_apps_list`≡`app_switcher`) and resolve through the alias table
--- rather than duplicating a translated string in twenty-one files.
---
--- The hold-only ones have no registry row by design, not by omission: a
--- gesture has no duration. The bare modifiers and their combinations are named
--- from the key name table (name_modifier_holds), the layer holds by the hold
--- picker's layer label (name_held_layers). A sticky label is a template its
--- modifiers fill from the same table (« 📌 {1} rémanents »).
--- @param actions table The decoded action list, mutated in place.
--- @return number localised How many labels came from the registry.
local function localise_action_labels(actions)
	local ok_reg, Registry = pcall(require, "gestures.engine.actions")
	local aliases = {}
	if ok_reg and type(Registry) == "table" and type(Registry.karabiner_aliases) == "function" then
		aliases = Registry.karabiner_aliases() or {}
	else
		Logger.warn(LOG, "Action registry unavailable — aliased labels stay in their catalogue language.")
	end

	local localised = 0
	for _, action in ipairs(actions) do
		if type(action) == "table" and type(action.id) == "string" then
			local key = "sg_actions." .. (aliases[action.id] or action.id)
			-- A missing key means this action has no registry row and no alias.
			-- i18n.has answers it from the active catalogue: i18n.get decoded
			-- en.json for the first miss of every boot only to miss again.
			local translated = i18n.has(key) and i18n.get(key) or nil
			if translated and translated ~= key and translated ~= "" then
				if StickyLabel.is_sticky(action.id) then
					translated = StickyLabel.label(action.id, key, "macos", i18n.get)
				end
				action.label = translated
				action.short_label = translated
				localised = localised + 1
			end
		end
	end
	Logger.debug(LOG, "Localised %d of %d action label(s) from the shared registry.", localised, #actions)
	return localised
end

--- Names the bare modifier and modifier-combination holds (those declaring
--- `modifiers`) from the shared key name table: their glyphs, then their names
--- in the user's language (« ⌘⇧ Cmd + Maj »). They read « ⌘⇧ — Cmd+Shift »
--- in English in every locale.
--- @param actions table The decoded action list, mutated in place.
local function name_modifier_holds(actions)
	for _, action in ipairs(actions) do
		if type(action) == "table" and action.modifiers ~= nil then
			if type(action.modifiers) ~= "table" or #action.modifiers == 0 then
				error("remap action " .. tostring(action.id) .. " declares no modifier", 2)
			end
			action.label = KeyNames.modifiers_heading(action.modifiers, "macos", i18n.get)
			action.short_label = KeyNames.modifiers_label(action.modifiers, "macos", i18n.get)
			if action.id == "hyper" then
				action.label = "Hyper — " .. action.label
				action.short_label = "Hyper"
			end
		end
	end
end

--- Names the layer holds (those declaring `hold_layer`) by the label the shared
--- hold picker gives that layer on every driver (_shared/tap_hold/engine/
--- hold_options.lua: tap_hold.hold.<layer>_layer). The navigation layer hold
--- read « Layer nav. — Actif tant que maintenu » in French in every locale.
--- @param actions table The decoded action list, mutated in place.
local function name_held_layers(actions)
	for _, action in ipairs(actions) do
		if type(action) == "table" and action.hold_layer ~= nil then
			if type(action.hold_layer) ~= "string" or action.hold_layer == "" then
				error("remap action " .. tostring(action.id) .. " declares no layer", 2)
			end
			local key = "tap_hold.hold." .. action.hold_layer .. "_layer"
			local text = i18n.get(key)
			if type(text) ~= "string" or text == "" then
				error("remap action " .. tostring(action.id) .. ": " .. key .. " has no text", 2)
			end
			action.label = "🗂 " .. text
			action.short_label = text
		end
	end
end

--- Names the actions that stand for one key (those declaring `key_name`) from
--- the shared key name table: its macOS glyph when it has one, then its name
--- in the user's language. AltGr read « ⌥ AltGr (option droite — interne) »
--- in French in every locale.
--- @param actions table The decoded action list, mutated in place.
local function name_key_actions(actions)
	for _, action in ipairs(actions) do
		if type(action) == "table" and action.key_name ~= nil then
			if type(action.key_name) ~= "string" or not KeyNames.canonical(action.key_name) then
				error("remap action " .. tostring(action.id) .. " names no known key", 2)
			end
			local name = KeyNames.label(action.key_name, "macos", i18n.get)
			local glyph = KeyNames.has_macos_symbol(action.key_name) and KeyNames.macos_symbol(action.key_name)
			action.label = glyph and (glyph .. " " .. name) or name
			action.short_label = name
		end
	end
end

--- Names each action's picker heading: `category` is an id of the
--- remap.category.* locale keys. The headings read « Modificateurs »,
--- « Touches » or « Keyboard shortcuts » whatever the user's language. A
--- catalogue miss shows its dotted key, like every other label; an action
--- without a category has no heading, as the picker already allows.
--- @param actions table The decoded action list, mutated in place.
local function name_categories(actions)
	for _, action in ipairs(actions) do
		if type(action) == "table" and action.category ~= nil then
			if type(action.category) ~= "string" or not action.category:match("^[a-z_]+$") then
				error("remap action " .. tostring(action.id) .. ": category " .. tostring(action.category)
					.. " is not a category id", 2)
			end
			action.category = i18n.get("remap.category." .. action.category)
		end
	end
end

local function append_shared_modifier_chords(actions)
	local catalogue_path = Paths.shared("shortcuts/data/actions/modifier_chords.json")
	if not catalogue_path then return end
	if _chord_catalogue == nil then
		_chord_catalogue = load_json_file(catalogue_path) or false
	end
	local catalogue = _chord_catalogue or nil
	local platform = catalogue and catalogue.platforms and catalogue.platforms.macos
	local modifiers = platform and platform.modifiers
	local keys = catalogue and catalogue.keys
	if type(modifiers) ~= "table" or type(keys) ~= "table" then return end

	local max_mask = (2 ^ #modifiers) - 1
	for mask = 1, max_mask do
		local ids, karabiner_modifiers = {}, {}
		for index, modifier in ipairs(modifiers) do
			if math.floor(mask / (2 ^ (index - 1))) % 2 == 1 then
				ids[#ids + 1] = modifier.id
				karabiner_modifiers[#karabiner_modifiers + 1] = modifier.karabiner
			end
		end
		local id_prefix = table.concat(ids, "_")
		for _, key_def in ipairs(keys) do
			local label = KeyNames.chord_label(ids, key_def, "macos", i18n.get)
			local action = {
				id = id_prefix .. "_" .. key_def.id,
				short_label = label,
				label = label,
				category = "keyboard_shortcuts",
				holdable = false,
			}
			if key_def.karabiner_key then
				action.karabiner_to = {{
					key_code = key_def.karabiner_key,
					modifiers = karabiner_modifiers,
				}}
			else
				action.logical_char = key_def.id
				action.karabiner_modifiers = karabiner_modifiers
			end
			actions[#actions + 1] = action
		end
	end
end

--- Loads all action definitions from keyboard/data/actions.json.
--- Entries with a "logical_char" field have their "karabiner_to" resolved at load
--- time via modules.keymap.layout, so the physical key_code always matches the current OS
--- keyboard layout — no hardcoded QWERTY positions.
--- @param actions_file string Absolute path to actions.json.
--- @return table|nil List of action definitions, or nil on failure.
--- @return string|nil error_message Validation failure.
-- Built action list, cached across layout changes. Declared above the functions
-- that read it: a local placed below would bind the nil global instead.
local _cached_actions = nil

--- Re-resolves every layout-dependent action against the CURRENT keyboard layout.
---
--- Split out of load_available_actions because it is the only part of it that
--- depends on the layout. The rest — a 20 kB JSON read and decode, plus the ~600
--- generated modifier-chord entries — is layout-independent and was being redone
--- on every single layout change.
---
--- It is also what the resume path needs. After a sleep/wake or a config reload the
--- action list still holds the key codes of whatever layout was active when it was
--- built, and re-running the whole loader to fix that was the only option; now the
--- resolution can be re-run on its own, against the list already in memory.
---
--- @param list table The action list to re-resolve IN PLACE.
--- @param product string|nil Virtual keyboard product the names are written for; nil only for
---   the first load, which every deploy re-resolves with the user's choice before it generates.
--- @return number How many actions were resolved.
--- @return string The captured layout keycode convention (the keycodes keys arrive as).
function M.resolve_layout_actions(list, product)
	if type(list) ~= "table" then
		Logger.error(LOG, "resolve_layout_actions(): expected a table — nothing resolved.")
		return 0
	end
	-- One declaration owns every logical character in this generation. It names
	-- the keycodes keys arrive as; the names are written for the deployed
	-- virtual keyboard product, which passes the ISO pair through unswapped.
	-- Two phases inside karabiner.layout_actions: the field's 230 ms there is
	-- native work, and the registry snapshot and the per-character keycode
	-- lookups are its two candidates (field report 2026-11-03); the next report
	-- names the one to move before anything is changed.
	local Phases = require("infra.phase_stats")
	local stage_started = Phases.now()
	local form = Layout.keyboard_form()
	Phases.stop("karabiner.layout_actions.keyboard_form", stage_started)
	product = product or Layout.default_virtual_keyboard_product()
	local resolved = 0
	stage_started = Phases.now()
	for _, action in ipairs(list) do
		if action.logical_char then
			local key_code = Layout.key_code_for_char(action.logical_char, product)
			local mods     = action.karabiner_modifiers
			local entry    = { key_code = key_code }
			if type(mods) == "table" and #mods > 0 then
				entry.modifiers = mods
			end
			action.karabiner_to = { entry }
			resolved = resolved + 1
		end
	end
	Phases.stop("karabiner.layout_actions.key_codes", stage_started)
	-- One summary line, not one per action. DEBUG is this driver's default level
	-- and every layout change re-runs this loop, so per-action lines were 548 log
	-- writes for a fact the total already conveys.
	Logger.debug(LOG, "Resolved %d logical-char action(s) to key codes.", resolved)
	return resolved, form
end

function M.load_available_actions(actions_file)
	-- The built list is cached and re-resolved rather than rebuilt. Everything up to
	-- the resolution below is layout-INDEPENDENT: the JSON read and decode, and the
	-- ~600 modifier-chord entries generated from the shared catalogue. A layout
	-- change re-ran all of it to change only the key codes.
	if _cached_actions then
		M.resolve_layout_actions(_cached_actions)
		Logger.debug(LOG, "Re-resolved %d cached action(s) for the current layout.",
			#_cached_actions)
		return _cached_actions
	end

	local list = load_json_file(actions_file)
	if not list then
		Logger.error(LOG, "Cannot load actions — module will be non-functional.")
		return nil
	end
	localise_action_labels(list)
	name_modifier_holds(list)
	name_held_layers(list)
	name_key_actions(list)
	append_shared_modifier_chords(list)
	name_categories(list)
	local _, catalogue_err = ActionCatalogue.index_by_id(list)
	if catalogue_err then
		Logger.error(LOG, "Cannot load actions: %s.", catalogue_err)
		return nil, catalogue_err
	end
	M.resolve_layout_actions(list)

	_cached_actions = list
	Logger.info(LOG, "Loaded %d action(s) from actions.json.", #list)
	return list
end

--- Loads configurable key definitions from keyboard/data/tap_hold_keys.json.
--- @param tap_hold_file string Absolute path to tap_hold_keys.json.
--- @return table|nil List of key definitions, or nil on failure.
function M.load_tap_hold_keys(tap_hold_file)
	local list = load_json_file(tap_hold_file)
	if not list then
		Logger.error(LOG, "Cannot load tap_hold_keys — module will be non-functional.")
		return nil
	end
	Logger.info(LOG, "Loaded %d configurable tap / hold key(s).", #list)
	return list
end

--- Loads modifier combo definitions from keyboard/data/mod_combos.json.
--- @param mod_combos_file string Absolute path to mod_combos.json.
--- @return table|nil List of combo definitions, or nil on failure.
function M.load_mod_combos(mod_combos_file)
	local list = load_json_file(mod_combos_file)
	if not list then
		Logger.error(LOG, "Cannot load mod_combos — module will be non-functional.")
		return nil
	end
	Logger.info(LOG, "Loaded %d modifier combo(s).", #list)
	return list
end

--- Builds the non-canonical combo set: IDs whose reverse (same two keys in
--- opposite order) appeared earlier in mod_combos. Used to hide redundant
--- entries when symmetric mode is on.
--- @param mod_combos table List of combo definitions from load_mod_combos.
--- @return table Map of combo_id → true for every non-canonical combo.
function M.compute_non_canonical_combos(mod_combos)
	local seen          = {}
	local non_canonical = {}

	for _, combo_def in ipairs(mod_combos) do
		local sim = combo_def.from and combo_def.from.simultaneous
		if type(sim) ~= "table" or #sim ~= 2 then goto next end

		local k1       = sim[1].key_code or ""
		local k2       = sim[2].key_code or ""
		local pair_fwd = k1 .. "|" .. k2
		local pair_rev = k2 .. "|" .. k1

		if seen[pair_rev] then
			non_canonical[combo_def.id] = true
			Logger.debug(LOG, "Non-canonical combo: '%s' (reverse of '%s').",
				combo_def.id, seen[pair_rev])
		elseif not seen[pair_fwd] then
			seen[pair_fwd] = combo_def.id
		end

		::next::
	end

	local count = TableUtil.count(non_canonical)
	Logger.debug(LOG, "Non-canonical combos computed: %d.", count)
	return non_canonical
end





-- ========================================
-- ========================================
-- ======= 2/ Default State Builder =======
-- ========================================
-- ========================================

--- Builds the default full state from tap / hold keys and modifier combos.
--- Used only at first launch and when the user resets to defaults.
--- @param tap_hold_keys table List from load_tap_hold_keys.
--- @param mod_combos table List from load_mod_combos.
--- @return table Full default state: {enabled, tap_hold_config, mod_combos_config, timeouts…}
local function build_state(tap_hold_keys, mod_combos, recommended)
	local tap_hold_config = {}
	for _, key_def in ipairs(tap_hold_keys or {}) do
		local d = recommended and Defaults.tap_hold[key_def.id] or nil
		if recommended and not d then
			Logger.warn(LOG, "No default entry for key '%s' in the shared tap-hold defaults (defaults.toml) — using none/none.", key_def.id)
		end
		tap_hold_config[key_def.id] = {
			tap  = d and d[1] or "none",
			hold = d and d[2] or "none",
		}
	end

	local mod_combos_config = {}
	for _, combo_def in ipairs(mod_combos or {}) do
		local d = recommended and Defaults.combos[combo_def.id] or nil
		if recommended and not d then
			Logger.warn(LOG, "No default entry for combo '%s' in the shared tap-hold defaults (defaults.toml) — using none/none/none.", combo_def.id)
		end
		mod_combos_config[combo_def.id] = {
			combo = d and d[1] or "none",
			tap   = d and d[2] or "none",
			hold  = d and d[3] or "none",
		}
	end

	return {
		enabled                   = M.INTEGRATION_ENABLED_DEFAULT,
		tap_holds_enabled         = recommended and Manifest.recommended_for(ConfigKeys.KEY.TAP_HOLDS_ENABLED)
			or Manifest.default_for(ConfigKeys.KEY.TAP_HOLDS_ENABLED),
		-- Absent: the key combinations are on whatever the Tap-Holds switch says
		-- (Generator.key_combinations_enabled), in the preset as on a fresh install.
		mod_combos_enabled        = nil,
		tap_hold_config           = tap_hold_config,
		mod_combos_config         = mod_combos_config,
		tap_hold_timeout_ms       = TAP_HOLD_TIMEOUT_MS_DEFAULT,
		lone_modifier_tap_max_ms  = M.LONE_MODIFIER_TAP_MAX_MS_DEFAULT,
		sticky_timeout_ms         = STICKY_TIMEOUT_MS_DEFAULT,
		simultaneous_threshold_ms = SIMULTANEOUS_THRESHOLD_MS_DEFAULT,
		combo_symmetric           = COMBO_SYMMETRIC_DEFAULT,
	}
end

--- Builds a neutral state without importing any recommended input bindings.
--- @param tap_hold_keys table Available key definitions.
--- @param mod_combos table Available combo definitions.
--- @return table state Neutral desired state with parameter defaults.
function M.build_default_state(tap_hold_keys, mod_combos)
	return build_state(tap_hold_keys, mod_combos, false)
end

--- Projects the shipped preset for an explicit scoped restore only.
--- @param tap_hold_keys table Available key definitions.
--- @param mod_combos table Available combo definitions.
--- @return table state Recommended desired state.
function M.build_recommended_state(tap_hold_keys, mod_combos)
	return build_state(tap_hold_keys, mod_combos, true)
end





-- ==========================================
-- ==========================================
-- ======= 3/ User Config Persistence =======
-- ==========================================
-- ==========================================

--- Loads tap_hold.toml as the Karabiner model.
--- If the file is absent (first launch), builds and returns the default state.
--- A sparse file is completed with neutral values; legacy combos are upgraded.
--- @param tap_hold_keys table List from load_tap_hold_keys.
--- @param mod_combos table List from load_mod_combos.
--- @param user_config_path string Absolute path to tap_hold.toml.
--- @return table|nil state Full state, or nil when the persisted source is unsafe.
--- @return string status One of "ok", "absent", or "error".
--- @return table|nil source Optional exact same-read path/status/raw admission receipt.
function M.load_user_config(tap_hold_keys, mod_combos, user_config_path)
	local data, err, source, shapes = M._load_toml_file(user_config_path)

	if not data then
		if err == "parse_error" or err == "read_error" then
			-- File exists but is corrupt: _load_toml_file already logged the
			-- error with the full path. Fall back to defaults so the driver can
			-- run, but do NOT overwrite the corrupt file.
			return nil, "error"
		end
	end
	-- The manifest rows live in config.toml: an unsafe one refuses the state
	-- like a corrupt tap_hold.toml, rather than read its rows as neutral.
	local config_part, config_source, config_shapes = M._read_config_part(user_config_path)
	if config_part == nil then return nil, "error" end
	source.config = config_source
	if not data then
		if next(config_part) == nil then
			Logger.info(LOG, "No user config found — initializing from defaults.")
			return M.build_default_state(tap_hold_keys, mod_combos), "absent", source
		end
		Logger.info(LOG, "No tap_hold.toml yet — the config.toml rows apply over the defaults.")
		data = {}
	end
	overlay_config(data, config_part, config_shapes)
	shapes = merged_shapes(shapes, config_shapes)

	-- The switch decides whether any lease or guardian may be acquired, so an
	-- unreadable value is refused like a corrupt file rather than read as on.
	local integration = data[INTEGRATION_SECTION]
	if integration ~= nil and (type(integration) ~= "table"
		or (shapes and shapes.arrays[integration])) then
		Logger.error(LOG, "[%s] in '%s' is not a table — refusing the unsafe user config.",
			INTEGRATION_SECTION, user_config_path)
		return nil, "error"
	end
	local integration_enabled = M.INTEGRATION_ENABLED_DEFAULT
	if integration ~= nil and integration[INTEGRATION_KEY] ~= nil then
		if type(integration[INTEGRATION_KEY]) ~= "boolean" then
			Logger.error(LOG, "[%s] %s in '%s' must be true or false, got a %s — refusing the unsafe user config.",
				INTEGRATION_SECTION, INTEGRATION_KEY, user_config_path, type(integration[INTEGRATION_KEY]))
			return nil, "error"
		end
		integration_enabled = integration[INTEGRATION_KEY]
	end
	local runtime = M.RUNTIME_DEFAULT
	if integration ~= nil and integration[RUNTIME_KEY] ~= nil then
		local value = integration[RUNTIME_KEY]
		if value ~= KePaths.RUNTIME_SHARED and value ~= KePaths.RUNTIME_OWNED then
			Logger.error(LOG, "[%s] %s in '%s' must be \"%s\" or \"%s\", got %s — refusing the unsafe user config.",
				INTEGRATION_SECTION, RUNTIME_KEY, user_config_path, KePaths.RUNTIME_SHARED,
				KePaths.RUNTIME_OWNED, tostring(value))
			return nil, "error"
		end
		runtime = value
	end
	local close_other_instances = M.CLOSE_OTHER_INSTANCES_DEFAULT
	if integration ~= nil and integration[CLOSE_OTHER_KEY] ~= nil then
		local value = integration[CLOSE_OTHER_KEY]
		if type(value) ~= "boolean" then
			Logger.error(LOG, "[%s] %s in '%s' must be true or false, got %s — refusing the unsafe user config.",
				INTEGRATION_SECTION, CLOSE_OTHER_KEY, user_config_path, tostring(value))
			return nil, "error"
		end
		close_other_instances = value
	end
	report_retired_integration(integration, user_config_path)

	-- Saves are sparse against the neutral state: an absent table, key, slot or
	-- timing IS the neutral value, so it is completed silently. Only a present
	-- value of the wrong type is an anomaly worth a warning.
	local function source_array(value, segments)
		if not shapes or not shapes.arrays[value] then return false end
		Outdated.report_in_file(user_config_path, segments,
			OUTDATED_ARRAY_REASON, Logger)
		return true
	end
	local tap_holds = type(data.tap_holds) == "table"
		and not source_array(data.tap_holds, { ConfigKeys.KEY.TAP_HOLDS }) and data.tap_holds or {}
	local combos = type(data.mod_combos) == "table"
		and not source_array(data.mod_combos, { ConfigKeys.KEY.MOD_COMBOS }) and data.mod_combos or {}

	local function owned_table(parent, key, label, section)
		if parent[key] == nil then return {} end
		if type(parent[key]) == "table" then
			if source_array(parent[key], { section, key }) then return {} end
			return parent[key]
		end
		Logger.warn(LOG, "Ignoring the non-table %s in the saved config — using neutral bindings.", label)
		return {}
	end

	local function complete_slots(entry, slots)
		for _, slot in ipairs(slots) do
			if entry[slot] == nil then entry[slot] = "none" end
		end
	end

	local tap_hold_config = owned_table(tap_holds, "config", "[tap_holds.config]", ConfigKeys.KEY.TAP_HOLDS)
	for _, key_def in ipairs(tap_hold_keys) do
		if tap_hold_config[key_def.id] == nil then tap_hold_config[key_def.id] = {} end
		if source_array(tap_hold_config[key_def.id], { ConfigKeys.KEY.TAP_HOLDS, "config", key_def.id }) then
			tap_hold_config[key_def.id] = {}
		end
		if type(tap_hold_config[key_def.id]) == "table" then
			complete_slots(tap_hold_config[key_def.id], { "tap", "hold" })
		end
	end

	local combos_config = owned_table(combos, "config", "[mod_combos.config]", ConfigKeys.KEY.MOD_COMBOS)
	local known_combos = {}
	for _, def in ipairs(mod_combos) do known_combos[def.id] = true end
	for id, entry in pairs(combos_config) do
		if known_combos[id] and source_array(entry, { ConfigKeys.KEY.MOD_COMBOS, "config", tostring(id) }) then
			combos_config[id] = {}
		elseif type(entry) == "string" then
			Logger.info(LOG, "Migrating combo '%s' from legacy string format.", id)
			combos_config[id] = { tap = "none", hold = entry, combo = "none" }
		end
	end
	for _, combo_def in ipairs(mod_combos) do
		if combos_config[combo_def.id] == nil then combos_config[combo_def.id] = {} end
	end
	for _, entry in pairs(combos_config) do
		if type(entry) == "table" then complete_slots(entry, { "tap", "hold", "combo" }) end
	end

	-- An entry this build cannot use is outdated: a key or combination the
	-- catalogue no longer has, or a binding that is not a table. It is warned
	-- once naming this file. A retired entry is left out of the state: a save
	-- merges only the state's own ids, so it stays on disk for the user instead
	-- of making every save fail to encode it. A known key's unusable value runs
	-- as its neutral binding. Unrelated saves preserve that scalar, while a
	-- changed binding still refuses until the user explicitly repairs the file.
	local function drop_outdated(config, catalogue, section, slots)
		local known = {}
		for _, def in ipairs(catalogue) do known[def.id] = true end
		for id, entry in pairs(config) do
			if not known[id] then
				Outdated.report_in_file(user_config_path, { section, "config", tostring(id) },
					"no entry of this build's catalogue has this id")
				config[id] = nil
			elseif type(entry) ~= "table" then
				Outdated.report_in_file(user_config_path, { section, "config", id },
					OUTDATED_BINDING_REASON, Logger)
				config[id] = {}
				complete_slots(config[id], slots)
			end
		end
	end
	drop_outdated(tap_hold_config, tap_hold_keys, ConfigKeys.KEY.TAP_HOLDS, { "tap", "hold" })
	drop_outdated(combos_config, mod_combos, ConfigKeys.KEY.MOD_COMBOS, { "tap", "hold", "combo" })

	-- A key's own delay the generator cannot deploy is named here, once: the key
	-- follows the global delay, and the file keeps the value for the user.
	for id, entry in pairs(tap_hold_config) do
		local own = type(entry) == "table" and entry.timeout_ms or nil
		if own ~= nil and not (type(own) == "number" and own > 0 and own <= TAP_HOLD_MAX_TIMEOUT_MS) then
			Outdated.report_in_file(user_config_path, { ConfigKeys.KEY.TAP_HOLDS, "config", tostring(id), "timeout_ms" },
				string.format("a key's delay is more than 0 and at most %d ms; the key follows the global delay",
					TAP_HOLD_MAX_TIMEOUT_MS), Logger)
		end
	end

	-- Reads one optional number; absence is the canonical default.
	local function timing(section, key, default, label)
		local section_name = assert(label:match("^([^.]+)%."), "a timing needs its owning section")
		return timing_leaf(section, key, default, user_config_path, section_name)
	end
	local timeout_ms = timing(tap_holds, "timeout_ms", TAP_HOLD_TIMEOUT_MS_DEFAULT, ConfigKeys.KEY.TAP_HOLDS_TIMEOUT_MS)
	local sticky_ms = timing(tap_holds, ConfigKeys.LEAF.STICKY_TIMEOUT_MS, STICKY_TIMEOUT_MS_DEFAULT,
		ConfigKeys.KEY.TAP_HOLDS_STICKY_TIMEOUT_MS)
	local lone_tap_ms = lone_tap_leaf(tap_holds, ConfigKeys.LEAF.LONE_MODIFIER_TAP_MAX_MS,
		M.LONE_MODIFIER_TAP_MAX_MS_DEFAULT, user_config_path, ConfigKeys.KEY.TAP_HOLDS)
	local simultaneous_ms = timing(combos, ConfigKeys.LEAF.SIMULTANEOUS_THRESHOLD_MS, SIMULTANEOUS_THRESHOLD_MS_DEFAULT,
		ConfigKeys.KEY.MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS)

	local combo_symmetric = combinations_symmetric(combos, user_config_path)

	-- Absence is neutral even when other explicit remap preferences are present.
	local tap_holds_enabled = tap_holds_switch(tap_holds, user_config_path)

	-- The key-combinations switch stays absent until the user sets it: absent,
	-- the combinations are on (Generator.key_combinations_enabled).
	local mod_combos_enabled = combinations_enabled(combos, user_config_path)

	Logger.info(LOG, "User config loaded (Ergopti uses Karabiner: %s).", tostring(integration_enabled))
	local status = source.status == "absent" and "absent" or "ok"
	return {
		enabled                   = integration_enabled,
		runtime                   = runtime,
		close_other_instances     = close_other_instances,
		tap_holds_enabled         = tap_holds_enabled,
		mod_combos_enabled        = mod_combos_enabled,
		tap_hold_config           = tap_hold_config,
		mod_combos_config         = combos_config,
		tap_hold_timeout_ms       = timeout_ms,
		lone_modifier_tap_max_ms  = lone_tap_ms,
		sticky_timeout_ms         = sticky_ms,
		simultaneous_threshold_ms = simultaneous_ms,
		combo_symmetric           = combo_symmetric,
	}, status, source
end

-- The scalar leaves a menu setter can name as explicitly set by the user.
local INTENT_LEAVES = {
	[ConfigKeys.KEY.TAP_HOLDS_ENABLED] = true, [ConfigKeys.KEY.TAP_HOLDS_TIMEOUT_MS] = true, [ConfigKeys.KEY.TAP_HOLDS_STICKY_TIMEOUT_MS] = true,
	[ConfigKeys.KEY.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS] = true,
	[ConfigKeys.KEY.MOD_COMBOS_ENABLED] = true, [ConfigKeys.KEY.MOD_COMBOS_SIMULTANEOUS_THRESHOLD_MS] = true,
	[ConfigKeys.KEY.MOD_COMBOS_SYMMETRIC] = true,
}

--- Validates a save's explicit leaf intent: only owned leaves, each set to true.
--- A carried value is never intent; only the setter of that leaf supplies it.
--- @param intent table|nil `{ leaves = { [path] = true } }`.
--- @return table leaves Set of explicitly owned leaf paths (empty when nil).
function M.explicit_leaves(intent)
	if intent == nil then return {} end
	assert(type(intent) == "table" and getmetatable(intent) == nil and type(intent.leaves) == "table",
		"remap leaf intent must be a plain { leaves = ... } table")
	for name in pairs(intent) do assert(name == "leaves", "remap leaf intent has an unknown field") end
	local leaves = {}
	for path, owned in pairs(intent.leaves) do
		assert(type(path) == "string" and owned == true, "remap leaf intent names each leaf with true")
		local binding = path:match("^tap_holds%.config%.([%w_]+)$") or path:match("^mod_combos%.config%.([%w_+]+)$")
		assert(INTENT_LEAVES[path] or binding ~= nil, "remap leaf intent names a leaf this owner does not write: " .. path)
		leaves[path] = true
	end
	return leaves
end

--- Persists the non-neutral state sparsely to tap_hold.toml.
--- Refuses to publish over a file that exists but cannot be decoded as TOML:
--- load_user_config() already falls back to defaults without touching such a
--- file, so the overwrite performed by the very next setter is where the user's
--- still-recoverable tap/hold and combo configuration was actually destroyed.
--- @param state table The current module state table.
--- @param user_config_path string Absolute path to tap_hold.toml.
--- @param overwrite_corrupt boolean|nil True only for the explicit reset-to-defaults
---        action — the one case where clobbering an unparseable file is the intent.
--- @param expected_source table|nil `{ status, content }` a scope transaction read
---        and backed up: the save refuses when the file no longer holds exactly it.
--- @param intent table|nil `{ leaves = { ["<section>.<key>"] = true } }` naming the
---        leaves the caller's user explicitly set. An obsolete value at such a leaf
---        is replaced; every other obsolete leaf keeps the ordinary preservation.
--- @return boolean True only after publication and native cleanup settle.
--- @return string|nil detail Publication refusal.
--- @return table|nil receipt Private exact source/candidate and retained native cleanup.
function M.save_user_config(state, user_config_path, overwrite_corrupt, expected_source, intent)
	assert(expected_source == nil or (not overwrite_corrupt and type(expected_source) == "table"
		and (expected_source.status == "absent" or (expected_source.status == "ok"
			and type(expected_source.content) == "string"))), "invalid remap source precondition")
	local explicit = M.explicit_leaves(intent)
	assert(intent == nil or not overwrite_corrupt, "a reset already owns every remap leaf")
	local document = {}
	local document_shapes
	-- The shared file the save started from, nil when it starts from none; a
	-- reset's parsed source, whose other drivers' settings it keeps.
	local shared_file, reset_base
	local source, source_status
	-- The config.toml rows read before the save, compared with the model after.
	local config_part, config_source, config_shapes = M._read_config_part(user_config_path)
	if config_part == nil then
		Logger.error(LOG, "Refusing to save the remap settings: the config.toml beside '%s' is unsafe — settings NOT saved.",
			user_config_path)
		return false
	end
	if expected_source and expected_source.config and (expected_source.config.status ~= config_source.status
		or (config_source.status == "ok" and expected_source.config.content ~= config_source.content)) then
		Logger.error(LOG, "Refusing to overwrite '%s': it changed after its backup — settings NOT saved.",
			config_source.path)
		return false
	end
	if not overwrite_corrupt then
		-- Re-reading before every save is cheap (a few KB, only on user action)
		-- and is the only way to notice that the file went bad since boot.
		source, source_status = FileSystem.read_with_status(user_config_path)
		if expected_source and (source_status ~= expected_source.status
			or (source_status == "ok" and source ~= expected_source.content)) then
			Logger.error(LOG, "Refusing to overwrite '%s': it changed after its backup — settings NOT saved.",
				user_config_path)
			return false
		end
		if source_status == "error" then
			Logger.error(LOG, "Refusing to overwrite the unsafe user config at '%s' — settings NOT saved.",
				user_config_path)
			return false
		end
		if source_status == "ok" then
			local decoded_ok, decoded, shapes = pcall(TomlCodec.decode_with_shapes, source)
			if not decoded_ok or type(decoded) ~= "table" then
				if not expected_source then
					Logger.error(LOG, "Refusing to overwrite the unparseable user config at '%s' — settings NOT saved. Repair or delete the file, or use Tap-Holds › Restore recommended values, which backs it up and rewrites it.",
						user_config_path)
					return false
				end
				-- A scope already verified a backup of these exact bytes, so its
				-- candidate may replace them: the only menu path that repairs the file.
				Logger.warn(LOG, "Rewriting the unparseable user config at '%s'; its exact bytes are in the scope backup.",
					user_config_path)
				decoded, shapes = {}, nil
			else
				shared_file = TapHoldFile.read(decoded, shapes, user_config_path)
				-- The save edits these bytes line by line: comments and other drivers' text stay.
				shared_file.source_text = source
				if not shared_file.writable then
					Logger.error(LOG, "Refusing to overwrite '%s': it was saved by a newer build or its version is unusable — settings NOT saved.",
						user_config_path)
					return false
				end
				decoded, shapes = shared_file.model, shared_file.model_shapes
			end
			document, document_shapes = decoded, shapes
		elseif source_status ~= "absent" then
			Logger.error(LOG, "Refusing to overwrite user config at '%s' after an unclassified read.",
				user_config_path)
			return false
		end
	else
		-- Explicit repair owns corrupt bytes, not a later writer's replacement.
		-- Retain the raw source even when decoding is deliberately bypassed.
		source, source_status = FileSystem.read_with_status(user_config_path)
		if source_status ~= "ok" and source_status ~= "absent" then
			Logger.error(LOG, "Refusing to repair unreadable user config at '%s'.", user_config_path)
			return false
		end
		-- The file is shared: a reset replaces what macOS owns and keeps the
		-- other drivers' settings of a file that still parses.
		if source_status == "ok" then
			local decoded_ok, decoded, shapes = pcall(TomlCodec.decode_with_shapes, source)
			if decoded_ok and type(decoded) == "table" then reset_base = { document = decoded, shapes = shapes } end
		end
	end

	-- An ordinary save keeps every config.toml row it does not change, outdated
	-- spellings included; a reset replaces what macOS owns there too.
	if not overwrite_corrupt then overlay_config(document, config_part, config_shapes) end
	document_shapes = merged_shapes(document_shapes, config_shapes)
	local config_rows
	local candidate_refusal = nil
	local ok, payload = pcall(function()
		local function table_at(parent, key)
			if parent[key] == nil then parent[key] = {} end
			assert(type(parent[key]) == "table" and not (document_shapes and document_shapes.arrays[parent[key]]),
				"owned remap table conflicts with a scalar or array")
			return parent[key]
		end
		local function assign(target, key, value, neutral)
			if not overwrite_corrupt and value == neutral then value = nil end
			target[key] = value
		end
		local function assign_timing(target, section, key, value, neutral, read_leaf)
			local _, outdated = (read_leaf or timing_leaf)(target, key, neutral, user_config_path, section)
			if not overwrite_corrupt and outdated and not explicit[section .. "." .. key] then
				if value ~= neutral then
					candidate_refusal = "candidate has no explicit repair owner for " .. section .. "." .. key
					error(candidate_refusal, 0)
				end
				return
			end
			assign(target, key, value, neutral)
		end
		local function assign_boolean(target, section, key, value, neutral, classify)
			local _, outdated = classify(target, user_config_path)
			if not overwrite_corrupt and outdated and not explicit[section .. "." .. key] then
				if value ~= neutral then
					candidate_refusal = "candidate has no explicit repair owner for " .. section .. "." .. key
					error(candidate_refusal, 0)
				end
				return
			end
			assign(target, key, value, neutral)
		end
		local function merge_bindings(target, updates, fields, section)
			for id, values in pairs(updates or {}) do
				assert(type(id) == "string" and type(values) == "table", "invalid remap binding candidate")
				local repaired = explicit[section .. ".config." .. id] == true
				local preserve_array = not overwrite_corrupt and not repaired
					and document_shapes and document_shapes.arrays[target[id]]
				-- Combo strings keep their distinct explicit legacy migration path.
				local preserve_scalar = not overwrite_corrupt and not repaired
					and target[id] ~= nil and type(target[id]) ~= "table"
					and (section == ConfigKeys.KEY.TAP_HOLDS or (section == ConfigKeys.KEY.MOD_COMBOS and type(target[id]) ~= "string"))
				-- The user's own edit of this binding replaces its unusable value.
				if repaired and (type(target[id]) ~= "table"
					or (document_shapes and document_shapes.arrays[target[id]])) then
					target[id] = nil
				end
				if preserve_scalar or preserve_array then
					Outdated.report_in_file(user_config_path, { section, "config", id },
						(preserve_array and OUTDATED_ARRAY_REASON
							or OUTDATED_BINDING_REASON), Logger)
					for _, field in ipairs(fields) do
						local neutral = field ~= "timeout_ms" and "none" or nil
						if values[field] ~= nil and values[field] ~= neutral then
							candidate_refusal = "candidate has no explicit repair owner for " .. section .. ".config." .. id
							error(candidate_refusal, 0)
						end
					end
				else
					local entry = table_at(target, id)
					for _, field in ipairs(fields) do
						local neutral = field ~= "timeout_ms" and "none" or nil
						assign(entry, field, values[field], neutral)
					end
					if next(entry) == nil then target[id] = nil end
				end
			end
		end
		local function bindings_neutral(updates, fields)
			for id, values in pairs(updates or {}) do
				assert(type(id) == "string" and type(values) == "table", "invalid remap binding candidate")
				for _, field in ipairs(fields) do
					local neutral = field ~= "timeout_ms" and "none" or nil
					if values[field] ~= nil and values[field] ~= neutral then return false end
				end
			end
			return true
		end
		local function preserve_array(value, segments, neutral)
			if overwrite_corrupt or not document_shapes or not document_shapes.arrays[value] then return false end
			Outdated.report_in_file(user_config_path, segments,
				OUTDATED_ARRAY_REASON, Logger)
			if not neutral then
				candidate_refusal = "candidate has no explicit repair owner for " .. table.concat(segments, ".")
				error(candidate_refusal, 0)
			end
			return true
		end
		local integration = document[INTEGRATION_SECTION]
		report_retired_integration(integration, user_config_path)
		-- A settings-only candidate carries no switch: only an explicit boolean
		-- is an integration decision worth writing.
		if state.enabled ~= nil then
			assert(type(state.enabled) == "boolean", "the Karabiner integration switch must be a boolean")
			table_at(document, INTEGRATION_SECTION)[INTEGRATION_KEY] = state.enabled
		end
		-- The close consent is written once the user changed it, and kept in sync after.
		if state.close_other_instances ~= nil then
			assert(type(state.close_other_instances) == "boolean", "the close consent must be a boolean")
			if state.close_other_instances ~= M.CLOSE_OTHER_INSTANCES_DEFAULT
				or (type(integration) == "table" and integration[CLOSE_OTHER_KEY] ~= nil) then
				table_at(document, INTEGRATION_SECTION)[CLOSE_OTHER_KEY] = state.close_other_instances
			end
		end
		if not preserve_array(document.tap_holds, { ConfigKeys.KEY.TAP_HOLDS },
			(state.tap_holds_enabled == nil or state.tap_holds_enabled == Manifest.default_for(ConfigKeys.KEY.TAP_HOLDS_ENABLED))
			and (state.tap_hold_timeout_ms == nil or state.tap_hold_timeout_ms == TAP_HOLD_TIMEOUT_MS_DEFAULT)
			and (state.sticky_timeout_ms == nil or state.sticky_timeout_ms == STICKY_TIMEOUT_MS_DEFAULT)
			and (state.lone_modifier_tap_max_ms == nil
				or state.lone_modifier_tap_max_ms == M.LONE_MODIFIER_TAP_MAX_MS_DEFAULT)
			and bindings_neutral(state.tap_hold_config, { "tap", "hold", "timeout_ms" })) then
			local tap_holds = table_at(document, ConfigKeys.KEY.TAP_HOLDS)
			assign_boolean(tap_holds, ConfigKeys.KEY.TAP_HOLDS, "enabled", state.tap_holds_enabled,
				Manifest.default_for(ConfigKeys.KEY.TAP_HOLDS_ENABLED), tap_holds_switch)
			assign_timing(tap_holds, ConfigKeys.KEY.TAP_HOLDS, "timeout_ms", state.tap_hold_timeout_ms, TAP_HOLD_TIMEOUT_MS_DEFAULT)
			assign_timing(tap_holds, ConfigKeys.KEY.TAP_HOLDS, ConfigKeys.LEAF.STICKY_TIMEOUT_MS, state.sticky_timeout_ms, STICKY_TIMEOUT_MS_DEFAULT)
			-- 0 is the strict tap-hold, a choice of its own: only the default is elided.
			if state.lone_modifier_tap_max_ms ~= nil and not pcall(LoneTap.validate, state.lone_modifier_tap_max_ms) then
				candidate_refusal = "candidate has an invalid " .. ConfigKeys.KEY.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS
				error(candidate_refusal, 0)
			end
			assign_timing(tap_holds, ConfigKeys.KEY.TAP_HOLDS, ConfigKeys.LEAF.LONE_MODIFIER_TAP_MAX_MS,
				state.lone_modifier_tap_max_ms, M.LONE_MODIFIER_TAP_MAX_MS_DEFAULT, lone_tap_leaf)
			if not preserve_array(tap_holds.config, { ConfigKeys.KEY.TAP_HOLDS, "config" },
				bindings_neutral(state.tap_hold_config, { "tap", "hold", "timeout_ms" })) then
				merge_bindings(table_at(tap_holds, "config"), state.tap_hold_config, { "tap", "hold", "timeout_ms" }, ConfigKeys.KEY.TAP_HOLDS)
				if next(tap_holds.config) == nil then tap_holds.config = nil end
			end
			if next(tap_holds) == nil then document.tap_holds = nil end
		end
		if not preserve_array(document.mod_combos, { ConfigKeys.KEY.MOD_COMBOS },
			state.mod_combos_enabled == nil
			and (state.simultaneous_threshold_ms == nil or state.simultaneous_threshold_ms == SIMULTANEOUS_THRESHOLD_MS_DEFAULT)
			and (state.combo_symmetric == nil or state.combo_symmetric == COMBO_SYMMETRIC_DEFAULT)
			and bindings_neutral(state.mod_combos_config, { "tap", "hold", "combo" })) then
			local mod_combos = table_at(document, ConfigKeys.KEY.MOD_COMBOS)
			-- Written only once set: an absent flag is on (Generator.key_combinations_enabled).
			local _, outdated_enabled = combinations_enabled(mod_combos, user_config_path)
			if not overwrite_corrupt and outdated_enabled and not explicit[ConfigKeys.KEY.MOD_COMBOS_ENABLED] then
				if state.mod_combos_enabled ~= nil then
					candidate_refusal = "candidate has no explicit repair owner for mod_combos.enabled"
					error(candidate_refusal, 0)
				end
			else
				mod_combos.enabled = state.mod_combos_enabled
			end
			assign_timing(mod_combos, ConfigKeys.KEY.MOD_COMBOS, ConfigKeys.LEAF.SIMULTANEOUS_THRESHOLD_MS, state.simultaneous_threshold_ms, SIMULTANEOUS_THRESHOLD_MS_DEFAULT)
			assign_boolean(mod_combos, ConfigKeys.KEY.MOD_COMBOS, "symmetric", state.combo_symmetric,
				COMBO_SYMMETRIC_DEFAULT, combinations_symmetric)
			if not preserve_array(mod_combos.config, { ConfigKeys.KEY.MOD_COMBOS, "config" },
				bindings_neutral(state.mod_combos_config, { "tap", "hold", "combo" })) then
				merge_bindings(table_at(mod_combos, "config"), state.mod_combos_config, { "tap", "hold", "combo" }, ConfigKeys.KEY.MOD_COMBOS)
				if next(mod_combos.config) == nil then mod_combos.config = nil end
			end
			if next(mod_combos) == nil then document.mod_combos = nil end
		end
		config_rows = TapHoldFile.config_rows(config_part, document, document_shapes)
		-- Only an ordinary valid-source read owns the parsed identities. Explicit
		-- resets, absent files and backed corrupt repair start a new shared file.
		if reset_base then return TapHoldFile.encode_reset(reset_base.document, reset_base.shapes, document) end
		return TapHoldFile.encode(shared_file, document)
	end)
	if not ok or type(payload) ~= "string" then
		Logger.error(LOG, "User config candidate for '%s' refused: %s.", user_config_path,
			candidate_refusal or "the candidate could not be encoded as TOML")
		return false
	end

	-- config.toml first: its rows are what the menus show, and a tap_hold.toml
	-- refused after it is reported with both publications in the receipt.
	local companion
	if #config_rows > 0 then
		local config_expected = { status = config_source.status, content = config_source.content }
		local prepared, prepare_detail, config_candidate, prepared_source = writer().prepare_batch(config_source.path,
			config_rows, FileSystem, config_expected)
		if prepared ~= true or type(config_candidate) ~= "string" then
			Logger.error(LOG, "The tap-hold rows of '%s' cannot be prepared (%s) — settings NOT saved.",
				config_source.path, tostring(prepare_detail))
			return false
		end
		local called, published, publish_detail, config_cleanup = pcall(writer().publish_if_unchanged,
			config_source.path, config_candidate, FileSystem, prepared_source or config_expected)
		companion = { path = config_source.path, source = config_expected, candidate = config_candidate,
			verify_absence = true }
		if type(config_cleanup) == "function" then companion.publication_cleanup = config_cleanup end
		if not called or published ~= true then
			Logger.error(LOG, "Cannot publish the tap-hold rows to '%s' — settings NOT saved.", config_source.path)
			return false, tostring(called and publish_detail or published),
				type(config_cleanup) == "function" and companion or nil
		end
		adopt_config_publication(config_source.path, config_expected, config_candidate)
	end
	local publication_source = { status = source_status, content = source }
	local write_ok, written, detail, retry_cleanup = pcall(FileSystem.write_if_unchanged,
		user_config_path, payload, publication_source)
	local receipt = { path = user_config_path, source = publication_source, candidate = payload, verify_absence = true,
		companion = companion }
	if type(retry_cleanup) == "function" then receipt.publication_cleanup = retry_cleanup end
	if not write_ok or written ~= true then
		Logger.error(LOG, "Cannot atomically publish user config to '%s' — settings NOT saved.",
			user_config_path)
		-- A refusal can follow publication. Only its exact native receipt can
		-- distinguish that inverse from a proven no-effect cleanup on retry.
		return false, tostring(write_ok and detail or written),
			(type(retry_cleanup) == "function" or companion ~= nil) and receipt or nil
	end
	Logger.debug(LOG, "User config saved.")
	return true, nil, receipt
end


--- Prepares only the chord leaves from an exact fresh settings source.
--- Ordinary setters retain their existing save path and source policy.
function M.prepare_copy_taps_to_chords(entries, actions, path)
	-- The chords are config.toml rows; `path` (tap_hold.toml) stays the route identity.
	local config_path = M.config_toml_path_for(path)
	local source, status = FileSystem.read_with_status(config_path)
	assert(status == "absent" or (status == "ok" and type(source) == "string"), "fresh chord source could not be read")
	local expected = { status = status, content = source }
	local known = {}; for _, action in ipairs(actions) do known[action.id] = true end
	-- The shared file names a combination by its pair id.
	local pairs_of = {}
	for index, entry in ipairs(entries) do pairs_of[index] = { id = TapHoldFile.pair_of_combo(entry.id) } end
	local plan = require("tap_hold.engine.key_combinations").plan_chord_copy(status == "absent" and "" or source, {
		entries = pairs_of, is_action = function(action) return known[action] == true end,
		settings = { simultaneous_threshold_ms = SIMULTANEOUS_THRESHOLD_MS_DEFAULT, combo_symmetric = COMBO_SYMMETRIC_DEFAULT },
	})
	local by_combo = {}
	for pair, slots in pairs(plan.mod_combos_config) do by_combo[TapHoldFile.combo_of_pair(pair)] = slots end
	plan.mod_combos_config = by_combo
	local prepared, detail, content, witnessed = writer().prepare_batch(config_path, plan.rows, FileSystem, expected)
	assert(prepared == true and type(content) == "string" and type(witnessed) == "table", detail or "chord source preparation refused")
	plan.path, plan.config_path, plan.expected_source, plan.candidate = path, config_path, expected, content
	return plan
end

--- Publishes only the exact prepared sparse candidate; retains native cleanup debt.
function M.publish_copy_taps_to_chords(plan, current_path, admission)
	assert(type(plan) == "table" and plan.path == current_path, "chord copy route changed")
	assert(admission == nil or type(admission) == "function", "chord copy admission must be a function")
	local Writer = writer()
	local function admitted()
		if Writer.write_refusal(plan.config_path) ~= nil then return false end
		local accepted = admission == nil or admission() == true
		return accepted and Writer.write_refusal(plan.config_path) == nil
	end
	-- The shared publisher owns session refusal and requires the same native
	-- owner to run this captured admission after its final source observations.
	-- A missing admitted capability refuses; the direct writer is no substitute.
	local called, written, detail, cleanup = pcall(Writer.publish_if_unchanged,
		plan.config_path, plan.candidate, FileSystem, plan.expected_source, nil, admitted)
	local receipt = { path = plan.config_path, source = plan.expected_source, candidate = plan.candidate, verify_absence = true }
	if type(cleanup) == "function" then receipt.publication_cleanup = cleanup end
	if not called or written ~= true then return false, called and detail or written, type(cleanup) == "function" and receipt or nil end
	return true, nil, receipt
end

return M
