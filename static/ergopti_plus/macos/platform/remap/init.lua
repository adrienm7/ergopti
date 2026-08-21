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
local TimerScheduler = require("adapters.timer_scheduler")
local Timings     = require("infra.timings")
local FileSystem  = require("adapters.file_system")

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

-- An unexpected worker/guardian loss is already fenced by LeaseController
-- before it publishes FAILED. Retry only a small, named series: an unbounded
-- loop would continuously rewrite karabiner.json when launchd approval or the
-- native helper is unavailable.
local LEASE_RECOVERY_RETRY_DELAYS_SEC = { 1.0, 10.0, 30.0 }
local LEASE_RECOVERY_TIMER_ARM_ATTEMPTS = 3
local LEASE_GUARDIAN_STATUS_POLL_SEC = 3.0
local LEASE_GUARDIAN_PROBE_TIMEOUT_SEC = 2.0
local FIRST_RUN_WIZARD_DELAY_SEC = 2.0
local FIRST_RUN_WIZARD_TIMER_MAX_ATTEMPTS = 3
-- A retained input-source event is an ordering barrier for lease recovery: the
-- replacement must not resolve keycodes until TIS has settled.  Transient
-- failures inside that barrier therefore get their own bounded retry budget;
-- otherwise one failed timer/query/rebind can leave both pipelines waiting on
-- each other forever.
local LAYOUT_REFRESH_RETRY_DELAYS_SEC = { 1.0, 10.0, 30.0 }
local REMAP_GUARDIAN_STATUS_ENV = "ERGOPTI_REMAP_GUARDIAN_STATUS"
local REMAP_GUARDIAN_READY = "ready"

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
local _wizard_timer             = nil  -- Exact deferred first-run capability or cleanup debt
local _wizard_timer_committed   = false -- Fences queued callbacks before native cancellation
local _layout_rebuild_timer     = nil  -- Stored so rapid layout changes cancel the pending rebuild
local _pending_layout_refresh   = nil  -- Latest settled-layout pipeline deferred by a lease transition
local _layout_event_serial      = 0    -- Monotonic identity of physical TIS/wake notifications
local _layout_settled_serial    = 0    -- Newest physical event whose TIS delay elapsed
local _layout_deployed_serial   = 0    -- Newest settled layout carried by a proven regeneration
local _deferred_layout_regeneration = nil -- User intent retained until the newest TIS event settles
local schedule_layout_refresh  = nil  -- Forward declaration used by the lease-phase callback
local retry_pending_layout_refresh = nil -- Forward declaration used by deferred activation replay
local begin_lease_recovery = nil -- Forward declaration used by proven failure-fence callbacks
-- Wake-from-sleep watcher. Held at module scope so it survives past the function
-- that arms it: an hs.caffeinate.watcher referenced only by a local is collected
-- and stops delivering, silently.
local _wake_watcher             = nil
local _kc_parent_ensured        = false -- metrics/ exists from the first regenerate onwards
local _lifecycle_epoch          = 0     -- Invalidates async callbacks retained past M.stop()
local _running                  = false -- True only for the current initialized lifecycle
local _shutdown_requested       = false -- Rejects new work while the exact fence is pending
local _activation_transaction  = nil   -- Same-token regenerate callers share one mount + RESUME
local _regeneration_contexts   = {}    -- All unsettled builds, including callers joined before READY
local _hotkey_cleanup_backlog  = {}    -- Failed adapter deletes retained for a later exact retry
local _gesture_cleanup_backlog = {}    -- Failed eventtap stops retain their exact handles for retry
local _lease_inputs_tainted    = false -- Retained disabled handles are not proof of liveness
local _lease_recovery          = nil   -- One bounded retry series across replacement tokens
local _lease_recovery_timer_cleanup_backlog = {} -- Native timers whose stop must be retried
local _lease_recovery_probe_cleanup_backlog = {} -- Exact status tasks whose terminate must be retried
local _guardian_regeneration_wait = nil -- Bundled rebuilds retained behind exact native readiness
local _last_failed_lease_token = nil   -- Replays a FAILED hidden by an enabled-state transaction
local _lease_user_intent_revision = 0  -- Fences late recovery callbacks after an explicit lease Stop

local _state = nil
local _enabled_transition = nil
local _enabled_preflight = nil -- Owns async onboarding settlement before disable can enter STOPPED
local _bulk_settings_transaction = nil -- Owns candidate publication and exact inverse recovery
local retry_bulk_settings_recovery = nil -- Forward declaration used by sibling mutation gates
-- Unforgeable module-private capabilities allow only fail-closed lifecycle
-- transactions to rebuild while the public script state remains paused
local PAUSED_DISABLE_RECOVERY = {}
local PAUSED_RESUME_REGENERATION = {}
local LEASE_FAILURE_RECOVERY_CAPABILITY = {}
local ACTIVE_LAYOUT_FAILURE_RECOVERY = {}
local GUARDIAN_READY_REGENERATION = {}

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

--- Invalidates a disable preflight without abandoning its native onboarding
--- owner. Revoke/teardown independently join that owner before publishing their
--- own terminal, while the superseded set_enabled callbacks settle exactly once.
--- @param reason string Stable supersession reason.
--- @return boolean invalidated True when one preflight was owned.
local function invalidate_enabled_preflight(reason)
	local preflight = _enabled_preflight
	if not preflight then return false end
	_enabled_preflight = nil
	settle_enabled_callbacks(preflight, false, reason)
	return true
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
	if transaction.committed == true and _state.enabled == true then
		return true, "already-enabled"
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
	if not ok or result ~= true then
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

--- Returns whether a proven failure fence has no other transaction that will
--- restore the live enabled state. Layout-invalidated contexts already retain
--- their own exact retry; private enable/resume/recovery contexts do likewise.
--- @param owner table|nil Regeneration context or the internal layout sentinel.
--- @return boolean required
local function failure_fence_needs_background_recovery(owner)
	if owner == ACTIVE_LAYOUT_FAILURE_RECOVERY then return true end
	return type(owner) == "table" and owner.intent == "public"
		and owner.layout_invalidated ~= true
end

--- Creates an exact-once completion which transfers a proven ACTIVE fence to
--- the bounded fresh-token recovery state machine. Accepted STOPPING is not
--- enough: only the aggregate STOPPED/fallback callback establishes that a new
--- generation may be allocated. All user-intent gates are re-read afterwards.
--- @param expected_token string Exact generation being fenced.
--- @param owner table|nil Regeneration context or the internal layout sentinel.
--- @return function|nil callback
local function make_failure_fence_completion(expected_token, owner)
	if not failure_fence_needs_background_recovery(owner) then return nil end
	local expected_epoch = _lifecycle_epoch
	local expected_user_intent_revision = _lease_user_intent_revision
	local callback_fired = false
	return function(fenced, detail)
		if callback_fired then
			Logger.warn(LOG, "Duplicate failure-driven Karabiner fence completion ignored.")
			return
		end
		callback_fired = true
		if fenced ~= true then
			Logger.error(LOG, "Failure-driven Karabiner fence did not prove STOPPED: %s.",
				tostring(detail))
			return
		end
		if expected_epoch ~= _lifecycle_epoch
			or expected_user_intent_revision ~= _lease_user_intent_revision
			or not _running or _shutdown_requested then return end
		-- A newer layout can turn the same public context into a retained activation
		-- owner while this asynchronous fence is completing. Never launch a second
		-- recovery producer for that context.
		if not failure_fence_needs_background_recovery(owner) then return end
		if type(begin_lease_recovery) ~= "function" then
			Logger.error(LOG, "Failure-driven Karabiner recovery API is unavailable after STOPPED.")
			return
		end
		local status_ok, phase, snapshot = pcall(LeaseController.status)
		if status_ok and phase == "active" and type(snapshot) == "table"
			and snapshot.token ~= expected_token then
			Logger.debug(LOG, "Failure recovery skipped because a newer exact generation is ACTIVE.")
			return
		end
		begin_lease_recovery(expected_token)
	end
end

--- Fences only the captured generation when config publication may already
--- have happened while its normal rules were live. A proven PAUSED/PREPARED
--- generation is inert and can safely be retried without destroying its lease.
--- @param expected_token string Exact generation embedded in the attempted file.
--- @param detail any Deployment failure detail for diagnostics.
--- @param recovery_owner table|nil Regeneration transaction owning later recovery.
--- @return boolean safe True when no fence is needed or exact fencing was accepted.
local function contain_ambiguous_deploy_failure(expected_token, detail, recovery_owner)
	local exact_phase = exact_generation_phase(expected_token)
	if exact_phase == "paused" or exact_phase == "prepared" then return true end
	if type(LeaseController.stop_exact) ~= "function" then
		Logger.error(LOG,
			"Cannot fence ambiguous Karabiner deployment for token %s — exact stop API is unavailable.",
			tostring(expected_token))
		return false
	end
	local on_fenced = exact_phase == "active"
		and make_failure_fence_completion(expected_token, recovery_owner) or nil
	local stop_ok, stopped_or_err = xpcall(function()
		return LeaseController.stop_exact(
			expected_token,
			"deploy_publication_ambiguous",
			on_fenced
		)
	end, debug.traceback)
	if not stop_ok or stopped_or_err ~= true then
		Logger.error(LOG, "Exact fence after ambiguous Karabiner deployment failed: %s.",
			tostring(stopped_or_err))
		return false
	end
	Logger.warn(LOG,
		"Exact Karabiner generation %s is being fenced after ambiguous deployment: %s.",
		tostring(expected_token), tostring(detail))
	return true
end

--- Fences rules resolved for the previous input source when settled layout
--- maintenance cannot even publish a replacement. Leaving that exact ACTIVE
--- generation installed would turn a build error into silently wrong keycodes.
--- @param expected_token string Exact pre-maintenance ACTIVE generation.
--- @param detail any Maintenance failure detail for diagnostics.
--- @return boolean safe True when no fence is needed or exact fencing was accepted.
local function fence_failed_active_layout_generation(expected_token, detail)
	if exact_generation_phase(expected_token) ~= "active" then return true end
	if type(LeaseController.stop_exact) ~= "function" then
		Logger.error(LOG,
			"Cannot fence stale-layout Karabiner generation %s — exact stop API is unavailable.",
			tostring(expected_token))
		return false
	end
	local on_fenced = make_failure_fence_completion(
		expected_token,
		ACTIVE_LAYOUT_FAILURE_RECOVERY
	)
	local stop_ok, stopped_or_err = xpcall(function()
		return LeaseController.stop_exact(
			expected_token,
			"layout_refresh_failed",
			on_fenced
		)
	end, debug.traceback)
	if not stop_ok or stopped_or_err ~= true then
		Logger.error(LOG, "Exact stale-layout fence after maintenance failure failed: %s.",
			tostring(stopped_or_err))
		return false
	end
	Logger.warn(LOG,
		"Exact Karabiner generation %s is being fenced after layout maintenance failed: %s.",
		tostring(expected_token), tostring(detail))
	return true
end

