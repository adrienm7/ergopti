--- modules/karabiner/init.lua

--- ==============================================================================
--- MODULE: Karabiner Elements Bridge
--- DESCRIPTION:
--- Bridge between Hammerspoon and Karabiner-Elements. Orchestrates all
--- sub-modules: process lifecycle, JSON generation, config persistence, and
--- event watchers. Exposes the full public API consumed by menu_karabiner.lua.
---
--- FEATURES & RATIONALE:
--- 1. CapsWord Watcher: Detects trackpad scroll/gesture events and deactivates
---    CapsWord so the user never gets stuck in caps mode after using the trackpad.
--- 2. User Config: karabiner_user_config.json is the single runtime truth.
---    On first launch it is created from defaults; after that it is the full
---    persisted state — defaults are never recomputed at runtime except when
---    the user explicitly clicks "Reset to defaults".
--- 3. Shared Action Dictionary: Loads data/actions.json so the menu always
---    lists exactly the same actions, with zero duplication.
--- 4. Modifier Combos: data/mod_combos.json defines all available two-modifier
---    combos. Each combo maps to tap, hold, and chord slots.
--- 5. Inline Generation: karabiner.json is built directly in Lua from in-memory
---    state — no Python subprocess, no external dependency.
--- 6. Deployment: The generated file is copied to the Karabiner-Elements config
---    directory via two sequential strategies, each logged separately.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("lib.logger")
local Defaults    = require("modules.karabiner.defaults")
local Config      = require("modules.karabiner.config")
local Generator   = require("modules.karabiner.generator")
local KeLifecycle = require("modules.karabiner.ke_lifecycle")
local Watchers    = require("modules.karabiner.watchers")

-- Optional: keylogger may not be loaded in all deployments
local ok_kcb, KcBridge = pcall(require, "modules.keylogger.kc_bridge")
if not ok_kcb then KcBridge = nil end

local LOG = "karabiner"

-- Resolve the directory that contains this init.lua at load time.
-- Works whether the file is symlinked, run from the project, or deployed.
local _SELF_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./")

local KARABINER_OUT   = os.getenv("HOME") .. "/.config/karabiner/karabiner.json"

-- Go up from modules/karabiner/ to the Hammerspoon config root so generated
-- and user files are kept at the root level, not buried in the module.
local HS_ROOT       = _SELF_DIR .. "../../"
local KARABINER_GEN = HS_ROOT .. "karabiner.json"
local USER_CONFIG   = HS_ROOT .. "karabiner_user_config.json"
local ACTIONS_FILE    = _SELF_DIR .. "data/actions.json"
local TAP_HOLD_FILE   = _SELF_DIR .. "data/tap_hold_keys.json"
local MOD_COMBOS_FILE = _SELF_DIR .. "data/mod_combos.json"

-- Re-export defaults as module constants so callers (e.g. the menu) have a
-- single import path and never need to require defaults.lua themselves.
M.DEFAULT_TAP_HOLD_TIMEOUT_MS       = Defaults.tap_hold_timeout_ms
M.DEFAULT_STICKY_TIMEOUT_MS         = Defaults.sticky_timeout_ms
M.DEFAULT_SIMULTANEOUS_THRESHOLD_MS = Defaults.simultaneous_threshold_ms
M.DEFAULT_COMBO_SYMMETRIC           = Defaults.combo_symmetric

--- Non-canonical combo IDs: populated by M.init() after loading mod_combos.json.
--- A combo is non-canonical when its reverse (same two keys in opposite order)
--- appears earlier in MOD_COMBOS. Used to hide redundant entries in symmetric mode.
M.NON_CANONICAL_COMBOS = {}

--- Populated by M.init() from data/actions.json (shared with other tools).
M.AVAILABLE_ACTIONS = {}

--- Populated by M.init() from data/tap_hold_keys.json (shared with other tools).
--- Each entry carries default_tap and default_hold for first-launch init and reset.
M.TAP_HOLD_KEYS = {}

--- Populated by M.init() from data/mod_combos.json.
--- Each entry defines a two-modifier simultaneous combo the user can map to an action.
M.MOD_COMBOS = {}

