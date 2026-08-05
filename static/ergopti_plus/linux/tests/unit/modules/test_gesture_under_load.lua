--- tests/unit/modules/test_gesture_under_load.lua

--- ==============================================================================
--- MODULE: The Two Things That Only Go Wrong on a Busy Machine
--- DESCRIPTION:
--- The drain bound and the dropped-frame reset — the two gesture risks the audit
--- left open because both are load-dependent, which is exactly why neither had a
--- test.
---
--- WHY THEY WERE LEFT OPEN, AND WHY THAT WAS THE WRONG CALL:
--- "Only reproduces under load" was read as "only testable under load". It is
--- not. What load DOES is change the arithmetic — how many events a drain sees,
--- whether the kernel discards a frame — and arithmetic can be stated. Both
--- cases below feed the decoder exactly what a loaded kernel would hand it and
--- assert the outcome, on any machine, in a millisecond.
---
--- 1. MAX_EVENTS_PER_DRAIN = 256 was sized for keyboard autorepeat. A touchpad
---    frame is far larger than a keystroke, and the question was whether
---    sustained five-finger movement could saturate the bound and leave the
---    gesture trailing the hand. The answer is derived here from the decoder's
---    own vocabulary rather than assumed, so a future frame that grows — a
---    pressure axis, a tilt axis — moves the number and this test says so.
---
--- 2. SYN_DROPPED means the kernel threw events away because this process was
---    not reading fast enough. The slot state left behind describes a hand that
---    is no longer on the pad. The decoder resets on it, and that reset is
---    already pinned; what was NOT pinned is the failure the audit actually
---    predicted — that the NEXT gesture inherits the stale count, so a
---    three-finger swipe intermittently fires the five-finger action.
---
--- WHAT ONLY HARDWARE CAN SAY: whether a real kernel under a real compositor
--- ever drops a frame at all. HARDWARE.md keeps that observation.
--- ==============================================================================

local helpers = require("tests.helpers")

local Decoder = helpers.load_module("modules.gestures.mt_decoder")
local Reader  = helpers.load_module("adapters.evdev_reader")

local BTN_TOUCH = 0x14a
local TOOL = { [1] = 0x145, [2] = 0x14d, [3] = 0x14e, [4] = 0x14f, [5] = 0x148 }

-- What a touchpad reports, in seconds between frames. 125 Hz is the common rate
-- for the class; a slower pad only ever helps.
local FRAME_INTERVAL_SEC = 0.008

-- How long the event loop may be starved before the bound stops covering the
-- backlog. The loop sleeps ~1 ms per iteration, so this is two orders of
-- magnitude beyond its nominal cadence — the margin, not the target.
local STARVATION_BUDGET_SEC = 0.100

--- The events one frame of sustained N-finger movement carries.
---
--- Derived, not counted by hand: each moving finger needs its slot selected and
--- both coordinates restated, and the frame ends with one SYN_REPORT. A future
--- axis added to the decoder changes this and the assertions move with it.
--- @param fingers integer
--- @return integer
local function events_per_frame(fingers)
	local per_finger = 3  -- ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y
	return fingers * per_finger + 1
end

--- A whole gesture as the kernel would deliver it, with `steps` movement frames.
--- @param fingers integer
--- @param dy integer
--- @param steps integer
--- @return table
local function gesture_events(fingers, dy, steps)
	local events = {}
	local function push(t, c, v) events[#events + 1] = { type = t, code = c, value = v } end
	local base_x, base_y = 1000, 900

	for index = 0, fingers - 1 do
		push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_TRACKING_ID, 500 + index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200)
		push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y)
		if index > 0 then push(Decoder.EV_KEY, TOOL[index], 0) end
		push(Decoder.EV_KEY, TOOL[index + 1], 1)
		if index == 0 then push(Decoder.EV_KEY, BTN_TOUCH, 1) end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end

	for step = 1, steps do
		for index = 0, fingers - 1 do
			push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
			push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200)
			push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y + math.floor(dy * step / steps))
		end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end

	for index = fingers - 1, 0, -1 do
		push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
		push(Decoder.EV_KEY, TOOL[index + 1], 0)
		if index > 0 then push(Decoder.EV_KEY, TOOL[index], 1) end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end
	push(Decoder.EV_KEY, BTN_TOUCH, 0)
	push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)

	return events
end

