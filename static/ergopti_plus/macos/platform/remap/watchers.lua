--- platform/remap/watchers.lua

--- ==============================================================================
--- MODULE: Karabiner Bridge Watchers
--- DESCRIPTION:
--- Three event handlers for the Karabiner bridge: a pointer-event watcher that
--- deactivates CapsWord when the user reaches for the trackpad (any touch,
--- scroll, gesture, or click), a debounced input-source watcher that fires a
--- callback on each keyboard layout change, and a hotkey that cycles through
--- windows of the frontmost application.
---
--- FEATURES & RATIONALE:
--- 1. CapsWord Safety: Any pointer event signals the user has left the keyboard,
---    so CapsWord is cancelled automatically. Two complementary layers are used:
---    hs.eventtap catches clicks, scrolls, and cursor movement; the undocumented
---    MultitouchSupport frameCallback catches bare finger touches that eventtap
---    cannot see. A 100 ms subprocess throttle prevents CPU spikes.
--- 2. Layout Awareness: macOS can emit two input-source notifications in rapid
---    succession during a layout switch. Debouncing coalesces them into a
---    single callback so the caller does not rebuild the KE config twice.
--- 3. Window Cycling: Cycles focus through standard windows of the active app
---    directly via the Hammerspoon API, bypassing the macOS Cmd+` shortcut
---    which is layout-dependent and inactive on some keyboard layouts (AZERTY).
--- ==============================================================================

local M = {}

local hs             = hs
local Logger         = require("infra.logger")
local TaskLifecycle  = require("adapters.task_lifecycle")
local Timings        = require("infra.timings")
local Keycodes       = require("infra.keycodes")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local KeyState       = require("adapters.key_state")
local MouseControl   = require("adapters.mouse_control")
local Registrar      = require("adapters.hotkey_registrar")
local KePaths        = require("platform.remap.ke_paths")
local LeaseContract  = require("platform.remap.lease_contract")
local KeVariables   = require("platform.remap.ke_variables")


local LOG = "karabiner"

-- hs.hotkey accepts the macOS key name directly, derived here from the
-- registry numeric keycode so the registry stays the canonical source.
local KEYCODE_F17_NAME = Keycodes.to_name(Keycodes.F17_CYCLE_WINDOWS)
local MOD_SHIFT = "shift"
local MOD_ALT = "alt"
local MOD_CTRL = "ctrl"

local KARABINER_CLI = KePaths.CLI

-- macOS can emit two input-source change notifications in rapid succession
-- during a layout switch — debouncing coalesces them into a single rebuild.
-- Shared cross-driver value ([debounce] input_source_ms).
local INPUT_SOURCE_DEBOUNCE_SEC = Timings.sec("debounce", "input_source_ms")

-- mouseMoved fires at display refresh rate (~60–120 fps); capping the
-- subprocess check prevents CPU spikes when CapsWord is not even active.
-- Shared cross-driver value ([ui] capsword_check_interval_ms).
local CAPSWORD_CHECK_INTERVAL_S = Timings.sec("ui", "capsword_check_interval_ms")

-- Holds the pending debounce timer so consecutive notifications within the
-- window supersede the previous one instead of triggering parallel rebuilds.
local _input_source_timer = nil

-- Last known layout name — used by the HIToolbox poll to detect changes when
-- hs.keycodes.inputSourceChanged is unreliable (Sequoia regression).
local _last_known_layout = nil

-- Poll interval for the HIToolbox fallback watcher.
-- Shared cross-driver value ([ui] layout_poll_ms).
local LAYOUT_POLL_SEC = Timings.sec("ui", "layout_poll_ms")

-- Holds the fallback poll timer so it can be cancelled on stop.
local _layout_poll_timer = nil
-- Guard so the async fallback poll never piles up concurrent `defaults` reads.
local _layout_poll_pending = false
-- Max time to wait for a layout read that reported a successful start but never
-- completes. Refused starts release the guard synchronously; this watchdog owns
-- the independent hung/zombied-child failure mode.
local LAYOUT_POLL_TIMEOUT_SEC = 5.0
-- Watchdog handle declared ABOVE the poll body (closure-before-local rule): a
-- `local` declared textually after a closure that uses it binds the nil GLOBAL,
-- and the resulting error inside an async callback is swallowed to the
-- Hammerspoon Console — never reaching infra/logger.
local _layout_poll_watchdog = nil

-- Handle of the in-flight layout read, so the watchdog can reclaim it. Without
-- this the watchdog could only clear the guard: the abandoned `defaults read`
-- stayed pinned in ShellRunner._active_tasks (the pin that stops the GC killing a
-- live task), so every timeout leaked one process and its pin for the rest of the
-- session. Declared above the poll body for the same closure-before-local reason.
local _layout_poll_handle = nil
-- A timeout whose exact ShellRunner termination was refused must be retried
-- before a later tick may construct a successor read.
local _layout_poll_termination_pending = false

-- Identity of the CURRENT layout read. Bumped when a read starts, and again
-- whenever one is abandoned (watchdog timeout, watcher stop), so a completion
-- callback can tell whether it still speaks for the read in flight.
--
-- Terminating a read does not cancel its completion callback — the OS still
-- delivers the SIGTERM exit, moments later, by which time the next tick has
-- usually started read #2. That late callback then cleared read #2's handle
-- (leaving its watchdog nothing to terminate), released read #2's pending guard
-- (letting a third read pile on top), and cancelled read #2's watchdog outright
-- — so the very read that was still running lost every protection it had.
-- Declared above the poll body for the same closure-before-local reason as the
-- handle itself.
local _layout_read_generation = 0

-- Previous hs.keycodes.inputSourceChanged callback saved before start_input_source_watcher
-- installs its own, so stop_input_source_watcher can restore it instead of passing nil
-- (karabiner-input-source-changed-overwrite).
local _previous_input_source_cb = nil
-- Ownership bit is separate because nil is itself a valid previous callback.
-- Without it teardown cannot distinguish "restore nil" from "already restored".
local _input_source_callback_owned = false
local _installed_input_source_cb = nil
-- Every installed callback captures this generation. A native watcher/timer
-- whose stop fails remains physically live but becomes logically inert at once.
local _input_source_watcher_gen = 0

-- Timestamp (fractional seconds) of the last CapsWord subprocess check.
local _capsword_last_check_s = 0

-- Guard against spawning concurrent async checks while one is already in flight.
local _capsword_check_pending = false
-- Max time to wait for the karabiner_cli probe to complete before force-releasing
-- the pending lock. The async task only fires its callback on process EXIT, so a
-- started-but-hung/zombied CLI would otherwise leave the lock set forever (F-L6).
local CAPSWORD_PROBE_TIMEOUT_SEC = 1.5
-- Watchdog timer declared ABOVE deactivate_capsword (closure-nil rule) so the task
-- callback can cancel it and the watchdog callback can reach the pending flag.
local _capsword_probe_watchdog = nil

-- Delayed CapsLock LED correction and the optional gestures-engine hook are
-- lease-owned too; both must be cancellable when Ergopti remapping goes inert.
local _capsword_led_timer = nil
local _gestures_engine = nil
local _capsword_timer_cleanup_backlog = {}

-- Monotonic probe generation. A terminated or timed-out probe's callback still
-- fires, and it used to clear _capsword_check_pending and cancel the watchdog
-- unconditionally — the SUCCESSOR probe's, by then. The sibling layout read in
-- this same module was generation-gated for exactly this; the CapsWord probe was
-- not, so a slow probe could unlock a fresh one and leave two racing.
local _capsword_gen = 0
-- Generation of an accepted CapsWord clear. Ordinary follow-up probes must not
-- cancel its delayed LED correction, but a newer clear or lifecycle restart must.
-- Separate lifecycle generation for installed event/touch callbacks. Probe
-- generations change on every query, so they cannot identify which watcher
-- closure owns an event queued before stop/restart.
local _capsword_watcher_gen = 0

-- GC root for the CapsWord probe tasks. An hs.task that is not referenced from a
-- GC root can be collected mid-run, which kills the subprocess and means its
-- completion callback never fires — here that would leave KE with capsword=1 and
-- the next spacebar would switch CapsLock back on. Canonical spelling recognised
-- by tests/unit/meta/test_gc_retention.lua. Entries are released in the callbacks.
local _active_tasks = {}
-- Partial starts return nil to their caller, so this module must retain any
-- eventtap whose rollback failed; no outer layer ever received that capability.
local _capsword_watcher_backlog = {}
local _input_source_timer_cleanup_backlog = {}
local _layout_watchdog_cleanup_backlog = {}

-- App history cache for direct app-previous focus.
local _current_bundle_id = nil
local _previous_bundle_id = nil
local _current_app_name = nil
local _previous_app_name = nil
local _app_switch_watcher = nil
local _app_switch_watcher_gen = 0
local _app_switch_watcher_active = false

--- Adds an exact cleanup capability once.
--- @param backlog table Dense handle array.
--- @param handle any Exact native/adapter handle.
local function retain_cleanup_handle(backlog, handle)
	for _, retained in ipairs(backlog) do
		if retained == handle then return end
	end
	backlog[#backlog + 1] = handle
end

--- Cancels one TimerScheduler handle and reports native refusal without throw.
--- @param handle table Adapter timer handle.
--- @param label string Diagnostic owner.
--- @return boolean stopped
local function cancel_scheduled_timer(handle, label)
	local cancelled, cancel_result = pcall(TimerScheduler.cancel, handle)
	if cancelled and cancel_result == true then return true end
	Logger.error(LOG, "%s cancellation failed; retained for retry: %s.",
		label, tostring(cancel_result))
	return false
end





-- ===========================================
-- ===========================================
-- ======= 1/ CapsWord Gesture Watcher =======
-- ===========================================
-- ===========================================

--- Applies the CapsLock LED side effect only after the serialized exact-token
--- variable clear has completed and remains the newest local CapsWord intent.
--- @param watcher_gen number Watcher lifecycle generation.
--- @param ok boolean Variable-write settlement.
--- @param reason string Settlement reason.
--- @param revision number Logical CapsWord revision settled by the writer.
local function complete_capsword_clear(watcher_gen, ok, reason, revision)
	if watcher_gen ~= _capsword_watcher_gen then return end
	_capsword_check_pending = false
	if ok ~= true then
		Logger.warn(LOG, "CapsWord clear did not settle successfully: %s.", tostring(reason))
		return
	end

	local revision_ok, current_revision = pcall(KeVariables.capsword_revision)
	if not revision_ok or current_revision ~= revision then
		Logger.debug(LOG, "CapsWord LED clear superseded by newer local intent.")
		return
	end

	if _capsword_led_timer then
		if not cancel_scheduled_timer(_capsword_led_timer, "Superseded CapsWord LED timer") then
			retain_cleanup_handle(_capsword_timer_cleanup_backlog, _capsword_led_timer)
		end
		_capsword_led_timer = nil
	end
	Logger.pcall(LOG, KeyState.set_capslock, false)

	local led_timer = nil
	local callback_fired_before_return = false
	local timer_ok, timer_or_err = pcall(
		TimerScheduler.after,
		0.15,
		function()
			if led_timer == nil then
				callback_fired_before_return = true
				return
			end
			if _capsword_led_timer ~= led_timer then return end
			_capsword_led_timer = nil
			if watcher_gen ~= _capsword_watcher_gen then return end
			local current_ok, latest_revision = pcall(KeVariables.capsword_revision)
			if current_ok and latest_revision == revision then
				Logger.pcall(LOG, KeyState.set_capslock, false)
			end
		end
	)
	led_timer = timer_or_err
	if not timer_ok or type(timer_or_err) ~= "table"
		or timer_or_err.fired == true or callback_fired_before_return then
		if type(timer_or_err) == "table"
			and not cancel_scheduled_timer(timer_or_err, "Rejected CapsWord LED timer") then
			retain_cleanup_handle(_capsword_timer_cleanup_backlog, timer_or_err)
		end
		Logger.error(LOG, "CapsWord LED correction timer could not be armed: %s.",
			tostring(timer_ok and "timer unavailable" or timer_or_err))
		return
	end
	_capsword_led_timer = timer_or_err
	Logger.done(LOG, "CapsWord deactivated via pointer event.")
end

--- Stops one native watcher without dropping a failed capability.
--- @param watcher table Native watcher or eventtap.
--- @param label string Diagnostic owner.
--- @return boolean stopped
local function stop_native_watcher(watcher, label)
	local stopped, stop_err = pcall(function() watcher:stop() end)
	if stopped then return true end
	Logger.error(LOG, "%s stop failed; retained for retry: %s.",
		label, tostring(stop_err))
	return false
end

--- Resets CapsWord: clears the KE variable then turns off the CapsLock LED.
--- Uses a time-based throttle and async hs.task to avoid blocking the Hammerspoon
--- main loop — hs.execute is synchronous and would lag the mouse at ~10 calls/sec.
local function deactivate_capsword(capsword_variable_name, watcher_gen)
	if watcher_gen ~= _capsword_watcher_gen then return end
	-- Throttle: mouseMoved fires at display refresh rate — cap subprocess spawns
	local now_s = hs.timer.secondsSinceEpoch()
	if now_s - _capsword_last_check_s < CAPSWORD_CHECK_INTERVAL_S then return end
	-- Skip if a check is already in flight to avoid concurrent async tasks
	if _capsword_check_pending then return end
	_capsword_last_check_s    = now_s
	_capsword_check_pending   = true
	_capsword_gen             = _capsword_gen + 1
	local my_capsword_gen     = _capsword_gen
	local supersede_callback_fired = false
	local function finish_superseded_activation(ok, reason, revision)
		supersede_callback_fired = true
		complete_capsword_clear(watcher_gen, ok, reason, revision)
	end
	local supersede_ok, superseded_or_err, my_probe_revision = pcall(
		KeVariables.supersede_capsword_activation,
		finish_superseded_activation
	)
	if not supersede_ok then
		_capsword_check_pending = false
		Logger.error(LOG, "CapsWord activation supersession raised: %s",
			tostring(superseded_or_err))
		return
	end
	if superseded_or_err == true or supersede_callback_fired then
		-- A known local activation was either queued for clearing or failed with
		-- a visible settlement. Do not race it with a second probe-owned write.
		return
	end
	if superseded_or_err ~= false
		or type(my_probe_revision) ~= "number"
		or my_probe_revision < 0
		or my_probe_revision ~= math.floor(my_probe_revision) then
		_capsword_check_pending = false
		Logger.error(LOG, "CapsWord activation supersession returned an invalid revision: %s.",
			tostring(my_probe_revision))
		return
	end
	local function abandon_probe(failed_task, reason)
		if watcher_gen ~= _capsword_watcher_gen
			or my_capsword_gen ~= _capsword_gen then return end
		-- A start/scheduling failure can still produce a late task callback. Move
		-- the generation first so that callback cannot mutate a successor probe.
		_capsword_gen = _capsword_gen + 1
		_capsword_check_pending = false
		if _capsword_probe_watchdog then
			if not cancel_scheduled_timer(_capsword_probe_watchdog, "Abandoned CapsWord watchdog") then
				retain_cleanup_handle(_capsword_timer_cleanup_backlog, _capsword_probe_watchdog)
			end
			_capsword_probe_watchdog = nil
		end
		if failed_task then
			local stopped, stop_err = pcall(function() failed_task:terminate() end)
			if stopped then
				_active_tasks[failed_task] = nil
			else
				Logger.error(LOG, "Abandoned CapsWord task termination failed; retained for retry: %s.",
					tostring(stop_err))
			end
		end
		if reason then Logger.error(LOG, "%s", reason) end
	end

	-- Async get: unblocks the main loop immediately; callback fires on completion
	local task
	local function finish_probe(exit_code, stdout, _)
		if task then _active_tasks[task] = nil end
		-- A superseded probe releases nothing: the flag and the watchdog it would
		-- clear belong to the probe that replaced it.
		if watcher_gen ~= _capsword_watcher_gen
			or my_capsword_gen ~= _capsword_gen then return end
		if _capsword_probe_watchdog then
			if not cancel_scheduled_timer(_capsword_probe_watchdog, "Completed CapsWord watchdog") then
				retain_cleanup_handle(_capsword_timer_cleanup_backlog, _capsword_probe_watchdog)
			end
			_capsword_probe_watchdog = nil
		end
		if exit_code ~= 0 or tonumber(stdout) ~= 1 then
			_capsword_check_pending = false
			return
		end

		Logger.trace(LOG, "Pointer event while CapsWord active — deactivating…")

		local clear_callback_fired = false
		local function finish_conditional_clear(ok, reason, revision)
			clear_callback_fired = true
			complete_capsword_clear(watcher_gen, ok, reason, revision)
		end
		local clear_ok, accepted_or_err = pcall(
			KeVariables.set_if_revision,
			"capsword",
			0,
			my_probe_revision,
			finish_conditional_clear
		)
		if not clear_ok then
			if not clear_callback_fired then _capsword_check_pending = false end
			Logger.error(LOG, "Conditional CapsWord clear raised: %s", tostring(accepted_or_err))
			return
		end
		if accepted_or_err ~= true and not clear_callback_fired then
			_capsword_check_pending = false
			Logger.error(LOG, "Conditional CapsWord clear was rejected without settlement.")
		end
		return

	end
	local task_or_err = TaskLifecycle.native("CapsWord variable probe",
		KARABINER_CLI,
		function(...) Logger.pcall(LOG, finish_probe, ...) end,
		{"--get-variable", capsword_variable_name}
	)
	task = task_or_err
	-- Nil means the CLI binary is absent; release the lock immediately so the guard is not permanent.
	if not task then
		abandon_probe(nil, "CapsWord check task is nil; CLI binary absent (karabiner-capsword-lock-leak).")
		return
	end
	-- If task:start() returns false the callback never fires — release the lock so subsequent
	-- pointer events are not permanently blocked (karabiner-capsword-lock-leak).
	_active_tasks[task] = true
	if not TaskLifecycle.start(task, "CapsWord variable probe") then
		abandon_probe(task,
			"CapsWord check task failed to start (karabiner-capsword-lock-leak).")
		return
	end
	-- Started OK, but the async task fires its callback only on process EXIT. Arm a watchdog
	-- so a CLI that starts then hangs/zombies still releases the pending lock instead
	-- of permanently disabling trackpad auto-deactivation of CapsWord (F-L6). Scheduled
	-- via the TimerScheduler adapter (not raw hs.timer.doAfter) so this OS call is
	-- properly attributed to the adapter boundary (PF-1).
	if _capsword_probe_watchdog then
		if not cancel_scheduled_timer(_capsword_probe_watchdog, "Superseded CapsWord watchdog") then
			retain_cleanup_handle(_capsword_timer_cleanup_backlog, _capsword_probe_watchdog)
		end
		_capsword_probe_watchdog = nil
	end
	local watchdog
	local ok_watchdog, watchdog_or_err = pcall(
		TimerScheduler.after,
		CAPSWORD_PROBE_TIMEOUT_SEC,
		function()
			if watcher_gen ~= _capsword_watcher_gen
				or my_capsword_gen ~= _capsword_gen
				or _capsword_probe_watchdog ~= watchdog then return end
			_capsword_probe_watchdog = nil
			if _capsword_check_pending then
				Logger.debug(LOG, "CapsWord probe timed out — releasing lock (karabiner-capsword-lock-leak).")
				abandon_probe(task, nil)
			end
		end
	)
	watchdog = ok_watchdog and watchdog_or_err or nil
	if type(watchdog) ~= "table" or watchdog.fired then
		abandon_probe(task, ok_watchdog
			and "CapsWord probe watchdog could not be armed."
			or "CapsWord probe watchdog raised: " .. tostring(watchdog_or_err))
		return
	end
	_capsword_probe_watchdog = watchdog
end

--- Starts the eventtap watching for any pointer event that signals the user
--- has left the keyboard: movement, scroll, gestures, and all click types.
--- Bare finger contact is handled via gestures_engine.set_any_touch_hook(),
--- which piggybacks on the existing touchdevice frameCallback in the gestures
--- module rather than registering a competing second frameCallback.
--- @param gestures_engine table The gestures engine module (may be nil).
--- @param lease_token string Exact active generation token.
--- @return hs.eventtap|nil The running eventtap watcher instance.
function M.start_gesture_watcher(gestures_engine, lease_token)
	local scoped_name, scope_err = LeaseContract.runtime_variable_name("capsword", lease_token)
	if not scoped_name then
		Logger.error(LOG, "CapsWord watcher refused — %s.", tostring(scope_err))
		return nil
	end
	_capsword_watcher_gen = _capsword_watcher_gen + 1
	_capsword_gen = _capsword_gen + 1
	local watcher_gen = _capsword_watcher_gen
	local function deactivate_current_capsword()
		return deactivate_capsword(scoped_name, watcher_gen)
	end
	local ev = hs.eventtap.event.types
	local watcher
	local create_ok, watcher_or_err = pcall(hs.eventtap.new,
		{
			ev.mouseMoved,
			ev.scrollWheel,
			ev.gesture,
			ev.leftMouseDown,
			ev.rightMouseDown,
			ev.otherMouseDown,
		},
		function(_event)
			if watcher_gen ~= _capsword_watcher_gen then return false end
			-- This is the hottest eventtap. Keep the full probe entry guarded even
			-- though each async constructor/completion also has its own file-log boundary.
			Logger.pcall(LOG, deactivate_current_capsword)
			return false
		end
	)
	watcher = create_ok and watcher_or_err or nil
	if not create_ok or not watcher then
		_capsword_watcher_gen = _capsword_watcher_gen + 1
		Logger.error(LOG, "Trackpad CapsWord watcher creation failed: %s",
			tostring(watcher_or_err))
		return nil
	end
	local start_ok, started_or_err = pcall(function() return watcher:start() end)
	if not start_ok or not started_or_err then
		_capsword_watcher_gen = _capsword_watcher_gen + 1
		if not stop_native_watcher(watcher, "Partial-start CapsWord eventtap") then
			_capsword_watcher_backlog[#_capsword_watcher_backlog + 1] = watcher
		end
		Logger.error(LOG, "Trackpad CapsWord watcher failed to start: %s",
			tostring(started_or_err))
		return nil
	end
	Logger.success(LOG, "Trackpad CapsWord watcher started.")

	-- Layer 2: hook into the gestures engine's existing frameCallback so bare
	-- finger touch (no click, no movement) also deactivates CapsWord.
	if gestures_engine and type(gestures_engine.set_any_touch_hook) == "function" then
		_gestures_engine = gestures_engine
		local hook_ok, hook_err = pcall(
			gestures_engine.set_any_touch_hook,
			deactivate_current_capsword
		)
		if not hook_ok then
			_capsword_watcher_gen = _capsword_watcher_gen + 1
			local hook_cleared = pcall(gestures_engine.set_any_touch_hook, nil)
			if hook_cleared then _gestures_engine = nil end
			if not stop_native_watcher(watcher, "Touch-hook CapsWord eventtap rollback") then
				_capsword_watcher_backlog[#_capsword_watcher_backlog + 1] = watcher
			end
			Logger.error(LOG, "Bare-touch CapsWord hook registration failed: %s",
				tostring(hook_err))
			return nil
		end
		Logger.success(LOG, "Bare-touch CapsWord hook registered on gestures engine.")
	else
		Logger.warn(LOG, "gestures_engine unavailable — bare-touch CapsWord detection disabled.")
	end

	return watcher
end

--- Stops every CapsWord pointer resource owned by this remap generation.
--- @param watcher table|nil Eventtap returned by start_gesture_watcher().
function M.stop_gesture_watcher(watcher)
	_capsword_watcher_gen = _capsword_watcher_gen + 1
	_capsword_gen = _capsword_gen + 1
	_capsword_check_pending = false
	_capsword_last_check_s = 0
	local all_stopped = true
	if watcher then
		if not stop_native_watcher(watcher, "Trackpad CapsWord eventtap") then all_stopped = false end
	end
	for index = #_capsword_watcher_backlog, 1, -1 do
		if stop_native_watcher(_capsword_watcher_backlog[index], "Partial-start CapsWord backlog") then
			table.remove(_capsword_watcher_backlog, index)
		else
			all_stopped = false
		end
	end
	if _capsword_probe_watchdog then
		if cancel_scheduled_timer(_capsword_probe_watchdog, "CapsWord probe watchdog") then
			_capsword_probe_watchdog = nil
		else
			all_stopped = false
		end
	end
	if _capsword_led_timer then
		if cancel_scheduled_timer(_capsword_led_timer, "CapsWord LED timer") then
			_capsword_led_timer = nil
		else
			all_stopped = false
		end
	end
	for index = #_capsword_timer_cleanup_backlog, 1, -1 do
		if cancel_scheduled_timer(_capsword_timer_cleanup_backlog[index],
			"CapsWord timer backlog") then
			table.remove(_capsword_timer_cleanup_backlog, index)
		else
			all_stopped = false
		end
	end
	local tasks = {}
	for task in pairs(_active_tasks) do tasks[#tasks + 1] = task end
	for _, task in ipairs(tasks) do
		local stopped, stop_err = pcall(function() task:terminate() end)
		if stopped then
			_active_tasks[task] = nil
		else
			Logger.error(LOG, "CapsWord probe task termination failed; retained for retry: %s.",
				tostring(stop_err))
			all_stopped = false
		end
	end
	if _gestures_engine and type(_gestures_engine.set_any_touch_hook) == "function" then
		local stopped, stop_err = pcall(_gestures_engine.set_any_touch_hook, nil)
		if stopped then
			_gestures_engine = nil
		else
			Logger.error(LOG, "Bare-touch CapsWord hook removal failed; retained for retry: %s.",
				tostring(stop_err))
			all_stopped = false
		end
	else
		_gestures_engine = nil
	end
	if all_stopped then
		Logger.debug(LOG, "Trackpad CapsWord resources stopped with the Ergopti lease.")
	end
	return all_stopped
end





-- =======================================
-- =======================================
-- ======= 2/ Input Source Watcher =======
-- =======================================
-- =======================================

--- Parses the KeyboardLayout Name out of `defaults read … AppleSelectedInputSources`.
--- @param raw string|nil The raw `defaults` output.
--- @return string|nil The layout name, or nil when absent.
local function parse_layout_name(raw)
	if type(raw) ~= "string" or raw == "" then return nil end
	return raw:match('"KeyboardLayout Name"%s*=%s*"([^"]+)"')
		or raw:match("KeyboardLayout Name%s*=%s*([^;%s]+)")
end

--- Reads the current keyboard layout name from HIToolbox SYNCHRONOUSLY.
--- More reliable than hs.keycodes.currentLayout() on Sequoia which can return
--- stale values from the TIS cache. Used only on the infrequent paths (the
--- one-time boot seed + the notification callback); the periodic fallback poll
--- reads ASYNCHRONOUSLY (read_layout_async) so it never blocks the run loop.
--- @return string|nil
local function read_current_layout_from_hitoolbox()
	local raw, ok = hs.execute("defaults read com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null")
	if not ok then return nil end
	return parse_layout_name(raw)
end

--- Reads Hammerspoon's cached layout exactly once under exception protection.
--- @return string|nil The layout name, or nil when the native read failed.
local function read_current_layout_safe()
	local ok, layout = pcall(hs.keycodes.currentLayout)
	if ok and type(layout) == "string" and layout ~= "" then return layout end
	if not ok then
		Logger.error(LOG, "Cached input-layout read failed: %s.", tostring(layout))
	end
	return nil
end

--- Reads the current keyboard layout name ASYNCHRONOUSLY via the ShellRunner
--- adapter (off the main run loop). The previous fallback poll spawned a
--- SYNCHRONOUS `defaults` subprocess on the main loop every LAYOUT_POLL_SEC for
--- the whole session — exactly the steady-state main-loop cost the profilers aim
--- to eliminate, and worse on the Sequoia machines this poll exists for.
--- @param callback fun(layout_name: string|nil)
--- @return boolean started True only when the exact read task started.
local function read_layout_async(callback)
	-- Stamp this read so its completion can prove it is still the current one.
	_layout_read_generation = _layout_read_generation + 1
	local my_generation = _layout_read_generation

	-- Capture the handle and call start() — ShellRunner.spawn() builds the task
	-- but deliberately does NOT start it; the caller must invoke handle.start().
	-- Without this the subprocess never launches, the completion callback never
	-- fires, and _layout_poll_pending leaks true forever (F-LOW-4 regression).
	local handle
	local spawn_ok, handle_or_err = pcall(ShellRunner.spawn, "/usr/bin/defaults",
		{ "read", "com.apple.HIToolbox", "AppleSelectedInputSources" },
		function(exit_code, stdout, _)
			-- A terminated read still delivers its exit callback, and by then the
			-- next read is usually in flight. Every line below mutates state that
			-- now belongs to THAT read, so a stale completion must stop here rather
			-- than clear its handle, release its guard and cancel its watchdog.
			if my_generation ~= _layout_read_generation then
				if _layout_poll_handle == handle then
					_layout_poll_handle = nil
					_layout_poll_pending = false
					_layout_poll_termination_pending = false
				end
				Logger.debug(LOG, "Ignoring completion of superseded layout read (gen %d, current %d).",
					my_generation, _layout_read_generation)
				return
			end
			-- Drop the ownership reference first: a handle that has completed must
			-- never be terminated by a later watchdog tick.
			_layout_poll_handle = nil
			_layout_poll_termination_pending = false
			if exit_code ~= 0 then callback(nil); return end
			callback(parse_layout_name(stdout))
		end)
	handle = spawn_ok and handle_or_err or nil
	if not spawn_ok or type(handle) ~= "table" or type(handle.start) ~= "function" then
		_layout_read_generation = _layout_read_generation + 1
		Logger.error(LOG, "Layout read construction failed: %s.", tostring(handle_or_err))
		return false
	end
	-- Published BEFORE start() so a handle that completes synchronously has already
	-- cleared it in its callback and cannot be overwritten by a stale assignment.
	_layout_poll_handle = handle
	local start_ok, started_or_err = pcall(handle.start)
	if not start_ok or started_or_err ~= true then
		_layout_read_generation = _layout_read_generation + 1
		if _layout_poll_handle == handle then _layout_poll_handle = nil end
		_layout_poll_termination_pending = false
		Logger.error(LOG, "Layout read failed to start: %s.", tostring(started_or_err))
		return false
	end
	return true
end

--- Fires the on_change callback with proper debouncing, updating _last_known_layout.
--- @param on_change fun(layout_name: string)
--- @param layout_name string
local function fire_layout_change(on_change, layout_name, watcher_gen)
	if _input_source_timer then
		if not stop_native_watcher(_input_source_timer, "Superseded input-source debounce timer") then
			retain_cleanup_handle(_input_source_timer_cleanup_backlog, _input_source_timer)
		end
		_input_source_timer = nil
	end
	local timer
	timer = hs.timer.doAfter(INPUT_SOURCE_DEBOUNCE_SEC, function()
		if _input_source_timer ~= timer then return end
		_input_source_timer = nil
		if watcher_gen ~= _input_source_watcher_gen then return end
		_last_known_layout  = layout_name
		local ok_cb, err = pcall(on_change, layout_name)
		if not ok_cb then
			Logger.error(LOG, "Input source change handler failed: %s.", tostring(err))
		end
	end)
	_input_source_timer = timer
end

--- Registers a debounced layout-change watcher.
--- Uses both hs.keycodes.inputSourceChanged (immediate notification) AND a
--- periodic HIToolbox poll (fallback for Sequoia where the TIS callback is
--- unreliable). The on_change callback fires at most once per debounce window.
--- @param on_change fun(layout_name: string) Called on each debounced layout change.
local function has_input_source_cleanup_debt()
	return _input_source_callback_owned
		or _input_source_timer ~= nil
		or _layout_poll_timer ~= nil
		or _layout_poll_watchdog ~= nil
		or _layout_poll_handle ~= nil
		or _layout_poll_termination_pending
		or _layout_poll_pending
		or #_input_source_timer_cleanup_backlog > 0
		or #_layout_watchdog_cleanup_backlog > 0
end

function M.start_input_source_watcher(on_change)
	Logger.trace(LOG, "Registering input source watcher…")

	-- A failed stop may leave any one of these exact native capabilities alive.
	-- Never overwrite its only retry handle merely because a sibling resource
	-- happened to stop successfully.
	if has_input_source_cleanup_debt() then
		Logger.warn(LOG, "start_input_source_watcher() refused while prior cleanup is unsettled.")
		return false
	end
	_input_source_watcher_gen = _input_source_watcher_gen + 1
	local watcher_gen = _input_source_watcher_gen

	-- Seed the initial known layout from HIToolbox
	_last_known_layout = read_current_layout_from_hitoolbox()
		or read_current_layout_safe()
		or nil
	Logger.debug(LOG, "Initial layout: '%s'.", tostring(_last_known_layout))

	-- Save the previous global callback so stop_input_source_watcher can restore it
	-- rather than passing nil (which would clear callbacks registered by other modules).
	_previous_input_source_cb = hs.keycodes.inputSourceChanged()

	-- Primary: hs.keycodes notification (fires immediately on most macOS versions)
	local installed_callback = function()
		if watcher_gen ~= _input_source_watcher_gen then return end
		Logger.debug(LOG, "Input source notification received — debouncing (%.0fms)…",
			INPUT_SOURCE_DEBOUNCE_SEC * 1000)
		-- Read from HIToolbox, not hs.keycodes.currentLayout(), to avoid TIS cache lag
		local new_layout = read_current_layout_from_hitoolbox()
			or read_current_layout_safe()
			or "<unknown>"
		fire_layout_change(on_change, new_layout, watcher_gen)
	end
	hs.keycodes.inputSourceChanged(installed_callback)
	_installed_input_source_cb = installed_callback
	_input_source_callback_owned = true

	-- Fallback: poll HIToolbox every LAYOUT_POLL_SEC — catches layout changes that
	-- didn't trigger hs.keycodes.inputSourceChanged (Sequoia regression).
	_layout_poll_timer = hs.timer.doEvery(LAYOUT_POLL_SEC, function()
		if watcher_gen ~= _input_source_watcher_gen then return end
		if _layout_poll_termination_pending then
			local abandoned = _layout_poll_handle
			if abandoned then
				local stopped, stop_result = pcall(abandoned.terminate)
				if not stopped or stop_result ~= true then
					Logger.error(LOG,
						"Abandoned layout read termination retry failed; retaining the exact handle: %s.",
						tostring(stop_result))
					return
				end
				if _layout_poll_handle == abandoned then _layout_poll_handle = nil end
			end
			_layout_poll_pending = false
			_layout_poll_termination_pending = false
		end
		-- Read HIToolbox ASYNCHRONOUSLY (off the main run loop). Skip if a read is
		-- already in flight so back-to-back ticks under load cannot pile up tasks.
		if _layout_poll_pending then return end
		_layout_poll_pending = true
		-- Arm the watchdog alongside the guard so a read whose completion callback
		-- never fires still releases it and the next tick can retry. Scheduled via
		-- the TimerScheduler adapter (not raw hs.timer.doAfter) so this OS call is
		-- attributed to the adapter boundary, mirroring the CapsWord probe watchdog.
		if _layout_poll_watchdog then
			if not cancel_scheduled_timer(_layout_poll_watchdog, "Superseded layout watchdog") then
				retain_cleanup_handle(_layout_watchdog_cleanup_backlog, _layout_poll_watchdog)
			end
			_layout_poll_watchdog = nil
		end
		local watchdog
		local callback_fired_before_return = false
		local watchdog_ok, watchdog_or_err = pcall(
			TimerScheduler.after,
			LAYOUT_POLL_TIMEOUT_SEC,
			function()
				if watchdog == nil then
					callback_fired_before_return = true
					return
				end
				if watcher_gen ~= _input_source_watcher_gen
					or _layout_poll_watchdog ~= watchdog then return end
				_layout_poll_watchdog = nil
				if _layout_poll_pending then
					_layout_poll_pending = false
					-- Terminate the abandoned read, don't just stop waiting for it.
					-- handle.terminate() releases the GC pin as well as killing the
					-- process, so neither the subprocess nor its pin outlives the timeout.
					-- Retire the generation BEFORE terminating: terminate() only asks the
					-- OS to kill the process, and its exit callback still arrives later.
					-- Without this the abandoned read comes back to clear the NEXT
					-- read's handle and cancel its watchdog.
					_layout_read_generation = _layout_read_generation + 1
					if _layout_poll_handle then
						local stale = _layout_poll_handle
						local stopped, stop_result = pcall(stale.terminate)
						if stopped and stop_result == true then
							if _layout_poll_handle == stale then _layout_poll_handle = nil end
							_layout_poll_pending = false
							_layout_poll_termination_pending = false
							Logger.warn(LOG, "Layout poll read timed out — terminated the read and released the guard so the next tick can retry.")
						else
							_layout_poll_pending = true
							_layout_poll_termination_pending = true
							Logger.error(LOG,
								"Timed-out layout read termination failed; retaining the exact handle: %s.",
								tostring(stop_result))
						end
					end
				end
			end
		)
		watchdog = watchdog_ok and watchdog_or_err or nil
		if not watchdog_ok or type(watchdog) ~= "table"
			or watchdog.fired == true or callback_fired_before_return then
			_layout_poll_pending = false
			if type(watchdog) == "table"
				and not cancel_scheduled_timer(watchdog, "Rejected layout watchdog") then
				retain_cleanup_handle(_layout_watchdog_cleanup_backlog, watchdog)
			end
			Logger.error(LOG, "Layout poll watchdog could not be armed: %s.",
				tostring(watchdog_ok and "timer unavailable" or watchdog_or_err))
			return
		end
		_layout_poll_watchdog = watchdog
		local read_started = read_layout_async(function(current)
			_layout_poll_pending = false
			if _layout_poll_watchdog == watchdog then
				if not cancel_scheduled_timer(watchdog, "Completed layout watchdog") then
					retain_cleanup_handle(_layout_watchdog_cleanup_backlog, watchdog)
				end
				_layout_poll_watchdog = nil
			end
			if current and current ~= _last_known_layout then
				Logger.info(LOG, "Layout poll detected change: '%s' → '%s'.",
					tostring(_last_known_layout), current)
				fire_layout_change(on_change, current, watcher_gen)
			end
		end)
		if read_started ~= true then
			_layout_poll_pending = false
			if _layout_poll_watchdog == watchdog then
				if not cancel_scheduled_timer(watchdog, "Unstarted layout watchdog") then
					retain_cleanup_handle(_layout_watchdog_cleanup_backlog, watchdog)
				end
				_layout_poll_watchdog = nil
			end
		end
	end)

	Logger.done(LOG, "Input source watcher registered (poll every %.0fs).", LAYOUT_POLL_SEC)
	return true
end

--- Clears the hs.keycodes.inputSourceChanged callback, cancels the poll timer,
--- and cancels any pending debounced rebuild.
function M.stop_input_source_watcher()
	Logger.trace(LOG, "Stopping input source watcher…")
	_input_source_watcher_gen = _input_source_watcher_gen + 1
	local all_stopped = true
	-- Restore the previous callback rather than passing nil, so that any
	-- callback registered before this module started is not silently dropped.
	if _input_source_callback_owned then
		local current_ok, current_or_err = pcall(hs.keycodes.inputSourceChanged)
		if not current_ok then
			Logger.error(LOG, "Input-source callback ownership check failed; retained for retry: %s.",
				tostring(current_or_err))
			all_stopped = false
		elseif current_or_err ~= _installed_input_source_cb then
			-- Another subsystem replaced our callback after start. It now owns the
			-- global slot; restoring our predecessor would clobber that third party.
			_input_source_callback_owned = false
			_installed_input_source_cb = nil
			_previous_input_source_cb = nil
			Logger.debug(LOG, "Input-source callback already replaced by another owner; leaving it intact.")
		else
			local stopped, stop_err = pcall(function()
				hs.keycodes.inputSourceChanged(_previous_input_source_cb)
			end)
			if not stopped then
				Logger.error(LOG, "Input-source callback restoration failed; retained for retry: %s.",
					tostring(stop_err))
				all_stopped = false
			else
				_input_source_callback_owned = false
				_installed_input_source_cb = nil
				_previous_input_source_cb = nil
			end
		end
	end
	if _input_source_timer then
		if stop_native_watcher(_input_source_timer, "Input-source debounce timer") then
			_input_source_timer = nil
		else
			all_stopped = false
		end
	end
	for index = #_input_source_timer_cleanup_backlog, 1, -1 do
		if stop_native_watcher(_input_source_timer_cleanup_backlog[index],
			"Input-source debounce backlog") then
			table.remove(_input_source_timer_cleanup_backlog, index)
		else
			all_stopped = false
		end
	end
	if _layout_poll_timer then
		if stop_native_watcher(_layout_poll_timer, "Layout poll timer") then
			_layout_poll_timer = nil
		else
			all_stopped = false
		end
	end
	-- Cancel the in-flight read's watchdog too, so it cannot fire after the watcher
	-- is gone and flip the guard on a module that is no longer polling.
	if _layout_poll_watchdog then
		if cancel_scheduled_timer(_layout_poll_watchdog, "Layout poll watchdog") then
			_layout_poll_watchdog = nil
		else
			all_stopped = false
		end
	end
	for index = #_layout_watchdog_cleanup_backlog, 1, -1 do
		if cancel_scheduled_timer(_layout_watchdog_cleanup_backlog[index],
			"Layout watchdog backlog") then
			table.remove(_layout_watchdog_cleanup_backlog, index)
		else
			all_stopped = false
		end
	end
	_layout_poll_pending = false
	-- Retire the in-flight read as well. Its completion would otherwise land on a
	-- stopped watcher and fire a layout change nobody is listening for.
	_layout_read_generation = _layout_read_generation + 1
	if _layout_poll_handle then
		local handle = _layout_poll_handle
		local stopped, stop_result = pcall(handle.terminate)
		if stopped and stop_result == true then
			if _layout_poll_handle == handle then _layout_poll_handle = nil end
			_layout_poll_termination_pending = false
		else
			_layout_poll_termination_pending = true
			Logger.error(LOG, "In-flight layout read termination failed; retained for retry: %s.",
				tostring(stop_result))
			all_stopped = false
		end
	else
		_layout_poll_termination_pending = false
	end
	if all_stopped then Logger.done(LOG, "Input source watcher stopped.") end
	return all_stopped
end






-- =======================================
-- =======================================
-- ======= 3/ Cycle Windows Hotkey =======
-- =======================================
-- =======================================

--- Cycles focus to the next standard, visible window of the frontmost application.
--- Skips minimised and non-standard (panel, drawer, sheet) windows.
local function cycle_windows_in_app()
	local app = hs.application.frontmostApplication()
	if not app then return end

	local visible = {}
	for _, w in ipairs(app:allWindows() or {}) do
		if w:isStandard() and not w:isMinimized() then
			visible[#visible + 1] = w
		end
	end

	if #visible < 2 then return end

	local focused  = hs.window.focusedWindow()
	local next_idx = 1
	for i, w in ipairs(visible) do
		if w == focused then
			-- Wrap around: last window goes back to first
			next_idx = (i % #visible) + 1
			break
		end
	end

	local ok_focus, focus_result = pcall(function() return visible[next_idx]:focus() end)
	-- hs.window:focus() returns the window object, not literal true.
	if not ok_focus or focus_result == nil or focus_result == false then
		Logger.warn(LOG, "Window cycle focus was refused: %s.", tostring(focus_result))
		return false
	end
	return true
end

--- Starts app-activation tracking for direct previous-app switching.
local function ensure_app_switch_watcher()
	if _app_switch_watcher then return _app_switch_watcher_active == true end
	_app_switch_watcher_gen = _app_switch_watcher_gen + 1
	local watcher_gen = _app_switch_watcher_gen

	local created, watcher_or_err = pcall(hs.application.watcher.new, function(_name, event_type, app)
		if watcher_gen ~= _app_switch_watcher_gen or not _app_switch_watcher_active then return end
		if event_type ~= hs.application.watcher.activated then return end
		if not app then return end

		local bundle_id = app:bundleID()
		local app_name = app:name()
		if type(app_name) ~= "string" or app_name == "" then return end
		if app_name == _current_app_name then return end

		_previous_bundle_id = _current_bundle_id
		_previous_app_name = _current_app_name
		_current_bundle_id = bundle_id
		_current_app_name = app_name
	end)
	if not created or not watcher_or_err then
		Logger.error(LOG, "App-switch watcher creation failed: %s.", tostring(watcher_or_err))
		return false
	end
	_app_switch_watcher = watcher_or_err
	_app_switch_watcher_active = true
	local started, start_result = pcall(function() return watcher_or_err:start() end)
	if not started or start_result == false then
		_app_switch_watcher_active = false
		_app_switch_watcher_gen = _app_switch_watcher_gen + 1
		if stop_native_watcher(watcher_or_err, "Partial app-switch watcher") then
			_app_switch_watcher = nil
		end
		Logger.error(LOG, "App-switch watcher failed to start: %s.", tostring(start_result))
		return false
	end

	local front = hs.application.frontmostApplication()
	if front then
		_current_bundle_id = front:bundleID()
		_current_app_name = front:name()
	end
	return true
end

--- Focuses the most recently used standard window, optionally restricted to one
--- screen.
---
--- `screen_id` restricts candidates, or nil for no constraint. The two public
--- cyclers differ only in that argument: one implementation means a window state
--- that has to be excluded — minimised, non-standard — is excluded from both,
--- which is not true of two functions that merely look alike.
--- @param screen_id number|nil Restrict candidates to windows on this screen.
--- @return boolean True when a window was focused.
local function focus_previous_window(screen_id)
	local wins = hs.window.orderedWindows()
	if type(wins) ~= "table" or #wins <= 1 then return false end

	local focused = hs.window.focusedWindow()
	local focused_id = focused and focused:id() or nil

	for _, w in ipairs(wins) do
		local wid = w and w:id() or nil
		if wid and (not focused_id or wid ~= focused_id)
			and w:isStandard() and not w:isMinimized() then
			local on_screen = true
			if screen_id then
				local w_screen = w:screen()
				on_screen = w_screen ~= nil and w_screen:id() == screen_id
			end
			if on_screen then
				local ok_focus, focus_result = pcall(function() return w:focus() end)
				if ok_focus and focus_result ~= nil and focus_result ~= false then return true end
				Logger.warn(LOG, "Previous-window focus was refused for window %s: %s.",
					tostring(wid), tostring(focus_result))
			end
		end
	end

	return false
end

--- Focuses the globally previous standard window (MRU-2), any screen.
local function focus_previous_window_global()
	return focus_previous_window(nil)
end

--- Focuses the previous standard window on the display under the cursor.
--- The Windows driver has cycled per-monitor since it was written; macOS only
--- cycled globally, so on a multi-screen desk the same gesture behaved
--- differently on the two platforms with nothing recording the difference. Both
--- behaviours are wanted — this is the missing half, not a replacement.
local function focus_previous_window_on_screen()
	local screen_id = MouseControl.screen_id_under_cursor()
	if not screen_id then
		-- The cursor is on no screen — a real state during a display change.
		-- Falling back to the global cycle would be worse than doing nothing:
		-- the user asked for THIS screen, and silently focusing a window on
		-- another one is a switch they then have to undo.
		Logger.debug(LOG, "Per-screen window cycle: the cursor is on no screen — nothing to cycle.")
		return false
	end
	return focus_previous_window(screen_id)
end

--- Focuses the previously active application directly (no macOS switcher overlay).
local function focus_previous_app_direct()
	if not ensure_app_switch_watcher() then return false end

	if type(_previous_bundle_id) == "string"
		and _previous_bundle_id ~= ""
		and type(hs.application.launchOrFocusByBundleID) == "function" then
		local ok, result = pcall(hs.application.launchOrFocusByBundleID, _previous_bundle_id)
		if ok and result == true then return true end
	end

	if type(_previous_app_name) == "string" and _previous_app_name ~= "" then
		local ok, result = pcall(hs.application.launchOrFocus, _previous_app_name)
		if ok and result == true then return true end
	end

	if type(_previous_bundle_id) == "string" and _previous_bundle_id ~= "" then
		local target = hs.application.get(_previous_bundle_id)
		if target then
			local ok_activate, activate_result = pcall(function() return target:activate() end)
			return ok_activate and activate_result == true
		end
	end

	return false
end

--- Registers a global hotkey on F17 that cycles windows within the frontmost app.
--- F17 is sent by the 'cycle_windows_in_app' Karabiner action, making the shortcut
--- layout-independent — no dependency on the macOS Cmd+` binding, which is
--- unreliable on AZERTY and other non-US keyboard layouts.
--- F17 is used here because F13/F14/F15 are reserved as script-control
--- sentinels and F16 carries the LLM-chain signal in this codebase.
--- Binds one F17 chord through the hotkey adapter.
---
--- The four bindings used to call hs.hotkey.new directly. Routing them through
--- adapters/hotkey_registrar keeps this module free of the Hammerspoon hotkey
--- API — the same reason keyboard_shortcuts.lua was moved onto it — and gives
--- all four one place where a chord the OS refuses is reported.
--- @param chord string Canonical chord, e.g. "Ctrl+F17".
--- @param label string What the binding is, for the log lines.
--- @param action function Zero-arity behaviour to run on press.
--- @return string|nil handle Registrar handle, or nil when the OS refused it.
local function bind_f17(chord, label, action)
	Logger.trace(LOG, "Registering %s hotkey (%s)…", label, chord)
	local handle = Registrar.bind(chord, function()
		local ok, result = pcall(action)
		if not ok then
			Logger.warn(LOG, "%s callback failed: %s", chord, tostring(result))
			return false
		end
		return result
	end)
	if not handle then
		Logger.error(LOG, "%s could not be bound — the %s action is unreachable from a key.", chord, label)
		return nil
	end
	Logger.done(LOG, "%s hotkey registered.", label)
	return handle
