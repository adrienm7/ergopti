--- tests/unit/modules/gestures/actions/test_composite_resume.lua

--- ==============================================================================
--- MODULE: Gesture Actions composite resume
--- DESCRIPTION:
--- Exercises gesture Actions composite resume through the shared isolated fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

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