--- Rolls back a failed input mount and, unless the caller can prove the same
--- generation remains PAUSED, fences only the exact Ergopti lease. The KC
--- classifier remains live while an ACTIVE generation is still being fenced so
--- already-emitted managed events cannot be mistaken for physical input.
--- @param detail string Diagnostic detail.
--- @param retain_if_paused boolean True only for a user resume that may remain paused.
--- @param expected_token string|nil Generation capability captured before mounting.
--- @param recovery_owner table|nil Regeneration transaction owning later recovery.
--- @return boolean Always false.
--- @return string Stable public failure reason.
local function fail_lease_bound_input_start(
	detail,
	retain_if_paused,
	expected_token,
	recovery_owner
)
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
		local on_fenced = exact_phase == "active"
			and make_failure_fence_completion(expected_token, recovery_owner) or nil
		local stop_ok, stop_result
		if stop_method == LeaseController.stop_exact then
			stop_ok, stop_result = pcall(
				stop_method,
				expected_token,
				"lease_input_bind_failed",
				on_fenced
			)
		else
			stop_ok, stop_result = pcall(stop_method, "lease_input_bind_failed", on_fenced)
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
--- @param recovery_owner table|nil Regeneration transaction owning later recovery.
--- @return boolean mounted True only when every lease-owned resource is retained.
--- @return string reason Stable acceptance/failure detail.
local function start_lease_bound_inputs(required_phase, retain_if_paused, recovery_owner)
	local function fail_start(detail, may_retain, token)
		return fail_lease_bound_input_start(detail, may_retain, token, recovery_owner)
	end
	if not inputs_are_authorized() then
		return fail_start("integration is not enabled", retain_if_paused)
	end
	local status_ok, phase, lease_snapshot = pcall(LeaseController.status)
	if not status_ok or phase ~= required_phase or type(lease_snapshot) ~= "table"
		or type(lease_snapshot.token) ~= "string" then
		return fail_start(
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
			return fail_start(
				"tainted F17 handles cannot be repaired while rules are ACTIVE",
				false,
				expected_token
			)
		end
		-- A registrar delete failure retains a deliberately disabled handle. Its
		-- non-nil Lua object is not proof of liveness, so retry exact cleanup while
		-- rules are still PAUSED before deciding whether fresh binds are safe.
		if stop_lease_bound_inputs() ~= true then
			return fail_start(
				"tainted F17 handles could not be released before resume",
				true,
				expected_token
			)
		end
	end
	local has_all_hotkeys = _state.hotkey_cycle_windows and _state.hotkey_alt_tab_windows
		and _state.hotkey_alt_tab_apps and _state.hotkey_alt_tab_monitor
	if required_phase == "active" and not has_all_hotkeys then
		return fail_start(
			"an ACTIVE lease was observed before all F17 consumers existed",
			false,
			expected_token
		)
	end
	if not has_all_hotkeys and (_state.hotkey_cycle_windows or _state.hotkey_alt_tab_windows
		or _state.hotkey_alt_tab_apps or _state.hotkey_alt_tab_monitor) then
		return fail_start(
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
			return fail_start(watcher_ok
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
			return fail_start(
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
		return fail_start(bind_err, retain_if_paused, expected_token)
	end

	-- Binders do not yield in production, but a re-entrant test double must not
	-- be able to publish handles into a replacement lifecycle or generation.
	local final_ok, final_phase, final_snapshot = pcall(LeaseController.status)
	if not final_ok or not _running or _lifecycle_epoch ~= expected_epoch
		or _state ~= expected_state or not inputs_are_authorized()
		or final_phase ~= required_phase or type(final_snapshot) ~= "table"
		or final_snapshot.token ~= expected_token then
		rollback_uncommitted_inputs(handles, uncommitted_watcher, true)
		return fail_start(
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
	if not ok or result ~= true then
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
	local function fail_activation_inputs(detail, may_retain, token)
		return fail_lease_bound_input_start(
			detail,
			may_retain,
			token,
			options.failure_recovery_owner
		)
	end
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
		local _, reason = fail_activation_inputs(
			"activation did not expose an exact settled generation",
			retain_if_paused,
			token
		)
		finish(false, reason)
		return false
	end
	local function reject_stale_layout(stage)
		if type(options.layout_guard) ~= "function" then return false end
		local guard_ok, current, guard_reason = xpcall(options.layout_guard, debug.traceback)
		if guard_ok and current == true then return false end
		local public_reason = guard_ok
			and (guard_reason or "layout-refresh-pending") or "layout-guard-raised"
		fail_activation_inputs(
			stage .. ": " .. tostring(guard_ok and guard_reason or current),
			false,
			token
		)
		finish(false, public_reason or "layout-refresh-pending")
		return true
	end

	local script_paused = false
	if respect_pause_intent and phase == "paused" then
		local ok_shortcuts, shortcuts = pcall(require, "modules.shortcuts")
		if ok_shortcuts and shortcuts and type(shortcuts.is_paused) == "function" then
			local ok_paused, paused_or_err = pcall(shortcuts.is_paused)
			if not ok_paused then
				local _, reason = fail_activation_inputs(
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
				local _, reason = fail_activation_inputs(
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
	if reject_stale_layout("layout changed before lease-input preparation") then return false end

	local inputs_ok, inputs_reason = start_lease_bound_inputs(
		phase,
		retain_if_paused,
		options.failure_recovery_owner
	)
	if inputs_ok ~= true then
		finish(false, inputs_reason)
		return false
	end

	local classifier_ok, classifier_reason = refresh_managed_output_set()
	if classifier_ok ~= true then
		local _, reason = fail_activation_inputs(
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
			local _, reason = fail_activation_inputs(
				"pre-RESUME commit failed: " .. tostring(hook_ok and commit_reason or committed),
				retain_if_paused,
				token
			)
			finish(false, commit_reason or reason)
			return false
		end
	end
	if reject_stale_layout("layout changed before RESUME") then return false end

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
				local _, failure_reason = fail_activation_inputs(
					"prepared lease RESUME failed: " .. tostring(resume_reason),
					retain_if_paused,
					token
				)
				if exact_generation_phase(token) == "paused" then clear_managed_output_set() end
				finish(false, resume_reason or failure_reason)
				return
			end
			if reject_stale_layout("layout changed before RESUMED publication") then return end

			local final_ok, final_phase, final_snapshot = pcall(LeaseController.status)
			if not final_ok or final_phase ~= "active"
				or type(final_snapshot) ~= "table" or final_snapshot.token ~= token then
				local _, failure_reason = fail_activation_inputs(
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
		local _, reason = fail_activation_inputs(
			"prepared lease RESUME raised: " .. tostring(accepted_or_err),
			retain_if_paused,
			token
		)
		if exact_generation_phase(token) == "paused" then clear_managed_output_set() end
		finish(false, reason)
		return false
	end
	if accepted_or_err ~= true and not callback_fired then
		local _, reason = fail_activation_inputs(
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

local LAYOUT_REGENERATION_DEFER_REASONS = {
	["disable-in-progress"] = true,
	["enabled-transition-in-progress"] = true,
	["lease-transition-in-progress"] = true,
	["pause-intent-pending"] = true,
}

--- Leaves the exact newest scheduled layout record pending across a transient
--- lease state. Identity prevents an older async completion from owning a newer
--- input-source event.
--- @param pending table Exact scheduled layout record.
--- @param reason string Stable transient rejection reason.
--- @return boolean retained
local function retain_layout_refresh(pending, reason)
	if _pending_layout_refresh ~= pending or not _running or _shutdown_requested
		or _state == nil or _lifecycle_epoch ~= pending.epoch then return false end
	Logger.info(LOG, "Deferred %s layout refresh until the exact lease settles (%s).",
		tostring(pending.source), tostring(reason))
	return true
end

--- Schedules one retained layout pipeline after the lease reaches a safe phase.
--- A newer debounce timer already represents equal-or-newer layout state and
--- therefore subsumes the retained record.
--- @return boolean scheduled
local function replay_pending_layout_refresh()
	local pending = _pending_layout_refresh
	if not pending then return false end
	if not _running or _shutdown_requested or _state == nil
		or _lifecycle_epoch ~= pending.epoch then
		_pending_layout_refresh = nil
		return false
	end
	if _layout_rebuild_timer then
		-- The retained timer was scheduled by this record or a newer event.
		return true
	end
	if type(schedule_layout_refresh) ~= "function" then
		Logger.error(LOG, "Deferred layout refresh scheduler is unavailable.")
		return false
	end
	-- A record retained after its owning timer fired has already paid the TIS
	-- debounce and can re-enter on the next runloop turn. A record whose timer
	-- could not be armed must still wait the full settle interval.
	return schedule_layout_refresh(
		pending.layout_name,
		pending.source,
		pending.epoch,
		pending.tis_settled,
		pending.retry_attempt,
		pending.tis_settled and 0 or nil,
		pending.retry_lineage
	) == true
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

--- Returns whether a deferred regeneration still represents live user intent.
--- The capability itself is not sufficient for enable/rollback: the exact
--- enabled-state transaction must still be the one that requested the build.
--- @param context table Regeneration transaction retained across TIS settle.
--- @return boolean current
local function deferred_regeneration_intent_is_current(context)
	if type(context) ~= "table" or context.settled
		or not is_current_lifecycle(context.epoch) then return false end
	if context.intent == "enable" then
		return type(_enabled_transition) == "table"
			and _enabled_transition == context.enabled_transaction
			and _enabled_transition.kind == "enabling"
	end
	if context.intent == "disable-recovery" then
		return type(_enabled_transition) == "table"
			and _enabled_transition == context.enabled_transaction
			and _enabled_transition.kind == "recovering"
	end
	if context.intent == "resume" then
		return _state.enabled == true
			and _enabled_transition == context.enabled_transaction
			and (_enabled_transition == nil or _enabled_transition.kind ~= "disabling")
	end
	if context.intent == "public" then
		return _state.enabled == true and _enabled_transition == nil
	end
	return false
end

--- Settles and detaches one retained layout regeneration exactly once.
--- @param reason string Stable public failure reason.
local function cancel_deferred_layout_regeneration(reason)
	local context = _deferred_layout_regeneration
	_deferred_layout_regeneration = nil
	if not context then return true end
	context.waiting_for_layout = false
	if not context.settled and type(context.settle) == "function" then
		context:settle(false, reason or "layout-regeneration-cancelled")
	end
	return true
end

--- Retains a user-visible regeneration instead of publishing a transient
--- failure merely because the input source changed at READY/RESUMED.
--- @param context table Regeneration transaction.
--- @param token string|nil Exact generation invalidated by the event.
--- @param replay_now boolean|nil False while schedule_layout_refresh is still arming its timer.
--- @return boolean retained
local function retain_regeneration_for_layout(context, token, replay_now)
	if not deferred_regeneration_intent_is_current(context) then return false end
	if context.built_layout_serial == _layout_event_serial
		and context.built_after_tis_settle == true then
		return false
	end
	local pending = _pending_layout_refresh
	if not pending or pending.layout_serial ~= _layout_event_serial then return false end
	local existing = _deferred_layout_regeneration
	if existing and existing ~= context then
		local same_intent = existing.epoch == context.epoch
			and existing.intent == context.intent
			and existing.capability == context.capability
			and existing.enabled_transaction == context.enabled_transaction
		local active_intents_are_compatible = existing.epoch == context.epoch
			and existing.enabled_transaction == nil
			and context.enabled_transaction == nil
			and ((existing.intent == "public" and context.intent == "resume")
				or (existing.intent == "resume" and context.intent == "public"))
		if (same_intent or active_intents_are_compatible)
			and deferred_regeneration_intent_is_current(existing) then
			if context.intent == "resume" then
				existing.intent = "resume"
				existing.capability = PAUSED_RESUME_REGENERATION
			end
			for _, callback in ipairs(context.callbacks) do
				existing.callbacks[#existing.callbacks + 1] = callback
			end
			context.callbacks = {}
			context.waiting_for_layout = false
			context.settled = true
			_regeneration_contexts[context] = nil
			Logger.debug(LOG,
				"Joined an equivalent %s regeneration behind layout event %d.",
				tostring(context.intent), _layout_event_serial)
			return true
		end
		Logger.error(LOG,
			"A second layout-invalidated regeneration was rejected while one user intent is retained.")
		return false
	end
	context.waiting_for_layout = true
	context.invalidated_token = token or context.invalidated_token
	_deferred_layout_regeneration = context
	Logger.info(LOG,
		"Retained %s Karabiner regeneration until layout event %d settles.",
		tostring(context.intent), _layout_event_serial)
	if replay_now ~= false then replay_pending_layout_refresh() end
	return true
end

--- Invalidates an activation whose RESUME may already be in flight. The
--- retained context prevents the settled layout record from being consumed as
--- ordinary maintenance before the exact stale token has been fenced.
local function invalidate_inflight_regeneration_for_layout()
	local contexts = {}
	for context in pairs(_regeneration_contexts) do
		contexts[#contexts + 1] = context
	end
	local invalidated_tokens = {}
	for _, context in ipairs(contexts) do
		local layout_is_stale = type(context) == "table" and not context.settled
			and context.intent ~= "lease-recovery"
			and type(context.built_layout_serial) == "number"
			and (context.built_layout_serial ~= _layout_event_serial
				or context.built_after_tis_settle ~= true)
		if layout_is_stale then
			context.layout_invalidated = true
			if type(context.lease_token) == "string" then
				invalidated_tokens[context.lease_token] = true
			end
			retain_regeneration_for_layout(context, context.lease_token, false)
		end
	end
	if next(invalidated_tokens) == nil then return end
	local status_ok, phase, snapshot = pcall(LeaseController.status)
	local invalidated_token = type(snapshot) == "table" and snapshot.token or nil
	local owns_invalidated_token = status_ok and type(snapshot) == "table"
		and type(invalidated_token) == "string"
		and invalidated_tokens[invalidated_token] == true
	if not owns_invalidated_token
		or (phase ~= "starting" and phase ~= "resuming" and phase ~= "active") then return end
	local stop_ok, stopped_or_err = pcall(
		LeaseController.stop_exact,
		invalidated_token,
		"layout_changed_during_activation"
	)
	if not stop_ok or stopped_or_err ~= true then
		Logger.error(LOG, "Could not fence in-flight layout-invalidated generation %s: %s.",
			tostring(invalidated_token), tostring(stopped_or_err))
	end
end

--- Restarts one retained intent only after TIS settled and the invalidated
--- generation reached a non-emitting phase. The pending record deliberately
--- remains owned by the layout pipeline until the replacement becomes ACTIVE;
--- a newer physical event therefore invalidates the replacement as well.
--- @param pending table Exact settled layout record.
--- @return boolean handled
local function restart_deferred_layout_regeneration(pending)
	local context = _deferred_layout_regeneration
	if not context then return false end
	if not deferred_regeneration_intent_is_current(context) then
		cancel_deferred_layout_regeneration("layout-regeneration-intent-cancelled")
		return false
	end
	if pending.tis_settled ~= true or pending.layout_serial ~= _layout_event_serial
		or context.attempt_finished ~= true then
		return true
	end
	local status_ok, phase, snapshot = pcall(LeaseController.status)
	if not status_ok or type(snapshot) ~= "table" then
		retry_pending_layout_refresh(pending, "lease-status-unavailable")
		return true
	end
	local invalidated_token_is_live = type(context.invalidated_token) == "string"
		and snapshot.token == context.invalidated_token
		and (phase == "active" or phase == "resuming" or phase == "starting")
	if invalidated_token_is_live then
		local stop_ok, stopped_or_err = pcall(
			LeaseController.stop_exact,
			context.invalidated_token,
			"layout_changed_during_activation"
		)
		if not stop_ok or stopped_or_err ~= true then
			Logger.error(LOG, "Could not fence layout-invalidated generation %s: %s.",
				tostring(context.invalidated_token), tostring(stopped_or_err))
			retry_pending_layout_refresh(pending, "layout-generation-fence-failed")
		end
		return true
	end
	if phase == "recovering" or phase == "fencing" or phase == "pausing"
		or phase == "resuming" or phase == "starting" or phase == "stopping" then
		return true
	end
	local active_without_invalidated_generation = phase == "active"
		and context.invalidated_token == nil
	if not active_without_invalidated_generation
		and phase ~= "paused" and phase ~= "prepared" and phase ~= "idle" and phase ~= "failed" then
		Logger.error(LOG, "Deferred layout regeneration reached unsafe lease phase '%s'.",
			tostring(phase))
		cancel_deferred_layout_regeneration("layout-regeneration-unsafe-phase")
		return true
	end

	_deferred_layout_regeneration = nil
	context.waiting_for_layout = false
	context.attempt_finished = false
	local call_ok, accepted_or_err = xpcall(function()
		return M.regenerate(nil, context.capability, context)
	end, debug.traceback)
	if not call_ok then
		context:settle(false, "layout-regeneration-raised: " .. tostring(accepted_or_err))
	elseif accepted_or_err ~= true and not context.settled
		and _deferred_layout_regeneration ~= context then
		context:settle(false, "layout-regeneration-request-rejected")
	end
	if context.settled and _pending_layout_refresh == pending then
		replay_pending_layout_refresh()
	end
	return true
end

--- Retries cancellation of timers whose native stop previously failed.
--- Their callbacks are already inert because their owning recovery record was
--- detached before cancellation was attempted.
--- @return boolean complete Whether no native recovery timer remains retained.
local function retry_lease_recovery_timer_cleanup()
	for index = #_lease_recovery_timer_cleanup_backlog, 1, -1 do
		local timer = _lease_recovery_timer_cleanup_backlog[index]
		local ok, cancelled_or_err = pcall(TimerScheduler.cancel, timer)
		if ok and cancelled_or_err == true then
			table.remove(_lease_recovery_timer_cleanup_backlog, index)
		else
			Logger.error(LOG, "Karabiner lease recovery timer cancellation retry failed: %s.",
				tostring(cancelled_or_err))
		end
	end
	return #_lease_recovery_timer_cleanup_backlog == 0
end

--- Rejects an uncommitted TimerScheduler candidate without losing exact native
--- cleanup ownership when stop() itself refuses.
--- @param timer table|nil Candidate returned by TimerScheduler.after().
--- @param label string Diagnostic context.
local function reject_lease_recovery_timer(timer, label)
	if type(timer) ~= "table" or timer.timer == nil then return end
	local ok, cancelled_or_err = pcall(TimerScheduler.cancel, timer)
	if ok and cancelled_or_err == true then return end
	_lease_recovery_timer_cleanup_backlog[#_lease_recovery_timer_cleanup_backlog + 1] = timer
	Logger.error(LOG, "%s timer rollback failed; exact handle retained: %s.",
		tostring(label), tostring(cancelled_or_err))
end

--- Retries exact guardian-status task termination without process discovery.
--- ShellRunner deliberately retains the native task after a failed terminate;
--- retaining this opaque handle is therefore the only safe cleanup capability.
--- @return boolean complete Whether no native status task remains retained.
local function retry_lease_recovery_probe_cleanup()
	for index = #_lease_recovery_probe_cleanup_backlog, 1, -1 do
		local handle = _lease_recovery_probe_cleanup_backlog[index]
		local terminate = type(handle) == "table" and handle.terminate or nil
		local ok, terminated_or_err = pcall(function()
			if type(terminate) ~= "function" then return false end
			return terminate()
		end)
		if ok and terminated_or_err == true then
			table.remove(_lease_recovery_probe_cleanup_backlog, index)
		else
			Logger.error(LOG, "Karabiner guardian-status probe termination retry failed: %s.",
				tostring(terminated_or_err))
		end
	end
	return #_lease_recovery_probe_cleanup_backlog == 0
end

--- Cancels one exact recovery series logically before touching its native timer.
--- Exact-record identity keeps a queued callback inert even when timer:stop()
--- itself fails.
--- @param reason string Stable diagnostic reason.
--- @return boolean complete Whether every native timer cancellation is proven.
local function cancel_lease_recovery(reason)
	local backlog_clean = retry_lease_recovery_timer_cleanup()
	local probe_backlog_clean = retry_lease_recovery_probe_cleanup()
	local recovery = _lease_recovery
	_lease_recovery = nil
	if not recovery then return backlog_clean and probe_backlog_clean end
	recovery.cancelled = true
	-- Detach the exact probe before asking its task to stop. hs.task may still
	-- deliver a completion after terminate(); record identity makes that callback
	-- inert even when native termination fails or races process exit.
	local guardian_probe = recovery.guardian_probe
	recovery.guardian_probe = nil
	recovery.waiting_for_guardian = false
	local probe_timer_clean = true
	if guardian_probe and guardian_probe.timeout then
		local timeout = guardian_probe.timeout
		guardian_probe.timeout = nil
		local ok, cancelled_or_err = pcall(TimerScheduler.cancel, timeout)
		if not ok or cancelled_or_err ~= true then
			probe_timer_clean = false
			_lease_recovery_timer_cleanup_backlog[
				#_lease_recovery_timer_cleanup_backlog + 1
			] = timeout
			Logger.error(LOG,
				"Karabiner guardian-status timeout cancellation failed; callback fenced by identity: %s.",
				tostring(cancelled_or_err))
		end
	end
	local probe_clean = true
	if guardian_probe and guardian_probe.handle then
		local terminate = guardian_probe.handle.terminate
		local ok, terminated_or_err = pcall(function()
			if type(terminate) ~= "function" then return false end
			return terminate()
		end)
		if not ok or terminated_or_err ~= true then
			probe_clean = false
			_lease_recovery_probe_cleanup_backlog[
				#_lease_recovery_probe_cleanup_backlog + 1
			] = guardian_probe.handle
			Logger.error(LOG,
				"Karabiner guardian-status probe termination failed; callback fenced by identity: %s.",
				tostring(terminated_or_err))
		end
	end
	local timer = recovery.timer
	recovery.timer = nil
	local timer_clean = true
	if timer then
		local ok, cancelled_or_err = pcall(TimerScheduler.cancel, timer)
		if not ok or cancelled_or_err ~= true then
			timer_clean = false
			_lease_recovery_timer_cleanup_backlog[
				#_lease_recovery_timer_cleanup_backlog + 1
			] = timer
			Logger.error(LOG,
				"Karabiner lease recovery timer cancellation failed; callback fenced by identity: %s.",
				tostring(cancelled_or_err))
		end
	end
	Logger.debug(LOG, "Cancelled Karabiner lease auto-recovery (%s).", tostring(reason))
	return backlog_clean and probe_backlog_clean and probe_timer_clean
		and timer_clean and probe_clean
end

--- Defers one pending automatic attempt until the post-TIS layout pipeline has
--- consumed the newest event. A native timer whose stop fails is still harmless:
--- clearing the record's exact timer slot makes its queued callback stale.
--- @param recovery table Exact bounded recovery series.
local function defer_lease_recovery_for_layout(recovery)
	if _lease_recovery ~= recovery or recovery.cancelled then return end
	recovery.waiting_for_layout = true
	recovery.layout_barrier_exhausted = false
	if recovery.in_flight then recovery.refund_current_attempt = true end
	-- READY and the RESUMED acknowledgement are separate async boundaries.  If
	-- the input source changes after RESUME was sent, the pre-RESUME hook has
	-- already run and cannot protect this generation.  Fence the exact private
	-- token now so its old-layout rules can never become the surviving ACTIVE set.
	if recovery.in_flight and type(recovery.owned_token) == "string" then
		local status_ok, phase, snapshot = pcall(LeaseController.status)
		local owns_resuming_generation = status_ok and phase == "resuming"
			and type(snapshot) == "table" and snapshot.token == recovery.owned_token
		if owns_resuming_generation or not status_ok then
			local stop_ok, stopped_or_err = pcall(
				LeaseController.stop_exact,
				recovery.owned_token,
				"layout_changed_during_recovery_resume"
			)
			if not stop_ok or stopped_or_err ~= true then
				Logger.error(LOG,
					"Exact recovery generation could not be fenced after a layout change: %s.",
					tostring(stopped_or_err))
			else
				Logger.warn(LOG,
					"Fencing recovery generation %s because layout changed before RESUMED.",
					recovery.owned_token)
			end
		end
	end
	local timer = recovery.timer
	if not timer then
		return
	end
	recovery.timer = nil
	-- Arming reserves an attempt number; a layout deferral happens before that
	-- attempt runs, so it must not consume the bounded failure budget.
	recovery.attempt = math.max(0, recovery.attempt - 1)
	local ok, cancelled_or_err = pcall(TimerScheduler.cancel, timer)
	if not ok or cancelled_or_err ~= true then
		_lease_recovery_timer_cleanup_backlog[
			#_lease_recovery_timer_cleanup_backlog + 1
		] = timer
		Logger.error(LOG,
			"Karabiner lease recovery timer could not stop for layout settle; callback fenced by identity: %s.",
			tostring(cancelled_or_err))
	end
end

--- Returns a stable reason when automatic recovery must not create authority.
--- @return string|nil reason
local function lease_recovery_block_reason()
	if not _running or _state == nil then return "lifecycle-inactive" end
	if _shutdown_requested then return "shutdown-in-progress" end
	if _state.enabled ~= true then return "integration-disabled" end
	if _enabled_transition ~= nil then return "enabled-transition-in-progress" end
	return nil
end

local schedule_lease_recovery
local schedule_guardian_status_poll
local probe_guardian_for_recovery

--- Returns whether this process was launched through the ErgoptiPlus app and
--- therefore has an exact native guardian-status role available. Direct
--- Hammerspoon development sessions intentionally export no status and keep the
--- existing bounded recovery path. An unreadable or malformed environment is
--- treated as bundled/fail-closed, never as permission to skip the native gate.
--- @return boolean required
local function guardian_status_probe_required()
	local ok, exported_status = pcall(os.getenv, REMAP_GUARDIAN_STATUS_ENV)
	if not ok then
		Logger.error(LOG, "Could not read %s; requiring an exact native guardian probe: %s.",
			REMAP_GUARDIAN_STATUS_ENV, tostring(exported_status))
		return true
	end
	if exported_status == nil or exported_status == "" then return false end
	if type(exported_status) ~= "string" then
		Logger.error(LOG, "%s had a non-string value; requiring an exact native guardian probe.",
			REMAP_GUARDIAN_STATUS_ENV)
	end
	return true
end

local schedule_guardian_regeneration_poll
local start_guardian_regeneration_probe

--- Returns whether one retained preflight still owns the current lifecycle.
--- @param wait table Exact bundled regeneration wait.
--- @return boolean current
local function guardian_regeneration_wait_is_current(wait)
	return _guardian_regeneration_wait == wait
		and wait.cancelled ~= true
		and is_current_lifecycle(wait.epoch)
end

--- Moves callbacks from an equivalent duplicate context into the retained one.
--- @param retained table Existing regeneration context.
--- @param duplicate table Newly created equivalent context.
local function join_guardian_regeneration_context(retained, duplicate)
	for _, callback in ipairs(duplicate.callbacks or {}) do
		retained.callbacks[#retained.callbacks + 1] = callback
	end
	duplicate.callbacks = {}
	duplicate.settled = true
	duplicate.attempt_finished = true
	_regeneration_contexts[duplicate] = nil
end

--- Terminates one exact status helper after logically detaching it. The
--- controller wrapper invalidates cache authority before native termination,
--- so a late completion stays inert even when terminate() itself fails.
--- @param probe table Owned probe record.
--- @param label string Stable diagnostic label.
--- @return boolean terminated
local function terminate_guardian_regeneration_probe(probe, label)
	local handle = probe and probe.handle or nil
	if probe then probe.handle = nil end
	if not handle then return true end
	local terminate = type(handle) == "table" and handle.terminate or nil
	local ok, terminated_or_err = pcall(function()
		if type(terminate) ~= "function" then return false end
		return terminate()
	end)
	if ok and terminated_or_err == true then return true end
	_lease_recovery_probe_cleanup_backlog[
		#_lease_recovery_probe_cleanup_backlog + 1
	] = handle
	Logger.error(LOG, "%s; exact status helper retained for termination retry: %s.",
		label, tostring(terminated_or_err))
	return false
end

--- Cancels one probe timeout while retaining a failed timer capability.
--- @param probe table Owned probe record.
--- @return boolean cancelled
local function cancel_guardian_regeneration_probe_timeout(probe)
	local timeout = probe and probe.timeout or nil
	if probe then probe.timeout = nil end
	if not timeout then return true end
	local ok, cancelled_or_err = pcall(TimerScheduler.cancel, timeout)
	if ok and cancelled_or_err == true then return true end
	_lease_recovery_timer_cleanup_backlog[
		#_lease_recovery_timer_cleanup_backlog + 1
	] = timeout
	Logger.error(LOG,
		"Karabiner regeneration guardian timeout could not stop; callback fenced by identity: %s.",
		tostring(cancelled_or_err))
	return false
end

--- Settles every regeneration retained behind guardian readiness.
--- @param reason string Stable cancellation reason.
--- @return boolean complete Whether native cleanup was proven.
local function cancel_guardian_regeneration_wait(reason)
	local wait = _guardian_regeneration_wait
	_guardian_regeneration_wait = nil
	if not wait then return true end
	wait.cancelled = true

	local all_clean = true
	local timer = wait.timer
	wait.timer = nil
	if timer then
		local ok, cancelled_or_err = pcall(TimerScheduler.cancel, timer)
		if not ok or cancelled_or_err ~= true then
			all_clean = false
			_lease_recovery_timer_cleanup_backlog[
				#_lease_recovery_timer_cleanup_backlog + 1
			] = timer
			Logger.error(LOG,
				"Karabiner regeneration guardian poll could not stop; callback fenced by identity: %s.",
				tostring(cancelled_or_err))
		end
	end
	local probe = wait.probe
	wait.probe = nil
	if probe then
		probe.cancelled = true
		if not cancel_guardian_regeneration_probe_timeout(probe) then all_clean = false end
		if not terminate_guardian_regeneration_probe(
			probe,
			"Karabiner regeneration guardian probe could not stop"
		) then all_clean = false end
	end

	local contexts = wait.contexts
	wait.contexts = {}
	for _, context in ipairs(contexts) do
		if not context.settled and type(context.settle) == "function" then
			context:settle(false, reason or "guardian-readiness-cancelled")
		end
	end
	return all_clean
end

--- Replays retained regenerations through their ordinary state/layout gates.
--- The module-private proof is valid only for this synchronous callback chain.
--- @param wait table Exact bundled regeneration wait.
local function replay_guardian_regenerations(wait)
	if not guardian_regeneration_wait_is_current(wait) then return end
	_guardian_regeneration_wait = nil
	wait.completed = true
	local contexts = wait.contexts
	wait.contexts = {}
	for _, context in ipairs(contexts) do
		if not context.settled then
			local call_ok, accepted_or_err = xpcall(function()
				return M.regenerate(
					nil,
					context.capability,
					context,
					GUARDIAN_READY_REGENERATION
				)
			end, debug.traceback)
			if not call_ok then
				context:settle(false,
					"guardian-ready-regeneration-raised: " .. tostring(accepted_or_err))
			elseif accepted_or_err ~= true and not context.settled then
				context:settle(false, "guardian-ready-regeneration-rejected")
			end
		end
	end
end

--- Arms the next non-budgeted readiness poll for bundled regeneration.
--- @param wait table Exact bundled regeneration wait.
--- @param reason any Last canonical status or probe failure.
--- @return boolean retained
schedule_guardian_regeneration_poll = function(wait, reason)
	if not guardian_regeneration_wait_is_current(wait)
		or wait.probe ~= nil or wait.timer ~= nil then return false end
	retry_lease_recovery_timer_cleanup()

	local timer = nil
	local armed = false
	local fired_before_arm = false
	local schedule_ok, timer_or_err, timer_committed = pcall(
		TimerScheduler.after,
		LEASE_GUARDIAN_STATUS_POLL_SEC,
		function()
			if not armed then
				fired_before_arm = true
				return
			end
			if not guardian_regeneration_wait_is_current(wait)
				or wait.timer ~= timer then return end
			wait.timer = nil
			run_async_step("Karabiner regeneration guardian-status poll", function()
				start_guardian_regeneration_probe(wait, "guardian-status-poll")
			end)
		end
	)
	if schedule_ok then timer = timer_or_err end
	if timer_committed ~= true or type(timer) ~= "table"
		or timer.fired == true or fired_before_arm then
		reject_lease_recovery_timer(timer, "Guardian readiness poll")
		wait.timer_arm_attempts = wait.timer_arm_attempts + 1
		if wait.timer_arm_attempts < LEASE_RECOVERY_TIMER_ARM_ATTEMPTS then
			Logger.warn(LOG,
				"Guardian readiness poll arm %d/%d failed; retrying retained regeneration: %s.",
				wait.timer_arm_attempts, LEASE_RECOVERY_TIMER_ARM_ATTEMPTS,
				tostring(schedule_ok and "invalid timer handle" or timer_or_err))
			return schedule_guardian_regeneration_poll(wait, reason)
		end
		Logger.error(LOG,
			"Could not retain Karabiner regeneration after %d guardian timer failures: %s.",
			wait.timer_arm_attempts,
			tostring(schedule_ok and "invalid timer handle" or timer_or_err))
		cancel_guardian_regeneration_wait("guardian-status-timer-unavailable")
		return false
	end
	wait.timer_arm_attempts = 0
	wait.timer = timer
	armed = true
	Logger.debug(LOG,
		"Karabiner regeneration remains fail-closed pending guardian readiness "
			.. "(next check in %.1f s; %s).",
		LEASE_GUARDIAN_STATUS_POLL_SEC, tostring(reason))
	return true
end

--- Performs one exact, bounded native readiness observation for all queued
--- bundled regenerations. Only `ready` may enter the build/deploy path.
--- @param wait table Exact bundled regeneration wait.
--- @param reason string Stable diagnostic reason.
--- @return boolean retained
start_guardian_regeneration_probe = function(wait, reason)
	if not guardian_regeneration_wait_is_current(wait)
		or wait.probe ~= nil or wait.timer ~= nil then return false end
	if not retry_lease_recovery_probe_cleanup() then
		return schedule_guardian_regeneration_poll(
			wait,
			"previous-probe-termination-pending"
		)
	end

	local probe = { handle = nil, timeout = nil, settled = false, cancelled = false }
	wait.probe = probe
	local function settle_probe(status, probe_error)
		if probe.settled or probe.cancelled then return end
		probe.settled = true
		cancel_guardian_regeneration_probe_timeout(probe)
		if not guardian_regeneration_wait_is_current(wait)
			or wait.probe ~= probe then return end
		wait.probe = nil
		if status == REMAP_GUARDIAN_READY then
			wait.last_wait_status = nil
			replay_guardian_regenerations(wait)
			return
		end

		local wait_status = status or "probe-failed"
		local log_wait = wait.last_wait_status == wait_status
			and Logger.debug or Logger.warn
		wait.last_wait_status = wait_status
		log_wait(LOG,
			"Karabiner regeneration remains fail-closed after guardian status '%s' (%s).",
			tostring(status), tostring(probe_error or reason))
		schedule_guardian_regeneration_poll(wait, status or probe_error or reason)
	end

	local call_ok, handle_or_err, launch_error = xpcall(function()
		return LeaseController.probe_guardian_status(settle_probe)
	end, debug.traceback)
	if not call_ok then
		settle_probe(nil, "guardian-status-probe-raised: " .. tostring(handle_or_err))
		return guardian_regeneration_wait_is_current(wait)
	end
	if probe.settled then return true end
	if type(handle_or_err) ~= "table" then
		settle_probe(nil, launch_error or "guardian-status-probe-rejected")
		return guardian_regeneration_wait_is_current(wait)
	end
	probe.handle = handle_or_err

	local timeout = nil
	local armed = false
	local fired_before_arm = false
	local timer_ok, timeout_or_err, timeout_committed = pcall(
		TimerScheduler.after,
		LEASE_GUARDIAN_PROBE_TIMEOUT_SEC,
		function()
			if not armed then
				fired_before_arm = true
				return
			end
			if not guardian_regeneration_wait_is_current(wait)
				or wait.probe ~= probe or probe.timeout ~= timeout then return end
			probe.timeout = nil
			terminate_guardian_regeneration_probe(
				probe,
				"Karabiner regeneration guardian probe timed out"
			)
			settle_probe(nil, "guardian-status-probe-timeout")
		end
	)
	if timer_ok then timeout = timeout_or_err end
	if timeout_committed ~= true or type(timeout) ~= "table"
		or timeout.fired == true or fired_before_arm then
		reject_lease_recovery_timer(timeout, "Regeneration guardian probe timeout")
		terminate_guardian_regeneration_probe(
			probe,
			"Karabiner regeneration guardian timeout could not arm"
		)
		settle_probe(nil, timer_ok and "guardian-status-timeout-invalid-handle"
			or "guardian-status-timeout-arm-raised: " .. tostring(timeout_or_err))
		return guardian_regeneration_wait_is_current(wait)
	end
	probe.timeout = timeout
	armed = true
	return true
end

--- Queues one already-validated regeneration until native readiness is fresh.
--- Equivalent repeated callers share one probe and one eventual build.
--- @param context table Regeneration context created by M.regenerate().
--- @return boolean retained
local function queue_guardian_regeneration(context)
	local wait = _guardian_regeneration_wait
	if wait and not guardian_regeneration_wait_is_current(wait) then
		cancel_guardian_regeneration_wait("guardian-readiness-owner-stale")
		wait = nil
	end
	if not wait then
		wait = {
			epoch = _lifecycle_epoch,
			contexts = {},
			probe = nil,
			timer = nil,
			cancelled = false,
			completed = false,
			last_wait_status = nil,
			timer_arm_attempts = 0,
		}
		_guardian_regeneration_wait = wait
	end

	for _, retained in ipairs(wait.contexts) do
		local equivalent = retained.epoch == context.epoch
			and retained.intent == context.intent
			and retained.capability == context.capability
			and retained.enabled_transaction == context.enabled_transaction
		if equivalent and not retained.settled then
			join_guardian_regeneration_context(retained, context)
			return true
		end
	end
	wait.contexts[#wait.contexts + 1] = context
	if wait.probe ~= nil or wait.timer ~= nil then return true end
	return start_guardian_regeneration_probe(wait, "regeneration-preflight")
end

--- Runs one side-effect-free native status observation for this exact launcher.
--- Only `ready` advances the retained recovery. Every other result polls without
--- charging the bounded build/deploy retry budget. The probe record is installed
--- before calling the controller so even a synchronous test callback is fenced.
--- @param recovery table Exact retained recovery series.
--- @param continuation function Work allowed only after an exact ready result.
--- @param refund_attempt boolean Whether a timer already reserved one retry.
--- @param reason string Stable diagnostic reason.
--- @return boolean started_or_settled
probe_guardian_for_recovery = function(recovery, continuation, refund_attempt, reason)
	if _lease_recovery ~= recovery or recovery.cancelled
		or recovery.guardian_probe ~= nil
		or not is_current_lifecycle(recovery.epoch) then return false end
	local blocked = lease_recovery_block_reason()
	if blocked then
		cancel_lease_recovery(blocked)
		return false
	end
	if not retry_lease_recovery_probe_cleanup() then
		schedule_guardian_status_poll(recovery, "previous-probe-termination-pending")
		return false
	end

	local probe = { handle = nil, timeout = nil, completed = false }
	recovery.guardian_probe = probe
	recovery.waiting_for_guardian = true
	local callback_fired = false
	local function cancel_probe_timeout()
		local timeout = probe.timeout
		probe.timeout = nil
		if not timeout then return true end
		local ok, cancelled_or_err = pcall(TimerScheduler.cancel, timeout)
		if ok and cancelled_or_err == true then return true end
		_lease_recovery_timer_cleanup_backlog[
			#_lease_recovery_timer_cleanup_backlog + 1
		] = timeout
		Logger.error(LOG,
			"Karabiner guardian-status timeout cancellation failed; callback fenced by identity: %s.",
			tostring(cancelled_or_err))
		return false
	end
	local function terminate_probe_handle(label)
		local handle = probe.handle
		probe.handle = nil
		if not handle then return true end
		local terminate = handle.terminate
		local ok, terminated_or_err = pcall(function()
			if type(terminate) ~= "function" then return false end
			return terminate()
		end)
		if ok and terminated_or_err == true then return true end
		_lease_recovery_probe_cleanup_backlog[
			#_lease_recovery_probe_cleanup_backlog + 1
		] = handle
		Logger.error(LOG, "%s; exact probe retained for termination retry: %s.",
			label, tostring(terminated_or_err))
		return false
	end
	local function settle_probe(status, probe_error)
		if callback_fired then return end
		callback_fired = true
		probe.completed = true
		cancel_probe_timeout()
		if _lease_recovery ~= recovery or recovery.cancelled
			or recovery.guardian_probe ~= probe
			or not is_current_lifecycle(recovery.epoch) then return end
		recovery.guardian_probe = nil
		recovery.waiting_for_guardian = false

		local current_block = lease_recovery_block_reason()
		if current_block then
			cancel_lease_recovery(current_block)
			return
		end
		if status == REMAP_GUARDIAN_READY then
			recovery.last_guardian_wait_status = nil
			recovery.guardian_timer_arm_attempts = 0
			local continued = run_async_step(
				"Karabiner guardian-status ready continuation",
				continuation
			)
			if not continued and _lease_recovery == recovery and not recovery.cancelled then
				if refund_attempt then
					recovery.attempt = math.max(0, recovery.attempt - 1)
				end
				schedule_guardian_status_poll(recovery, "ready-continuation-failed")
			end
			return
		end

		if refund_attempt then
			recovery.attempt = math.max(0, recovery.attempt - 1)
		end
		local wait_status = status or "probe-failed"
		local log_wait = recovery.last_guardian_wait_status == wait_status
			and Logger.debug or Logger.warn
		recovery.last_guardian_wait_status = wait_status
		log_wait(LOG,
			"Karabiner lease recovery remains fail-closed after guardian status '%s' (%s).",
			tostring(status), tostring(probe_error or reason))
		schedule_guardian_status_poll(recovery, status or probe_error or reason)
	end

	local call_ok, handle_or_err, launch_error = xpcall(function()
		return LeaseController.probe_guardian_status(settle_probe)
	end, debug.traceback)
	if not call_ok then
		settle_probe(nil, "guardian-status-probe-raised: " .. tostring(handle_or_err))
		return false
	end
	if callback_fired then return true end
	if type(handle_or_err) ~= "table" then
		settle_probe(nil, launch_error or "guardian-status-probe-rejected")
		return false
	end
	probe.handle = handle_or_err

	local timer = nil
	local armed = false
	local fired_before_arm = false
	local timer_ok, timer_or_err, timer_committed = pcall(
		TimerScheduler.after,
		LEASE_GUARDIAN_PROBE_TIMEOUT_SEC,
		function()
			if not armed then
				fired_before_arm = true
				return
			end
			if _lease_recovery ~= recovery or recovery.guardian_probe ~= probe
				or probe.timeout ~= timer then return end
			probe.timeout = nil
			terminate_probe_handle("Karabiner guardian-status probe timed out")
			settle_probe(nil, "guardian-status-probe-timeout")
		end
	)
	if timer_ok then timer = timer_or_err end
	if timer_committed ~= true or type(timer) ~= "table"
		or timer.fired == true or fired_before_arm then
		reject_lease_recovery_timer(timer, "Guardian status probe timeout")
		terminate_probe_handle("Karabiner guardian-status timeout could not arm")
		settle_probe(nil, timer_ok and "guardian-status-timeout-invalid-handle"
			or "guardian-status-timeout-arm-raised: " .. tostring(timer_or_err))
		return false
	end
	probe.timeout = timer
	armed = true
	return true
end

--- Consumes one retained retry after re-proving every user-intent gate.
--- @param recovery table Exact bounded recovery series.
--- @param guardian_proven_ready boolean|nil Exact status proof from this callback chain.
local function run_lease_recovery_attempt(recovery, guardian_proven_ready)
	if _lease_recovery ~= recovery or recovery.cancelled
		or not is_current_lifecycle(recovery.epoch) then return end
	recovery.timer = nil
	if _pending_layout_refresh ~= nil then
		-- The timer fired after an input-source event but before TIS settled. Do
		-- not read the old key map or charge an attempt that performed no work.
		recovery.attempt = math.max(0, recovery.attempt - 1)
		recovery.waiting_for_layout = true
		return
	end

	local blocked = lease_recovery_block_reason()
	if blocked then
		cancel_lease_recovery(blocked)
		return
	end
	if guardian_proven_ready ~= true and guardian_status_probe_required() then
		probe_guardian_for_recovery(recovery, function()
			run_lease_recovery_attempt(recovery, true)
		end, true, "recovery-attempt")
		return
	end
	local pause_ok, _, paused = query_shortcuts_pause_state(
		"Karabiner lease auto-recovery pause-state query"
	)
	if pause_ok and paused == true then
		cancel_lease_recovery("script-paused")
		return
	end
	if not pause_ok then
		Logger.warn(LOG, "Karabiner lease auto-recovery remained inert because pause state is unavailable.")
		schedule_lease_recovery(recovery, "pause-state-unavailable", true)
		return
	end

	local status_ok, phase, snapshot = pcall(LeaseController.status)
	if not status_ok then
		Logger.error(LOG, "Karabiner lease auto-recovery could not read controller status: %s.",
			tostring(phase))
		schedule_lease_recovery(recovery, "lease-status-unavailable", true)
		return
	end
	if phase == "recovering" or phase == "fencing" or phase == "pausing"
		or phase == "resuming" or phase == "stopping" then
		-- The next settled phase callback owns continuation. Scheduling here would
		-- race the exact fence or burn the bounded budget while it is still working.
		recovery.attempt = math.max(0, recovery.attempt - 1)
		recovery.waiting_for_phase = true
		recovery.last_reason = "lease-transition-in-progress"
		return
	end
	local owns_observed_token = type(snapshot) == "table"
		and type(recovery.owned_token) == "string"
		and snapshot.token == recovery.owned_token
	local may_retry = phase == "failed" or phase == "idle"
		or ((phase == "prepared" or phase == "paused") and owns_observed_token)
	if not may_retry then
		cancel_lease_recovery("lease-superseded-in-phase-" .. tostring(phase))
		return
	end

	recovery.in_flight = true
	recovery.waiting_for_phase = false
	recovery.refund_current_attempt = false
	local attempt_number = recovery.attempt
	local callback_fired = false
	local function finish_attempt(ok, reason)
		if callback_fired then return end
		callback_fired = true
		if _lease_recovery ~= recovery or recovery.cancelled
			or not is_current_lifecycle(recovery.epoch) then return end
		recovery.in_flight = false
		if ok == true then
			Logger.info(LOG, "Karabiner lease auto-recovery completed with a fresh generation.")
			cancel_lease_recovery("recovered")
			return
		end
		Logger.warn(LOG, "Karabiner lease auto-recovery attempt %d failed: %s.",
			attempt_number, tostring(reason))
		if recovery.refund_current_attempt then
			recovery.attempt = math.max(0, recovery.attempt - 1)
			recovery.refund_current_attempt = false
		end
		recovery.last_reason = reason or "regeneration-failed"
		schedule_lease_recovery(recovery, reason or "regeneration-failed", true)
	end
	local call_ok, requested_or_err = xpcall(function()
		return M.regenerate(
			finish_attempt,
			recovery,
			nil,
			GUARDIAN_READY_REGENERATION
		)
	end, debug.traceback)
	if not call_ok then
		finish_attempt(false, "regeneration-raised: " .. tostring(requested_or_err))
	elseif requested_or_err ~= true and not callback_fired then
		finish_attempt(false, "regeneration-request-rejected")
	end
end

--- Arms the next bounded retry while retaining exact timer ownership.
--- @param recovery table Exact bounded recovery series.
--- @param reason string Stable reason for diagnostics.
--- @param guardian_proven_ready boolean|nil Exact status proof from this callback chain.
--- @return boolean scheduled
schedule_lease_recovery = function(recovery, reason, guardian_proven_ready)
	if _lease_recovery ~= recovery or recovery.cancelled or recovery.in_flight
		or recovery.timer ~= nil or recovery.waiting_for_layout or recovery.waiting_for_phase
		or recovery.waiting_for_guardian
		or _pending_layout_refresh ~= nil
		or not is_current_lifecycle(recovery.epoch) then return false end
	if guardian_proven_ready ~= true and guardian_status_probe_required() then
		return probe_guardian_for_recovery(recovery, function()
			schedule_lease_recovery(recovery, reason, true)
		end, false, reason)
	end
	local next_attempt = recovery.attempt + 1
	local delay = LEASE_RECOVERY_RETRY_DELAYS_SEC[next_attempt]
	if type(delay) ~= "number" then
		recovery.exhausted = true
		Logger.error(LOG,
			"Karabiner lease auto-recovery exhausted after %d attempt(s); rules remain fail-closed (%s).",
			recovery.attempt, tostring(reason))
		return false
	end

	retry_lease_recovery_timer_cleanup()
	local timer = nil
	local armed = false
	local fired_before_arm = false
	local schedule_ok, timer_or_err, timer_committed = pcall(TimerScheduler.after, delay, function()
		if not armed then
			fired_before_arm = true
			return
		end
		if _lease_recovery ~= recovery or recovery.timer ~= timer then return end
		run_async_step("Karabiner lease auto-recovery timer", function()
			run_lease_recovery_attempt(recovery)
		end)
	end)
	if schedule_ok then timer = timer_or_err end
	if timer_committed ~= true or type(timer) ~= "table"
		or timer.fired == true or fired_before_arm then
		reject_lease_recovery_timer(timer, "Lease recovery")
		recovery.timer_arm_attempts = (recovery.timer_arm_attempts or 0) + 1
		if recovery.timer_arm_attempts < LEASE_RECOVERY_TIMER_ARM_ATTEMPTS then
			Logger.warn(LOG,
				"Karabiner lease recovery timer arm %d/%d failed; retrying the same bounded attempt: %s.",
				recovery.timer_arm_attempts, LEASE_RECOVERY_TIMER_ARM_ATTEMPTS,
				tostring(schedule_ok and "invalid timer handle" or timer_or_err))
			return schedule_lease_recovery(recovery, reason, true)
		end
		recovery.exhausted = true
		Logger.error(LOG,
			"Could not arm Karabiner lease auto-recovery attempt %d after %d scheduler attempt(s): %s.",
			next_attempt, recovery.timer_arm_attempts,
			tostring(schedule_ok and "invalid timer handle" or timer_or_err))
		return false
	end
	recovery.timer_arm_attempts = 0
	recovery.attempt = next_attempt
	recovery.last_reason = reason
	recovery.timer = timer
	armed = true
	Logger.warn(LOG,
		"Karabiner lease failed after exact fencing; fresh-generation recovery attempt %d/%d in %.1f s (%s).",
		next_attempt, #LEASE_RECOVERY_RETRY_DELAYS_SEC, delay, tostring(reason))
	return true
end

--- Polls the exact launcher status while authorization or guardian health is
--- unavailable. These checks never consume the bounded regeneration budget and
--- never register a service or open System Settings by themselves.
--- @param recovery table Exact retained recovery series.
--- @param reason any Last canonical status or probe failure.
--- @return boolean scheduled
schedule_guardian_status_poll = function(recovery, reason)
	if _lease_recovery ~= recovery or recovery.cancelled or recovery.in_flight
		or recovery.timer ~= nil or recovery.waiting_for_layout
		or recovery.waiting_for_phase or recovery.guardian_probe ~= nil
		or not is_current_lifecycle(recovery.epoch) then return false end
	recovery.waiting_for_guardian = true
	retry_lease_recovery_timer_cleanup()

	local timer = nil
	local armed = false
	local fired_before_arm = false
	local schedule_ok, timer_or_err, timer_committed = pcall(
		TimerScheduler.after,
		LEASE_GUARDIAN_STATUS_POLL_SEC,
		function()
			if not armed then
				fired_before_arm = true
				return
			end
			if _lease_recovery ~= recovery or recovery.timer ~= timer then return end
			run_async_step("Karabiner guardian-status poll", function()
				recovery.timer = nil
				recovery.waiting_for_guardian = false
				local blocked = lease_recovery_block_reason()
				if blocked then
					cancel_lease_recovery(blocked)
					return
				end
				probe_guardian_for_recovery(recovery, function()
					Logger.info(LOG,
						"Remap guardian became ready; resuming bounded lease recovery.")
					schedule_lease_recovery(recovery, "guardian-ready", true)
				end, false, "guardian-status-poll")
			end)
		end
	)
	if schedule_ok then timer = timer_or_err end
	if timer_committed ~= true or type(timer) ~= "table"
		or timer.fired == true or fired_before_arm then
		reject_lease_recovery_timer(timer, "Guardian status poll")
		recovery.guardian_timer_arm_attempts =
			(recovery.guardian_timer_arm_attempts or 0) + 1
		if recovery.guardian_timer_arm_attempts < LEASE_RECOVERY_TIMER_ARM_ATTEMPTS then
			Logger.warn(LOG,
				"Guardian-status timer arm %d/%d failed; retrying without charging recovery: %s.",
				recovery.guardian_timer_arm_attempts, LEASE_RECOVERY_TIMER_ARM_ATTEMPTS,
				tostring(schedule_ok and "invalid timer handle" or timer_or_err))
			return schedule_guardian_status_poll(recovery, reason)
		end
		recovery.exhausted = true
		Logger.error(LOG,
			"Could not arm guardian-status polling after %d scheduler attempt(s): %s.",
			recovery.guardian_timer_arm_attempts,
			tostring(schedule_ok and "invalid timer handle" or timer_or_err))
		return false
	end
	recovery.guardian_timer_arm_attempts = 0
	recovery.timer = timer
	armed = true
	Logger.debug(LOG,
		"Karabiner lease recovery is waiting for guardian readiness (next check in %.1f s; %s).",
		LEASE_GUARDIAN_STATUS_POLL_SEC, tostring(reason))
	return true
end

--- Starts or coalesces one bounded series after an unexpected lease loss.
--- A failed enabled-state rollback can finish before its asynchronous exact
--- fence publishes IDLE/FAILED; in that case the record is retained without a
--- timer and the settled phase callback owns the first arm.
--- @param failed_token string Exact token owned by the failed transaction.
--- @param wait_for_phase boolean|nil True while its exact fence is still pending.
begin_lease_recovery = function(failed_token, wait_for_phase)
	if type(failed_token) ~= "string" or failed_token == "" then return end
	local blocked = lease_recovery_block_reason()
	if blocked then
		cancel_lease_recovery(blocked)
		return
	end

	local pause_ok, _, paused = query_shortcuts_pause_state(
		"Karabiner lease failure pause-state query"
	)
	if pause_ok and paused == true then
		cancel_lease_recovery("script-paused")
		return
	end

	local recovery = _lease_recovery
	if not recovery then
		recovery = {
			epoch = _lifecycle_epoch,
			failed_token = failed_token,
			attempt = 0,
			in_flight = false,
			cancelled = false,
			exhausted = false,
			capability = LEASE_FAILURE_RECOVERY_CAPABILITY,
			waiting_for_layout = false,
			layout_barrier_exhausted = false,
			waiting_for_phase = false,
			waiting_for_guardian = false,
			refund_current_attempt = false,
			timer_arm_attempts = 0,
			guardian_timer_arm_attempts = 0,
			guardian_probe = nil,
			last_guardian_wait_status = nil,
			owned_token = nil,
			last_reason = nil,
			timer = nil,
		}
		_lease_recovery = recovery
	else
		recovery.failed_token = failed_token
		recovery.waiting_for_phase = false
	end
	if wait_for_phase == true then
		recovery.waiting_for_phase = true
		recovery.last_reason = "recovery-fence-pending"
		return
	end
	if recovery.in_flight or recovery.timer ~= nil or recovery.exhausted then return end
	if _pending_layout_refresh ~= nil then
		recovery.waiting_for_layout = true
		return
	end
	schedule_lease_recovery(recovery,
		pause_ok and "unexpected-worker-loss" or "pause-state-unavailable")
end

--- Rearms a layout-deferred series only after the latest event was consumed.
local function resume_lease_recovery_after_layout()
	local recovery = _lease_recovery
	if not recovery or recovery.cancelled or not recovery.waiting_for_layout then return end
	recovery.waiting_for_layout = false
	recovery.layout_barrier_exhausted = false
	local blocked = lease_recovery_block_reason()
	if blocked then
		cancel_lease_recovery(blocked)
		return
	end
	schedule_lease_recovery(recovery, "layout-settled")
end

--- Releases derivative state after every settled non-active lease transition.
--- In-flight pause/resume commands retain the last settled classification until
--- their ACK, avoiding a double-count window while Karabiner still has old state.
--- @param phase string Lease-controller lifecycle phase.
--- @param token string|nil Exact generation token named by the controller.
local function on_lease_phase(phase, token)
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
	if phase == "active" or phase == "paused" or phase == "prepared"
		or phase == "idle" or phase == "failed" then
		replay_pending_layout_refresh()
	end

	local recovery = _lease_recovery
	if phase == "failed" then
		if type(token) == "string" and token ~= "" then _last_failed_lease_token = token end
		begin_lease_recovery(token)
	elseif phase == "active" then
		_last_failed_lease_token = nil
		if not recovery or token ~= recovery.owned_token then
			cancel_lease_recovery("lease-settled-active")
		end
	elseif phase == "idle" and recovery then
		recovery.waiting_for_phase = false
		if not recovery.in_flight and recovery.timer == nil
			and not recovery.waiting_for_layout and not recovery.exhausted then
			schedule_lease_recovery(recovery, recovery.last_reason or "recovery-fence-settled")
		end
	elseif (phase == "prepared" or phase == "starting" or phase == "paused")
		and recovery and not recovery.in_flight then
		-- A public/manual transaction superseded the pending automatic attempt.
		-- During an automatic attempt these phases are intermediate and must keep
		-- the series budget until its callback proves success or failure.
		if type(token) == "string" and token == recovery.owned_token then
			recovery.waiting_for_phase = false
			if recovery.timer == nil and not recovery.waiting_for_layout
				and not recovery.exhausted then
				schedule_lease_recovery(recovery, recovery.last_reason or "owned-phase-settled")
			end
		else
			cancel_lease_recovery("lease-superseded-in-phase-" .. phase)
		end
	end
end

--- Classifies whether a retained layout event may be consumed right now.
--- Enabled-state transitions are authoritative even when `_state.enabled` still
--- carries the previous committed value. For a live integration, both the exact
--- native phase and Hammerspoon's published pause state must describe the same
--- settled mode before any layout-dependent state is mutated.
--- @param paused boolean Strict Hammerspoon pause state.
--- @return string|nil mode `active`, `paused`, `inactive`, or `disabled` when settled.
--- @return string|nil reason Stable transient reason when not settled.
local function settled_layout_refresh_mode(paused)
	if _enabled_transition ~= nil then return nil, "enabled-transition-in-progress" end
	if _state.enabled == false then return "disabled", nil end
	if _state.enabled ~= true then return nil, "enabled-state-unavailable" end

	local status_ok, phase, snapshot = pcall(LeaseController.status)
	if not status_ok then
		Logger.error(LOG, "Settled layout lease-status query failed: %s.", tostring(phase))
		return nil, "lease-status-unavailable"
	end
	if type(snapshot) ~= "table" or type(snapshot.activation_blocked) ~= "boolean" then
		Logger.error(LOG, "Settled layout lease-status query returned an invalid snapshot.")
		return nil, "lease-status-unavailable"
	end
	-- Direct menu Stop, a fully fenced controller failure, and an observable
	-- PREPARED token intentionally have no live generation. They are stable
	-- non-deploying modes; a future explicit Start re-resolves the layout again
	-- before publishing a fresh generation.
	if phase == "prepared" or phase == "idle" or phase == "failed" then
		return paused == true and "paused" or "inactive", nil
	end
	if type(snapshot.token) ~= "string" then return nil, "lease-status-unavailable" end
	if phase == "paused" and paused == true then return "paused", nil end
	if phase == "active" and paused == false and snapshot.activation_blocked == false then
		return "active", nil
	end
	return nil, "lease-transition-in-progress"
end

--- Terminates one exhausted retained layout barrier explicitly.  Recovery must
--- stay fail-closed rather than wait forever on a record that owns no timer.
--- A later physical input-source event creates a new independent retry budget.
--- @param pending table Exact retained layout record.
--- @param reason string Stable terminal reason.
local function exhaust_pending_layout_refresh(pending, reason)
	if _pending_layout_refresh ~= pending then return end
	if _layout_rebuild_timer then
		pcall(function() _layout_rebuild_timer:stop() end)
		_layout_rebuild_timer = nil
	end
	_pending_layout_refresh = nil
	local deferred = _deferred_layout_regeneration
	if deferred and deferred.waiting_for_layout
		and pending.layout_serial == _layout_event_serial then
		cancel_deferred_layout_regeneration("layout-refresh-exhausted")
	end
	local recovery = _lease_recovery
	if recovery and recovery.waiting_for_layout then
		recovery.layout_barrier_exhausted = true
		Logger.error(LOG,
			"%s layout refresh exhausted after %d retry attempt(s); remap recovery remains fail-closed until a new layout event (%s).",
			tostring(pending.source), pending.retry_attempt or 0, tostring(reason))
	else
		Logger.error(LOG,
			"%s layout refresh exhausted after %d retry attempt(s); the current lease state was retained (%s).",
			tostring(pending.source), pending.retry_attempt or 0, tostring(reason))
	end
end

--- Rearms one exact post-TIS pipeline after a transient callback failure.
--- Failed timer creation is routed through the same bounded budget, so every
--- retained pending record either owns a live timer or has a documented future
--- lease transition that will replay it.
--- @param pending table Exact retained layout record.
--- @param reason string Stable diagnostic reason.
--- @return boolean scheduled
retry_pending_layout_refresh = function(pending, reason)
	local current = _pending_layout_refresh
	if current ~= pending then
		if not current or current.retry_lineage ~= pending.retry_lineage then return false end
		pending = current
	end
	if not is_current_lifecycle(pending.epoch) then
		return false
	end
	local lineage = pending.retry_lineage
	local next_attempt = (lineage.retry_attempt or 0) + 1
	local delay = LAYOUT_REFRESH_RETRY_DELAYS_SEC[next_attempt]
	if type(delay) ~= "number" then
		exhaust_pending_layout_refresh(pending, reason)
		return false
	end
	if pending.tis_settled ~= true then
		delay = math.max(delay, LAYOUT_TIS_SETTLE_SEC)
	end
	lineage.retry_attempt = next_attempt
	pending.retry_attempt = next_attempt
	Logger.warn(LOG, "%s layout refresh retry %d/%d in %.1f s (%s).",
		tostring(pending.source), next_attempt, #LAYOUT_REFRESH_RETRY_DELAYS_SEC,
		delay, tostring(reason))
	return schedule_layout_refresh(
		pending.layout_name,
		pending.source,
		pending.epoch,
		pending.tis_settled,
		next_attempt,
		delay,
		lineage
	) == true
end

--- Executes the one canonical post-TIS-settle layout refresh pipeline.
--- Both input-source notifications and wake events schedule this function.
--- @param layout_name string|nil Notification layout label, if known.
--- @param source string Stable event source for diagnostics.
--- @param epoch integer Scheduling lifecycle epoch.
local function perform_settled_layout_refresh(layout_name, source, epoch)
	if not is_current_lifecycle(epoch) then return end
	local pending = _pending_layout_refresh
	if not pending or pending.epoch ~= epoch then return end
	local pause_ok, shortcuts, paused = query_shortcuts_pause_state(
		"Settled " .. source .. " pause-state query"
	)
	if not pause_ok then
		retry_pending_layout_refresh(pending, "pause-state-unavailable")
		return
	end
	if not is_current_lifecycle(epoch) or _pending_layout_refresh ~= pending then return end
	if restart_deferred_layout_regeneration(pending) then return end
	local settled_mode, unsettled_reason = settled_layout_refresh_mode(paused)
	if not settled_mode then
		if LAYOUT_REGENERATION_DEFER_REASONS[unsettled_reason] then
			retain_layout_refresh(pending, unsettled_reason)
		else
			retry_pending_layout_refresh(pending, unsettled_reason or "layout-mode-unavailable")
		end
		return
	end

	local function adopt_current_lineage()
		local current = _pending_layout_refresh
		if current == pending then return true end
		if not current or current.retry_lineage ~= pending.retry_lineage then return false end
		pending = current
		return true
	end
	local function consume_pending()
		if not adopt_current_lineage() then return end
		_pending_layout_refresh = nil
		resume_lease_recovery_after_layout()
	end
	local function rebind_if_current()
		if not is_current_lifecycle(epoch) or not adopt_current_lineage() then return end
		if type(shortcuts.rebind_for_layout) ~= "function" then
			Logger.error(LOG, "Settled %s shortcut rebind API is unavailable.", source)
			retry_pending_layout_refresh(pending, "shortcut-rebind-unavailable")
			return
		end
		if type(shortcuts.rebind_for_layout) == "function" then
			local rebind_ok, rebound = run_async_step(
				"Settled " .. source .. " shortcut rebind",
				shortcuts.rebind_for_layout
			)
			if not rebind_ok then
				retry_pending_layout_refresh(pending, "shortcut-rebind-failed")
				return
			end
			if rebound then
				Logger.info(LOG, "Shortcuts rebound for layout '%s'.",
					tostring(layout_name or "current"))
			else
				Logger.debug(LOG, "Shortcuts not rebound for layout '%s' — layer is stopped.",
					tostring(layout_name or "current"))
			end
		end
		consume_pending()
	end

	local resolved_count = nil
	if settled_mode ~= "active" then
		local resolved_ok
		resolved_ok, resolved_count = resolve_current_layout_actions(
			"Settled " .. source .. " layout-action resolution"
		)
		if not resolved_ok then
			retry_pending_layout_refresh(pending, "layout-action-resolution-failed")
			return
		end
		if not is_current_lifecycle(epoch) or _pending_layout_refresh ~= pending then return end
	end

	if settled_mode == "paused" then
		Logger.info(LOG, "%s refresh: re-resolved %s action(s), not redeploying — script is paused.",
			source, tostring(resolved_count))
		consume_pending()
		return
	end

	if settled_mode == "active" then
		if _layout_deployed_serial >= (pending.layout_serial or 0) then
			Logger.debug(LOG,
				"%s refresh already deployed by the layout-fenced activation; rebinding only.",
				source)
			rebind_if_current()
			return
		end
		local active_status_ok, active_phase, active_snapshot = pcall(LeaseController.status)
		local maintenance_token = type(active_snapshot) == "table" and active_snapshot.token or nil
		if not active_status_ok or active_phase ~= "active"
			or type(maintenance_token) ~= "string" then
			Logger.error(LOG,
				"Settled %s layout maintenance lost its exact ACTIVE generation before build.",
				source)
			retry_pending_layout_refresh(pending, "active-generation-unavailable")
			return
		end
		-- regenerate() owns the one active-mode resolution immediately before its
		-- consumer. Resolving here as well would double the layout hot-path walk.
		local callback_fired = false
		local function finish_regeneration(regenerated, reason)
			if callback_fired then
				Logger.warn(LOG, "Duplicate settled %s regeneration callback ignored.", source)
				return
			end
			callback_fired = true
			if not is_current_lifecycle(epoch) or not adopt_current_lineage() then return end
			if regenerated ~= true then
				if LAYOUT_REGENERATION_DEFER_REASONS[reason] then
					retain_layout_refresh(pending, reason)
				else
					Logger.error(LOG, "Settled %s Karabiner regeneration failed: %s.",
						source, tostring(reason))
					fence_failed_active_layout_generation(maintenance_token, reason)
					retry_pending_layout_refresh(pending,
						"regeneration-failed:" .. tostring(reason))
				end
				return
			end
			if reason == "ready-paused-by-user-intent" then
				consume_pending()
				return
			end
			rebind_if_current()
		end
		local regenerate_ok, accepted_or_err = xpcall(function()
			return M.regenerate(finish_regeneration)
		end, debug.traceback)
		if not regenerate_ok then
			Logger.error(LOG, "Settled %s Karabiner regeneration raised: %s.",
				source, tostring(accepted_or_err))
			fence_failed_active_layout_generation(
				maintenance_token,
				"regeneration-raised:" .. tostring(accepted_or_err)
			)
			retry_pending_layout_refresh(pending, "regeneration-raised")
			return
		end
		if accepted_or_err ~= true and not callback_fired then
			finish_regeneration(false, "regeneration-request-rejected")
		end
		return
	elseif settled_mode == "disabled" then
		Logger.info(LOG, "%s refresh: re-resolved %s action(s); bridge disabled, no redeploy.",
			source, tostring(resolved_count))
	else
		Logger.info(LOG, "%s refresh: re-resolved %s action(s); exact lease inactive, no redeploy.",
			source, tostring(resolved_count))
	end
	rebind_if_current()
end

--- Debounces layout work until macOS TIS has published the post-event key map.
--- @param layout_name string|nil Notification layout label, if known.
--- @param source string Stable event source for diagnostics.
--- @param epoch integer Scheduling lifecycle epoch.
--- @param tis_settled boolean|nil True when a retained event already paid the TIS debounce.
--- @param retry_attempt integer|nil Count of transient failures already charged.
--- @param delay_override number|nil Exact retry/replay delay; nil uses the TIS delay.
--- @param retry_lineage table|nil Shared budget across re-entrant phase replays.
--- @return boolean scheduled
schedule_layout_refresh = function(
	layout_name,
	source,
	epoch,
	tis_settled,
	retry_attempt,
	delay_override,
	retry_lineage
)
	if not is_current_lifecycle(epoch) then return false end
	if _layout_rebuild_timer then
		pcall(function() _layout_rebuild_timer:stop() end)
		_layout_rebuild_timer = nil
	end
	local lineage = retry_lineage or {
		retry_attempt = retry_attempt or 0,
		layout_serial = _layout_event_serial,
	}
	if retry_attempt ~= nil then lineage.retry_attempt = retry_attempt end
	if type(lineage.layout_serial) ~= "number" then
		lineage.layout_serial = _layout_event_serial
	end
	local pending = {
		layout_name = layout_name,
		source = source,
		epoch = epoch,
		layout_serial = lineage.layout_serial,
		tis_settled = tis_settled == true,
		retry_attempt = lineage.retry_attempt or 0,
		retry_lineage = lineage,
	}
	_pending_layout_refresh = pending
	invalidate_inflight_regeneration_for_layout()
	if _lease_recovery then defer_lease_recovery_for_layout(_lease_recovery) end
	-- Exact fencing can settle synchronously (for example a re-entrant STOPPED
	-- transport callback) and replay this pending event before defer returns.
	-- Never let the superseded outer call overwrite that newer timer owner.
	if _pending_layout_refresh ~= pending then return _layout_rebuild_timer ~= nil end
	local timer = nil
	local armed = false
	local fired_before_arm = false
	local delay = type(delay_override) == "number"
		and delay_override or (pending.tis_settled and 0 or LAYOUT_TIS_SETTLE_SEC)
	local timer_ok, timer_or_err = pcall(hs.timer.doAfter, delay, function()
		if not armed then
			fired_before_arm = true
			return
		end
		-- A stopped callback can already be queued when a newer event replaces it.
		-- Only the currently retained timer may clear the handle or perform work.
		if _layout_rebuild_timer ~= timer or _pending_layout_refresh ~= pending then return end
		_layout_rebuild_timer = nil
		pending.tis_settled = true
		_layout_settled_serial = math.max(_layout_settled_serial, pending.layout_serial or 0)
		local ok = run_async_step("Delayed " .. source .. " layout refresh", function()
			perform_settled_layout_refresh(layout_name, source, epoch)
		end)
		if not ok then retry_pending_layout_refresh(pending, "layout-callback-raised") end
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
		return retry_pending_layout_refresh(pending, "timer-arm-failed")
	end
	_layout_rebuild_timer = timer_or_err
	armed = true
	return true
end

--- Opens the Karabiner-Elements GUI for the user on explicit request.
function M.open_gui() KeLifecycle.open_gui() end

--- Opens Login Items only for an enabled integration whose last exact native
--- observation still requires approval. The child rechecks ServiceManagement
--- immediately before opening, so a stale menu can never cause the side effect.
--- @param on_done function|nil Callback fn(ok, reason).
--- @return boolean accepted
function M.open_guardian_settings(on_done)
	if not require_state("open_guardian_settings") then
		invoke_public_callback("open guardian settings", on_done, false, "not-initialized")
		return false
	end
	if _state.enabled ~= true then
		invoke_public_callback("open guardian settings", on_done, false, "integration-disabled")
		return false
	end
	local status_ok, _, snapshot = pcall(LeaseController.status)
	if not status_ok or type(snapshot) ~= "table"
		or snapshot.guardian_status ~= "requires_approval" then
		invoke_public_callback("open guardian settings", on_done, false,
			status_ok and "approval-not-required" or "guardian-status-unavailable")
		return false
	end

	local callback_fired = false
	local function finish(ok, reason)
		if callback_fired then return end
		callback_fired = true
		invoke_public_callback("open guardian settings", on_done, ok, reason)
	end
	local call_ok, accepted_or_err = xpcall(function()
		return LeaseController.open_guardian_settings(finish)
	end, debug.traceback)
	if not call_ok then
		finish(false, "settings-request-raised: " .. tostring(accepted_or_err))
		return false
	end
	if accepted_or_err ~= true then
		finish(false, "settings-request-rejected")
		return false
	end
	return true
end





-- ===============================================
-- ===============================================
-- ======= 1/ State Accessors and Mutators =======
-- ===============================================
-- ===============================================

--- Fences and settles the exact deferred first-run timer with bounded retries.
--- Literal true is the only cancellation proof. Refusal leaves the original
--- wrapper retained and callback-inert so no sibling capability can replace it.
--- @param context string Lifecycle boundary requesting cancellation.
--- @return boolean settled True only when no native timer remains owned.
local function cancel_first_run_wizard_timer(context)
	_wizard_timer_committed = false
	local timer = _wizard_timer
	if not timer then return true end
	for attempt = 1, FIRST_RUN_WIZARD_TIMER_MAX_ATTEMPTS do
		local cancel_ok, result = xpcall(function()
			return TimerScheduler.cancel(timer)
		end, debug.traceback)
		if cancel_ok and result == true then
			if _wizard_timer == timer then _wizard_timer = nil end
			return true
		end
		Logger.error(LOG,
			"%s: first-run wizard timer cancellation attempt %d/%d failed: %s.",
			context, attempt, FIRST_RUN_WIZARD_TIMER_MAX_ATTEMPTS, tostring(result))
	end
	return false
end

--- Acquires the delayed first-run wizard without replacing unresolved debt.
--- A scheduler refusal is rolled back exactly before the bounded successor
--- attempt; a queued predecessor callback remains fenced by identity and epoch.
--- @param wizard_epoch number Lifecycle epoch owning the deferred wizard.
--- @return boolean committed True only when one exact timer was armed.
local function schedule_first_run_wizard(wizard_epoch)
	if cancel_first_run_wizard_timer("First-run wizard replacement") ~= true then
		return false
	end
	for attempt = 1, FIRST_RUN_WIZARD_TIMER_MAX_ATTEMPTS do
		local candidate = nil
		local schedule_ok, handle_or_err, committed = xpcall(function()
			return TimerScheduler.after(FIRST_RUN_WIZARD_DELAY_SEC, function()
				if _wizard_timer ~= candidate or _wizard_timer_committed ~= true then return end
				_wizard_timer_committed = false
				cancel_first_run_wizard_timer("First-run wizard delivery")
				if not is_current_lifecycle(wizard_epoch)
					or not _state or _state.enabled ~= true then return end
				local callback_ok, callback_err = xpcall(function()
					local Onboarding = require("platform.remap.onboarding")
					Onboarding.run_first_run_wizard()
				end, debug.traceback)
				if not callback_ok then
					Logger.error(LOG, "First-run wizard callback failed: %s.", tostring(callback_err))
				end
			end)
		end, debug.traceback)
		candidate = type(handle_or_err) == "table" and handle_or_err or nil
		if candidate then _wizard_timer = candidate end
		if schedule_ok and committed == true and candidate then
			_wizard_timer_committed = true
			return true
		end
		_wizard_timer_committed = false
		Logger.error(LOG,
			"First-run wizard timer acquisition attempt %d/%d failed: %s.",
			attempt, FIRST_RUN_WIZARD_TIMER_MAX_ATTEMPTS, tostring(handle_or_err))
		if candidate
			and cancel_first_run_wizard_timer("First-run wizard acquisition rollback") ~= true then
			return false
		end
	end
	return false
end

--- Stops the loaded onboarding subsystem without constructing it during teardown.
--- @param context string Lifecycle boundary requesting installer revocation.
--- @param on_done function|nil Joined callback fn(ok, detail) after exact settlement.
--- @return boolean accepted_or_settled Callback form reports acceptance; synchronous
--- form reports whether every exact onboarding owner settled.
local function stop_loaded_onboarding(context, on_done)
	local first_run_settled = cancel_first_run_wizard_timer(context) == true
	if not first_run_settled then
		Logger.error(LOG, "%s: first-run wizard timer settlement failed.", context)
	end
	local onboarding = package.loaded["platform.remap.onboarding"]
	if not onboarding then
		local detail = first_run_settled and "onboarding-not-loaded"
			or "first-run-wizard-stop-incomplete"
		invoke_public_callback("onboarding stop", on_done, first_run_settled, detail)
		return first_run_settled
	end
	if type(onboarding) ~= "table" or type(onboarding.stop) ~= "function" then
		Logger.error(LOG, "%s: loaded onboarding module has no stop contract.", context)
		invoke_public_callback("onboarding stop", on_done, false, "stop-unavailable")
		return false
	end
	if type(on_done) ~= "function" then
		local stop_ok, stop_result = xpcall(onboarding.stop, debug.traceback)
		if not stop_ok or stop_result ~= true then
			Logger.error(LOG, "%s: onboarding installer settlement failed: %s.",
				context, tostring(stop_result))
			return false
		end
		return first_run_settled
	end

	local callback_fired = false
	local callback_succeeded = false
	local dispatching = true
	local pending_onboarding_ok = false
	local pending_detail = nil
	local function publish(onboarding_ok, detail)
		callback_succeeded = onboarding_ok == true and first_run_settled
		if not first_run_settled then detail = "first-run-wizard-stop-incomplete" end
		invoke_public_callback("onboarding stop", on_done, callback_succeeded, detail)
	end
	local function finish(onboarding_ok, detail)
		if callback_fired then
			Logger.warn(LOG, "%s: duplicate onboarding stop completion ignored.", context)
			return
		end
		callback_fired = true
		if dispatching then
			pending_onboarding_ok = onboarding_ok == true
			pending_detail = detail
			return
		end
		publish(onboarding_ok, detail)
	end
	local stop_ok, stop_result = xpcall(function()
		return onboarding.stop(finish)
	end, debug.traceback)
	dispatching = false
	if not stop_ok or stop_result ~= true then
		Logger.error(LOG, "%s: onboarding installer settlement failed: %s.",
			context, tostring(stop_result))
		-- A synchronous terminal is only a candidate until the request itself
		-- returns literal true; fence that candidate and every later duplicate
		callback_fired = true
		local refusal_detail = stop_ok and "stop-rejected" or "stop-raised"
		if pending_onboarding_ok == false and pending_detail ~= nil then
			refusal_detail = pending_detail
		end
		publish(false, refusal_detail)
		return false
	end
	if callback_fired then
		publish(pending_onboarding_ok, pending_detail)
		return callback_succeeded
	end
	return true
end

-- Unforgeable recursion token: only a completion from stop_loaded_onboarding()
-- may enter the continuation below the installer settlement fence.
local ONBOARDING_STOP_JOINED = {}

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
--- @param onboarding_gate table|nil Private exact-settlement continuation token.
--- @return boolean True when accepted or already settled.
function M.set_enabled(value, on_done, onboarding_gate)
	if not require_state("set_enabled") then
		invoke_public_callback("set_enabled", on_done, false, "not-initialized")
		return false
	end
	if not _running or _shutdown_requested then
		local reason = _shutdown_requested and "shutdown-in-progress" or "lifecycle-inactive"
		Logger.warn(LOG, "Karabiner enabled-state request refused while lifecycle is inactive.")
		invoke_public_callback("set_enabled", on_done, false, reason)
		return false
	end
	local target_enabled = value == true
	if _bulk_settings_transaction then
		local phase = _bulk_settings_transaction.phase
		if phase == "rollback-persistence" or phase == "rollback-regeneration" then
			retry_bulk_settings_recovery()
		end
		if _bulk_settings_transaction then
			Logger.error(LOG,
				"Karabiner enabled-state request refused during bulk phase '%s'.",
				tostring(_bulk_settings_transaction.phase))
			invoke_public_callback("set_enabled", on_done, false, "bulk-settings-busy")
			return false
		end
	end
	if _enabled_preflight then
		if not target_enabled then
			if type(on_done) == "function" then
				_enabled_preflight.callbacks[#_enabled_preflight.callbacks + 1] = on_done
			end
			Logger.debug(LOG, "Joined the in-flight Karabiner disable onboarding preflight.")
			return true
		end
		Logger.warn(LOG,
			"Karabiner enable request rejected while disable onboarding preflight is in flight.")
		invoke_public_callback("set_enabled", on_done, false, "transition-in-progress")
		return false
	end
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
	if not target_enabled and onboarding_gate ~= ONBOARDING_STOP_JOINED then
		local preflight = { callbacks = {}, epoch = _lifecycle_epoch }
		if type(on_done) == "function" then preflight.callbacks[1] = on_done end
		_enabled_preflight = preflight
		local callback_fired = false
		local continuation_result = false
		local accepted = stop_loaded_onboarding("Karabiner integration disable",
			function(stopped)
				callback_fired = true
				if _enabled_preflight ~= preflight then return end
				if preflight.epoch ~= _lifecycle_epoch or not _running or _shutdown_requested then
					invalidate_enabled_preflight("shutdown-in-progress")
					return
				end
				_enabled_preflight = nil
				if stopped == true then
					continuation_result = M.set_enabled(value, function(ok, reason)
						settle_enabled_callbacks(preflight, ok == true, reason)
					end, ONBOARDING_STOP_JOINED)
				else
					settle_enabled_callbacks(preflight, false, "onboarding-stop-incomplete")
				end
			end)
		if callback_fired then return continuation_result end
		if accepted ~= true and _enabled_preflight == preflight then
			_enabled_preflight = nil
			settle_enabled_callbacks(preflight, false, "onboarding-stop-incomplete")
		end
		return accepted == true
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
				replay_pending_layout_refresh()
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
				replay_pending_layout_refresh()
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

	cancel_guardian_regeneration_wait("integration-disable-requested")
	cancel_deferred_layout_regeneration("integration-disable-requested")
	cancel_lease_recovery("integration-disable-requested")
	local _, _, disable_snapshot = pcall(LeaseController.status)
	local transaction = {
		kind = "disabling",
		callbacks = {},
		previous_token = type(disable_snapshot) == "table" and disable_snapshot.token or nil,
	}
	if type(on_done) == "function" then transaction.callbacks[1] = on_done end
	_enabled_transition = transaction
	Logger.info(LOG, "Karabiner integration disable requested; awaiting STOPPED.")

	local function finish_recovery(recovered, recovery_reason, disable_reason)
		if _enabled_transition ~= transaction then return end
		_enabled_transition = nil
		replay_pending_layout_refresh()
		if recovered then
			Logger.warn(LOG, "Disable failed; the previous enabled state was restored after READY.")
		else
			Logger.error(LOG, "Disable rollback failed before READY: %s.", tostring(recovery_reason))
		end
		settle_enabled_callbacks(transaction, false,
			disable_reason or recovery_reason or "disable-failed")
		if not recovered and _enabled_transition == nil and _state.enabled == true then
			local status_ok, phase, snapshot = pcall(LeaseController.status)
			local seed_token = type(snapshot) == "table" and snapshot.token
				or _last_failed_lease_token or transaction.previous_token
			local phase_is_settled = phase == "failed" or phase == "idle"
				or phase == "prepared" or phase == "paused"
			local phase_is_fencing = phase == "recovering" or phase == "fencing"
				or phase == "pausing" or phase == "resuming"
				or phase == "starting" or phase == "stopping"
			if status_ok and type(seed_token) == "string"
				and (phase_is_settled or phase_is_fencing) then
				begin_lease_recovery(seed_token, phase_is_fencing)
				if _lease_recovery and type(snapshot) == "table"
					and snapshot.token == seed_token then
					_lease_recovery.owned_token = seed_token
				end
			end
		end
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
		replay_pending_layout_refresh()
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


--- Clones the persisted settings without sharing either nested binding table.
--- @param source table Source state.
--- @return table candidate Detached settings candidate.
local function clone_settings_state(source)
	local candidate = {}
	for key, value in pairs(source) do candidate[key] = value end
	candidate.tap_hold_config = {}
	for key, value in pairs(source.tap_hold_config or {}) do
		if type(value) == "table" then
			local copy = {}; for item_key, item_value in pairs(value) do copy[item_key] = item_value end
			candidate.tap_hold_config[key] = copy
		else
			candidate.tap_hold_config[key] = value
		end
	end
	candidate.mod_combos_config = {}
	for key, value in pairs(source.mod_combos_config or {}) do
		if type(value) == "table" then
			local copy = {}; for item_key, item_value in pairs(value) do copy[item_key] = item_value end
			candidate.mod_combos_config[key] = copy
		else
			candidate.mod_combos_config[key] = value
		end
	end
	return candidate
end

--- Publishes only persisted settings, preserving live lifecycle capabilities.
--- @param candidate table Persisted settings candidate.
local function publish_settings_state(candidate)
	_state.tap_hold_config = candidate.tap_hold_config
	_state.mod_combos_config = candidate.mod_combos_config
	_state.tap_hold_timeout_ms = candidate.tap_hold_timeout_ms
	_state.sticky_timeout_ms = candidate.sticky_timeout_ms
	_state.simultaneous_threshold_ms = candidate.simultaneous_threshold_ms
	_state.combo_symmetric = candidate.combo_symmetric
end

--- Persists and then publishes one detached settings candidate.
--- @param candidate table Detached settings candidate.
--- @param overwrite_corrupt boolean|nil Explicit reset-only overwrite intent.
--- @param label string Stable operation label for diagnostics.
--- @return boolean committed
local function persist_and_publish_settings(candidate, overwrite_corrupt, label)
	local payload = clone_settings_state(candidate)
	-- Settings compensation must never roll back a separately owned preference
	payload.enabled = _state.enabled == true
	local call_ok, saved = pcall(
		Config.save_user_config,
		payload,
		resolve_user_config(),
		overwrite_corrupt
	)
	if not call_ok or saved ~= true then
		Logger.error(LOG, "%s did not persist; live Karabiner settings were preserved: %s.",
			tostring(label), tostring(saved))
		return false
	end
	publish_settings_state(payload)
	return true
end

--- Completes the original bulk caller exactly once.
--- @param transaction table Active bulk transaction.
--- @param ok boolean Final operation result.
--- @param reason string Stable terminal detail.
local function finish_bulk_settings_callback(transaction, ok, reason)
	if transaction.callback_settled then return end
	transaction.callback_settled = true
	invoke_public_callback(
		transaction.label,
		transaction.on_done,
		ok == true,
		reason,
		transaction.change_count
	)
end

--- Dispatches regeneration and requires both exact request acceptance and one
--- exact terminal callback. Synchronous callbacks are held until the request's
--- return value is known, so a callback followed by false/nil cannot look valid.
--- @param transaction table Active bulk transaction.
--- @param label string Stable regeneration boundary label.
--- @param on_terminal function Callback fn(ok, reason).
--- @return boolean accepted True only for a literal-true request result.
local function dispatch_bulk_regeneration(transaction, label, on_terminal)
	if _bulk_settings_transaction ~= transaction then
		Logger.error(LOG, "%s refused a stale bulk transaction.", tostring(label))
		on_terminal(false, "stale-bulk-transaction")
		return false
	end
	local callback_seen = false
	local dispatching = true
	local pending_ok = false
	local pending_reason = nil

	local function handle_terminal(ok, reason)
		if callback_seen then
			Logger.warn(LOG, "Duplicate %s callback ignored.", tostring(label))
			return
		end
		callback_seen = true
		if dispatching then
			pending_ok = ok == true
			pending_reason = reason
			return
		end
		on_terminal(ok == true, reason)
	end

	local call_ok, accepted_or_err = xpcall(function()
		return M.regenerate(handle_terminal)
	end, debug.traceback)
	dispatching = false
	if not call_ok or accepted_or_err ~= true then
		callback_seen = true
		local reason = call_ok and "regeneration-request-refused" or "regeneration-request-raised"
		Logger.error(LOG, "%s failed: %s.", tostring(label), tostring(accepted_or_err))
		on_terminal(false, reason)
		return false
	end
	if callback_seen then on_terminal(pending_ok, pending_reason) end
	return true
end

--- Requests the exact inverse deployment retained by a rejected bulk mutation.
--- @param transaction table Active recovery ledger.
--- @return boolean accepted True only when regeneration accepted the retry.
local function request_bulk_inverse_regeneration(transaction)
	transaction.phase = "rollback-regeneration-pending"
	return dispatch_bulk_regeneration(
		transaction,
		transaction.label .. " inverse regeneration",
		function(ok, reason)
			if _bulk_settings_transaction ~= transaction then return end
			if ok == true then
				_bulk_settings_transaction = nil
				Logger.info(LOG, "%s inverse configuration restored successfully.",
					transaction.label)
				finish_bulk_settings_callback(
					transaction,
					false,
					transaction.failure_reason or "candidate-regeneration-failed"
				)
				return
			end
			transaction.phase = "rollback-regeneration"
			Logger.error(LOG, "%s inverse regeneration remains pending: %s.",
				transaction.label, tostring(reason))
			finish_bulk_settings_callback(
				transaction,
				false,
				transaction.failure_reason or "candidate-regeneration-failed"
			)
		end
	)
end

--- Retries the exact inverse before any sibling settings mutation is admitted.
--- @return boolean settled True only when no recovery debt remains.
retry_bulk_settings_recovery = function()
	local transaction = _bulk_settings_transaction
	if not transaction then return true end
	if transaction.phase == "rollback-persistence" then
		Logger.warn(LOG, "Retrying retained %s inverse persistence.", transaction.label)
		if not persist_and_publish_settings(
			transaction.snapshot,
			transaction.overwrite_corrupt,
			transaction.label .. " inverse"
		) then
			return false
		end
		transaction.phase = "rollback-regeneration"
	end
	if transaction.phase == "rollback-regeneration" then
		Logger.warn(LOG, "Retrying retained %s inverse regeneration.", transaction.label)
		request_bulk_inverse_regeneration(transaction)
		return _bulk_settings_transaction == nil
	end
	return false
end

--- Joins any retained bulk compensation before a lifecycle boundary can publish.
--- A retryable inverse is attempted exactly once; an accepted asynchronous retry
--- keeps the same transaction owner, so revoke/teardown callers must retry only
--- after its terminal callback. Candidate terminals already in flight are never
--- guessed or cancelled here.
--- @param boundary string Stable lifecycle boundary label.
--- @return boolean settled True only when no bulk owner or debt remains.
local function settle_bulk_settings_before_lifecycle(boundary)
	local transaction = _bulk_settings_transaction
	if not transaction then return true end
	local phase = transaction.phase
	if phase == "rollback-persistence" or phase == "rollback-regeneration" then
		retry_bulk_settings_recovery()
	end
	if _bulk_settings_transaction == nil then return true end
	Logger.error(LOG, "%s refused while %s remains in bulk phase '%s'.",
		tostring(boundary), tostring(transaction.label),
		tostring(_bulk_settings_transaction.phase))
	return false
end

--- Rejects a failed candidate and retains every unsettled inverse boundary.
--- @param transaction table Active bulk transaction.
--- @param reason string Candidate failure detail.
local function reject_bulk_settings_candidate(transaction, reason)
	if _bulk_settings_transaction ~= transaction then return end
	transaction.failure_reason = reason or "candidate-regeneration-failed"
	transaction.phase = "rollback-persistence"
	Logger.error(LOG, "%s failed after settings commit; restoring the exact prior configuration.",
		transaction.label)
	if not persist_and_publish_settings(
		transaction.snapshot,
		transaction.overwrite_corrupt,
		transaction.label .. " inverse"
	) then
		Logger.error(LOG, "%s inverse persistence remains pending.", transaction.label)
		finish_bulk_settings_callback(transaction, false, transaction.failure_reason)
		return
	end
	transaction.phase = "rollback-regeneration"
	request_bulk_inverse_regeneration(transaction)
end

--- Applies one multi-setting candidate, deploys it, and compensates exactly on
--- any non-true terminal. All sibling setters remain gated until candidate
--- success or the retained inverse has persisted and regenerated successfully.
--- @param label string Stable operation label.
--- @param mutate function Receives a detached candidate and returns a count.
--- @param on_done function|nil Callback fn(ok, reason, change_count).
--- @param overwrite_corrupt boolean|nil Explicit reset-only overwrite intent.
--- @return boolean accepted True only when candidate regeneration was accepted.
local function apply_bulk_settings_transaction(label, mutate, on_done, overwrite_corrupt)
	if not require_state(label) then
		invoke_public_callback(label, on_done, false, "not-initialized", 0)
		return false
	end
	if not _running or _shutdown_requested then
		local reason = _shutdown_requested and "shutdown-in-progress" or "lifecycle-inactive"
		Logger.error(LOG, "%s refused while the Karabiner lifecycle is inactive.", label)
		invoke_public_callback(label, on_done, false, reason, 0)
		return false
	end
	if _enabled_preflight then
		Logger.error(LOG, "%s refused during disable onboarding preflight.", label)
		invoke_public_callback(label, on_done, false, "enabled-transition-in-progress", 0)
		return false
	end
	if _enabled_transition then
		Logger.error(LOG, "%s refused during enabled-state phase '%s'.",
			label, tostring(_enabled_transition.kind))
		invoke_public_callback(label, on_done, false, "enabled-transition-in-progress", 0)
		return false
	end
	if _bulk_settings_transaction then
		local phase = _bulk_settings_transaction.phase
		if phase == "rollback-persistence" or phase == "rollback-regeneration" then
			retry_bulk_settings_recovery()
		end
		Logger.error(LOG, "%s refused while another bulk settings transaction is '%s'.",
			label, tostring(phase))
		invoke_public_callback(label, on_done, false, "bulk-settings-busy", 0)
		return false
	end
	if type(mutate) ~= "function" then
		Logger.error(LOG, "%s refused an invalid settings mutator.", label)
		invoke_public_callback(label, on_done, false, "invalid-mutator", 0)
		return false
	end

	local snapshot = clone_settings_state(_state)
	local candidate = clone_settings_state(snapshot)
	local mutate_ok, change_count_or_err = xpcall(function()
		return mutate(candidate)
	end, debug.traceback)
	if not mutate_ok then
		Logger.error(LOG, "%s candidate construction failed: %s.",
			label, tostring(change_count_or_err))
		invoke_public_callback(label, on_done, false, "candidate-construction-failed", 0)
		return false
	end

	local transaction = {
		label = label,
		on_done = on_done,
		snapshot = snapshot,
		change_count = tonumber(change_count_or_err) or 0,
		overwrite_corrupt = overwrite_corrupt,
		phase = "candidate-persistence",
		callback_settled = false,
	}
	_bulk_settings_transaction = transaction
	if not persist_and_publish_settings(candidate, overwrite_corrupt, label) then
		_bulk_settings_transaction = nil
		finish_bulk_settings_callback(transaction, false, "candidate-persistence-failed")
		return false
	end

	transaction.phase = "candidate-regeneration-pending"
	return dispatch_bulk_regeneration(transaction, label .. " regeneration", function(ok, reason)
		if _bulk_settings_transaction ~= transaction then return end
		if ok == true then
			_bulk_settings_transaction = nil
			finish_bulk_settings_callback(transaction, true, reason or "ready")
			return
		end
		reject_bulk_settings_candidate(transaction, reason)
	end)
end

--- Persists a prospective state and publishes one live mutation only after the
--- writer confirms success. The candidate has fresh nested config tables, so a
--- failed save cannot leak a partial setter mutation through shared references.
--- @param mutate function Receives a detached candidate state.
--- @param overwrite_corrupt boolean|nil Explicit reset-only overwrite intent.
--- @return boolean committed
local function commit_state_mutation(mutate, overwrite_corrupt)
	if not _running or _shutdown_requested then
		Logger.error(LOG, "Karabiner setting mutation refused while lifecycle is inactive.")
		return false
	end
	if _enabled_preflight then
		Logger.error(LOG, "Karabiner setting mutation refused during disable onboarding preflight.")
		return false
	end
	if _enabled_transition then
		Logger.error(LOG, "Karabiner setting mutation refused during enabled-state phase '%s'.",
			tostring(_enabled_transition.kind))
		return false
	end
	if _bulk_settings_transaction then
		local phase = _bulk_settings_transaction.phase
		if phase == "rollback-persistence" or phase == "rollback-regeneration" then
			retry_bulk_settings_recovery()
		end
		Logger.error(LOG, "Karabiner setting mutation refused during bulk phase '%s'.",
			tostring(phase))
		return false
	end
	local candidate = clone_settings_state(_state)
	local mutate_ok, mutate_err = xpcall(function() mutate(candidate) end, debug.traceback)
	if not mutate_ok then
		Logger.error(LOG, "Karabiner setting candidate construction failed: %s.",
			tostring(mutate_err))
		return false
	end
	return persist_and_publish_settings(candidate, overwrite_corrupt, "Karabiner setting mutation")
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
	if not require_state("set_tap_action") then return false end
	local committed = commit_state_mutation(function(candidate)
		local cfg = candidate.tap_hold_config[key_id] or {}
		candidate.tap_hold_config[key_id] = {
			tap = action_id,
			hold = cfg.hold or "none",
			timeout_ms = cfg.timeout_ms,
		}
	end)
	if committed then Logger.debug(LOG, "Key '%s' tap → '%s'.", key_id, action_id) end
	return committed
end

--- Sets the hold action for a key and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param key_id string Key id.
--- @param action_id string Action id from actions.json.
function M.set_hold_action(key_id, action_id)
	if not require_state("set_hold_action") then return false end
	local committed = commit_state_mutation(function(candidate)
		local cfg = candidate.tap_hold_config[key_id] or {}
		candidate.tap_hold_config[key_id] = {
			tap = cfg.tap or "none",
			hold = action_id,
			timeout_ms = cfg.timeout_ms,
		}
	end)
	if committed then Logger.debug(LOG, "Key '%s' hold → '%s'.", key_id, action_id) end
	return committed
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
	if not require_state("set_tap_timeout") then return false end
	local value = tonumber(ms)
	if value and value > 0 then
		value = math.floor(value)
	else
		value = nil  -- clear override → inherit the global timeout
	end
	local committed = commit_state_mutation(function(candidate)
		local cfg = candidate.tap_hold_config[key_id] or {}
		candidate.tap_hold_config[key_id] = {
			tap = cfg.tap or "none",
			hold = cfg.hold or "none",
			timeout_ms = value,
		}
	end)
	if committed then
		Logger.debug(LOG, "Key '%s' tap/hold timeout override → %s.",
			key_id, value and (value .. " ms") or "global")
	end
	return committed
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
local function update_combo_slot(config, combo_id, slot, action_id)
	local cfg   = config[combo_id]
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
	if not require_state("set_combo_tap_action") then return false end
	local committed = commit_state_mutation(function(candidate)
		candidate.mod_combos_config[combo_id] = update_combo_slot(
			candidate.mod_combos_config, combo_id, "tap", action_id)
	end)
	if committed then Logger.debug(LOG, "Combo '%s' tap → '%s'.", combo_id, action_id) end
	return committed
end

--- Sets the hold action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_hold_action(combo_id, action_id)
	if not require_state("set_combo_hold_action") then return false end
	local committed = commit_state_mutation(function(candidate)
		candidate.mod_combos_config[combo_id] = update_combo_slot(
			candidate.mod_combos_config, combo_id, "hold", action_id)
	end)
	if committed then Logger.debug(LOG, "Combo '%s' hold → '%s'.", combo_id, action_id) end
	return committed
end

--- Sets the chord action for a modifier combo and saves the user config.
--- Does NOT regenerate — call M.regenerate() explicitly when ready.
--- @param combo_id string Combo id.
--- @param action_id string Action id from actions.json.
function M.set_combo_combo_action(combo_id, action_id)
	if not require_state("set_combo_combo_action") then return false end
	local committed = commit_state_mutation(function(candidate)
		candidate.mod_combos_config[combo_id] = update_combo_slot(
			candidate.mod_combos_config, combo_id, "combo", action_id)
	end)
	if committed then Logger.debug(LOG, "Combo '%s' combo → '%s'.", combo_id, action_id) end
	return committed
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
	if not require_state("set_tap_hold_timeout") then return false end
	local value = tonumber(ms)
	if not value or value <= 0 then
		Logger.error(LOG, "set_tap_hold_timeout: invalid value '%s' — ignoring.", tostring(ms))
		return false
	end
	value = math.floor(value)
	local committed = commit_state_mutation(function(candidate)
		candidate.tap_hold_timeout_ms = value
	end)
	if committed then Logger.debug(LOG, "Tap/hold timeout: %d ms.", value) end
	return committed
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
	if not require_state("set_sticky_timeout") then return false end
	local value = tonumber(ms)
	if not value or value <= 0 then
		Logger.error(LOG, "set_sticky_timeout: invalid value '%s' — ignoring.", tostring(ms))
		return false
	end
	value = math.floor(value)
	local committed = commit_state_mutation(function(candidate)
		candidate.sticky_timeout_ms = value
	end)
	if committed then Logger.debug(LOG, "Sticky timeout: %d ms.", value) end
	return committed
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
	if not require_state("set_simultaneous_threshold") then return false end
	local value = tonumber(ms)
	if not value or value <= 0 then
		Logger.error(LOG, "set_simultaneous_threshold: invalid value '%s' — ignoring.", tostring(ms))
		return false
	end
	value = math.floor(value)
	local committed = commit_state_mutation(function(candidate)
		candidate.simultaneous_threshold_ms = value
	end)
	if committed then Logger.debug(LOG, "Simultaneous threshold: %d ms.", value) end
	return committed
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
	if not require_state("set_combo_symmetric") then return false end
	local normalized = value == true
	local committed = commit_state_mutation(function(candidate)
		candidate.combo_symmetric = normalized
	end)
	if committed then Logger.debug(LOG, "Combo symmetric: %s.", tostring(normalized)) end
	return committed
end

--- Clears both slots for one tap/hold key as one exact transaction.
--- @param key_id string Key id as defined in tap_hold_keys.json.
--- @param on_done function|nil Callback fn(ok, reason, change_count).
--- @return boolean accepted True only when exact regeneration was accepted.
function M.clear_tap_hold_binding(key_id, on_done)
	Logger.debug(LOG, "Clear tap/hold binding transaction requested: %s.", tostring(key_id))
	return apply_bulk_settings_transaction("Clear tap/hold binding", function(candidate)
		local cfg = candidate.tap_hold_config[key_id] or {}
		local tap = cfg.tap or "none"
		local hold = cfg.hold or "none"
		candidate.tap_hold_config[key_id] = {
			tap = "none",
			hold = "none",
			timeout_ms = cfg.timeout_ms,
		}
		return (tap ~= "none" or hold ~= "none") and 1 or 0
	end, on_done)
end

--- Clears all three slots for one modifier combo as one exact transaction.
--- @param combo_id string Combo id as defined in mod_combos.json.
--- @param on_done function|nil Callback fn(ok, reason, change_count).
--- @return boolean accepted True only when exact regeneration was accepted.
function M.clear_combo_binding(combo_id, on_done)
	Logger.debug(LOG, "Clear modifier combo transaction requested: %s.", tostring(combo_id))
	return apply_bulk_settings_transaction("Clear modifier combo", function(candidate)
		local cfg = candidate.mod_combos_config[combo_id] or {}
		local tap = cfg.tap or "none"
		local hold = cfg.hold or "none"
		local combo = cfg.combo or "none"
		candidate.mod_combos_config[combo_id] = {
			tap = "none",
			hold = "none",
			combo = "none",
		}
		return (tap ~= "none" or hold ~= "none" or combo ~= "none") and 1 or 0
	end, on_done)
end

--- Clears every tap/hold and modifier-combo binding as one exact transaction.
--- @param on_done function|nil Callback fn(ok, reason, change_count).
--- @return boolean accepted True only when exact regeneration was accepted.
function M.clear_all_bindings(on_done)
	Logger.debug(LOG, "Clear-all bindings transaction requested.")
	return apply_bulk_settings_transaction("Clear-all bindings", function(candidate)
		local changed = 0
		for _, key_def in ipairs(M.TAP_HOLD_KEYS) do
			local cfg = candidate.tap_hold_config[key_def.id] or {}
			local tap = cfg.tap or "none"
			local hold = cfg.hold or "none"
			if tap ~= "none" or hold ~= "none" then changed = changed + 1 end
			candidate.tap_hold_config[key_def.id] = {
				tap = "none",
				hold = "none",
				timeout_ms = cfg.timeout_ms,
			}
		end
		for _, combo_def in ipairs(M.MOD_COMBOS) do
			local cfg = candidate.mod_combos_config[combo_def.id] or {}
			local tap = cfg.tap or "none"
			local hold = cfg.hold or "none"
			local combo = cfg.combo or "none"
			if tap ~= "none" or hold ~= "none" or combo ~= "none" then
				changed = changed + 1
			end
			candidate.mod_combos_config[combo_def.id] = {
				tap = "none",
				hold = "none",
				combo = "none",
			}
		end
		return changed
	end, on_done)
end

--- Restores all settings to defaults as one exact transaction.
--- This remains the sole mutation allowed to overwrite an unparseable config.
--- @param on_done function|nil Callback fn(ok, reason, change_count).
--- @return boolean accepted True only when exact regeneration was accepted.
function M.reset_to_defaults(on_done)
	Logger.debug(LOG, "Reset-to-defaults transaction requested.")
	return apply_bulk_settings_transaction("Reset-to-defaults", function(candidate)
		local defaults = Config.build_default_state(M.TAP_HOLD_KEYS, M.MOD_COMBOS)
		candidate.tap_hold_config           = defaults.tap_hold_config
		candidate.mod_combos_config         = defaults.mod_combos_config
		candidate.tap_hold_timeout_ms       = defaults.tap_hold_timeout_ms
		candidate.sticky_timeout_ms         = defaults.sticky_timeout_ms
		candidate.simultaneous_threshold_ms = defaults.simultaneous_threshold_ms
		candidate.combo_symmetric           = defaults.combo_symmetric
		return #M.TAP_HOLD_KEYS + #M.MOD_COMBOS
	end, on_done, true)
end

--- Copies every combo tap binding into its chord slot as one exact transaction.
--- @param on_done function|nil Callback fn(ok, reason, change_count).
--- @return boolean accepted True only when exact regeneration was accepted.
function M.copy_tap_actions_to_combos(on_done)
	Logger.debug(LOG, "Tap-to-combo transaction requested.")
	return apply_bulk_settings_transaction("Tap-to-combo propagation", function(candidate)
		local changed = 0
		for _, combo_def in ipairs(M.MOD_COMBOS) do
			local cfg = candidate.mod_combos_config[combo_def.id] or {}
			local tap = cfg.tap or "none"
			local combo = cfg.combo or "none"
			if tap ~= combo then changed = changed + 1 end
			candidate.mod_combos_config[combo_def.id] = {
				tap = tap,
				hold = cfg.hold or "none",
				combo = tap,
			}
		end
		return changed
	end, on_done)
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
--- @param regeneration_context table|nil Private transaction retained across a layout settle.
--- @param guardian_ready_capability any Private proof from an immediately preceding native probe.
--- @return boolean True when the regeneration request was accepted or retained;
---   final deployment and activation completion is reported through `on_done`.
function M.regenerate(
	on_done,
	recovery_capability,
	regeneration_context,
	guardian_ready_capability
)
	if regeneration_context == nil then
		local retained = _deferred_layout_regeneration
		if retained and retained.capability == recovery_capability
			and deferred_regeneration_intent_is_current(retained) then
			if type(on_done) == "function" then
				retained.callbacks[#retained.callbacks + 1] = on_done
			end
			Logger.debug(LOG, "Joined retained %s regeneration after a layout change.",
				tostring(retained.intent))
			return true
		end
	end
	if guardian_ready_capability ~= nil
		and guardian_ready_capability ~= GUARDIAN_READY_REGENERATION then
		Logger.error(LOG, "Karabiner regeneration refused an invalid guardian-ready capability.")
		invoke_public_callback("regenerate", on_done, false, "invalid-guardian-capability")
		return false
	end
	local enable_transaction = recovery_capability
	local is_enable_transition = type(enable_transaction) == "table"
		and enable_transaction == _enabled_transition
		and enable_transaction.kind == "enabling"
	local is_disable_recovery = recovery_capability == PAUSED_DISABLE_RECOVERY
	local is_resume_regeneration = recovery_capability == PAUSED_RESUME_REGENERATION
	local is_lease_failure_recovery = type(recovery_capability) == "table"
		and recovery_capability == _lease_recovery
		and recovery_capability.capability == LEASE_FAILURE_RECOVERY_CAPABILITY
	local context = regeneration_context
	if context ~= nil and (type(context) ~= "table" or context.capability ~= recovery_capability
		or context.settled or context.epoch ~= _lifecycle_epoch) then
		invoke_public_callback("regenerate", on_done, false, "invalid-regeneration-context")
		return false
	end
	if context == nil then
		local intent = is_enable_transition and "enable"
			or is_disable_recovery and "disable-recovery"
			or is_resume_regeneration and "resume"
			or is_lease_failure_recovery and "lease-recovery"
			or "public"
		context = {
			epoch = _lifecycle_epoch,
			capability = recovery_capability,
			enabled_transaction = (is_enable_transition or is_disable_recovery
				or is_resume_regeneration)
				and _enabled_transition or nil,
			intent = intent,
			callbacks = {},
			settled = false,
			attempt = 0,
			attempt_finished = false,
			waiting_for_layout = false,
			layout_invalidated = false,
		}
		_regeneration_contexts[context] = true
		if type(on_done) == "function" then context.callbacks[1] = on_done end
		function context:settle(ok, reason)
			if self.settled then return end
			self.settled = true
			self.waiting_for_layout = false
			_regeneration_contexts[self] = nil
			if _deferred_layout_regeneration == self then
				_deferred_layout_regeneration = nil
			end
			local callbacks = self.callbacks
			self.callbacks = {}
			for _, callback in ipairs(callbacks) do
				invoke_public_callback("regenerate", callback, ok == true, reason)
			end
		end
	end
	context.attempt = context.attempt + 1
	local attempt = context.attempt
	context.attempt_finished = false
	context.layout_invalidated = false
	local callback_settled = false
	local function finish(ok, reason)
		if callback_settled then return end
		callback_settled = true
		if context.settled or context.attempt ~= attempt then return end
		context.attempt_finished = true
		local layout_invalidated = reason == "layout-refresh-pending"
			or context.layout_invalidated == true
		if context.intent ~= "lease-recovery" and layout_invalidated then
			if retain_regeneration_for_layout(context, context.lease_token) then return end
			context:settle(false, reason or "layout-refresh-pending")
			return
		end
		if ok == true and context.built_layout_serial == _layout_event_serial
			and context.built_after_tis_settle == true then
			_layout_deployed_serial = math.max(
				_layout_deployed_serial,
				context.built_layout_serial
			)
		end
		context:settle(ok == true, reason)
	end
	local function fail(reason)
		finish(false, reason)
		return false
	end
	if not require_state("regenerate") then return fail("not-initialized") end
	local has_private_capability = is_enable_transition
		or is_disable_recovery or is_resume_regeneration or is_lease_failure_recovery
	if recovery_capability ~= nil and not has_private_capability then
		Logger.error(LOG, "Karabiner regeneration refused an invalid private recovery capability.")
		return fail("invalid-recovery-capability")
	end
	if _shutdown_requested then
		Logger.debug(LOG, "Regenerate skipped — exact lease shutdown is in progress.")
		return fail("shutdown-in-progress")
	end
	if _enabled_transition and _enabled_transition.kind == "disabling" then
		Logger.debug(LOG, "Regenerate skipped — Karabiner disable fencing is in progress.")
		return fail("disable-in-progress")
	end
	if (recovery_capability == nil or is_lease_failure_recovery)
		and _enabled_transition ~= nil then
		Logger.debug(LOG, "Regenerate skipped — a Karabiner enabled-state transition is in progress.")
		return fail("enabled-transition-in-progress")
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
	local pause_ok, _, script_is_paused = query_shortcuts_pause_state(
		"Karabiner regeneration pause-state query"
	)
	if not pause_ok then return fail("pause-state-unavailable") end
	if script_is_paused and not is_disable_recovery and not is_enable_transition
		and not is_resume_regeneration then
		Logger.info(LOG, "Regenerate skipped — script is paused (« pause = tout éteint »).")
		return fail("script-paused")
	end

	if recovery_capability == nil or is_lease_failure_recovery then
		local status_ok, phase, snapshot = pcall(LeaseController.status)
		if not status_ok or type(snapshot) ~= "table"
			or type(snapshot.activation_blocked) ~= "boolean" then
			return fail("lease-status-unavailable")
		end
		if snapshot.activation_blocked == true then
			Logger.info(LOG,
				"Karabiner regeneration deferred — an exact pause or stop intent is pending.")
			return fail("pause-intent-pending")
		end
		if phase == "pausing" or phase == "resuming" or phase == "recovering"
			or phase == "fencing" or phase == "stopping" then
			Logger.error(LOG, "Karabiner regeneration refused during lease phase '%s'.", tostring(phase))
			return fail("lease-transition-in-progress")
		end
	end
	local pending_layout = _pending_layout_refresh
	local layout_serial_is_unsettled = context.intent ~= "lease-recovery"
		and _layout_settled_serial < _layout_event_serial
	if layout_serial_is_unsettled then
		context.layout_invalidated = true
		context.attempt_finished = true
		local owns_live_barrier = type(pending_layout) == "table"
			and pending_layout.epoch == context.epoch
			and pending_layout.layout_serial == _layout_event_serial
		if owns_live_barrier then
			if retain_regeneration_for_layout(context, context.lease_token) then
				Logger.info(LOG,
					"Karabiner regeneration retained until layout event %d settles before build.",
					_layout_event_serial)
				return true
			end
			return fail("layout-refresh-pending")
		end
		Logger.error(LOG,
			"Karabiner regeneration refused because layout event %d exhausted its settle barrier.",
			_layout_event_serial)
		return fail("layout-refresh-exhausted")
	end
	if guardian_status_probe_required()
		and guardian_ready_capability ~= GUARDIAN_READY_REGENERATION then
		Logger.debug(LOG,
			"Retaining %s Karabiner regeneration behind a fresh native guardian proof.",
			tostring(context.intent))
		return queue_guardian_regeneration(context)
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
	context.built_layout_serial = _layout_event_serial
	context.built_after_tis_settle = _layout_settled_serial >= context.built_layout_serial

	local lease_token = LeaseController.token()
	if type(lease_token) ~= "string" then
		Logger.error(LOG, "Karabiner generation refused — no exact Ergopti lease token is available.")
		return fail("token-unavailable")
	end
	context.lease_token = lease_token
	if is_lease_failure_recovery then recovery_capability.owned_token = lease_token end

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

	local deploy_ok, deployed, deploy_detail = xpcall(function()
		return Generator.merge_and_deploy_config(
			result,
			KARABINER_OUT,
			legacy_rules,
			legacy_context
		)
	end, debug.traceback)
	if not deploy_ok or deployed ~= true then
		local deploy_failure = deploy_ok and deploy_detail or deployed
		Logger.error(LOG, "Karabiner deploy failed → '%s': %s.",
			KARABINER_OUT, tostring(deploy_failure))
		contain_ambiguous_deploy_failure(lease_token, deploy_failure, context)
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
	local layout_guard = nil
	if not is_lease_failure_recovery then
		layout_guard = function()
			if context.settled or context.attempt ~= attempt
				or not is_current_lifecycle(context.epoch) then
				return false, "layout-regeneration-cancelled"
			end
			local current = context.built_layout_serial == _layout_event_serial
				and context.built_after_tis_settle == true
			if current then return true end
			context.layout_invalidated = true
			return false, "layout-refresh-pending"
		end
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
			elseif is_lease_failure_recovery then
				local captured_recovery = recovery_capability
				before_resume = function()
					if _lease_recovery ~= captured_recovery or captured_recovery.cancelled then
						-- A user PAUSE deliberately cancels future automatic work, but a
						-- replacement that has already reached exact PAUSED is the desired
						-- fail-closed state: retain its script-control-only rules. Every
						-- other cancellation (disable, resume, revoke, lifecycle loss)
						-- remains unauthorized and fences this token below.
						local pause_ok, _, paused = query_shortcuts_pause_state(
							"Cancelled Karabiner lease recovery pause-state query"
						)
						local status_ok, current_phase, current_snapshot = pcall(LeaseController.status)
						local pause_intent_proven = pause_ok and paused == true
							or (status_ok and current_phase == "paused"
								and type(current_snapshot) == "table"
								and current_snapshot.token == lease_token
								and current_snapshot.activation_blocked == true)
						if pause_intent_proven and exact_generation_phase(lease_token) == "paused" then
							return true
						end
						return false, "lease-recovery-cancelled"
					end
					if captured_recovery.waiting_for_layout
						or _pending_layout_refresh ~= nil then
						captured_recovery.waiting_for_layout = true
						return false, captured_recovery.layout_barrier_exhausted
							and "layout-refresh-exhausted" or "layout-refresh-pending"
					end
					return true
				end
			end
			return start_or_join_lease_activation({
				retain_if_paused = is_resume_regeneration,
				respect_pause_intent = not is_resume_regeneration,
				before_resume = before_resume,
				layout_guard = layout_guard,
				failure_recovery_owner = context,
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
				local pending_recovery = _lease_recovery
				if not is_lease_failure_recovery and pending_recovery
					and pending_recovery.owned_token == lease_token then
					cancel_lease_recovery("owned-generation-activated-manually")
				end
				local notify_ok, notify_err = xpcall(KeLifecycle.notify_ready, debug.traceback)
				if not notify_ok then
					Logger.error(LOG, "Karabiner ready notification failed after activation: %s.",
						tostring(notify_err))
				end
				finish(true, activation_reason or reason or "ready")
			end)
		end, debug.traceback)
		if not activation_ok then
			local _, failure_reason = fail_lease_bound_input_start(
				"prepared activation callback raised: " .. tostring(activation_requested_or_err),
				is_resume_regeneration,
				lease_token,
				context
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

--- Stops only the current exact Ergopti lease while keeping the integration
--- enabled. The intent revision is advanced before joining an existing fence,
--- so a late failure-recovery callback cannot undo the user's explicit Stop.
--- Stock/personal Karabiner processes and local bridge lifecycle remain intact.
--- @param on_done function|nil Callback fn(ok, reason) after the exact fence.
--- @return boolean True when the stop transaction was accepted or completed.
function M.stop_lease(on_done)
	if not require_state("stop_lease") then
		invoke_public_callback("stop lease", on_done, false, "not-initialized")
		return false
	end
	_lease_user_intent_revision = _lease_user_intent_revision + 1
	cancel_guardian_regeneration_wait("explicit-lease-stop-requested")
	cancel_deferred_layout_regeneration("explicit-lease-stop-requested")
	cancel_lease_recovery("explicit-lease-stop-requested")
	Logger.start(LOG, "Stopping the exact Ergopti Karabiner lease by user request…")
	local callback_fired = false
	local callback_succeeded = false
	local function finish_stop(stopped, reason)
		if callback_fired then
			Logger.warn(LOG, "Duplicate explicit Karabiner lease-stop callback ignored.")
			return
		end
		callback_fired = true
		callback_succeeded = stopped == true
		if stopped == true then
			Logger.success(LOG, "Exact Ergopti Karabiner lease stopped by user request.")
		else
			Logger.error(LOG, "Exact Ergopti Karabiner lease stop failed: %s.", tostring(reason))
		end
		invoke_public_callback("stop lease", on_done, stopped == true, reason)
		replay_pending_layout_refresh()
	end
	local stop_ok, accepted_or_err = xpcall(function()
		return LeaseController.stop("menu_stop", finish_stop)
	end, debug.traceback)
	if not stop_ok then
		Logger.error(LOG, "Exact Ergopti Karabiner lease stop raised: %s.",
			tostring(accepted_or_err))
		if not callback_fired then finish_stop(false, "stop-raised") end
		return false
	end
	if accepted_or_err ~= true then
		Logger.error(LOG, "Exact Ergopti Karabiner lease stop request was rejected.")
		if not callback_fired then finish_stop(false, "stop-rejected") end
		return false
	end
	if callback_fired then return callback_succeeded end
	return true
end

--- Selects the pause-only managed rules through the exact generation variable.
--- No config file or stock Karabiner process is touched.
--- Does nothing when the integration is disabled.
--- @param on_done function|nil Callback fn(ok, reason) after PAUSED or failure.
--- @param onboarding_gate table|nil Private exact-settlement continuation token.
function M.pause(on_done, onboarding_gate)
	if not _state or not _state.enabled then
		invoke_public_callback("pause", on_done, false, "integration-disabled")
		return false
	end
	if onboarding_gate ~= ONBOARDING_STOP_JOINED then
		local callback_fired = false
		local continuation_result = false
		local accepted = stop_loaded_onboarding("Karabiner pause", function(stopped)
			callback_fired = true
			if stopped == true then
				continuation_result = M.pause(on_done, ONBOARDING_STOP_JOINED)
			else
				invoke_public_callback("pause", on_done, false, "onboarding-stop-incomplete")
			end
		end)
		if callback_fired then return continuation_result end
		return accepted == true
	end
	cancel_guardian_regeneration_wait("script-pause-requested")
	cancel_deferred_layout_regeneration("script-pause-requested")
	cancel_lease_recovery("script-pause-requested")
	local status_ok, phase = pcall(LeaseController.status)
	if status_ok and (phase == "failed" or phase == "idle" or phase == "prepared") then
		-- No generation can emit normal Ergopti rules in these settled phases.
		-- Treat that exact fail-closed fact as PAUSED so script_control can commit
		-- its local pause state; the later explicit Resume provisions/activates a
		-- generation instead of trapping the UI in an unpaused/no-lease loop.
		Logger.info(LOG, "Karabiner pause already satisfied by fail-closed lease phase '%s'.", phase)
		invoke_public_callback("pause", on_done, true, "already-fail-closed")
		replay_pending_layout_refresh()
		return true
	end
	if status_ok and (phase == "stopping" or phase == "fencing") then
		-- The controller has already detached the failed generation, so PAUSE
		-- cannot address it. Its old rules may still emit until STOPPED/fallback,
		-- however: join the aggregate exact fence and publish Pause only afterwards.
		Logger.info(LOG, "Karabiner pause is joining the in-flight exact lease fence.")
		local callback_fired = false
		local function finish_joined_pause(stopped, reason)
			if callback_fired then
				Logger.warn(LOG, "Duplicate joined-fence Karabiner pause callback ignored.")
				return
			end
			callback_fired = true
			if stopped == true then
				Logger.info(LOG, "Karabiner pause committed after the exact lease fence settled.")
			else
				Logger.error(LOG, "Karabiner pause could not prove the in-flight fence: %s.",
					tostring(reason))
			end
			invoke_public_callback("pause", on_done, stopped == true,
				stopped == true and "already-fail-closed" or reason)
			if stopped == true then
				-- Aggregate Stop publishes IDLE before this callback. Also cancel any
				-- recovery armed by an earlier FAILED publication: the accepted user
				-- pause remains the newest intent after the joined fence.
				cancel_lease_recovery("script-pause-committed-after-fence")
			end
			replay_pending_layout_refresh()
		end
		local join_ok, accepted_or_err = xpcall(function()
			return LeaseController.stop("script_pause_joined_fence", finish_joined_pause)
		end, debug.traceback)
		if not join_ok then
			Logger.error(LOG, "Karabiner pause exact-fence join raised: %s.",
				tostring(accepted_or_err))
			if not callback_fired then finish_joined_pause(false, "fence-join-raised") end
			return false
		end
		if accepted_or_err ~= true then
			Logger.error(LOG, "Karabiner pause exact-fence join was rejected.")
			if not callback_fired then finish_joined_pause(false, "fence-join-rejected") end
			return false
		end
		return true
	end
	Logger.start(LOG, "Pausing ErgoptiPlus Karabiner remapping…")
	local callback_fired = false
	local request_ok, requested_or_err = xpcall(function()
		return LeaseController.pause(function(ok, reason)
			callback_fired = true
			if ok then
				Logger.success(LOG, "ErgoptiPlus Karabiner remapping paused (script-control rules retained).")
			else
				Logger.error(LOG, "Karabiner pause variable update failed: %s.", tostring(reason))
			end
			invoke_public_callback("pause", on_done, ok == true, reason)
			replay_pending_layout_refresh()
		end)
	end, debug.traceback)
	if not request_ok or requested_or_err ~= true then
		if not request_ok then
			Logger.error(LOG, "Karabiner pause request raised: %s.", tostring(requested_or_err))
		end
		Logger.error(LOG, "Karabiner pause could not be requested.")
		if not callback_fired then
			invoke_public_callback("pause", on_done, false,
				request_ok and "request-rejected" or "request-raised")
			replay_pending_layout_refresh()
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
	cancel_lease_recovery("script-resume-requested")
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
		replay_pending_layout_refresh()
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
--- @return boolean initialized True only after every required owner commits.
function M.init(file_system)
	Logger.start(LOG, "Initializing Karabiner bridge…")

	if type(file_system) ~= "table" or type(file_system.expand_path) ~= "function" then
		Logger.error(LOG, "M.init(): file_system adapter is required and must implement expand_path — module non-functional.")
		return false
	end

	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return false
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
		local results = table.pack(fn())
		Logger.info(LOG, "init phase '%s': %.1f ms.", label, (hs.timer.absoluteTime() - t0) / 1e6)
		return table.unpack(results, 1, results.n)
	end
	M.AVAILABLE_ACTIONS    = timed("load_available_actions", function() return Config.load_available_actions(ACTIONS_FILE) end) or {}
	M.TAP_HOLD_KEYS        = timed("load_tap_hold_keys",     function() return Config.load_tap_hold_keys(TAP_HOLD_FILE) end)    or {}
	M.MOD_COMBOS           = timed("load_mod_combos",        function() return Config.load_mod_combos(MOD_COMBOS_FILE) end)     or {}
	M.NON_CANONICAL_COMBOS = timed("compute_non_canonical_combos", function() return Config.compute_non_canonical_combos(M.MOD_COMBOS) end)

	if #M.AVAILABLE_ACTIONS == 0 or #M.TAP_HOLD_KEYS == 0 or #M.MOD_COMBOS == 0 then
		Logger.error(LOG, "One or more data files failed to load — aborting initialization.")
		return false
	end

	local user_cfg, user_config_status = timed("load_user_config", function()
		return Config.load_user_config(M.TAP_HOLD_KEYS, M.MOD_COMBOS, resolve_user_config())
	end)
	if user_config_status == "error" or type(user_cfg) ~= "table" then
		Logger.error(LOG, "Karabiner bridge initialization refused because its user config is unsafe.")
		return false
	end
	local first_launch = user_config_status == "absent"

	-- Establish no lease generation until the persisted enable/disable decision
	-- is safely readable. An unreadable config may contain `enabled = false`.
	if not LeaseController.init(on_lease_phase) then
		Logger.error(LOG, "Exact Karabiner lease controller initialization failed — remapping stays fail-closed.")
		return false
	end
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

	local input_source_watcher_started = timed("start_input_source_watcher", function()
		return Watchers.start_input_source_watcher(function(layout_name)
			run_async_step("Input-source callback", function()
				local epoch = _lifecycle_epoch
				if not is_current_lifecycle(epoch) then return end
				_layout_event_serial = _layout_event_serial + 1
				Logger.start(LOG, "Layout change detected — scheduling settled refresh for layout '%s'…",
					tostring(layout_name))
				schedule_layout_refresh(layout_name, "Layout-change", epoch)
			end)
		end)
	end)
	if input_source_watcher_started ~= true then
		_running = false
		_shutdown_requested = true
		_lifecycle_epoch = _lifecycle_epoch + 1
		_state.enabled = false
		Logger.error(LOG,
			"Karabiner bridge initialization refused because layout observation is unavailable.")
		return false
	end

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
			_layout_event_serial = _layout_event_serial + 1
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
	-- exits silently. A logged callback boundary keeps onboarding failure from
	-- aborting the timer while still making it visible in the file logger.
	-- The session guard prevents the dialog from re-appearing on every
	-- hs.reload() within the same Hammerspoon session.
	if _state.enabled and not _wizard_ran_this_session then
		_wizard_ran_this_session = true
		local wizard_epoch = _lifecycle_epoch
		if schedule_first_run_wizard(wizard_epoch) ~= true then
			Logger.error(LOG, "First-run wizard timer could not be scheduled or settled.")
		end
	end

	Logger.success(LOG,
		"Karabiner bridge initialized (%d action(s), %d combo(s) active).",
		#M.AVAILABLE_ACTIONS, active_combos)
	return true
end

--- Releases local watchers and hotkeys only after an exact native fence.
--- @return boolean stopped True only when every local resource was released.
local function stop_local_resources()
	_running = false
	_shutdown_requested = true
	_lifecycle_epoch = _lifecycle_epoch + 1
	invalidate_enabled_preflight("shutdown-in-progress")
	cancel_guardian_regeneration_wait("local-teardown")
	cancel_deferred_layout_regeneration("local-teardown")
	_pending_layout_refresh = nil
	local all_stopped = cancel_lease_recovery("local-teardown") == true
	-- The module-level contract owns timers, installer tasks, partials, and mounts
	if stop_loaded_onboarding("Karabiner local teardown") ~= true then all_stopped = false end
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
	if settle_bulk_settings_before_lifecycle("Karabiner local teardown") ~= true then
		return false
	end
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

--- Revokes Ergopti's exact lease and joins onboarding installer settlement.
--- Local F17 consumers stay mounted until both fences complete, and are
--- deliberately owned by a later local teardown transaction. Stock Karabiner
--- processes remain user-managed.
--- @param reason string|nil Stable teardown reason for diagnostics.
--- @param on_done function|nil Callback fn(fenced, reason).
--- @return boolean True when exact revocation was accepted.
function M.revoke(reason, on_done)
	if settle_bulk_settings_before_lifecycle("Karabiner lease revocation") ~= true then
		invoke_public_callback(
			"revoke",
			on_done,
			false,
			"bulk-settings-recovery-pending"
		)
		return false
	end
	Logger.start(LOG, "Revoking the exact Ergopti Karabiner lease…")
	-- The native fence is asynchronous, but every already-queued wake/layout
	-- callback must become stale immediately. Keep F17 consumers and the KC
	-- classifier mounted until STOPPED; only reject *new* lifecycle work here.
	if not _shutdown_requested then
		_shutdown_requested = true
		_lifecycle_epoch = _lifecycle_epoch + 1
	end
	invalidate_enabled_preflight("shutdown-in-progress")
	cancel_guardian_regeneration_wait("lease-revocation-requested")
	cancel_lease_recovery("lease-revocation-requested")
	cancel_deferred_layout_regeneration("lease-revocation-requested")
	_pending_layout_refresh = nil
	local callback_fired = false
	local callback_succeeded = false
	local onboarding_done = false
	local onboarding_succeeded = false
	local onboarding_detail = nil
	local lease_done = false
	local lease_succeeded = false
	local lease_detail = nil
	local function settle_revoke(ok, detail)
		if callback_fired then
			Logger.warn(LOG, "Duplicate Ergopti Karabiner revocation completion ignored.")
			return
		end
		callback_fired = true
		callback_succeeded = ok == true
		invoke_public_callback("revoke", on_done, ok == true, detail)
	end
	local function settle_join_if_ready()
		if not onboarding_done or not lease_done then return end
		if onboarding_succeeded ~= true then
			Logger.error(LOG, "Ergopti onboarding revocation failed: %s.",
				tostring(onboarding_detail))
			settle_revoke(false, onboarding_detail or "onboarding-stop-incomplete")
			return
		end
		if lease_succeeded ~= true then
			Logger.error(LOG, "Ergopti Karabiner lease revocation failed: %s.",
				tostring(lease_detail))
			settle_revoke(false, lease_detail or "revocation-failed")
			return
		end
		settle_revoke(true, lease_detail or "stopped")
	end

	local onboarding_accepted = stop_loaded_onboarding("Karabiner lease revocation",
		function(stopped, detail)
			if onboarding_done then
				Logger.warn(LOG, "Duplicate onboarding half of Karabiner revocation ignored.")
				return
			end
			onboarding_done = true
			onboarding_succeeded = stopped == true
			onboarding_detail = detail
			settle_join_if_ready()
		end)
	if onboarding_accepted ~= true and not onboarding_done then
		onboarding_done = true
		onboarding_detail = "onboarding-stop-rejected"
	end
	local call_ok, accepted_or_err = xpcall(function()
		return LeaseController.stop(reason or "hammerspoon_shutdown", function(stopped, stop_reason)
			if lease_done then
				Logger.warn(LOG, "Duplicate lease half of Karabiner revocation ignored.")
				return
			end
			lease_done = true
			lease_succeeded = stopped == true
			lease_detail = stop_reason
			settle_join_if_ready()
		end)
	end, debug.traceback)
	if not call_ok then
		Logger.error(LOG, "Ergopti Karabiner lease revocation raised: %s.",
			tostring(accepted_or_err))
		lease_done = true
		lease_detail = "revocation-raised"
	elseif accepted_or_err ~= true then
		Logger.error(LOG, "Ergopti Karabiner lease revocation was not accepted.")
		lease_done = true
		lease_detail = "revocation-rejected"
	else
		Logger.success(LOG, "Ergopti Karabiner lease revocation requested; stock Karabiner left untouched.")
	end
	settle_join_if_ready()
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
