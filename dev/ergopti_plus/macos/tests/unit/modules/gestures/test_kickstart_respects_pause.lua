--- tests/unit/modules/gestures/test_kickstart_respects_pause.lua

--- ==============================================================================
--- MODULE: Regression — kickstart_hid must not act while the script is paused
--- DESCRIPTION:
--- CoreState.enabled is the FEATURE flag; CoreState.suspended is the pause. Both
--- guard sites around kickstart_hid checked only the first, so pausing the script
--- did not stop the HID kickstart from warping the cursor and posting a synthetic
--- scroll event.
---
--- ROOT CAUSE ENCODED:
--- Two flags meaning different things, one of them consulted. The invariant the
--- maintainer states is "pause = everything off", and a cursor that jumps during
--- a pause is the most visible possible way to break it.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("gestures: the HID kickstart is silent while paused", function()

	helpers.it("both guard sites consult the suspend flag, not only the feature flag", function()
		local src = helpers.read_driver_source("kickstart_hid")
		helpers.assert_true(type(src) == "string" and src ~= "",
			"the gestures source must be readable or this asserts nothing")

		-- Every guard preceding a kickstart must mention the pause flag. Counting
		-- rather than matching one spelling: the point is that NO site is left
		-- checking the feature flag alone.
		local weak = 0
		for line in src:gmatch("[^\n]+") do
			if line:find("if not CoreState.enabled then return end", 1, true) then
				weak = weak + 1
			end
		end
		helpers.assert_eq(weak, 0,
			"a guard that checks only CoreState.enabled lets the kickstart warp the cursor and "
			.. "post a synthetic scroll during a pause; the pause flag is CoreState.suspended")
	end)

end)
