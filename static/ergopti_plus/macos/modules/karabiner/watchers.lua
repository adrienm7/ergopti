--- modules/karabiner/watchers.lua

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
local EventTapGuard = require("adapters.event_tap_guard")
local Timings        = require("infra.timings")
local Keycodes       = require("infra.keycodes")
local ShellRunner    = require("adapters.shell_runner")
local TimerScheduler = require("adapters.timer_scheduler")


local LOG = "karabiner"

-- hs.hotkey accepts the macOS key name directly, derived here from the
-- registry numeric keycode so the registry stays the canonical source.
local KEYCODE_F17_NAME = Keycodes.to_name(Keycodes.F17_CYCLE_WINDOWS)
local MOD_SHIFT = "shift"
local MOD_ALT = "alt"

local KARABINER_CLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

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
-- Max time to wait for the async layout read before force-releasing the pending
-- guard. ShellRunner.spawn() returns a handle UNCONDITIONALLY — when the task
-- constructor failed, handle.start() only logs an error — and task:start() can
-- itself return false under fork pressure. Neither is a throw, and in both cases
-- the completion callback never fires, so without this watchdog
-- _layout_poll_pending latches true and the guard short-circuits EVERY later tick
-- for the rest of the session, silently killing the Sequoia layout-change poll.
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

-- Monotonic probe generation. A terminated or timed-out probe's callback still
-- fires, and it used to clear _capsword_check_pending and cancel the watchdog
-- unconditionally — the SUCCESSOR probe's, by then. The sibling layout read in
-- this same module was generation-gated for exactly this; the CapsWord probe was
-- not, so a slow probe could unlock a fresh one and leave two racing.
local _capsword_gen = 0

-- GC root for the CapsWord probe tasks. An hs.task that is not referenced from a
-- GC root can be collected mid-run, which kills the subprocess and means its
-- completion callback never fires — here that would leave KE with capsword=1 and
-- the next spacebar would switch CapsLock back on. Canonical spelling recognised
-- by tests/unit/meta/test_gc_retention.lua. Entries are released in the callbacks.
local _active_tasks = {}

-- App history cache for direct app-previous focus.
local _current_bundle_id = nil
local _previous_bundle_id = nil
local _current_app_name = nil
local _previous_app_name = nil
local _app_switch_watcher = nil





-- ===========================================
-- ===========================================
-- ======= 1/ CapsWord Gesture Watcher =======
-- ===========================================
-- ===========================================

