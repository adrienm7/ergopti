--- tests/unit/gestures/engine/engine/test_resting_thumb_join.lua

--- ==============================================================================
--- MODULE: Regression — a resting thumb never makes a pair three fingers
---         (resting-thumb-join)
--- DESCRIPTION:
--- The Mac field report of 2026-11-05 saw a thumb resting about 60 mm from two
--- swiping fingers join them within the landing window (tab_close fired) and a
--- held tap with that thumb commit tap_3. The Linux decoder's join had the same
--- gap: a third contact became the gesture's count with no spatial check. The
--- decoder now asks the shared rule (_shared/gestures/engine/contact_join.lua),
--- which the macOS engine asks too, in millimetres from the pad's resolution.
--- ==============================================================================

local helpers = require("tests.helpers")

local Decoder = helpers.load_module("gestures.engine.mt_decoder")
local ContactJoin = require("gestures.engine.contact_join")

local EV_SYN, EV_KEY, EV_ABS = Decoder.EV_SYN, Decoder.EV_KEY, Decoder.EV_ABS
local BTN_TOOL = { [1] = 0x145, [2] = 0x14d, [3] = 0x14e, [4] = 0x14f, [5] = 0x148 }

-- A pad reporting 10 units per millimetre on both axes.
local UNITS_PER_MM = 10

-- Contacts as { slot, x, y, major } in device units: a pair 20 mm apart, a
-- ring finger beside it, the field's thumb 60 mm below, and a flat thumb near
-- the pair but twice a fingertip.
local INDEX      = { 0, 400, 500, 80 }
local MIDDLE     = { 1, 600, 500, 85 }
local RING       = { 2, 800, 500, 82 }
local FAR_THUMB  = { 2, 500, 1100, 90 }
local FLAT_THUMB = { 2, 500, 750, 170 }

--- Builds a frame player on a driven clock.
--- @param opts table|nil Decoder options; units_per_mm defaults to the pad's.
--- @return table player { frame, lift, result }
local function new_player(opts)
	local clock = 100.0
	local decoder_opts = { now_sec = function() return clock end, tap_max_sec = 0.7,
		units_per_mm = { x = UNITS_PER_MM, y = UNITS_PER_MM } }
	for key, value in pairs(opts or {}) do decoder_opts[key] = value end
	if decoder_opts.units_per_mm == false then decoder_opts.units_per_mm = nil end
	local decoder = Decoder.new(decoder_opts)
	local player, live, count = {}, {}, 0
	local function send(t, c, v)
		local out = decoder:feed({ type = t, code = c, value = v })
		if out then player.result = out end
	end

	--- Plays one frame with exactly these contacts, each moved by dy.
	--- @param contacts table Array of { slot, x, y, major }.
	--- @param dy number Offset along y.
	function player.frame(contacts, dy)
		local seen = {}
		for _, c in ipairs(contacts) do
			seen[c[1]] = true
			send(EV_ABS, Decoder.ABS_MT_SLOT, c[1])
			if not live[c[1]] then
				send(EV_ABS, Decoder.ABS_MT_TRACKING_ID, 700 + c[1])
				live[c[1]] = true
			end
			send(EV_ABS, Decoder.ABS_MT_POSITION_X, c[2])
			send(EV_ABS, Decoder.ABS_MT_POSITION_Y, c[3] + (dy or 0))
			send(EV_ABS, Decoder.ABS_MT_TOUCH_MAJOR, c[4])
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

	--- Lifts every contact.
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

--- Lands a pair, joins a third contact two frames later, and swipes all three up.
--- @param p table Player.
--- @param third table The joining contact.
local function pair_then_third_swipe(p, third)
	for _ = 1, 2 do p.frame({ INDEX, MIDDLE }, 0) end
	for i = 0, 20 do p.frame({ INDEX, MIDDLE, third }, -i * 20) end
	p.lift()
end

--- Holds three contacts still for a tap, then lifts.
--- @param p table Player.
--- @param contacts table The three contacts, landing together.
local function three_finger_tap(p, contacts)
	for _ = 1, 6 do p.frame(contacts, 0) end
	p.lift()
end

helpers.describe("mt decoder: a resting thumb never makes a pair three fingers (resting-thumb-join)", function()
	helpers.it("a far thumb joining a swiping pair keeps it a two-finger swipe", function()
		local p = new_player()
		pair_then_third_swipe(p, FAR_THUMB)
		helpers.assert_true(p.result ~= nil and p.result.fingers == 2 and p.result.direction == "up",
			"got " .. tostring(p.result and p.result.fingers))
	end)

	helpers.it("a held tap beside a far thumb is no three-finger tap", function()
		local p = new_player()
		three_finger_tap(p, { INDEX, MIDDLE, FAR_THUMB })
		helpers.assert_true(p.result == nil or p.result.fingers ~= 3,
			"got a " .. tostring(p.result and p.result.fingers) .. "-finger result")
	end)

	helpers.it("an oversized thumb joining near the pair is refused", function()
		local p = new_player()
		pair_then_third_swipe(p, FLAT_THUMB)
		helpers.assert_true(p.result ~= nil and p.result.fingers == 2,
			"got " .. tostring(p.result and p.result.fingers))
	end)

	helpers.it("three fingers of one hand still join, swipe and tap", function()
		local p = new_player()
		pair_then_third_swipe(p, RING)
		helpers.assert_true(p.result ~= nil and p.result.fingers == 3 and p.result.direction == "up")
		p.result = nil
		three_finger_tap(p, { INDEX, MIDDLE, RING })
		helpers.assert_true(p.result ~= nil and p.result.fingers == 3 and p.result.tap == true)
	end)

	helpers.it("judges the same millimetres as macOS through the pad's resolution", function()
		-- 60 mm at 10 units per mm is far; the same units at 40 per mm are 15 mm.
		helpers.assert_true(ContactJoin.MAX_FINGER_GAP_MM < 60)
		local p = new_player({ units_per_mm = { x = 40, y = 40 } })
		pair_then_third_swipe(p, { 2, 500, 1100, 82 })
		helpers.assert_true(p.result ~= nil and p.result.fingers == 3)
		helpers.assert_eq(pcall(Decoder.new, { units_per_mm = { x = 0, y = 10 } }), false)
	end)
end)
