--- modules/gestures/mt_decoder.lua

--- ==============================================================================
--- MODULE: Multitouch Frame Decoder
--- DESCRIPTION:
--- Turns a stream of decoded evdev events from a touchpad into completed
--- gestures: how many fingers, which direction, and whether it was a tap.
---
--- WHY THE DRIVER READS THE TOUCHPAD ITSELF RATHER THAN ASKING libinput:
--- libinput gates its entire gesture state machine on
---   `if (tp->gesture.finger_count <= 4) tp_gesture_handle_state(...)`
--- (src/evdev-mt-touchpad-gestures.c), so a five-finger swipe never becomes an
--- event — there is no LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN with finger_count 5,
--- on any version. Its documentation separately rules out taps beyond three
--- fingers, and taps leave it as BTN_LEFT/RIGHT/MIDDLE rather than as gestures.
--- Against the slots this project declares, libinput can serve at most sixteen
--- and none of the four taps. Every route built on it inherits that ceiling.
---
--- The kernel does not have that ceiling: it publishes the finger count directly
--- as BTN_TOOL_{FINGER,DOUBLETAP,TRIPLETAP,QUADTAP,QUINTTAP}, one bit at a time,
--- from input_mt_report_finger_count().
---
--- WHY THIS FILE IS PURE, WITH NO FFI AND NO FILE HANDLE:
--- Everything that needs real hardware — opening the device, the ioctl capability
--- probe, the read loop — lives in the adapter. What is left here is a state
--- machine over decoded events, which is the part that can be wrong in ways no
--- amount of hardware testing would reveal quickly, and the part a fixture can
--- pin exactly.
---
--- THE TWO RULES THAT ARE EASY TO GET WRONG:
--- 1. The finger count must be LATCHED AT ITS PEAK across the whole touch, never
---    read at the moment of lift. Fingers land and leave one at a time, so the
---    count walks up a ladder and back down: a three-finger swipe passes through
---    one and two on the way in and on the way out. Reading the instantaneous
---    value classifies most three-finger gestures as one-finger ones.
--- 2. With six or more fingers down, EVERY BTN_TOOL_* bit is 0 while BTN_TOUCH
---    stays 1. That is "unknown count", not "no fingers", and treating it as the
---    latter ends the gesture in the middle of it.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Event codes ======================
-- =============================================
-- =============================================

-- Event types, from include/uapi/linux/input-event-codes.h.
local EV_SYN = 0x00
local EV_KEY = 0x01
local EV_ABS = 0x03

-- SYN_REPORT ends a frame; SYN_DROPPED says the kernel discarded events because
-- this reader fell behind, and everything buffered must then be thrown away.
local SYN_REPORT  = 0
local SYN_DROPPED = 3

-- Multitouch axes. ABS_MT_SLOT selects which contact the following ABS_MT_*
-- values describe, and the driver omits it when the slot does not change — so the
-- current slot is a register that persists across events AND across frames.
local ABS_MT_SLOT        = 0x2f
local ABS_MT_POSITION_X  = 0x35
local ABS_MT_POSITION_Y  = 0x36
local ABS_MT_TRACKING_ID = 0x39

-- BTN_TOUCH is 1 whenever any finger is down.
local BTN_TOUCH = 0x14a

-- The finger-count bits. QUINTTAP is deliberately OUT of sequence — it was
-- retrofitted into a free code in 2011 — so it must never be computed as
-- DOUBLETAP + 3.
local FINGER_COUNT_CODES = {
	[0x145] = 1, -- BTN_TOOL_FINGER
	[0x14d] = 2, -- BTN_TOOL_DOUBLETAP
	[0x14e] = 3, -- BTN_TOOL_TRIPLETAP
	[0x14f] = 4, -- BTN_TOOL_QUADTAP
	[0x148] = 5, -- BTN_TOOL_QUINTTAP
}

M.EV_SYN, M.EV_KEY, M.EV_ABS = EV_SYN, EV_KEY, EV_ABS
M.SYN_REPORT, M.SYN_DROPPED = SYN_REPORT, SYN_DROPPED
M.ABS_MT_SLOT, M.ABS_MT_POSITION_X = ABS_MT_SLOT, ABS_MT_POSITION_X
M.ABS_MT_POSITION_Y, M.ABS_MT_TRACKING_ID = ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID
M.BTN_TOUCH = BTN_TOUCH
M.FINGER_COUNT_CODES = FINGER_COUNT_CODES

-- A gesture must travel at least this far, in device units, before it counts as a
-- swipe rather than a tap or a tremor. Device units are not millimetres and vary
-- per touchpad, so the adapter scales this by the device's reported resolution
-- when it has one; this value is the fallback for a device that reports none.
M.DEFAULT_SWIPE_THRESHOLD = 120

-- Beyond this ratio the movement is unambiguous on one axis. Below it the
-- gesture is diagonal, and this project's slot space has explicit diagonal
-- directions, so it is a real answer rather than a rejection.
M.DIAGONAL_RATIO = 2.0




-- =============================================
-- =============================================
-- ======= 2/ The state machine ================
-- =============================================
-- =============================================

