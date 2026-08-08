--- modules/shortcuts/actions/system.lua

--- ==============================================================================
--- MODULE: Shortcuts — System Actions
--- DESCRIPTION:
--- Implements system-level shortcuts: keep-awake (mouse jiggler), pixel color
--- copy, interactive screenshot, instant window screenshot, volume control via
--- layer key + scroll wheel, mouse teleport, display mirror toggle, and mouse
--- spotlight (yellow ring indicator).
---
--- FEATURES & RATIONALE:
--- 1. Keep-Awake Jitter: Moves the mouse by small random offsets and calls
---    hs.caffeinate.declareUserActivity() so the OS considers the session active
---    without touching any power-management settings permanently.
--- 2. EventTap Factories: bind_* functions return a fake-hotkey object exposing
---    a :delete() method, letting the bindings registry manage all shortcut
---    types uniformly, whether hs.hotkey or hs.eventtap underneath.
--- 3. Display Mirror: Calls CGBeginDisplayConfiguration / CGConfigureDisplayMirrorOfDisplay
---    via an inline Python script, bypassing keyboard shortcuts entirely so mirroring
---    toggles reliably regardless of F-key mode or system preferences.
---
--- Sub-modules (merged into this table at load time):
---   * system_pixel.lua  — pixel color copy and screenshot helpers (section 3)
---   * system_mouse.lua  — mouse teleport, display mirror, emoji picker, spotlight (section 5)
--- ==============================================================================

local M = {}

local hs            = hs
local timer         = hs.timer
local eventtap      = hs.eventtap
local pasteboard    = hs.pasteboard
local notifications = require("infra.notifications")
local EventTapGuard = require("adapters.event_tap_guard")
local EventProvenance = require("adapters.event_provenance")
local KeyState      = require("adapters.key_state")
local ShellRunner   = require("adapters.shell_runner")
local Logger        = require("infra.logger")
local text_utils = require("infra.text_utils")
local Timings       = require("infra.timings")
local i18n          = require("infra.i18n")
local SyntheticInput = require("adapters.synthetic_input")

local LOG = "shortcuts.actions.system"

-- Absolute paths: the interactive layer must not inherit its binaries from PATH,
-- which differs between a login shell and the Hammerspoon process.
local MKDIR_BIN         = "/bin/mkdir"
local SCREENCAPTURE_BIN = "/usr/sbin/screencapture"

-- Explicit inter-key delay for simulated keystrokes. hs.eventtap.keyStroke()
-- defaults this argument to 200 000 us and implements it as a BLOCKING usleep on
-- the main run loop, so an omitted delay stalls the loop that services the typing
-- event tap — long enough for macOS to disable it (kCGEventTapDisabledByTimeout).
local KEYSTROKE_NO_DELAY_US = 0

local ok_gestures, gestures = pcall(require, "modules.gestures")
if not ok_gestures then gestures = nil end

local text_acts = require("modules.shortcuts.actions.text")





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

-- Physical key-code for the @ / # key (position-based, not character-based)
local KEYCODE_AT_HASH        = 10

local Keycodes               = require("infra.keycodes")

-- Keep-awake jitter parameters. The tick interval bounds + return delay come
-- from the shared cross-driver registry ([keep_awake]); the pixel offsets are
-- macOS-local (no AHK equivalent).
local AWAKE_TICK_MIN_SEC     = Timings.sec("keep_awake", "tick_min_ms")     -- Minimum interval between mouse-jitter ticks
local AWAKE_TICK_MAX_SEC     = Timings.sec("keep_awake", "tick_max_ms")     -- Maximum interval between mouse-jitter ticks
local AWAKE_JITTER_X         = 80   -- Max horizontal pixel offset per tick (visible but stays near origin)
local AWAKE_JITTER_Y         = 80   -- Max vertical pixel offset per tick (visible but stays near origin)
local AWAKE_RETURN_DELAY_SEC = Timings.sec("keep_awake", "return_delay_ms") -- Seconds to hold offset before returning to origin

-- No-op key code posted on every keep-awake tick to signal KEYBOARD activity.
-- Warping the cursor does NOT post a CGEvent, so it never resets the system HID
-- idle counter that presence-aware apps (Microsoft Teams) read — which is why
-- Teams went "absent" despite the visible jiggle. A real F18 key event resets
-- that counter; F18 types nothing, fires no shortcut, and the keymap engine
-- fast-exits it (FAST_EXIT_KEYCODES). This is the macOS analog of the AHK
-- driver's {VKFF} empty keystroke. Single source of truth: _shared/lua/keycodes
-- (F18_WAKE_OS), the same code the keymap reserves.
local KEEP_AWAKE_WAKE_KEY    = Keycodes.F18_WAKE_OS

-- Grace period after activation during which the auto-deactivation watcher
-- ignores ALL input. It must absorb three settle sources: the trigger keystroke's
-- own key/flag events, the programmatic 1 px origin nudge, and — crucially — a
-- rapid second Ctrl+M (toggle OFF) together with the incidental touchpad brush a
-- laptop thumb makes while pressing it. Too short and that brush silently
-- auto-disables keep-awake, so the next Ctrl+M re-enables instead of disabling.
local AWAKE_ACTIVATION_GRACE_SEC = 1.0