-- Minimal karabiner.json deployed on pause: same profile structure as normal but
-- with zero rules, so KE's FSEvents watcher reloads and applies no remapping.
-- Daemons stay alive — no process kill, no restart, no Space switch.
local EMPTY_KE_CONFIG = {
	profiles = {
		{
			complex_modifications = { rules = {} },
			devices              = { { identifiers = { is_keyboard = true }, simple_modifications = {} } },
			name                 = "Default profile",
			selected             = true,
			virtual_hid_keyboard = { country_code = 0, keyboard_type_v2 = "ansi" },
		}
	}
}

local _state = nil

local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — module not initialized.", func_name)
		return false
	end
	return true
end


--- Stops the KE GUI suppressor watcher, if active.
function M.stop_gui_suppressor() KeLifecycle.stop_gui_suppressor() end

--- Opens the Karabiner-Elements GUI for the user.
--- Stops the startup suppressor first so the watcher does not fight the launch.
function M.open_gui() KeLifecycle.open_gui() end

--- Ensures Karabiner-Elements background services are running.
--- @return boolean True if services are running after this call.
function M.launch_headless() return KeLifecycle.launch_headless() end




-- ===============================================
-- ===============================================
-- ======= 1/ State Accessors and Mutators =======
-- ===============================================
-- ===============================================

--- Returns true when the Karabiner integration is enabled.
--- @return boolean
function M.get_enabled()
	if not _state then return false end
	return _state.enabled == true
end

--- Enables or disables the Karabiner integration and persists the choice.
--- When enabling, Karabiner-Elements is launched in the background.
--- When disabling, Karabiner-Elements is quit.
--- @param value boolean
function M.set_enabled(value)
	if not require_state("set_enabled") then return end
	_state.enabled = value == true
	Logger.info(LOG, "Karabiner integration %s.", _state.enabled and "enabled" or "disabled")
	Config.save_user_config(_state, USER_CONFIG)
	if _state.enabled then
		KeLifecycle.launch_headless()
	else
		hs.execute("osascript -e 'tell application \"Karabiner-Elements\" to quit' 2>/dev/null")
	end
end


--- Returns the current tap action id for a key.
--- @param key_id string Key id as defined in tap_hold_keys.json.
--- @return string action_id
function M.get_tap_action(key_id)
	if not require_state("get_tap_action") then return "none" end
	local cfg = _state.tap_hold_config[key_id]
	return cfg and cfg.tap or "none"
end

--- Returns the current hold action id for a key.
--- @param key_id string Key id as defined in tap_hold_keys.json.
--- @return string action_id
function M.get_hold_action(key_id)
	if not require_state("get_hold_action") then return "none" end
	local cfg = _state.tap_hold_config[key_id]
	return cfg and cfg.hold or "none"
end

--- Sets the tap action for a key and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param key_id string Key id.
--- @param action_id string Action id from actions.json.
function M.set_tap_action(key_id, action_id)
	if not require_state("set_tap_action") then return end
	local cfg = _state.tap_hold_config[key_id] or {}
	_state.tap_hold_config[key_id] = { tap = action_id, hold = cfg.hold or "none" }
	Logger.debug(LOG, "Key '%s' tap → '%s'.", key_id, action_id)
	Config.save_user_config(_state, USER_CONFIG)
end

--- Sets the hold action for a key and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param key_id string Key id.
--- @param action_id string Action id from actions.json.
function M.set_hold_action(key_id, action_id)
	if not require_state("set_hold_action") then return end
	local cfg = _state.tap_hold_config[key_id] or {}
	_state.tap_hold_config[key_id] = { tap = cfg.tap or "none", hold = action_id }
	Logger.debug(LOG, "Key '%s' hold → '%s'.", key_id, action_id)
	Config.save_user_config(_state, USER_CONFIG)
end


--- Returns the tap action id for a modifier combo.
--- @param combo_id string Combo id.
--- @return string action_id
function M.get_combo_tap_action(combo_id)
	if not require_state("get_combo_tap_action") then return "none" end
	local cfg = _state.mod_combos_config[combo_id]
	return (type(cfg) == "table" and cfg.tap) or "none"
end

--- Returns the hold action id for a modifier combo.
--- @param combo_id string Combo id.
--- @return string action_id
function M.get_combo_hold_action(combo_id)
	if not require_state("get_combo_hold_action") then return "none" end
	local cfg = _state.mod_combos_config[combo_id]
	return (type(cfg) == "table" and cfg.hold) or "none"