--- Creates a decoder.
--- @param opts table|nil { swipe_threshold = number }
--- @return table
function M.new(opts)
	opts = opts or {}
	local threshold = tonumber(opts.swipe_threshold) or M.DEFAULT_SWIPE_THRESHOLD

	local decoder = {}

	-- Per-slot contact state, and the slot register the kernel expects us to keep.
	local _slots = {}
	local _current_slot = 0

	-- Whether any finger is down, and the highest finger count seen since the
	-- first one landed. The peak is the gesture's identity; see rule 1 above.
	local _touching = false
	local _peak_fingers = 0

	-- Where the gesture started, averaged across the contacts present at the time.
	local _origin_x, _origin_y = nil, nil
	local _last_x, _last_y = nil, nil

	--- Discards everything and returns to "no fingers down".
	local function reset()
		_slots = {}
		_current_slot = 0
		_touching = false
		_peak_fingers = 0
		_origin_x, _origin_y = nil, nil
		_last_x, _last_y = nil, nil
	end

	--- The mean position of every live contact, or nil when there is none.
	--- @return number|nil, number|nil
	local function centroid()
		local sum_x, sum_y, n = 0, 0, 0
		for _, slot in pairs(_slots) do
			if slot.id and slot.id >= 0 and slot.x and slot.y then
				sum_x, sum_y, n = sum_x + slot.x, sum_y + slot.y, n + 1
			end
		end
		if n == 0 then return nil, nil end
		return sum_x / n, sum_y / n
	end

	--- Names the direction of a displacement.
	---
	--- Y grows DOWNWARD in evdev, so a negative dy is "up". Getting that backwards
	--- inverts every vertical gesture and reads as the binding being wrong rather
	--- than the decoder.
	--- @param dx number
	--- @param dy number
	--- @return string|nil
	local function direction_of(dx, dy)
		local ax, ay = math.abs(dx), math.abs(dy)
		if ax < threshold and ay < threshold then return nil end

		if ax >= ay * M.DIAGONAL_RATIO then return dx > 0 and "right" or "left" end
		if ay >= ax * M.DIAGONAL_RATIO then return dy > 0 and "down" or "up" end

		local vertical = dy > 0 and "down" or "up"
		local horizontal = dx > 0 and "right" or "left"
		return vertical .. "_" .. horizontal
	end

	--- Feeds one decoded event.
	---
	--- @param event table { type, code, value } as infra/input_event.lua decodes it.
	--- @return table|nil A completed gesture { fingers, direction, tap }, or nil.
	function decoder:feed(event)
		if type(event) ~= "table" then return nil end
		local etype, code, value = event.type, event.code, event.value

		if etype == EV_ABS then
			if code == ABS_MT_SLOT then
				_current_slot = value
			else
				local slot = _slots[_current_slot]
				if not slot then slot = {} ; _slots[_current_slot] = slot end
				if code == ABS_MT_TRACKING_ID then
					slot.id = value
					-- -1 retires the slot. Its position is dropped with it so a stale
					-- coordinate cannot contribute to the next gesture's centroid.
					if value < 0 then slot.x, slot.y = nil, nil end
				elseif code == ABS_MT_POSITION_X then
					slot.x = value
				elseif code == ABS_MT_POSITION_Y then
					slot.y = value
				end
			end
			return nil
		end

		if etype == EV_KEY then
			local reported = FINGER_COUNT_CODES[code]
			if reported and value == 1 then
				-- Rule 1: the peak, never the instantaneous value.
				if reported > _peak_fingers then _peak_fingers = reported end
			elseif code == BTN_TOUCH then
				if value == 1 then
					_touching = true
				else
					_touching = false
				end
			end
			return nil
		end

		if etype ~= EV_SYN then return nil end

		if code == SYN_DROPPED then
			-- The kernel threw events away because this reader fell behind, so the
			-- slot state no longer describes the hand on the pad. Continuing would
			-- emit a gesture assembled from a mix of pre- and post-drop state — a
			-- three-finger swipe firing the five-finger action, intermittently, and
			-- only ever on a loaded machine.
			reset()
			return nil
		end

		if code ~= SYN_REPORT then return nil end

		local cx, cy = centroid()

		if _touching then
			if cx and cy then
				if not _origin_x then _origin_x, _origin_y = cx, cy end
				_last_x, _last_y = cx, cy
			end
			return nil
		end

		-- Every finger is up: the gesture, if there was one, is complete.
		if _peak_fingers == 0 then
			reset()
			return nil
		end

		local fingers = _peak_fingers
		local dx = (_last_x and _origin_x) and (_last_x - _origin_x) or 0
		local dy = (_last_y and _origin_y) and (_last_y - _origin_y) or 0
		local direction = direction_of(dx, dy)

		reset()

		if direction then
			return { fingers = fingers, direction = direction, tap = false }
		end
		-- No meaningful travel: a tap. Reported for every finger count the hardware
		-- can express, which is the half libinput cannot do at all.
		return { fingers = fingers, direction = nil, tap = true }
	end

	--- Throws away any partial gesture.
	function decoder:reset()
		reset()
	end

	--- Test seam: the peak count latched so far.
	--- @return integer
	function decoder:peak_fingers()
		return _peak_fingers
	end

	return decoder
end

return M