local awake_timer      = nil
local awake_active     = false
local awake_origin_pos = nil
-- Timestamp (seconds since epoch) when keep-awake was last toggled ON; used
-- to log the duration as an "awake" passive period on toggle OFF so the
-- dashboard can subtract it from focus stats when the toggle is disabled.
local awake_started_at = nil
-- Name of the focused app at the moment keep-awake was enabled. The
-- jiggler keeps this app at the foreground for the duration, so the
-- dashboard can credit the awake_ms back to that app on toggle OFF.
local awake_focused_app = nil
-- Eventtap that watches for any real user input while keep-awake is active;
-- stops the jiggler immediately so the cursor doesn't fight the user.
local awake_input_watcher = nil
-- Handle returned by hs.alert.show so the persistent "active" banner can be
-- dismissed precisely when keep-awake is disabled, without closing other alerts.
local awake_alert_id = nil
-- Whether a keep-awake banner is currently on screen. Tracked separately from
-- awake_alert_id because the id is absent on builds where the show call returns
-- nil — and the no-handle teardown below is a screen-wide sweep, so it must be
-- reachable ONLY when one of our banners is genuinely up.
local awake_alert_shown = false

-- Closes the persistent keep-awake banner. The previous closeAll(0) assumed our
-- banner was the only long-lived alert on screen, which is not ours to assume:
-- it dismissed EVERY visible alert, including ones other modules had just posted
-- (shortcuts-awake-closes-all-alerts). Whenever the show call handed us a handle
-- we therefore close that one precisely and leave every other alert alone.
-- The closeAll fallback survives for the no-handle case only: some Hammerspoon
-- builds return nil instead of an alert id, and without a handle closeSpecific
-- cannot reach our banner — it would stay on screen forever, which is strictly
-- worse than the collateral dismissal. That path is the one guarded by the
-- "closeAll even when the alert id is nil" regression test, and it is gated on
-- awake_alert_shown so a call made when no banner of ours is up (the defensive
-- clear on the activation path) sweeps nothing.
-- Pending "return the cursor to where it was" timer. Declared above every closure
-- that touches it: a local declared below one binds the nil global instead.
local _awake_return_timer = nil

local function close_awake_alert()
	local id    = awake_alert_id
	local shown = awake_alert_shown
	awake_alert_id    = nil
	awake_alert_shown = false
	if id ~= nil then
		pcall(hs.alert.closeSpecific, id, 0)
		return
	end
	if shown then
		pcall(hs.alert.closeAll, 0)
	end
end

-- Forward declaration required because schedule_awake_tick calls itself recursively
local schedule_awake_tick

-- AX selection cache for the wrap-text eventtap: read_ax_selection() is two
-- synchronous cross-process Accessibility calls, and the eventtap fires on
-- EVERY keystroke matching a wrap symbol with no caching at all — a slow AX
-- call here risks kCGEventTapDisabledByTimeout. Mirrors infra/vscode_bridge.lua's
-- get_editor_ax_frame() TTL-cache pattern (shortcuts-wrap-ax-uncached).
local _wrap_ax_selection_cache = nil
local _wrap_ax_selection_ts    = 0
-- Separate validity flag so a nil selection (nothing selected, or an app that hides
-- AXSelectedText) is cached like any other result. Keying freshness on the value
-- itself never cached a negative — see read_wrap_ax_selection_cached.
local _wrap_ax_selection_valid = false
local WRAP_AX_SELECTION_TTL_SEC = 0.2


--- Applies the exact-provenance gate shared by every input tap in this module.
--- Owned output is never a user command. An unreadable tag is also non-authoritative,
--- but still claims and returns the older-output fence so no queued action is lost.
--- @param event userdata|table Quartz event.
--- @param consumer_id string Stable provenance consumer identifier.
--- @return boolean physical True only for an explicitly foreign event.
--- @return table|nil fence_events Older callback-return events to hand downstream.
local function classify_physical_event(event, consumer_id)
	local metadata, status, fence = EventProvenance.classify_with_fence(event, consumer_id)
	local fence_events = fence and fence.events or nil
	if metadata or status == EventProvenance.STATUS_UNREADABLE then
		return false, fence_events
	end
	return status == EventProvenance.STATUS_FOREIGN, fence_events
end


--- Normalises the two-value Hammerspoon eventtap return contract.
--- @param consume boolean Whether the original event is suppressed.
--- @param fence_events table|nil Older synthetic payload returned before it.
--- @return boolean consume
--- @return table|nil fence_events
local function finish_tap(consume, fence_events)
	return consume == true, fence_events
end

--- Posts a single no-op F18 key event (down + up) to register KEYBOARD activity
--- with the OS and with presence-aware apps. Exposed as M._emit_activity_keystroke
--- so the regression test can assert it fires. The auto-deactivation watcher
--- ignores only its exact provenance tag so a physical F18 remains user activity.
local function emit_activity_keystroke()
	-- This is an OS heartbeat, not a user-visible cursor/text action. Letting the
	-- adapter create its default `action` transaction advanced the process-wide
	-- action epoch on every tick, clearing the typing buffer and quarantining LLM
	-- predictions while the user was idle. An explicit replacement transaction
	-- keeps the pair tagged without publishing an observable action boundary.
	local transaction = nil
	local ok, err = xpcall(function()
		transaction = SyntheticInput.begin("shortcuts.keep_awake", "replacement")
		assert(SyntheticInput.emit_key_stroke(
			{}, KEEP_AWAKE_WAKE_KEY, KEYSTROKE_NO_DELAY_US, transaction),
			"F18 activity pair could not be queued")
		assert(SyntheticInput.seal(transaction),
			"F18 activity transaction could not be sealed")
	end, debug.traceback)
	if ok then return true end
	if transaction then pcall(SyntheticInput.cancel, transaction) end
	Logger.error(LOG, "Keep-awake F18 activity signal failed - %s.", tostring(err))
	return false
