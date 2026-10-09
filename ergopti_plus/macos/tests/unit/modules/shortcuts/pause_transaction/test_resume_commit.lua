--- tests/unit/modules/shortcuts/pause_transaction/test_resume_commit.lua

--- ==============================================================================
--- MODULE: Script-Control Resume Commit Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context
local Assertions = require("tests.support.pause_transaction_assertions")
local count_notifications = Assertions.count_notifications

helpers.describe("script-control resume transaction is atomic", function()
	helpers.it("keeps PAUSED ownership when the Karabiner resume snapshot is ambiguous", function()
		for _, mode in ipairs({ "nil", "non_boolean" }) do
			local options = {}
			with_context(options, function(script_control, ctx)
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				ctx.pause_callback(true, "paused")
				local exact_fence = ctx.admission_fence
				local committed_calls = #ctx.call_order

				options.get_enabled_mode = mode
				helpers.assert_eq(script_control.resume_all(), false)
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_true(ctx.admission_fence == exact_fence,
					"ambiguous native state must retain the exact PAUSED admission fence")
				helpers.assert_eq(#ctx.call_order, committed_calls,
					"ambiguous native state may not resume a local owner")
				helpers.assert_eq(ctx.calls.karabiner_resume, nil,
					"ambiguous native state may not dispatch native RESUME")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))

				options.get_enabled_mode = nil
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callback(true, "resumed")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_nil(ctx.admission_fence)
				helpers.assert_true(script_control.stop())
			end)
		end
	end)

	helpers.it("keeps pause and resumes zero Hammerspoon modules when RESUMED fails", function()
		with_context(nil, function(script_control, ctx)
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callback(true, "paused")

			script_control.resume_all()
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_resume, 1)
			helpers.assert_eq(script_control.is_paused(), true,
				"resume request must keep the last ACKed pause state")
			helpers.assert_eq(ctx.calls.keymap_resume, nil)
			helpers.assert_eq(ctx.calls.shortcuts_resume, nil)
			helpers.assert_eq(ctx.calls.gestures_resume, nil)

			ctx.resume_callback(false, "cli-failed")
			helpers.assert_eq(script_control.is_paused(), true,
				"a failed CLI transition must leave the script fully paused")
			helpers.assert_eq(ctx.calls.keymap_resume, nil,
				"failure must resume zero Hammerspoon submodules")
			helpers.assert_eq(ctx.calls.shortcuts_resume, nil)
			helpers.assert_eq(ctx.calls.gestures_resume, nil)
			helpers.assert_true(#ctx.errors >= 1, "the failure must be logged")
			helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 1,
				"the user must see a non-blocking failure notification")
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
				"no resume listener may fire for a failed transition")
			script_control.stop()
		end)
	end)

	helpers.it("commits a successful completed-resume callback exactly once", function()
		with_context(nil, function(script_control, ctx)
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callback(true, "paused")
			helpers.assert_not_nil(ctx.admission_fence)

			script_control.resume_all()
			ctx.fire_deferred()
			ctx.resume_callback(true, "resumed")
			ctx.resume_callback(true, "duplicate-resumed")

			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_nil(ctx.admission_fence,
				"RESUMED plus local activation is the exact admission reopen point")
			helpers.assert_eq(ctx.calls.admission_release, 1)
			helpers.assert_eq(ctx.calls.keymap_resume, 1)
			helpers.assert_eq(ctx.calls.shortcuts_resume, 1)
			helpers.assert_eq(ctx.calls.gestures_resume, 1)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
			helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
			script_control.stop()
		end)
	end)

end)
