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

local function it(name, callback)
	helpers.it(name, function()
		Fixture.with_fixture(callback)
	end)
end

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


helpers.describe("gesture Actions native result diagnostics", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		it("reports system-key post " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ system_key_post_mode = mode })
			helpers.assert_eq(actions.execute_single("vol_up"), true)
			helpers.assert_eq(#calls.system_key_posts, 2,
				"both hardware-key phases must reach the native boundary")
			helpers.assert_eq(#calls.errors, 2,
				"each refused hardware-key phase must reach the file logger")
		end)

		it("reports window-action " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ window_action_mode = mode })
			for _, action in ipairs({ "snap_left", "snap_right", "maximize" }) do
				helpers.assert_eq(actions.execute_single(action), true)
			end
			helpers.assert_eq(#calls.window_actions, 3)
			helpers.assert_eq(#calls.errors, 3,
				"each refused window action must reach the file logger")
		end)
	end
end)


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


helpers.describe("gesture Actions lookup transaction", function()
	for _, case in ipairs({
		{ binding = "tap_3", parent = "gestures", sibling = "shortcut_bindings" },
		{ binding = "keyboard__cmd_1", parent = "shortcut_bindings", sibling = "gestures" },
	}) do
		it("normalizes lookup binding provenance to " .. case.parent, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions()
			helpers.assert_eq(actions.execute_single("lookup", case.binding), true)
			helpers.assert_eq(calls.after[1].parent, case.parent)
			helpers.assert_eq(actions.force_cleanup(case.sibling), true)
			helpers.assert_eq(calls.fire(calls.after[1].token), true,
				"a sibling lifecycle must not consume the lookup timer")

			local actions2, calls2 = fresh_actions()
			helpers.assert_eq(actions2.execute_single("lookup", case.binding), true)
			helpers.assert_eq(actions2.force_cleanup(case.parent), true)
			helpers.assert_eq(calls2.fire(calls2.after[1].token), false,
				"the matching feature parent must join the lookup timer")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		it("does not click when timer acquisition returns " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ prepare_mode = mode })
			helpers.assert_eq(actions.trigger_lookup(), false)
			helpers.assert_eq(#calls.mouse_posts, 0)
			helpers.assert_eq(#calls.keys, 0)
		end)

		it("rolls back the timer when mouse position read returns " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ mouse_read_mode = mode })
			helpers.assert_eq(actions.trigger_lookup(), false)
			helpers.assert_eq(calls.rollback, 1)
			helpers.assert_eq(#calls.mouse_posts, 0)
			helpers.assert_eq(calls.fire(calls.after[1].token), false)
			helpers.assert_eq(#calls.keys, 0)
		end)

		for _, boundary in ipairs({ "down_construct", "up_construct", "down_post", "up_post" }) do
			it("rolls back the timer when " .. boundary .. " returns " .. mode, function(fresh_actions, with_feature_lifecycles)
				local actions, calls = fresh_actions({ [boundary .. "_mode"] = mode })
				helpers.assert_eq(actions.trigger_lookup(), false)
				helpers.assert_eq(calls.rollback, 1)
				helpers.assert_eq(calls.fire(calls.after[1].token), false,
					"a rolled-back lookup timer must remain permanently inert")
				helpers.assert_eq(#calls.keys, 0)
			end)
		end
	end

	it("retains PAUSE when position read reenters the lifecycle", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions({ pause_on_mouse_read = true })
		helpers.assert_eq(actions.trigger_lookup(), false)
		helpers.assert_eq(calls.aux_is_paused(), true)
		helpers.assert_eq(calls.rollback, 1)
		helpers.assert_eq(#calls.mouse_posts, 0)
	end)

	it("posts only cleanup mouse-up work when mouse-down reenters PAUSE", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions({ pause_on_post = 1 })
		helpers.assert_eq(actions.trigger_lookup(), false)
		helpers.assert_eq(calls.lookup_cleanup_results, { false },
			"the real composite PAUSE cannot settle inside mouse-down post")
		helpers.assert_eq(calls.aux_is_paused(), true)
		helpers.assert_eq(calls.mouse_posts, { 1, 2 })
		helpers.assert_eq(calls.rollback, 1)
		helpers.assert_eq(#calls.keys, 0)
		helpers.assert_eq(actions.force_cleanup("gestures"), true)
	end)

	for _, parent in ipairs({ "gestures", "shortcut_bindings" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			it("retains " .. parent .. " lookup mouse-up debt after " .. mode,
				function(fresh_actions, with_feature_lifecycles)
					local sibling = parent == "gestures"
						and "shortcut_bindings" or "gestures"
					local actions, calls = fresh_actions({
						pause_on_post = 1,
						pause_parent = parent,
						up_post_mode = mode,
					})
					helpers.assert_eq(actions.trigger_lookup(parent), false)
					helpers.assert_eq(calls.lookup_cleanup_results, { false })
					helpers.assert_eq(#calls.mouse_post_attempts, 2,
						"the failed emergency mouse-up must be attempted once")
					local exact_up = calls.mouse_post_attempts[2]
					helpers.assert_eq(actions.force_cleanup(sibling), true,
						"a sibling PAUSE cannot consume foreign release debt")
					helpers.assert_eq(#calls.mouse_post_attempts, 2)
					helpers.assert_eq(actions.force_cleanup(parent), false)
					helpers.assert_eq(calls.mouse_post_attempts[3] == exact_up, true,
						"matching retry must retain the exact mouse-up identity")
					calls.controls.up_post_mode = "success"
					helpers.assert_eq(actions.force_cleanup(parent), true)
					helpers.assert_eq(calls.mouse_post_attempts[4] == exact_up, true)
					helpers.assert_eq(calls.mouse_posts, { 1, 2 })
					helpers.assert_eq(calls.fire(calls.after[1].token), false)
					helpers.assert_eq(#calls.keys, 0)
				end)
		end
	end

	it("retries retained lookup mouse-up debt before the next lookup", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions({ up_post_mode = "false" })
		helpers.assert_eq(actions.trigger_lookup("gestures"), false)
		local exact_up = calls.mouse_post_attempts[2]
		helpers.assert_eq(calls.mouse_post_attempts[3] == exact_up, true,
			"initial cleanup must retain the exact refused mouse-up")

		calls.controls.up_post_mode = "success"
		helpers.assert_eq(actions.trigger_lookup("gestures"), true,
			"the next lookup must first settle retained release debt")
		helpers.assert_eq(calls.mouse_post_attempts[4] == exact_up, true,
			"recovery must retry the exact retained mouse-up identity")
		helpers.assert_eq(#calls.after, 2,
			"a fresh lookup may acquire its timer only after cleanup commits")
		helpers.assert_eq(calls.fire(calls.after[1].token), false,
			"the rolled-back timer from the failed lookup must remain inert")
		helpers.assert_eq(calls.fire(calls.after[2].token), true)
		helpers.assert_eq(#calls.keys, 1)
	end)

	it("reports retained lookup mouse-up debt when recovery still refuses", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions({ up_post_mode = "false" })
		helpers.assert_eq(actions.trigger_lookup("gestures"), false)
		local exact_up = calls.mouse_post_attempts[2]
		local errors_before = #calls.errors

		helpers.assert_eq(actions.trigger_lookup("gestures"), false)
		helpers.assert_eq(calls.mouse_post_attempts[4] == exact_up, true,
			"recovery must retry the exact retained mouse-up identity")
		helpers.assert_eq(#calls.after, 1,
			"a refused cleanup may not acquire a sibling lookup timer")
		helpers.assert_eq(#calls.errors, errors_before + 1)
		helpers.assert_true(calls.errors[#calls.errors].message:find(
			"Dictionary lookup mouse-up cleanup remains pending", 1, true) ~= nil,
			"ongoing lookup disability must remain visible in the log")
	end)
end)


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


helpers.describe("gesture Actions composite resume", function()
	for _, child in ipairs({ "text", "mouse", "screenshot" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			it("keeps aggregate admission closed during " .. child
				.. " resume " .. mode, function(fresh_actions, with_feature_lifecycles)
				local options = { reenter_during_resume = child }
				options[child .. "_resume_mode"] = mode
				local actions, calls = fresh_actions(options)
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), false)
				helpers.assert_eq(calls.reentrant_results, { false },
					"a child resume callback must observe the composite fence")
				helpers.assert_eq(#calls.open, 0,
					"Aux side effects may not escape before every child commits")
				helpers.assert_eq(calls.aux_is_paused("gestures"), true)
				helpers.assert_eq(calls.text_is_paused("gestures"), true)
				helpers.assert_eq(calls.mouse_is_paused("gestures"), true)
				helpers.assert_eq(calls.screenshot_is_paused("gestures"), true)
			end)
		end
	end

	for _, child in ipairs({ "text", "mouse", "screenshot" }) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			it("retains the composite fence when " .. child
				.. " rollback pause returns " .. mode, function(fresh_actions, with_feature_lifecycles)
				local options = {
					rollback_pause_kind = child,
					rollback_pause_mode = mode,
				}
				options[child .. "_resume_mode"] = "false"
				options[child .. "_resume_mutates"] = true
				local actions, calls = fresh_actions(options)
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), false)
				helpers.assert_eq(actions.execute_single("open_config"), false)
				helpers.assert_eq(#calls.open, 0)
				local paused
				if child == "text" then
					paused = calls.text_is_paused("gestures")
				elseif child == "mouse" then
					paused = calls.mouse_is_paused("gestures")
				else
					paused = calls.screenshot_is_paused("gestures")
				end
				helpers.assert_eq(paused, false,
					"the mutated child must remain observable as exact rollback debt")
				helpers.assert_eq(actions.force_cleanup("gestures"), false,
					"matching cleanup must retry rather than hide the refused inverse")
				calls.controls.rollback_pause_mode = "success"
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				calls.controls[child .. "_resume_mode"] = "success"
				calls.controls[child .. "_resume_mutates"] = false
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
				helpers.assert_eq(actions.execute_single("open_config"), true)
			end)
		end
	end

	for _, phase in ipairs({ "cleanup", "resume" }) do
		for _, owner in ipairs({ "aux", "text", "mouse", "screenshot" }) do
			for _, edge in ipairs({ "paused", "pending" }) do
				for _, mode in ipairs({ "nil", "throw" }) do
					it("fails closed on " .. phase .. " " .. owner .. " "
						.. edge .. " query " .. mode, function(fresh_actions, with_feature_lifecycles)
						local options = {}
						options[owner .. "_" .. edge .. "_query_mode"] = mode
						if phase == "resume" then options.query_fault_phase = "resume" end
						local actions, calls = fresh_actions(options)
						if phase == "resume" then
							helpers.assert_eq(actions.force_cleanup("gestures"), true)
							helpers.assert_eq(actions.resume_after_cleanup("gestures"), false)
						else
							helpers.assert_eq(actions.force_cleanup("gestures"), false)
						end
						helpers.assert_eq(actions.execute_single("open_config"), false)
						helpers.assert_eq(#calls.open, 0,
							"an ambiguous query may never open aggregate admission")
						helpers.assert_true(calls.pause > 0)
						helpers.assert_true(#calls.text_lifecycle > 0)
						helpers.assert_true(#calls.mouse_lifecycle > 0)
						helpers.assert_true(#calls.screenshot_pause > 0,
							"cleanup must continue through every sibling owner")

						calls.controls[owner .. "_" .. edge .. "_query_mode"] = nil
						calls.controls.query_fault_phase = nil
						helpers.assert_eq(actions.force_cleanup("gestures"), true)
						helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
						helpers.assert_eq(actions.execute_single("open_config"), true)
					end)
				end
			end
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		it("retains composite debt when auxiliary rollback pause returns " .. mode,
			function(fresh_actions, with_feature_lifecycles)
				local actions, calls = fresh_actions({
					rollback_pause_kind = "auxiliary",
					rollback_pause_mode = mode,
					text_resume_mode = "false",
					text_resume_mutates = true,
				})
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), false)
				helpers.assert_eq(calls.aux_is_paused("gestures"), false,
					"the opened Aux child remains observable behind the composite fence")
				helpers.assert_eq(actions.execute_single("open_config"), false)
				helpers.assert_eq(#calls.open, 0)
				helpers.assert_eq(actions.force_cleanup("gestures"), false,
					"matching cleanup retries the exact refused Aux inverse")
				calls.controls.rollback_pause_mode = "success"
				helpers.assert_eq(actions.force_cleanup("gestures"), true)
				calls.controls.text_resume_mode = "success"
				calls.controls.text_resume_mutates = false
				helpers.assert_eq(actions.resume_after_cleanup("gestures"), true)
				helpers.assert_eq(actions.execute_single("open_config"), true)
			end)
	end

	it("passes the exact parent through every composite owner and query", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions()
		helpers.assert_eq(actions.force_cleanup("shortcut_bindings"), true)
		helpers.assert_eq(actions.resume_after_cleanup("shortcut_bindings"), true)
		helpers.assert_eq(actions.execute_single(
			"open_config", "keyboard__cmd_1"), true)

		helpers.assert_true(#calls.click_force_parents > 0)
		helpers.assert_true(#calls.click_release_parents > 0)
		helpers.assert_true(#calls.sticky_clear_parents > 0)
		for _, parent in ipairs(calls.click_force_parents) do
			helpers.assert_eq(parent, "shortcut_bindings")
		end
		for _, parent in ipairs(calls.click_release_parents) do
			helpers.assert_eq(parent, "shortcut_bindings")
		end
		for _, parent in ipairs(calls.sticky_clear_parents) do
			helpers.assert_eq(parent, "shortcut_bindings")
		end
		for _, calls_for_owner in ipairs({
			calls.text_lifecycle, calls.mouse_lifecycle,
			calls.aux_queries, calls.text_queries,
			calls.mouse_queries, calls.screenshot_queries,
		}) do
			helpers.assert_true(#calls_for_owner > 0,
				"each shared lifecycle/query recorder must be exercised")
			for _, call in ipairs(calls_for_owner) do
				helpers.assert_eq(call.parent, "shortcut_bindings",
					"omitting or substituting the owner parent must fail this recorder")
			end
		end
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		it("compensates auxiliary resume when screenshot resume returns " .. mode, function(fresh_actions, with_feature_lifecycles)
			local actions, calls = fresh_actions({ screenshot_resume_mode = mode })
			helpers.assert_eq(actions.force_cleanup(), true)
			helpers.assert_eq(calls.aux_is_paused(), true)
			helpers.assert_eq(actions.resume_after_cleanup(), false)
			helpers.assert_eq(calls.resume, 1)
			helpers.assert_eq(calls.pause, 3,
				"preflight cleanup and reverse compensation must both retain ownership")
			helpers.assert_eq(calls.screenshot_pause,
				{ "gestures", "gestures", "gestures" },
				"the screenshot claim must also be restored after a hostile resume refusal")
			helpers.assert_eq(calls.aux_is_paused(), true)
			helpers.assert_eq(actions.execute_single("open_config"), false)
			helpers.assert_eq(#calls.open, 0)
		end)
	end

	it("rolls both owners back when screenshot resume reenters auxiliary PAUSE", function(fresh_actions, with_feature_lifecycles)
		local actions, calls = fresh_actions({ pause_during_screenshot_resume = true })
		helpers.assert_eq(actions.force_cleanup(), true)
		helpers.assert_eq(actions.resume_after_cleanup(), false)
		helpers.assert_eq(calls.aux_is_paused(), true)
		helpers.assert_eq(calls.pause, 3)
		helpers.assert_eq(calls.screenshot_pause,
			{ "gestures", "gestures", "gestures" })
	end)
end)
