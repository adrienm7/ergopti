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
--- 2. User Config: config_karabiner.toml is the single runtime truth.
---    On first launch it is created from defaults; after that it is the full
---    persisted state — defaults are never recomputed at runtime except when
---    the user explicitly clicks "Reset to defaults".
--- 3. Local Action Dictionary: Loads modules/karabiner/data/actions.json so the menu
---    always lists exactly the same actions, with zero duplication.
--- 4. Modifier Combos: modules/karabiner/data/mod_combos.json defines all available
---    two-modifier combos. Each combo maps to tap, hold, and chord slots.
--- 5. Inline Generation: karabiner.json is built directly in Lua from in-memory
---    state — no Python subprocess, no external dependency.
--- 6. Deployment: The generated file is copied to the Karabiner-Elements config
---    directory via two sequential strategies, each logged separately.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("infra.logger")
local Defaults    = require("modules.karabiner.defaults")
local Config      = require("modules.karabiner.config")
local Generator   = require("modules.karabiner.generator")
local KeLifecycle = require("modules.karabiner.ke_lifecycle")
local Watchers    = require("modules.karabiner.watchers")
local Timings     = require("infra.timings")

-- Optional: keylogger may not be loaded in all deployments
local ok_kcb, KcBridge = pcall(require, "modules.keylogger.kc_bridge")
if not ok_kcb then KcBridge = nil end

local LOG = "karabiner"

-- macOS TIS settle delay: the keycode map is updated asynchronously by the Text
-- Input Source subsystem AFTER the input-source-changed notification fires. Wait
-- this long before rebuilding the Karabiner config so key_code_for_char() reads
-- the NEW layout's keycode map, not the previous one. Sourced from the Timings
-- registry (was a bare 0.5 inline literal) so it is tunable cross-driver in one place.
local LAYOUT_TIS_SETTLE_SEC = Timings.sec("debounce", "layout_tis_settle_ms")

-- Delay before binding the window-management convenience hotkeys (cycle windows,
-- alt-tab). They are not needed on the boot path, so binding them on a short timer
-- keeps their hs.hotkey setup off the critical boot sequence.
local HOTKEY_BIND_DEFER_SEC = 0.5

-- Resolve the directory that contains this init.lua at load time.
-- Works whether the file is symlinked, run from the project, or deployed.
local _SELF_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./")

-- Data JSONs live alongside this module under data/; Karabiner-Elements is
-- macOS-exclusive so there is no reason to put these files in _shared/.
local _DATA_DIR = _SELF_DIR .. "data/"

-- Standard Karabiner-Elements config path, expressed as a tilde path so the
-- FileSystem port adapter can resolve it through hs.fs.pathToAbsolute (which
-- follows symlinks and honours any macOS path aliasing), rather than naively
-- concatenating HOME ourselves.  The CI/test override is still honoured first.
local KARABINER_KE_TILDE_PATH = "~/.config/karabiner/karabiner.json"

-- Resolved at M.init() time via the injected FileSystem adapter.
-- Kept as a module-level variable (not constant) so generator calls can
-- reference it after init() has run; nil before init().
local KARABINER_OUT = nil

-- The user-editable Karabiner config lives under the user's resolved
-- config dir (paths.toml override honoured) at:
--     <config_dir>/hammerspoon/config_karabiner.toml
-- Resolution is deferred to MenuPaths so a relocated config follows.
local function resolve_user_config()
	local MenuPaths = require("ui.menu.menu_paths")
	return MenuPaths.get("KarabinerConfigPath")
end
local ACTIONS_FILE    = _DATA_DIR .. "actions.json"
local TAP_HOLD_FILE   = _DATA_DIR .. "tap_hold_keys.json"
local MOD_COMBOS_FILE = _DATA_DIR .. "mod_combos.json"

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

--- Populated by M.init() from modules/karabiner/data/actions.json.
M.AVAILABLE_ACTIONS = {}

--- Populated by M.init() from modules/karabiner/data/tap_hold_keys.json.
--- Each entry carries default_tap and default_hold for first-launch init and reset.
M.TAP_HOLD_KEYS = {}

