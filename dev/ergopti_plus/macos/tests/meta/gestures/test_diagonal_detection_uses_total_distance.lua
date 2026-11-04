--- tests/meta/gestures/test_diagonal_detection_uses_total_distance.lua

--- ==============================================================================
--- MODULE: Gesture diagonal detection (meta)
--- DESCRIPTION:
--- Diagonal swipe detection uses the total distance, not both axes separately.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

helpers.describe("gestures/engine.lua: diagonal detection uses total distance (audit-v5)", function()

	-- computeDir() (which owns the diagonal-distance guard) was extracted from
	-- gestures/engine.lua into the self-contained gestures/geometry.lua, which
	-- now delegates the classification to the shared direction module both
	-- drivers use. Read all three so the guard assertions survive those moves
	-- (move-resilient); the shared corpus pins the same rule behaviourally.
	local function read_geometry_src()
		local handle = assert(io.open(helpers.shared("lua/gestures/direction.lua"), "r"))
		local shared = handle:read("*a")
		handle:close()
		return (read_source("local function triggerLiveAxisIfNeeded") or "") ..
			"\n" .. (read_source("function M.slotForDir") or "") .. "\n" .. shared
	end

	helpers.it("old `adx >= diagMin and ady >= diagMin` pattern is gone", function()
		local src = read_geometry_src()
		helpers.assert_true(
			not src:find("adx >= diagMin and ady >= diagMin", 1, true)
				and not src:find("adx >= diagonal_minimum and ady >= diagonal_minimum", 1, true),
			"engine/geometry must not require each axis to reach the diagonal minimum (requires 2x distance)")
	end)

	helpers.it("diagonal check uses `dist >= diagonal_minimum`", function()
		local src = read_geometry_src()
		helpers.assert_true(
			src:find("local dist = adx + ady", 1, true) ~= nil
				and src:find("dist >= diagonal_minimum", 1, true) ~= nil,
			"the diagonal check must use `dist >= diagonal_minimum` on the Manhattan total distance")
	end)

end)
