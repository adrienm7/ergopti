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
---    so CapsWord is cancelled automatically. A 100 ms subprocess throttle
---    prevents CPU spikes from high-frequency events such as mouseMoved.
--- 2. Layout Awareness: macOS can emit two input-source notifications in rapid
---    succession during a layout switch. Debouncing coalesces them into a
---    single callback so the caller does not rebuild the KE config twice.
--- 3. Window Cycling: Cycles focus through standard windows of the active app
---    directly via the Hammerspoon API, bypassing the macOS Cmd+` shortcut
---    which is layout-dependent and inactive on some keyboard layouts (AZERTY).
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "karabiner"

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

-- Timestamp (fractional seconds) of the last CapsWord subprocess check.
local _capsword_last_check_s = 0

-- Guard against spawning concurrent async checks while one is already in flight.
local _capsword_check_pending = false




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
		hs.task.new(KARABINER_CLI, function(_, _, _) end, {"--set-variable", "capsword", "0"}):start()

		-- hs.eventtap.keyStroke does not work for CapsLock on macOS — CapsLock is
		-- a flagsChanged event, not a regular keyDown/keyUp, so keyStroke fails
		-- silently. hs.hid.capslock.set is the only reliable way to toggle the LED.
		pcall(hs.hid.capslock.set, false)

		Logger.done(LOG, "CapsWord deactivated via pointer event.")
	end, {"--get-variable", "capsword"}):start()
end

--- Starts the eventtap watching for any pointer event that signals the user
--- has left the keyboard: movement, scroll, gestures, and all click types.
--- @return hs.eventtap The running watcher instance.
function M.start_gesture_watcher()
	local watcher = hs.eventtap.new(
		{
			hs.eventtap.event.types.mouseMoved,
			hs.eventtap.event.types.scrollWheel,
			hs.eventtap.event.types.gesture,
			hs.eventtap.event.types.leftMouseDown,
			hs.eventtap.event.types.rightMouseDown,
			hs.eventtap.event.types.otherMouseDown,
		},
		function(_event)
			deactivate_capsword()
			return false
		end
	)
	watcher:start()
	Logger.success(LOG, "Trackpad CapsWord watcher started.")
	return watcher
end




-- =======================================
-- =======================================
-- ======= 2/ Input Source Watcher =======
-- =======================================
-- =======================================

--- Registers a debounced hs.keycodes.inputSourceChanged callback.
--- The provided on_change callback is invoked once per layout switch, after the
--- debounce window, with the new layout name as its only argument.
--- The hs.keycodes callback slot is global — this module assumes exclusive ownership.
--- @param on_change fun(layout_name: string) Called on each debounced layout change.
function M.start_input_source_watcher(on_change)
	Logger.trace(LOG, "Registering input source watcher…")
	hs.keycodes.inputSourceChanged(function()
		Logger.debug(LOG, "Input source notification received — debouncing (%.0fms)…",
			INPUT_SOURCE_DEBOUNCE_SEC * 1000)
		if _input_source_timer then
			pcall(function() _input_source_timer:stop() end)
		end
		_input_source_timer = hs.timer.doAfter(INPUT_SOURCE_DEBOUNCE_SEC, function()
			_input_source_timer = nil
			local layout_name  = "<unknown>"
			local ok, current  = pcall(function() return hs.keycodes.currentLayout() end)
			if ok and current then layout_name = tostring(current) end
			local ok_cb, err = pcall(on_change, layout_name)
			if not ok_cb then
				Logger.error(LOG, "Input source change handler failed: %s.", tostring(err))
			end
		end)
	end)
	Logger.done(LOG, "Input source watcher registered.")
end

--- Clears the hs.keycodes.inputSourceChanged callback and cancels any
--- pending debounced rebuild.
function M.stop_input_source_watcher()
	Logger.trace(LOG, "Stopping input source watcher…")
	pcall(function() hs.keycodes.inputSourceChanged(nil) end)
	if _input_source_timer then
		pcall(function() _input_source_timer:stop() end)
		_input_source_timer = nil
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

--- Registers a global hotkey on F13 that cycles windows within the frontmost app.
--- F13 is sent by the 'cycle_windows_in_app' Karabiner action, making the shortcut
--- layout-independent — no dependency on the macOS Cmd+` binding, which is
--- unreliable on AZERTY and other non-US keyboard layouts.
--- F13 is used here because F18/F19/F20 are already reserved as script-control
--- sentinels and LLM-chain signals in this codebase.
--- @return hs.hotkey The enabled hotkey instance.
function M.start_cycle_windows_hotkey()
	Logger.trace(LOG, "Registering cycle-windows hotkey (F13)…")
	local hotkey = hs.hotkey.new({}, "f13", cycle_windows_in_app)
	hotkey:enable()
	Logger.done(LOG, "Cycle-windows hotkey registered.")
	return hotkey
end

return M