--- Populated by M.init() from modules/karabiner/data/mod_combos.json.
--- Each entry defines a two-modifier simultaneous combo the user can map to an action.
M.MOD_COMBOS = {}

-- Session guard: prevent the first-run wizard from firing more than once per
-- Hammerspoon session. hs.reload() re-requires all modules so this flag resets
-- to false each time — but within a single boot a second M.init() call (e.g.
-- from a menu "Reload") must not re-prompt the user.
local _wizard_ran_this_session  = false
local _layout_rebuild_timer     = nil  -- Stored so rapid layout changes cancel the pending rebuild
-- Wake-from-sleep watcher. Held at module scope so it survives past the function
-- that arms it: an hs.caffeinate.watcher referenced only by a local is collected
-- and stops delivering, silently.
local _wake_watcher             = nil
local _deferred_hotkeys_timer   = nil  -- Pending convenience-hotkey bind; cancelled by M.stop()
local _kc_parent_ensured        = false -- metrics/ exists from the first regenerate onwards

-- Builds the minimal karabiner.json deployed on pause: the same profile structure
-- as normal but carrying only `rules` (an empty list = full native keyboard). KE's
-- FSEvents watcher reloads and applies just those — daemons stay alive, no process
-- kill, no restart, no Space switch. M.pause() passes the script-control rules here
-- so AltGr+Enter / Backspace / Escape survive the pause (« exempt de pause »).
-- @param rules table List of Karabiner rule objects to keep active while paused.
-- @return table A karabiner.json config table ready for merge_into_existing_config.
local function build_paused_ke_config(rules)
	return {
		profiles = {
			{
				complex_modifications = { rules = rules or {} },
				devices              = { { identifiers = { is_keyboard = true }, simple_modifications = {} } },
				name                 = "Default profile",
				selected             = true,
				virtual_hid_keyboard = { country_code = 0, keyboard_type_v2 = "ansi" },
			}
		}
	}
end

local _state = nil

local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — module not initialized.", func_name)
		return false
	end
	return true
end

--- Checks whether a file exists at the given path without leaking a file descriptor.
--- io.open returns a handle on success; we must close it immediately or the GC is
--- the only thing preventing an fd leak for the lifetime of the process.
--- @param path string Absolute path to test.
--- @return boolean True if the file exists and can be opened for reading.
local function file_exists(path)
	local f = io.open(path, "r")
	if f then f:close() end
	return f ~= nil
end


--- Opens the Karabiner-Elements GUI for the user on explicit request.
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
--- When enabling: launches KE daemons headlessly and deploys the config.
--- When disabling: kills the KE daemons we started — the user toggled the feature
--- off intentionally, so KE must not keep running in the background.
--- @param value boolean
function M.set_enabled(value)
	if not require_state("set_enabled") then return end
	local was_enabled = _state.enabled == true
	_state.enabled = value == true
	Logger.info(LOG, "Karabiner integration %s.", _state.enabled and "enabled" or "disabled")
	Config.save_user_config(_state, resolve_user_config())
	if _state.enabled then
		M.regenerate()
	elseif was_enabled then
		local hs_owned = type(KeLifecycle.is_hs_owned_bridge) == "function"
			and KeLifecycle.is_hs_owned_bridge() or false
		if hs_owned then
			-- Use kill_async to avoid blocking the main run loop ≥3 s
			-- (KILL_CMD has a 3-pass sleep loop — synchronous execution stalls HS).
			pcall(function() KeLifecycle.kill_async() end)
			Logger.info(LOG, "KE daemons stop requested asynchronously (feature disabled).")
		else
			Logger.info(LOG, "Feature disabled but KE left alive — session appears user-managed.")
		end
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
	-- Preserve any per-key timeout override — rebuilding the entry must not drop it.
	_state.tap_hold_config[key_id] = { tap = action_id, hold = cfg.hold or "none", timeout_ms = cfg.timeout_ms }
	Logger.debug(LOG, "Key '%s' tap → '%s'.", key_id, action_id)
	Config.save_user_config(_state, resolve_user_config())
end