end
M._emit_activity_keystroke = emit_activity_keystroke





-- ============================================
-- ============================================
-- ======= 2/ Keep-Awake Implementation =======
-- ============================================
-- ============================================

--- Schedules the next keep-awake tick at a random interval.
--- Each tick moves the mouse slightly around the recorded origin, then returns.
schedule_awake_tick = function()
	if not awake_active then return end

	if awake_timer and type(awake_timer.stop) == "function" then
		pcall(function() awake_timer:stop() end)
		awake_timer = nil
	end

	-- math.random(m, n) requires integer bounds in Lua 5.4; the tick bounds come from
	-- Timings.sec() which returns floats, so use the float-safe uniform form instead.
	local span = AWAKE_TICK_MAX_SEC - AWAKE_TICK_MIN_SEC
	local interval = AWAKE_TICK_MIN_SEC + math.random() * span
	awake_timer = timer.doAfter(interval, function()
		if not awake_active then return end

		local origin = awake_origin_pos
		if not origin then
			local ok, p = pcall(hs.mouse.absolutePosition)
			if ok and p then origin = {x = p.x, y = p.y} end
		end

		if origin then
			local ox = math.random(-AWAKE_JITTER_X, AWAKE_JITTER_X)
			local oy = math.random(-AWAKE_JITTER_Y, AWAKE_JITTER_Y)
			local tx = origin.x + ox
			local ty = origin.y + oy

			-- Clamp position to the current screen boundaries
			local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
			if screen and type(screen.frame) == "function" then
				local f = screen:frame()
				tx = math.max(f.x, math.min(f.x + f.w - 1, tx))
				ty = math.max(f.y, math.min(f.y + f.h - 1, ty))
			end

			pcall(hs.mouse.absolutePosition, {x = tx, y = ty})

			-- Handle retained so switching keep-awake OFF can cancel it. Without
			-- that, the cursor was still teleported back to its remembered origin
			-- up to AWAKE_RETURN_DELAY_SEC after the user turned the feature off —
			-- a pointer that moves on its own once the feature is disabled.
			if _awake_return_timer then pcall(function() _awake_return_timer:stop() end) end
			_awake_return_timer = timer.doAfter(AWAKE_RETURN_DELAY_SEC, function()
				_awake_return_timer = nil
				if origin then pcall(hs.mouse.absolutePosition, {x = origin.x, y = origin.y}) end
			end)

			-- Declare user activity so the OS resets its display-idle / power assertion
			pcall(hs.caffeinate.declareUserActivity)
		end

		-- Post the F18 no-op keystroke EVERY tick (independent of mouse origin): it
		-- is the only thing here that resets the HID idle counter Teams reads, so it
		-- is what actually keeps presence "available". declareUserActivity above only
		-- covers display sleep, not app-level presence.
		emit_activity_keystroke()

		schedule_awake_tick()
	end)
end

--- Stops the input-activity watcher without touching keep-awake state.
local function stop_awake_input_watcher()
	if awake_input_watcher then
		pcall(function() awake_input_watcher:stop() end)
		awake_input_watcher = nil
	end
end


--- Auto-disables keep-awake after the observing eventtap has returned.
--- The activation token prevents an old queued callback from disabling a newer
--- keep-awake session after a rapid OFF -> ON cycle.
--- @param expected_started_at number|nil Activation timestamp captured by the tap.
local function auto_disable_awake(expected_started_at)
	if not awake_active or awake_started_at ~= expected_started_at then return end

	awake_active = false
	stop_awake_input_watcher()

	if awake_timer and type(awake_timer.stop) == "function" then
		pcall(function() awake_timer:stop() end)
		awake_timer = nil
	end

	close_awake_alert()

	-- Log duration so the dashboard accounts for the keep-awake period.
	if awake_started_at then
		local dur_ms = math.floor((hs.timer.secondsSinceEpoch() - awake_started_at) * 1000)
		if dur_ms > 0 then
			local ok_lm, log_manager = pcall(require, "modules.keylogger.log_manager")
			if ok_lm and log_manager then
				if type(log_manager.log_passive_period) == "function" then
					pcall(log_manager.log_passive_period, "awake", dur_ms)
				end
				if awake_focused_app and type(log_manager.tag_awake_focus) == "function" then
					pcall(log_manager.tag_awake_focus, awake_focused_app, dur_ms)
				end
			end
		end
		awake_started_at  = nil
		awake_focused_app = nil
	end

	Logger.info(LOG, "Keep-awake auto-disabled — user activity detected.")
end

