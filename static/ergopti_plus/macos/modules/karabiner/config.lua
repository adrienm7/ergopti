--- modules/karabiner/config.lua

--- ==============================================================================
--- MODULE: Karabiner Config Loader and Persistence
--- DESCRIPTION:
--- Handles all data loading and user configuration persistence for the
--- Karabiner bridge: JSON data files (actions, keys, combos), default state
--- construction, and reading/writing config_karabiner.toml.
---
--- FEATURES & RATIONALE:
--- 1. Driver-Local Data Files: modules/karabiner/data/ hosts actions.json,
---    tap_hold_keys.json and mod_combos.json — single source of truth for
---    available actions and keys, loaded once at startup and on every layout change.
--- 2. Layout-Aware Actions: Actions with a "logical_char" field are resolved
---    to a physical key_code via lib.layout at load time, so the KE config
---    always references the correct physical key regardless of the OS layout.
--- 3. Migration: load_user_config() silently upgrades legacy JSON shapes
---    (bare string, {tap,hold} without combo slot) to the current format, and
---    seeds any newly added combos from defaults so the saved file stays valid
---    across updates.
--- 4. Corruption Safety: an unparseable config_karabiner.toml is never silently
---    replaced. The read path falls back to defaults without touching the file
---    and the write path refuses to publish over it, so the user keeps a file
---    they can still repair by hand. Only an explicit reset overrides that.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local Layout = require("lib.layout")
local Paths  = require("lib.paths")

local Defaults = require("modules.karabiner.defaults")

local LOG = "karabiner"

local TAP_HOLD_TIMEOUT_MS_DEFAULT       = Defaults.tap_hold_timeout_ms
local STICKY_TIMEOUT_MS_DEFAULT         = Defaults.sticky_timeout_ms
local SIMULTANEOUS_THRESHOLD_MS_DEFAULT = Defaults.simultaneous_threshold_ms
local COMBO_SYMMETRIC_DEFAULT           = Defaults.combo_symmetric





-- ====================================
-- ====================================
-- ======= 1/ JSON Data Loaders =======
-- ====================================
-- ====================================

--- Loads and parses a JSON file. Logs an error and returns nil on any failure.
--- @param path string Absolute path to the JSON file.
--- @return table|nil Decoded table, or nil.
local TomlCodec = require("lib.toml.codec")

--- Load a TOML user-config file.
--- Returns the decoded table on success, nil when the file is genuinely absent,
--- and nil,'parse_error' when the file exists but cannot be decoded as TOML
--- (so callers can distinguish first-launch from corruption).
function M._load_toml_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local raw = fh:read("*a"); fh:close()
	local ok, data = pcall(TomlCodec.decode, raw)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Cannot parse '%s' as TOML — refusing to silently reset user config.", path)
		return nil, "parse_error"
	end
	return data
end

local function load_json_file(path)
	local fh = io.open(path, "r")
	if not fh then
		Logger.error(LOG, "Cannot open file '%s'.", path)
		return nil
	end
	local raw = fh:read("*a")
	fh:close()
	local ok, data = pcall(hs.json.decode, raw)
	if not ok or type(data) ~= "table" then
		Logger.error(LOG, "Cannot decode JSON from '%s': %s.", path, tostring(data))
		return nil
	end
	return data
end

--- Appends the full shared modifier × key matrix used by gesture and tap-hold
--- action pickers. The labels come verbatim from the catalogue, so "Ctrl + A"
--- never depends on the active UI language.
-- Decoded once. The shared modifier-chord catalogue is a file on disk that does
-- not change while the driver runs, and this whole function re-ran on EVERY
-- layout change — re-reading and re-decoding the JSON to rebuild the same 673
-- action tables. Declared above the function that reads it.
local _chord_catalogue = nil

local function append_shared_modifier_chords(actions)
	local catalogue_path = Paths.shared("modules/gestures/modifier_chords.json")
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

