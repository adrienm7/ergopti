--- platform/remap/watchers.lua

--- ==============================================================================
--- MODULE: Karabiner Bridge Watchers
--- DESCRIPTION:
--- Three event handlers for the Karabiner bridge: a CapsWord watcher that ends
--- CapsWord on what [shortcuts.caps_word] checks (a typed delimiter, the
--- inactivity delay, a pointer kind: touch, gesture, motion, scroll or click),
--- a debounced input-source watcher that fires a callback on each keyboard
--- layout change, and a hotkey that cycles through windows of the frontmost
--- application.
---
--- FEATURES & RATIONALE:
--- 1. CapsWord Auto-Off: the settings come from infra/capsword_auto_off and the
---    shared policy decides each event. hs.eventtap catches keystrokes, clicks,
---    scrolls, gestures and cursor movement; the undocumented MultitouchSupport
---    frameCallback catches bare finger touches that eventtap cannot see. A
---    100 ms throttle keeps pointer motion cheap; a typed delimiter and the
---    delay switch CapsLock off at once, before the next letter.
--- 2. Layout Awareness: macOS can emit two input-source notifications in rapid
---    succession during a layout switch. Debouncing coalesces them into a
---    single callback so the caller does not rebuild the KE config twice.
---    One layout has two names: hs.keycodes gives its localised name
---    ("Ergopti+"), HIToolbox its KeyboardLayout Name ("Ergopti_v2_2_2_plus").
---    Each is compared only with a name of its own form (layout-name-forms).
--- 3. Window Cycling: Cycles focus through standard windows of the active app
---    directly via the Hammerspoon API, bypassing the macOS Cmd+` shortcut
---    which is layout-dependent and inactive on some keyboard layouts (AZERTY).
--- ==============================================================================

local M = {}

local hs             = hs
local Logger         = require("infra.logger")
local InputSourceBroker = require("adapters.input_source_broker")
local Timings        = require("infra.timings")
local Keycodes       = require("infra.keycodes")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")
local KeyState       = require("adapters.key_state")
local MouseControl   = require("adapters.mouse_control")
local Registrar      = require("adapters.hotkey_registrar")
local LeaseContract  = require("platform.remap.lease_contract")
local KeVariables   = require("platform.remap.ke_variables")
local CapsWordAutoOff = require("infra.capsword_auto_off")
local CapsWordOutput = require("infra.capsword_output")
local AutoOffPolicy  = require("caps_word.auto_off")
-- Layout observation does not own keyboard-control resources. Acquire this
-- dependency only when the CapsWord generation starts its gesture watcher.
local ControlSentinels = nil


local LOG = "karabiner"
local INPUT_SOURCE_SUBSCRIBER_ID = "platform.remap.watchers"

-- hs.hotkey accepts the macOS key name directly, derived here from the
-- registry numeric keycode so the registry stays the canonical source.
local KEYCODE_F17_NAME = Keycodes.to_name(Keycodes.F17_CYCLE_WINDOWS)
local MOD_SHIFT = "shift"
local MOD_ALT = "alt"
local MOD_CTRL = "ctrl"

-- macOS can emit two input-source change notifications in rapid succession
-- during a layout switch — debouncing coalesces them into a single rebuild.
-- Shared cross-driver value ([debounce] input_source_ms).
local INPUT_SOURCE_DEBOUNCE_SEC = Timings.sec("debounce", "input_source_ms")

-- mouseMoved fires at display refresh rate (~60–120 fps); capping the
-- CapsWord check keeps the hottest eventtap cheap when CapsWord is not active.
-- Shared cross-driver value ([ui] capsword_check_interval_ms).
local NANOSECONDS_PER_SECOND = 1000000000
local CAPSWORD_CHECK_INTERVAL_NS = Timings.sec("ui", "capsword_check_interval_ms")
	* NANOSECONDS_PER_SECOND
local NANOSECONDS_PER_MILLISECOND = 1000000
local MILLISECONDS_PER_SECOND = 1000
-- otherMouseDown carries the button number: 2 is the middle button (0 and 1
-- are the left and right buttons, which have event types of their own).
local MIDDLE_BUTTON_NUMBER = 2

-- Holds the pending debounce timer so consecutive notifications within the
-- window supersede the previous one instead of triggering parallel rebuilds.
local _input_source_timer = nil

-- Last known layout as HIToolbox names it (KeyboardLayout Name) — used by the
-- HIToolbox poll to detect changes when hs.keycodes.inputSourceChanged is
-- unreliable (Sequoia regression). Nil until the watcher's first read adopts it.
local _last_known_layout = nil
-- The same layout as hs.keycodes names it (its localised name). Only the read
-- that adopts the HIToolbox baseline, and a notification whose HIToolbox read
-- failed, compare against it (layout-name-forms).
local _last_known_cached_layout = nil
-- A notification arrived before the HIToolbox baseline existed.
local _notification_before_baseline = false

-- Poll interval for the HIToolbox fallback watcher.
-- Shared cross-driver value ([ui] layout_poll_ms).
local LAYOUT_POLL_SEC = Timings.sec("ui", "layout_poll_ms")

-- Holds the fallback poll timer so it can be cancelled on stop.
local _layout_poll_timer = nil
local _layout_poll_committed = false
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
local _layout_read_observed = setmetatable({}, { __mode = "k" })

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

local _input_source_callback_owned = false
-- Every installed callback captures this generation. A native watcher/timer
-- whose stop fails remains physically live but becomes logically inert at once.
local _input_source_watcher_gen = 0

-- Monotonic timestamp of the last CapsWord check.
local _capsword_last_check_ns = 0

-- Set while an accepted CapsWord clear settles, so pointer events queue no duplicate.
local _capsword_check_pending = false

-- Delayed CapsLock LED correction and the optional gestures-engine hook are
-- lease-owned too; both must be cancellable when Ergopti remapping goes inert.
local _capsword_led_timer = nil
local _gestures_engine = nil
local _capsword_listener_owned = false
local _capsword_timer_cleanup_backlog = {}

-- Lifecycle generation for installed event/touch callbacks: it identifies which
-- watcher closure owns an event queued before stop/restart.
local _capsword_watcher_gen = 0

-- CapsWord inactivity: the one-shot check timer, and the monotonic clock of the
-- activation or keystroke it measures from. Declared above their closures.
local _capsword_idle_timer = nil
local _capsword_last_activity_ns = 0

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

--- Retries every exact timer capability retained after a refused cancellation.
--- No same-family successor may be acquired while one native candidate remains
--- unsettled, even though its generation fence already makes its callback inert.
--- @param backlog table Dense handle array.
--- @param label string Diagnostic owner.
--- @return boolean settled
local function drain_scheduled_backlog(backlog, label)
	local settled = true
	for index = #backlog, 1, -1 do
		if cancel_scheduled_timer(backlog[index], label) then
			table.remove(backlog, index)
		else
			settled = false
		end
	end
	return settled
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
--- @param cause string What ended CapsWord, for the log.
local function complete_capsword_clear(watcher_gen, ok, reason, revision, cause)
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
	if not drain_scheduled_backlog(_capsword_timer_cleanup_backlog,
		"CapsWord timer backlog") then
		Logger.error(LOG, "CapsWord LED correction blocked by prior timer cleanup debt.")
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
	local timer_ok, timer_or_err, timer_committed = pcall(
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
	if not timer_ok or timer_committed ~= true or type(timer_or_err) ~= "table"
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
	Logger.debug(LOG, "CapsWord clear settled (%s).", tostring(cause))
end

--- Cancels the inactivity timer, retaining a refused handle for the teardown.
local function cancel_capsword_idle_timer()
	if not _capsword_idle_timer then return end
	if not cancel_scheduled_timer(_capsword_idle_timer, "CapsWord inactivity timer") then
		retain_cleanup_handle(_capsword_timer_cleanup_backlog, _capsword_idle_timer)
	end
	_capsword_idle_timer = nil
end

--- Stops one native watcher without dropping a failed capability.
--- @param watcher table Native watcher or eventtap.
--- @param label string Diagnostic owner.
--- @return boolean stopped
local function stop_native_watcher(watcher, label)
	local stopped, stop_result = pcall(function() return watcher:stop() end)
	if stopped and stop_result ~= false then return true end
	Logger.error(LOG, "%s stop failed; retained for retry: %s.",
		label, tostring(stop_result))
	return false
end

--- Verifies the exact native running state of the recurring layout poll timer.
--- Real Hammerspoon timers expose running(); the boolean branch is only for the
--- pure-Lua lifecycle doubles used by the unit suite.
--- @param timer_handle table|userdata Native timer candidate.
--- @param expected boolean Required running state.
--- @return boolean matches
--- @return string|nil detail
local function layout_poll_running_matches(timer_handle, expected)
	local member_ok, member_or_err = pcall(function() return timer_handle.running end)
	if not member_ok then return false, tostring(member_or_err) end
	if type(member_or_err) == "boolean" and type(timer_handle) == "table" then
		if member_or_err == expected then return true end
		return false, string.format("running state was %s", tostring(member_or_err))
	end
	if type(member_or_err) ~= "function" then return false, "running() unavailable" end
	local probe_ok, running_or_err = pcall(member_or_err, timer_handle)
	if not probe_ok or type(running_or_err) ~= "boolean" then
		return false, tostring(running_or_err)
	end
	if running_or_err ~= expected then
		return false, string.format("running() returned %s", tostring(running_or_err))
	end
	return true
end

--- Stops the exact layout-poll capability and retains it unless native state
--- proves that it is no longer running.
--- @param timer_handle table|userdata Exact layout timer.
--- @param label string Diagnostic owner.
--- @return boolean stopped
local function stop_layout_poll_timer(timer_handle, label)
	local stopped, stop_result = pcall(function() return timer_handle:stop() end)
	local state_stopped, state_detail = layout_poll_running_matches(timer_handle, false)
	if stopped and stop_result ~= false and state_stopped then return true end
	Logger.error(LOG, "%s stop failed; retained for retry: %s.", label,
		tostring(not stopped and stop_result
			or (stop_result == false and "stop returned false")
			or state_detail))
	return false
end

--- Cancels a CapsWord this driver knows to be active: one it activated, or one
--- whose Karabiner control signal it observed. karabiner_cli has no option to
--- read a variable (no --get-variable), so no other activation can be detected
--- and none is cleared. The clear is serialized and asynchronous; a throttle and
--- a pending flag keep pointer events from queuing duplicates. A keystroke cause
--- (a checked delimiter, the inactivity delay) is never throttled and switches
--- CapsLock off at once, before the event reaches the application: waiting for
--- the asynchronous clear would capitalise the next letters.
--- @param watcher_gen number Watcher lifecycle generation.
--- @param cause string What ends CapsWord, for the log.
--- @param immediate boolean|nil True for a keystroke cause.
local function deactivate_capsword(watcher_gen, cause, immediate)
	if watcher_gen ~= _capsword_watcher_gen then return end
	if not drain_scheduled_backlog(_capsword_timer_cleanup_backlog,
		"CapsWord timer backlog") then
		Logger.error(LOG, "CapsWord clear blocked by prior timer cleanup debt.")
		return
	end
	-- Throttle: mouseMoved fires at display refresh rate.
	local now_ns = TimerScheduler.now_ns()
	if not immediate and now_ns - _capsword_last_check_ns < CAPSWORD_CHECK_INTERVAL_NS then return end
	-- Skip while an accepted clear is still settling.
	if _capsword_check_pending then return end
	_capsword_last_check_ns   = now_ns
	_capsword_check_pending   = true
	local supersede_callback_fired = false
	local function finish_superseded_activation(ok, reason, revision)
		supersede_callback_fired = true
		complete_capsword_clear(watcher_gen, ok, reason, revision, cause)
	end
	local supersede_ok, superseded_or_err = pcall(
		KeVariables.supersede_capsword_activation,
		finish_superseded_activation
	)
	if not supersede_ok then
		_capsword_check_pending = false
		Logger.error(LOG, "CapsWord activation supersession raised: %s",
			tostring(superseded_or_err))
		return
	end
	-- An accepted clear, or one that already settled, owns the pending flag.
	if superseded_or_err == true or supersede_callback_fired then
		if superseded_or_err == true then
			Logger.info(LOG, "CapsWord deactivated: %s.", tostring(cause))
			cancel_capsword_idle_timer()
			if immediate then Logger.pcall(LOG, KeyState.set_capslock, false) end
		end
		return
	end
	_capsword_check_pending = false
	if superseded_or_err ~= false then
		Logger.error(LOG, "CapsWord activation supersession returned an invalid result: %s.",
			tostring(superseded_or_err))
	end
end

-- Forward declaration: the check and the scheduler call each other.
local schedule_capsword_idle_check

--- Ends CapsWord once the delay has passed since its activation or its last
--- keystroke, or looks again when the remaining time is due.
--- @param watcher_gen number Watcher lifecycle generation.
--- @param handle table Exact timer this check belongs to.
local function capsword_idle_check(watcher_gen, handle)
	if watcher_gen ~= _capsword_watcher_gen or _capsword_idle_timer ~= handle then return end
	_capsword_idle_timer = nil
	if not KeVariables.capsword_known_active() then return end
	local delay_ms = AutoOffPolicy.idle_delay_ms(CapsWordAutoOff.policy())
	if not delay_ms then return end
	local now_ms = TimerScheduler.now_ns() / NANOSECONDS_PER_MILLISECOND
	local last_ms = _capsword_last_activity_ns / NANOSECONDS_PER_MILLISECOND
	if AutoOffPolicy.idle_expired(CapsWordAutoOff.policy(), last_ms, now_ms) then
		deactivate_capsword(watcher_gen,
			string.format("no keystroke for %g s", delay_ms / MILLISECONDS_PER_SECOND), true)
		return
	end
	schedule_capsword_idle_check(watcher_gen, (delay_ms - (now_ms - last_ms)) / MILLISECONDS_PER_SECOND)
end

--- Arms the one inactivity check of this watcher generation.
--- @param watcher_gen number Watcher lifecycle generation.
--- @param seconds number Delay before the check.
schedule_capsword_idle_check = function(watcher_gen, seconds)
	cancel_capsword_idle_timer()
	local handle = nil
	local fired_before_return = false
	local ok, handle_or_err, committed = pcall(TimerScheduler.after, seconds, function()
		if handle == nil then
			fired_before_return = true
			return
		end
		Logger.pcall(LOG, capsword_idle_check, watcher_gen, handle)
	end)
	handle = handle_or_err
	if not ok or committed ~= true or type(handle_or_err) ~= "table" or fired_before_return then
		if type(handle_or_err) == "table"
			and not cancel_scheduled_timer(handle_or_err, "Rejected CapsWord inactivity timer") then
			retain_cleanup_handle(_capsword_timer_cleanup_backlog, handle_or_err)
		end
		Logger.error(LOG, "CapsWord inactivity timer could not be armed: %s.",
			tostring(ok and "timer unavailable" or handle_or_err))
		return
	end
	_capsword_idle_timer = handle_or_err
end

--- Starts measuring inactivity from now, when a delay is configured.
--- @param watcher_gen number Watcher lifecycle generation.
local function start_capsword_idle_clock(watcher_gen)
	cancel_capsword_idle_timer()
	local delay_ms = AutoOffPolicy.idle_delay_ms(CapsWordAutoOff.policy())
	if not delay_ms then return end
	_capsword_last_activity_ns = TimerScheduler.now_ns()
	schedule_capsword_idle_check(watcher_gen, delay_ms / MILLISECONDS_PER_SECOND)
end

--- Names the declared pointer kind of one pointer event.
--- @param event table hs.eventtap.event of a watched pointer type.
--- @param types table hs.eventtap.event.types.
--- @return string kind
local function capsword_pointer_kind(event, types)
	local event_type = event:getType()
	if event_type == types.mouseMoved or event_type == types.scrollWheel then return "pointer_motion" end
	if event_type == types.gesture then return "gesture" end
	if event_type == types.leftMouseDown then return "left_click" end
	if event_type == types.rightMouseDown then return "right_click" end
	if event_type == types.otherMouseDown then
		local button = event:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)
		return button == MIDDLE_BUTTON_NUMBER and "middle_click" or "other_buttons"
	end
	error("CapsWord watcher received an unwatched event type " .. tostring(event_type))
end

--- Handles one watched event: a keystroke while CapsWord is on resets the
--- inactivity clock and ends CapsWord on a checked delimiter; a pointer event
--- ends it when its kind is checked.
--- @param watcher_gen number Watcher lifecycle generation.
--- @param event table hs.eventtap.event.
--- @param types table hs.eventtap.event.types.
local function handle_capsword_event(watcher_gen, event, types)
	if event:getType() == types.keyDown then
		-- Every keystroke reaches this tap; only an active CapsWord costs anything.
		-- The characters are the typed output: the layout's, Karabiner's remap,
		-- a completed dead key, a French spaced-punctuation carrier.
		if not KeVariables.capsword_known_active() then return end
		_capsword_last_activity_ns = TimerScheduler.now_ns()
		local text = event:getCharacters()
		if AutoOffPolicy.ends_on_text(CapsWordAutoOff.policy(), text) then
			deactivate_capsword(watcher_gen, "delimiter typed", true)
		end
		return
	end
	local kind = capsword_pointer_kind(event, types)
	if AutoOffPolicy.ends_on_pointer(CapsWordAutoOff.policy(), kind) then
		deactivate_capsword(watcher_gen, "pointer " .. kind)
	end
end

--- Ends CapsWord on a delimiter in text the driver itself typed (a hotstring
--- expansion, a replayed delimiter): its key events may never cross this tap.
--- @param watcher_gen number Watcher lifecycle generation.
--- @param text string Driver output.
local function handle_capsword_output(watcher_gen, text)
	if watcher_gen ~= _capsword_watcher_gen or not KeVariables.capsword_known_active() then return end
	_capsword_last_activity_ns = TimerScheduler.now_ns()
	if AutoOffPolicy.ends_on_text(CapsWordAutoOff.policy(), text) then
		deactivate_capsword(watcher_gen, "delimiter in driver output", true)
	end
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
	-- The lease token gates the control-signal listener below; refuse a token
	-- that cannot even name the generation's CapsWord variable.
	local scoped_name, scope_err = LeaseContract.runtime_variable_name("capsword", lease_token)
	if not scoped_name then
		Logger.error(LOG, "CapsWord watcher refused — %s.", tostring(scope_err))
		return nil
	end
	if ControlSentinels == nil then
		local owner_ok, owner_or_err = pcall(require, "modules.keymap.control_sentinels")
		if not owner_ok then
			Logger.error(LOG, "CapsWord control signal owner could not be loaded: %s.", tostring(owner_or_err))
			return nil
		end
		ControlSentinels = owner_or_err
	end
	_capsword_watcher_gen = _capsword_watcher_gen + 1
	local watcher_gen = _capsword_watcher_gen
	local ev = hs.eventtap.event.types
	local function handle_current_event(event)
		return handle_capsword_event(watcher_gen, event, ev)
	end
	-- A bare finger on the trackpad is a gesture kind for the CapsWord settings.
	local function touch_current_capsword()
		if AutoOffPolicy.ends_on_pointer(CapsWordAutoOff.policy(), "gesture") then
			return deactivate_capsword(watcher_gen, "pointer gesture")
		end
	end
	local watcher
	-- Every type is armed and the settings filter each event: a menu change
	-- applies at the next event without restarting this lease-owned tap.
	local create_ok, watcher_or_err = pcall(hs.eventtap.new,
		{
			ev.mouseMoved,
			ev.scrollWheel,
			ev.gesture,
			ev.leftMouseDown,
			ev.rightMouseDown,
			ev.otherMouseDown,
			ev.keyDown,
		},
		function(event)
			if watcher_gen ~= _capsword_watcher_gen then return false end
			-- This is the hottest eventtap. Keep the full entry guarded even though
			-- each asynchronous clear settlement also has its own file-log boundary.
			Logger.pcall(LOG, handle_current_event, event)
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
			touch_current_capsword
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

	-- Initialize the serialized owner's exact token off the HID callback. The
	-- named listener then does only bounded in-memory observation; stale stopped
	-- closures cannot adopt a replacement lease or invalidate its LED receipt.
	local initialized, revision = pcall(KeVariables.capsword_revision)
	local registered, register_err = false, nil
	if initialized and type(revision) == "number" then
		registered, register_err = pcall(ControlSentinels.set_listener, "karabiner.capsword", function(signal)
			-- Tags use the existing reserved-key route, not a token-bearing IPC
			-- payload. The active graph and captured watcher lease are the fences;
			-- a queued identical tag cannot prove its original producing token.
			if watcher_gen ~= _capsword_watcher_gen then return end
			local value = signal == ControlSentinels.CAPSWORD_ACTIVATED and 1
				or (signal == ControlSentinels.CAPSWORD_DEACTIVATED and 0 or nil)
			if value == nil then return end
			if KeVariables.observe_capsword_state(value, lease_token) ~= true then return end
			-- The inactivity delay counts from the activation; a Karabiner exit
			-- (Escape, an arrow, CapsLock) leaves nothing to time out.
			if value == 1 then
				Logger.pcall(LOG, start_capsword_idle_clock, watcher_gen)
			else
				cancel_capsword_idle_timer()
			end
		end)
	end
	if not registered then
		_capsword_watcher_gen = _capsword_watcher_gen + 1
		if _gestures_engine then
			local cleared = pcall(_gestures_engine.set_any_touch_hook, nil)
			if cleared then _gestures_engine = nil end
		end
		if not stop_native_watcher(watcher, "CapsWord listener acquisition rollback") then
			_capsword_watcher_backlog[#_capsword_watcher_backlog + 1] = watcher
		end
		Logger.error(LOG, "CapsWord control listener could not be acquired: %s.",
			tostring(register_err or revision))
		return nil
	end
	_capsword_listener_owned = true
	CapsWordOutput.set_observer(function(text)
		return handle_capsword_output(watcher_gen, text)
	end)
	return watcher
end

--- Starts the inactivity delay of a CapsWord this driver switched on itself (a
--- gesture's CapsWord action writes the Karabiner variable, which raises no
--- control signal). A no-op without a running watcher.
--- @return boolean armed True when a running watcher took the activation.
function M.note_capsword_activated()
	if not _capsword_listener_owned then return false end
	start_capsword_idle_clock(_capsword_watcher_gen)
	return true
end

--- Stops every CapsWord pointer resource owned by this remap generation.
--- @param watcher table|nil Eventtap returned by start_gesture_watcher().
function M.stop_gesture_watcher(watcher)
	_capsword_watcher_gen = _capsword_watcher_gen + 1
	_capsword_check_pending = false
	_capsword_last_check_ns = 0
	CapsWordOutput.set_observer(nil)
	local all_stopped = true
	if _capsword_listener_owned then
		local removed, remove_err = pcall(ControlSentinels.set_listener, "karabiner.capsword", nil)
		if removed then
			_capsword_listener_owned = false
		else
			all_stopped = false
			Logger.error(LOG, "CapsWord control listener removal failed: %s.", tostring(remove_err))
		end
	end
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
	if _capsword_led_timer then
		if cancel_scheduled_timer(_capsword_led_timer, "CapsWord LED timer") then
			_capsword_led_timer = nil
		else
			all_stopped = false
		end
	end
	if _capsword_idle_timer then
		if cancel_scheduled_timer(_capsword_idle_timer, "CapsWord inactivity timer") then
			_capsword_idle_timer = nil
		else
			all_stopped = false
		end
	end
	_capsword_last_activity_ns = 0
	for index = #_capsword_timer_cleanup_backlog, 1, -1 do
		if cancel_scheduled_timer(_capsword_timer_cleanup_backlog[index],
			"CapsWord timer backlog") then
			table.remove(_capsword_timer_cleanup_backlog, index)
		else
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
--- `defaults` always quotes that key (it holds a space) and quotes a value
--- only when it is not purely alphanumeric: `"KeyboardLayout Name" = ABC;`
--- but `"KeyboardLayout Name" = "Ergopti_v2_2_2_plus";`. The bare form used to
--- match nothing, so the poll never resolved an ABC or French layout.
--- @param raw string|nil The raw `defaults` output.
--- @return string|nil The layout name, or nil when absent.
local function parse_layout_name(raw)
	if type(raw) ~= "string" or raw == "" then return nil end
	return raw:match('"KeyboardLayout Name"%s*=%s*"([^"]+)"')
		or raw:match('"KeyboardLayout Name"%s*=%s*([%w]+)%s*;')
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

--- Fires the on_change callback with proper debouncing, updating both layout
--- names. A change seen only in the localised form leaves the HIToolbox
--- baseline to the next read, which adopts it without reporting it again.
--- @param on_change fun(layout_name: string)
--- @param layout_name string
--- @param watcher_gen integer Watcher generation that observed the change.
--- @param hitoolbox_name string|nil The new KeyboardLayout Name, when read.
local function fire_layout_change(on_change, layout_name, watcher_gen, hitoolbox_name)
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
		_last_known_layout = hitoolbox_name
		_last_known_cached_layout = read_current_layout_safe()
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

--- Releases the named broker subscription after a partial watcher start.
--- The generation is retired first so a native dispatcher retained by a failed
--- unsubscribe cannot invoke the callback from the rejected lifecycle.
--- @param reason string Acquisition failure reported to the file logger.
--- @return boolean released True only when no broker cleanup debt remains.
local function rollback_input_source_subscription(reason)
	_input_source_watcher_gen = _input_source_watcher_gen + 1
	local release_ok, released_or_err = pcall(
		InputSourceBroker.unsubscribe,
		INPUT_SOURCE_SUBSCRIBER_ID
	)
	if release_ok and released_or_err == true then
		_input_source_callback_owned = false
	else
		Logger.error(LOG,
			"%s; input-source broker cleanup remains pending: %s.",
			reason, tostring(released_or_err))
	end
	return not _input_source_callback_owned
end

--- Requests retirement without confusing a signal acknowledgement with exit.
--- SIGTERM acceptance leaves the native task and its GC pin owned until exit.
--- @param handle table Exact ShellRunner read handle.
--- @return boolean settled
--- @return any detail
local function retire_layout_read(handle)
	local function released()
		if _layout_poll_handle ~= handle then return end
		_layout_poll_handle = nil
		_layout_poll_pending = false
		_layout_poll_termination_pending = false
	end
	local settled_ok, settled = pcall(handle.isSettled)
	if settled_ok and settled == true then released(); return true end
	if not _layout_read_observed[handle] then
		local observed_ok, observed = pcall(handle.onSettled, released)
		if observed_ok and observed == true then _layout_read_observed[handle] = true end
	end
	local stopped, stop_result = pcall(handle.terminate)
	settled_ok, settled = pcall(handle.isSettled)
	if settled_ok and settled == true then released(); return true end
	if _layout_poll_handle == handle then
		_layout_poll_pending = true
		_layout_poll_termination_pending = true
	end
	return false, stopped and stop_result == true and "native exit pending" or stop_result
end

--- Retries the exact layout-read termination retained by a prior refusal.
--- @param reason string Stable cleanup context for diagnostics.
--- @return boolean settled True only when no termination debt remains.
local function retry_layout_read_termination(reason)
	if not _layout_poll_termination_pending then return true end
	local abandoned = _layout_poll_handle
	if abandoned then
		local settled, stop_result = retire_layout_read(abandoned)
		if not settled then
			Logger.error(LOG,
				"%s; retained layout read termination retry failed: %s.",
				reason, tostring(stop_result))
			return false
		end
	end
	_layout_poll_pending = false
	_layout_poll_termination_pending = false
	return true
end

--- Settles only orphaned cleanup owners before a watcher restart.
--- A live watcher still owns its poll timer, so duplicate starts remain refused.
--- @return boolean settled True only when the restart-specific debts cleared.
local function retry_input_source_cleanup_before_start()
	local settled = retry_layout_read_termination(
		"Input-source watcher restart recovery")
	local orphaned_subscription = _input_source_callback_owned
		and _layout_poll_timer == nil
		and _layout_poll_committed ~= true
	if orphaned_subscription
		and rollback_input_source_subscription(
			"Input-source watcher restart recovery") ~= true then
		settled = false
	end
	return settled
end

function M.start_input_source_watcher(on_change)
	Logger.trace(LOG, "Registering input source watcher…")

	-- A failed stop may leave any one of these exact native capabilities alive.
	-- Never overwrite its only retry handle merely because a sibling resource
	-- happened to stop successfully.
	if has_input_source_cleanup_debt()
		and (retry_input_source_cleanup_before_start() ~= true
			or has_input_source_cleanup_debt()) then
		Logger.warn(LOG, "start_input_source_watcher() refused while prior cleanup is unsettled.")
		return false
	end
	_input_source_watcher_gen = _input_source_watcher_gen + 1
	local watcher_gen = _input_source_watcher_gen

	-- Seed only the localised name without spawning: the first asynchronous
	-- read adopts the HIToolbox name after native watcher ownership commits.
	-- The two forms differ for an Ergopti layout ("Ergopti+" against
	-- "Ergopti_v2_2_2_plus"), and comparing them reported a layout change at
	-- the first poll of every boot, which fenced the boot's lease activation
	-- in flight (layout-name-forms).
	_last_known_layout = nil
	_notification_before_baseline = false
	_last_known_cached_layout = read_current_layout_safe()
	Logger.debug(LOG, "Initial layout: '%s'.", tostring(_last_known_cached_layout))

	local run_layout_refresh = nil
	local notification_before_refresh_ready = false

	-- Primary: one named subscriber behind the process-wide broker
	local installed_callback = function()
		if watcher_gen ~= _input_source_watcher_gen then return end
		Logger.debug(LOG, "Input source notification received — debouncing (%.0fms)…",
			INPUT_SOURCE_DEBOUNCE_SEC * 1000)
		if _last_known_layout == nil then _notification_before_baseline = true end
		if type(run_layout_refresh) ~= "function" then
			-- A hostile broker may deliver synchronously from subscribe(). Replay only
			-- after the poll timer and every cleanup owner have committed.
			notification_before_refresh_ready = true
			return
		end
		if run_layout_refresh("notification") ~= true then
			Logger.warn(LOG, "Input source notification could not start an asynchronous layout read.")
		end
	end
	-- Publish the cleanup obligation before crossing the adapter boundary: a
	-- subscriber installation may mutate the native slot and then throw.
	_input_source_callback_owned = true
	local subscribe_ok, subscribed_or_err = pcall(
		InputSourceBroker.subscribe,
		INPUT_SOURCE_SUBSCRIBER_ID,
		installed_callback
	)
	if not subscribe_ok or subscribed_or_err ~= true then
		rollback_input_source_subscription("Input source watcher registration failed")
		Logger.error(LOG, "Input source watcher registration failed at the shared broker.")
		return false
	end

	-- Fallback: poll HIToolbox every LAYOUT_POLL_SEC — catches layout changes that
	-- didn't trigger hs.keycodes.inputSourceChanged (Sequoia regression).
	run_layout_refresh = function(source)
		if watcher_gen ~= _input_source_watcher_gen then return false end
		local refresh_source = source == "notification" and "notification" or "poll"
		if not drain_scheduled_backlog(_layout_watchdog_cleanup_backlog,
			"Layout watchdog backlog") then
			Logger.error(LOG, "Layout poll blocked by prior watchdog cleanup debt.")
			return false
		end
		if _layout_poll_termination_pending then
			if retry_layout_read_termination("Layout poll retry") ~= true then return false end
		end
		-- Read HIToolbox ASYNCHRONOUSLY (off the main run loop). Skip if a read is
		-- already in flight so back-to-back ticks under load cannot pile up tasks.
		if _layout_poll_pending then return true end
		_layout_poll_pending = true
		-- Arm the watchdog alongside the guard so a read whose completion callback
		-- never fires still releases it and the next tick can retry. Scheduled via
		-- the TimerScheduler adapter (not raw hs.timer.doAfter) so this OS call is
		-- attributed to the adapter boundary.
		if _layout_poll_watchdog then
			if not cancel_scheduled_timer(_layout_poll_watchdog, "Superseded layout watchdog") then
				retain_cleanup_handle(_layout_watchdog_cleanup_backlog, _layout_poll_watchdog)
			end
			_layout_poll_watchdog = nil
		end
		local watchdog
		local callback_fired_before_return = false
		local watchdog_ok, watchdog_or_err, watchdog_committed = pcall(
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
					-- Retire the generation BEFORE terminating: terminate() only asks the
					-- OS to kill the process, and its exit callback still arrives later.
					-- Without this the abandoned read comes back to clear the NEXT
					-- read's handle and cancel its watchdog.
					_layout_read_generation = _layout_read_generation + 1
					if _layout_poll_handle then
						local stale = _layout_poll_handle
						local settled, stop_result = retire_layout_read(stale)
						if settled then
							Logger.warn(LOG, "Layout poll read timed out — terminated the read and released the guard so the next tick can retry.")
						else
							Logger.error(LOG,
								"Timed-out layout read termination failed; retaining the exact handle: %s.",
								tostring(stop_result))
						end
					end
				end
			end
		)
		watchdog = watchdog_ok and watchdog_or_err or nil
		if not watchdog_ok or watchdog_committed ~= true or type(watchdog) ~= "table"
			or watchdog.fired == true or callback_fired_before_return then
			_layout_poll_pending = false
			if type(watchdog) == "table"
				and not cancel_scheduled_timer(watchdog, "Rejected layout watchdog") then
				retain_cleanup_handle(_layout_watchdog_cleanup_backlog, watchdog)
			end
			Logger.error(LOG, "Layout poll watchdog could not be armed: %s.",
				tostring(watchdog_ok and "timer unavailable" or watchdog_or_err))
			return false
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
			if current and _last_known_layout == nil then
				-- The first HIToolbox name has nothing of its form to be compared with.
				-- It is adopted unless a notification arrived before it, or the
				-- localised name moved since the seed: either way the layout may have
				-- changed after the build read it, so a change is reported.
				local notified = refresh_source == "notification" or _notification_before_baseline
				_notification_before_baseline = false
				local cached = read_current_layout_safe()
				if notified or cached ~= _last_known_cached_layout then
					Logger.info(LOG, "Layout %s detected change before its baseline: '%s' → '%s'.",
						refresh_source, tostring(_last_known_cached_layout), current)
					fire_layout_change(on_change, current, watcher_gen, current)
				else
					_last_known_layout = current
					Logger.debug(LOG, "Layout baseline adopted from HIToolbox: '%s'.", current)
				end
			elseif current and current ~= _last_known_layout then
				Logger.info(LOG, "Layout %s detected change: '%s' → '%s'.",
					refresh_source,
					tostring(_last_known_layout), current)
				fire_layout_change(on_change, current, watcher_gen, current)
			elseif not current and refresh_source == "notification" then
				local cached = read_current_layout_safe()
				if cached and cached ~= _last_known_cached_layout then
					Logger.info(LOG, "Layout notification detected change: '%s' → '%s'.",
						tostring(_last_known_cached_layout), cached)
					fire_layout_change(on_change, cached, watcher_gen, nil)
				elseif not cached then
					Logger.warn(LOG,
						"Input source notification could not resolve a layout; waiting for poll recovery.")
				end
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
		return read_started == true
	end

	-- Keep construction and start separate. The combined constructor starts the
	-- timer before returning it, so a native start that mutates and then raises
	-- makes the exact live handle impossible to recover for rollback.
	local poll_candidate = nil
	local poll_ok, poll_or_err = pcall(hs.timer.new, LAYOUT_POLL_SEC, function()
		if _layout_poll_committed ~= true
			or _layout_poll_timer ~= poll_candidate then return end
		Logger.pcall(LOG, run_layout_refresh, "poll")
	end)
	local poll_type = type(poll_or_err)
	local methods_ok, start_method, stop_method = pcall(function()
		return poll_or_err and poll_or_err.start, poll_or_err and poll_or_err.stop
	end)
	if not poll_ok
		or (poll_type ~= "table" and poll_type ~= "userdata")
		or not methods_ok
		or type(start_method) ~= "function"
		or type(stop_method) ~= "function" then
		local failure = poll_ok and "timer unavailable" or tostring(poll_or_err)
		rollback_input_source_subscription("Layout poll timer acquisition failed")
		Logger.error(LOG, "Layout poll timer acquisition failed: %s.", failure)
		return false
	end
	poll_candidate = poll_or_err
	_layout_poll_timer = poll_candidate
	_layout_poll_committed = false
	local start_ok, started_or_err = pcall(start_method, poll_candidate)
	local state_started, state_detail = layout_poll_running_matches(poll_candidate, true)
	if not start_ok or started_or_err ~= poll_candidate or not state_started then
		-- Retire the callback before cleanup. If stop refuses, the retained exact
		-- timer may keep firing, but it cannot mutate state or start a layout read.
		_input_source_watcher_gen = _input_source_watcher_gen + 1
		_layout_poll_committed = false
		if stop_layout_poll_timer(poll_candidate, "Rejected layout poll timer") then
			if _layout_poll_timer == poll_candidate then _layout_poll_timer = nil end
		end
		-- Broker rollback is independent of timer rollback: one refusal must not
		-- strand the sibling capability acquired earlier in this transaction.
		rollback_input_source_subscription("Layout poll timer start failed")
		Logger.error(LOG, "Layout poll timer start failed; cleanup may remain pending: %s.",
			tostring(not start_ok and started_or_err
				or (started_or_err ~= poll_candidate and "start returned a foreign value")
				or state_detail))
		return false
	end
	_layout_poll_committed = true
	if notification_before_refresh_ready then
		notification_before_refresh_ready = false
		if run_layout_refresh("notification") ~= true then
			Logger.warn(LOG, "Deferred input source notification could not start a layout read.")
		end
	end

	Logger.done(LOG, "Input source watcher registered (poll every %.0fs).", LAYOUT_POLL_SEC)
	return true
end

--- Clears the hs.keycodes.inputSourceChanged callback, cancels the poll timer,
--- and cancels any pending debounced rebuild.
function M.stop_input_source_watcher()
	Logger.trace(LOG, "Stopping input source watcher…")
	_input_source_watcher_gen = _input_source_watcher_gen + 1
	_layout_poll_committed = false
	local all_stopped = true
	if _input_source_callback_owned then
		if InputSourceBroker.unsubscribe(INPUT_SOURCE_SUBSCRIBER_ID) ~= true then
			Logger.error(LOG, "Input-source broker cleanup failed; retained for retry.")
			all_stopped = false
		else
			_input_source_callback_owned = false
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
		if stop_layout_poll_timer(_layout_poll_timer, "Layout poll timer") then
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
		local settled, stop_result = retire_layout_read(handle)
		if not settled then
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
	if _app_switch_watcher then
		if _app_switch_watcher_active then return true end
		if not stop_native_watcher(_app_switch_watcher, "Retained app-switch watcher") then
			return false
		end
		_app_switch_watcher = nil
	end
	_app_switch_watcher_gen = _app_switch_watcher_gen + 1
	local watcher_gen = _app_switch_watcher_gen

	local created, watcher_or_err = pcall(hs.application.watcher.new, function(_name, event_type, app)
		if watcher_gen ~= _app_switch_watcher_gen or not _app_switch_watcher_active then return end
		if event_type ~= hs.application.watcher.activated then return end
		if not app then return end

		local bundle_id = app:bundleID()
		local app_name = app:name()
		if type(app_name) ~= "string" or app_name == "" then return end
		-- A display name can belong to several installed applications or clones.
		-- Ignore duplicate activation only while both recorded identities match.
		if app_name == _current_app_name and bundle_id == _current_bundle_id then return end

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
	if not stop_native_watcher(watcher, "App-switch watcher") then return false end
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