--- Toggles keep-awake mode on or off.
--- When active, jiggles the mouse periodically to prevent the display from sleeping.
function M.toggle_awake()
	if awake_active then
		awake_active = false

		stop_awake_input_watcher()

		if awake_timer and type(awake_timer.stop) == "function" then
			pcall(function() awake_timer:stop() end)
			awake_timer = nil
		end

		-- Cancel the pending cursor return too. Stopping only the tick timer left
		-- a scheduled "put the pointer back" firing up to AWAKE_RETURN_DELAY_SEC
		-- after the user switched the feature off — a cursor that moves by itself
		-- once nothing is supposed to be moving it.
		if _awake_return_timer then
			pcall(function() _awake_return_timer:stop() end)
			_awake_return_timer = nil
		end

		-- Log the keep-awake duration as a special passive period AND tag the
		-- focused app so the dashboard can subtract it from per-app stats
		-- when the user opted out of counting keep-awake time.
		if awake_started_at then
			local dur_ms = math.floor((hs.timer.secondsSinceEpoch() - awake_started_at) * 1000)
			if dur_ms > 0 then
				local ok_lm, log_manager = pcall(require, "modules.keylogger.log_manager")
				if ok_lm and log_manager then
					if type(log_manager.log_passive_period) == "function" then
						pcall(log_manager.log_passive_period, "awake", dur_ms)
					end
					if awake_focused_app and type(log_manager.tag_awake_focus) == "function" then
						pcall(log_manager.tag_awake_focus, awake_focused_app, dur_ms)
					end
				end
			end
			awake_started_at  = nil
			awake_focused_app = nil
		end

		Logger.info(LOG, "Keep-awake disabled.")
		-- Close the persistent banner first, THEN show the transient "off" toast so
		-- the close cannot swallow the toast we just displayed (it still would on
		-- the no-handle path, which falls back to closeAll).
		close_awake_alert()
		pcall(hs.alert.show, i18n.get("shortcuts.keep_awake_off"), 2.0)
	else
		awake_active = true
		awake_started_at = hs.timer.secondsSinceEpoch()
		-- Capture the focused app at toggle-on so we can credit the keep-awake
		-- duration back to it on toggle-off.
		local _ok_app, _front = pcall(hs.application.frontmostApplication)
		if _ok_app and _front and type(_front.name) == "function" then
			awake_focused_app = _front:name()
		end
		math.randomseed(os.time())

		close_awake_alert()
		local _ok_alert, _alert_id = pcall(hs.alert.show, i18n.get("shortcuts.keep_awake_on"), math.huge)
		if _ok_alert then
			awake_alert_id    = _alert_id
			-- Record that a banner is up even when the build gave us no id, so the
			-- teardown can still reach it via the no-handle fallback.
			awake_alert_shown = true
		end

		-- Record the current mouse position as the jitter origin
		local ok_pos, pos = pcall(hs.mouse.absolutePosition)
		if ok_pos and pos then
			awake_origin_pos = {x = pos.x, y = pos.y}

			-- Move 1 px to immediately register OS activity without visible displacement
			local dx = (math.random(0, 1) == 0) and -1 or 1
			pcall(hs.mouse.absolutePosition, {x = pos.x + dx, y = pos.y})
		end

		-- Watch for any real keyboard or touchpad activity (key press, scroll,
		-- swipe, tap, pinch, rotate...). We cut silently (no alert) since the user
		-- is clearly back — the visual noise would be worse than the keep-awake itself.
		local ev = eventtap.event.types
		local watch_types = {
			ev.scrollWheel, ev.leftMouseDown, ev.rightMouseDown, ev.otherMouseDown,
			ev.leftMouseUp, ev.rightMouseUp, ev.otherMouseUp,
			ev.mouseMoved, ev.keyDown
		}
		-- Touchpad gesture event types — some may be absent on older macOS builds
		for _, name in ipairs({ "gesture", "beginGesture", "endGesture", "swipe", "magnify", "rotate", "directTouch", "smartMagnify" }) do
			if ev[name] then
				table.insert(watch_types, ev[name])
			end
		end
		awake_input_watcher = eventtap.new(watch_types, function(_ev)
			if EventTapGuard.handle_disabled(_ev, awake_input_watcher, "shortcuts.keep_awake") then return false end
			local is_physical, fence_events = classify_physical_event(
				_ev, "shortcuts.keep_awake")
			if not is_physical or not awake_active then
				return finish_tap(false, fence_events)
			end

			-- Ignore events within the activation grace window so the trigger
			-- keystroke, the origin nudge, and a rapid second Ctrl+M (with the
			-- touchpad brush it carries) never instantly deactivate keep-awake.
			if awake_started_at and hs.timer.secondsSinceEpoch() - awake_started_at < AWAKE_ACTIVATION_GRACE_SEC then
				return finish_tap(false, fence_events)
			end

			-- Local must NOT be named `type`: that would shadow the `type()` builtin
			-- in the deferred teardown (type(awake_timer.stop)), turning it into a
			-- number and crashing before the banner is ever closed.
			local ok_type, ev_type = pcall(_ev.getType, _ev)
			if not ok_type then return finish_tap(false, fence_events) end
			-- Ignore key presses with modifiers to prevent the trigger shortcut
			-- from instantly deactivating the keep-awake mode.
			if ev_type == ev.keyDown then
				-- Exact ownership above, never an F18 keycode heuristic, distinguishes
				-- our heartbeat from a real extended-keyboard F18 press.
				local ok_flags, flags = pcall(_ev.getFlags, _ev)
				if not ok_flags or type(flags) ~= "table" then
					return finish_tap(false, fence_events)
				end
				if flags.cmd or flags.alt or flags.ctrl then
					return finish_tap(false, fence_events)
				end
			end
			-- If it's a mouse movement, only deactivate if it moved beyond the jitter area
			if ev_type == ev.mouseMoved and awake_origin_pos then
				local ok_pos, pos = pcall(_ev.location, _ev)
				if not ok_pos or type(pos) ~= "table"
					or type(pos.x) ~= "number" or type(pos.y) ~= "number" then
					return finish_tap(false, fence_events)
				end
				if math.abs(pos.x - awake_origin_pos.x) <= AWAKE_JITTER_X and
				   math.abs(pos.y - awake_origin_pos.y) <= AWAKE_JITTER_Y then
					return finish_tap(false, fence_events)
				end
			end

			-- State teardown, keylogger I/O and logging all run after this callback has
			-- handed Quartz every older fence event and the physical event itself.
			SyntheticInput.defer_after_callback(
				"keep-awake auto-deactivation", auto_disable_awake, awake_started_at)
			return finish_tap(false, fence_events)
		end)
		-- Start immediately so keyboard, scroll, gesture and click detection are
		-- all live as soon as activation returns to the run loop.
		if awake_active and awake_input_watcher then
			pcall(function() awake_input_watcher:start() end)
		end

		schedule_awake_tick()
		Logger.info(LOG, "Keep-awake enabled.")
	end
