--- modules/gestures/actions_click.lua

--- ==============================================================================
--- MODULE: Gestures Synthetic Click Hold
--- DESCRIPTION:
--- Owns the synthetic left/right "click-hold" subsystem: posting a held mouse
--- button, converting idle mouse-moves into drag events, and auto-releasing the
--- hold on the next keypress. Extracted from gestures/actions.lua so the action
--- registry stays a pure mapping of names to behaviours, while this self-contained
--- module keeps the mutable hold state (held flags, mouse/keyboard event taps) in
--- one place.
---
--- FEATURES & RATIONALE:
--- 1. Single owner of hold state — the held flags and the three event taps live
---    here only, so no other module can leave a dangling synthetic button down.
--- 2. Race-safe deferred toggles — the mouseUp re-toggle is guarded on the held
---    flag so a concurrent key-down release cannot re-engage a phantom hold.
--- 3. Shared release path — force_cleanup and release_held_for_tap funnel through
---    the same teardown so a tap action and a hard reset behave identically.
--- ==============================================================================

local M = {}

local hs      = hs
local Logger  = require("infra.logger")
local EventTapGuard = require("adapters.event_tap_guard")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput = require("adapters.synthetic_input")
local Timings = require("infra.timings")
local LOG     = "gestures.click"

-- Delay to ignore the spurious mouseUp from the gesture's own finger-lift.
-- Shared cross-driver value ([gestures] click_cooldown_ms).
local CLICK_COOLDOWN_SEC = Timings.sec("gestures", "click_cooldown_ms")

local rightClickHeld    = false
local leftClickHeld     = false
local rightMouseTap     = nil
local leftMouseTap      = nil
local click_key_watcher = nil





-- ================================================
-- ================================================
-- ======= 1/ Keyboard Auto-Release Watcher =======
-- ================================================
-- ================================================

--- Stops the keyboard watcher that auto-releases held clicks on any keypress.
local function stop_click_key_watcher()
	if not click_key_watcher then return end
	pcall(function() click_key_watcher:stop() end)
	click_key_watcher = nil
end

