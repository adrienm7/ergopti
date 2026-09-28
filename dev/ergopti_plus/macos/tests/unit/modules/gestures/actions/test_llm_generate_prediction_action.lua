--- tests/unit/modules/gestures/actions/test_llm_generate_prediction_action.lua

--- ==============================================================================
--- MODULE: The llm_generate_prediction action reaches the keymap bridge
--- DESCRIPTION:
--- A gesture or a keyboard slot bound to llm_generate_prediction runs the
--- keymap bridge's request_manual_prediction, which owns the prediction engine
--- and its refusal feedback.
---
--- ROOT CAUSE ENCODED:
--- "Generate a prediction" could not be bound at all: the only way to ask for
--- one was the AI menu's own trigger shortcut, a second binding system beside
--- the keyboard slots and gestures every other action uses.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("llm_generate_prediction action", function()
	it("runs the bridge's manual request from a gesture and from a keyboard slot", function(fresh_actions)
		local actions = fresh_actions()
		local saved = package.loaded["modules.keymap"]
		local requests = 0
		package.loaded["modules.keymap"] = {
			request_manual_prediction = function()
				requests = requests + 1
				return true
			end,
		}
		local ok, err = pcall(function()
			helpers.assert_eq(actions.execute_single("llm_generate_prediction"), true,
				"the action must be a registered gesture action")
			helpers.assert_eq(actions.execute_single("llm_generate_prediction", "keyboard__hs_ctrl_space"), true,
				"a keyboard slot runs the same action")
			helpers.assert_eq(requests, 2, "each dispatch must ask the bridge for one prediction")
		end)
		package.loaded["modules.keymap"] = saved
		if not ok then error(err, 0) end
	end)
end)
