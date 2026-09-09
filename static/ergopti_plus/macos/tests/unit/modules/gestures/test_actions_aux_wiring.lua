--- tests/unit/modules/gestures/test_actions_aux_wiring.lua

--- ==============================================================================
--- MODULE: Gesture Auxiliary Owner Wiring
--- DESCRIPTION:
--- Calls the real Actions registry through representative timer, shell and
--- screenshot entries. This mutation-sensitive slice prevents a false green in
--- which the exact owners exist but production registrations still use raw APIs.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("gesture Actions exact-owner wiring", function()
	it("routes representative async actions and lifecycle boundaries", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.trigger_lookup(), true)
		helpers.assert_eq(actions.execute_axis("lines", true), true)
		helpers.assert_eq(actions.execute_single("script_save_reload"), true)
		helpers.assert_eq(#calls.after, 3)
		helpers.assert_eq(calls.after[1].label, "dictionary lookup")
		helpers.assert_eq(calls.after[2].label, "line down")
		helpers.assert_eq(calls.after[3].label, "script save reload")

		helpers.assert_eq(actions.execute_single("notification_center"), true)
		helpers.assert_eq(actions.execute_single("open_config"), true)
		helpers.assert_eq(#calls.applescript, 1)
		helpers.assert_eq(#calls.open, 1)
		helpers.assert_eq(calls.open[1].target, "/tmp/ergopti/config.toml")

		helpers.assert_eq(actions.execute_single("screenshot_region_clipboard"), true)
		helpers.assert_eq(actions.execute_single("screenshot_window_save"), true)
		helpers.assert_eq(calls.capture[1], { "-ci" })
		helpers.assert_eq(calls.save[1].prefix, "win")

		helpers.assert_eq(actions.force_cleanup(), true)
		helpers.assert_eq(calls.pause, 1)
		helpers.assert_eq(calls.screenshot_pause, { "gestures" })
		helpers.assert_eq(actions.execute_single("open_config"), false,
			"the shared auxiliary fence must block registry delivery")
		helpers.assert_eq(#calls.open, 1)
		helpers.assert_eq(actions.resume_after_cleanup(), true)
		helpers.assert_eq(calls.resume, 1)
		helpers.assert_eq(calls.pause, 2,
			"resume preflight must rejoin cleanup before reopening")
		helpers.assert_eq(calls.screenshot_pause, { "gestures", "gestures" })
		helpers.assert_eq(calls.screenshot_resume, { "gestures" })
		helpers.assert_eq(actions.execute_single("open_config"), true)
		helpers.assert_eq(#calls.open, 2)
	end)

	it("pins nested axis dispatch to the gesture parent", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions({ axis_during_release = true })
		helpers.assert_eq(actions.execute_single(
			"open_config", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.nested_axis_result, true)
		helpers.assert_eq(#calls.after, 1)
		helpers.assert_eq(calls.after[1].label, "line down")
		helpers.assert_eq(calls.after[1].parent, "gestures",
			"a nested keyboard dispatch must not lend its shortcut parent to an axis")
	end)

	it("routes catalogue lock_screen through the scoped mouse owner", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.execute_single(
			"lock_screen", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.mouse_actions[#calls.mouse_actions], {
			name = "lock_screen", parent = "shortcut_bindings",
		})
		helpers.assert_eq(actions.execute_single("lock_screen", "tap_3"), true)
		helpers.assert_eq(calls.mouse_actions[#calls.mouse_actions], {
			name = "lock_screen", parent = "gestures",
		})
	end)
end)
