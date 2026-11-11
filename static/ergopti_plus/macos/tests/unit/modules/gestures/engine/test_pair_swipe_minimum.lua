--- tests/unit/modules/gestures/engine/test_pair_swipe_minimum.lua

--- ==============================================================================
--- MODULE: Pair Swipe Minimum Regression
--- DESCRIPTION:
--- A two-finger swipe decides its direction from the shared pair minimum
--- (gestures.direction, 3.0 mm, diagonal 5.0 mm), the one the Linux tracker
--- reads too (maintainer decision GSD-3 of 11 November 2026); three fingers or
--- more keep 1.5 mm.
--- ==============================================================================

local helpers = require("tests.helpers")
local Geometry = require("modules.gestures.geometry")

helpers.describe("gestures/geometry.lua: the pair swipe minimum (pair-incremental-minimum)", function()
	helpers.it("a pair below 3.0 mm has no direction, three fingers do (pair-incremental-minimum)", function()
		helpers.assert_nil(Geometry.computeDir(2.5, 0, 2), "2.5 mm is below a pair's minimum")
		helpers.assert_eq(Geometry.computeDir(3.0, 0, 2), "horiz", "3.0 mm decides a pair")
		helpers.assert_eq(Geometry.computeDir(2.5, 0, 3), "horiz", "2.5 mm decides three fingers")
	end)

	helpers.it("a pair's diagonal needs the shared 5.0 mm (pair-incremental-minimum)", function()
		helpers.assert_eq(Geometry.computeDir(2.4, -2.4, 2), "horiz", "4.8 mm is a pair's dominant axis")
		helpers.assert_eq(Geometry.computeDir(2.5, -2.5, 2), "diag", "5.0 mm is a pair's diagonal")
	end)
end)

return true
