--- modules/gestures/frame_clock.lua

--- ==============================================================================
--- MODULE: Gestures Frame Clock
--- DESCRIPTION:
--- Places each touch frame on the awake timeline at the moment the trackpad
--- captured it, not at the moment Lua processed it.
---
--- FEATURES & RATIONALE:
--- 1. Capture time, not delivery time — the touch device queues frames while the
---    Hammerspoon main thread is busy and then delivers them in one burst. Timed
---    at delivery, 35 frames held over 280 ms read as 2 ms, and the engine
---    refused a deliberate three-finger swipe as a one-frame palm spike.
--- 2. One timeline — the device stamp is anchored to the awake clock by the
---    smallest delivery delay seen, so a frame time never runs ahead of its
---    delivery and stays comparable with the engine's other awake readings.
--- 3. Re-anchoring — a stamp that runs backward (a device restarted) or lags its
---    delivery by more than MAX_LAG_SEC re-anchors on the delivery, so a reset
---    device clock can never freeze gesture time.
--- ==============================================================================

local M = {}





-- =========================================
-- =========================================
-- ======= 1/ Constants & Thresholds =======
-- =========================================
-- =========================================

-- Longest delivery delay a queued frame keeps its capture time for. A burst
-- after a main-thread stall of a few seconds stays exact; anything longer is a
-- device clock that stopped or jumped, and the delivery time is safer.
M.MAX_LAG_SEC = 10.0





-- =====================================
-- =====================================
-- ======= 2/ Clock Construction =======
-- =====================================
-- =====================================

--- Tells whether a value is a finite number.
--- @param value any
--- @return boolean
local function is_finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- Creates a frame clock with no anchor yet.
--- @return table clock { capture(stamp, delivered), reset() }
function M.new()
	local clock = {}
	local offset     = nil -- delivered - stamp, the smallest seen since the anchor
	local last_stamp = nil
	local last_time  = nil

	--- Returns the awake time at which a frame was captured.
	--- @param stamp number|nil Device timestamp of the frame, in seconds.
	--- @param delivered number Awake time at which the frame is processed.
	--- @return number time Capture time on the awake timeline, never after delivery.
	--- @return boolean anchored False when the stamp was unusable or re-anchored.
	function clock.capture(stamp, delivered)
		if not is_finite(delivered) then error("frame clock: the delivery time must be a finite number") end
		if not is_finite(stamp) then return delivered, false end
		local anchored = true
		local delay = delivered - stamp
		if offset == nil or (last_stamp ~= nil and stamp < last_stamp) then
			offset, anchored = delay, false
		elseif delay < offset then
			offset = delay
		elseif delay - offset > M.MAX_LAG_SEC then
			offset, anchored = delay, false
		end
		last_stamp = stamp
		local time = stamp + offset
		-- A smaller delay found after an earlier frame must not move time backward.
		if last_time ~= nil and time < last_time then time = last_time end
		last_time = time
		return time, anchored
	end

	--- Forgets the anchor, for a stopped engine or a new device.
	function clock.reset()
		offset, last_stamp, last_time = nil, nil, nil
	end

	return clock
end

return M
