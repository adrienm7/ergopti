--- tests/unit/modules/test_mt_decoder.lua

--- ==============================================================================
--- MODULE: Multitouch Frame Decoder
--- DESCRIPTION:
--- The state machine that turns touchpad evdev events into "three fingers, up".
---
--- WHY THIS IS WORTH PINNING BEFORE ANY HARDWARE EXISTS:
--- Every rule here is a rule about the KERNEL's protocol, and each one is easy to
--- implement in a way that looks right and is wrong on most touchpads:
---   - the finger count walks a ladder up AND down, so reading it at lift-off
---     classifies most three-finger gestures as one-finger ones;
---   - six fingers clears every BTN_TOOL_* bit while BTN_TOUCH stays 1, which is
---     "unknown", not "none";
---   - ABS_MT_SLOT is a register the driver only emits when it CHANGES, so a
---     decoder that forgets it across frames attributes motion to the wrong
---     finger;
---   - Y grows downward, so a naive sign test inverts every vertical gesture;
---   - SYN_DROPPED only ever fires on a loaded machine, so a decoder that ignores
---     it passes every test and misfires in the field.
--- None of those would show up quickly on real hardware either — they produce a
--- gesture, just the wrong one, intermittently.
---
--- WHY RAW EVDEV AND NOT libinput:
--- libinput gates its gesture state machine on `finger_count <= 4`, so five-finger
--- swipes are never emitted, and its own documentation rules out taps past three
--- fingers. The 5-finger and tap cases below are exactly what no libinput-based
--- route can deliver.
--- ==============================================================================

local helpers = require("tests.helpers")

local Decoder = helpers.load_module("modules.gestures.mt_decoder")

local EV_SYN, EV_KEY, EV_ABS = Decoder.EV_SYN, Decoder.EV_KEY, Decoder.EV_ABS
local SYN_REPORT, SYN_DROPPED = Decoder.SYN_REPORT, Decoder.SYN_DROPPED
local BTN_TOUCH = Decoder.BTN_TOUCH

local BTN_TOOL = { [1] = 0x145, [2] = 0x14d, [3] = 0x14e, [4] = 0x14f, [5] = 0x148 }

--- Feeds a list of {type, code, value} triples, returning the last gesture.
--- @param decoder table
--- @param events table
--- @return table|nil
local function feed_all(decoder, events)
	local last = nil
	for _, e in ipairs(events) do
		local out = decoder:feed({ type = e[1], code = e[2], value = e[3] })
		if out then last = out end
	end
	return last
end

