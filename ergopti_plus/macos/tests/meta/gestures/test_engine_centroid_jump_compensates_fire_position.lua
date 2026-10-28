--- tests/meta/gestures/test_engine_centroid_jump_compensates_fire_position.lua

--- ==============================================================================
--- MODULE: Gesture engine compensates a centroid jump (meta)
--- DESCRIPTION:
--- The gesture engine must compensate the last fire position when the finger-count centroid jumps.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_src(selector)
	local s = helpers.read_driver_source(selector)
	return s
end

helpers.describe("gesture engine compensates a centroid jump", function()

	-- =========================================================
	-- ===== 4) engine.lua: lastFirePos compensated on centroid jump
	-- =========================================================

	helpers.it("engine.lua must compensate lastFirePos on finger-count centroid jump", function()
		local src = read_src("local function triggerLiveAxisIfNeeded") -- modules/gestures/engine.lua
		assert(src, "modules/gestures/engine.lua must be readable")
		-- The bug: startPos was adjusted by jumpX/jumpY but lastFirePos was not.
		-- The reversal detector uses (pos - lastFirePos), so the jump appeared as
		-- movement in the wrong direction, firing a spurious reversal.
		assert(
			src:find("gs%.lastFirePos", 1, false) and src:find("jumpX", 1, true),
			"engine.lua: lastFirePos must be updated with the same jump offsets as startPos"
		)
		-- Verify both are updated in the same compensation block
		-- Window of 700 bytes: long comments with UTF-8 chars push lastFirePos past 650 bytes
		local comp_start = src:find("StartPos Compensation", 1, true)
		local comp_block = comp_start and src:sub(comp_start, comp_start + 700) or ""
		assert(
			comp_block:find("gs%.lastFirePos", 1, false),
			"engine.lua: lastFirePos compensation must be inside the centroid-jump block"
		)
	end)

end)
