--- tests/unit/modules/gestures/test_peak_override_regression.lua

--- ==============================================================================
--- MODULE: Gesture Peak-Override Regression Tests
--- DESCRIPTION:
--- Regression tests for the framerate-dependent peak-finger confirmation bug.
--- The commitGesture() function was using FINGER_CONFIRM_FRAMES (a frame count)
--- to decide whether to override maxFingers with peakN, but the constant
--- PEAK_FINGERS_CONFIRM_MS (50 ms) was defined and NEVER used (dead code).
---
--- Root cause: on a 120 Hz ProMotion display 4 frames ≈ 33 ms — below the
--- intended 50 ms threshold — so a 4-finger swipe's peakN could be confirmed too
--- early, raising the risk of false-positive finger-count overrides.
---
--- Fix: commitGesture computes a peak_elapsed in SECONDS and tests it against
--- PEAK_FINGERS_CONFIRM_MS (0.05 s), making the confirmation hardware-independent.
---
--- The cases below model that threshold comparison in isolation. What they do NOT
--- pin is which two timestamps production subtracts: it first used
--- (now - peakNFirstSeen), the peak's AGE, which grew with the rest of the gesture
--- and let a one-frame spike confirm. That separate defect — and the switch to the
--- peak's HELD span — is covered behaviourally by
--- test_peak_override_needs_sustained_hold.lua.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Reproduces the OLD (buggy) peak-override condition.
--- @param peakNFrames number Frames the peak was observed.
--- @param FINGER_CONFIRM_FRAMES number Frame threshold.
--- @return boolean
local function old_peak_confirmed(peakNFrames, FINGER_CONFIRM_FRAMES)
	return (peakNFrames or 0) >= FINGER_CONFIRM_FRAMES
end

--- Reproduces the FIXED time-based peak-override condition.
--- @param now number Current time in seconds.
--- @param peakNFirstSeen number|nil Timestamp when peak was first seen.
--- @param PEAK_FINGERS_CONFIRM_MS number Time threshold in seconds.
--- @return boolean
local function new_peak_confirmed(now, peakNFirstSeen, PEAK_FINGERS_CONFIRM_MS)
	local peak_elapsed = now - (peakNFirstSeen or now)
	return peak_elapsed >= PEAK_FINGERS_CONFIRM_MS
end




-- ==============================================================
-- ==============================================================
-- ======= 1/ Old Formula — Framerate Dependency Bug ============
-- ==============================================================
-- ==============================================================

helpers.describe("commitGesture old formula: frame-based — framerate dependent", function()
	helpers.it("4 frames at 60 Hz passes (67 ms > 50 ms) — would be correct", function()
		-- At 60 Hz each frame ≈ 16.7 ms; 4 frames ≈ 66.7 ms > 50 ms threshold
		local passed = old_peak_confirmed(4, 4)
		helpers.assert_eq(passed, true)
	end)

	helpers.it("4 frames at 120 Hz passes too (33 ms) — but is below 50 ms intent", function()
		-- At 120 Hz each frame ≈ 8.3 ms; 4 frames ≈ 33 ms < 50 ms.
		-- The old formula still returns true, confirming too early on ProMotion.
		-- The frame count is the same regardless of hardware, so the guard is wrong.
		local passed = old_peak_confirmed(4, 4)
		helpers.assert_eq(passed, true,
			"old formula confirms at 4 frames on 120 Hz — 33 ms < intended 50 ms")
	end)
end)




-- ==============================================================
-- ==============================================================
-- ======= 2/ Fixed Formula — Time-Based Correctness ============
-- ==============================================================
-- ==============================================================

helpers.describe("commitGesture fixed formula: time-based — hardware-independent", function()
	local THRESHOLD = 0.05  -- PEAK_FINGERS_CONFIRM_MS = 0.050 s

	helpers.it("30 ms elapsed is NOT confirmed (below 50 ms threshold)", function()
		local now      = 1.030
		local first    = 1.000
		local passed   = new_peak_confirmed(now, first, THRESHOLD)
		helpers.assert_eq(passed, false,
			"peak held for 30 ms must not be confirmed (threshold is 50 ms)")
	end)

	helpers.it("50 ms elapsed IS confirmed (exactly at threshold)", function()
		local now    = 1.050
		local first  = 1.000
		local passed = new_peak_confirmed(now, first, THRESHOLD)
		helpers.assert_eq(passed, true,
			"peak held for exactly 50 ms must be confirmed")
	end)

	helpers.it("70 ms elapsed IS confirmed (above threshold)", function()
		local now    = 1.070
		local first  = 1.000
		local passed = new_peak_confirmed(now, first, THRESHOLD)
		helpers.assert_eq(passed, true)
	end)

	helpers.it("nil peakNFirstSeen means elapsed == 0 — not confirmed", function()
		-- When peakNFirstSeen is nil, (now - now) == 0 < 0.05 → not confirmed
		local now    = 1.100
		local passed = new_peak_confirmed(now, nil, THRESHOLD)
		helpers.assert_eq(passed, false,
			"nil peakNFirstSeen must not confirm (0 ms elapsed)")
	end)

	helpers.it("result is the same for 60 Hz and 120 Hz scenarios at the same wall time", function()
		-- 4 frames at 60 Hz ≈ 66.7 ms → confirmed
		local first = 1.000
		local at_60hz  = new_peak_confirmed(1.067, first, THRESHOLD)
		-- 4 frames at 120 Hz ≈ 33.3 ms → NOT confirmed
		local at_120hz = new_peak_confirmed(1.033, first, THRESHOLD)
		helpers.assert_eq(at_60hz,  true,  "66.7 ms must be confirmed")
		helpers.assert_eq(at_120hz, false, "33.3 ms must NOT be confirmed")
	end)
end)




-- ==============================================================
-- ==============================================================
-- ======= 3/ Source Guard — Fix Permanence =====================
-- ==============================================================
-- ==============================================================

helpers.describe("commitGesture: production source uses time-based peak check", function()
	helpers.it("engine.lua uses peak_elapsed against PEAK_FINGERS_CONFIRM_MS", function()
		local driver_root = helpers.driver_root()
		local src_path    = driver_root .. "modules/gestures/engine.lua"
		local fh          = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil,
			"could not open engine.lua at " .. tostring(src_path))
		local src = fh:read("*a")
		fh:close()

		-- Fixed pattern must be present
		helpers.assert_true(
			src:find("peak_elapsed", 1, true) ~= nil,
			"source must compute peak_elapsed")
		helpers.assert_true(
			src:find("peak_elapsed >= PEAK_FINGERS_CONFIRM_MS", 1, true) ~= nil,
			"source must compare peak_elapsed against PEAK_FINGERS_CONFIRM_MS")

		-- The exact old line that used frame count in the peak-override must be gone.
		-- plain=true avoids cross-line matching via Lua's greedy `.` pattern.
		helpers.assert_eq(
			src:find("(gs.peakNFrames or 0) >= FINGER_CONFIRM_FRAMES", 1, true),
			nil,
			"source must NOT contain the old frame-count peak-override line")
	end)
end)
