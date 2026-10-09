--- platform/remap/config.lua

--- ==============================================================================
--- MODULE: Karabiner Config Loader and Persistence
--- DESCRIPTION:
--- Handles all data loading and user configuration persistence for the
--- Karabiner bridge: JSON data files (actions, keys, combos), default state
--- construction, and reading/writing config_karabiner.toml.
---
--- FEATURES & RATIONALE:
--- 1. Driver-Local Data Files: platform/remap/data/ hosts actions.json,
---    tap_hold_keys.json and mod_combos.json — single source of truth for
---    available actions and keys, loaded once at startup and on every layout change.
--- 2. Layout-Aware Actions: Actions with a "logical_char" field are resolved
---    to a physical key_code via modules.keymap.layout at load time, so the KE config
---    always references the correct physical key regardless of the OS layout.
--- 3. Sparse Persistence: save_user_config() writes only non-neutral leaves
---    and preserves every field it does not own; load_user_config() reads an
---    absent table, key, slot or timing as its neutral value and upgrades the
---    legacy bare-string combo shape.
--- 4. Corruption Safety: an unparseable config_karabiner.toml is never silently
---    replaced. The read path falls back to defaults without touching the file
---    and the write path refuses to publish over it, so the user keeps a file
---    they can still repair by hand. Only an explicit reset overrides that.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local Layout = require("modules.keymap.layout")
local Paths  = require("infra.paths")
local i18n   = require("infra.i18n")
local FileSystem = require("adapters.file_system")
local JsonCodec  = require("adapters.json_codec")

local Defaults = require("platform.remap.defaults")
local ActionCatalogue = require("platform.remap.action_catalogue")
local Manifest = require("infra.manifest_reader")
local Outdated = require("config_outdated")

local LOG = "karabiner"

local TAP_HOLD_TIMEOUT_MS_DEFAULT       = Defaults.tap_hold_timeout_ms
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
	local called, value = pcall(tonumber, section[key])
	if called and value ~= nil then return value, false end
	Outdated.report_in_file(path, { section_name, key },
		"a timing is numeric; the canonical default is used", Logger)
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
	return boolean_leaf(section, "enabled", nil, path, "mod_combos",
		"a combination switch is boolean; its absent state is used")
end

--- Reads the tap-hold switch with its manifest-owned neutral value.
--- @return boolean value
--- @return boolean outdated
local function tap_holds_switch(section, path)
	return boolean_leaf(section, "enabled", Manifest.default_for("tap_holds.enabled"), path, "tap_holds",
		"a tap-hold switch is boolean; the neutral state is used")
end

--- Reads combination symmetry with its shared native default.
--- @return boolean value
--- @return boolean outdated
local function combinations_symmetric(section, path)
	return boolean_leaf(section, "symmetric", COMBO_SYMMETRIC_DEFAULT, path, "mod_combos",
		"a combination symmetry switch is boolean; the canonical default is used")
end

--- « Ergopti uses Karabiner »: `[karabiner] integration_enabled` in
--- config_karabiner.toml. On by default; off means no lease worker, no guardian
--- registration and no ErgoptiPlus rule left in karabiner.json. Karabiner
--- itself is never touched.
M.INTEGRATION_ENABLED_DEFAULT = true
local INTEGRATION_SECTION = "karabiner"
local INTEGRATION_KEY = "integration_enabled"
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
local TomlCodec = require("infra.toml.codec")

-- New refusal proofs belong only to this reader and the canonical shared parser.
-- Modeled public seams retain their original first four return values.
local parser_refusal = { decoder = rawget(TomlCodec, "decode_with_shapes") }
do
	local identity = require("module_source_identity")
	local directory = require("module_source_directory").capture()
	local expected = identity.sibling(debug.getinfo(1, "S").source,
		"macos/platform/remap/config.lua", "_shared/lua/toml_codec/codec.lua", directory)
	parser_refusal.decoder_canonical = type(parser_refusal.decoder) == "function"
		and identity.same(debug.getinfo(parser_refusal.decoder, "S").source, expected, directory)