--- Starts a keyboard watcher that releases all held synthetic clicks on the next keydown.
local function start_click_key_watcher()
	if click_key_watcher then return end
	click_key_watcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown, hs.eventtap.event.types.flagsChanged }, function(e)
		if EventTapGuard.handle_disabled(e, click_key_watcher, "gestures.click_key") then return false end
		local provenance, status, fence = EventProvenance.classify_with_fence(
			e, "gestures.click_key")
		local ordered_events = {}
		for _, older in ipairs((fence and fence.events) or {}) do
			ordered_events[#ordered_events + 1] = older
		end
		if provenance or status == EventProvenance.STATUS_UNREADABLE then
			return false, (#ordered_events > 0 and ordered_events or nil)
		end
		-- Snapshot the intended release, then construct every mouseUp before
		-- tearing down a single tap/state bit. A native constructor failure must
		-- leave the hold recoverable instead of stranding the application in drag.
		local releaseLeft  = leftClickHeld
		local releaseRight = rightClickHeld
		local ok_pos, pos = pcall(hs.mouse.absolutePosition)
		local release_events = {}
		local construction_error = nil
		if not ok_pos or type(pos) ~= "table" then
			construction_error = tostring(pos or "mouse position unavailable")
		end
		local function build_release(event_type)
			if construction_error then return end
			local ok_event, mouse_up = pcall(hs.eventtap.event.newMouseEvent, event_type, pos)
			if not ok_event or mouse_up == nil then
				construction_error = tostring(mouse_up or "newMouseEvent returned nil")
				return
			end
			release_events[#release_events + 1] = mouse_up
		end
		if releaseLeft then build_release(hs.eventtap.event.types.leftMouseUp) end
		if releaseRight then build_release(hs.eventtap.event.types.rightMouseUp) end
		if construction_error then
			SyntheticInput.defer_after_callback("click-hold release diagnostic", function()
				Logger.error(LOG, "Could not construct click-hold mouseUp: %s.",
					construction_error)
			end)
			return false, (#ordered_events > 0 and ordered_events or nil)
		end

		local tapL = leftMouseTap
		local tapR = rightMouseTap
		if tapL then pcall(function() tapL:stop() end); leftMouseTap = nil end
		if tapR then pcall(function() tapR:stop() end); rightMouseTap = nil end
		leftClickHeld  = false
		rightClickHeld = false
		pcall(function() click_key_watcher:stop() end)
		click_key_watcher = nil
		-- Return mouseUp before the original key. Hammerspoon posts returned events
		-- first, so no synchronous event:post() or duplicate raw key is needed.
		for _, mouse_up in ipairs(release_events) do
			ordered_events[#ordered_events + 1] = mouse_up
		end
		SyntheticInput.defer_after_callback("click-hold release log", function()
			if releaseLeft then Logger.info(LOG, "Synthetic Left-Click RELEASED by keydown.") end
			if releaseRight then Logger.info(LOG, "Synthetic Right-Click RELEASED by keydown.") end
		end)
		return false, (#ordered_events > 0 and ordered_events or nil)
	end)
	pcall(function() click_key_watcher:start() end)
end





-- ===================================
-- ===================================
-- ======= 2/ Public Click API =======
-- ===================================
-- ===================================

--- Forcefully releases every held synthetic click and stops all related taps.
function M.force_cleanup()
	Logger.debug(LOG, "Forcefully releasing all held clicks…")
	stop_click_key_watcher()
	local pos = hs.mouse.absolutePosition()
	if leftMouseTap  then pcall(function() leftMouseTap:stop()  end); leftMouseTap  = nil end
	if rightMouseTap then pcall(function() rightMouseTap:stop() end); rightMouseTap = nil end
	if leftClickHeld then
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp,  pos):post() end)
		leftClickHeld = false
		Logger.info(LOG, "Synthetic Left-Click forcefully released.")
	end
	if rightClickHeld then
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, pos):post() end)
		rightClickHeld = false
		Logger.info(LOG, "Synthetic Right-Click forcefully released.")
	end
end

--- Toggles a held synthetic right-click (press-and-hold, or release if held).
function M.toggle_right_click()
	if rightClickHeld then
		if rightMouseTap then pcall(function() rightMouseTap:stop() end); rightMouseTap = nil end
		pcall(function()
			hs.eventtap.event.newMouseEvent(
				hs.eventtap.event.types.rightMouseUp, hs.mouse.absolutePosition()
			):post()
		end)
		rightClickHeld = false
		Logger.info(LOG, "Synthetic Right-Click RELEASED.")
		if not leftClickHeld then stop_click_key_watcher() end
		return
	end

	Logger.debug(LOG, "Enabling right-click hold mode…")
	pcall(function()
		local ev = hs.eventtap.event.newMouseEvent(
			hs.eventtap.event.types.rightMouseDown, hs.mouse.absolutePosition()
		)
		-- HID-sourced so the event reaches title bars and WindowServer-managed areas.
		pcall(function() ev:setProperty(hs.eventtap.event.properties.eventSourceStateID, 1) end)
		ev:post()
	end)
	rightClickHeld = true
	start_click_key_watcher()

	local t0       = hs.timer.secondsSinceEpoch()
	local evTypes  = hs.eventtap.event.types
	rightMouseTap  = hs.eventtap.new({ evTypes.mouseMoved, evTypes.rightMouseUp }, function(e)
		if EventTapGuard.handle_disabled(e, rightMouseTap, "gestures.right_click") then return false end
		local t = e:getType()
		if t == evTypes.rightMouseUp then
			-- Swallow the spurious finger-lift mouseUp within the cooldown window.
			if hs.timer.secondsSinceEpoch() - t0 < CLICK_COOLDOWN_SEC then return true end
			-- Guard mirrors the left-click path: if rightClickHeld was already
			-- cleared by a concurrent key-down event before this callback fires,
			-- re-toggling would create a phantom hold.
			hs.timer.doAfter(0, function() if rightClickHeld then M.toggle_right_click() end end)
			return true
		end
		-- Convert idle mouseMoved to rightMouseDragged for apps that need it.
		if t == evTypes.mouseMoved then
			pcall(function()
				hs.eventtap.event.newMouseEvent(evTypes.rightMouseDragged, e:location()):post()
			end)
			return false
		end
		return false
	end)
	if rightMouseTap then pcall(function() rightMouseTap:start() end) end
	Logger.info(LOG, "Synthetic Right-Click HELD.")
end

--- Toggles a held synthetic left-click (press-and-hold, or release if held).
function M.toggle_left_click()
	if leftClickHeld then
		if leftMouseTap then pcall(function() leftMouseTap:stop() end); leftMouseTap = nil end
		pcall(function()
			hs.eventtap.event.newMouseEvent(
				hs.eventtap.event.types.leftMouseUp, hs.mouse.absolutePosition()
			):post()
		end)
		leftClickHeld = false
		Logger.info(LOG, "Synthetic Left-Click RELEASED.")
		if not rightClickHeld then stop_click_key_watcher() end
		return
	end

	Logger.debug(LOG, "Enabling left-click hold mode…")
	pcall(function()
		local ev = hs.eventtap.event.newMouseEvent(
			hs.eventtap.event.types.leftMouseDown, hs.mouse.absolutePosition()
		)
		-- HID-sourced so the event reaches title bars and WindowServer-managed areas.
		pcall(function() ev:setProperty(hs.eventtap.event.properties.eventSourceStateID, 1) end)
		ev:post()
	end)
	leftClickHeld = true
	start_click_key_watcher()

	local t0      = hs.timer.secondsSinceEpoch()
	local evTypes = hs.eventtap.event.types
	leftMouseTap  = hs.eventtap.new({ evTypes.mouseMoved, evTypes.leftMouseUp }, function(e)
		if EventTapGuard.handle_disabled(e, leftMouseTap, "gestures.left_click") then return false end
		local t = e:getType()
		if t == evTypes.leftMouseUp then
			-- Swallow the spurious finger-lift mouseUp within the cooldown window.
			if hs.timer.secondsSinceEpoch() - t0 < CLICK_COOLDOWN_SEC then return true end
			-- Guard: click_key_watcher may have already released leftClickHeld
			-- synchronously before this deferred callback fires (race window between
			-- the mouseUp eventtap and a concurrent key-down event). Re-toggling
			-- from a false state would silently re-engage the hold.
			hs.timer.doAfter(0, function() if leftClickHeld then M.toggle_left_click() end end)
			return true
		end
		-- Convert mouseMoved to leftMouseDragged so apps see a proper drag event.
		if t == evTypes.mouseMoved then
			pcall(function()
				hs.eventtap.event.newMouseEvent(evTypes.leftMouseDragged, e:location()):post()
			end)
			return false
		end
		return false
	end)
	if leftMouseTap then pcall(function() leftMouseTap:start() end) end
	Logger.info(LOG, "Synthetic Left-Click HELD.")
end

--- Releases any held synthetic click before a tap action fires, so a selection
--- started with a click-toggle is committed first. Shares the teardown path with
--- the toggles; the action name is logged to attribute the release.
--- @param name string The tap action name, used only for the release log line.
function M.release_held_for_tap(name)
	local pos = hs.mouse.absolutePosition()
	if leftClickHeld then
		if leftMouseTap then pcall(function() leftMouseTap:stop() end); leftMouseTap = nil end
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pos):post() end)
		leftClickHeld = false
		Logger.info(LOG, "Synthetic Left-Click RELEASED by tap action '%s'.", name)
	end
	if rightClickHeld then
		if rightMouseTap then pcall(function() rightMouseTap:stop() end); rightMouseTap = nil end
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, pos):post() end)
		rightClickHeld = false
		Logger.info(LOG, "Synthetic Right-Click RELEASED by tap action '%s'.", name)
	end
	if not leftClickHeld and not rightClickHeld then stop_click_key_watcher() end
end

--- @return boolean Whether a synthetic right-click is currently held.
function M.is_right_click_held()
	return rightClickHeld
end

return M