end

--- Returns the chord action id for a modifier combo.
--- @param combo_id string Combo id.
--- @return string action_id
function M.get_combo_combo_action(combo_id)
	if not require_state("get_combo_combo_action") then return "none" end
	local cfg = _state.mod_combos_config[combo_id]
	return (type(cfg) == "table" and cfg.combo) or "none"
end

--- Returns a fresh {tap, hold, combo} table cloning the current slots except
--- the one being overwritten. Avoids mutating shared references and keeps the
--- three setters symmetric.
--- @param combo_id string Combo id.
--- @param slot string Slot being written ("tap" | "hold" | "combo").
--- @param action_id string New action id for that slot.
--- @return table Updated slot table.
local function update_combo_slot(combo_id, slot, action_id)
	local cfg   = _state.mod_combos_config[combo_id]
	local tap   = (type(cfg) == "table" and cfg.tap)   or "none"
	local hold  = (type(cfg) == "table" and cfg.hold)  or "none"
	local combo = (type(cfg) == "table" and cfg.combo) or "none"
	if     slot == "tap"   then tap   = action_id
	elseif slot == "hold"  then hold  = action_id
	elseif slot == "combo" then combo = action_id
	end
	return { tap = tap, hold = hold, combo = combo }
end

--- Sets the tap action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_tap_action(combo_id, action_id)
	if not require_state("set_combo_tap_action") then return end
	_state.mod_combos_config[combo_id] = update_combo_slot(combo_id, "tap", action_id)
	Logger.debug(LOG, "Combo '%s' tap → '%s'.", combo_id, action_id)
	Config.save_user_config(_state, USER_CONFIG)
end

--- Sets the hold action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_hold_action(combo_id, action_id)
	if not require_state("set_combo_hold_action") then return end
	_state.mod_combos_config[combo_id] = update_combo_slot(combo_id, "hold", action_id)
	Logger.debug(LOG, "Combo '%s' hold → '%s'.", combo_id, action_id)
	Config.save_user_config(_state, USER_CONFIG)
end

--- Sets the chord action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_combo_action(combo_id, action_id)
	if not require_state("set_combo_combo_action") then return end
	_state.mod_combos_config[combo_id] = update_combo_slot(combo_id, "combo", action_id)
	Logger.debug(LOG, "Combo '%s' combo → '%s'.", combo_id, action_id)
	Config.save_user_config(_state, USER_CONFIG)
end


--- Returns the current tap / hold timeout in milliseconds.
--- Maps to KE's basic.to_if_alone_timeout_milliseconds.
--- @return number milliseconds
function M.get_tap_hold_timeout()
	if not require_state("get_tap_hold_timeout") then return nil end
	return _state.tap_hold_timeout_ms
end

--- Sets the tap / hold timeout and persists it.
--- Logs an error and returns without saving if the value is invalid.
--- @param ms number Timeout in milliseconds (must be a positive integer).
function M.set_tap_hold_timeout(ms)
	if not require_state("set_tap_hold_timeout") then return end
	local value = tonumber(ms)
	if not value or value <= 0 then
		Logger.error(LOG, "set_tap_hold_timeout: invalid value '%s' — ignoring.", tostring(ms))
		return
	end
	_state.tap_hold_timeout_ms = math.floor(value)
	Logger.debug(LOG, "Tap/hold timeout: %d ms.", _state.tap_hold_timeout_ms)
	Config.save_user_config(_state, USER_CONFIG)
end

--- Returns the sticky/one-shot modifier timeout in milliseconds.
--- @return number milliseconds
function M.get_sticky_timeout()
	if not require_state("get_sticky_timeout") then return nil end
	return _state.sticky_timeout_ms
end

--- Sets the sticky modifier timeout and persists it.
--- Logs an error and returns without saving if the value is invalid.
--- @param ms number Timeout in milliseconds (must be a positive integer).
function M.set_sticky_timeout(ms)
	if not require_state("set_sticky_timeout") then return end
	local value = tonumber(ms)
	if not value or value <= 0 then
		Logger.error(LOG, "set_sticky_timeout: invalid value '%s' — ignoring.", tostring(ms))
		return
	end
	_state.sticky_timeout_ms = math.floor(value)
	Logger.debug(LOG, "Sticky timeout: %d ms.", _state.sticky_timeout_ms)
	Config.save_user_config(_state, USER_CONFIG)