end

--- Stops keep-awake cleanly; called when the bindings module shuts down.
function M.stop_awake()
	awake_active = false

	stop_awake_input_watcher()

	if awake_timer and type(awake_timer.stop) == "function" then
		pcall(function() awake_timer:stop() end)
		awake_timer = nil
	end

	close_awake_alert()
end

--- Toggles the hardware CapsLock state through Hammerspoon's HID API.
--- @return boolean|nil New CapsLock state, or nil when the HID call failed.
function M.toggle_capslock()
	-- CapsLock is delivered as flagsChanged on macOS. A newKeyEvent down/up pair
	-- reports no construction error but does not change the lock state or LED.
	local state, err = KeyState.toggle_capslock()
	if state == nil then
		Logger.error(LOG, "CapsLock toggle failed - %s.", tostring(err))
		return nil
	end
	Logger.debug(LOG, "CapsLock toggled — now %s.", state and "ON" or "OFF")
	return state
end





-- =============================================
-- =============================================
-- ======= 3/ EventTap Factory Functions =======
-- =============================================
-- =============================================

--- Wraps an already-started eventtap in a fake-hotkey object with a :delete() method.
--- This lets the bindings registry treat eventtaps and hs.hotkeys uniformly.
--- @param tap userdata The hs.eventtap to wrap (must already be started).
--- @return table Fake-hotkey compatible object.
local function wrap_tap(tap)
	return {
		delete = function()
			if tap and type(tap.stop) == "function" then
				pcall(function() tap:stop() end)
			end
		end
	}
end


--- Captures the frontmost window outside the keyboard eventtap callback.
--- The delayed lookup is intentional: any action-epoch fence returned by the tap
--- must reach the application before the target window is resolved.
local function capture_frontmost_window()
	local ok, w = pcall(hs.window.frontmostWindow)
	if not ok or not w then
		notifications.notify(i18n.get("shortcuts.no_active_window"), nil, "warning")
		return
	end

	local ok_id, id = pcall(w.id, w)
	if not ok_id or not id then
		notifications.notify(i18n.get("shortcuts.no_active_window"), nil, "warning")
		return
	end
	local home = os.getenv("HOME") or "~"
	local dir  = home .. "/Pictures/screenshots"
	local filename = string.format("%s/screenshot_%s.png", dir, os.date("%Y_%m_%d_%Hh_%Mmin_%Ss"))
	-- mkdir then screencapture, chained through the completion callback: the
	-- directory has to exist before the capture runs. Both are asynchronous.
	ShellRunner.spawn(MKDIR_BIN, { "-p", dir }, function()
		ShellRunner.spawn(SCREENCAPTURE_BIN, { "-l", tostring(id), filename }, function(exit_code)
			if exit_code == 0 then
				notifications.notify(string.format(i18n.get("shortcuts.saved"), filename), nil, "success")
				return
			end
			Logger.warn(LOG, "screencapture -l exited with code %s — no file written.",
				tostring(exit_code))
			notifications.notify(i18n.get("shortcuts.screenshot_failed"), nil, "error")
		end).start()
	end).start()
end

--- Captures the frontmost window on the physical @/# key (key-code 10).
--- Uses a raw keyDown tap so the shortcut fires before macOS generates characters.
--- @return table Fake-hotkey object with :delete().
function M.bind_instant_screenshot()
	local tap
	tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
		if EventTapGuard.handle_disabled(e, tap, "shortcuts.at_hash") then return false end
		local is_physical, fence_events = classify_physical_event(
			e, "shortcuts.at_hash")
		if not is_physical then return finish_tap(false, fence_events) end

		local ok_key, keycode = pcall(e.getKeyCode, e)
		if not ok_key or keycode ~= KEYCODE_AT_HASH then
			return finish_tap(false, fence_events)
		end
		local ok_flags, flags = pcall(e.getFlags, e)
		if not ok_flags or type(flags) ~= "table"
			or flags.cmd or flags.alt or flags.ctrl or flags.shift then
			return finish_tap(false, fence_events)
		end

		local scheduled = SyntheticInput.defer_after_callback(
			"instant screenshot", capture_frontmost_window)
		return finish_tap(scheduled, fence_events)
	end)
	tap:start()
	return wrap_tap(tap)