end
local function parser_refusal_current()
	return parser_refusal.decoder_canonical and rawget(package.loaded, "platform.remap.config") == M
		and rawget(package.loaded, "infra.toml.codec") == TomlCodec
		and rawget(M, "load_user_config") == parser_refusal.reader
		and rawget(M, "_load_toml_file") == parser_refusal.loader
		and rawget(TomlCodec, "decode_with_shapes") == parser_refusal.decoder
		and rawget(M, "parser_refusal_factory") == parser_refusal.factory
end

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
	local attempt = parser_refusal.attempt
	local raw, read_status = FileSystem.read_with_status(path)
	if read_status ~= "ok" then
		if read_status == "absent" then return nil, "absent", { path = path, status = "absent" } end
		Logger.error(LOG, "Cannot read Karabiner user config; treating it as unavailable "
			.. "(failure content withheld).")
		return nil, "read_error"
	end
	local decoder_current = parser_refusal_current()
	local ok, data, shapes = pcall(TomlCodec.decode_with_shapes, raw)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Cannot parse '%s' as TOML — refusing to silently reset user config.", path)
		if decoder_current and parser_refusal_current() and attempt ~= nil
			and parser_refusal.attempt == attempt then attempt.proof = {} end
		return nil, "parse_error"
	end
	return data, nil, { path = path, status = "ok", content = raw }, shapes
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

--- Admits the one shared native selector declaration without granting runtime authority.
--- @return table|nil setting Valid enum declaration.
local function runtime_setting()
	local path = Paths.shared("platform/remap/runtime_setting.json")
	local setting = type(path) == "string" and load_json_file(path) or nil
	local fields = { ["$schema"] = true, path = true, file = true, owner = true,
		platforms = true, type = true, enum_values = true, default = true, recommended = true,
		description_key = true, unavailable_key = true }
	local function refused()
		Logger.error(LOG, "The shared native runtime selector declaration is unavailable or invalid.")
		return nil
	end
	if type(setting) ~= "table" then return refused() end
	-- The decoder owns its returned tree. Retain our own declaration before
	-- later source or encoding ports can mutate that borrowed tree.
	local admitted = {}
	for key, value in next, setting do admitted[key] = value end
	for _, key in ipairs({ "platforms", "enum_values" }) do
		local values = rawget(setting, key)
		if type(values) == "table" then
			local retained = {}
			for index, value in next, values do retained[index] = value end
			admitted[key] = retained
		end
	end
	setting = admitted
	local count = 0
	for key in pairs(setting) do
		if not fields[key] then return refused() end
		count = count + 1
	end
	if count ~= 11 or setting["$schema"] ~= "./runtime_setting.schema.json"
		or setting.path ~= "karabiner.runtime" or setting.file ~= "config_karabiner.toml"
		or setting.owner ~= "platform.remap.config" or setting.type ~= "enum"
		or type(setting.platforms) ~= "table" or setting.platforms[1] ~= "hs"
		or type(setting.enum_values) ~= "table"
		or setting.description_key ~= "menu.global.karabiner_runtime"
		or setting.unavailable_key ~= "menu.global.karabiner_runtime_unavailable" then return refused() end
	for index in pairs(setting.platforms) do
		if index ~= 1 then return refused() end
	end
	local values, size = {}, 0
	for index, value in pairs(setting.enum_values) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1
			or type(value) ~= "string" or not value:match("^[a-z][a-z0-9_]*$") or values[value] then return refused() end
		values[value], size = true, size + 1
	end
	for index = 1, size do
		if type(setting.enum_values[index]) ~= "string" then return refused() end
	end
	if size < 2 or #setting.enum_values ~= size or not values[setting.default]
		or not values[setting.recommended] then return refused() end
	return setting
end

