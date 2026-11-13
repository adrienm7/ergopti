--- tests/unit/gestures/engine/engine/test_decoder_millimetres.lua

--- ==============================================================================
--- MODULE: Regression — the decoder's distances are millimetres (gsd2-decoder-mm)
--- DESCRIPTION:
--- GSD-2 (decided by the maintainer on 2026-11-11): the Linux decoder's swipe
--- minimum and pair-scroll travel were 120 device units, about 10 mm on a pad
--- of 12 units per mm and 4 mm on one of 30, while the incremental tracker
--- counted millimetres. Both are now millimetres through the pad's resolution,
--- read from the shared timings registry ([gestures]
--- decoder_swipe_minimum_mm, pair_scroll_travel_mm).
--- ==============================================================================

local helpers = require("tests.helpers")

local Decoder = helpers.load_module("gestures.engine.mt_decoder")

local EV_SYN, EV_KEY, EV_ABS = Decoder.EV_SYN, Decoder.EV_KEY, Decoder.EV_ABS
local BTN_TOOL = { [1] = 0x145, [2] = 0x14d, [3] = 0x14e }

--- A frame player over contacts { slot, x, y } on a driven clock.
--- @param units number Device units per millimetre of the pad.
--- @return table player
local function new_player(units)
	local clock = 100.0
	local decoder = Decoder.new({ now_sec = function() return clock end, tap_max_sec = 0.7,
		units_per_mm = { x = units, y = units } })
	local player, live, count = {}, {}, 0
	local function send(t, c, v)
		local out = decoder:feed({ type = t, code = c, value = v })
		if out then player.result = out end
	end
	function player.frame(contacts)
		local seen = {}
		for _, c in ipairs(contacts) do
			seen[c[1]] = true
			send(EV_ABS, Decoder.ABS_MT_SLOT, c[1])
			if not live[c[1]] then send(EV_ABS, Decoder.ABS_MT_TRACKING_ID, 900 + c[1]); live[c[1]] = true end
			send(EV_ABS, Decoder.ABS_MT_POSITION_X, c[2])
			send(EV_ABS, Decoder.ABS_MT_POSITION_Y, c[3])
		end
		for slot in pairs(live) do
			if not seen[slot] then
				send(EV_ABS, Decoder.ABS_MT_SLOT, slot)
				send(EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
				live[slot] = nil
			end
		end
		if #contacts ~= count then
			if count > 0 then send(EV_KEY, BTN_TOOL[count], 0) end
			send(EV_KEY, BTN_TOOL[#contacts], 1)
			if count == 0 then send(EV_KEY, Decoder.BTN_TOUCH, 1) end
			count = #contacts
		end
		send(EV_SYN, Decoder.SYN_REPORT, 0)
		clock = clock + 0.008
	end
	function player.lift()
		for slot in pairs(live) do
			send(EV_ABS, Decoder.ABS_MT_SLOT, slot)
			send(EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
		end
		live = {}
		if count > 0 then send(EV_KEY, BTN_TOOL[count], 0) end
		count = 0
		send(EV_KEY, Decoder.BTN_TOUCH, 0)
		send(EV_SYN, Decoder.SYN_REPORT, 0)
		clock = clock + 0.008
	end
	return player
end

--- Three fingers of one hand, `units` units per mm apart about 15 mm, moved right.
local function three_finger_swipe(p, units, travel_mm)
	local steps = 10
	for i = 0, steps do
		local dx = math.floor(travel_mm * units * i / steps + 0.5)
		p.frame({ { 0, 40 * units + dx, 50 * units }, { 1, 55 * units + dx, 50 * units },
			{ 2, 70 * units + dx, 50 * units } })
	end
	p.lift()
end

helpers.describe("mt decoder: distances in millimetres through the resolution (gsd2-decoder-mm)", function()
	helpers.it("reads the swipe minimum and the pair-scroll travel from the shared registry (gsd2-decoder-mm)", function()
		local Timings = require("core.timing.engine.timings")
		helpers.assert_eq(Decoder.SWIPE_MINIMUM_MM, Timings.count("gestures", "decoder_swipe_minimum_mm"))
		helpers.assert_eq(Decoder.PAIR_SCROLL_TRAVEL_MM, Timings.count("gestures", "pair_scroll_travel_mm"))
		helpers.assert_eq(Decoder.DEFAULT_SWIPE_THRESHOLD, nil, "no swipe threshold in device units is left")
	end)

	helpers.it("needs the same millimetres of swipe on a coarse and a fine pad (gsd2-decoder-mm)", function()
		local short = Decoder.SWIPE_MINIMUM_MM * 0.6
		local long = Decoder.SWIPE_MINIMUM_MM * 1.5
		for _, units in ipairs({ 12, 30 }) do
			local p = new_player(units)
			three_finger_swipe(p, units, short)
			helpers.assert_true(p.result == nil or p.result.direction == nil,
				string.format("%.1f mm on a pad of %d units per mm must not be a swipe", short, units))
			p.result = nil
			three_finger_swipe(p, units, long)
			helpers.assert_true(p.result ~= nil and p.result.fingers == 3 and p.result.direction == "right",
				string.format("%.1f mm on a pad of %d units per mm is a right swipe", long, units))
		end
	end)

	helpers.it("lets a finger join a pair that moved less than the scroll travel in mm (gsd2-decoder-mm)", function()
		-- 6 mm of pair travel on a 30 units/mm pad is 180 units: more than the
		-- former 120-unit limit, less than the shared millimetre travel.
		local units, travel = 30, Decoder.PAIR_SCROLL_TRAVEL_MM * 0.6
		local p = new_player(units)
		for i = 0, 3 do
			local dx = math.floor(travel * units * i / 3 + 0.5)
			p.frame({ { 0, 40 * units + dx, 50 * units }, { 1, 55 * units + dx, 50 * units } })
		end
		local moved = math.floor(travel * units + 0.5)
		for i = 0, 20 do
			local dx = moved + i * 2 * units
			p.frame({ { 0, 40 * units + dx, 50 * units }, { 1, 55 * units + dx, 50 * units },
				{ 2, 70 * units + dx, 50 * units } })
		end
		p.lift()
		helpers.assert_true(p.result ~= nil and p.result.fingers == 3,
			"a pair that moved 6 mm is still landing: got " .. tostring(p.result and p.result.fingers) .. " fingers")
	end)
end)
