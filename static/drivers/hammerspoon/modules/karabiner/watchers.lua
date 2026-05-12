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

local hs          = hs
local Logger      = require("lib.logger")
local Keycodes    = require("lib.keycodes")

-- Optional: undocumented MultitouchSupport wrapper — nil when unavailable.
local ok_td, touchdevice = pcall(require, "hs._asm.undocumented.touchdevice")
if not ok_td then touchdevice = nil end

local LOG = "karabiner"

-- hs.hotkey accepts the macOS key name directly, derived here from the
-- registry numeric keycode so the registry stays the canonical source.
local KEYCODE_F17_NAME = Keycodes.to_name(Keycodes.F17_CYCLE_WINDOWS)
local MOD_SHIFT = "shift"
local MOD_ALT = "alt"

local KARABINER_CLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"

-- macOS can emit two input-source change notifications in rapid succession
-- during a layout switch — debouncing coalesces them into a single rebuild.
local INPUT_SOURCE_DEBOUNCE_SEC = 0.25

-- mouseMoved fires at display refresh rate (~60–120 fps); capping the
-- subprocess check prevents CPU spikes when CapsWord is not even active.
local CAPSWORD_CHECK_INTERVAL_S = 0.1

-- Holds the pending debounce timer so consecutive notifications within the
-- window supersede the previous one instead of triggering parallel rebuilds.
local _input_source_timer = nil

-- Last known layout name — used by the HIToolbox poll to detect changes when
-- hs.keycodes.inputSourceChanged is unreliable (Sequoia regression).
local _last_known_layout = nil

-- Poll interval for the HIToolbox fallback watcher.
local LAYOUT_POLL_SEC = 2.0

-- Holds the fallback poll timer so it can be cancelled on stop.
local _layout_poll_timer = nil

-- Timestamp (fractional seconds) of the last CapsWord subprocess check.
local _capsword_last_check_s = 0

-- Guard against spawning concurrent async checks while one is already in flight.
local _capsword_check_pending = false

-- touchdevice frameCallback watchers keyed by device ID — kept alive to prevent GC.
local _td_devices  = {}
local _td_watchers = {}

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

	-- Async get: unblocks the main loop immediately; callback fires on completion
	hs.task.new(KARABINER_CLI, function(exit_code, stdout, _)
		_capsword_check_pending = false
		if exit_code ~= 0 or tonumber(stdout) ~= 1 then return end

		Logger.trace(LOG, "Pointer event while CapsWord active — deactivating…")

		-- Clear the KE variable first so the engine does not re-activate CapsWord
		-- when it sees the subsequent LED state change.
		hs.task.new(KARABINER_CLI, function(_, _, _)
			-- macOS sometimes re-displays the CapsLock indicator after a single
			-- LED reset (race with the Karabiner virtual CapsLock state machine).
			-- A second unconditional set 150 ms later ensures the indicator stays off.
			pcall(hs.hid.capslock.set, false)
			hs.timer.doAfter(0.15, function() pcall(hs.hid.capslock.set, false) end)
			Logger.done(LOG, "CapsWord deactivated via pointer event.")
		end, {"--set-variable", "capsword", "0"}):start()

		-- hs.eventtap.keyStroke does not work for CapsLock on macOS — CapsLock is
		-- a flagsChanged event, not a regular keyDown/keyUp, so keyStroke fails
		-- silently. hs.hid.capslock.set is the only reliable way to toggle the LED.
		pcall(hs.hid.capslock.set, false)
	end, {"--get-variable", "capsword"}):start()
end