--- Reads runtime intent with a declared missing-key default and no unsafe fallback.
--- @param section table|nil Admitted native Karabiner dictionary.
--- @param setting table Shared enum declaration.
--- @param path string Exact user settings route.
--- @return string|nil runtime Valid requested selector.
local function runtime_leaf(section, setting, path)
	local value = section and section.runtime
	if value == nil then return setting.default end
	for _, candidate in ipairs(setting.enum_values) do
		if type(value) == "string" and value == candidate then return value end
	end
	Outdated.report_in_file(path, { INTEGRATION_SECTION, "runtime" },
		"a runtime selector must be one of the declared values; native admission is refused", Logger)
	Logger.error(LOG, "The native Karabiner runtime selector is invalid; refusing the unsafe user config.")
	return nil
end

--- Appends the full shared modifier × key matrix used by gesture and tap-hold
--- action pickers. The labels come verbatim from the catalogue, so "Ctrl + A"
--- never depends on the active UI language.
-- Decoded once. The shared modifier-chord catalogue is a file on disk that does
-- not change while the driver runs, and this whole function re-ran on EVERY
-- layout change — re-reading and re-decoding the JSON to rebuild the same 673
-- action tables. Declared above the function that reads it.
local _chord_catalogue = nil

--- Replaces the hardcoded French label of any action that also exists in the one
--- action registry with its translated one.
---
--- This catalogue's entries and the rows of _shared/modules/actions/actions.toml
--- are now ONE namespace: the 18 that always overlapped, plus the 32 merged on
--- 2026-08-03, plus 4 that turned out to be Karabiner spellings of an action the
--- registry already carried (`return`≡`enter`, `delete_fwd`≡`delete`, `cmd_tab`
--- and `alt_tab_apps_list`≡`app_switcher`) and resolve through the alias table
--- rather than duplicating a translated string in twenty-one files.
---
--- The 19 that remain French are the hold-only ones — `layer`, the bare
--- modifiers and their combinations. A gesture has no duration, so they have no
--- registry row by design, not by omission.
--- @param actions table The decoded action list, mutated in place.
--- @return number localised How many labels came from the registry.
local function localise_action_labels(actions)
	local ok_reg, Registry = pcall(require, "modules.gestures.actions")
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
			local translated = i18n.get(key)
			-- i18n.get answers with the KEY when it does not resolve, which is the
			-- signal that this action has no registry row and no alias. Writing it
			-- through would put "sg_actions.hyper" in the menu.
			if translated and translated ~= key and translated ~= "" then
				action.label = translated
				action.short_label = translated
				localised = localised + 1
			end
		end
	end
	Logger.debug(LOG, "Localised %d of %d action label(s) from the shared registry.", localised, #actions)
	return localised
end

local function append_shared_modifier_chords(actions)
	local catalogue_path = Paths.shared("modules/actions/modifier_chords.json")
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
		local ids, labels, karabiner_modifiers = {}, {}, {}
		for index, modifier in ipairs(modifiers) do
			if math.floor(mask / (2 ^ (index - 1))) % 2 == 1 then
				ids[#ids + 1] = modifier.id
				labels[#labels + 1] = modifier.label
				karabiner_modifiers[#karabiner_modifiers + 1] = modifier.karabiner
			end
		end
		local id_prefix = table.concat(ids, "_")
		local label_prefix = table.concat(labels, " + ")
		for _, key_def in ipairs(keys) do
			local action = {
				id = id_prefix .. "_" .. key_def.id,
				short_label = label_prefix .. " + " .. key_def.label,
				label = label_prefix .. " + " .. key_def.label,
				category = "Keyboard shortcuts",
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

--- Loads all action definitions from platform/remap/data/actions.json.
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
--- @return number How many actions were resolved.
function M.resolve_layout_actions(list)
	if type(list) ~= "table" then
		Logger.error(LOG, "resolve_layout_actions(): expected a table — nothing resolved.")
		return 0
	end
	local resolved = 0
	for _, action in ipairs(list) do
		if action.logical_char then
			local key_code = Layout.key_code_for_char(action.logical_char)
			local mods     = action.karabiner_modifiers
			local entry    = { key_code = key_code }
			if type(mods) == "table" and #mods > 0 then
				entry.modifiers = mods
			end
			action.karabiner_to = { entry }
			resolved = resolved + 1
		end
	end
	-- One summary line, not one per action. DEBUG is this driver's default level
	-- and every layout change re-runs this loop, so per-action lines were 548 log
	-- writes for a fact the total already conveys.
	Logger.debug(LOG, "Resolved %d logical-char action(s) to key codes.", resolved)
	return resolved
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
	append_shared_modifier_chords(list)
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

--- Loads configurable key definitions from platform/remap/data/tap_hold_keys.json.
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

--- Loads modifier combo definitions from platform/remap/data/mod_combos.json.
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

	local count = 0
	for _ in pairs(non_canonical) do count = count + 1 end
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
	local setting = assert(runtime_setting(), "shared native runtime selector declaration is required")
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
		runtime                   = recommended and setting.recommended or setting.default,
		enabled                   = M.INTEGRATION_ENABLED_DEFAULT,
		tap_holds_enabled         = recommended and Manifest.recommended_for("tap_holds.enabled")
			or Manifest.default_for("tap_holds.enabled"),
		-- Absent: the key combinations are on whatever the Tap-Holds switch says
		-- (Generator.key_combinations_enabled), in the preset as on a fresh install.
		mod_combos_enabled        = nil,
		tap_hold_config           = tap_hold_config,
		mod_combos_config         = mod_combos_config,
		tap_hold_timeout_ms       = TAP_HOLD_TIMEOUT_MS_DEFAULT,
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

--- Loads config_karabiner.toml.
--- If the file is absent (first launch), builds and returns the default state.
--- A sparse file is completed with neutral values; legacy combos are upgraded.
--- @param tap_hold_keys table List from load_tap_hold_keys.
--- @param mod_combos table List from load_mod_combos.
--- @param user_config_path string Absolute path to config_karabiner.toml.
--- @return table|nil state Full state, or nil when the persisted source is unsafe.
--- @return string status One of "ok", "absent", or "error".
--- @return table|nil source Optional exact same-read path/status/raw admission receipt.
--- @return string|nil failure "parse_error" only for the actual TOML decoder refusal.
--- @return table|nil proof Opaque same-read proof only for a genuine parser refusal.
function M.load_user_config(tap_hold_keys, mod_combos, user_config_path)
	local attempt = {}
	parser_refusal.attempt = attempt
	local setting = runtime_setting()
	if not setting then return nil, "error" end
	local data, err, source, shapes = M._load_toml_file(user_config_path)

	if not data then
		if err == "parse_error" or err == "read_error" then
			if err == "parse_error" then
				return nil, "error", nil, "parse_error",
					parser_refusal_current() and parser_refusal.attempt == attempt and attempt.proof or nil
			end
			-- File exists but is corrupt: _load_toml_file already logged the
			-- error with the full path. Fall back to defaults so the driver can
			-- run, but do NOT overwrite the corrupt file.
			return nil, "error"
		end
		Logger.info(LOG, "No user config found — initializing from defaults.")
		return M.build_default_state(tap_hold_keys, mod_combos), "absent", source
	end

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
	local runtime = runtime_leaf(integration, setting, user_config_path)
	if runtime == nil then return nil, "error" end
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
		and not source_array(data.tap_holds, { "tap_holds" }) and data.tap_holds or {}
	local combos = type(data.mod_combos) == "table"
		and not source_array(data.mod_combos, { "mod_combos" }) and data.mod_combos or {}

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

	local tap_hold_config = owned_table(tap_holds, "config", "[tap_holds.config]", "tap_holds")
	for _, key_def in ipairs(tap_hold_keys) do
		if tap_hold_config[key_def.id] == nil then tap_hold_config[key_def.id] = {} end
		if source_array(tap_hold_config[key_def.id], { "tap_holds", "config", key_def.id }) then
			tap_hold_config[key_def.id] = {}
		end
		if type(tap_hold_config[key_def.id]) == "table" then
			complete_slots(tap_hold_config[key_def.id], { "tap", "hold" })
		end
	end

	local combos_config = owned_table(combos, "config", "[mod_combos.config]", "mod_combos")
	local known_combos = {}
	for _, def in ipairs(mod_combos) do known_combos[def.id] = true end
	for id, entry in pairs(combos_config) do
		if known_combos[id] and source_array(entry, { "mod_combos", "config", tostring(id) }) then
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
	drop_outdated(tap_hold_config, tap_hold_keys, "tap_holds", { "tap", "hold" })
	drop_outdated(combos_config, mod_combos, "mod_combos", { "tap", "hold", "combo" })

	-- Reads one optional number; absence is the canonical default.
	local function timing(section, key, default, label)
		local section_name = assert(label:match("^([^.]+)%."), "a timing needs its owning section")
		return timing_leaf(section, key, default, user_config_path, section_name)
	end
	local timeout_ms = timing(tap_holds, "timeout_ms", TAP_HOLD_TIMEOUT_MS_DEFAULT, "tap_holds.timeout_ms")
	local sticky_ms = timing(tap_holds, "sticky_timeout_ms", STICKY_TIMEOUT_MS_DEFAULT,
		"tap_holds.sticky_timeout_ms")
	local simultaneous_ms = timing(combos, "simultaneous_threshold_ms", SIMULTANEOUS_THRESHOLD_MS_DEFAULT,
		"mod_combos.simultaneous_threshold_ms")

	local combo_symmetric = combinations_symmetric(combos, user_config_path)

	-- Absence is neutral even when other explicit remap preferences are present.
	local tap_holds_enabled = tap_holds_switch(tap_holds, user_config_path)

	-- The key-combinations switch stays absent until the user sets it: absent,
	-- the combinations are on (Generator.key_combinations_enabled).
	local mod_combos_enabled = combinations_enabled(combos, user_config_path)

	Logger.info(LOG, "User config loaded (Ergopti uses Karabiner: %s).", tostring(integration_enabled))
	return {
		runtime                   = runtime,
		enabled                   = integration_enabled,
		tap_holds_enabled         = tap_holds_enabled,
		mod_combos_enabled        = mod_combos_enabled,
		tap_hold_config           = tap_hold_config,
		mod_combos_config         = combos_config,
		tap_hold_timeout_ms       = timeout_ms,
		sticky_timeout_ms         = sticky_ms,
		simultaneous_threshold_ms = simultaneous_ms,
		combo_symmetric           = combo_symmetric,
	}, "ok", source
end

--- Publishes one exact native configuration candidate through its existing owner.
--- @param user_config_path string Native settings route.
--- @param payload string Complete source-bound candidate.
--- @param source string|nil Exact admitted source bytes.
--- @param source_status string Classified source status.
--- @return boolean saved Actual conditional publication result.
--- @return string|nil reason Publication refusal.
--- @return table|nil receipt Exact candidate and retained native cleanup.
local function publish_config_candidate(user_config_path, payload, source, source_status)
	local publication_source = { status = source_status, content = source }
	local write_ok, written, detail, retry_cleanup = pcall(FileSystem.write_if_unchanged,
		user_config_path, payload, publication_source)
	local receipt = { path = user_config_path, source = publication_source, candidate = payload, verify_absence = true }
	if type(retry_cleanup) == "function" then receipt.publication_cleanup = retry_cleanup end
	if not write_ok or written ~= true then
		Logger.error(LOG, "Cannot atomically publish user config to '%s' — settings NOT saved.",
			user_config_path)
		-- A refusal can follow publication. Only its exact native receipt can
		-- distinguish that inverse from a proven no-effect cleanup on retry.
		return false, tostring(write_ok and detail or written),
			type(retry_cleanup) == "function" and receipt or nil
	end
	Logger.debug(LOG, "User config saved.")
	return true, nil, receipt
end

--- Persists the non-neutral state sparsely to config_karabiner.toml.
--- Refuses to publish over a file that exists but cannot be decoded as TOML:
--- load_user_config() already falls back to defaults without touching such a
--- file, so the overwrite performed by the very next setter is where the user's
--- still-recoverable tap/hold and combo configuration was actually destroyed.
--- @param state table The current module state table.
--- @param user_config_path string Absolute path to config_karabiner.toml.
--- @param overwrite_corrupt boolean|nil True only for the explicit reset-to-defaults
---        action — the one case where clobbering an unparseable file is the intent.
--- @param expected_source table|nil `{ status, content }` a scope transaction read
---        and backed up: the save refuses when the file no longer holds exactly it.
--- @return boolean True only after publication and native cleanup settle.
--- @return string|nil detail Publication refusal.
--- @return table|nil receipt Private exact source/candidate and retained native cleanup.
function M.save_user_config(state, user_config_path, overwrite_corrupt, expected_source)
	assert(expected_source == nil or (not overwrite_corrupt and type(expected_source) == "table"
		and (expected_source.status == "absent" or (expected_source.status == "ok"
			and type(expected_source.content) == "string"))), "invalid remap source precondition")
	local document = {}
	local document_shapes
	local source, source_status
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
	end

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
		local function assign_timing(target, section, key, value, neutral)
			local _, outdated = timing_leaf(target, key, neutral, user_config_path, section)
			if not overwrite_corrupt and outdated then
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
			if not overwrite_corrupt and outdated then
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
				local preserve_array = not overwrite_corrupt and document_shapes and document_shapes.arrays[target[id]]
				-- Combo strings keep their distinct explicit legacy migration path.
				local preserve_scalar = not overwrite_corrupt and target[id] ~= nil and type(target[id]) ~= "table"
					and (section == "tap_holds" or (section == "mod_combos" and type(target[id]) ~= "string"))
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
		if not preserve_array(document.tap_holds, { "tap_holds" },
			(state.tap_holds_enabled == nil or state.tap_holds_enabled == Manifest.default_for("tap_holds.enabled"))
			and (state.tap_hold_timeout_ms == nil or state.tap_hold_timeout_ms == TAP_HOLD_TIMEOUT_MS_DEFAULT)
			and (state.sticky_timeout_ms == nil or state.sticky_timeout_ms == STICKY_TIMEOUT_MS_DEFAULT)
			and bindings_neutral(state.tap_hold_config, { "tap", "hold", "timeout_ms" })) then
			local tap_holds = table_at(document, "tap_holds")
			assign_boolean(tap_holds, "tap_holds", "enabled", state.tap_holds_enabled,
				Manifest.default_for("tap_holds.enabled"), tap_holds_switch)
			assign_timing(tap_holds, "tap_holds", "timeout_ms", state.tap_hold_timeout_ms, TAP_HOLD_TIMEOUT_MS_DEFAULT)
			assign_timing(tap_holds, "tap_holds", "sticky_timeout_ms", state.sticky_timeout_ms, STICKY_TIMEOUT_MS_DEFAULT)
			if not preserve_array(tap_holds.config, { "tap_holds", "config" },
				bindings_neutral(state.tap_hold_config, { "tap", "hold", "timeout_ms" })) then
				merge_bindings(table_at(tap_holds, "config"), state.tap_hold_config, { "tap", "hold", "timeout_ms" }, "tap_holds")
				if next(tap_holds.config) == nil then tap_holds.config = nil end
			end
			if next(tap_holds) == nil then document.tap_holds = nil end
		end
		if not preserve_array(document.mod_combos, { "mod_combos" },
			state.mod_combos_enabled == nil
			and (state.simultaneous_threshold_ms == nil or state.simultaneous_threshold_ms == SIMULTANEOUS_THRESHOLD_MS_DEFAULT)
			and (state.combo_symmetric == nil or state.combo_symmetric == COMBO_SYMMETRIC_DEFAULT)
			and bindings_neutral(state.mod_combos_config, { "tap", "hold", "combo" })) then
			local mod_combos = table_at(document, "mod_combos")
			-- Written only once set: an absent flag is on (Generator.key_combinations_enabled).
			local _, outdated_enabled = combinations_enabled(mod_combos, user_config_path)
			if not overwrite_corrupt and outdated_enabled then
				if state.mod_combos_enabled ~= nil then
					candidate_refusal = "candidate has no explicit repair owner for mod_combos.enabled"
					error(candidate_refusal, 0)
				end
			else
				mod_combos.enabled = state.mod_combos_enabled
			end
			assign_timing(mod_combos, "mod_combos", "simultaneous_threshold_ms", state.simultaneous_threshold_ms, SIMULTANEOUS_THRESHOLD_MS_DEFAULT)
			assign_boolean(mod_combos, "mod_combos", "symmetric", state.combo_symmetric,
				COMBO_SYMMETRIC_DEFAULT, combinations_symmetric)
			if not preserve_array(mod_combos.config, { "mod_combos", "config" },
				bindings_neutral(state.mod_combos_config, { "tap", "hold", "combo" })) then
				merge_bindings(table_at(mod_combos, "config"), state.mod_combos_config, { "tap", "hold", "combo" }, "mod_combos")
				if next(mod_combos.config) == nil then mod_combos.config = nil end
			end
			if next(mod_combos) == nil then document.mod_combos = nil end
		end
		-- Only an ordinary valid-source read owns the parsed identities. Explicit
		-- resets, absent files and backed corrupt repair keep their default encoder.
		if document_shapes then return TomlCodec.encode_with_shapes(document, document_shapes) end
		return TomlCodec.encode(document)
	end)
	if not ok or type(payload) ~= "string" then
		Logger.error(LOG, "User config candidate for '%s' refused: %s.", user_config_path,
			candidate_refusal or "the candidate could not be encoded as TOML")
		return false
	end

	return publish_config_candidate(user_config_path, payload, source, source_status)
end

--- Publishes only the native runtime preference over an exact admitted source.
--- This settings choice grants no installed runtime or start authority.
--- @param value string Requested value from the shared declaration.
--- @param user_config_path string Exact native configuration route.
--- @param expected_source table Same-read path, status and raw source receipt.
--- @return boolean saved Actual conditional publication result.
--- @return string|nil reason Refusal or retained publication failure.
--- @return table|nil receipt Exact candidate and retained native cleanup.
function M.save_runtime(value, user_config_path, expected_source)
	-- Capture displayed-source custody before any declaration, read or log port.
	-- A caller still owns its receipt and may change it during those callbacks.
	local expected_path, expected_status, expected_content
	if type(expected_source) == "table" then
		expected_path = rawget(expected_source, "path")
		expected_status = rawget(expected_source, "status")
		expected_content = rawget(expected_source, "content")
	end
	local setting = runtime_setting()
	local accepted = false
	if setting then
		for _, candidate in ipairs(setting.enum_values) do
			if type(value) == "string" and value == candidate then accepted = true; break end
		end
	end
	if not accepted or type(user_config_path) ~= "string" or user_config_path == ""
		or type(expected_source) ~= "table" or expected_path ~= user_config_path
		or not (expected_status == "absent" and expected_content == nil
			or expected_status == "ok" and type(expected_content) == "string") then
		Logger.error(LOG, "Runtime selector publication refused an invalid candidate or source receipt.")
		return false
	end
	local document, reason, source, shapes = M._load_toml_file(user_config_path)
	if not source or source.path ~= expected_path or source.status ~= expected_status
		or source.content ~= expected_content or (not document and reason ~= "absent") then
		Logger.error(LOG, "Runtime selector publication refused an unsafe or changed native source.")
		return false
	end
	document = document or {}
	local section = document[INTEGRATION_SECTION]
	if section ~= nil and (type(section) ~= "table" or shapes and shapes.arrays[section]) then
		Logger.error(LOG, "Runtime selector publication refused a scalar or array Karabiner parent.")
		return false
	end
	local ok, payload = pcall(function()
		if value ~= setting.default then
			section = section or {}
			section.runtime = value
			document[INTEGRATION_SECTION] = section
		elseif section ~= nil then
			section.runtime = nil
			if next(section) == nil then document[INTEGRATION_SECTION] = nil end
		end
		if shapes then return TomlCodec.encode_with_shapes(document, shapes) end
		return TomlCodec.encode(document)
	end)
	if not ok or type(payload) ~= "string" then
		Logger.error(LOG, "Runtime selector candidate could not be encoded; settings were preserved.")
		return false
	end
	return publish_config_candidate(user_config_path, payload, expected_content, expected_status)
end


-- Bind the original declarations only after both public functions exist.
parser_refusal.reader, parser_refusal.loader = M.load_user_config, M._load_toml_file
local function qualify_parser_refusal(proof)
	local attempt = parser_refusal.attempt
	if not parser_refusal_current() or type(proof) ~= "table" or attempt == nil
		or attempt.proof ~= proof or attempt.consumed then return nil end
	attempt.consumed = true
	return function()
		return parser_refusal_current() and parser_refusal.attempt == attempt and attempt.proof == proof
	end
end
--- Returns the closed reader origin and inert parser-refusal qualification ports.
--- No modeled public seam, stale receipt or foreign owner issues a proof.
--- @return table origin
--- @return function reader
--- @return function loader
--- @return function decoder
--- @return function current
--- @return function qualify
parser_refusal.factory = function()
	return M, parser_refusal.reader, parser_refusal.loader, parser_refusal.decoder,
		parser_refusal_current, qualify_parser_refusal
end
M.parser_refusal_factory = parser_refusal.factory

--- Prepares only the chord leaves from an exact fresh settings source.
--- Ordinary setters retain their existing save path and source policy.
function M.prepare_copy_taps_to_chords(entries, actions, path)
	local source, status = FileSystem.read_with_status(path)
	assert(status == "absent" or (status == "ok" and type(source) == "string"), "fresh chord source could not be read")
	local expected = { status = status, content = source }
	local known = {}; for _, action in ipairs(actions) do known[action.id] = true end
	local plan = require("tap_hold.key_combinations").plan_chord_copy(status == "absent" and "" or source, {
		entries = entries, is_action = function(action) return known[action] == true end,
		settings = { simultaneous_threshold_ms = SIMULTANEOUS_THRESHOLD_MS_DEFAULT, combo_symmetric = COMBO_SYMMETRIC_DEFAULT },
	})
	local prepared, detail, content, witnessed = require("toml_codec.writer").prepare_batch(path, plan.rows, FileSystem, expected)
	assert(prepared == true and type(content) == "string" and type(witnessed) == "table", detail or "chord source preparation refused")
	plan.path, plan.expected_source, plan.candidate = path, expected, content
	return plan
end

--- Publishes only the exact prepared sparse candidate; retains native cleanup debt.
function M.publish_copy_taps_to_chords(plan, current_path, admission)
	assert(type(plan) == "table" and plan.path == current_path, "chord copy route changed")
	assert(admission == nil or type(admission) == "function", "chord copy admission must be a function")
	local Writer = require("toml_codec.writer")
	local function admitted()
		if Writer.write_refusal(plan.path) ~= nil then return false end
		local accepted = admission == nil or admission() == true
		return accepted and Writer.write_refusal(plan.path) == nil
	end
	-- The shared publisher owns session refusal and requires the same native
	-- owner to run this captured admission after its final source observations.
	-- A missing admitted capability refuses; the direct writer is no substitute.
	local called, written, detail, cleanup = pcall(Writer.publish_if_unchanged,
		plan.path, plan.candidate, FileSystem, plan.expected_source, nil, admitted)
	local receipt = { path = plan.path, source = plan.expected_source, candidate = plan.candidate, verify_absence = true }
	if type(cleanup) == "function" then receipt.publication_cleanup = cleanup end
	if not called or written ~= true then return false, called and detail or written, type(cleanup) == "function" and receipt or nil end
	return true, nil, receipt
end

return M