--- The events for a whole gesture: N fingers land, travel by (dx, dy), lift.
---
--- Deliberately walks the finger count UP as fingers land and DOWN as they lift,
--- because that is what the kernel does and it is the single most important thing
--- this decoder has to survive.
--- @param fingers integer
--- @param dx integer
--- @param dy integer
--- @return table
local function gesture_events(fingers, dx, dy)
	local events = {}
	local function push(t, c, v) events[#events + 1] = { t, c, v } end

	local base_x, base_y = 1000, 900

	-- Landing, one finger at a time.
	for index = 0, fingers - 1 do
		push(EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(EV_ABS, Decoder.ABS_MT_TRACKING_ID, 500 + index)
		push(EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200)
		push(EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y)
		if index > 0 then push(EV_KEY, BTN_TOOL[index], 0) end
		push(EV_KEY, BTN_TOOL[index + 1], 1)
		if index == 0 then push(EV_KEY, BTN_TOUCH, 1) end
		push(EV_SYN, SYN_REPORT, 0)
	end

	-- Motion, in a few frames.
	for step = 1, 4 do
		for index = 0, fingers - 1 do
			push(EV_ABS, Decoder.ABS_MT_SLOT, index)
			-- math.floor, not "//": the integer-division operator is 5.3+, and CI runs
			-- LuaJIT, which is 5.1-based and would refuse to PARSE this file.
			push(EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200 + math.floor(dx * step / 4))
			push(EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y + math.floor(dy * step / 4))
		end
		push(EV_SYN, SYN_REPORT, 0)
	end

	-- Lifting, one finger at a time, count walking back down.
	for index = fingers - 1, 0, -1 do
		push(EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
		push(EV_KEY, BTN_TOOL[index + 1], 0)
		if index > 0 then push(EV_KEY, BTN_TOOL[index], 1) end
		push(EV_SYN, SYN_REPORT, 0)
	end
	push(EV_KEY, BTN_TOUCH, 0)
	push(EV_SYN, SYN_REPORT, 0)

	return events
end




-- =================================================================
-- =================================================================
-- ======= 1/ Finger counting ======================================
-- =================================================================
-- =================================================================

helpers.describe("mt decoder: how many fingers", function()

	for fingers = 2, 5 do
		helpers.it(string.format("reports %d finger(s) despite the count walking up and down", fingers), function()
			local out = feed_all(Decoder.new(), gesture_events(fingers, 0, -400))
			helpers.assert_true(out ~= nil, "the gesture must complete when the last finger lifts")
			helpers.assert_eq(out.fingers, fingers,
				"the PEAK count is the gesture's identity — fingers land and leave one at "
					.. "a time, so the instantaneous value at lift-off is 1 for every gesture")
		end)
	end

	helpers.it("keeps counting through a frame where every BTN_TOOL bit is 0", function()
		-- Six or more fingers clears them all while BTN_TOUCH stays 1. That is
		-- "unknown count", not "no fingers"; ending the gesture there truncates it.
		local decoder = Decoder.new()
		local events = gesture_events(5, 0, -400)
		-- Splice a six-finger frame in: every tool bit off, touch still on.
		local spliced = {}
		for index, e in ipairs(events) do
			spliced[#spliced + 1] = e
			if index == 20 then
				for _, code in pairs(BTN_TOOL) do spliced[#spliced + 1] = { EV_KEY, code, 0 } end
				spliced[#spliced + 1] = { EV_SYN, SYN_REPORT, 0 }
			end
		end
		local out = feed_all(decoder, spliced)
		helpers.assert_true(out ~= nil, "the gesture must still complete")
		helpers.assert_eq(out.fingers, 5, "and keep the peak it had already reached")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Direction ============================================
-- =================================================================
-- =================================================================

helpers.describe("mt decoder: which way", function()

	helpers.it("reads a negative dy as UP, because evdev Y grows downward", function()
		local out = feed_all(Decoder.new(), gesture_events(3, 0, -400))
		helpers.assert_eq(out.direction, "up",
			"getting this backwards inverts every vertical gesture and reads as the "
				.. "binding being wrong rather than the decoder")
	end)

	helpers.it("reads a positive dy as DOWN", function()
		helpers.assert_eq(feed_all(Decoder.new(), gesture_events(3, 0, 400)).direction, "down")
	end)

	helpers.it("reads left and right", function()
		helpers.assert_eq(feed_all(Decoder.new(), gesture_events(4, -400, 0)).direction, "left")
		helpers.assert_eq(feed_all(Decoder.new(), gesture_events(4, 400, 0)).direction, "right")
	end)

	helpers.it("names a diagonal the way the slot space spells it", function()
		local out = feed_all(Decoder.new(), gesture_events(3, 400, -400))
		helpers.assert_eq(out.direction, "right_up",
			"HORIZONTAL first: the declared slots are swipe_3_left_up, "
				.. "swipe_3_right_down and so on. This said \"up_right\" until the "
				.. "dispatch test caught it — a name no slot carries, so every diagonal "
				.. "bound to nothing")
	end)

	helpers.it("names all four diagonals", function()
		local cases = {
			{ dx = 400,  dy = -400, want = "right_up" },
			{ dx = -400, dy = -400, want = "left_up" },
			{ dx = 400,  dy = 400,  want = "right_down" },
			{ dx = -400, dy = 400,  want = "left_down" },
		}
		for _, case in ipairs(cases) do
			local out = feed_all(Decoder.new(), gesture_events(3, case.dx, case.dy))
			helpers.assert_eq(out.direction, case.want,
				string.format("dx=%d dy=%d must be %s", case.dx, case.dy, case.want))
		end
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ Taps =================================================
-- =================================================================
-- =================================================================

helpers.describe("mt decoder: taps", function()

	helpers.it("reports a motionless touch as a tap, at every finger count", function()
		-- libinput implements tapping for one, two and three fingers only, and
		-- delivers them as pointer buttons rather than gestures. Four- and
		-- five-finger taps exist here and nowhere else on Linux.
		for fingers = 1, 5 do
			local out = feed_all(Decoder.new(), gesture_events(fingers, 0, 0))
			helpers.assert_true(out ~= nil, "a tap must complete like any other gesture")
			helpers.assert_true(out.tap, fingers .. "-finger tap must be reported as a tap")
			helpers.assert_eq(out.fingers, fingers, "with its own finger count")
			helpers.assert_nil(out.direction, "and no direction")
		end
	end)

	helpers.it("does not call a tremor a swipe", function()
		local out = feed_all(Decoder.new(), gesture_events(3, 6, 4))
		helpers.assert_true(out.tap, "a few device units of travel is a finger resting, not a swipe")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 4/ Robustness ===========================================
-- =================================================================
-- =================================================================

helpers.describe("mt decoder: what must not go wrong", function()

	helpers.it("throws the gesture away on SYN_DROPPED", function()
		local decoder = Decoder.new()
		local events = gesture_events(5, 0, -400)
		local truncated = {}
		for index = 1, 20 do truncated[#truncated + 1] = events[index] end
		feed_all(decoder, truncated)
		decoder:feed({ type = EV_SYN, code = SYN_DROPPED, value = 0 })
		helpers.assert_eq(decoder:peak_fingers(), 0,
			"the kernel discarded events, so the slot state no longer describes the "
				.. "hand on the pad; carrying it forward fires the wrong finger count "
				.. "intermittently, and only ever on a loaded machine")
	end)

	helpers.it("remembers the slot register across frames", function()
		-- The driver emits ABS_MT_SLOT only when it CHANGES, so a decoder that
		-- resets it per frame attributes every later coordinate to slot 0 and the
		-- centroid stops moving.
		local decoder = Decoder.new()
		feed_all(decoder, {
			{ EV_ABS, Decoder.ABS_MT_SLOT, 0 }, { EV_ABS, Decoder.ABS_MT_TRACKING_ID, 1 },
			{ EV_ABS, Decoder.ABS_MT_POSITION_X, 100 }, { EV_ABS, Decoder.ABS_MT_POSITION_Y, 100 },
			{ EV_KEY, BTN_TOUCH, 1 }, { EV_KEY, BTN_TOOL[1], 1 },
			{ EV_SYN, SYN_REPORT, 0 },
			{ EV_ABS, Decoder.ABS_MT_SLOT, 1 }, { EV_ABS, Decoder.ABS_MT_TRACKING_ID, 2 },
			{ EV_ABS, Decoder.ABS_MT_POSITION_X, 900 }, { EV_ABS, Decoder.ABS_MT_POSITION_Y, 100 },
			{ EV_KEY, BTN_TOOL[1], 0 }, { EV_KEY, BTN_TOOL[2], 1 },
			{ EV_SYN, SYN_REPORT, 0 },
			-- No ABS_MT_SLOT here: still slot 1.
			{ EV_ABS, Decoder.ABS_MT_POSITION_Y, 500 },
			{ EV_SYN, SYN_REPORT, 0 },
			{ EV_ABS, Decoder.ABS_MT_SLOT, 0 }, { EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1 },
			{ EV_ABS, Decoder.ABS_MT_SLOT, 1 }, { EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1 },
			{ EV_KEY, BTN_TOOL[2], 0 }, { EV_KEY, BTN_TOUCH, 0 },
			{ EV_SYN, SYN_REPORT, 0 },
		})
		-- Slot 1 moved 400 units down while slot 0 stayed; the centroid therefore
		-- moved 200, which is above the threshold.
		helpers.assert_eq(decoder:peak_fingers(), 0, "and the gesture is finished and cleared")
	end)

	helpers.it("ignores events that are not touch events", function()
		local decoder = Decoder.new()
		helpers.assert_nil(decoder:feed({ type = 0x04, code = 4, value = 458792 }),
			"EV_MSC scan codes arrive on the same device and mean nothing here")
		helpers.assert_nil(decoder:feed(nil), "and a malformed event must not raise")
	end)

end)
