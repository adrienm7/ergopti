--- tests/unit/modules/gestures/engine/test_incremental_tab_step.lua

--- ==============================================================================
--- MODULE: Regression — one three-finger swipe switches one tab
---         (three-finger-tab-step)
--- DESCRIPTION:
--- On the maintainer's Mac (2026-10-28, 12:51 field run) the vertical
--- three-finger swipe (tab_prev / tab_next, incremental) switched two or three
--- tabs per swipe: a 19.84-unit swipe committed 3 steps at sensitivity 5, and a
--- small swipe often fired nothing.
---
--- ROOT CAUSES ENCODED:
--- 1. The step was one action every 5 units, far below a normal swipe's 15 to
---    45, and the first action needed a full step. The slot's default is now
---    25 per action, the first one after Geometry.INCREMENTAL_FIRST_STEP: the
---    actions land at 4, 29, 54 and so on.
--- 2. When the distance shrank below a step boundary (sd 39.78 after 8 steps,
---    4.91 after 1) the engine rebased its origin and step count on the current
---    point, so the next small move forward fired the same step again.
--- ==============================================================================

local helpers = require("tests.helpers")

-- About 125 Hz, the rate the touch device reports frames at.
local FRAME_DT_SEC = 0.008

local HAND = { { x = 40, y = 50 }, { x = 50, y = 50 }, { x = 60, y = 50 } }

local GESTURES = {
	swipe_2_up = "none", swipe_2_down = "none", swipe_2_left = "none", swipe_2_right = "none",
	swipe_3_up = "tab_prev", swipe_3_down = "tab_next",
	swipe_3_left = "none", swipe_3_right = "none",
	swipe_4_up = "none", swipe_4_down = "none", swipe_4_left = "none", swipe_4_right = "none",
	tap_2 = "none", tap_3 = "none", tap_4 = "none", tap_5 = "none",
}





-- =================================
-- =================================
-- ======= 1/ Engine Harness =======
-- =================================
-- =================================

