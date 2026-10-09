--- tests/unit/modules/gestures/test_gesture_suspend_axis.lua

--- ==============================================================================
--- MODULE: Gesture suspend/resume axis regression tests
--- DESCRIPTION:
--- Regression tests for F-MED-5: the gestures module was conflating the user
--- feature flag (CoreState.enabled) with the pause-suspend flag, so toggling
--- gestures ON via the menu during a pause made them fire while paused, and
--- toggling them OFF during a pause was lost on resume.
---
--- FEATURES & RATIONALE:
--- 1. Structural tests assert gestures/init.lua exposes suspend()/resume() and
---    is_suspended(), and gestures/engine.lua gates fire paths on suspended too.
--- 2. These tests encode the root cause, not the symptom: the dual-axis invariant
---    (enabled AND NOT suspended) must be present in every engine dispatch gate.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ====================================================================
-- ====================================================================
-- ======= 1/ Structural: suspend/resume public API exists ===========
-- ====================================================================
-- ====================================================================

helpers.describe("gestures.init: suspend/resume axis (F-MED-5)", function()

	local function read_init_source()
		local src = helpers.read_driver_source("function M.suspend")
		helpers.assert_not_nil(src, "modules/gestures/init.lua must be readable")
		return src
	end

	local function read_engine_source()
		local src = helpers.read_driver_source("triggerLiveAxisIfNeeded")
		helpers.assert_not_nil(src, "modules/gestures/engine.lua must be readable")
		return src
	end


	helpers.it("CoreState has a 'suspended' field initialised to false", function()
		local src = read_init_source()
		helpers.assert_true(
			src:find("suspended%s*=%s*false", 1, false) ~= nil,
			"CoreState must declare 'suspended = false'"
		)
	end)


	helpers.it("M.suspend() sets CoreState.suspended=true", function()
		local src = read_init_source()
		helpers.assert_true(
			src:find("function M%.suspend", 1, false) ~= nil,
			"gestures/init.lua must expose M.suspend()"
		)
		helpers.assert_true(
			src:find("CoreState%.suspended%s*=%s*true", 1, false) ~= nil,
			"M.suspend() must set CoreState.suspended=true"
		)
	end)


	helpers.it("M.resume() sets CoreState.suspended=false", function()
		local src = read_init_source()
		helpers.assert_true(
			src:find("function M%.resume", 1, false) ~= nil,
			"gestures/init.lua must expose M.resume()"
		)
		helpers.assert_true(
			src:find("CoreState%.suspended%s*=%s*false", 1, false) ~= nil,
			"M.resume() must set CoreState.suspended=false"
		)
	end)


	helpers.it("M.is_suspended() is exposed for introspection", function()
		local src = read_init_source()
		helpers.assert_true(
			src:find("function M%.is_suspended", 1, false) ~= nil,
			"gestures/init.lua must expose M.is_suspended()"
		)
	end)


	helpers.it("engine live-fire gate checks both enabled AND NOT suspended", function()
		local src = read_engine_source()
		-- The live-fire guard in triggerLiveAxisIfNeeded must block on suspended
		helpers.assert_true(
			src:find("not _state%.enabled or _state%.suspended", 1, false) ~= nil,
			"engine live-fire gate must include 'not enabled or suspended' dual-axis check"
		)
	end)


	helpers.it("engine commitGesture gate checks both enabled AND NOT suspended", function()
		local src = read_engine_source()
		helpers.assert_true(
			src:find("not _state%.enabled or _state%.suspended or not gs%.startPos", 1, false) ~= nil,
			"engine commitGesture gate must include suspended axis alongside enabled"
		)
	end)


	helpers.it("scroll-block n>=3 branch checks both enabled AND NOT suspended", function()
		local src = read_engine_source()
		helpers.assert_true(
			src:find("n >= 3 and _state and _state%.enabled and not _state%.suspended", 1, false) ~= nil,
			"scroll-block branch must gate on both enabled and not suspended"
		)
	end)

end)
