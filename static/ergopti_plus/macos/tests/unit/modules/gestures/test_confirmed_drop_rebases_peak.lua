--- tests/unit/modules/gestures/test_confirmed_drop_rebases_peak.lua

--- ==============================================================================
--- MODULE: Regression — a confirmed finger drop must outrank the peak override
---         (confirmed-drop-rebases-peak)
--- DESCRIPTION:
--- Lifting one finger mid-gesture and continuing with three still fired the
--- FOUR-finger action. Two mechanisms that were each correct in isolation
--- disagreed at commit time.
---
--- ROOT CAUSE ENCODED: the confirmed finger-drop demotes maxFingers to the new
--- count — it spends several frames, or a full confirm window, establishing that
--- the user really did change finger count rather than flicker. But it demoted
--- maxFingers ALONE. peakN kept holding the abandoned count, and the peak
--- override at commit re-promotes any sustained peak above maxFingers, so it
--- undid the demotion the engine had just spent frames confirming.
---
--- The peak override exists to recover intent when a finger lifts a frame or two
--- early, before the drop can confirm. It was never meant to outrank a drop that
--- DID confirm — once confirmed, that count IS the intent, and the peak must be
--- rebased onto it exactly as the fast-path join branch already rebases it.
---
--- WHY IT WAS SILENT: the override logs at INFO and reads like a success
--- ("PEAK OVERRIDE — using peakN=4 … over maxFingers=3"), so the log confirms
--- the wrong decision instead of flagging it. The user just sees the wrong
--- action, on a gesture they performed deliberately.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The contacts never move. A travelling gesture fires its action LIVE, per
-- step, while the fingers are still down — so the four-finger action would fire
-- legitimately during the four-finger phase and tell us nothing about which
-- count won at COMMIT, which is where the two mechanisms actually collide. A
-- motionless gesture commits as a tap and fires exactly once, from the count the
-- commit chose.
local FRAME_DT_SEC = 0.02
local PEAK_FRAMES  = 8
local AFTER_FRAMES = 10





-- ==================================================================
-- ==================================================================
-- ======= 1/ A confirmed 4 → 3 drop commits as three fingers =======
-- ==================================================================
-- ==================================================================

--- Runs a gesture that starts with a SUSTAINED four fingers, drops to three long
--- enough for the drop to be confirmed, and finishes at three.
--- @return table Array of action names, in fire order.
local function gesture_with_confirmed_drop()
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["lib.timings"] = {
		sec = function(_, key)
			-- tap_max_ms is generous on purpose: confirming the drop legitimately
			-- costs more than a production tap window, and the gesture must still
			-- reach the tap branch so the commit's chosen count is observable.
			if key == "tap_max_ms" then return 1.0
			elseif key == "finger_confirm_ms" then return 0.05
			elseif key == "finger_drop_confirm_ms" then return 0.12 end
			return 0.0
		end,
	}

	-- Drive the engine's clock: the defect is about which counts survive to
	-- commit, and real elapsed time between calls (microseconds) would leave
	-- every confirm window unsatisfied.
	local hs          = _G.hs
	local saved_clock = hs.timer.secondsSinceEpoch
	local clock       = 1000.0
	hs.timer.secondsSinceEpoch = function() return clock end

	local Engine = require("modules.gestures.engine")
	local fired  = {}
	Engine.init({
		enabled = true,
		ga = {
			swipe_3_up = "none",  swipe_3_down = "none",
			swipe_3_left = "none", swipe_3_right = "none",
			swipe_4_up = "none",  swipe_4_down = "none",
			swipe_4_left = "none", swipe_4_right = "none",
			tap_2 = "none", tap_3 = "tab_next", tap_4 = "space_next", tap_5 = "none",
		},
		modes         = {},
		sensitivities = {},
	}, {
		execute_single = function(a) fired[#fired + 1] = a end,
		execute_axis   = function(a) fired[#fired + 1] = a end,
		set_gesture_in_progress = function() end,
	})

	local function fingers(count, y)
		local f = {}
		for i = 1, count do
			f[#f + 1] = { absoluteVector = { position = { x = 100 + (i * 10), y = y } } }
		end
		return f
	end

	local y = 100
	local function frame(count)
		Engine.process_frame(fingers(count, y))
		clock = clock + FRAME_DT_SEC
	end

	for _ = 1, PEAK_FRAMES  do frame(4) end   -- Four fingers, sustained: peakN = maxFingers = 4
	for _ = 1, AFTER_FRAMES do frame(3) end   -- One lifts; the drop confirms and the gesture continues

	for _ = 1, 5 do
		Engine.process_frame({})
		clock = clock + FRAME_DT_SEC
	end

	hs.timer.secondsSinceEpoch = saved_clock
	package.loaded["modules.gestures.engine"] = nil
	return fired
end

--- True when `list` contains `name`.
--- @param list table Array of strings.
--- @param name string Value to look for.
--- @return boolean
local function contains(list, name)
	for _, v in ipairs(list) do
		if v == name then return true end
	end
	return false
end

helpers.describe("a confirmed finger drop outranks the sustained peak", function()
	helpers.it("does not fire the 4-finger action after the drop is confirmed", function()
		local fired = gesture_with_confirmed_drop()
		helpers.assert_true(#fired > 0,
			"the gesture must have fired something — with nothing fired this test would pass "
				.. "regardless of which count won the commit")
		helpers.assert_true(not contains(fired, "space_next"), string.format(
			"the drop to three fingers was CONFIRMED — the engine spent frames establishing it "
				.. "was a real finger-count change and demoted maxFingers accordingly. peakN kept "
				.. "the abandoned count, so the peak override re-promoted it at commit and undid "
				.. "the demotion. The peak exists to recover a finger lifting a frame early, not "
				.. "to overrule a drop that confirmed. Fired: %s",
			table.concat(fired, ", ")))
	end)

	helpers.it("fires the 3-finger action the user finished with", function()
		local fired = gesture_with_confirmed_drop()
		helpers.assert_true(contains(fired, "tab_next"), string.format(
			"suppressing the stale peak must leave the real gesture intact: the gesture ended on "
				.. "three fingers, so tap_3 must fire. Asserting only the ABSENCE of "
				.. "the 4-finger action would also pass on an engine that fired nothing at all. "
				.. "Fired: %s",
			table.concat(fired, ", ")))
	end)
end)
