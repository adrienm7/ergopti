--- tests/unit/modules/gestures/actions/test_system_layer_actions.lua

--- ==============================================================================
--- MODULE: Shortcut-layer system functions exposed as catalogue actions
--- DESCRIPTION:
--- The emoji picker, display mirroring and keep-awake existed only as fixed
--- shortcut-layer hotkeys (Ctrl+., Ctrl+P, Ctrl+M), so no gesture or keyboard
--- slot could bind them. The emoji picker and the mirror toggle run in the
--- parent-scoped mouse owner under the dispatching parent; keep-awake is one
--- session toggle whatever triggered it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("gesture actions reach the shortcut layer's system functions", function()
	it("runs the emoji picker and the mirror toggle under the dispatching parent", function(fresh_actions)
		local actions, calls = fresh_actions()
		for action_id, method in pairs({
			open_emoji_picker = "open_emoji_picker",
			display_mirror_toggle = "toggle_display_mirror",
		}) do
			helpers.assert_eq(actions.execute_single(action_id), true,
				action_id .. " must be a registered gesture action")
			local last = calls.mouse_actions[#calls.mouse_actions]
			helpers.assert_eq(last.name, method)
			helpers.assert_eq(last.parent, "gestures")
			helpers.assert_eq(actions.execute_single(action_id, "keyboard__cmd_1"), true)
			helpers.assert_eq(calls.mouse_actions[#calls.mouse_actions].parent, "shortcut_bindings")
		end
	end)

	it("toggles keep-awake through the shortcut layer's session", function(fresh_actions)
		local saved = package.loaded["modules.shortcuts.actions.system"]
		local toggles = 0
		package.loaded["modules.shortcuts.actions.system"] = {
			toggle_awake = function() toggles = toggles + 1; return true end,
		}
		local ok, err = pcall(function()
			local actions = fresh_actions()
			helpers.assert_eq(actions.execute_single("activity_simulation"), true)
			helpers.assert_eq(toggles, 1, "activity_simulation must toggle the keep-awake session")
		end)
		package.loaded["modules.shortcuts.actions.system"] = saved
		helpers.assert_true(ok, tostring(err))
	end)
end)