--- Resets CapsWord: clears the KE variable then turns off the CapsLock LED.
--- Uses a time-based throttle and async hs.task to avoid blocking the Hammerspoon
--- main loop — hs.execute is synchronous and would lag the mouse at ~10 calls/sec.
local function deactivate_capsword()
	-- Throttle: mouseMoved fires at display refresh rate — cap subprocess spawns
	local now_s = hs.timer.secondsSinceEpoch()
	if now_s - _capsword_last_check_s < CAPSWORD_CHECK_INTERVAL_S then return end
	-- Skip if a check is already in flight to avoid concurrent async tasks
	if _capsword_check_pending then return end
	_capsword_last_check_s    = now_s
	_capsword_check_pending   = true
	_capsword_gen             = _capsword_gen + 1
	local my_capsword_gen     = _capsword_gen

	-- Async get: unblocks the main loop immediately; callback fires on completion
	local task
	task = hs.task.new(KARABINER_CLI, function(exit_code, stdout, _)
		if task then _active_tasks[task] = nil end
		-- A superseded probe releases nothing: the flag and the watchdog it would
		-- clear belong to the probe that replaced it.
		if my_capsword_gen ~= _capsword_gen then return end
		_capsword_check_pending = false
		if _capsword_probe_watchdog then
			TimerScheduler.cancel(_capsword_probe_watchdog)
			_capsword_probe_watchdog = nil
		end
		if exit_code ~= 0 or tonumber(stdout) ~= 1 then return end

		Logger.trace(LOG, "Pointer event while CapsWord active — deactivating…")

		-- Clear the KE variable first so the engine does not re-activate CapsWord
		-- when it sees the subsequent LED state change.
		local inner_task
		inner_task = hs.task.new(KARABINER_CLI, function(_, _, _)
			if inner_task then _active_tasks[inner_task] = nil end
			-- macOS sometimes re-displays the CapsLock indicator after a single
			-- LED reset (race with the Karabiner virtual CapsLock state machine).
			-- A second unconditional set 150 ms later ensures the indicator stays off.
			pcall(hs.hid.capslock.set, false)
			hs.timer.doAfter(0.15, function() pcall(hs.hid.capslock.set, false) end)
			Logger.done(LOG, "CapsWord deactivated via pointer event.")
		end, {"--set-variable", "capsword", "0"})
		-- Nil-check: hs.task.new() returns nil when the CLI binary is absent.
		-- Pin BEFORE start: this task clears KE's capsword variable, and if the GC
		-- collects it mid-run the variable stays 1 and the next space re-enables
		-- CapsLock. start() reports a refused launch by RETURNING false, so the pin
		-- is released on that path too rather than leaking for the session.
		if inner_task then
			_active_tasks[inner_task] = true
			if not inner_task:start() then
				_active_tasks[inner_task] = nil
				Logger.error(LOG, "CapsWord clear-variable task failed to start — KE may keep capsword=1.")
			end
		end

		-- hs.eventtap.keyStroke does not work for CapsLock on macOS — CapsLock is
		-- a flagsChanged event, not a regular keyDown/keyUp, so keyStroke fails
		-- silently. hs.hid.capslock.set is the only reliable way to toggle the LED.
		pcall(hs.hid.capslock.set, false)
	end, {"--get-variable", "capsword"})
	-- Nil means the CLI binary is absent; release the lock immediately so the guard is not permanent.
	if not task then
		_capsword_check_pending = false
		Logger.error(LOG, "CapsWord check task is nil — CLI binary absent (karabiner-capsword-lock-leak).")
		return
	end
	-- If task:start() returns false the callback never fires — release the lock so subsequent
	-- pointer events are not permanently blocked (karabiner-capsword-lock-leak).
	_active_tasks[task] = true
	if not task:start() then
		_active_tasks[task] = nil
		_capsword_check_pending = false
		Logger.error(LOG, "CapsWord check task failed to start (karabiner-capsword-lock-leak).")
		return
	end
	-- Started OK, but the async task fires its callback only on process EXIT. Arm a watchdog
	-- so a CLI that starts then hangs/zombies still releases the pending lock instead
	-- of permanently disabling trackpad auto-deactivation of CapsWord (F-L6). Scheduled
	-- via the TimerScheduler adapter (not raw hs.timer.doAfter) so this OS call is
	-- properly attributed to the adapter boundary (PF-1).
	if _capsword_probe_watchdog then TimerScheduler.cancel(_capsword_probe_watchdog) end
	_capsword_probe_watchdog = TimerScheduler.after(CAPSWORD_PROBE_TIMEOUT_SEC, function()
		_capsword_probe_watchdog = nil
		if _capsword_check_pending then
			_capsword_check_pending = false
			Logger.debug(LOG, "CapsWord probe timed out — releasing lock (karabiner-capsword-lock-leak).")
			pcall(function() task:terminate() end)
		end
	end)
end

--- Starts the eventtap watching for any pointer event that signals the user
--- has left the keyboard: movement, scroll, gestures, and all click types.
--- Bare finger contact is handled via gestures_engine.set_any_touch_hook(),
--- which piggybacks on the existing touchdevice frameCallback in the gestures
--- module rather than registering a competing second frameCallback.
--- @param gestures_engine table The gestures engine module (may be nil).
--- @return hs.eventtap The running eventtap watcher instance.
function M.start_gesture_watcher(gestures_engine)
	local ev = hs.eventtap.event.types
	local watcher
	watcher = hs.eventtap.new(
		{
			ev.mouseMoved,
			ev.scrollWheel,
			ev.gesture,
			ev.leftMouseDown,
			ev.rightMouseDown,
			ev.otherMouseDown,
		},
		function(_event)
			if EventTapGuard.handle_disabled(_event, watcher, "karabiner.trackpad_capsword") then return false end
			-- This callback fires on mouseMoved/scrollWheel/gesture/click — the
			-- hottest possible eventtap. deactivate_capsword() contains an
			-- unguarded hs.task.new(...) call; every sibling eventtap added in
			-- the same refactor window wraps its callback body, so an unhandled
			-- exception here would silently disable the whole tap
			-- (karabiner-watchers-unguarded-capsword).
			Logger.pcall(LOG, deactivate_capsword)
			return false
		end
	)
	watcher:start()
	Logger.success(LOG, "Trackpad CapsWord watcher started.")

	-- Layer 2: hook into the gestures engine's existing frameCallback so bare
	-- finger touch (no click, no movement) also deactivates CapsWord.
	if gestures_engine and type(gestures_engine.set_any_touch_hook) == "function" then
		gestures_engine.set_any_touch_hook(deactivate_capsword)
		Logger.success(LOG, "Bare-touch CapsWord hook registered on gestures engine.")
	else
		Logger.warn(LOG, "gestures_engine unavailable — bare-touch CapsWord detection disabled.")
	end

	return watcher
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

