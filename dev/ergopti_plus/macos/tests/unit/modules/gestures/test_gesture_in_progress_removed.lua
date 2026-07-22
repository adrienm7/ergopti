--- tests/unit/modules/gestures/test_gesture_in_progress_removed.lua

--- ==============================================================================
--- MODULE: Regression — the dead gestureInProgress flag is removed
--- DESCRIPTION:
--- Audit finding F-L5. set_gesture_in_progress wrote gestureInProgress but NOTHING
--- ever read it — the documented drag-selection protection was a no-op, with
--- comments asserting a behavior that never executed (violates §5.6 no dead code,
--- §5.7 comments must be real). Removed the flag, the setter, its actions re-export,
--- and the two engine call sites. This pins read-vs-write parity: the identifier
--- must not reappear write-only.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read(rel)
	local fh = assert(io.open(helpers.driver_root() .. rel, "r"))
	local s = fh:read("*a"); fh:close()
	return s
end

helpers.describe("gestureInProgress dead flag is fully removed", function()
	helpers.it("actions_click no longer declares or sets gestureInProgress", function()
		local src = read("modules/gestures/actions_click.lua")
		helpers.assert_true(src:find("gestureInProgress", 1, true) == nil,
			"gestureInProgress must be gone from actions_click")
		helpers.assert_true(src:find("set_gesture_in_progress", 1, true) == nil,
			"set_gesture_in_progress must be gone from actions_click")
	end)

	helpers.it("engine no longer calls set_gesture_in_progress", function()
		helpers.assert_true(read("modules/gestures/engine.lua"):find("set_gesture_in_progress", 1, true) == nil,
			"engine must not call the removed setter")
	end)

	helpers.it("actions no longer re-exports set_gesture_in_progress", function()
		helpers.assert_true(read("modules/gestures/actions.lua"):find("set_gesture_in_progress", 1, true) == nil,
			"actions must not re-export the removed setter")
	end)
end)
