--- tests/unit/modules/gestures/actions/test_search_acquisition.lua

--- ==============================================================================
--- MODULE: Gesture Actions search acquisition
--- DESCRIPTION:
--- Exercises gesture Actions search acquisition epoch through the shared isolated fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

helpers.describe("gesture Actions search acquisition epoch", function()
	for _, boundary in ipairs({ "clear", "timer", "emit" }) do
		it("fences search when " .. boundary .. " reenters cleanup", function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ search_reenter = boundary })
			actions.init({ action_params = {} })
			helpers.assert_eq(actions.set_action_parameter(
				"tap_3", "search_web", "https://example.test/?q=%s"), true)
			helpers.assert_eq(actions.execute_single("search_web", "tap_3"), false)
			helpers.assert_eq(calls.clipboard_text(), "original",
				"cleanup must restore the exact clipboard snapshot after " .. boundary)
			if boundary == "timer" then
				helpers.assert_eq(calls.search_cleanup_results, { true },
					"timer construction has no native mutation outstanding")
			else
				helpers.assert_eq(calls.search_cleanup_results, { false },
					"clipboard mutation boundaries must remain pending until return")
			end
			if boundary ~= "emit" then
				helpers.assert_eq(#calls.keys, 0,
					"no copy key may cross an earlier lifecycle fence")
			end
			for _, timer in ipairs(calls.hs.timer.__timers or {}) do
				if timer.running then timer:fire() end
			end
			helpers.assert_eq(#calls.opened_urls, 0,
				"a stale search callback may never publish a URL")
			helpers.assert_eq(actions.force_cleanup("gestures"), true)
		end)
	end

	it("keeps clipboard restore visible until its native boundary returns", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions({ search_reenter = "restore" })
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.execute_single("search_web", "tap_3"), true)
		helpers.assert_eq(calls.clipboard_text(), "selected words")
		calls.hs.timer.__timers[1]:fire()
		helpers.assert_eq(calls.search_cleanup_results, { false })
		helpers.assert_eq(calls.clipboard_text(), "original")
		helpers.assert_eq(#calls.opened_urls, 0)
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		it("retains restore-boundary debt after inverse " .. mode, function(fresh_actions, with_feature_lifecycles)
			local controls = {
				search_reenter = "restore",
				search_restore_mode = mode,
			}
			local actions, calls = fresh_actions(controls)
			actions.init({ action_params = {} })
			helpers.assert_eq(actions.set_action_parameter(
				"tap_3", "search_web", "https://example.test/?q=%s"), true)
			helpers.assert_eq(actions.execute_single("search_web", "tap_3"), true)
			calls.hs.timer.__timers[1]:fire()
			helpers.assert_eq(calls.search_cleanup_results, { false })
			helpers.assert_eq(calls.clipboard_text(), "selected words")
			local restore_calls = calls.clipboard_restore_calls
			helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true)
			helpers.assert_eq(calls.clipboard_restore_calls, restore_calls)
			controls.search_restore_mode = nil
			helpers.assert_eq(actions.force_cleanup("gestures"), true)
			helpers.assert_eq(calls.clipboard_text(), "original")
			helpers.assert_eq(#calls.opened_urls, 0)
		end)
	end

	for _, boundary in ipairs({ "clear", "emit" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			it("retains exact " .. boundary .. " clipboard debt when restore "
				.. mode, function(fresh_actions, with_feature_lifecycles)
				local controls = {
					search_reenter = boundary,
					search_restore_mode = mode,
				}
				local actions, calls = fresh_actions(controls)
				actions.init({ action_params = {} })
				helpers.assert_eq(actions.set_action_parameter(
					"tap_3", "search_web", "https://example.test/?q=%s"), true)
				helpers.assert_eq(actions.execute_single("search_web", "tap_3"), false)
				helpers.assert_eq(calls.search_cleanup_results, { false },
					"re-entrant cleanup may not claim settlement before mutation returns")
				helpers.assert_eq(calls.clipboard_text(),
					boundary == "emit" and "selected words" or nil,
					"a refused restore must leave the exact native mutation observable")

				helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true,
					"a sibling parent may not consume gesture clipboard recovery debt")
				helpers.assert_eq(calls.clipboard_text(),
					boundary == "emit" and "selected words" or nil)

				controls.search_restore_mode = nil
				helpers.assert_eq(actions.force_cleanup("gestures"), true,
					"the matching parent must retry the retained snapshot exactly")
				helpers.assert_eq(calls.clipboard_text(), "original")
				for _, timer in ipairs(calls.hs.timer.__timers or {}) do
					if timer.running then timer:fire() end
				end
				helpers.assert_eq(#calls.opened_urls, 0,
					"a stale capture/recovery callback may never publish a URL")
			end)
		end
	end

	for _, case in ipairs({
		{ name = "cleanup after clear", controls = { search_reenter = "clear" } },
		{ name = "admission close after timer acquisition", controls = {
			aux_pause_on_query = 4,
		} },
	}) do
		it("arms clipboard recovery after " .. case.name, function(fresh_actions, with_feature_lifecycles)
			case.controls.search_restore_mode = "false"
			local actions, calls = fresh_actions(case.controls)
			actions.init({ action_params = {} })
			helpers.assert_eq(actions.set_action_parameter(
				"tap_3", "search_web", "https://example.test/?q=%s"), true)
			helpers.assert_eq(actions.execute_single("search_web", "tap_3"), false)
			helpers.assert_true(#calls.errors > 0,
				"a refused rollback must reach the file logger")

			local recovery_timer = nil
			for _, timer in ipairs(calls.hs.timer.__timers or {}) do
				if timer.running then recovery_timer = timer end
			end
			helpers.assert_not_nil(recovery_timer,
				"a refused rollback must retain an automatic retry capability")
			case.controls.search_restore_mode = nil
			recovery_timer:fire()
			helpers.assert_eq(calls.clipboard_text(), "original")
		end)
	end

	it("does not let a shortcut sibling consume gesture clipboard recovery debt", function(fresh_actions, with_feature_lifecycles)
		local controls = {
			search_reenter = "emit",
			search_restore_mode = "false",
		}
		local actions, calls = fresh_actions(controls)
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter(
			"tap_3", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.set_action_parameter(
			"keyboard__cmd_1", "search_web", "https://example.test/?q=%s"), true)
		helpers.assert_eq(actions.execute_single("search_web", "tap_3"), false)
		local restore_calls = calls.clipboard_restore_calls
		helpers.assert_eq(calls.clipboard_text(), "selected words")

		controls.search_restore_mode = nil
		helpers.assert_eq(actions.execute_single(
			"search_web", "keyboard__cmd_1"), true,
			"the registered sibling action remains owned when foreign debt refuses its work")
		helpers.assert_eq(calls.clipboard_restore_calls, restore_calls,
			"a sibling action may observe but never settle foreign recovery debt")
		helpers.assert_eq(calls.clipboard_text(), "selected words")
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
		helpers.assert_eq(calls.clipboard_restore_calls, restore_calls + 1)
		helpers.assert_eq(calls.clipboard_text(), "original")
	end)
end)