--- Reads the current keyboard layout name ASYNCHRONOUSLY via the ShellRunner
--- adapter (off the main run loop). The previous fallback poll spawned a
--- SYNCHRONOUS `defaults` subprocess on the main loop every LAYOUT_POLL_SEC for
--- the whole session — exactly the steady-state main-loop cost the profilers aim
--- to eliminate, and worse on the Sequoia machines this poll exists for.
--- @param callback fun(layout_name: string|nil)
local function read_layout_async(callback)
	-- Stamp this read so its completion can prove it is still the current one.
	_layout_read_generation = _layout_read_generation + 1
	local my_generation = _layout_read_generation

	-- Capture the handle and call start() — ShellRunner.spawn() builds the task
	-- but deliberately does NOT start it; the caller must invoke handle.start().
	-- Without this the subprocess never launches, the completion callback never
	-- fires, and _layout_poll_pending leaks true forever (F-LOW-4 regression).
	local handle = ShellRunner.spawn("/usr/bin/defaults",
		{ "read", "com.apple.HIToolbox", "AppleSelectedInputSources" },
		function(exit_code, stdout, _)
			-- A terminated read still delivers its exit callback, and by then the
			-- next read is usually in flight. Every line below mutates state that
			-- now belongs to THAT read, so a stale completion must stop here rather
			-- than clear its handle, release its guard and cancel its watchdog.
			if my_generation ~= _layout_read_generation then
				Logger.debug(LOG, "Ignoring completion of superseded layout read (gen %d, current %d).",
					my_generation, _layout_read_generation)
				return
			end
			-- Drop the ownership reference first: a handle that has completed must
			-- never be terminated by a later watchdog tick.
			_layout_poll_handle = nil
			if exit_code ~= 0 then callback(nil); return end
			callback(parse_layout_name(stdout))
		end)
	-- Published BEFORE start() so a handle that completes synchronously has already
	-- cleared it in its callback and cannot be overwritten by a stale assignment.
	_layout_poll_handle = handle
	handle.start()
end

--- Fires the on_change callback with proper debouncing, updating _last_known_layout.
--- @param on_change fun(layout_name: string)
--- @param layout_name string
local function fire_layout_change(on_change, layout_name)
	if _input_source_timer then
		pcall(function() _input_source_timer:stop() end)
	end
	_input_source_timer = hs.timer.doAfter(INPUT_SOURCE_DEBOUNCE_SEC, function()
		_input_source_timer = nil
		_last_known_layout  = layout_name
		local ok_cb, err = pcall(on_change, layout_name)
		if not ok_cb then
			Logger.error(LOG, "Input source change handler failed: %s.", tostring(err))
		end
	end)
end