end

--- @return string|nil Registrar handle for the bare F17 binding.
function M.start_cycle_windows_hotkey()
	return bind_f17(KEYCODE_F17_NAME, "cycle-windows", cycle_windows_in_app)
end

--- Registers Shift+F17 as "global previous window".
--- @return string|nil Registrar handle.
function M.start_alt_tab_windows_hotkey()
	return bind_f17(MOD_SHIFT .. "+" .. KEYCODE_F17_NAME, "Alt+Tab windows", focus_previous_window_global)
end

--- Registers Ctrl+F17 as "previous window on the display under the cursor".
---
--- The fourth F17 chord, and the last free one in the set the remap layer uses.
--- Windows has cycled per-monitor since it was written and macOS only globally,
--- so the same physical key behaved differently on the two platforms with
--- nothing recording it. Both behaviours are now bindable on both.
--- @return string|nil Registrar handle.
function M.start_alt_tab_monitor_hotkey()
	return bind_f17(MOD_CTRL .. "+" .. KEYCODE_F17_NAME, "per-screen window", focus_previous_window_on_screen)
end

--- Registers Option+F17 as "direct previous app".
--- @return string|nil Registrar handle.
function M.start_alt_tab_apps_hotkey()
	if not ensure_app_switch_watcher() then return nil end
	return bind_f17(MOD_ALT .. "+" .. KEYCODE_F17_NAME, "Alt+Tab apps", focus_previous_app_direct)
end

--- Stops the internal app-switch watcher used by Alt+Tab app-previous.
function M.stop_alt_tab_apps_tracker()
	_app_switch_watcher_gen = _app_switch_watcher_gen + 1
	if not _app_switch_watcher then return true end
	_app_switch_watcher_active = false
	local watcher = _app_switch_watcher
	local stopped, stop_err = pcall(function() watcher:stop() end)
	if not stopped then
		Logger.error(LOG, "App-switch watcher stop failed; retained for retry: %s.",
			tostring(stop_err))
		return false
	end
	if _app_switch_watcher == watcher then
		_app_switch_watcher = nil
		_current_bundle_id = nil
		_previous_bundle_id = nil
		_current_app_name = nil
		_previous_app_name = nil
	end
	return true
end

return M