end

--- Returns the current simultaneous-combo threshold in milliseconds.
--- @return number milliseconds
function M.get_simultaneous_threshold()
	if not require_state("get_simultaneous_threshold") then return nil end
	return _state.simultaneous_threshold_ms
end

--- Sets the simultaneous-combo threshold and persists it.
--- Logs an error and returns without saving if the value is invalid.
--- @param ms number Threshold in milliseconds (must be a positive integer).
function M.set_simultaneous_threshold(ms)
	if not require_state("set_simultaneous_threshold") then return end
	local value = tonumber(ms)
	if not value or value <= 0 then
		Logger.error(LOG, "set_simultaneous_threshold: invalid value '%s' — ignoring.", tostring(ms))
		return
	end
	_state.simultaneous_threshold_ms = math.floor(value)
	Logger.debug(LOG, "Simultaneous threshold: %d ms.", _state.simultaneous_threshold_ms)
	Config.save_user_config(_state, USER_CONFIG)
end

--- Returns true when combo symmetric mode is active (A+B = B+A).
--- @return boolean
function M.get_combo_symmetric()
	if not require_state("get_combo_symmetric") then return false end
	return _state.combo_symmetric == true
end

--- Sets combo symmetric mode and persists it.
--- When true, key_down_order: "strict" is removed from chord rules so A+B and
--- B+A fire the same action. Non-canonical (reverse) combos are also suppressed
--- in the KE config and in the menu.
--- @param value boolean
function M.set_combo_symmetric(value)
	if not require_state("set_combo_symmetric") then return end
	_state.combo_symmetric = value == true
	Logger.debug(LOG, "Combo symmetric: %s.", tostring(_state.combo_symmetric))
	Config.save_user_config(_state, USER_CONFIG)
end

--- Resets all settings to their defaults and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
function M.reset_to_defaults()
	if not require_state("reset_to_defaults") then return end
	Logger.start(LOG, "Resetting all settings to defaults…")
	local defaults                   = Config.build_default_state(M.TAP_HOLD_KEYS, M.MOD_COMBOS)
	_state.tap_hold_config           = defaults.tap_hold_config
	_state.mod_combos_config         = defaults.mod_combos_config
	_state.tap_hold_timeout_ms       = defaults.tap_hold_timeout_ms
	_state.sticky_timeout_ms         = defaults.sticky_timeout_ms
	_state.simultaneous_threshold_ms = defaults.simultaneous_threshold_ms
	_state.combo_symmetric           = defaults.combo_symmetric
	Config.save_user_config(_state, USER_CONFIG)
	Logger.success(LOG, "All settings reset to defaults.")
end




-- =================================================
-- =================================================
-- ======= 2/ Regeneration, Pause and Resume =======
-- =================================================
-- =================================================

