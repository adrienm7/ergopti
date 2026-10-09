--- tests/unit/modules/gestures/actions/test_wrap_selection_action.lua

--- ==============================================================================
--- MODULE: wrap_selection wraps the selection with the binding's own pair
--- DESCRIPTION:
--- A gesture or keyboard slot bound to wrap_selection stores its pair as the
--- binding's parameter; dispatching it hands that pair to the text owner, under
--- the dispatching parent. A binding without a valid pair does nothing and says
--- so instead of wrapping with a guess.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("wrap_selection gesture action", function()
	it("wraps with the pair stored for the binding, under its parent", function(fresh_actions)
		local actions, calls = fresh_actions()
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter("tap_3", "wrap_selection", "«"), true)
		helpers.assert_eq(actions.set_action_parameter(
			"keyboard__cmd_1", "wrap_selection", "**|**"), true)

		helpers.assert_eq(actions.execute_single("wrap_selection", "tap_3"), true)
		local last = calls.text_actions[#calls.text_actions]
		helpers.assert_eq(last.name, "wrap_copied_selection")
		helpers.assert_eq(last.left, "« ")
		helpers.assert_eq(last.right, " »")
		helpers.assert_eq(last.parent, "gestures")

		helpers.assert_eq(actions.execute_single("wrap_selection", "keyboard__cmd_1"), true)
		last = calls.text_actions[#calls.text_actions]
		helpers.assert_eq(last.left, "**")
		helpers.assert_eq(last.right, "**")
		helpers.assert_eq(last.parent, "shortcut_bindings")
	end)

	it("refuses an invalid pair and wraps nothing without one", function(fresh_actions)
		local actions, calls = fresh_actions()
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter("tap_3", "wrap_selection", "xyz"), false,
			"an unknown symbol must be refused at assignment")
		local before = #calls.text_actions
		actions.execute_single("wrap_selection", "tap_3")
		helpers.assert_eq(#calls.text_actions, before,
			"a binding without a stored pair must not wrap anything")
	end)
end)
