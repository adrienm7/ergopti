--- platform/remap/init.lua

--- ==============================================================================
--- MODULE: Karabiner Elements Bridge
--- DESCRIPTION:
--- Bridge between Hammerspoon and Karabiner-Elements. Orchestrates exact-lease
--- lifecycle, JSON generation, config persistence, and
--- event watchers. Exposes the full public API consumed by menu_karabiner.lua.
---
--- FEATURES & RATIONALE:
--- 1. CapsWord Watcher: Detects trackpad scroll/gesture events and deactivates
---    CapsWord so the user never gets stuck in caps mode after using the trackpad.
--- 2. User Config: config_karabiner.toml is the single runtime truth.
---    On first launch it is created from defaults; after that it is the full
---    persisted state — defaults are never recomputed at runtime except when
---    the user explicitly clicks "Reset to defaults".
--- 3. Local Action Dictionary: Loads platform/remap/data/actions.json so the menu
---    always lists exactly the same actions, with zero duplication.
--- 4. Modifier Combos: platform/remap/data/mod_combos.json defines all available
---    two-modifier combos. Each combo maps to tap, hold, and chord slots.
--- 5. Inline Generation: karabiner.json is built directly in Lua from in-memory
---    state — no Python subprocess, no external dependency.
--- 6. Deployment: The generated file is copied to the Karabiner-Elements config
---    directory via two sequential strategies, each logged separately.
--- ==============================================================================

local M = {}

local hs          = hs
local Logger      = require("infra.logger")
local Defaults    = require("platform.remap.defaults")
local Config      = require("platform.remap.config")
local Generator   = require("platform.remap.generator")
local KeLifecycle = require("platform.remap.ke_lifecycle")
local LeaseController = require("platform.remap.lease_controller")
local Watchers    = require("platform.remap.watchers")
local Registrar   = require("adapters.hotkey_registrar")
local Timings     = require("infra.timings")

-- The managed-output classifier is a lease prerequisite even when the
-- keylogger feature is disabled. A load failure must keep generated rules
-- PAUSED; activating without it would let a later keylogger start classify
-- Karabiner output as physical input.
local ok_kcb, KcBridge = pcall(require, "modules.keylogger.kc_bridge")
if not ok_kcb then KcBridge = nil end

local LOG = "karabiner"

-- macOS TIS settle delay: the keycode map is updated asynchronously by the Text
-- Input Source subsystem AFTER the input-source-changed notification fires. Wait
-- this long before rebuilding the Karabiner config so key_code_for_char() reads
-- the NEW layout's keycode map, not the previous one. Sourced from the Timings
-- registry (was a bare 0.5 inline literal) so it is tunable cross-driver in one place.
local LAYOUT_TIS_SETTLE_SEC = Timings.sec("debounce", "layout_tis_settle_ms")

local DISABLED_LEGACY_PROBE_STRINGS = {
	"[ErgoptiPlus managed:",
	"Script control: physical rcmd + ",
	"Paused script control: option + ",
	"ke_held_",
}

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
	local MenuPaths = require("infra.config_paths")
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

--- Populated by M.init() from platform/remap/data/actions.json.
M.AVAILABLE_ACTIONS = {}

--- Populated by M.init() from platform/remap/data/tap_hold_keys.json.
--- Each entry carries default_tap and default_hold for first-launch init and reset.
M.TAP_HOLD_KEYS = {}

--- Populated by M.init() from platform/remap/data/mod_combos.json.
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
local _kc_parent_ensured        = false -- metrics/ exists from the first regenerate onwards
local _lifecycle_epoch          = 0     -- Invalidates async callbacks retained past M.stop()
local _running                  = false -- True only for the current initialized lifecycle
local _shutdown_requested       = false -- Rejects new work while the exact fence is pending
local _activation_transaction  = nil   -- Same-token regenerate callers share one mount + RESUME
local _hotkey_cleanup_backlog  = {}    -- Failed adapter deletes retained for a later exact retry
local _gesture_cleanup_backlog = {}    -- Failed eventtap stops retain their exact handles for retry
local _lease_inputs_tainted    = false -- Retained disabled handles are not proof of liveness

local _state = nil
local _enabled_transition = nil
-- Unforgeable module-private capabilities allow only fail-closed lifecycle
-- transactions to rebuild while the public script state remains paused
local PAUSED_DISABLE_RECOVERY = {}
local PAUSED_RESUME_REGENERATION = {}

--- Invokes a public async callback without letting its error vanish in a task callback.
--- @param label string Operation label for diagnostics.
--- @param callback function|nil Callback to invoke.
--- @param ... any Callback arguments.
local function invoke_public_callback(label, callback, ...)
	if type(callback) ~= "function" then return end
	local ok, err = pcall(callback, ...)
	if not ok then Logger.error(LOG, "%s callback failed: %s.", label, tostring(err)) end
end

--- Settles every callback joined to one enable-state transaction.
--- @param transaction table Transaction descriptor.
--- @param ok boolean Operation result.
--- @param reason string Result detail.
local function settle_enabled_callbacks(transaction, ok, reason)
	local callbacks = transaction.callbacks or {}
	transaction.callbacks = {}
	for _, callback in ipairs(callbacks) do
		invoke_public_callback("set_enabled", callback, ok, reason)
	end
end

--- Persists an enabled flag without mutating the live state before commit.
--- @param enabled boolean Target persisted flag.
--- @return boolean True only when the config writer explicitly succeeds.
local function persist_enabled_flag(enabled)
	local persisted = {}
	for key, item in pairs(_state) do persisted[key] = item end
	persisted.enabled = enabled == true
	local ok, saved_or_err = pcall(Config.save_user_config, persisted, resolve_user_config())
	if not ok or saved_or_err ~= true then
		Logger.error(LOG, "Karabiner enabled preference could not be persisted: %s.",
			tostring(ok and saved_or_err or saved_or_err))
		return false
	end
	return true
end

--- Commits an enable transaction only after its exact generation reached READY.
--- @param transaction table Private transaction capability.
--- @return boolean committed True only after enabled=true was durably saved.
--- @return string reason Stable failure detail.
local function commit_enable_transition(transaction)
	if _enabled_transition ~= transaction or transaction.kind ~= "enabling" then
		return false, "stale-enable-transaction"
	end
	if not persist_enabled_flag(true) then return false, "persistence-failed" end
	_state.enabled = true
	transaction.committed = true
	return true, "enabled"
end

--- Releases keycode ownership that is valid only while Ergopti rules are live.
--- @return boolean cleared True only when the exact classifier API completed.
local function clear_managed_output_set()
	if not KcBridge or type(KcBridge.clear_managed_set) ~= "function" then
		Logger.error(LOG, "Managed-output classifier clear API is unavailable.")
		return false
	end
	local ok, result = xpcall(KcBridge.clear_managed_set, debug.traceback)
	if not ok then
		Logger.error(LOG, "Managed-output classifier clear failed: %s.", tostring(result))
		return false
	end
	return true
end

--- Releases one registrar handle without mistaking a contained false for success.
--- @param handle any Opaque registrar capability.
--- @param label string Stable diagnostic label.
--- @return boolean released
local function try_unbind_hotkey(handle, label)
	local call_ok, released_or_err = pcall(Registrar.unbind, handle)
	if call_ok and released_or_err == true then return true end
	Logger.error(LOG, "Lease-bound hotkey teardown failed for %s: %s.",
		label, tostring(released_or_err))
	return false
end

--- Stops one CapsWord eventtap through the strict watcher teardown contract.
--- @param watcher any Exact eventtap capability.
--- @param label string Stable diagnostic label.
--- @return boolean released
local function try_stop_gesture_watcher(watcher, label)
	local call_ok, stopped_or_err
	if type(Watchers.stop_gesture_watcher) == "function" then
		call_ok, stopped_or_err = pcall(Watchers.stop_gesture_watcher, watcher)
	else
		call_ok, stopped_or_err = pcall(function()
			watcher:stop()
			return true
		end)
	end
	if call_ok and stopped_or_err == true then return true end
	Logger.error(LOG, "Lease-bound gesture watcher teardown failed for %s: %s.",
		label, tostring(stopped_or_err))
	return false
end