end

--- Maps F19 + scroll wheel to system volume up/down.
--- F19 is the physical "layer" key; holding it while scrolling bypasses page scroll.
--- @return table Fake-hotkey object with :delete().
function M.bind_layer_scroll()
	local layer_held  = false
	local f19_keycode = Keycodes.F19_VOLUME_SCROLL_MODIFIER

	local key_tap
	key_tap = hs.eventtap.new(
		{hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp},
		function(event)
			if EventTapGuard.handle_disabled(event, key_tap, "shortcuts.f19_layer") then return false end
			local is_physical, fence_events = classify_physical_event(
				event, "shortcuts.f19_layer")
			if not is_physical then return finish_tap(false, fence_events) end

			local ok_key, keycode = pcall(event.getKeyCode, event)
			if not ok_key or keycode ~= f19_keycode then
				return finish_tap(false, fence_events)
			end
			local ok_type, event_type = pcall(event.getType, event)
			if not ok_type then return finish_tap(false, fence_events) end
			local should_hold = event_type == hs.eventtap.event.types.keyDown
			if not should_hold and event_type ~= hs.eventtap.event.types.keyUp then
				return finish_tap(false, fence_events)
			end

			-- This O(1) state write must be visible before the first following scroll;
			-- deferring it creates a down -> scroll race where the first notch leaks to
			-- the application. Only gesture cleanup is deferred off the HID callback.
			layer_held = should_hold
			if should_hold then
				SyntheticInput.defer_after_callback("F19 gesture cleanup", function()
					if gestures and type(gestures.isRightClickHeld) == "function"
						and gestures.isRightClickHeld() then
						pcall(function() gestures.forceCleanup() end)
					end
				end)
			end
			return finish_tap(false, fence_events)
		end
	)

	local scroll_tap
	scroll_tap = hs.eventtap.new({hs.eventtap.event.types.scrollWheel}, function(event)
		if EventTapGuard.handle_disabled(event, scroll_tap, "shortcuts.f19_scroll") then return false end
		local is_physical, fence_events = classify_physical_event(
			event, "shortcuts.f19_scroll")
		if not is_physical or not layer_held then
			return finish_tap(false, fence_events)
		end

		local ok_delta, delta = pcall(event.getProperty, event,
			hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)
		-- A zero delta is a scroll-PHASE event (phase began / phase ended / momentum
		-- ended), which macOS brackets every gesture with — not actual movement.
		-- Falling through would classify it as "down" (delta > 0 is false) while
		-- math.max(1, …) manufactures a real repetition, so every upward scroll ended
		-- one or more notches LOWER than it started (shortcuts-layer-scroll-zero-delta).
		-- Returning false also lets the phase event pass through instead of consuming it.
		if not ok_delta or type(delta) ~= "number" or delta == 0 then
			return finish_tap(false, fence_events)
		end

		local key  = delta > 0 and "SOUND_UP" or "SOUND_DOWN"
		local reps = math.max(1, math.floor(math.abs(delta)))
		local scheduled = SyntheticInput.defer_after_callback("F19 volume scroll", function()
			if gestures and type(gestures.isRightClickHeld) == "function"
				and gestures.isRightClickHeld() then
				pcall(function() gestures.forceCleanup() end)
			end
			-- NX system-defined media events are not keyDown/keyUp events, so they do
			-- not enter keymap/keylogger keyboard callbacks and stay native here.
			for _ = 1, reps do
				hs.eventtap.event.newSystemKeyEvent(key, true):post()
				hs.eventtap.event.newSystemKeyEvent(key, false):post()
			end
		end)
		return finish_tap(scheduled, fence_events)
	end)

	pcall(function() key_tap:start() end)
	pcall(function() scroll_tap:start() end)

	return {
		delete = function()
			if key_tap    and type(key_tap.stop)    == "function" then pcall(function() key_tap:stop() end) end
			if scroll_tap and type(scroll_tap.stop) == "function" then pcall(function() scroll_tap:stop() end) end
		end
	}
end