--- Sets the hold action for a key and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param key_id string Key id.
--- @param action_id string Action id from actions.json.
function M.set_hold_action(key_id, action_id)
	if not require_state("set_hold_action") then return end
	local cfg = _state.tap_hold_config[key_id] or {}
	-- Preserve any per-key timeout override — rebuilding the entry must not drop it.
	_state.tap_hold_config[key_id] = { tap = cfg.tap or "none", hold = action_id, timeout_ms = cfg.timeout_ms }
	Logger.debug(LOG, "Key '%s' hold → '%s'.", key_id, action_id)
	Config.save_user_config(_state, resolve_user_config())
end

--- Returns the per-key tap/hold threshold override in milliseconds, or nil when
--- the key inherits the global tap/hold timeout (no per-key customisation).
--- @param key_id string Key id.
--- @return number|nil Per-key override in milliseconds, or nil.
function M.get_tap_timeout(key_id)
	if not require_state("get_tap_timeout") then return nil end
	local cfg = _state.tap_hold_config[key_id]
	return cfg and tonumber(cfg.timeout_ms) or nil
end

--- Sets or clears the per-key tap/hold threshold override and persists it.
--- A positive value overrides the global timeout for this key only; nil or a
--- non-positive value clears the override so the key inherits the single global
--- value again — no stale per-key literal is left behind. Does NOT regenerate.
--- @param key_id string Key id.
--- @param ms number|nil Per-key override in milliseconds, or nil to clear.
function M.set_tap_timeout(key_id, ms)
	if not require_state("set_tap_timeout") then return end
	local cfg   = _state.tap_hold_config[key_id] or {}
	local value = tonumber(ms)
	if value and value > 0 then
		value = math.floor(value)
	else
		value = nil  -- clear override → inherit the global timeout
	end
	_state.tap_hold_config[key_id] = { tap = cfg.tap or "none", hold = cfg.hold or "none", timeout_ms = value }
	Logger.debug(LOG, "Key '%s' tap/hold timeout override → %s.", key_id, value and (value .. " ms") or "global")
	Config.save_user_config(_state, resolve_user_config())
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
	Config.save_user_config(_state, resolve_user_config())
end

--- Sets the hold action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_hold_action(combo_id, action_id)
	if not require_state("set_combo_hold_action") then return end
	_state.mod_combos_config[combo_id] = update_combo_slot(combo_id, "hold", action_id)
	Logger.debug(LOG, "Combo '%s' hold → '%s'.", combo_id, action_id)
	Config.save_user_config(_state, resolve_user_config())
end

--- Sets the chord action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_combo_action(combo_id, action_id)
	if not require_state("set_combo_combo_action") then return end
	_state.mod_combos_config[combo_id] = update_combo_slot(combo_id, "combo", action_id)
	Logger.debug(LOG, "Combo '%s' combo → '%s'.", combo_id, action_id)
	Config.save_user_config(_state, resolve_user_config())
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
	Config.save_user_config(_state, resolve_user_config())
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
	Config.save_user_config(_state, resolve_user_config())
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
	Config.save_user_config(_state, resolve_user_config())
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
	Config.save_user_config(_state, resolve_user_config())
end

