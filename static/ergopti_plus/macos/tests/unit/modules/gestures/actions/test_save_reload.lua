--- tests/unit/modules/gestures/actions/test_save_reload.lua

--- ==============================================================================
--- MODULE: Gesture Actions save reload
--- DESCRIPTION:
--- Exercises gesture Actions save/reload transaction through the shared isolated fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("gesture Actions save/reload transaction", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		it("posts no save when reload timer acquisition returns " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ prepare_mode = mode })
			helpers.assert_eq(actions.execute_single("script_save_reload"), true,
				"the registered save action remains owned after its continuation refuses")
			helpers.assert_eq(#calls.keys, 0,
				"save must not post unless its exact reload continuation is already owned")
			helpers.assert_eq(calls.reload, 0)
		end)

		it("rolls back reload when save dispatch returns " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ key_post_mode = mode })
			helpers.assert_eq(actions.execute_single("script_save_reload"), true,
				"the registered save action remains owned after its native dispatch refuses")
			helpers.assert_eq(calls.rollback, 1)
			helpers.assert_eq(#calls.keys, 0)
			helpers.assert_eq(calls.fire(calls.after[1].token), false)
			helpers.assert_eq(calls.reload, 0)
		end)
	end

	it("commits reload only after save dispatch succeeds", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.execute_single("script_save_reload"), true)
		helpers.assert_eq(#calls.keys, 1)
		helpers.assert_eq(calls.keys[1].key, "s")
		helpers.assert_eq(calls.reload, 0)
		helpers.assert_eq(calls.fire(calls.after[1].token), true)
		helpers.assert_eq(calls.reload, 1)
	end)
end)