--- Stops every Hammerspoon resource whose input is emitted by managed KE rules.
--- @return boolean stopped True only when no retained consumer handle remains.
local function stop_lease_bound_inputs()
	local all_stopped = true
	local gesture_stop_called = false
	if _state and _state.watcher then
		gesture_stop_called = true
		local watcher = _state.watcher
		if try_stop_gesture_watcher(watcher, "committed") then
			_state.watcher = nil
		else
			all_stopped = false
		end
	end
	if not gesture_stop_called and type(Watchers.stop_gesture_watcher) == "function" then
		if not try_stop_gesture_watcher(nil, "internal-backlog") then all_stopped = false end
	end
	for index = #_gesture_cleanup_backlog, 1, -1 do
		local watcher = _gesture_cleanup_backlog[index]
		if try_stop_gesture_watcher(watcher, "uncommitted-backlog") then
			table.remove(_gesture_cleanup_backlog, index)
		else
			all_stopped = false
		end
	end
	if _state then
		for _, field in ipairs({
			"hotkey_cycle_windows",
			"hotkey_alt_tab_windows",
			"hotkey_alt_tab_apps",
			"hotkey_alt_tab_monitor",
		}) do
			if _state[field] then
				local handle = _state[field]
				if try_unbind_hotkey(handle, field) then
					_state[field] = nil
				else
					all_stopped = false
				end
			end
		end
	end
	for index = #_hotkey_cleanup_backlog, 1, -1 do
		local handle = _hotkey_cleanup_backlog[index]
		if try_unbind_hotkey(handle, "uncommitted-backlog") then
			table.remove(_hotkey_cleanup_backlog, index)
		else
			all_stopped = false
		end
	end
	if type(Watchers.stop_alt_tab_apps_tracker) == "function" then
		local stopped, stop_result = pcall(Watchers.stop_alt_tab_apps_tracker)
		if not stopped or stop_result ~= true then
			Logger.error(LOG, "Lease-bound app tracker stop failed: %s.", tostring(stop_result))
			all_stopped = false
		end
	end
	_lease_inputs_tainted = not all_stopped
	return all_stopped
end

--- Returns the settled phase only when status still names the captured token.
--- @param expected_token string|nil Generation capability captured by the caller.
--- @return string|nil exact_phase
local function exact_generation_phase(expected_token)
	if type(expected_token) ~= "string" then return nil end
	local ok, phase, snapshot = pcall(LeaseController.status)
	if not ok or type(snapshot) ~= "table" or snapshot.token ~= expected_token then return nil end
	return phase
end

--- Rolls back a failed input mount and, unless the caller can prove the same
--- generation remains PAUSED, fences only the exact Ergopti lease. The KC
--- classifier remains live while an ACTIVE generation is still being fenced so
--- already-emitted managed events cannot be mistaken for physical input.
--- @param detail string Diagnostic detail.
--- @param retain_if_paused boolean True only for a user resume that may remain paused.
--- @param expected_token string|nil Generation capability captured before mounting.
--- @return boolean Always false.
--- @return string Stable public failure reason.
local function fail_lease_bound_input_start(detail, retain_if_paused, expected_token)
	Logger.error(LOG, "Lease-bound input startup failed: %s.", tostring(detail))
	local exact_phase = exact_generation_phase(expected_token)
	if exact_phase == nil then
		-- Ownership changed while a local transaction was running. Never translate
		-- that stale failure into an untargeted stop of the replacement generation.
		Logger.warn(LOG, "Stale lease-input failure ignored for superseded token %s.",
			tostring(expected_token))
		return false, "stale-lease-input-start"
	end
	local is_safely_paused = exact_phase == "paused"
	local may_remain_paused = retain_if_paused == true and is_safely_paused
	if not may_remain_paused then
		local stop_method = type(LeaseController.stop_exact) == "function"
			and LeaseController.stop_exact or LeaseController.stop
		local stop_ok, stop_result
		if stop_method == LeaseController.stop_exact then
			stop_ok, stop_result = pcall(stop_method, expected_token, "lease_input_bind_failed")
		else
			stop_ok, stop_result = pcall(stop_method, "lease_input_bind_failed")
		end
		if not stop_ok or stop_result ~= true then
			Logger.error(LOG, "Exact lease fencing request after input startup failure failed: %s.",
				tostring(stop_result))
		end
	end
	-- PAUSED rules cannot emit the F17 outputs, so local rollback is safe there.
	-- In every ambiguous/ACTIVE phase, keep any committed consumers alive until
	-- the phase listener observes the exact STOPPED/fallback fence.
	if is_safely_paused then
		clear_managed_output_set()
		stop_lease_bound_inputs()
	end
	return false, "lease-input-start-failed"
end