--- Attaches a frameCallback watcher on every available touchdevice so that
--- any bare finger contact (no click required) triggers CapsWord deactivation.
--- The MultitouchSupport API fires at ~60 Hz; the existing throttle inside
--- deactivate_capsword() prevents CPU spikes.
local function start_touchdevice_watchers()
	if not touchdevice then
		Logger.warn(LOG, "touchdevice unavailable — bare-touch CapsWord detection disabled.")
		return
	end

	local ok_list, devices = pcall(touchdevice.devices)
	if not ok_list or type(devices) ~= "table" then
		Logger.warn(LOG, "touchdevice.devices() failed — bare-touch detection disabled.")
		return
	end

	for _, id in ipairs(devices) do
		local ok_dev, dev = pcall(touchdevice.forDeviceID, id)
		if not ok_dev or not dev then
			Logger.warn(LOG, "touchdevice.forDeviceID(%s) failed.", tostring(id))
		else
			-- Hold a strong reference to prevent GC from collecting the device.
			_td_devices[id] = dev
			local w = dev:frameCallback(function(_, touches, _, _)
				if type(touches) == "table" and #touches > 0 then
					deactivate_capsword()
				end
			end)
			if w then
				pcall(function() w:start() end)
				_td_watchers[id] = w
				Logger.success(LOG, "Touchdevice bare-touch watcher started (device=%s).", tostring(id))
			else
				Logger.warn(LOG, "frameCallback returned nil for device=%s.", tostring(id))
			end
		end
	end
end

--- Starts the eventtap watching for any pointer event that signals the user
--- has left the keyboard: movement, scroll, gestures, and all click types.
--- A separate touchdevice frameCallback layer catches bare finger touches
--- that eventtap cannot see (no click, no movement).
--- @return hs.eventtap The running eventtap watcher instance.
function M.start_gesture_watcher()
	local ev = hs.eventtap.event.types
	local watcher = hs.eventtap.new(
		{
			ev.mouseMoved,
			ev.scrollWheel,
			ev.gesture,
			ev.leftMouseDown,
			ev.rightMouseDown,
			ev.otherMouseDown,
		},
		function(_event)
			deactivate_capsword()
			return false
		end
	)
	watcher:start()
	Logger.success(LOG, "Trackpad CapsWord watcher started.")

	-- Layer 2: MultitouchSupport frameCallback for bare finger detection.
	start_touchdevice_watchers()

	return watcher
end




-- =======================================
-- =======================================
-- ======= 2/ Input Source Watcher =======
-- =======================================
-- =======================================

--- Reads the current keyboard layout name from HIToolbox (AppleSelectedInputSources).
--- More reliable than hs.keycodes.currentLayout() on Sequoia which can return
--- stale values from the TIS cache.
--- @return string|nil
local function read_current_layout_from_hitoolbox()
	local raw, ok = hs.execute("defaults read com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null")
	if not ok or type(raw) ~= "string" or raw == "" then return nil end
	local name = raw:match('"KeyboardLayout Name"%s*=%s*"([^"]+)"')
		or raw:match("KeyboardLayout Name%s*=%s*([^;%s]+)")
	return name
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

	-- Seed the initial known layout from HIToolbox
	_last_known_layout = read_current_layout_from_hitoolbox()
		or (pcall(function() return hs.keycodes.currentLayout() end) and hs.keycodes.currentLayout())
		or nil
	Logger.debug(LOG, "Initial layout: '%s'.", tostring(_last_known_layout))

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
		local current = read_current_layout_from_hitoolbox()
		if current and current ~= _last_known_layout then
			Logger.info(LOG, "Layout poll detected change: '%s' → '%s'.",
				tostring(_last_known_layout), current)
			fire_layout_change(on_change, current)
		end
	end)

	Logger.done(LOG, "Input source watcher registered (poll every %.0fs).", LAYOUT_POLL_SEC)
end

--- Clears the hs.keycodes.inputSourceChanged callback, cancels the poll timer,
--- and cancels any pending debounced rebuild.
function M.stop_input_source_watcher()
	Logger.trace(LOG, "Stopping input source watcher…")
	pcall(function() hs.keycodes.inputSourceChanged(nil) end)
	if _input_source_timer then
		pcall(function() _input_source_timer:stop() end)
		_input_source_timer = nil
	end
	if _layout_poll_timer then
		pcall(function() _layout_poll_timer:stop() end)
		_layout_poll_timer = nil
	end
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
	for _, w in ipairs(app:allWindows()) do
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
	local hotkey = hs.hotkey.new({}, KEYCODE_F17_NAME, cycle_windows_in_app)
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
