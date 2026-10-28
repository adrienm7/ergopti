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
--- THE THREE RULES THAT ARE EASY TO GET WRONG:
--- 1. The finger count must be LATCHED AT ITS PEAK across the whole touch, never
---    read at the moment of lift. Fingers land and leave one at a time, so the
---    count walks up a ladder and back down: a three-finger swipe passes through
---    one and two on the way in and on the way out. Reading the instantaneous
---    value classifies most three-finger gestures as one-finger ones.
---    The peak must be HELD, though: a count only becomes the peak after
---    stable_frames consecutive frames, and a pair takes no further finger once
---    it has travelled or outlived its landing. Otherwise a palm grazing the pad
---    for one frame during a two-finger scroll made it a three-finger swipe.
--- 2. With six or more fingers down, EVERY BTN_TOOL_* bit is 0 while BTN_TOUCH
---    stays 1. That is "unknown count", not "no fingers", and treating it as the
---    latter ends the gesture in the middle of it.
--- 3. Travel is what the peak contacts covered TOGETHER: motion while fewer
---    fingers are down (the scroll before a late finger, the pair left after
---    one lifts) is not the swipe, and a three-finger gesture starting right
---    after a two-finger scroll is the user stopping it, not a swipe.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Direction = require("gestures.direction")

local LOG = "gestures.mt_decoder"




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

-- How long a touch may last and still be a tap, from the shared timings registry
-- so the three drivers cannot drift on it.
--
-- Without a ceiling, resting fingers on the pad and lifting them later is
-- indistinguishable from tapping: both travel no distance. The old engine had
-- this and a test pinned it — a two-second near-stationary hold must NOT fire a
-- tap — so it is carried here rather than lost with that engine.
local ok_timings, Timings = pcall(require, "infra.timings")
M.TAP_MAX_SEC = ok_timings and Timings.sec("gestures", "tap_max_ms") or nil
if not M.TAP_MAX_SEC then
	-- Loud, not defaulted. A missing key is a broken install, and inventing a
	-- ceiling here would make every driver disagree about what a tap is.
	Logger.error(LOG, "[gestures].tap_max_ms is unreadable — taps cannot be time-bounded.")
end

