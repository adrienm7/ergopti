--- tests/unit/modules/gestures/engine/test_tap_system_conflict_gate.lua

--- ==============================================================================
--- MODULE: Regression — a tap macOS uses fires nothing (tap-held-by-macos)
--- DESCRIPTION:
--- The three-finger tap belongs to macOS Look up while that setting is on, and
--- the conflict owner reports the slot as held. Swipes asked that predicate
--- before dispatch; the tap commit called the single dispatcher directly, so a
--- three-finger tap ran Ergopti's action on top of Look up (macOS MG002).
--- These cases drive the real engine with stationary contacts and a lift.
--- ==============================================================================

local helpers = require("tests.helpers")

-- About 125 Hz, the rate the touch device reports frames at.
local FRAME_DT_SEC = 0.008

local HAND = { { x = 40, y = 50 }, { x = 50, y = 50 }, { x = 60, y = 50 } }

local GESTURES = {
	swipe_2_up = "none", swipe_2_down = "none", swipe_2_left = "none", swipe_2_right = "none",
	swipe_3_up = "none", swipe_3_down = "none", swipe_3_left = "none", swipe_3_right = "none",
	swipe_4_up = "none", swipe_4_down = "none", swipe_4_left = "none", swipe_4_right = "none",
	tap_2 = "none", tap_3 = "tab_next", tap_4 = "none", tap_5 = "none",
}





-- =================================
-- =================================
-- ======= 1/ Engine Harness =======
-- =================================
-- =================================

--- Plays one stationary three-finger tap and returns the dispatched actions.
--- @param held function|nil The core state's system_held predicate.
--- @return table fired
local function tap(held)
	local hs = _G.hs
	local saved_clock = hs.timer.secondsSinceEpoch
	local saved_absolute = hs.timer.absoluteTime
	local saved_scheduler = package.loaded["adapters.timer_scheduler"]
	local saved_timings = package.loaded["infra.timings"]
	local clock = 3000.0
	hs.timer.secondsSinceEpoch = function() return clock end
	hs.timer.absoluteTime = function() return clock * 1e9 end
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["infra.timings"] = nil
	package.loaded["modules.gestures.engine"] = nil
	hs.eventtap.__reset()

	local Engine = require("modules.gestures.engine")
	local fired = {}
	local initialized = Engine.init({
		enabled = true,
		ga = GESTURES,
		system_held = held,
	}, {
		execute_single = function(a) fired[#fired + 1] = a; return true end,
		execute_axis   = function(a) fired[#fired + 1] = a; return true end,
		set_gesture_in_progress = function() end,
	})
	helpers.assert_true(initialized == true, "the engine must initialize on the stub eventtap")

	local ok, err = pcall(function()
		for _ = 1, 10 do
			local touches = {}
			for _, c in ipairs(HAND) do
				touches[#touches + 1] = { absoluteVector = { position = { x = c.x, y = c.y } } }
			end
			Engine.process_frame(touches)
			clock = clock + FRAME_DT_SEC
		end
		Engine.process_frame({})
	end)
	Engine.stop()
	hs.timer.secondsSinceEpoch = saved_clock
	hs.timer.absoluteTime = saved_absolute
	package.loaded["adapters.timer_scheduler"] = saved_scheduler
	package.loaded["infra.timings"] = saved_timings
	package.loaded["modules.gestures.engine"] = nil
	if not ok then error(err, 0) end
	return fired
end





-- =====================================
-- =====================================
-- ======= 2/ Tap Conflict Gate ========
-- =====================================
-- =====================================

helpers.describe("a tap macOS uses fires nothing (tap-held-by-macos)", function()
	helpers.it("a free three-finger tap fires its action (control)", function()
		local fired = tap(function() return false end)
		helpers.assert_eq(table.concat(fired, ","), "tab_next")
	end)

	helpers.it("a three-finger tap macOS holds fires nothing and asks for tap_3", function()
		local asked = {}
		local fired = tap(function(slot) asked[#asked + 1] = slot; return slot == "tap_3" end)
		helpers.assert_eq(#fired, 0, "Look up owns the tap: firing Ergopti's action too is a double action")
		helpers.assert_eq(table.concat(asked, ","), "tap_3", "the tap commit must ask the conflict owner")
	end)
end)