--- Releases locally-created resources that were never committed to module state.
--- @param handles table Ordered handles acquired by the current bind attempt.
--- @param watcher any|nil Gesture watcher acquired by the same attempt.
--- @param stop_app_tracker boolean Whether this attempt could have created it.
local function rollback_uncommitted_inputs(handles, watcher, stop_app_tracker)
	for index = #handles, 1, -1 do
		local handle = handles[index]
		if not try_unbind_hotkey(handle, "uncommitted") then
			_hotkey_cleanup_backlog[#_hotkey_cleanup_backlog + 1] = handle
			_lease_inputs_tainted = true
		end
	end
	if watcher ~= nil then
		if not try_stop_gesture_watcher(watcher, "uncommitted") then
			_gesture_cleanup_backlog[#_gesture_cleanup_backlog + 1] = watcher
			_lease_inputs_tainted = true
		end
	end
	if stop_app_tracker and type(Watchers.stop_alt_tab_apps_tracker) == "function" then
		local ok, err = pcall(Watchers.stop_alt_tab_apps_tracker)
		if not ok or err ~= true then
			Logger.error(LOG, "Uncommitted app tracker rollback failed: %s.", tostring(err))
			_lease_inputs_tainted = true
		end
	end
end

--- Mounts every Hammerspoon consumer while the exact generation is in the
--- required settled phase. Callers use PAUSED before activation and ACTIVE only
--- when repairing an already-live generation. All four F17 handles commit as one
--- synchronous main-runloop transaction; no timer can expose live KE rules first.
--- Returns whether the current state or its private enable transaction owns the
--- right to prepare Ergopti-only input consumers.
--- @return boolean authorized
local function inputs_are_authorized()
	return _state ~= nil and (_state.enabled == true
		or (_enabled_transition ~= nil and _enabled_transition.kind == "enabling"))
end

--- @param required_phase string `paused` or `active`.
--- @param retain_if_paused boolean True only for a user resume that may remain paused.
--- @return boolean mounted True only when every lease-owned resource is retained.
--- @return string reason Stable acceptance/failure detail.
local function start_lease_bound_inputs(required_phase, retain_if_paused)
	if not inputs_are_authorized() then
		return fail_lease_bound_input_start("integration is not enabled", retain_if_paused)
	end
	local status_ok, phase, lease_snapshot = pcall(LeaseController.status)
	if not status_ok or phase ~= required_phase or type(lease_snapshot) ~= "table"
		or type(lease_snapshot.token) ~= "string" then
		return fail_lease_bound_input_start(
			"exact " .. tostring(required_phase) .. " lease snapshot is unavailable",
			retain_if_paused,
			type(lease_snapshot) == "table" and lease_snapshot.token or nil
		)
	end
	local expected_state = _state
	local expected_epoch = _lifecycle_epoch
	local expected_token = lease_snapshot.token
	if _lease_inputs_tainted then
		if required_phase ~= "paused" then
			return fail_lease_bound_input_start(
				"tainted F17 handles cannot be repaired while rules are ACTIVE",
				false,
				expected_token
			)
		end
		-- A registrar delete failure retains a deliberately disabled handle. Its
		-- non-nil Lua object is not proof of liveness, so retry exact cleanup while
		-- rules are still PAUSED before deciding whether fresh binds are safe.
		if stop_lease_bound_inputs() ~= true then
			return fail_lease_bound_input_start(
				"tainted F17 handles could not be released before resume",
				true,
				expected_token
			)
		end
	end
	local has_all_hotkeys = _state.hotkey_cycle_windows and _state.hotkey_alt_tab_windows
		and _state.hotkey_alt_tab_apps and _state.hotkey_alt_tab_monitor
	if required_phase == "active" and not has_all_hotkeys then
		return fail_lease_bound_input_start(
			"an ACTIVE lease was observed before all F17 consumers existed",
			false,
			expected_token
		)
	end
	if not has_all_hotkeys and (_state.hotkey_cycle_windows or _state.hotkey_alt_tab_windows
		or _state.hotkey_alt_tab_apps or _state.hotkey_alt_tab_monitor) then
		return fail_lease_bound_input_start(
			"partial F17 hotkey state existed before startup",
			retain_if_paused,
			expected_token
		)
	end
	local uncommitted_watcher = nil
	if not _state.watcher then
		local ok_ge, gestures_engine = pcall(require, "modules.gestures.engine")
		if not ok_ge then gestures_engine = nil end
		local watcher_ok, watcher_or_err = xpcall(function()
			return Watchers.start_gesture_watcher(gestures_engine, expected_token)
		end, debug.traceback)
		if not watcher_ok or watcher_or_err == nil then
			return fail_lease_bound_input_start(watcher_ok
				and "gesture watcher returned nil"
				or watcher_or_err, retain_if_paused, expected_token)
		end
		uncommitted_watcher = watcher_or_err
	end
	if has_all_hotkeys then
		local final_ok, final_phase, final_snapshot = pcall(LeaseController.status)
		if not final_ok or not _running or _lifecycle_epoch ~= expected_epoch
			or _state ~= expected_state or not inputs_are_authorized()
			or final_phase ~= required_phase or type(final_snapshot) ~= "table"
			or final_snapshot.token ~= expected_token then
			rollback_uncommitted_inputs({}, uncommitted_watcher, false)
			return fail_lease_bound_input_start(
				"lease ownership changed during gesture watcher startup",
				retain_if_paused,
				expected_token
			)
		end
		if uncommitted_watcher then _state.watcher = uncommitted_watcher end
		return true, "already-started"
	end

	local handles = {}
	local bind_ok, bind_err = xpcall(function()
		handles[1] = Watchers.start_cycle_windows_hotkey()
		if not handles[1] then error("cycle-windows hotkey returned nil") end
		handles[2] = Watchers.start_alt_tab_windows_hotkey()
		if not handles[2] then error("Alt+Tab windows hotkey returned nil") end
		handles[3] = Watchers.start_alt_tab_monitor_hotkey()
		if not handles[3] then error("per-screen window hotkey returned nil") end
		-- Keep the app-switch tracker last so every earlier refusal can roll back
		-- without creating that shared watcher.
		handles[4] = Watchers.start_alt_tab_apps_hotkey()
		if not handles[4] then error("Alt+Tab apps hotkey returned nil") end
	end, debug.traceback)
	if not bind_ok then
		rollback_uncommitted_inputs(handles, uncommitted_watcher, true)
		return fail_lease_bound_input_start(bind_err, retain_if_paused, expected_token)
	end

	-- Binders do not yield in production, but a re-entrant test double must not
	-- be able to publish handles into a replacement lifecycle or generation.
	local final_ok, final_phase, final_snapshot = pcall(LeaseController.status)
	if not final_ok or not _running or _lifecycle_epoch ~= expected_epoch
		or _state ~= expected_state or not inputs_are_authorized()
		or final_phase ~= required_phase or type(final_snapshot) ~= "table"
		or final_snapshot.token ~= expected_token then
		rollback_uncommitted_inputs(handles, uncommitted_watcher, true)
		return fail_lease_bound_input_start(
			"lease ownership changed during F17 binding",
			retain_if_paused,
			expected_token
		)
	end

	_state.hotkey_cycle_windows = handles[1]
	_state.hotkey_alt_tab_windows = handles[2]
	_state.hotkey_alt_tab_monitor = handles[3]
	_state.hotkey_alt_tab_apps = handles[4]
	if uncommitted_watcher then _state.watcher = uncommitted_watcher end
	_lease_inputs_tainted = false
	Logger.debug(LOG, "Lease-owned F17 hotkeys bound atomically before activation.")
	return true, "inputs-ready"
end

--- Refreshes the keylogger classifier without letting a failure disappear from
--- the asynchronous lease callback that owns activation.
--- @return boolean refreshed
--- @return any reason
local function refresh_managed_output_set()
	if not KcBridge or type(KcBridge.refresh_managed_set) ~= "function" then
		Logger.error(LOG, "Managed-output classifier refresh API is unavailable.")
		return false, "classifier-unavailable"
	end
	local ok, result = xpcall(function()
		return KcBridge.refresh_managed_set(_state.tap_hold_config, M.AVAILABLE_ACTIONS)
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Managed-output classifier refresh failed before lease activation: %s.",
			tostring(result))
		return false, result
	end
	return true, result
end

--- Completes one exact generation activation. A fresh/recovering generation is
--- deliberately started PAUSED: all F17 consumers and the KC classifier are
--- installed first, then RESUME is the final mutating step. Because these Lua
--- operations run synchronously on Hammerspoon's main loop, no user event can
--- interleave between the last successful bind and sending RESUME.
--- @param options table Activation policy and optional pre-RESUME commit hook.
--- @param on_done function Callback fn(ok, reason).
--- @return boolean accepted
local function activate_lease_generation(options, on_done)
	options = options or {}
	local retain_if_paused = options.retain_if_paused == true
	local respect_pause_intent = options.respect_pause_intent == true
	local settled = false
	local function finish(ok, reason)
		if settled then return end
		settled = true
		invoke_public_callback("lease activation", on_done, ok == true, reason)
	end

	local status_ok, phase, snapshot = pcall(LeaseController.status)
	local token = type(snapshot) == "table" and snapshot.token or nil
	if not status_ok or (phase ~= "paused" and phase ~= "active")
		or type(token) ~= "string" then
		local _, reason = fail_lease_bound_input_start(
			"activation did not expose an exact settled generation",
			retain_if_paused,
			token
		)
		finish(false, reason)
		return false
	end

	local script_paused = false
	if respect_pause_intent and phase == "paused" then
		local ok_shortcuts, shortcuts = pcall(require, "modules.shortcuts")
		if ok_shortcuts and shortcuts and type(shortcuts.is_paused) == "function" then
			local ok_paused, paused_or_err = pcall(shortcuts.is_paused)
			if not ok_paused then
				local _, reason = fail_lease_bound_input_start(
					"script pause-state query failed: " .. tostring(paused_or_err),
					retain_if_paused,
					token
				)
				finish(false, reason)
				return false
			end
			script_paused = paused_or_err == true
		end
	end
	local pause_won = phase == "paused" and respect_pause_intent
		and (script_paused or snapshot.activation_blocked == true)
	if pause_won then
		if type(options.before_resume) == "function" then
			local hook_ok, committed, commit_reason = xpcall(options.before_resume, debug.traceback)
			if not hook_ok or committed ~= true then
				local _, reason = fail_lease_bound_input_start(
					"paused activation commit failed: "
						.. tostring(hook_ok and commit_reason or committed),
					false,
					token
				)
				finish(false, reason)
				return false
			end
		end
		clear_managed_output_set()
		stop_lease_bound_inputs()
		finish(true, "ready-paused-by-user-intent")
		return true
	end

	local inputs_ok, inputs_reason = start_lease_bound_inputs(phase, retain_if_paused)
	if inputs_ok ~= true then
		finish(false, inputs_reason)
		return false
	end

	local classifier_ok, classifier_reason = refresh_managed_output_set()
	if classifier_ok ~= true then
		local _, reason = fail_lease_bound_input_start(
			"managed-output classifier unavailable: " .. tostring(classifier_reason),
			retain_if_paused,
			token
		)
		finish(false, reason)
		return false
	end

	if type(options.before_resume) == "function" then
		local hook_ok, committed, commit_reason = xpcall(options.before_resume, debug.traceback)
		if not hook_ok or committed ~= true then
			local _, reason = fail_lease_bound_input_start(
				"pre-RESUME commit failed: " .. tostring(hook_ok and commit_reason or committed),
				retain_if_paused,
				token
			)
			finish(false, commit_reason or reason)
			return false
		end
	end

	if phase == "active" then
		finish(true, "already-active")
		return true
	end

	local callback_fired = false
	local safely_remained_paused = false
	local call_ok, accepted_or_err = xpcall(function()
		local resume_method = respect_pause_intent
			and LeaseController.resume_prepared or LeaseController.resume
		if type(resume_method) ~= "function" then
			error("exact prepared-lease resume API is unavailable")
		end
		local function settle_resume(resumed, resume_reason)
			if callback_fired then
				Logger.warn(LOG, "Duplicate prepared-lease RESUME callback ignored.")
				return
			end
			callback_fired = true
			if resumed ~= true then
				if respect_pause_intent and resume_reason == "pause-intent-pending"
					and exact_generation_phase(token) == "paused" then
					safely_remained_paused = true
					clear_managed_output_set()
					stop_lease_bound_inputs()
					finish(true, "ready-paused-by-user-intent")
					return
				end
				local _, failure_reason = fail_lease_bound_input_start(
					"prepared lease RESUME failed: " .. tostring(resume_reason),
					retain_if_paused,
					token
				)
				if exact_generation_phase(token) == "paused" then clear_managed_output_set() end
				finish(false, resume_reason or failure_reason)
				return
			end

			local final_ok, final_phase, final_snapshot = pcall(LeaseController.status)
			if not final_ok or final_phase ~= "active"
				or type(final_snapshot) ~= "table" or final_snapshot.token ~= token then
				local _, failure_reason = fail_lease_bound_input_start(
					"RESUMED did not publish the captured ACTIVE generation",
					false,
					token
				)
				finish(false, failure_reason)
				return
			end
			finish(true, resume_reason or "resumed")
		end
		if resume_method == LeaseController.resume_prepared then
			return resume_method(token, settle_resume)
		end
		return resume_method(settle_resume)
	end, debug.traceback)

	if not call_ok then
		local _, reason = fail_lease_bound_input_start(
			"prepared lease RESUME raised: " .. tostring(accepted_or_err),
			retain_if_paused,
			token
		)
		if exact_generation_phase(token) == "paused" then clear_managed_output_set() end
		finish(false, reason)
		return false
	end
	if accepted_or_err ~= true and not callback_fired then
		local _, reason = fail_lease_bound_input_start(
			"prepared lease RESUME request was rejected",
			retain_if_paused,
			token
		)
		if exact_generation_phase(token) == "paused" then clear_managed_output_set() end
		finish(false, reason)
		return false
	end
	return accepted_or_err == true or safely_remained_paused
end

--- Joins every regeneration callback targeting the same generation to one
--- local mount + RESUME transaction. READY callbacks are settled sequentially;
--- without this join, the first callback moves PAUSED→RESUMING and the second
--- mistakes that healthy in-flight state for an invariant failure.
--- @param options table Activation policy passed to activate_lease_generation.
--- @param on_done function Callback fn(ok, reason).
--- @return boolean accepted
local function start_or_join_lease_activation(options, on_done)
	local status_ok, _, snapshot = pcall(LeaseController.status)
	local token = type(snapshot) == "table" and snapshot.token or nil
	if not status_ok or type(token) ~= "string" then
		invoke_public_callback("lease activation", on_done, false, "activation-token-unavailable")
		return false
	end

	local existing = _activation_transaction
	if existing and not existing.settled then
		if existing.token ~= token then
			invoke_public_callback("lease activation", on_done, false, "activation-generation-changed")
			return false
		end
		existing.callbacks[#existing.callbacks + 1] = on_done
		return true
	end

	local transaction = {
		token = token,
		callbacks = { on_done },
		settled = false,
		ok = false,
	}
	_activation_transaction = transaction
	local function settle(ok, reason)
		if transaction.settled then return end
		transaction.settled = true
		transaction.ok = ok == true
		if _activation_transaction == transaction then _activation_transaction = nil end
		local callbacks = transaction.callbacks
		transaction.callbacks = {}
		for _, callback in ipairs(callbacks) do
			invoke_public_callback("lease activation join", callback, ok == true, reason)
		end
	end

	local call_ok, accepted_or_err = xpcall(function()
		return activate_lease_generation(options, settle)
	end, debug.traceback)
	if not call_ok then
		settle(false, accepted_or_err)
		return false
	end
	if accepted_or_err ~= true and not transaction.settled then
		settle(false, "activation-request-rejected")
	end
	return accepted_or_err == true or transaction.ok == true
end

--- Releases derivative state after every settled non-active lease transition.
--- In-flight pause/resume commands retain the last settled classification until
--- their ACK, avoiding a double-count window while Karabiner still has old state.
--- @param phase string Lease-controller lifecycle phase.
local function on_lease_phase(phase)
	if not _running then return end
	-- A bounded heartbeat retry retains the last settled mode. Tearing down and
	-- immediately rebuilding derivative inputs during that one-second recovery
	-- window would create user-visible churn without improving fail-closedness.
	if phase == "recovering" then return end
	-- FENCING means the protocol failed, not that the tombstone transport has
	-- completed. Retain both consumers and classification until IDLE/FAILED;
	-- otherwise still-live rules can emit an F17 with nobody listening.
	if phase == "fencing" then return end
	-- A normal STOPPING is only an accepted disable/quit intent. Rules can still
	-- emit until STOPPED, so consumers and classification remain live to avoid a
	-- transient missing-output window. The settled IDLE phase releases both.
	if phase == "stopping" then return end
	if phase == "idle" or phase == "prepared" or phase == "starting"
		or phase == "paused" or phase == "failed" then
		clear_managed_output_set()
		stop_lease_bound_inputs()
		KeLifecycle.stop()
	end
end

local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — module not initialized.", func_name)
		return false
	end
	return true
end

--- Runs work originating at an async Hammerspoon boundary and file-logs failures.
--- @param label string Stable diagnostic label.
--- @param callback function Work to execute.
--- @return boolean ok
--- @return any result
local function run_async_step(label, callback)
	local ok, result = xpcall(callback, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s failed: %s.", label, tostring(result))
		return false, nil
	end
	return true, result
end

--- Returns whether an async callback still belongs to the initialized lifecycle.
--- @param epoch integer Epoch captured when work was scheduled.
--- @return boolean current
local function is_current_lifecycle(epoch)
	return _running and _lifecycle_epoch == epoch and _state ~= nil
end

--- Resolves the current action list without silently swallowing malformed layout data.
--- @param label string Diagnostic context.
--- @return boolean ok
--- @return number|nil resolved_count
local function resolve_current_layout_actions(label)
	if M.AVAILABLE_ACTIONS == nil then return true, 0 end
	return run_async_step(label, function()
		return Config.resolve_layout_actions(M.AVAILABLE_ACTIONS)
	end)
end

--- Reads the pause state fail-closed and returns the same module for rebind.
--- @param label string Diagnostic context.
--- @return boolean ok
--- @return table|nil shortcuts
--- @return boolean|nil paused
local function query_shortcuts_pause_state(label)
	local ok, result = run_async_step(label, function()
		local shortcuts = require("modules.shortcuts")
		if type(shortcuts) ~= "table" or type(shortcuts.is_paused) ~= "function" then
			error("modules.shortcuts.is_paused is unavailable")
		end
		local paused = shortcuts.is_paused()
		if type(paused) ~= "boolean" then error("modules.shortcuts.is_paused returned a non-boolean") end
		return { shortcuts = shortcuts, paused = paused }
	end)
	if not ok then return false, nil, nil end
	return true, result.shortcuts, result.paused
end

--- Executes the one canonical post-TIS-settle layout refresh pipeline.
--- Both input-source notifications and wake events schedule this function.
--- @param layout_name string|nil Notification layout label, if known.
--- @param source string Stable event source for diagnostics.
--- @param epoch integer Scheduling lifecycle epoch.
local function perform_settled_layout_refresh(layout_name, source, epoch)
	if not is_current_lifecycle(epoch) then return end
	local pause_ok, shortcuts, paused = query_shortcuts_pause_state(
		"Settled " .. source .. " pause-state query"
	)
	if not pause_ok or not is_current_lifecycle(epoch) then return end

	local resolved_count = nil
	if paused or not _state.enabled then
		local resolved_ok
		resolved_ok, resolved_count = resolve_current_layout_actions(
			"Settled " .. source .. " layout-action resolution"
		)
		if not resolved_ok or not is_current_lifecycle(epoch) then return end
	end

	if paused then
		Logger.info(LOG, "%s refresh: re-resolved %s action(s), not redeploying — script is paused.",
			source, tostring(resolved_count))
		return
	end

	if _state.enabled then
		-- regenerate() owns the one active-mode resolution immediately before its
		-- consumer. Resolving here as well would double the layout hot-path walk.
		local regenerate_ok, accepted = run_async_step(
			"Settled " .. source .. " Karabiner regeneration",
			function() return M.regenerate() end
		)
		if not regenerate_ok or accepted ~= true then
			if regenerate_ok then
				Logger.error(LOG, "Settled %s Karabiner regeneration was rejected.", source)
			end
			return
		end
	else
		Logger.info(LOG, "%s refresh: re-resolved %s action(s); bridge disabled, no redeploy.",
			source, tostring(resolved_count))
	end
	if not is_current_lifecycle(epoch) then return end

	if type(shortcuts.rebind_for_layout) == "function" then
		local rebind_ok, rebound = run_async_step(
			"Settled " .. source .. " shortcut rebind",
			shortcuts.rebind_for_layout
		)
		if rebind_ok and rebound then
			Logger.info(LOG, "Shortcuts rebound for layout '%s'.", tostring(layout_name or "current"))
		elseif rebind_ok then
			Logger.debug(LOG, "Shortcuts not rebound for layout '%s' — layer is stopped.",
				tostring(layout_name or "current"))
		end
	end
end

--- Debounces layout work until macOS TIS has published the post-event key map.
--- @param layout_name string|nil Notification layout label, if known.
--- @param source string Stable event source for diagnostics.
--- @param epoch integer Scheduling lifecycle epoch.
--- @return boolean scheduled
local function schedule_layout_refresh(layout_name, source, epoch)
	if not is_current_lifecycle(epoch) then return false end
	if _layout_rebuild_timer then
		pcall(function() _layout_rebuild_timer:stop() end)
		_layout_rebuild_timer = nil
	end
	local timer = nil
	local armed = false
	local fired_before_arm = false
	local timer_ok, timer_or_err = pcall(hs.timer.doAfter, LAYOUT_TIS_SETTLE_SEC, function()
		if not armed then
			fired_before_arm = true
			return
		end
		-- A stopped callback can already be queued when a newer event replaces it.
		-- Only the currently retained timer may clear the handle or perform work.
		if _layout_rebuild_timer ~= timer then return end
		_layout_rebuild_timer = nil
		local ok = run_async_step("Delayed " .. source .. " layout refresh", function()
			perform_settled_layout_refresh(layout_name, source, epoch)
		end)
		if not ok then return end
	end)
	timer = timer_or_err
	local timer_type = type(timer_or_err)
	if not timer_ok or (timer_type ~= "table" and timer_type ~= "userdata")
		or type(timer_or_err.stop) ~= "function" or fired_before_arm then
		if timer_ok and (timer_type == "table" or timer_type == "userdata")
			and type(timer_or_err.stop) == "function" then
			pcall(function() timer_or_err:stop() end)
		end
		Logger.error(LOG, "Could not schedule %s layout refresh: %s.", source, tostring(timer_or_err))
		return false
	end
	_layout_rebuild_timer = timer_or_err
	armed = true
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
--- When enabling: deploys inert token-gated rules, then activates the exact lease.
--- When disabling: revokes only that lease; stock Karabiner remains user-managed.
--- @param value boolean
--- @param on_done function|nil Callback fn(ok, reason) after READY or STOPPED.
--- @return boolean True when accepted or already settled.
function M.set_enabled(value, on_done)
	if not require_state("set_enabled") then
		invoke_public_callback("set_enabled", on_done, false, "not-initialized")
		return false
	end
	local target_enabled = value == true
	if _enabled_transition then
		local transition_targets_enabled = _enabled_transition.kind == "enabling"
			or _enabled_transition.kind == "enable-aborting"
		if target_enabled == transition_targets_enabled then
			if type(on_done) == "function" then
				_enabled_transition.callbacks[#_enabled_transition.callbacks + 1] = on_done
			end
			Logger.debug(LOG, "Joined the in-flight Karabiner %s transaction.",
				transition_targets_enabled and "enable" or "disable")
			return true
		end
		Logger.warn(LOG, "Karabiner state request rejected while the opposite transition is in flight.")
		invoke_public_callback("set_enabled", on_done, false, "transition-in-progress")
		return false
	end

	local was_enabled = _state.enabled == true
	if target_enabled == was_enabled then
		invoke_public_callback("set_enabled", on_done, true,
			target_enabled and "already-enabled" or "already-disabled")
		return true
	end

	if target_enabled then
		local transaction = { kind = "enabling", callbacks = {} }
		if type(on_done) == "function" then transaction.callbacks[1] = on_done end
		_enabled_transition = transaction
		Logger.info(LOG, "Karabiner integration enable requested; awaiting READY before commit.")

		local function finish_enable_failure(enable_reason)
			if _enabled_transition ~= transaction then return end
			transaction.kind = "enable-aborting"
			if transaction.committed then
				local rollback_saved = persist_enabled_flag(false)
				_state.enabled = false
				transaction.committed = false
				if not rollback_saved then
					Logger.error(LOG,
						"Failed enable rolled back in memory but enabled=false could not be persisted.")
				end
			end
			-- The preference commit happens before RESUME, so a later failure can
			-- observe rules that are ACTIVE or whose acknowledgement is in flight.
			-- Never dismantle F17 consumers/classification here; they stay mounted
			-- until the exact STOPPED/fallback fence below settles.
			Logger.error(LOG, "Karabiner enable activation failed: %s; revoking its exact generation.",
				tostring(enable_reason))

			local stop_callback_fired = false
			local function finish_after_stop(stopped, stop_reason)
				stop_callback_fired = true
				if _enabled_transition ~= transaction then return end
				if stopped == true then
					clear_managed_output_set()
					stop_lease_bound_inputs()
				else
					Logger.error(LOG,
						"Failed enable retained lease-bound consumers because STOPPED was not proven: %s.",
						tostring(stop_reason))
				end
				_enabled_transition = nil
				Logger.warn(LOG, "Karabiner enable transaction remained disabled after teardown (%s).",
					tostring(stop_reason))
				settle_enabled_callbacks(transaction, false, enable_reason or "enable-failed")
			end
			local ok_stop, stop_requested = pcall(
				LeaseController.stop,
				"integration_enable_failed",
				finish_after_stop
			)
			if not ok_stop then
				finish_after_stop(false, "stop-raised")
			elseif not stop_requested and not stop_callback_fired then
				finish_after_stop(false, "stop-request-rejected")
			end
		end

		local regenerate_callback_fired = false
		local function finish_enable(ok, reason)
			regenerate_callback_fired = true
			if _enabled_transition ~= transaction then return end
			if ok == true and transaction.committed == true then
				_enabled_transition = nil
				Logger.info(LOG, "Karabiner integration enabled after READY acknowledgement.")
				settle_enabled_callbacks(transaction, true, reason or "ready")
				return
			end
			finish_enable_failure(reason or "enable-failed")
		end

		local ok_regenerate, regenerate_requested = pcall(M.regenerate, finish_enable, transaction)
		if not ok_regenerate then
			finish_enable_failure("regenerate-raised")
			return _enabled_transition == transaction
		end
		if not regenerate_requested and not regenerate_callback_fired
			and _enabled_transition == transaction then
			finish_enable_failure("regenerate-request-rejected")
		end
		return regenerate_requested == true or _enabled_transition == transaction
	end

	local transaction = { kind = "disabling", callbacks = {} }
	if type(on_done) == "function" then transaction.callbacks[1] = on_done end
	_enabled_transition = transaction
	Logger.info(LOG, "Karabiner integration disable requested; awaiting STOPPED.")

	local function finish_recovery(recovered, recovery_reason, disable_reason)
		if _enabled_transition ~= transaction then return end
		_enabled_transition = nil
		if recovered then
			Logger.warn(LOG, "Disable failed; the previous enabled state was restored after READY.")
		else
			Logger.error(LOG, "Disable rollback failed before READY: %s.", tostring(recovery_reason))
		end
		settle_enabled_callbacks(transaction, false,
			disable_reason or recovery_reason or "disable-failed")
	end

	local function rollback_enabled_state(disable_reason)
		if _enabled_transition ~= transaction then return end
		transaction.kind = "recovering"
		Logger.error(LOG, "Karabiner disable did not receive STOPPED: %s; restoring a fresh lease.",
			tostring(disable_reason))
		local ok_recovery, recovery_requested = pcall(M.regenerate, function(ok, reason)
			finish_recovery(ok == true, reason, disable_reason)
		end, PAUSED_DISABLE_RECOVERY)
		if not ok_recovery then
			Logger.error(LOG, "Disable rollback raised before READY: %s.", tostring(recovery_requested))
			finish_recovery(false, "rollback-raised", disable_reason)
		elseif not recovery_requested and _enabled_transition == transaction then
			finish_recovery(false, "rollback-request-rejected", disable_reason)
		end
	end

	local callback_fired = false
	local ok_stop, stop_requested = pcall(LeaseController.stop, "integration_disabled", function(ok, reason)
		callback_fired = true
		if _enabled_transition ~= transaction then return end
		if ok ~= true then
			rollback_enabled_state(reason)
			return
		end

		if not persist_enabled_flag(false) then
			rollback_enabled_state("persistence-failed-after-STOPPED")
			return
		end
		_state.enabled = false
		clear_managed_output_set()
		stop_lease_bound_inputs()
		_enabled_transition = nil
		Logger.info(LOG, "Karabiner integration disabled after exact lease fencing.")
		settle_enabled_callbacks(transaction, true, reason or "stopped")
	end)
	if not ok_stop then
		rollback_enabled_state(stop_requested)
		return false
	end
	if not stop_requested and not callback_fired then
		rollback_enabled_state("stop-request-rejected")
	end
	return stop_requested == true
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
--- @param on_done function|nil Callback fn(ok, reason) after READY or failure.
--- @param recovery_capability any Private enable/rollback/resume capability; public callers omit it.
--- @return boolean True when deployment and activation request were accepted.
function M.regenerate(on_done, recovery_capability)
	local enable_transaction = recovery_capability
	local is_enable_transition = type(enable_transaction) == "table"
		and enable_transaction == _enabled_transition
		and enable_transaction.kind == "enabling"
	local is_disable_recovery = recovery_capability == PAUSED_DISABLE_RECOVERY
	local is_resume_regeneration = recovery_capability == PAUSED_RESUME_REGENERATION
	local callback_settled = false
	local function finish(ok, reason)
		if callback_settled then return end
		callback_settled = true
		invoke_public_callback("regenerate", on_done, ok, reason)
	end
	local function fail(reason)
		finish(false, reason)
		return false
	end
	if not require_state("regenerate") then return fail("not-initialized") end
	if _shutdown_requested then
		Logger.debug(LOG, "Regenerate skipped — exact lease shutdown is in progress.")
		return fail("shutdown-in-progress")
	end
	if _enabled_transition and _enabled_transition.kind == "disabling" then
		Logger.debug(LOG, "Regenerate skipped — Karabiner disable fencing is in progress.")
		return fail("disable-in-progress")
	end
	if not _state.enabled and not is_enable_transition then
		Logger.debug(LOG, "Regenerate skipped — Karabiner integration is disabled.")
		return fail("integration-disabled")
	end

	-- « pause = tout éteint ». Normal rules are now also gated by the exact pause
	-- variable, so a rebuild cannot reactivate them. It would still perform config
	-- I/O and touch the lease lifecycle behind a paused UI, however. Keep the guard
	-- in the function that performs the deploy so every current and future caller
	-- inherits the same no-work-under-pause contract.
	--
	-- Resume is the one active-mode exception: its private capability keeps
	-- script_control paused until deploy, READY and lease-bound input startup all
	-- succeed. Failed-disable and enable capabilities instead provision a fresh
	-- generation atomically paused, never normal-first
	local ok_sc, shortcuts = pcall(require, "modules.shortcuts")
	local script_is_paused = ok_sc
		and shortcuts
		and type(shortcuts.is_paused) == "function"
		and shortcuts.is_paused() == true
	if script_is_paused and not is_disable_recovery and not is_enable_transition
		and not is_resume_regeneration then
		Logger.info(LOG, "Regenerate skipped — script is paused (« pause = tout éteint »).")
		return fail("script-paused")
	end
	Logger.start(LOG, "Regenerating Karabiner config…")

	-- Re-resolve the layout-dependent key codes against the layout that is active
	-- NOW, immediately before the table is consumed.
	--
	-- The refresh and the consumer used to live on different paths. The layout
	-- watcher refreshed M.AVAILABLE_ACTIONS and then hit the pause guard and
	-- returned; regenerate() consumed the table and never refreshed. So a layout
	-- change while paused — which is the normal case, because the pause-layout
	-- feature switches the user off Ergopti as part of pausing — left the table
	-- resolved for the PAUSE layout, and the resume deployed a Karabiner config
	-- built for a layout that was no longer active.
	--
	-- Cheap enough to do unconditionally: load_available_actions memoises the
	-- built list, so this walks the logical_char entries and mutates their key
	-- codes in place rather than rebuilding 673 action tables.
	if M.AVAILABLE_ACTIONS then
		local layout_ok = resolve_current_layout_actions("Karabiner regeneration layout-action resolution")
		if not layout_ok then return fail("layout-resolution-failed") end
	end

	local lease_token = LeaseController.token()
	if type(lease_token) ~= "string" then
		Logger.error(LOG, "Karabiner generation refused — no exact Ergopti lease token is available.")
		return fail("token-unavailable")
	end

	local ok_build, result, build_err, legacy_rules, legacy_context = pcall(
		Generator.build_karabiner_json,
		_state,
		M.AVAILABLE_ACTIONS,
		M.TAP_HOLD_KEYS,
		M.MOD_COMBOS,
		M.NON_CANONICAL_COMBOS,
		_DATA_DIR,
		lease_token
	)
	if not ok_build or type(result) ~= "table" then
		Logger.error(LOG, "JSON generation failed: %s.", tostring(ok_build and build_err or result))
		return fail("generation-failed")
	end

	local deployed, deploy_detail = Generator.merge_and_deploy_config(
		result,
		KARABINER_OUT,
		legacy_rules,
		legacy_context
	)
	if not deployed then
		Logger.error(LOG, "Karabiner deploy failed → '%s': %s.",
			KARABINER_OUT, tostring(deploy_detail))
		return fail("deploy-failed")
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

	Logger.success(LOG,
		"Karabiner config regenerated: %d combo(s) + %d tap/hold key(s) deployed.",
		active_combos, #M.TAP_HOLD_KEYS)

	-- A newly prepared generation always starts with mode=PAUSED. Publishing
	-- ACTIVE at READY would let Karabiner emit F17 before Hammerspoon receives and
	-- processes that stdout line. Existing ACTIVE generations already own all
	-- consumers and can join the ordinary start path without a mode transition.
	local status_ok, status_phase = pcall(LeaseController.status)
	if not status_ok then return fail("lease-status-unavailable") end
	local start_lease
	if status_phase == "active" then
		start_lease = function(on_ready)
			on_ready(true, "already-active")
			return true
		end
	elseif status_phase == "prepared" or status_phase == "starting"
		or status_phase == "paused" then
		start_lease = LeaseController.start_paused
	else
		Logger.error(LOG, "Karabiner lease cannot regenerate from phase '%s'.",
			tostring(status_phase))
		return fail("invalid-lease-phase")
	end

	local start_callback_fired = false
	local function handle_start(ok, reason)
		if start_callback_fired then
			Logger.warn(LOG, "Duplicate Karabiner lease start callback ignored.")
			return
		end
		start_callback_fired = true
		if ok ~= true then
			Logger.error(LOG, "Ergopti Karabiner lease preparation failed: %s.", tostring(reason))
			finish(false, reason or "activation-failed")
			return
		end

		local activation_callback_fired = false
		local activation_ok, activation_requested_or_err = xpcall(function()
			local before_resume = nil
			if is_enable_transition then
				before_resume = function() return commit_enable_transition(enable_transaction) end
			end
			return start_or_join_lease_activation({
				retain_if_paused = is_resume_regeneration,
				respect_pause_intent = not is_resume_regeneration,
				before_resume = before_resume,
			}, function(activated, activation_reason)
				if activation_callback_fired then return end
				activation_callback_fired = true
				if activated ~= true then
					Logger.error(LOG, "Prepared Karabiner lease activation failed: %s.",
						tostring(activation_reason))
					finish(false, activation_reason or "activation-failed")
					return
				end
				if activation_reason == "ready-paused-by-user-intent" then
					Logger.success(LOG, "Ergopti Karabiner lease remained PAUSED for the latest user intent.")
				else
					Logger.success(LOG, "Ergopti Karabiner lease activated after local input preparation.")
				end
				KeLifecycle.notify_ready()
				finish(true, activation_reason or reason or "ready")
			end)
		end, debug.traceback)
		if not activation_ok then
			local _, failure_reason = fail_lease_bound_input_start(
				"prepared activation callback raised: " .. tostring(activation_requested_or_err),
				is_resume_regeneration,
				lease_token
			)
			if not activation_callback_fired then finish(false, failure_reason) end
		elseif activation_requested_or_err ~= true and not activation_callback_fired then
			finish(false, "activation-request-rejected")
		end
	end
	local start_call_ok, start_requested_or_err = xpcall(function()
		return start_lease(handle_start)
	end, debug.traceback)
	if not start_call_ok then
		Logger.error(LOG, "Ergopti Karabiner lease preparation raised: %s.",
			tostring(start_requested_or_err))
		if not start_callback_fired then finish(false, "activation-request-raised") end
		return false
	end
	if start_requested_or_err ~= true then
		Logger.error(LOG, "Ergopti Karabiner lease preparation could not be requested.")
		if not start_callback_fired then finish(false, "activation-request-rejected") end
		return false
	end
	return true
end

--- Selects the pause-only managed rules through the exact generation variable.
--- No config file or stock Karabiner process is touched.
--- Does nothing when the integration is disabled.
--- @param on_done function|nil Callback fn(ok, reason) after PAUSED or failure.
function M.pause(on_done)
	if not _state or not _state.enabled then
		invoke_public_callback("pause", on_done, false, "integration-disabled")
		return false
	end
	Logger.start(LOG, "Pausing ErgoptiPlus Karabiner remapping…")
	local callback_fired = false
	local requested = LeaseController.pause(function(ok, reason)
		callback_fired = true
		if ok then
			Logger.success(LOG, "ErgoptiPlus Karabiner remapping paused (script-control rules retained).")
		else
			Logger.error(LOG, "Karabiner pause variable update failed: %s.", tostring(reason))
		end
		invoke_public_callback("pause", on_done, ok == true, reason)
	end)
	if not requested then
		Logger.error(LOG, "Karabiner pause could not be requested.")
		if not callback_fired then
			invoke_public_callback("pause", on_done, false, "request-rejected")
		end
		return false
	end
	return true
end

--- Restores the full Karabiner config as one fail-closed resume transaction.
--- Deploy and every local consumer are prepared while the exact generation is
--- still PAUSED; RESUME is sent last, and success is published only after its
--- acknowledgement names the same ACTIVE token.
--- @param on_done function|nil Callback fn(ok, reason) after the full transaction.
function M.resume(on_done)
	if not _state or not _state.enabled then
		invoke_public_callback("resume", on_done, false, "integration-disabled")
		return false
	end
	if _enabled_transition and _enabled_transition.kind == "disabling" then
		Logger.debug(LOG, "Resume skipped — Karabiner disable fencing is in progress.")
		invoke_public_callback("resume", on_done, false, "disable-in-progress")
		return false
	end
	Logger.start(LOG, "Resuming ErgoptiPlus Karabiner remapping…")
	local callback_fired = false
	local function finish_resume(ok, reason)
		if callback_fired then return end
		callback_fired = true
		if ok == true then
			Logger.success(LOG, "ErgoptiPlus Karabiner remapping resumed after paused preparation.")
		else
			Logger.error(LOG, "Karabiner resume transaction failed while remaining fail-closed: %s.",
				tostring(reason))
		end
		invoke_public_callback("resume", on_done, ok == true, reason)
	end

	local call_ok, requested_or_err = xpcall(function()
		return M.regenerate(finish_resume, PAUSED_RESUME_REGENERATION)
	end, debug.traceback)
	if not call_ok then
		finish_resume(false, requested_or_err)
		return false
	end
	if requested_or_err ~= true and not callback_fired then
		finish_resume(false, "regeneration-request-rejected")
		return false
	end
	return requested_or_err == true
end

--- Removes only a fully proven historical ErgoptiPlus rule block while the
--- integration is disabled. No lease task is started and the generated B rules
--- are deliberately replaced with an empty incoming block before the merge.
--- @param file_system table Injected filesystem adapter.
--- @return boolean success Whether cleanup was unnecessary or safely deployed.
local function cleanup_disabled_legacy_rules(file_system)
	if _state.enabled then return true end
	if type(file_system.read) ~= "function" then
		Logger.error(LOG, "Disabled legacy cleanup unavailable — filesystem adapter has no read method.")
		return false
	end

	local read_ok, raw = pcall(file_system.read, KARABINER_OUT)
	if not read_ok then
		Logger.error(LOG, "Disabled legacy cleanup could not read karabiner.json: %s.", tostring(raw))
		return false
	end
	if raw == nil then return true end
	if type(raw) ~= "string" then
		Logger.error(LOG, "Disabled legacy cleanup received non-string karabiner.json content.")
		return false
	end
	local may_need_cleanup = false
	for _, signature in ipairs(DISABLED_LEGACY_PROBE_STRINGS) do
		if raw:find(signature, 1, true) then
			may_need_cleanup = true
			break
		end
	end
	if not may_need_cleanup then return true end

	local lease_token = LeaseController.token()
	if type(lease_token) ~= "string" then
		Logger.error(LOG, "Disabled legacy cleanup refused — no validation token is available.")
		return false
	end
	local ok_build, generated, build_err, legacy_rules, legacy_context = pcall(
		Generator.build_karabiner_json,
		_state,
		M.AVAILABLE_ACTIONS,
		M.TAP_HOLD_KEYS,
		M.MOD_COMBOS,
		M.NON_CANONICAL_COMBOS,
		_DATA_DIR,
		lease_token
	)
	if not ok_build or type(generated) ~= "table" then
		Logger.error(
			LOG,
			"Disabled legacy cleanup could not build its ownership proof: %s.",
			tostring(ok_build and build_err or generated)
		)
		return false
	end

	-- The build above exists only to reconstruct old ownership across state/layout
	-- changes. Installing any newly built manipulator while disabled would violate
	-- the user's explicit off state
	generated.profiles[1].complex_modifications.rules = {}
	local deployed, deploy_detail = Generator.merge_and_deploy_config(
		generated,
		KARABINER_OUT,
		legacy_rules,
		legacy_context
	)
	if not deployed then
		Logger.error(
			LOG,
			"Disabled legacy cleanup deploy failed: %s.",
			tostring(deploy_detail)
		)
		return false
	end
	Logger.info(LOG, "Disabled legacy ErgoptiPlus rules removed; personal rules and stock Karabiner were untouched.")
	return true
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

	-- Controller initialization is memory-only: it validates dependencies and
	-- prepares a generation token without spawning a task or touching Karabiner.
	-- This is safe even when the persisted integration setting is disabled.
	if not LeaseController.init(on_lease_phase) then
		Logger.error(LOG, "Exact Karabiner lease controller initialization failed — remapping stays fail-closed.")
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
		hotkey_alt_tab_monitor    = nil,
	}
	_lifecycle_epoch = _lifecycle_epoch + 1
	_running = true
	_shutdown_requested = false

	-- Persisted mappings do not prove that this Hammerspoon generation owns the
	-- corresponding output keycodes. READY will populate the set after deployment.
	clear_managed_output_set()
	if not _state.enabled then cleanup_disabled_legacy_rules(file_system) end

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

	-- Gesture probes and F17 sentinels are lease-owned resources. Starting them
	-- here would intercept or mutate a personal Karabiner setup while Ergopti is
	-- disabled/starting; READY starts them through start_lease_bound_inputs().

	timed("start_input_source_watcher", function()
		Watchers.start_input_source_watcher(function(layout_name)
			run_async_step("Input-source callback", function()
				local epoch = _lifecycle_epoch
				if not is_current_lifecycle(epoch) then return end
				Logger.start(LOG, "Layout change detected — scheduling settled refresh for layout '%s'…",
					tostring(layout_name))
				schedule_layout_refresh(layout_name, "Layout-change", epoch)
			end)
		end)
	end)

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
	if ok_cw and type(cw) == "table" and type(cw.new) == "function" then
		if _wake_watcher then
			local stopped, stop_err = pcall(function() return _wake_watcher:stop() end)
			if not stopped then
				Logger.error(LOG, "Previous wake watcher could not be stopped: %s.", tostring(stop_err))
			end
			_wake_watcher = nil
		end

		local wake_epoch = _lifecycle_epoch
		local function handle_wake(event)
			if event ~= cw.systemDidWake and event ~= cw.screensDidUnlock then return end
			if not is_current_lifecycle(wake_epoch) then return end

			-- Renew the exact generation before any layout work. Sleep can fence the
			-- private watchdog while Hammerspoon still believes the previous state.
			-- This step is independent and guarded so a layout failure cannot suppress
			-- the first post-wake liveness proof.
			if _state.enabled == true then
				local refresh_ok, refreshed = run_async_step(
					"Wake exact-lease liveness refresh",
					LeaseController.refresh_liveness
				)
				if not refresh_ok or refreshed ~= true then
					Logger.warn(LOG, "Wake refresh could not renew the exact Karabiner lease liveness.")
				end
			end
			if not is_current_lifecycle(wake_epoch) then return end
			-- Wake and input-source notifications share the same post-TIS-settle
			-- pipeline. Resolving immediately here can read the pre-sleep key map, and
			-- omitting the sibling shortcut rebind leaves Hammerspoon on old scancodes.
			schedule_layout_refresh(nil, "Wake", wake_epoch)
		end
		local function on_wake(event)
			run_async_step("Wake callback", function() handle_wake(event) end)
		end

		local created, watcher_or_err = pcall(cw.new, on_wake)
		local watcher_type = type(watcher_or_err)
		if not created or (watcher_type ~= "table" and watcher_type ~= "userdata")
			or type(watcher_or_err.start) ~= "function" then
			Logger.error(LOG, "Wake watcher construction failed: %s.", tostring(watcher_or_err))
		else
			_wake_watcher = watcher_or_err
			local started, start_result = pcall(function() return _wake_watcher:start() end)
			if not started or start_result == nil or start_result == false then
				Logger.error(LOG, "Wake watcher start failed: %s.", tostring(start_result))
				pcall(function() _wake_watcher:stop() end)
				_wake_watcher = nil
			end
		end
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
				local Onboarding = require("platform.remap.onboarding")
				Onboarding.run_first_run_wizard()
			end)
		end)
	end

	Logger.success(LOG,
		"Karabiner bridge initialized (%d action(s), %d combo(s) active).",
		#M.AVAILABLE_ACTIONS, active_combos)
end

--- Releases local watchers and hotkeys only after an exact native fence.
--- @return boolean stopped True only when every local resource was released.
local function stop_local_resources()
	_running = false
	_shutdown_requested = true
	_lifecycle_epoch = _lifecycle_epoch + 1
	local all_stopped = true
	if _wake_watcher then
		local stopped, stop_result = pcall(function() return _wake_watcher:stop() end)
		if not stopped or stop_result == false then
			Logger.error(LOG, "Wake watcher stop failed: %s.", tostring(stop_result))
			all_stopped = false
		else
			_wake_watcher = nil
		end
	end
	if not _state then return all_stopped end
	Logger.start(LOG, "Stopping Karabiner bridge…")
	if clear_managed_output_set() ~= true then all_stopped = false end
	if stop_lease_bound_inputs() ~= true then all_stopped = false end
	if _layout_rebuild_timer then
		local timer_ok, timer_result = pcall(function() return _layout_rebuild_timer:stop() end)
		if not timer_ok or timer_result == false then
			Logger.error(LOG, "Layout rebuild timer stop failed: %s.", tostring(timer_result))
			all_stopped = false
		else
			_layout_rebuild_timer = nil
		end
	end
	local input_ok, input_err = pcall(Watchers.stop_input_source_watcher)
	if not input_ok or input_err ~= true then
		Logger.error(LOG, "Input-source watcher stop failed: %s.", tostring(input_err))
		all_stopped = false
	end
	local lifecycle_ok, lifecycle_err = pcall(KeLifecycle.stop)
	if not lifecycle_ok or lifecycle_err ~= true then
		Logger.error(LOG, "Karabiner lifecycle teardown failed: %s.", tostring(lifecycle_err))
		all_stopped = false
	end
	if all_stopped then
		Logger.success(LOG, "Karabiner bridge stopped.")
	else
		Logger.error(LOG, "Karabiner bridge exact lease is fenced, but local teardown is incomplete.")
	end
	return all_stopped
end

--- Releases remap-local consumers only after the controller is provably idle.
--- This is separate from lease revocation so callers never confuse a retained
--- disabled hotkey with an unfenced Karabiner generation.
--- @return boolean stopped True only when every local resource was released.
function M.teardown_local()
	local status_ok, phase = xpcall(LeaseController.status, debug.traceback)
	if not status_ok then
		Logger.error(LOG, "Cannot verify the exact lease before local teardown: %s.", tostring(phase))
		return false
	end
	if phase ~= "idle" and phase ~= "uninitialized" then
		Logger.error(LOG, "Refusing local Karabiner teardown while exact lease phase is '%s'.",
			tostring(phase))
		return false
	end
	local teardown_ok, teardown_result = xpcall(stop_local_resources, debug.traceback)
	if not teardown_ok or teardown_result ~= true then
		Logger.error(LOG, "Exact lease is fenced but local Karabiner teardown failed: %s.",
			tostring(teardown_result))
		return false
	end
	return true
end

--- Revokes only Ergopti's exact lease. Local F17 consumers stay mounted until
--- the STOPPED/fallback callback, and are deliberately owned by a later local
--- teardown transaction. Stock Karabiner processes remain user-managed.
--- @param reason string|nil Stable teardown reason for diagnostics.
--- @param on_done function|nil Callback fn(fenced, reason).
--- @return boolean True when exact revocation was accepted.
function M.revoke(reason, on_done)
	Logger.start(LOG, "Revoking the exact Ergopti Karabiner lease…")
	-- The native fence is asynchronous, but every already-queued wake/layout
	-- callback must become stale immediately. Keep F17 consumers and the KC
	-- classifier mounted until STOPPED; only reject *new* lifecycle work here.
	if not _shutdown_requested then
		_shutdown_requested = true
		_lifecycle_epoch = _lifecycle_epoch + 1
	end
	local callback_fired = false
	local callback_succeeded = false
	local function settle_revoke(ok, detail)
		if callback_fired then
			Logger.warn(LOG, "Duplicate Ergopti Karabiner revocation completion ignored.")
			return
		end
		callback_fired = true
		callback_succeeded = ok == true
		invoke_public_callback("revoke", on_done, ok == true, detail)
	end
	local call_ok, accepted_or_err = xpcall(function()
		return LeaseController.stop(reason or "hammerspoon_shutdown", function(stopped, stop_reason)
			if stopped ~= true then
				Logger.error(LOG, "Ergopti Karabiner lease revocation failed: %s.",
					tostring(stop_reason))
				settle_revoke(false, stop_reason or "revocation-failed")
				return
			end
			settle_revoke(true, stop_reason or "stopped")
		end)
	end, debug.traceback)
	if not call_ok then
		Logger.error(LOG, "Ergopti Karabiner lease revocation raised: %s.",
			tostring(accepted_or_err))
		if not callback_fired then settle_revoke(false, "revocation-raised") end
		return false
	end
	if accepted_or_err ~= true then
		Logger.error(LOG, "Ergopti Karabiner lease revocation was not accepted.")
		if not callback_fired then settle_revoke(false, "revocation-rejected") end
		return false
	end
	Logger.success(LOG, "Ergopti Karabiner lease revocation requested; stock Karabiner left untouched.")
	if callback_fired then return callback_succeeded end
	return true
end

--- Requests a fenced public stop, then releases remap-local consumers.
--- @param reason string|nil Stable teardown reason for diagnostics.
--- @param on_done function|nil Callback fn(ok, reason) after both phases.
--- @return boolean True when the transaction was accepted or completed.
function M.shutdown(reason, on_done)
	local callback_fired = false
	local callback_succeeded = false
	local function settle_shutdown(ok, detail)
		if callback_fired then return end
		callback_fired = true
		callback_succeeded = ok == true
		invoke_public_callback("shutdown", on_done, ok == true, detail)
	end

	local accepted = M.revoke(reason, function(fenced, detail)
		if fenced ~= true then
			settle_shutdown(false, detail or "revocation-failed")
			return
		end
		if M.teardown_local() ~= true then
			settle_shutdown(false, "local-teardown-failed")
			return
		end
		settle_shutdown(true, detail or "stopped")
	end)
	if accepted ~= true and not callback_fired then
		settle_shutdown(false, "revocation-rejected")
	end
	if callback_fired then return callback_succeeded end
	return accepted == true
end

--- Requests a fenced public stop. Local consumers remain mounted until the
--- controller proves STOPPED or its exact fallback transports complete.
--- @return boolean True when the stop transaction was accepted.
function M.stop()
	return M.shutdown("hammerspoon_stop")
end

return M
