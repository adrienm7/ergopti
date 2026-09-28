--- tests/unit/modules/gestures/actions/test_text_layer_actions.lua

--- ==============================================================================
--- MODULE: Gesture actions delegate to the shortcut layer's text owner
--- DESCRIPTION:
--- The selection, plain-paste and case actions are implemented once, in
--- modules/shortcuts/actions/text.lua, whose lifecycle is scoped by parent. A
--- gesture must run them under the "gestures" parent and a keyboard slot under
--- "shortcut_bindings", so pausing one feature never fences the other.
---
--- ROOT CAUSE ENCODED:
--- Plain paste and word selection existed only as fixed shortcut-layer hotkeys
--- (Cmd+Shift+V, the Linux tray): no gesture or keyboard slot could bind them,
--- and the catalogue declared paste_plain for Windows alone.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

--- Catalogue id -> the text-owner function it must run.
local DELEGATES = {
	select_line = "select_line",
	select_word = "select_word",
	paste_plain = "paste_as_plain_text",
	uppercase_selection = "toggle_uppercase",
	titlecase_selection = "toggle_titlecase",
	selection_uppercase = "selection_uppercase",
	selection_lowercase = "selection_lowercase",
	selection_titlecase = "selection_titlecase",
	surround_parens = "surround_with_parens",
}

helpers.describe("gesture actions delegate to the text owner under their parent", function()
	it("runs each text action under the gesture or keyboard parent", function(fresh_actions)
		local actions, calls = fresh_actions()
		local checked = 0
		for action_id, method in pairs(DELEGATES) do
			helpers.assert_eq(actions.execute_single(action_id), true,
				action_id .. " must be a registered gesture action")
			local last = calls.text_actions[#calls.text_actions]
			helpers.assert_eq(last.name, method, action_id .. " must run text." .. method)
			helpers.assert_eq(last.parent, "gestures", action_id .. " runs under the gesture parent")

			helpers.assert_eq(actions.execute_single(action_id, "keyboard__cmd_1"), true)
			last = calls.text_actions[#calls.text_actions]
			helpers.assert_eq(last.name, method)
			helpers.assert_eq(last.parent, "shortcut_bindings",
				action_id .. " bound to a keyboard slot runs under the shortcut parent")
			checked = checked + 1
		end
		helpers.assert_eq(checked, 9)
	end)

	it("a paused gesture parent fences the text actions only for gestures", function(fresh_actions)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		local before = #calls.text_actions
		helpers.assert_eq(actions.execute_single("paste_plain"), false)
		helpers.assert_eq(#calls.text_actions, before, "a fenced gesture must not paste")
		helpers.assert_eq(actions.execute_single("paste_plain", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.text_actions[#calls.text_actions].parent, "shortcut_bindings")
	end)
end)