-- How a finger count becomes the gesture's, from the shared timings registry:
-- the frames it must hold, the landing window in which a pair may still take
-- more fingers, and how long after a two-finger scroll no larger gesture fires.
M.STABLE_FRAMES = ok_timings and Timings.count("gestures", "finger_join_frames") or nil
M.LANDING_SEC = ok_timings and Timings.sec("gestures", "multi_finger_landing_ms") or nil
M.SCROLL_GUARD_SEC = ok_timings and Timings.sec("gestures", "scroll_momentum_guard_ms") or nil




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
	assert(threshold > 0, "the swipe threshold must be a positive number of device units")

	-- Wall clock, injectable. Deliberately NOT os.clock(): its CPU time barely
	-- advances in an I/O-bound daemon, so a gesture held for seconds would report
	-- almost no elapsed time and be misclassified as a tap. That exact bug was
	-- found and fixed in the engine this decoder replaces.
	local now_sec = opts.now_sec
	if type(now_sec) ~= "function" then
		local ok_mono, Monotonic = pcall(require, "infra.monotonic")
		now_sec = ok_mono and Monotonic.now_sec or os.time
	end

	--- When a frame happened: the kernel's stamp on its SYN_REPORT. A busy
	--- daemon drains a backlog of queued events at once, and timing them when
	--- read measured a 400 ms landing or a one-second rest as no time at all.
	--- An event without a stamp (a replay) is timed when it is read.
	--- @param event table The SYN_REPORT event.
	--- @return number seconds
	local function frame_time(event)
		local stamp = event.timestamp_us
		if type(stamp) == "number" and stamp > 0 then return stamp / 1e6 end
		return now_sec()
	end
	local tap_max_sec = tonumber(opts.tap_max_sec) or M.TAP_MAX_SEC
	local stable_frames = tonumber(opts.stable_frames) or M.STABLE_FRAMES
	local landing_sec = tonumber(opts.landing_sec) or M.LANDING_SEC
	local scroll_guard_sec = tonumber(opts.scroll_guard_sec) or M.SCROLL_GUARD_SEC
	assert(type(stable_frames) == "number" and stable_frames >= 1,
		"[gestures].finger_join_frames must be a positive frame count")
	assert(type(landing_sec) == "number" and landing_sec >= 0,
		"[gestures].multi_finger_landing_ms must be a duration")
	assert(type(scroll_guard_sec) == "number" and scroll_guard_sec >= 0,
		"[gestures].scroll_momentum_guard_ms must be a duration")
	-- A pair that travelled a swipe's worth has scrolled.
	local landing_travel = threshold

	local decoder = {}

	-- Per-slot contact state, and the slot register the kernel expects us to keep.
	local _slots = {}
	local _current_slot = 0

	-- Whether any finger is down, and the highest finger count seen since the
	-- first one landed. The peak is the gesture's identity; see rule 1 above.
	local _touching = false
	local _peak_fingers = 0
	local _peak_since = nil

	-- The count the kernel reports now, and the run of frames it has held.
	local _count = 0
	local _run_count, _run_frames = 0, 0
	local _run_x, _run_y = nil, nil

	-- Travel the peak contacts covered together, and their previous centroid.
	local _travel_x, _travel_y = 0, 0
	local _prev_x, _prev_y = nil, nil
	local _late_join_refused = false
	-- A pair left travelling after the peak dropped: the gesture is a scroll.
	local _drop_x, _drop_y = nil, nil
	local _aborted = false

	-- When the last two-finger scroll ended; survives reset() on purpose.
	local _last_scroll_end_at = nil

	-- Where the gesture started, averaged across the contacts present at the time.
	local _origin_x, _origin_y = nil, nil
	local _last_x, _last_y = nil, nil

	-- When the first finger landed, so a hold can be told from a tap.
	local _started_at = nil
	local _dropping = false -- invalid queue contents through the next SYN_REPORT

	--- Discards everything and returns to "no fingers down".
	local function reset()
		_slots = {}
		_current_slot = 0
		_touching = false
		_peak_fingers = 0
		_peak_since = nil
		_count = 0
		_run_count, _run_frames = 0, 0
		_run_x, _run_y = nil, nil
		_travel_x, _travel_y = 0, 0
		_prev_x, _prev_y = nil, nil
		_late_join_refused = false
		_drop_x, _drop_y = nil, nil
		_aborted = false
		_origin_x, _origin_y = nil, nil
		_last_x, _last_y = nil, nil
		_started_at = nil
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

	--- Names the direction of a displacement through the classifier the macOS
	--- geometry uses too (_shared/lua/gestures/direction.lua), measured in this
	--- decoder's device units. The swipe threshold is the swipe minimum, and a
	--- diagonal needs the shared factor of it; this project's slot space has
	--- explicit diagonal directions, so a diagonal is a real answer.
	---
	--- Y grows DOWNWARD in evdev, so a negative dy is "up". Getting that backwards
	--- inverts every vertical gesture and reads as the binding being wrong rather
	--- than the decoder. The shared names put the horizontal part first
	--- (`swipe_3_left_up`), as _shared/modules/actions/actions.toml declares
	--- every slot: "up_right" would bind every diagonal silently to nothing.
	--- @param dx number
	--- @param dy number
	--- @return string|nil
	local function direction_of(dx, dy)
		return Direction.classify(dx, dy, threshold, threshold * Direction.DIAGONAL_MINIMUM_FACTOR)
	end

	--- Feeds one decoded event.
	---
	--- @param event table { type, code, value } as infra/input_event.lua decodes it.
	--- @return table|nil A completed gesture { fingers, direction, tap }, or nil.
	function decoder:feed(event)
		if type(event) ~= "table" then return nil end
		local etype, code, value = event.type, event.code, event.value
		if etype == EV_SYN and code == SYN_DROPPED then
			reset()
			_dropping = true
			return nil
		end
		-- event-codes.rst requires ignoring the whole packet after SYN_DROPPED.
		-- No slot, count or touch edge inside that packet can start a new gesture.
		if _dropping then
			if etype == EV_SYN and code == SYN_REPORT then _dropping = false end
			return nil
		end

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
				-- Rule 1: the count is judged per frame, at SYN_REPORT.
				_count = reported
			elseif reported and value == 0 then
				if _count == reported then _count = 0 end
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

		if code ~= SYN_REPORT then return nil end

		local cx, cy = centroid()

		if _touching then
			if cx and cy then
				local now = frame_time(event)
				if not _origin_x then
					_origin_x, _origin_y = cx, cy
					_started_at = now
				end
				_last_x, _last_y = cx, cy

				if _count ~= _run_count then
					if _peak_fingers >= 2 and _run_count > _peak_fingers and _run_frames < stable_frames then
						Logger.debug(LOG, "Three-finger candidate rejected by frames held: %d -> %d held %d frame(s) < %d.",
							_peak_fingers, _run_count, _run_frames, stable_frames)
					end
					_run_count, _run_frames = _count, 0
					_run_x, _run_y = cx, cy
				end
				_run_frames = _run_frames + 1

				if _count > _peak_fingers and _run_frames >= stable_frames then
					-- Rule 1: a pair that moved or outlived its landing is a scroll,
					-- and a finger joining it is a resting thumb or a palm.
					local since_landing = now - (_peak_since or now)
					local pair_travel = math.abs(_travel_x) + math.abs(_travel_y)
					local late = _peak_fingers >= 2
						and (since_landing > landing_sec or pair_travel >= landing_travel)
					if late then
						if not _late_join_refused then
							Logger.debug(LOG,
								"Three-finger candidate rejected by %s: %d -> %d, %.0f ms since landing (max %.0f), travel %.0f (max %.0f).",
								pair_travel >= landing_travel and "pair scroll" or "landing window",
								_peak_fingers, _count, since_landing * 1000, landing_sec * 1000,
								pair_travel, landing_travel)
							_late_join_refused = true
						end
					else
						_peak_fingers, _peak_since = _count, now
						_travel_x, _travel_y = cx - _run_x, cy - _run_y
						_prev_x, _prev_y = cx, cy
					end
				elseif _count == _peak_fingers and _peak_fingers > 0 then
					-- Rule 3: only frames where every peak contact is down travel.
					if _prev_x then
						_travel_x = _travel_x + (cx - _prev_x)
						_travel_y = _travel_y + (cy - _prev_y)
					end
					_prev_x, _prev_y = cx, cy
				else
					_prev_x, _prev_y = nil, nil
				end

				-- Fingers lifting one by one leave the rest still; a pair that
				-- travels on after the peak dropped is scrolling.
				if _peak_fingers >= 3 and _count == 2 then
					if not _drop_x then _drop_x, _drop_y = cx, cy end
					if math.abs(cx - _drop_x) + math.abs(cy - _drop_y) >= landing_travel then
						_aborted = true
					end
				else
					_drop_x, _drop_y = nil, nil
				end
			end
			return nil
		end

		-- Every finger is up: the gesture, if there was one, is complete.
		-- A contact held across loss can publish finger-count changes on lift,
		-- without another BTN_TOUCH down. Only a fresh observed start owns a tap.
		if _peak_fingers == 0 or _started_at == nil then
			reset()
			return nil
		end

		local fingers = _peak_fingers
		local dx, dy = _travel_x, _travel_y
		local direction = direction_of(dx, dy)
		local now = frame_time(event)
		local elapsed = (_started_at and now - _started_at) or 0
		local started_at = _started_at
		local aborted = _aborted

		reset()

		if aborted then
			Logger.debug(LOG, "%d-finger gesture continued as a scrolling pair; ignored.", fingers)
			_last_scroll_end_at = now
			return nil
		elseif fingers == 2 and direction then
			_last_scroll_end_at = now
		elseif fingers >= 3 and _last_scroll_end_at
			and started_at - _last_scroll_end_at < scroll_guard_sec then
			-- Rule 3: fingers landing to stop a scroll's momentum.
			Logger.debug(LOG, "Three-finger candidate rejected by scroll guard: %d fingers %.0f ms after a two-finger scroll < %.0f ms.",
				fingers, (started_at - _last_scroll_end_at) * 1000, scroll_guard_sec * 1000)
			return nil
		end

		if direction then
			-- A swipe is a swipe however long it took: someone dragging slowly
			-- across the pad means it, and a ceiling here would drop the gesture
			-- they were halfway through.
			return { fingers = fingers, direction = direction, tap = false }
		end

		-- No meaningful travel. That is a tap only if it was BRIEF — otherwise it
		-- is fingers resting on the pad, which travels no distance either. Without
		-- this, putting a hand down and lifting it later fires whatever tap_N is
		-- bound to.
		if not tap_max_sec then
			-- Fail closed: without a ceiling a rest is indistinguishable from a
			-- tap, so nothing may fire. Reporting tap=true here would fire
			-- tap_N for fingers merely resting on the pad.
			return nil
		end
		if elapsed > tap_max_sec then
			return nil
		end

		-- Reported for every finger count the hardware can express, which is the
		-- half libinput cannot do at all.
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

	--- Test seam: the finger count the kernel reports right now. Unlike the
	--- peak, it needs no stable run of frames.
	--- @return integer
	function decoder:fingers_down()
		return _count
	end

	return decoder
end

return M
