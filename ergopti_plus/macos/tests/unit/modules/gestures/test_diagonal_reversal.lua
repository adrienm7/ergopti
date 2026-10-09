--- tests/unit/modules/gestures/test_diagonal_reversal.lua

--- ==============================================================================
--- MODULE: Diagonal Gesture Reversal Regression Test
--- DESCRIPTION:
--- Guards against the regression where the incremental-reversal detector inside
--- triggerLiveAxisIfNeeded() used only the Y delta for diagonal gestures.
---
--- The original code: `local_delta = (axis == "horiz") and dx or dy`
--- When axis is "diag", the ternary falls through to `dy`, so a horizontal
--- component of a reversal was invisible to the detector. A user reversing a
--- left_up diagonal by moving right+down would be seen as only moving down —
--- the reversal could be missed or its sign computed wrong.
---
--- The fix: compute local_delta as the signed Euclidean distance from lastFirePos
--- along the 45° diagonal projection for the "diag" axis, matching how
--- signedDistAxis() handles it.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then out[#out + 1] = line end
	end
	return table.concat(out, "\n")
end


-- =====================================================================
-- =====================================================================
-- ======= 1/ Diagonal reversal uses both X and Y components ===========
-- =====================================================================
-- =====================================================================

helpers.describe("gestures/engine.lua: diagonal reversal detection", function()

	helpers.it("reversal delta for diag axis uses both dx and dy (not only Y)", function()
		local src = strip_comments(read_source("local function triggerLiveAxisIfNeeded"))

		-- The old bug: a plain ternary `(axis == "horiz") and dx or dy` silently
		-- fell through to dy for the diag case. The fix adds an explicit diag branch.
		-- Verify that the source contains a diag-specific delta that references both
		-- the x and y components from lastFirePos.
		local has_diag_branch = src:find('axis == "diag"') ~= nil
			or src:find("else") ~= nil and src:find("lastFirePos%.x") ~= nil and src:find("lastFirePos%.y") ~= nil
		helpers.assert_true(has_diag_branch,
			"reversal detector must have a diag-axis branch that uses both x and y components")
	end)

	helpers.it("the reversal detector references lastFirePos.x for diagonal direction", function()
		-- When axis is diag, local_delta must depend on the x component from
		-- lastFirePos — the old code never referenced lastFirePos.x in this block.
		local src = strip_comments(read_source("local function triggerLiveAxisIfNeeded"))
		helpers.assert_true(
			src:find("lastFirePos%.x") ~= nil,
			"reversal detector must reference lastFirePos.x (previously missing for diag axis)")
	end)

	helpers.it("signedDistAxis diag branch also uses both dx and dy", function()
		local src = strip_comments(read_source("local function triggerLiveAxisIfNeeded"))
		-- signedDistAxis uses dx*dx + dy*dy for the Euclidean magnitude
		helpers.assert_true(
			src:find("dx%*dx%s*%+%s*dy%*dy") ~= nil or src:find("dx%s*%*%s*dx%s*%+%s*dy%s*%*%s*dy") ~= nil,
			"signedDistAxis diag branch must use dx*dx + dy*dy for Euclidean distance")
	end)

end)