--- Loads all action definitions from modules/karabiner/data/actions.json.
--- Entries with a "logical_char" field have their "karabiner_to" resolved at load
--- time via lib.layout, so the physical key_code always matches the current OS
--- keyboard layout — no hardcoded QWERTY positions.
--- @param actions_file string Absolute path to actions.json.
--- @return table|nil List of action definitions, or nil on failure.
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
	append_shared_modifier_chords(list)
	M.resolve_layout_actions(list)

	_cached_actions = list
	Logger.info(LOG, "Loaded %d action(s) from actions.json.", #list)
	return list
end

--- Loads configurable key definitions from modules/karabiner/data/tap_hold_keys.json.
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

--- Loads modifier combo definitions from modules/karabiner/data/mod_combos.json.
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
function M.build_default_state(tap_hold_keys, mod_combos)
	local tap_hold_config = {}
	for _, key_def in ipairs(tap_hold_keys or {}) do
		local d = Defaults.tap_hold[key_def.id]
		if not d then
			Logger.warn(LOG, "No default entry for key '%s' in the shared tap-hold defaults (defaults.toml) — using none/none.", key_def.id)
		end
		tap_hold_config[key_def.id] = {
			tap  = d and d[1] or "none",
			hold = d and d[2] or "none",
		}
	end

	local mod_combos_config = {}
	for _, combo_def in ipairs(mod_combos or {}) do
		local d = Defaults.combos[combo_def.id]
		if not d then
			Logger.warn(LOG, "No default entry for combo '%s' in the shared tap-hold defaults (defaults.toml) — using none/none/none.", combo_def.id)
		end
		mod_combos_config[combo_def.id] = {
			combo = d and d[1] or "none",
			tap   = d and d[2] or "none",
			hold  = d and d[3] or "none",
		}
	end

	return {
		enabled                   = false,
		tap_hold_config           = tap_hold_config,
		mod_combos_config         = mod_combos_config,
		tap_hold_timeout_ms       = TAP_HOLD_TIMEOUT_MS_DEFAULT,
		sticky_timeout_ms         = STICKY_TIMEOUT_MS_DEFAULT,
		simultaneous_threshold_ms = SIMULTANEOUS_THRESHOLD_MS_DEFAULT,
		combo_symmetric           = COMBO_SYMMETRIC_DEFAULT,
	}
end





-- ==========================================
-- ==========================================
-- ======= 3/ User Config Persistence =======
-- ==========================================
-- ==========================================

--- Loads config_karabiner.toml.
--- If the file is absent (first launch), builds and returns the default state.
--- Silently migrates legacy JSON shapes and seeds missing combos from defaults.
--- @param tap_hold_keys table List from load_tap_hold_keys.
--- @param mod_combos table List from load_mod_combos.
--- @param user_config_path string Absolute path to config_karabiner.toml.
--- @return table Full state: {enabled, tap_hold_config, mod_combos_config, timeouts…}
function M.load_user_config(tap_hold_keys, mod_combos, user_config_path)
	local data, err = M._load_toml_file(user_config_path)

	if not data then
		if err == "parse_error" then
			-- File exists but is corrupt: _load_toml_file already logged the
			-- error with the full path. Fall back to defaults so the driver can
			-- run, but do NOT overwrite the corrupt file.
			return M.build_default_state(tap_hold_keys, mod_combos)
		end
		Logger.info(LOG, "No user config found — initializing from defaults.")
		return M.build_default_state(tap_hold_keys, mod_combos)
	end

	local defaults = M.build_default_state(tap_hold_keys, mod_combos)
	local tap_holds = type(data.tap_holds) == "table" and data.tap_holds or {}
	local combos    = type(data.mod_combos) == "table" and data.mod_combos or {}

	if type(tap_holds.config) ~= "table" then
		Logger.warn(LOG, "Missing tap_hold_config in saved config — using defaults.")
		tap_holds.config = defaults.tap_hold_config
	else
		-- Seed any tap/hold keys missing from the persisted config (new keys added after save)
		for _, key_def in ipairs(tap_hold_keys) do
			if not tap_holds.config[key_def.id] then
				local d = Defaults.tap_hold[key_def.id]
				Logger.info(LOG, "New tap/hold key '%s' not in saved config — seeding from defaults.", key_def.id)
				tap_holds.config[key_def.id] = {
					tap  = d and d[1] or "none",
					hold = d and d[2] or "none",
				}
			end
		end
	end

	if type(combos.config) ~= "table" then
		Logger.warn(LOG, "Missing mod_combos_config in saved config — using defaults.")
		combos.config = defaults.mod_combos_config
	else
		for id, entry in pairs(combos.config) do
			if type(entry) == "string" then
				Logger.info(LOG, "Migrating combo '%s' from legacy string format.", id)
				combos.config[id] = { tap = "none", hold = entry, combo = "none" }
			elseif type(entry) == "table" and entry.combo == nil then
				Logger.info(LOG, "Migrating combo '%s' to include combo slot.", id)
				entry.combo = "none"
			end
		end
		-- Seed any combos that are missing from the persisted config (new combos added after save)
		for _, combo_def in ipairs(mod_combos) do
			if not combos.config[combo_def.id] then
				local d = Defaults.combos[combo_def.id]
				Logger.info(LOG, "New combo '%s' not in saved config — seeding from defaults.", combo_def.id)
				combos.config[combo_def.id] = {
					combo = d and d[1] or "none",
					tap   = d and d[2] or "none",
					hold  = d and d[3] or "none",
				}
			end
		end
	end

	-- Fields absent in old saves get the canonical default, not a silent magic number
	local timeout_ms = tonumber(tap_holds.timeout_ms)
	if not timeout_ms then
		Logger.warn(LOG, "Missing tap_hold_timeout_ms in saved config — using default (%d ms).",
			TAP_HOLD_TIMEOUT_MS_DEFAULT)
		timeout_ms = TAP_HOLD_TIMEOUT_MS_DEFAULT
	end

	local sticky_ms = tonumber(tap_holds.sticky_timeout_ms)
	if not sticky_ms then
		Logger.warn(LOG, "Missing sticky_timeout_ms in saved config — using default (%d ms).",
			STICKY_TIMEOUT_MS_DEFAULT)
		sticky_ms = STICKY_TIMEOUT_MS_DEFAULT
	end

	local simultaneous_ms = tonumber(combos.simultaneous_threshold_ms)
	if not simultaneous_ms then
		Logger.warn(LOG, "Missing simultaneous_threshold_ms in saved config — using default (%d ms).",
			SIMULTANEOUS_THRESHOLD_MS_DEFAULT)
		simultaneous_ms = SIMULTANEOUS_THRESHOLD_MS_DEFAULT
	end

	local combo_symmetric
	if combos.symmetric == nil then
		Logger.warn(LOG, "Missing combo_symmetric in saved config — using default (%s).",
			tostring(COMBO_SYMMETRIC_DEFAULT))
		combo_symmetric = COMBO_SYMMETRIC_DEFAULT
	else
		combo_symmetric = combos.symmetric == true
	end

	Logger.info(LOG, "User config loaded.")
	-- Support both formats: new [karabiner] section and legacy root-level key
	local karabiner_section = type(data.karabiner) == "table" and data.karabiner or data
	return {
		enabled                   = karabiner_section.enabled == true,
		tap_hold_config           = tap_holds.config,
		mod_combos_config         = combos.config,
		tap_hold_timeout_ms       = timeout_ms,
		sticky_timeout_ms         = sticky_ms,
		simultaneous_threshold_ms = simultaneous_ms,
		combo_symmetric           = combo_symmetric,
	}
end

--- Persists the current full state to config_karabiner.toml.
--- Refuses to publish over a file that exists but cannot be decoded as TOML:
--- load_user_config() already falls back to defaults without touching such a
--- file, so the overwrite performed by the very next setter is where the user's
--- still-recoverable tap/hold and combo configuration was actually destroyed.
--- @param state table The current module state table.
--- @param user_config_path string Absolute path to config_karabiner.toml.
--- @param overwrite_corrupt boolean|nil True only for the explicit reset-to-defaults
---        action — the one case where clobbering an unparseable file is the intent.
--- @return boolean True when the state reached disk, false when nothing was saved.
function M.save_user_config(state, user_config_path, overwrite_corrupt)
	if not overwrite_corrupt then
		-- Re-reading before every save is cheap (a few KB, only on user action)
		-- and is the only way to notice that the file went bad since boot.
		local _, err = M._load_toml_file(user_config_path)
		if err == "parse_error" then
			Logger.error(LOG, "Refusing to overwrite the unparseable user config at '%s' — settings NOT saved. Repair or delete the file, or reset the Karabiner settings to defaults to rewrite it.",
				user_config_path)
			return false
		end
	end

	local ok, payload = pcall(TomlCodec.encode, {
		karabiner = {
			enabled = state.enabled == true,
		},
		tap_holds = {
			config = state.tap_hold_config or {},
			timeout_ms = state.tap_hold_timeout_ms,
			sticky_timeout_ms = state.sticky_timeout_ms,
		},
		mod_combos = {
			config = state.mod_combos_config or {},
			simultaneous_threshold_ms = state.simultaneous_threshold_ms,
			symmetric = state.combo_symmetric == true,
		},
	})
	if not ok or type(payload) ~= "string" then
		Logger.error(LOG, "Failed to encode user config as TOML.")
		return false
	end

	-- Atomic write via .tmp + rename.
	local tmp = user_config_path .. ".tmp"
	local fh  = io.open(tmp, "w")
	if not fh then
		Logger.error(LOG, "Cannot write user config at '%s'.", user_config_path)
		return false
	end
	fh:write(payload); fh:close()
	-- This is the ONLY persistence path for every Karabiner setting, and the
	-- rename is the step that actually publishes them. Discarding its result and
	-- logging success unconditionally meant a failed save was indistinguishable
	-- from a successful one until the next boot restored the old file.
	local ok_rename, renamed = pcall(os.rename, tmp, user_config_path)
	if not ok_rename or not renamed then
		Logger.error(LOG, "Cannot publish user config to '%s' — settings NOT saved (staged at '%s').",
			user_config_path, tmp)
		return false
	end
	Logger.debug(LOG, "User config saved.")
	return true
end

return M
