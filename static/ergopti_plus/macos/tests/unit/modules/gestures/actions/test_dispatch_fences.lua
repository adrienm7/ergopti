--- tests/unit/modules/gestures/actions/test_dispatch_fences.lua

--- ==============================================================================
--- MODULE: Gesture Actions dispatch fences
--- DESCRIPTION:
--- Exercises gesture Actions dispatch fences through the shared isolated fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("gesture Actions dispatch fences", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		it("refuses the action when held-click release returns " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ release_mode = mode })
			helpers.assert_eq(actions.execute_single("mission_control"), false)
			helpers.assert_eq(#calls.keys, 0)
		end)
	end

	it("revalidates PAUSE after held-click release before dispatch", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions({ pause_on_release = true })
		helpers.assert_eq(actions.execute_single("mission_control"), false)
		helpers.assert_eq(calls.aux_is_paused(), true)
		helpers.assert_eq(#calls.keys, 0)
	end)

	it("keeps only dedicated script-control lifecycle actions live behind PAUSE", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		helpers.assert_eq(actions.execute_single(
			"open_config", "script__escape"), false,
			"an arbitrary action assigned to the dedicated tap remains fenced")
		helpers.assert_eq(actions.execute_single(
			"script_reload", "script__backspace"), true)
		helpers.assert_eq(calls.reload, 1)
		helpers.assert_eq(actions.execute_single(
			"script_quit", "script__escape"), true)
	end)
end)
