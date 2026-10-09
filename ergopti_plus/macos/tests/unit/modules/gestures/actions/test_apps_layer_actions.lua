--- tests/unit/modules/gestures/actions/test_apps_layer_actions.lua

--- ==============================================================================
--- MODULE: Gesture actions reach the app-navigation and pixel owners
--- DESCRIPTION:
--- Opening Downloads, the file manager or the system settings, copying the
--- path of the selection and reading the pixel colour existed only as fixed
--- shortcut-layer hotkeys (Ctrl+D, Ctrl+E, Ctrl+I, Ctrl+S, Ctrl+X). Both owners
--- are scoped by parent: a gesture runs them under "gestures", a keyboard slot
--- under "shortcut_bindings", and each feature's PAUSE settles only its own work.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

--- Catalogue id -> the app-navigation function it must run.
local DELEGATES = {
	open_downloads = "open_downloads",
	open_file_manager = "open_finder",
	open_system_settings = "open_settings",
	copy_selected_path = "copy_or_open_path",
}

helpers.describe("gesture actions delegate to the app-navigation owner", function()
	it("runs each app action under the gesture or keyboard parent", function(fresh_actions)
		local actions, calls = fresh_actions()
		local checked = 0
		for action_id, method in pairs(DELEGATES) do
			helpers.assert_eq(actions.execute_single(action_id), true,
				action_id .. " must be a registered gesture action")
			local last = calls.apps_actions[#calls.apps_actions]
			helpers.assert_eq(last.name, method, action_id .. " must run apps." .. method)
			helpers.assert_eq(last.parent, "gestures")
			helpers.assert_eq(actions.execute_single(action_id, "keyboard__cmd_1"), true)
			helpers.assert_eq(calls.apps_actions[#calls.apps_actions].parent, "shortcut_bindings")
			checked = checked + 1
		end
		helpers.assert_eq(checked, 4)
	end)

	it("reads the pixel colour under the dispatching parent", function(fresh_actions)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.execute_single("pick_color"), true,
			"pick_color must be a registered gesture action")
		local last = calls.pixel_actions[#calls.pixel_actions]
		helpers.assert_eq(last.name, "copy_pixel_color")
		helpers.assert_eq(last.parent, "gestures")
		helpers.assert_eq(actions.execute_single("pick_color", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.pixel_actions[#calls.pixel_actions].parent, "shortcut_bindings")
	end)

	it("pauses and resumes only the dispatching parent's app scope", function(fresh_actions)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		local paused_parents = {}
		for _, entry in ipairs(calls.apps_lifecycle) do
			if entry.edge == "pause" then paused_parents[#paused_parents + 1] = entry.parent end
		end
		helpers.assert_eq(table.concat(paused_parents, ","), "gestures",
			"a gesture PAUSE must fence the gesture app scope and nothing else")
		helpers.assert_eq(actions.execute_single("open_downloads"), false)
		helpers.assert_eq(actions.execute_single("open_downloads", "keyboard__cmd_1"), true)
		helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
		helpers.assert_eq(actions.execute_single("open_downloads"), true)
	end)
end)