--- Builds a fresh engine with the shipped incremental defaults.
--- @param sensitivity number|nil Step to use instead of the manifest default.
--- @return table harness { path, lift, fired, finish }
local function new_harness(sensitivity)
	local hs = _G.hs
	local saved_clock = hs.timer.secondsSinceEpoch
	local saved_absolute = hs.timer.absoluteTime
	local saved_scheduler = package.loaded["adapters.timer_scheduler"]
	local saved_timings = package.loaded["infra.timings"]
	local clock = 2000.0
	hs.timer.secondsSinceEpoch = function() return clock end
	hs.timer.absoluteTime = function() return clock * 1e9 end
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["infra.timings"] = nil
	package.loaded["modules.gestures.engine"] = nil
	hs.eventtap.__reset()

	local Manifest = require("infra.manifest_reader")
	local step_up = sensitivity or Manifest.default_for("gestures.sensitivities.swipe_3_up")
	local step_down = sensitivity or Manifest.default_for("gestures.sensitivities.swipe_3_down")
	local Engine = require("modules.gestures.engine")
	local fired = {}
	local initialized = Engine.init({
		enabled = true,
		ga = GESTURES,
		modes = { swipe_3_up = "incremental", swipe_3_down = "incremental" },
		sensitivities = { swipe_3_up = step_up, swipe_3_down = step_down },
	}, {
		execute_single = function(a) fired[#fired + 1] = a; return true end,
		execute_axis   = function(a) fired[#fired + 1] = a; return true end,
		set_gesture_in_progress = function() end,
	})
	helpers.assert_true(initialized == true, "the engine must initialize on the stub eventtap")

	local harness = { fired = fired }
	local offset = 0

	--- Plays one frame of the three fingers at a vertical offset.
	--- @param dy number Offset of the hand from where it landed.
	local function frame(dy)
		local touches = {}
		for _, c in ipairs(HAND) do
			touches[#touches + 1] = { absoluteVector = { position = { x = c.x, y = c.y + dy } } }
		end
		Engine.process_frame(touches)
		clock = clock + FRAME_DT_SEC
		offset = dy
	end

	--- Moves the hand through each waypoint at `speed` units per frame, after
	--- resting on the landing point for the finger-count settle.
	--- @param waypoints table Array of offsets along the swipe.
	--- @param speed number|nil Units per frame (0.6 by default).
	function harness.path(waypoints, speed)
		speed = speed or 0.6
		for _ = 1, 10 do frame(0) end
		for _, target in ipairs(waypoints) do
			while math.abs(target - offset) > speed do
				frame(offset + (target > offset and speed or -speed))
			end
			frame(target)
		end
	end

	--- Lifts every finger.
	function harness.lift()
		Engine.process_frame({})
		clock = clock + FRAME_DT_SEC
	end

	--- Restores the clock and drops the engine instance.
	function harness.finish()
		Engine.stop()
		hs.timer.secondsSinceEpoch = saved_clock
		hs.timer.absoluteTime = saved_absolute
		package.loaded["adapters.timer_scheduler"] = saved_scheduler
		package.loaded["infra.timings"] = saved_timings
		package.loaded["modules.gestures.engine"] = nil
	end

	return harness
end

--- Plays one swipe along waypoints, lifts, and returns the fired actions.
--- @param waypoints table
--- @param sensitivity number|nil
--- @return table fired
local function swipe(waypoints, sensitivity)
	local h = new_harness(sensitivity)
	h.path(waypoints)
	h.lift()
	local fired = h.fired
	h.finish()
	return fired
end

--- Asserts that exactly `count` actions, all `action`, fired.
--- @param fired table
--- @param count number
--- @param action string
--- @param what string
local function assert_fires(fired, count, action, what)
	local same = true
	for _, a in ipairs(fired) do if a ~= action then same = false end end
	helpers.assert_true(#fired == count and same,
		what .. ": expected " .. count .. " x " .. action .. ", fired: " .. table.concat(fired, ", "))
end





-- =====================================
-- =====================================
-- ======= 2/ One Swipe, One Tab =======
-- =====================================
-- =====================================

helpers.describe("a three-finger swipe switches one tab (three-finger-tab-step)", function()
	helpers.it("the logged 19.84-unit swipe switches exactly one tab", function()
		assert_fires(swipe({ 19.84 }), 1, "tab_next", "sd 19.84 committed 3 steps at sensitivity 5")
	end)

	helpers.it("a short deliberate 4.9-unit swipe still switches one tab", function()
		assert_fires(swipe({ -4.9 }), 1, "tab_prev", "a short swipe must not be lost")
	end)

	helpers.it("a 26-unit swipe switches exactly one tab", function()
		assert_fires(swipe({ 26 }), 1, "tab_next", "a normal swipe below the second action")
	end)

	helpers.it("a 32-unit swipe switches two tabs", function()
		assert_fires(swipe({ 32 }), 2, "tab_next", "a long swipe past 29")
	end)

	helpers.it("a very long 60-unit swipe switches three tabs", function()
		assert_fires(swipe({ 60 }), 3, "tab_next", "a very long swipe past 54")
	end)
end)





-- ====================================================
-- ====================================================
-- ======= 3/ Drift Never Adds or Removes a Tab =======
-- ====================================================
-- ====================================================

helpers.describe("drift around a step boundary holds the tabs fired (three-finger-tab-step)", function()
	helpers.it("hovering just below the first step does not fire it twice", function()
		-- 4.91 after one step in the field log: the hand dips under the first
		-- step, comes back and goes on, then drifts back as it lifts.
		assert_fires(swipe({ 4.5, 3.8, 4.6, 3.8, 8.5, 7.3 }), 1, "tab_next", "a dip below the step")
	end)

	helpers.it("hovering just below a later step does not fire it twice", function()
		-- sd 39.78 after 8 steps at sensitivity 5: the step boundaries are at 4,
		-- 9, 14 ... 39, 44.
		local fired = swipe({ 39.5, 38.8, 39.4, 38.8, 43.0 }, 5)
		assert_fires(fired, 8, "tab_next", "a dip below a later boundary")
	end)

	helpers.it("lift-off drift back does not reverse a short swipe", function()
		assert_fires(swipe({ 5.0, 3.2 }), 1, "tab_next", "a short swipe drifting back as it lifts")
	end)

	helpers.it("a real reversal still switches back", function()
		local fired = swipe({ 20, -6 })
		helpers.assert_true(#fired == 2 and fired[1] == "tab_next" and fired[2] == "tab_prev",
			"a swipe brought back past its start is a reversal; fired: " .. table.concat(fired, ", "))
	end)
end)
