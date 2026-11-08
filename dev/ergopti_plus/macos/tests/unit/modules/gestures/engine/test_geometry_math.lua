--- tests/unit/modules/gestures/engine/test_geometry_math.lua

--- ==============================================================================
--- MODULE: Gesture Geometry Boundaries
--- DESCRIPTION:
--- Exercises contact pairing and incremental thresholds independently of the
--- engine's timing and native trackpad callbacks.
--- ==============================================================================

local helpers = require("tests.helpers")
local Geometry = require("modules.gestures.geometry")

local function touch(x, y)
	return { absoluteVector = { position = { x = x, y = y } } }
end

helpers.describe("gesture geometry", function()
	helpers.it("pairs reordered contacts across the swipe axis and rejects a resting finger", function()
		local origin = { touch(0, 0), touch(0, 2), touch(0, 4) }
		local reordered = { touch(3, 4), touch(3, 0), touch(3, 2) }
		local still_thumb = { touch(3, 4), touch(0, 0), touch(3, 2) }
		local start = Geometry.contactsAcross(origin, "horiz")
		local together, share = Geometry.movedTogether(start, Geometry.contactsAcross(reordered, "horiz"), "horiz")
		helpers.assert_eq(together, true)
		helpers.assert_eq(share, 1)
		local accepted, least = Geometry.movedTogether(start, Geometry.contactsAcross(still_thumb, "horiz"), "horiz")
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(least, 0)
	end)

	-- A resting thumb turned a two-finger swipe into a three-finger one; each
	-- accepted count logs every contact's position and size to calibrate the
	-- refusal of a far or oversized contact (field report 2026-11-05).
	helpers.it("describes each contact's position and major axis for the join log", function()
		local thumb = touch(62.4, 10)
		thumb.majorAxis = 14.256
		local pair = { touch(30, 40), thumb, touch(10.04, 41) }
		pair[1].majorAxis = 8
		helpers.assert_eq(Geometry.describeContacts(pair),
			"(10.0, 41.0 major ?) (30.0, 40.0 major 8.00) (62.4, 10.0 major 14.26)")
		helpers.assert_eq(Geometry.describeContacts({}), "none")
		helpers.assert_eq(Geometry.describeContacts(nil), "none")
	end)

	helpers.it("refuses unmatched contacts and leaves an unmoved centroid undecided", function()
		local start = { { x = 1, y = 1 }, { x = 2, y = 2 } }
		local accepted, share = Geometry.movedTogether(start, { start[1] }, "vert")
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(share, 0)
		accepted, share = Geometry.movedTogether(start, start, "vert")
		helpers.assert_eq(accepted, false)
		helpers.assert_nil(share)
	end)

	helpers.it("fires incremental actions at the first and subsequent thresholds", function()
		for _, case in ipairs({
			{ 3.99, 6, 0 }, { 4, 6, 1 }, { 9.99, 6, 1 }, { 10, 6, 2 },
			{ 1.99, 2, 0 }, { 2, 2, 1 }, { 4, 2, 2 },
		}) do
			helpers.assert_eq(Geometry.incrementalSteps(case[1], case[2]), case[3])
		end
		helpers.assert_eq(Geometry.incrementalReverseMin(6, 0.5), 2)
		helpers.assert_eq(Geometry.incrementalReverseMin(2, 1.5), 1.5)
		for _, step in ipairs({ 0, -1 }) do
			helpers.assert_eq(pcall(Geometry.incrementalSteps, 10, step), false)
		end
		for _, invalid in ipairs({ 0 / 0, math.huge, -math.huge }) do
			helpers.assert_eq(pcall(Geometry.incrementalSteps, 10, invalid), false)
			helpers.assert_eq(pcall(Geometry.incrementalSteps, invalid, 1), false)
		end
		helpers.assert_eq(pcall(Geometry.incrementalSteps, 10, 1e-320), false,
			"overflow in a corrupted internal step must never produce an infinite loop count")
	end)
end)