--- Feeds a list and returns every gesture the decoder emitted.
--- @param decoder table
--- @param events table
--- @return table
local function feed(decoder, events)
	local out = {}
	for _, event in ipairs(events) do
		local gesture = decoder:feed(event)
		if gesture then out[#out + 1] = gesture end
	end
	return out
end




-- =================================================================
-- =================================================================
-- ======= 1/ The drain bound has real headroom ====================
-- =================================================================
-- =================================================================

helpers.describe("gesture load: MAX_EVENTS_PER_DRAIN", function()

	helpers.it("covers a full frame of the widest gesture many times over", function()
		local widest = events_per_frame(5)
		helpers.assert_true(Reader.MAX_EVENTS_PER_DRAIN >= widest * 8,
			string.format(
				"one five-finger frame is %d events and the bound is %d. A bound that "
					.. "cannot hold several frames makes the gesture trail the hand, "
					.. "because each drain returns to a loop that sleeps before reading "
					.. "the rest.",
				widest, Reader.MAX_EVENTS_PER_DRAIN))
	end)

	helpers.it("still covers the backlog of a starved loop", function()
		local frames = math.floor(STARVATION_BUDGET_SEC / FRAME_INTERVAL_SEC)
		local backlog = frames * events_per_frame(5)
		helpers.assert_true(Reader.MAX_EVENTS_PER_DRAIN >= backlog,
			string.format(
				"%d ms of starvation is %d frames, %d events; the bound is %d. This is "
					.. "the margin the sizing has, not the case it was sized for — the "
					.. "loop sleeps about a millisecond per iteration, so reaching this "
					.. "means something else held the CPU for a hundred times that.",
				STARVATION_BUDGET_SEC * 1000, frames, backlog, Reader.MAX_EVENTS_PER_DRAIN))
	end)

	helpers.it("decodes a gesture split across two drains", function()
		-- The bound is a yield point, not a boundary: the decoder is fed
		-- incrementally and must carry its state across the gap. If it did not, a
		-- gesture long enough to span two drains would be lost exactly when the
		-- machine is busiest, which is when the user is least able to tell why.
		local events = gesture_events(3, -600, 40)
		helpers.assert_true(#events > Reader.MAX_EVENTS_PER_DRAIN,
			"the fixture must actually exceed one drain, or this asserts nothing")

		local decoder = Decoder.new()
		local first, second = {}, {}
		for index, event in ipairs(events) do
			if index <= Reader.MAX_EVENTS_PER_DRAIN then
				first[#first + 1] = event
			else
				second[#second + 1] = event
			end
		end

		helpers.assert_eq(#feed(decoder, first), 0, "no gesture before the fingers lift")
		local emitted = feed(decoder, second)
		helpers.assert_eq(#emitted, 1, "and exactly one once they do")
		helpers.assert_eq(emitted[1].fingers, 3)
		helpers.assert_eq(emitted[1].direction, "up")
	end)

end)





-- ===================================================================
-- ===================================================================
-- ======= 2/ A dropped frame does not poison the next gesture =======
-- ===================================================================
-- ===================================================================

helpers.describe("gesture load: SYN_DROPPED", function()

	helpers.it("does not let a five-finger touch become the next swipe's count", function()
		-- The exact failure the audit predicted: five fingers down, the kernel
		-- discards events, the user then swipes with three — and the stale peak
		-- makes it fire the five-finger action. Intermittent, load-only, and
		-- indistinguishable from a misread gesture when it happens.
		local decoder = Decoder.new()

		local interrupted = gesture_events(5, -600, 4)
		local partial = {}
		for index = 1, 24 do partial[#partial + 1] = interrupted[index] end
		feed(decoder, partial)
		helpers.assert_true(decoder:peak_fingers() > 0, "the fixture really did put fingers down")

		decoder:feed({ type = Decoder.EV_SYN, code = Decoder.SYN_DROPPED, value = 0 })

		local emitted = feed(decoder, gesture_events(3, -600, 4))
		helpers.assert_eq(#emitted, 1, "the gesture after the drop is decoded normally")
		helpers.assert_eq(emitted[1].fingers, 3,
			"three fingers on the pad must be three fingers in the gesture, whatever "
				.. "the kernel discarded before it")
	end)

	helpers.it("emits nothing for the gesture the drop interrupted", function()
		local decoder = Decoder.new()
		local events = gesture_events(4, -600, 4)

		local emitted = {}
		for index, event in ipairs(events) do
			-- Dropped one frame before the fingers lift, which is the worst moment:
			-- everything needed to name the gesture has been seen, so a decoder that
			-- kept its state would emit a gesture the user never completed.
			if index == #events - 6 then
				decoder:feed({ type = Decoder.EV_SYN, code = Decoder.SYN_DROPPED, value = 0 })
			end
			local gesture = decoder:feed(event)
			if gesture then emitted[#emitted + 1] = gesture end
		end

		helpers.assert_eq(#emitted, 0,
			"the events that would have named it are the events the kernel threw "
				.. "away — acting on what is left is guessing, and a wrong action is "
				.. "worse than none")
	end)

end)
