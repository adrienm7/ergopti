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
	-- gestures/engine.lua into the self-contained gestures/geometry.lua. Read
	-- both so the guard assertions survive that move (move-resilient).
	local function read_geometry_src()
		return (read_source("local function triggerLiveAxisIfNeeded") or "") ..
			"\n" .. (read_source("function M.slotForDir") or "")
	end

	helpers.it("old `adx >= diagMin and ady >= diagMin` pattern is gone", function()
		local src = read_geometry_src()
		helpers.assert_true(
			not src:find("adx >= diagMin and ady >= diagMin", 1, true),
			"engine/geometry must not use `adx >= diagMin and ady >= diagMin` (requires 2x distance)")
	end)

	helpers.it("diagonal check uses `dist >= diagMin`", function()
		local src = read_geometry_src()
		helpers.assert_true(
			src:find("dist >= diagMin", 1, true) ~= nil,
			"engine/geometry diagonal check must use `dist >= diagMin` (Manhattan total distance)")
	end)

end)
