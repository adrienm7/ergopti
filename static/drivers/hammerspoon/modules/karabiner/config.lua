--- modules/karabiner/config.lua

--- ==============================================================================
--- MODULE: Karabiner Config Loader and Persistence
--- DESCRIPTION:
--- Handles all data loading and user configuration persistence for the
--- Karabiner bridge: JSON data files (actions, keys, combos), default state
--- construction, and reading/writing karabiner_user_config.json.
---
--- FEATURES & RATIONALE:
--- 1. Shared Data Files: actions.json, tap_hold_keys.json and mod_combos.json
---    are the single source of truth for available actions and keys — loaded
---    once at startup and on every layout change.
--- 2. Layout-Aware Actions: Actions with a "logical_char" field are resolved
---    to a physical key_code via lib.layout at load time, so the KE config
---    always references the correct physical key regardless of the OS layout.
--- 3. Migration: load_user_config() silently upgrades legacy JSON shapes
---    (bare string, {tap,hold} without combo slot) to the current format, and
---    seeds any newly added combos from defaults so the saved file stays valid
---    across updates.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local Layout = require("lib.layout")

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

--- Loads all action definitions from data/actions.json.
--- Entries with a "logical_char" field have their "karabiner_to" resolved at load
--- time via lib.layout, so the physical key_code always matches the current OS
--- keyboard layout — no hardcoded QWERTY positions.
--- @param actions_file string Absolute path to actions.json.
--- @return table|nil List of action definitions, or nil on failure.
function M.load_available_actions(actions_file)
	local list = load_json_file(actions_file)
	if not list then
		Logger.error(LOG, "Cannot load actions — module will be non-functional.")
		return nil
	end

	-- Resolve layout-dependent actions: logical_char → physical key_code
	for _, action in ipairs(list) do
		if action.logical_char then
			local key_code = Layout.key_code_for_char(action.logical_char)
			local mods     = action.karabiner_modifiers
			local entry    = { key_code = key_code }
			if type(mods) == "table" and #mods > 0 then
				entry.modifiers = mods
			end
			action.karabiner_to = { entry }
			Logger.debug(LOG, "Action '%s': logical '%s' → key_code '%s'.",
				action.id, action.logical_char, key_code)
		end
	end

	Logger.info(LOG, "Loaded %d action(s) from actions.json.", #list)
	return list
end

--- Loads configurable key definitions from data/tap_hold_keys.json.
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

--- Loads modifier combo definitions from data/mod_combos.json.
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
	for _, key_def in ipairs(tap_hold_keys) do
		local d = Defaults.tap_hold[key_def.id]
		if not d then
			Logger.warn(LOG, "No default entry for key '%s' in defaults.lua — using none/none.", key_def.id)
		end
		tap_hold_config[key_def.id] = {
			tap  = d and d[1] or "none",
			hold = d and d[2] or "none",
		}
	end

	local mod_combos_config = {}
	for _, combo_def in ipairs(mod_combos) do
		local d = Defaults.combos[combo_def.id]
		if not d then
			Logger.warn(LOG, "No default entry for combo '%s' in defaults.lua — using none/none/none.", combo_def.id)
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

--- Loads karabiner_user_config.json.
--- If the file is absent (first launch), builds and returns the default state.
--- Silently migrates legacy JSON shapes and seeds missing combos from defaults.
--- @param tap_hold_keys table List from load_tap_hold_keys.
--- @param mod_combos table List from load_mod_combos.
--- @param user_config_path string Absolute path to karabiner_user_config.json.
--- @return table Full state: {enabled, tap_hold_config, mod_combos_config, timeouts…}
function M.load_user_config(tap_hold_keys, mod_combos, user_config_path)
	local data = load_json_file(user_config_path)

	if not data then
		Logger.info(LOG, "No user config found — initializing from defaults.")
		return M.build_default_state(tap_hold_keys, mod_combos)
	end

	local defaults = M.build_default_state(tap_hold_keys, mod_combos)

	if type(data.tap_hold_config) ~= "table" then
		Logger.warn(LOG, "Missing tap_hold_config in saved config — using defaults.")
		data.tap_hold_config = defaults.tap_hold_config
	end

	if type(data.mod_combos_config) ~= "table" then
		Logger.warn(LOG, "Missing mod_combos_config in saved config — using defaults.")
		data.mod_combos_config = defaults.mod_combos_config
	else
		-- Migrate legacy shapes to the current {tap, hold, combo} table.
		-- Oldest format: single action string (hold-only) — treat as hold slot.
		-- Previous format: {tap, hold} — add a "none" combo slot.
		for id, entry in pairs(data.mod_combos_config) do
			if type(entry) == "string" then
				Logger.info(LOG, "Migrating combo '%s' from legacy string format.", id)
				data.mod_combos_config[id] = { tap = "none", hold = entry, combo = "none" }
			elseif type(entry) == "table" and entry.combo == nil then
				Logger.info(LOG, "Migrating combo '%s' to include combo slot.", id)
				entry.combo = "none"
			end
		end
		-- Seed any combos that are missing from the persisted config (new combos added after save)
		for _, combo_def in ipairs(mod_combos) do
			if not data.mod_combos_config[combo_def.id] then
				local d = Defaults.combos[combo_def.id]
				Logger.info(LOG, "New combo '%s' not in saved config — seeding from defaults.", combo_def.id)
				data.mod_combos_config[combo_def.id] = {
					combo = d and d[1] or "none",
					tap   = d and d[2] or "none",
					hold  = d and d[3] or "none",
				}
			end
		end
	end

	-- Fields absent in old saves get the canonical default, not a silent magic number
	local timeout_ms = tonumber(data.tap_hold_timeout_ms)
	if not timeout_ms then
		Logger.warn(LOG, "Missing tap_hold_timeout_ms in saved config — using default (%d ms).",
			TAP_HOLD_TIMEOUT_MS_DEFAULT)
		timeout_ms = TAP_HOLD_TIMEOUT_MS_DEFAULT
	end

	local sticky_ms = tonumber(data.sticky_timeout_ms)
	if not sticky_ms then
		Logger.warn(LOG, "Missing sticky_timeout_ms in saved config — using default (%d ms).",
			STICKY_TIMEOUT_MS_DEFAULT)
		sticky_ms = STICKY_TIMEOUT_MS_DEFAULT
	end

	local simultaneous_ms = tonumber(data.simultaneous_threshold_ms)
	if not simultaneous_ms then
		Logger.warn(LOG, "Missing simultaneous_threshold_ms in saved config — using default (%d ms).",
			SIMULTANEOUS_THRESHOLD_MS_DEFAULT)
		simultaneous_ms = SIMULTANEOUS_THRESHOLD_MS_DEFAULT
	end

	local combo_symmetric
	if data.combo_symmetric == nil then
		Logger.warn(LOG, "Missing combo_symmetric in saved config — using default (%s).",
			tostring(COMBO_SYMMETRIC_DEFAULT))
		combo_symmetric = COMBO_SYMMETRIC_DEFAULT
	else
		combo_symmetric = data.combo_symmetric == true
	end

	Logger.info(LOG, "User config loaded.")
	return {
		enabled                   = data.enabled == true,
		tap_hold_config           = data.tap_hold_config,
		mod_combos_config         = data.mod_combos_config,
		tap_hold_timeout_ms       = timeout_ms,
		sticky_timeout_ms         = sticky_ms,
		simultaneous_threshold_ms = simultaneous_ms,
		combo_symmetric           = combo_symmetric,
	}
end

--- Persists the current full state to karabiner_user_config.json.
--- @param state table The current module state table.
--- @param user_config_path string Absolute path to karabiner_user_config.json.
function M.save_user_config(state, user_config_path)
	local payload = hs.json.encode({
		enabled                   = state.enabled,
		tap_hold_config           = state.tap_hold_config,
		mod_combos_config         = state.mod_combos_config,
		tap_hold_timeout_ms       = state.tap_hold_timeout_ms,
		sticky_timeout_ms         = state.sticky_timeout_ms,
		simultaneous_threshold_ms = state.simultaneous_threshold_ms,
		combo_symmetric           = state.combo_symmetric,
	}, true)

	local fh = io.open(user_config_path, "w")
	if not fh then
		Logger.error(LOG, "Cannot write user config at '%s'.", user_config_path)
		return
	end
	fh:write(payload)
	fh:close()
	Logger.debug(LOG, "User config saved.")
end

return M
