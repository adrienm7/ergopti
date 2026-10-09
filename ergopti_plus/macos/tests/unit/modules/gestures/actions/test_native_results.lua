--- tests/unit/modules/gestures/actions/test_native_results.lua

--- ==============================================================================
--- MODULE: Gesture Actions native results
--- DESCRIPTION:
--- Exercises gesture Actions native result diagnostics through the shared isolated fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("gesture Actions native result diagnostics", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		it("reports system-key post " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ system_key_post_mode = mode })
			helpers.assert_eq(actions.execute_single("vol_up"), true)
			helpers.assert_eq(#calls.system_key_posts, 2,
				"both hardware-key phases must reach the native boundary")
			helpers.assert_eq(#calls.errors, 2,
				"each refused hardware-key phase must reach the file logger")
		end)

		it("reports window-action " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ window_action_mode = mode })
			for _, action in ipairs({ "snap_left", "snap_right", "maximize" }) do
				helpers.assert_eq(actions.execute_single(action), true)
			end
			helpers.assert_eq(#calls.window_actions, 3)
			helpers.assert_eq(#calls.errors, 3,
				"each refused window action must reach the file logger")
		end)
	end
end)
