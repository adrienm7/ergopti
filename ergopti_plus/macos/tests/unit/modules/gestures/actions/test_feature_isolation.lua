--- tests/unit/modules/gestures/actions/test_feature_isolation.lua

--- ==============================================================================
--- MODULE: Gesture Actions feature isolation
--- DESCRIPTION:
--- Exercises gesture Actions feature isolation through the shared isolated fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("gesture Actions feature isolation", function()
	it("keeps keyboard actions live when gestures are off and vice versa", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		helpers.assert_eq(actions.execute_single("open_config"), false)
		helpers.assert_eq(
			actions.execute_single("open_config", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.open[1].parent, "shortcut_bindings")
		helpers.assert_eq(actions.execute_single(
			"screenshot_region_clipboard", "keyboard__cmd_1"), true)
		helpers.assert_eq(calls.action_parents[#calls.action_parents],
			"shortcut_bindings")

		helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true)
		helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
		helpers.assert_eq(actions.execute_single("open_config"), true)
		helpers.assert_eq(calls.open[#calls.open].parent, "gestures")
		helpers.assert_eq(
			actions.execute_single("open_config", "keyboard__cmd_1"), false)
	end)

	it("keeps a sibling search timer authorized and published in both directions", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions()
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter(
			"keyboard__cmd_1", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.execute_single(
			"search_web", "keyboard__cmd_1"), true)
		local shortcut_timer = calls.hs.timer.__timers[#calls.hs.timer.__timers]
		helpers.assert_not_nil(shortcut_timer)
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		helpers.assert_eq(shortcut_timer.running, true,
			"gesture cleanup must not stop a shortcut-owned search timer")
		shortcut_timer:fire()
		helpers.assert_eq(#calls.opened_urls, 1,
			"the surviving shortcut capture must still publish its browser URL")

		helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
		helpers.assert_eq(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.execute_single("search_web", "tap_3"), true)
		local gesture_timer = calls.hs.timer.__timers[#calls.hs.timer.__timers]
		helpers.assert_true(gesture_timer ~= shortcut_timer)
		helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true)
		helpers.assert_eq(gesture_timer.running, true,
			"shortcut cleanup must not stop a gesture-owned search timer")
		gesture_timer:fire()
		helpers.assert_eq(#calls.opened_urls, 2,
			"the surviving gesture capture must still publish its browser URL")
	end)

	it("keeps both feature directions isolated and preserves global pause claims", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions()
		with_feature_lifecycles(actions, calls, function(Shortcuts, Gestures, feature)
			helpers.assert_eq(Shortcuts.start(), true)
			helpers.assert_eq(Gestures.enable_all(), true)
			helpers.assert_eq(feature.bindings_started, true)
			helpers.assert_eq(feature.keyboard_started, true)

			-- `feature_toggle` fences only static/configurable shortcuts. Gesture
			-- actions must still cross every formerly shared owner non-vacuously.
			helpers.assert_eq(Shortcuts.pause_bindings("feature_toggle"), true)
			helpers.assert_eq(feature.bindings_started, false)
			helpers.assert_eq(feature.keyboard_started, false)
			helpers.assert_eq(feature.keyboard_execute("open_config"), false)
			helpers.assert_eq(actions.execute_single("select_line"), true)
			helpers.assert_eq(actions.execute_single("teleport_mouse"), true)
			helpers.assert_eq(actions.execute_single("spotlight_mouse"), true)
			helpers.assert_eq(actions.execute_single(
				"screenshot_region_clipboard"), true)
			helpers.assert_eq(calls.text_actions[#calls.text_actions].parent, "gestures")
			helpers.assert_eq(calls.mouse_actions[#calls.mouse_actions].parent, "gestures")

			-- Reverse the feature split. Static screenshot and a configurable SG
			-- shortcut remain live while direct gesture dispatch is fenced.
			helpers.assert_eq(Shortcuts.resume_bindings("feature_toggle"), true)
			helpers.assert_eq(Gestures.disable_all(), true)
			helpers.assert_eq(feature.static_screenshot(), true)
			helpers.assert_eq(feature.keyboard_execute("open_config"), true)
			helpers.assert_eq(calls.open[#calls.open].parent, "shortcut_bindings")
			helpers.assert_eq(actions.execute_single("open_config"), false)

			-- The global ScriptControl claim joins both ON scopes. Feature changes
			-- made behind that fence survive its release: neither OFF feature is
			-- reopened by the global resume transaction.
			helpers.assert_eq(Gestures.enable_all(), true)
			helpers.assert_eq(Shortcuts.pause_bindings("script_control"), true)
			helpers.assert_eq(Gestures.suspend(), true)
			helpers.assert_eq(feature.static_screenshot(), false)
			helpers.assert_eq(feature.keyboard_execute("open_config"), false)
			helpers.assert_eq(actions.execute_single("open_config"), false)

			helpers.assert_eq(Shortcuts.pause_bindings("feature_toggle"), true)
			helpers.assert_eq(Gestures.disable_all(), true)
			helpers.assert_eq(Shortcuts.resume_bindings("script_control"), true)
			helpers.assert_eq(Gestures.resume(), true)
			helpers.assert_eq(feature.bindings_started, false)
			helpers.assert_eq(feature.keyboard_started, false)
			helpers.assert_eq(actions.execute_single("open_config"), false)

			helpers.assert_eq(Shortcuts.resume_bindings("feature_toggle"), true)
			helpers.assert_eq(feature.static_screenshot(), true)
			helpers.assert_eq(feature.keyboard_execute("open_config"), true)
			helpers.assert_eq(actions.execute_single("open_config"), false,
				"gesture OFF intent must survive global resume and shortcut reopen")
			helpers.assert_eq(Gestures.enable_all(), true)
			helpers.assert_eq(actions.execute_single("open_config"), true)
		end)
	end)
end)