--- Resets all settings to their defaults and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- This is the only save allowed to overwrite an unparseable config file: every
--- other setter refuses, so without this the user could never repair a corrupt
--- config from the UI.
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
	Config.save_user_config(_state, resolve_user_config(), true)
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
---
--- Stability-first strategy: deliberately never kills the bridge before
--- writing. KE's own FSEvents watcher picks up the new file and applies it to
--- the already-running daemon, so the keyboard is never left unresponsive by
--- a failed or late re-prime after an unnecessary kill/relaunch cycle.
function M.regenerate()
	if not require_state("regenerate") then return end

	-- « pause = tout éteint ». Deploying the full Ergopti config hands KE back every
	-- remap the pause just removed, so ANY caller reaching here while paused
	-- silently un-pauses the keyboard. The layout-change watcher below already
	-- short-circuits for this reason and its comment states the rule generally —
	-- but the guard lived at that ONE call site while ~29 others (every menu toggle
	-- that regenerates: delays, tap-hold, sticky, layout, action edits) had none.
	-- The invariant belongs in the function that performs the deploy.
	--
	-- Safe for the resume path: script_control clears _is_paused BEFORE calling
	-- resume_all(), so M.resume() -> M.regenerate() passes this guard. A setting
	-- changed while paused is therefore not lost — it lands on the resume rebuild.
	local ok_sc, shortcuts = pcall(require, "modules.shortcuts")
	if ok_sc and shortcuts and type(shortcuts.is_paused) == "function" and shortcuts.is_paused() then
		Logger.info(LOG, "Regenerate skipped — script is paused (« pause = tout éteint »).")
		return
	end

	Logger.start(LOG, "Regenerating Karabiner config…")

	local ok_build, result = pcall(
		Generator.build_karabiner_json,
		_state, M.AVAILABLE_ACTIONS, M.TAP_HOLD_KEYS, M.MOD_COMBOS, M.NON_CANONICAL_COMBOS, _DATA_DIR
	)
	if not ok_build then
		Logger.error(LOG, "JSON generation failed: %s.", tostring(result))
		return
	end

	local merged   = Generator.merge_into_existing_config(result, KARABINER_OUT)
	local json_str = hs.json.encode(merged, true)

	-- Stability-first strategy: never kill the bridge before deploy.
	-- On this setup, a failed/late re-prime after kill can leave keyboard input
	-- partially blocked system-wide. Keeping the bridge alive avoids that outage.
	Logger.info(LOG, "Keeping KE bridge alive during deploy (stability mode).")

	local ok_copy, cp_detail = Generator.deploy_string(json_str, KARABINER_OUT)
	if not ok_copy then
		Logger.error(LOG, "Deploy failed → '%s': %s.", KARABINER_OUT, cp_detail)
		return
	end

	-- Ensure the parent directory of the KC physical log exists before Karabiner
	-- starts writing to it via shell_command echo redirects
	local kc_parent = Generator.KE_PHYSICAL_KC_LOG and Generator.KE_PHYSICAL_KC_LOG:match("^(.*)/[^/]+$")
	if kc_parent and not _kc_parent_ensured then
		-- POSIX single-quoting, not Lua's %q. %q escapes for a LUA literal — it leaves
		-- $, backticks and ! untouched — so a config dir containing any of them was
		-- interpolated straight into /bin/sh. The path is user-configurable, so this
		-- is the same shell-quoting rule the generator applies 150 lines away, and the
		-- generator's own regression test covers only that file. Memoised because this
		-- runs on every regenerate: the directory does not stop existing.
		local function sq(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end
		pcall(hs.execute, "mkdir -p " .. sq(kc_parent))
		_kc_parent_ensured = true
	end

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

	-- Re-prime in non-forced mode: if bridge is already healthy, this becomes a
	-- cheap no-op; if missing, lifecycle will still launch it.
	KeLifecycle.prime_ke_for_session(function(ok)
		if ok then
			Logger.success(LOG, "Karabiner bridge primed after regeneration.")
		else
			Logger.warn(LOG, "Karabiner bridge prime failed after regeneration — retrying once…")
			hs.timer.doAfter(1.0, function()
				KeLifecycle.prime_ke_for_session(function(ok_retry)
					if ok_retry then
						Logger.success(LOG, "Karabiner bridge primed after regeneration retry.")
					else
						Logger.error(LOG, "Karabiner bridge prime failed after regeneration retry.")
					end
				end, true)
			end)
		end
	end, false)
end

--- Deploys an empty Karabiner config so remapping stops without killing any process.
--- KE reloads via FSEvents — daemons stay alive, no Space switch.
--- Does nothing when the integration is disabled.
function M.pause()
	if not _state or not _state.enabled then return end
	Logger.start(LOG, "Pausing Karabiner-Elements…")
	-- Pause strips every remap so the keyboard goes native (« pause = tout éteint »),
	-- EXCEPT the script-control rules: AltGr+Enter / Backspace / Escape must keep
	-- working so the user can un-pause from the keyboard. They are deployed as
	-- self-contained modifier-gated sentinel rules (no dependency on the stripped
	-- tap/hold holder variable) — see Generator.build_paused_script_control_rules.
	local paused_config = build_paused_ke_config(Generator.build_paused_script_control_rules())
	local merged   = Generator.merge_into_existing_config(paused_config, KARABINER_OUT)
	local json_str = hs.json.encode(merged, true)
	local ok, detail = Generator.deploy_string(json_str, KARABINER_OUT)
	if not ok then
		Logger.error(LOG, "Pause deploy failed: %s.", detail)
		return
	end
	Logger.success(LOG, "Karabiner-Elements paused (script-control rules retained).")
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
--- @param file_system table FileSystem port adapter (adapters/file_system.lua).
---   Used to resolve the KE config path through hs.fs.pathToAbsolute so the
---   module never hard-codes OS path logic outside the port boundary.
function M.init(file_system)
	Logger.start(LOG, "Initializing Karabiner bridge…")

	if type(file_system) ~= "table" or type(file_system.expand_path) ~= "function" then
		Logger.error(LOG, "M.init(): file_system adapter is required and must implement expand_path — module non-functional.")
		return
	end

	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	-- Resolve the KE output path through the FileSystem port so path logic is
	-- centralised in the adapter and not duplicated across modules.
	-- The env-var override is checked first to support CI and headless testing.
	local env_override = os.getenv("ERGOPTI_KARABINER_OUT")
	if env_override and env_override ~= "" then
		KARABINER_OUT = env_override
		Logger.info(LOG, "KE config path overridden by ERGOPTI_KARABINER_OUT: '%s'.", KARABINER_OUT)
	else
		KARABINER_OUT = file_system.expand_path(KARABINER_KE_TILDE_PATH)
		Logger.info(LOG, "KE config path resolved: '%s'.", KARABINER_OUT)
	end

	-- Load shared data files first — required before load_user_config() can
	-- call build_default_state() on first launch
	-- Each phase is timed so the boot log attributes init.lua's "UI: karabiner.init"
	-- cost to a specific JSON load or the non-canonical combo computation
	-- (karabiner-init-breakdown).
	local function timed(label, fn)
		local t0 = hs.timer.absoluteTime()
		local result = fn()
		Logger.info(LOG, "init phase '%s': %.1f ms.", label, (hs.timer.absoluteTime() - t0) / 1e6)
		return result
	end
	M.AVAILABLE_ACTIONS    = timed("load_available_actions", function() return Config.load_available_actions(ACTIONS_FILE) end) or {}
	M.TAP_HOLD_KEYS        = timed("load_tap_hold_keys",     function() return Config.load_tap_hold_keys(TAP_HOLD_FILE) end)    or {}
	M.MOD_COMBOS           = timed("load_mod_combos",        function() return Config.load_mod_combos(MOD_COMBOS_FILE) end)     or {}
	M.NON_CANONICAL_COMBOS = timed("compute_non_canonical_combos", function() return Config.compute_non_canonical_combos(M.MOD_COMBOS) end)

	if #M.AVAILABLE_ACTIONS == 0 or #M.TAP_HOLD_KEYS == 0 or #M.MOD_COMBOS == 0 then
		Logger.error(LOG, "One or more data files failed to load — aborting initialization.")
		return
	end

	local first_launch = not file_exists(resolve_user_config())
	local user_cfg     = timed("load_user_config", function()
		return Config.load_user_config(M.TAP_HOLD_KEYS, M.MOD_COMBOS, resolve_user_config())
	end)
	local tab_cfg      = user_cfg.tap_hold_config and user_cfg.tap_hold_config.tab
	if type(tab_cfg) == "table" and tab_cfg.tap == "cmd_tab" then
		tab_cfg.tap = "alt_tab_windows"
		-- The save is refused when the file on disk is unparseable, so announcing
		-- the migration unconditionally would claim a persistence that never happened.
		if Config.save_user_config(user_cfg, resolve_user_config()) then
			Logger.info(LOG, "Migrated tab.tap: 'cmd_tab' → 'alt_tab_windows'.")
		else
			Logger.warn(LOG, "tab.tap migrated in memory only — the user config was not written.")
		end
	end

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
		hotkey_alt_tab_windows    = nil,
		hotkey_alt_tab_apps       = nil,
	}

	-- Propagate the tap/hold config to the KE physical-kc bridge so it knows
	-- which output keycodes to suppress in the HS event tap (preventing double
	-- counting of remapped keys in the heatmap).
	if KcBridge then
		timed("KcBridge.refresh_managed_set", function()
			KcBridge.refresh_managed_set(_state.tap_hold_config, M.AVAILABLE_ACTIONS)
		end)
	end

	if _state.enabled then
		Logger.info(LOG, "Integration enabled — deploy will be triggered from init.lua boot completion.")
		-- Do NOT call M.regenerate() here: hs.timer callbacks scheduled during
		-- module initialization do not fire reliably. The main init.lua calls
		-- M.regenerate() explicitly at the very end of its boot sequence, once
		-- the event loop is guaranteed to be running.
	end

	-- Persist immediately on first launch so the file exists for future runs
	if first_launch then
		if Config.save_user_config(_state, resolve_user_config()) then
			Logger.info(LOG, "Default config written to '%s'.", resolve_user_config())
		else
			Logger.error(LOG, "Default config could NOT be written to '%s' — settings will not survive a restart.",
				resolve_user_config())
		end
	end

	-- Gestures engine is an optional dependency: it provides the any-touch hook
	-- so bare finger contact on the trackpad also deactivates CapsWord.
	local ok_ge, gestures_engine = pcall(require, "modules.gestures.engine")
	if not ok_ge then gestures_engine = nil end
	_state.watcher = timed("start_gesture_watcher", function()
		return Watchers.start_gesture_watcher(gestures_engine)
	end)

	-- The window-management hotkeys (cycle windows, alt-tab) are pure convenience
	-- bindings — nothing on the boot path needs them, so bind them on a short timer
	-- to keep their hs.hotkey setup off the critical boot path. The timer is tracked
	-- so M.stop() can cancel it if a reload happens before it fires.
	_deferred_hotkeys_timer = hs.timer.doAfter(HOTKEY_BIND_DEFER_SEC, function()
		_deferred_hotkeys_timer = nil
		if not _state then return end  -- module stopped before the timer fired
		_state.hotkey_cycle_windows   = Watchers.start_cycle_windows_hotkey()
		_state.hotkey_alt_tab_windows = Watchers.start_alt_tab_windows_hotkey()
		_state.hotkey_alt_tab_apps    = Watchers.start_alt_tab_apps_hotkey()
		Logger.debug(LOG, "Window-management hotkeys bound (deferred).")
	end)

	timed("start_input_source_watcher", function() Watchers.start_input_source_watcher(function(layout_name)
		Logger.start(LOG, "Layout change detected — refreshing actions for layout '%s'…", layout_name)
		-- Delay the rebuild slightly: hs.keycodes.map is updated by the macOS TIS
		-- subsystem asynchronously after the notification fires. Without the delay,
		-- key_code_for_char() would still read the previous layout's keycode map and
		-- generate wrong physical keys in the Karabiner config.
		if _layout_rebuild_timer then
			pcall(function() _layout_rebuild_timer:stop() end)
			_layout_rebuild_timer = nil
		end
		_layout_rebuild_timer = hs.timer.doAfter(LAYOUT_TIS_SETTLE_SEC, function()
			_layout_rebuild_timer = nil
			local new_actions = Config.load_available_actions(ACTIONS_FILE)
			if new_actions then M.AVAILABLE_ACTIONS = new_actions end

			-- A layout switch fired WHILE PAUSED is almost always the pause-layout
			-- feature switching us off Ergopti as part of the pause itself. Redeploying
			-- the full remapping or re-arming the binding hotkeys here would silently
			-- undo the pause (« pause = tout éteint »): KE would get the full Ergopti
			-- config back and the user-facing shortcuts would come alive mid-pause. So
			-- while paused we leave the pause state untouched — the script-control rules
			-- already deployed by M.pause() are layout-independent (fixed key_codes), so
			-- AltGr+Enter/Backspace/Escape still work on the new layout. The eventual
			-- resume regenerates the full config for real.
			local ok_sc, shortcuts = pcall(require, "modules.shortcuts")
			if ok_sc and shortcuts and type(shortcuts.is_paused) == "function" and shortcuts.is_paused() then
				Logger.info(LOG, "Layout change ignored — script is paused (« pause = tout éteint »).")
				return
			end

			if _state and _state.enabled then
				M.regenerate()
				Logger.success(LOG, "Layout-change rebuild complete — KE reloaded from '%s'.", KARABINER_OUT)
			else
				Logger.success(LOG, "Layout change processed — bridge disabled, no rebuild.")
			end
			-- Rebuild Hammerspoon hotkeys so they track the new physical key positions.
			-- hs.hotkey.bind resolves key names at bind time, so existing bindings point
			-- at the old layout's scancodes until they are re-bound. Use the dedicated
			-- rebind helper — NOT shortcuts.stop()/start(): stop() also tears down the
			-- script-control eventtap (AltGr+Enter pause/resume) and start() is a
			-- Bindings-only proxy that never revives it, so the un-pause shortcut would
			-- die on the first layout switch. The helper rebinds the layout-dependent
			-- hotkeys while leaving the keycode-based, layout-independent eventtap alive.
			-- Nor the pause_bindings/resume_bindings pair it replaced: that round-trip is
			-- symmetric only when the layer was ON, so it re-enabled every shortcut the
			-- user had switched off from the menu (and killed keep-awake via stop()) on
			-- each layout change — which the pause-layout feature triggers on every pause.
			-- rebind_for_layout() is a no-op on a stopped layer by contract.
			if type(shortcuts.rebind_for_layout) == "function" then
				-- rebind_for_layout is a no-op on a stopped layer by contract, so the
				-- INFO line claimed a rebind that had not happened every time the user
				-- had shortcuts switched off — on every layout change, which the
				-- pause-layout feature triggers on every pause. Branch on the outcome.
				local ok_rb, rebound = pcall(shortcuts.rebind_for_layout)
				if ok_rb and rebound then
					Logger.info(LOG, "Shortcuts rebound for layout '%s'.", layout_name)
				else
					Logger.debug(LOG, "Shortcuts not rebound for layout '%s' — layer is stopped.", layout_name)
				end
			end
		end)
	end) end)  -- close the input-source callback, then the timed() wrapper

	-- Wake-from-sleep refresh of the layout-dependent key codes.
	--
	-- Every action carrying a logical_char is resolved against whatever layout was
	-- active when the list was built, and the only thing that re-resolves them is
	-- the input-source watcher above. That fires on
	-- AppleSelectedInputSourcesChangedNotification, which is NOT delivered for a
	-- layout that changed while the machine was asleep — and the TIS layer can
	-- settle differently across a wake. So the list could hold the key codes of a
	-- layout that is no longer active, Karabiner would be handed a config remapping
	-- the wrong physical keys, and nothing re-derived it until the user switched
	-- layout by hand.
	--
	-- The gestures module carries this same pattern for its touch device, for the
	-- same reason: after a wake the OS reports state the process still believes.
	local ok_cw, cw = pcall(require, "hs.caffeinate.watcher")
	if ok_cw and cw then
		if _wake_watcher then pcall(function() _wake_watcher:stop() end) end
		_wake_watcher = cw.new(function(event)
			if event ~= cw.systemDidWake and event ~= cw.screensDidUnlock then return end

			-- Re-resolve only. The JSON read and the ~600 generated chord entries are
			-- layout-independent, so the full loader would put a rebuild back on the
			-- wake path that the split deliberately removed.
			local n = Config.resolve_layout_actions(M.AVAILABLE_ACTIONS)
			Logger.info(LOG, "Wake detected — re-resolved %d layout-dependent action(s).", n)

			-- A wake while paused must not redeploy: regenerating hands Karabiner the
			-- full Ergopti config back and would silently undo the pause, which is the
			-- « pause = tout éteint » contract the layout-change path above protects
			-- with the same check.
			local ok_sc, shortcuts = pcall(require, "modules.shortcuts")
			if ok_sc and shortcuts and type(shortcuts.is_paused) == "function"
				and shortcuts.is_paused() then
				Logger.info(LOG, "Wake refresh: not redeploying — script is paused.")
				return
			end
			if _state and _state.enabled then M.regenerate() end
		end)
		pcall(function() _wake_watcher:start() end)
	else
		Logger.warn(LOG, "hs.caffeinate.watcher unavailable — layout key codes will not be "
			.. "re-resolved after a wake.")
	end

	local active_combos = 0
	for _, combo_def in ipairs(M.MOD_COMBOS) do
		local cfg = _state.mod_combos_config[combo_def.id] or {}
		if type(cfg) == "table"
			and (cfg.tap ~= "none" or cfg.hold ~= "none" or cfg.combo ~= "none") then
			active_combos = active_combos + 1
		end
	end

	-- Defer the first-run health check so it never blocks boot. The wizard
	-- only surfaces a dialog when a KE dependency is missing; otherwise it
	-- exits silently. Pcall-wrapped so any onboarding failure cannot prevent
	-- the bridge itself from finishing initialization.
	-- The session guard prevents the dialog from re-appearing on every
	-- hs.reload() within the same Hammerspoon session.
	if _state.enabled and not _wizard_ran_this_session then
		_wizard_ran_this_session = true
		hs.timer.doAfter(2.0, function()
			pcall(function()
				local Onboarding = require("modules.karabiner.onboarding")
				Onboarding.run_first_run_wizard()
			end)
		end)
	end

	Logger.success(LOG,
		"Karabiner bridge initialized (%d action(s), %d combo(s) active).",
		#M.AVAILABLE_ACTIONS, active_combos)
end

--- Stops all watchers and hotkeys registered by this module.
function M.stop()
	if not _state then return end
	Logger.start(LOG, "Stopping Karabiner bridge…")
	-- Cancel a still-pending deferred hotkey bind so it cannot fire after stop and
	-- leak a hotkey the matching disable below would have already skipped (nil).
	if _deferred_hotkeys_timer then
		pcall(function() _deferred_hotkeys_timer:stop() end)
		_deferred_hotkeys_timer = nil
	end
	if _state.watcher then
		pcall(function() _state.watcher:stop() end)
		_state.watcher = nil
	end
	if _state.hotkey_cycle_windows then
		pcall(function() _state.hotkey_cycle_windows:disable() end)
		_state.hotkey_cycle_windows = nil
	end
	if _state.hotkey_alt_tab_windows then
		pcall(function() _state.hotkey_alt_tab_windows:disable() end)
		_state.hotkey_alt_tab_windows = nil
	end
	if _state.hotkey_alt_tab_apps then
		pcall(function() _state.hotkey_alt_tab_apps:disable() end)
		_state.hotkey_alt_tab_apps = nil
	end
	if type(Watchers.stop_alt_tab_apps_tracker) == "function" then
		Watchers.stop_alt_tab_apps_tracker()
	end
	if _layout_rebuild_timer then
		pcall(function() _layout_rebuild_timer:stop() end)
		_layout_rebuild_timer = nil
	end
	Watchers.stop_input_source_watcher()
	Logger.success(LOG, "Karabiner bridge stopped.")
end

--- Stops all HS-side watchers and, if the feature was enabled, kills the KE
--- daemons that Hammerspoon started. Called when quitting Hammerspoon so KE
--- does not keep remapping the keyboard after HS exits.
--- If the feature was disabled, KE is left untouched (user's own setup).
function M.kill()
	Logger.start(LOG, "Stopping Karabiner bridge…")
	local was_enabled = _state and _state.enabled == true
	local hs_owned = type(KeLifecycle.is_hs_owned_bridge) == "function" and KeLifecycle.is_hs_owned_bridge() or false
	M.stop()
	if was_enabled and hs_owned then
		pcall(function() hs.execute(KeLifecycle.KILL_CMD) end)
		Logger.success(LOG, "Karabiner bridge stopped and HS-owned KE daemons killed.")
	elseif was_enabled then
		Logger.success(LOG, "Karabiner bridge stopped (KE kept alive — session appears user-managed).")
	else
		Logger.success(LOG, "Karabiner bridge stopped (feature was disabled — KE untouched).")
	end
end

return M
