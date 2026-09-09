--- tests/unit/modules/gestures/actions/test_lookup_transaction.lua

--- ==============================================================================
--- MODULE: Gesture Actions lookup transaction
--- DESCRIPTION:
--- Exercises gesture Actions lookup transaction through the shared isolated fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

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