--- Registers a debounced layout-change watcher.
--- Uses both hs.keycodes.inputSourceChanged (immediate notification) AND a
--- periodic HIToolbox poll (fallback for Sequoia where the TIS callback is
--- unreliable). The on_change callback fires at most once per debounce window.
--- @param on_change fun(layout_name: string) Called on each debounced layout change.
function M.start_input_source_watcher(on_change)
	Logger.trace(LOG, "Registering input source watcher…")

	-- Guard against double-call: overwriting _layout_poll_timer would orphan the
	-- previous timer with no reference left to stop it
	if _layout_poll_timer then
		Logger.warn(LOG, "start_input_source_watcher() called twice — ignoring.")
		return
	end

	-- Seed the initial known layout from HIToolbox
	_last_known_layout = read_current_layout_from_hitoolbox()
		or (pcall(function() return hs.keycodes.currentLayout() end) and hs.keycodes.currentLayout())
		or nil
	Logger.debug(LOG, "Initial layout: '%s'.", tostring(_last_known_layout))

	-- Save the previous global callback so stop_input_source_watcher can restore it
	-- rather than passing nil (which would clear callbacks registered by other modules).
	_previous_input_source_cb = hs.keycodes.inputSourceChanged()

	-- Primary: hs.keycodes notification (fires immediately on most macOS versions)
	hs.keycodes.inputSourceChanged(function()
		Logger.debug(LOG, "Input source notification received — debouncing (%.0fms)…",
			INPUT_SOURCE_DEBOUNCE_SEC * 1000)
		-- Read from HIToolbox, not hs.keycodes.currentLayout(), to avoid TIS cache lag
		local new_layout = read_current_layout_from_hitoolbox()
			or (pcall(function() return hs.keycodes.currentLayout() end) and hs.keycodes.currentLayout())
			or "<unknown>"
		fire_layout_change(on_change, new_layout)
	end)

	-- Fallback: poll HIToolbox every LAYOUT_POLL_SEC — catches layout changes that
	-- didn't trigger hs.keycodes.inputSourceChanged (Sequoia regression).
	_layout_poll_timer = hs.timer.doEvery(LAYOUT_POLL_SEC, function()
		-- Read HIToolbox ASYNCHRONOUSLY (off the main run loop). Skip if a read is
		-- already in flight so back-to-back ticks under load cannot pile up tasks.
		if _layout_poll_pending then return end
		_layout_poll_pending = true
		-- Arm the watchdog alongside the guard so a read whose completion callback
		-- never fires still releases it and the next tick can retry. Scheduled via
		-- the TimerScheduler adapter (not raw hs.timer.doAfter) so this OS call is
		-- attributed to the adapter boundary, mirroring the CapsWord probe watchdog.
		if _layout_poll_watchdog then TimerScheduler.cancel(_layout_poll_watchdog) end
		_layout_poll_watchdog = TimerScheduler.after(LAYOUT_POLL_TIMEOUT_SEC, function()
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
					_layout_poll_handle = nil
					pcall(function() stale.terminate() end)
				end
				Logger.warn(LOG, "Layout poll read timed out — terminated the read and released the guard so the next tick can retry.")
			end
		end)
		read_layout_async(function(current)
			_layout_poll_pending = false
			if _layout_poll_watchdog then
				TimerScheduler.cancel(_layout_poll_watchdog)
				_layout_poll_watchdog = nil
			end
			if current and current ~= _last_known_layout then
				Logger.info(LOG, "Layout poll detected change: '%s' → '%s'.",
					tostring(_last_known_layout), current)
				fire_layout_change(on_change, current)
			end
		end)
	end)

	Logger.done(LOG, "Input source watcher registered (poll every %.0fs).", LAYOUT_POLL_SEC)
end

--- Clears the hs.keycodes.inputSourceChanged callback, cancels the poll timer,
--- and cancels any pending debounced rebuild.
function M.stop_input_source_watcher()
	Logger.trace(LOG, "Stopping input source watcher…")
	-- Restore the previous callback rather than passing nil, so that any
	-- callback registered before this module started is not silently dropped.
	pcall(function() hs.keycodes.inputSourceChanged(_previous_input_source_cb) end)
	_previous_input_source_cb = nil
	if _input_source_timer then
		pcall(function() _input_source_timer:stop() end)
		_input_source_timer = nil
	end
	if _layout_poll_timer then
		pcall(function() _layout_poll_timer:stop() end)
		_layout_poll_timer = nil
	end
	-- Cancel the in-flight read's watchdog too, so it cannot fire after the watcher
	-- is gone and flip the guard on a module that is no longer polling.
	if _layout_poll_watchdog then
		TimerScheduler.cancel(_layout_poll_watchdog)
		_layout_poll_watchdog = nil
	end
	_layout_poll_pending = false
	-- Retire the in-flight read as well. Its completion would otherwise land on a
	-- stopped watcher and fire a layout change nobody is listening for.
	_layout_read_generation = _layout_read_generation + 1
	Logger.done(LOG, "Input source watcher stopped.")
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

	visible[next_idx]:focus()
