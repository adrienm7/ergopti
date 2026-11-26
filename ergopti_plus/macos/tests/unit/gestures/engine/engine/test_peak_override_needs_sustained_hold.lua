--- tests/unit/gestures/engine/engine/test_peak_override_needs_sustained_hold.lua

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
---
--- WHERE THE OVERRIDE IS OBSERVABLE:
--- Only a peak the engine has not already accepted reaches the commit-time
--- override. A finger joining before the swipe locks takes the fast path and
--- becomes maxFingers at once, and the old fixture's timings (every key but
--- three set to 0) confirmed a candidate instantly, so the previous version of
--- this test stayed green with the time gate deleted outright. The swipes below
--- use the real timings and lock at three fingers first: a fourth finger is then
--- a candidate, and only the override can turn it into the four-finger action.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Vertical travel per frame: enough to lock the direction and fire the live
-- three-finger action within the locking frames.
local FRAME_TRAVEL_PX = 12

-- Three-finger frames before the peak, so the swipe is locked when it arrives.
local LOCK_FRAMES = 6




-- =================================================
-- =================================================
-- ======= 1/ Swipe Driver =========================
-- =================================================
-- =================================================

--- Runs a three-finger downward swipe on the engine's own clock: LOCK_FRAMES at
--- three fingers, then a four-finger peak, then optional three-finger frames,
--- then lift-off. Returns the actions the engine fired.
--- @param peak_frames number Frames the four-finger peak is held.
--- @param frame_dt number Seconds per frame (1/120 is a ProMotion display).
--- @param after_frames number Three-finger frames between the peak and lift-off.
--- @return table fired Action names, in fire order.
local function swipe(peak_frames, frame_dt, after_frames)
	package.loaded["gestures.engine.engine"] = nil
	-- Production timings: a stubbed table that answers 0 confirms every
	-- candidate at once and hides the override this file is about.
	local saved_timings = package.loaded["core.timing.engine.timings"]
	package.loaded["core.timing.engine.timings"] = nil
	local hs = _G.hs
	local saved_clock = hs.timer.secondsSinceEpoch
	local saved_absolute_clock = hs.timer.absoluteTime
	local saved_scheduler = package.loaded["core.events.timer_scheduler"]
	local clock = 1000.0
	hs.timer.secondsSinceEpoch = function() return clock end
	hs.timer.absoluteTime = function() return clock * 1e9 end
	package.loaded["core.events.timer_scheduler"] = nil

	local fired = {}
	local ok, failure = xpcall(function()
		local Engine = require("gestures.engine.engine")
		Engine.init({
			enabled = true,
			ga = {
				-- The frames travel with y increasing, which the engine locks as
				-- "down"; the other slots stay unbound so only a down-swipe fires.
				swipe_3_up = "none", swipe_3_down = "tab_next",
				swipe_3_left = "none", swipe_3_right = "none",
				swipe_4_up = "none", swipe_4_down = "space_next",
				swipe_4_left = "none", swipe_4_right = "none",
				tap_2 = "none", tap_3 = "none", tap_4 = "none", tap_5 = "none",
			},
			modes = { swipe_3_down = "x1", swipe_4_down = "x1" },
			sensitivities = { swipe_3_down = 3.5, swipe_4_down = 3.5 },
		}, {
			execute_single = function(action) fired[#fired + 1] = action; return true end,
			execute_axis = function(action) fired[#fired + 1] = action; return true end,
			set_gesture_in_progress = function() end,
		})
		local y = 100
		local function frame(count)
			local contacts = {}
			for index = 1, count do
				contacts[#contacts + 1] = { absoluteVector = { position = { x = 100 + (index * 10), y = y } } }
			end
			Engine.process_frame(contacts)
			y = y + FRAME_TRAVEL_PX
			clock = clock + frame_dt
		end
		for _ = 1, LOCK_FRAMES do frame(3) end
		for _ = 1, peak_frames do frame(4) end
		for _ = 1, after_frames do frame(3) end
		for _ = 1, 3 do
			Engine.process_frame({})
			clock = clock + frame_dt
		end
	end, debug.traceback)

	hs.timer.secondsSinceEpoch = saved_clock
	hs.timer.absoluteTime = saved_absolute_clock
	package.loaded["core.events.timer_scheduler"] = saved_scheduler
	package.loaded["core.timing.engine.timings"] = saved_timings
	package.loaded["gestures.engine.engine"] = nil
	if not ok then error(failure, 0) end
	return fired
end

--- True when `list` contains `name`.
--- @param list table Array of strings.
--- @param name string Value to look for.
--- @return boolean
local function contains(list, name)
	for _, value in ipairs(list) do
		if value == name then return true end
	end
	return false
end





-- ===================================================
-- ===================================================
-- ======= 2/ Only a Held Peak Wins the Commit =======
-- ===================================================
-- ===================================================

helpers.describe("peak-finger override requires a sustained peak, not a stale one", function()
	helpers.it("does not fire the 4-finger action after a single 4-finger frame", function()
		local fired = swipe(1, 1 / 60, 6)
		helpers.assert_true(contains(fired, "tab_next"),
			"the three-finger swipe the user performed must fire. Fired: " .. table.concat(fired, ", "))
		helpers.assert_true(not contains(fired, "space_next"), string.format(
			"a 4-finger contact lasting ONE frame must never win the commit. It did because "
			.. "peak_elapsed was measured as (commit time - first seen), so it grew with the "
			.. "rest of the gesture. Fired: %s", table.concat(fired, ", ")))
	end)

	helpers.it("does not fire the 4-finger action for a 4-frame peak at 120 Hz (25 ms)", function()
		-- Four frames was the old frame-count threshold; at 120 Hz it is half the
		-- confirmation time, so a frame count would confirm what the clock refuses.
		local fired = swipe(4, 1 / 120, 0)
		helpers.assert_true(contains(fired, "tab_next"),
			"the three-finger swipe must fire. Fired: " .. table.concat(fired, ", "))
		helpers.assert_true(not contains(fired, "space_next"),
			"a peak held 25 ms is below PEAK_FINGERS_CONFIRM_MS. Fired: " .. table.concat(fired, ", "))
	end)

	helpers.it("fires the 4-finger action for a peak held past the confirmation time", function()
		-- Three frames at 30 Hz hold the peak about 67 ms, yet stay below the four
		-- frames the candidate path needs: only the commit-time override fires it.
		local fired = swipe(3, 1 / 30, 0)
		helpers.assert_true(contains(fired, "space_next"),
			"a 4-finger peak held past the confirmation time must win the commit. Fired: "
				.. table.concat(fired, ", "))
	end)
end)
