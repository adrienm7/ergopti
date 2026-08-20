--- tests/unit/modules/gestures/test_peak_override_needs_sustained_hold.lua

--- ==============================================================================
--- MODULE: Regression — the peak-finger override needs a SUSTAINED peak
--- DESCRIPTION:
--- A 3-finger swipe could fire the 4-finger action. One stray contact — a palm
--- edge, a knuckle grazing the trackpad for a single frame — was enough.
---
--- ROOT CAUSE ENCODED:
--- commitGesture computed the peak's age, not its duration:
---     peak_elapsed = now - peakNFirstSeen
--- `now` is commit time, so the value grew with the REST of the gesture. A
--- 4-finger spike lasting one frame, followed by 200 ms of ordinary 3-finger
--- swiping, yielded peak_elapsed = 200 ms — comfortably past
--- PEAK_FINGERS_CONFIRM_MS — and the override replaced maxFingers=3 with
--- peakN=4. The longer the user swiped, the more certain the engine became about
--- a peak it had seen exactly once. The guard was strictly easier to satisfy the
--- less the peak deserved it.
---
--- WHY IT WAS SILENT:
--- The override logs at INFO and reads as a success ("PEAK OVERRIDE — using
--- peakN=4 … over maxFingers=3"), so the log line confirms the wrong decision
--- rather than flagging it. From the user's side a swipe simply did the wrong
--- thing, intermittently, in a way no deliberate action reproduces.
---
--- The fix records peakNLastSeen and measures the span the peak was actually
--- observed over, so a one-frame spike scores 0 s and can never confirm.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Vertical travel per frame, comfortably past TAP_MAX_DELTA (8.0) and SWIPE_MIN
-- over the frame count below, so the gesture commits as a swipe rather than a tap.
local FRAME_TRAVEL_PX = 8

-- Seconds advanced per frame on the fake clock. 20 ms × 10 frames = 200 ms, well
-- past PEAK_FINGERS_CONFIRM_MS (0.05) — that gap is what the old formula banked.
local FRAME_DT_SEC    = 0.02
local SWIPE_FRAMES    = 10





-- =================================================
-- =================================================
-- ======= 1/ A One-Frame Spike Must Not Win =======
-- =================================================
-- =================================================

--- Runs a 3-finger upward swipe containing a single 4-finger frame and returns
--- the actions the engine fired.
--- @return table Array of action names, in fire order.
local function swipe_with_one_frame_spike()
	package.loaded["modules.gestures.engine"] = nil
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			-- tap_max_ms is deliberately short so a 200 ms gesture is unambiguously
			-- a swipe; the confirm windows keep their production values so the
			-- one-frame spike cannot legitimately confirm as a candidate.
			if key == "tap_max_ms" then return 0.05
			elseif key == "finger_confirm_ms" then return 0.05
			elseif key == "finger_drop_confirm_ms" then return 0.12 end
			return 0.0
		end,
	}

	-- Drive the engine's clock rather than the wall clock: the defect is entirely
	-- about which two timestamps get subtracted, so real elapsed time (microseconds
	-- between process_frame calls) would make both formulas score ~0 and the test
	-- could not tell them apart.
	local hs          = _G.hs
	local saved_clock = hs.timer.secondsSinceEpoch
	local clock       = 1000.0
	hs.timer.secondsSinceEpoch = function() return clock end

	local Engine = require("modules.gestures.engine")
	local fired  = {}
	Engine.init({
		enabled = true,
		ga = {
			-- The frames below travel with y increasing, which the engine locks as
			-- "down"; the "up" slots stay unbound so only a down-swipe can fire.
			swipe_3_up = "none",  swipe_3_down = "tab_next",
			swipe_3_left = "none", swipe_3_right = "none",
			swipe_4_up = "none",  swipe_4_down = "space_next",
			swipe_4_left = "none", swipe_4_right = "none",
			tap_2 = "none", tap_3 = "none", tap_4 = "none", tap_5 = "none",
		},
		modes         = { swipe_3_down = "x1", swipe_4_down = "x1" },
		sensitivities = { swipe_3_down = 3.5, swipe_4_down = 3.5 },
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
	--- Advances the clock and pushes one frame.
	--- @param count number Contacts on the trackpad this frame.
	local function frame(count)
		Engine.process_frame(fingers(count, y))
		y     = y + FRAME_TRAVEL_PX
		clock = clock + FRAME_DT_SEC
	end

	frame(3)              -- Gesture starts at three fingers: maxFingers = peakN = 3
	frame(4)              -- ONE stray frame: peakN rises to 4 and is never seen again
	for _ = 1, SWIPE_FRAMES do frame(3) end   -- The real swipe, all at three fingers

	for _ = 1, 5 do        -- Lift-off commits the gesture
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

helpers.describe("peak-finger override requires a sustained peak, not a stale one", function()
	helpers.it("does not fire the 4-finger action after a single 4-finger frame", function()
		local fired = swipe_with_one_frame_spike()
		helpers.assert_true(#fired > 0,
			"the swipe must have fired something — with nothing fired this test would "
			.. "pass no matter what the override did")
		helpers.assert_true(not contains(fired, "space_next"), string.format(
			"a 4-finger contact lasting ONE frame must never win the commit. It did because "
			.. "peak_elapsed was measured as (commit time - first seen), so it grew with the "
			.. "rest of the gesture: 200 ms of ordinary 3-finger swiping made a one-frame "
			.. "spike look like a 200 ms hold. Fired: %s",
			table.concat(fired, ", ")))
	end)

	helpers.it("fires the 3-finger action the user actually performed", function()
		local fired = swipe_with_one_frame_spike()
		helpers.assert_true(contains(fired, "tab_next"), string.format(
			"suppressing the bogus override must leave the real gesture intact — the swipe was "
			.. "three fingers up throughout, so swipe_3_down must fire (G2). Fired: %s",
			table.concat(fired, ", ")))
	end)
end)