end

--- Starts app-activation tracking for direct previous-app switching.
local function ensure_app_switch_watcher()
	if _app_switch_watcher then return end

	_app_switch_watcher = hs.application.watcher.new(function(_name, event_type, app)
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
	_app_switch_watcher:start()

	local front = hs.application.frontmostApplication()
	if front then
		_current_bundle_id = front:bundleID()
		_current_app_name = front:name()
	end
end

--- Focuses the globally previous standard window (MRU-2).
local function focus_previous_window_global()
	local wins = hs.window.orderedWindows()
	if type(wins) ~= "table" or #wins <= 1 then return false end

	local focused = hs.window.focusedWindow()
	local focused_id = focused and focused:id() or nil

	for _, w in ipairs(wins) do
		local wid = w and w:id() or nil
		if wid and (not focused_id or wid ~= focused_id)
			and w:isStandard() and not w:isMinimized() then
			w:focus()
			return true
		end
	end

	return false
end

--- Focuses the previously active application directly (no macOS switcher overlay).
local function focus_previous_app_direct()
	ensure_app_switch_watcher()

	if type(_previous_bundle_id) == "string"
		and _previous_bundle_id ~= ""
		and type(hs.application.launchOrFocusByBundleID) == "function" then
		local ok = pcall(hs.application.launchOrFocusByBundleID, _previous_bundle_id)
		if ok then return true end
	end

	if type(_previous_app_name) == "string" and _previous_app_name ~= "" then
		local ok = pcall(hs.application.launchOrFocus, _previous_app_name)
		if ok then return true end
	end

	if type(_previous_bundle_id) == "string" and _previous_bundle_id ~= "" then
		local target = hs.application.get(_previous_bundle_id)
		if target then
			target:activate()
			return true
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
--- @return hs.hotkey The enabled hotkey instance.
function M.start_cycle_windows_hotkey()
	Logger.trace(LOG, "Registering cycle-windows hotkey (F17)…")
	local hotkey = hs.hotkey.new({}, KEYCODE_F17_NAME, function() pcall(cycle_windows_in_app) end)
	hotkey:enable()
	Logger.done(LOG, "Cycle-windows hotkey registered.")
	return hotkey
end

--- Registers Shift+F17 as "global previous window".
--- @return hs.hotkey
function M.start_alt_tab_windows_hotkey()
	Logger.trace(LOG, "Registering Alt+Tab windows hotkey (Shift+F17)…")
	local hotkey = hs.hotkey.new({ MOD_SHIFT }, KEYCODE_F17_NAME, function()
		local ok = pcall(focus_previous_window_global)
		if not ok then
			Logger.warn(LOG, "Shift+F17 callback failed while focusing previous window.")
		end
	end)
	hotkey:enable()
	Logger.done(LOG, "Alt+Tab windows hotkey registered.")
	return hotkey
end

--- Registers Option+F17 as "direct previous app".
--- @return hs.hotkey
function M.start_alt_tab_apps_hotkey()
	ensure_app_switch_watcher()
	Logger.trace(LOG, "Registering Alt+Tab apps hotkey (Option+F17)…")
	local hotkey = hs.hotkey.new({ MOD_ALT }, KEYCODE_F17_NAME, function()
		local ok, switched = pcall(focus_previous_app_direct)
		if not ok or not switched then
			Logger.warn(LOG, "Option+F17 could not focus previous app.")
		end
	end)
	hotkey:enable()
	Logger.done(LOG, "Alt+Tab apps hotkey registered.")
	return hotkey
end

--- Stops the internal app-switch watcher used by Alt+Tab app-previous.
function M.stop_alt_tab_apps_tracker()
	if _app_switch_watcher then
		pcall(function() _app_switch_watcher:stop() end)
		_app_switch_watcher = nil
	end
end

return M