--- Intercepts Cmd+star / Cmd+* and re-fires as Cmd+S, preserving any additional modifiers.
--- hs.hotkey.bind cannot reliably intercept star (Shift+8 on some layouts) because the
--- OS assigns the character after modifier processing; a raw tap fires first.
--- @param on_trigger function|nil Called as on_trigger(label, app_name) for shortcut logging.
--- @return table Fake-hotkey object with :delete().
function M.bind_cmd_star(on_trigger)
	local tap
	tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
		if EventTapGuard.handle_disabled(e, tap, "shortcuts.cmd_star") then return false end
		local is_physical, fence_events = classify_physical_event(
			e, "shortcuts.cmd_star")
		if not is_physical then return finish_tap(false, fence_events) end

		local ok_flags, flags = pcall(e.getFlags, e)
		if not ok_flags or type(flags) ~= "table" or not flags.cmd then
			return finish_tap(false, fence_events)
		end

		local ok, ch = pcall(function() return e:getCharacters() end)
		if not ok or not ch then return finish_tap(false, fence_events) end
		if ch ~= "\xe2\x98\x85" and ch ~= "*" and ch ~= "\xe2\x9c\xb1" then
			return finish_tap(false, fence_events)
		end

		-- Build the modifier list to re-fire the keystroke faithfully
		local mods = {}
		if flags.cmd   then table.insert(mods, "cmd")   end
		if flags.shift then table.insert(mods, "shift") end
		if flags.alt   then table.insert(mods, "alt")   end
		if flags.ctrl  then table.insert(mods, "ctrl")  end

		-- Preserve only scalar flag state across the callback boundary; Quartz's
		-- event userdata is not retained or dereferenced by the deferred action.
		local flag_snapshot = {
			cmd = flags.cmd == true, ctrl = flags.ctrl == true,
			alt = flags.alt == true, shift = flags.shift == true,
		}
		local scheduled = SyntheticInput.defer_after_callback("Cmd-star action", function()
			-- Queue the user-visible output first. Application lookup and shortcut
			-- telemetry must never delay the replacement keystroke.
			SyntheticInput.emit_key_stroke(mods, "s", KEYSTROKE_NO_DELAY_US)
			if type(on_trigger) ~= "function" then return end

			local parts  = {}
			local order  = {"cmd", "ctrl", "alt", "shift"}
			local labels = {cmd = "Cmd", ctrl = "Ctrl", alt = "Alt", shift = "Shift"}
			for _, m in ipairs(order) do
				if flag_snapshot[m] then table.insert(parts, labels[m]) end
			end
			table.insert(parts, "S")

			local ok_app, app = pcall(hs.application.frontmostApplication)
			local app_name = nil
			if ok_app and app then
				local title_method = type(app.title) == "function" and app.title
					or (type(app.name) == "function" and app.name or nil)
				if title_method then
					local ok_title, title = pcall(title_method, app)
					if ok_title then app_name = title end
				end
			end
			if not app_name or app_name == "" then
				local ok_win, win = pcall(hs.window.focusedWindow)
				local ok_wa, wa = false, nil
				if ok_win and win and type(win.application) == "function" then
					ok_wa, wa = pcall(win.application, win)
				end
				if ok_wa and wa then
					local title_method = type(wa.title) == "function" and wa.title
						or (type(wa.name) == "function" and wa.name or nil)
					if title_method then
						local ok_title, title = pcall(title_method, wa)
						if ok_title then app_name = title end
					end
				end
				if not app_name or app_name == "" then app_name = "Unknown" end
			end
			pcall(on_trigger, table.concat(parts, "+"), app_name)
		end)
		return finish_tap(scheduled, fence_events)
	end)
	tap:start()
	return wrap_tap(tap)
end




--- Pure decision for the wrap eventtap, extracted so the two hard-won rules can
--- be unit-tested without synthesising key events.
--- Returns "wrap" when the eventtap must SUPPRESS the keystroke and wrap the
--- selection, or "passthrough" when it must return false so the OS types the
--- symbol itself (and never swallow it).
--- The rules:
---   1. Alt (Option) must NOT block wrapping — on the Ergopti layout the wrap
---      symbols live on the AltGr layer and carry the alt flag; only Cmd/Ctrl are
---      real shortcuts.
---   2. When no selection is readable (nothing selected, or an app such as VS Code
---      that does not expose AXSelectedText), pass the symbol through rather than
---      suppressing it.
--- @param flags table Modifier flags from the keyDown event (cmd/ctrl/alt/...).
--- @param ch string The character the keystroke produced.
--- @param pairs_tbl table The active {[char]={left,right}} wrap table.
--- @param has_selection boolean Whether a non-empty selection was readable.
--- @return string "wrap" or "passthrough".
function M.wrap_event_decision(flags, ch, pairs_tbl, has_selection)
	flags = type(flags) == "table" and flags or {}
	if flags.cmd or flags.ctrl then return "passthrough" end
	if type(ch) ~= "string" or ch == "" then return "passthrough" end
	if type(pairs_tbl) ~= "table" or pairs_tbl[ch] == nil then return "passthrough" end
	if not has_selection then return "passthrough" end
	return "wrap"
end

--- Reads the current AX selection with a short-lived cache, mirroring
--- infra/vscode_bridge.lua's get_editor_ax_frame(). read_ax_selection() performs
--- two synchronous cross-process Accessibility calls; without caching, a run of
--- rapid wrap-symbol keystrokes (e.g. a held key, or fast typing that repeats a
--- wrap char) would each pay that cost inline on the CGEventTap thread, risking
--- kCGEventTapDisabledByTimeout (shortcuts-wrap-ax-uncached).
--- @return string|nil The selected text, or nil when unavailable.
local function read_wrap_ax_selection_cached()
	local now = hs.timer.secondsSinceEpoch()
	-- Freshness is keyed on a separate validity flag, NOT on the cached value.
	-- `_wrap_ax_selection_cache ~= nil` made a NEGATIVE result uncacheable, and nil
	-- is the common result: nothing selected, or an app that hides AXSelectedText
	-- (VS Code / Electron, where it is nil every time). Every wrap-symbol keystroke
	-- therefore paid both synchronous cross-process AX calls inline on the
	-- CGEventTap thread — precisely the cost this cache exists to avoid. Same defect
	-- and same fix as infra/vscode_bridge.lua's _ax_frame_valid (3e403b254).
	if _wrap_ax_selection_valid and (now - _wrap_ax_selection_ts) < WRAP_AX_SELECTION_TTL_SEC then
		return _wrap_ax_selection_cache
	end
	local sel = text_acts.read_ax_selection()
	_wrap_ax_selection_cache = sel
	_wrap_ax_selection_ts    = now
	_wrap_ax_selection_valid = true
	return sel