--- Builds karabiner.json from the current in-memory state and deploys it to
--- the Karabiner-Elements config directory.
--- Only the complex_modifications section is replaced; all other KE settings
--- (devices, fn_function_keys, simple_modifications, global flags) are preserved.
--- Karabiner-Elements is fully stopped before the file is replaced and relaunched
--- afterwards, guaranteeing our deploy is never overwritten by a live KE process.
function M.regenerate()
	if not require_state("regenerate") then return end
	Logger.start(LOG, "Regenerating Karabiner config…")

	local ok_build, result = pcall(
		Generator.build_karabiner_json,
		_state, M.AVAILABLE_ACTIONS, M.TAP_HOLD_KEYS, M.MOD_COMBOS, M.NON_CANONICAL_COMBOS, _SELF_DIR
	)
	if not ok_build then
		Logger.error(LOG, "JSON generation failed: %s.", tostring(result))
		return
	end

	local merged   = Generator.merge_into_existing_config(result, KARABINER_OUT)
	local json_str = hs.json.encode(merged, true)

	local fh = io.open(KARABINER_GEN, "w")
	if not fh then
		Logger.error(LOG, "Cannot write generated config at '%s'.", KARABINER_GEN)
		return
	end
	fh:write(json_str)
	fh:close()

	-- Stop KE completely before writing: otherwise a live session_monitor or an
	-- open Preferences window may rewrite karabiner.json from its cached state
	-- within seconds, silently reverting our menu changes.
	Logger.trace(LOG, "Stopping Karabiner-Elements before deploy…")
	pcall(function() hs.execute(KeLifecycle.KILL_CMD) end)
	Logger.done(LOG, "Karabiner-Elements stopped.")

	local ok_copy, cp_detail = Generator.deploy_file(KARABINER_GEN, KARABINER_OUT)
	if not ok_copy then
		Logger.error(LOG, "Deploy failed → '%s': %s.", KARABINER_OUT, cp_detail)
		-- Still relaunch so the user is not left without their keyboard config
		KeLifecycle.arm_ke_gui_suppressor()
		pcall(function() hs.execute(KeLifecycle.OPEN_CMD) end)
		return
	end

	-- Arm the GUI suppressor BEFORE relaunching: some KE LaunchAgents pop the
	-- Preferences window during bootstrap. The watcher self-expires after its
	-- grace period so manual opens remain possible afterwards.
	KeLifecycle.arm_ke_gui_suppressor()

	Logger.trace(LOG, "Relaunching Karabiner-Elements after deploy…")
	pcall(function() hs.execute(KeLifecycle.OPEN_CMD) end)
	Logger.done(LOG, "Karabiner-Elements relaunch command issued.")

	local active_combos = 0
	for _, combo_def in ipairs(M.MOD_COMBOS) do
		local cfg = _state.mod_combos_config[combo_def.id] or {}
		if type(cfg) == "table"
			and (cfg.tap ~= "none" or cfg.hold ~= "none" or cfg.combo ~= "none") then
			active_combos = active_combos + 1
		end
	end

	-- Keep the bridge suppression set in sync with the newly generated config
	-- so the heatmap immediately reflects any tap/hold action changes.
	if KcBridge then
		KcBridge.refresh_managed_set(_state.tap_hold_config, M.AVAILABLE_ACTIONS)
	end

	Logger.success(LOG,
		"Karabiner config regenerated: %d combo(s) + %d tap/hold key(s) deployed.",
		active_combos, #M.TAP_HOLD_KEYS)
end

--- Deploys an empty Karabiner config so remapping stops without killing any process.
--- KE reloads via FSEvents — daemons stay alive, no Space switch.
--- Does nothing when the integration is disabled.
function M.pause()
	if not _state or not _state.enabled then return end
	Logger.start(LOG, "Pausing Karabiner-Elements…")
	local merged   = Generator.merge_into_existing_config(EMPTY_KE_CONFIG, KARABINER_OUT)
	local json_str = hs.json.encode(merged, true)
	local fh = io.open(KARABINER_GEN, "w")
	if not fh then
		Logger.error(LOG, "Cannot write empty config for pause at '%s'.", KARABINER_GEN)
		return
	end
	fh:write(json_str)
	fh:close()
	local ok, detail = Generator.deploy_file(KARABINER_GEN, KARABINER_OUT)
	if not ok then
		Logger.error(LOG, "Pause deploy failed: %s.", detail)
		return
	end
	Logger.success(LOG, "Karabiner-Elements paused (empty config deployed).")
end

--- Restores the full Karabiner config so remapping resumes.
--- Does nothing when the integration is disabled.
function M.resume()
	if not _state or not _state.enabled then return end
	Logger.start(LOG, "Resuming Karabiner-Elements…")
	M.regenerate()
	Logger.success(LOG, "Karabiner-Elements resumed.")
end




-- ============================
-- ============================
-- ======= 3/ Lifecycle =======
-- ============================
-- ============================

--- Initializes the Karabiner bridge.
--- No arguments needed — the module resolves its own directory at load time.
function M.init()
	Logger.start(LOG, "Initializing Karabiner bridge…")

	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	-- Try to remove KE from Login Items so it no longer auto-launches on next login
	KeLifecycle.remove_ke_from_login_items()

	-- Load shared data files first — required before load_user_config() can
	-- call build_default_state() on first launch
	M.AVAILABLE_ACTIONS    = Config.load_available_actions(ACTIONS_FILE) or {}
	M.TAP_HOLD_KEYS        = Config.load_tap_hold_keys(TAP_HOLD_FILE)   or {}
	M.MOD_COMBOS           = Config.load_mod_combos(MOD_COMBOS_FILE)    or {}
	M.NON_CANONICAL_COMBOS = Config.compute_non_canonical_combos(M.MOD_COMBOS)

	if #M.AVAILABLE_ACTIONS == 0 or #M.TAP_HOLD_KEYS == 0 or #M.MOD_COMBOS == 0 then
		Logger.error(LOG, "One or more data files failed to load — aborting initialization.")
		return
	end

	local first_launch = io.open(USER_CONFIG, "r") == nil
	local user_cfg     = Config.load_user_config(M.TAP_HOLD_KEYS, M.MOD_COMBOS, USER_CONFIG)

	_state = {
		enabled                   = user_cfg.enabled,
		tap_hold_config           = user_cfg.tap_hold_config,
		mod_combos_config         = user_cfg.mod_combos_config,
		tap_hold_timeout_ms       = user_cfg.tap_hold_timeout_ms,
		sticky_timeout_ms         = user_cfg.sticky_timeout_ms,
		simultaneous_threshold_ms = user_cfg.simultaneous_threshold_ms,
		combo_symmetric           = user_cfg.combo_symmetric,
		watcher                   = nil,
		hotkey_cycle_windows      = nil,
	}

	-- Propagate the tap/hold config to the KE physical-kc bridge so it knows
	-- which output keycodes to suppress in the HS event tap (preventing double
	-- counting of remapped keys in the heatmap).
	if KcBridge then
		KcBridge.refresh_managed_set(_state.tap_hold_config, M.AVAILABLE_ACTIONS)
	end

	-- Arm the suppressor watcher first so it catches any GUI activation triggered
	-- by the config reload below (KE may activate its window on FSEvents reload).
	KeLifecycle.arm_ke_gui_suppressor()

	if _state.enabled then
		Logger.info(LOG, "Integration enabled — deploying config…")
		KeLifecycle.launch_headless()
		M.regenerate()
	end

	-- Persist immediately on first launch so the file exists for future runs
	if first_launch then
		Config.save_user_config(_state, USER_CONFIG)
		Logger.info(LOG, "Default config written to '%s'.", USER_CONFIG)
	end

	_state.watcher              = Watchers.start_gesture_watcher()
	_state.hotkey_cycle_windows = Watchers.start_cycle_windows_hotkey()

	Watchers.start_input_source_watcher(function(layout_name)
		Logger.start(LOG, "Layout change detected — refreshing actions for layout '%s'…", layout_name)
		local new_actions = Config.load_available_actions(ACTIONS_FILE)
		if new_actions then M.AVAILABLE_ACTIONS = new_actions end
		if _state and _state.enabled then
			M.regenerate()
			Logger.success(LOG, "Layout-change rebuild complete — KE reloaded from '%s'.", KARABINER_OUT)
		else
			Logger.success(LOG, "Layout change processed — bridge disabled, no rebuild.")
		end
	end)

	local active_combos = 0
	for _, combo_def in ipairs(M.MOD_COMBOS) do
		local cfg = _state.mod_combos_config[combo_def.id] or {}
		if type(cfg) == "table"
			and (cfg.tap ~= "none" or cfg.hold ~= "none" or cfg.combo ~= "none") then
			active_combos = active_combos + 1
		end
	end

	Logger.success(LOG,
		"Karabiner bridge initialized (%d action(s), %d combo(s) active).",
		#M.AVAILABLE_ACTIONS, active_combos)
end

--- Stops all watchers and hotkeys registered by this module.
function M.stop()
	if not _state then return end
	Logger.start(LOG, "Stopping Karabiner bridge…")
	if _state.watcher then
		pcall(function() _state.watcher:stop() end)
		_state.watcher = nil
	end
	if _state.hotkey_cycle_windows then
		pcall(function() _state.hotkey_cycle_windows:disable() end)
		_state.hotkey_cycle_windows = nil
	end
	Watchers.stop_input_source_watcher()
	Logger.success(LOG, "Karabiner bridge stopped.")
end

--- Stops all HS-side watchers then fully kills the Karabiner-Elements processes.
--- Intended for use when quitting Hammerspoon so KE does not keep running headlessly.
function M.kill()
	Logger.start(LOG, "Killing Karabiner bridge and KE processes…")
	M.stop()
	pcall(function() hs.execute(KeLifecycle.KILL_CMD) end)
	Logger.success(LOG, "Karabiner-Elements processes killed.")
end

return M