end

--- Records that the cached selection has been consumed by a wrap, WITHOUT
--- discarding the cache entry.
---
--- wrap_selection replaces the selection it was given, so the cached value is
--- stale the instant a wrap fires. Within the TTL the next wrap key then re-wrapped
--- text that was no longer selected: the keystroke was swallowed and the previous
--- selection duplicated. Marking it as a fresh NEGATIVE (rather than clearing the
--- validity flag) is deliberate — clearing would re-pay both AX calls on every
--- subsequent wrap key and undo the negative-caching fix this file just received.
local function mark_wrap_selection_consumed()
	_wrap_ax_selection_cache = nil
	_wrap_ax_selection_ts    = hs.timer.secondsSinceEpoch()
	_wrap_ax_selection_valid = true
end

--- Starts a keyDown eventtap that wraps the current text selection with the typed symbol.
--- When no text is selected (or the focused app hides its selection), the key event
--- is passed through unchanged so the symbol is never swallowed.
--- @param get_wrap_pairs function|nil Callback returning the live {[char]={left,right}} table.
---   When nil, falls back to text_acts.WRAP_PAIRS (the full built-in catalogue).
--- @return table Fake-hotkey object with :delete().
function M.bind_wrap_text_if_selected(get_wrap_pairs)
	local tap
	tap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
		if EventTapGuard.handle_disabled(e, tap, "shortcuts.wrap_text") then return false end
		local is_physical, fence_events = classify_physical_event(
			e, "shortcuts.wrap_text")
		if not is_physical then return finish_tap(false, fence_events) end
		-- AX still describes the pre-return application while older callback events
		-- have not reached Quartz. Fail open for this rare ordering branch: the real
		-- symbol reaches keymap/app after the fence instead of wrapping stale text.
		if type(fence_events) == "table" and #fence_events > 0 then
			return finish_tap(false, fence_events)
		end

		local ok_flags, flags = pcall(e.getFlags, e)
		if not ok_flags or type(flags) ~= "table" then
			return finish_tap(false, fence_events)
		end
		-- Fast path: Cmd/Ctrl are real shortcuts — bail before any AX probe. Alt is
		-- intentionally allowed through (Ergopti wrap symbols are on the AltGr layer).
		if flags.cmd or flags.ctrl then return finish_tap(false, fence_events) end

		local ok_ch, ch = pcall(function() return e:getCharacters() end)
		if not ok_ch or type(ch) ~= "string" or ch == "" then
			return finish_tap(false, fence_events)
		end

		-- Resolve the live symbol table on every keystroke so menu changes take effect immediately
		local pairs_tbl = type(get_wrap_pairs) == "function"
			and get_wrap_pairs() or text_acts.WRAP_PAIRS
		local pair = pairs_tbl[ch]

		-- Probe the selection ONLY for configured wrap symbols (avoids an AX call on
		-- every other keystroke). nil = nothing selected OR the app hides
		-- AXSelectedText (e.g. VS Code / Electron). Cached for the short TTL above.
		local sel = pair and read_wrap_ax_selection_cached() or nil
		local decision = M.wrap_event_decision(flags, ch, pairs_tbl, sel ~= nil)
		if ch:match("%w") == nil and ch:match("%s") == nil then
			Logger.debug(LOG, "wrap key=%q alt=%s match=%s sel=%s => %s",
				ch, tostring(flags.alt == true), tostring(pair ~= nil),
				tostring(sel ~= nil), decision)
		end

		if decision ~= "wrap" then return finish_tap(false, fence_events) end
		text_acts.wrap_selection(sel, pair.left, pair.right)
		mark_wrap_selection_consumed()
		return finish_tap(true, fence_events)
	end)
	tap:start()
	return wrap_tap(tap)
end





-- ===========================================
-- ===========================================
-- ======= 4/ Sub-module Merge (Pixel) =======
-- ===========================================
-- ===========================================

-- Merge pixel-color and screenshot helpers from system_pixel so callers that
-- require("modules.shortcuts.actions.system") continue to see one flat table.
local pixel_mod = require("modules.shortcuts.actions.system_pixel")
for k, v in pairs(pixel_mod) do
	M[k] = v
end





-- ===========================================
-- ===========================================
-- ======= 5/ Sub-module Merge (Mouse) =======
-- ===========================================
-- ===========================================

-- Merge mouse/display/spotlight utilities from system_mouse for the same reason.
local mouse_mod = require("modules.shortcuts.actions.system_mouse")
for k, v in pairs(mouse_mod) do
	M[k] = v
end

return M
