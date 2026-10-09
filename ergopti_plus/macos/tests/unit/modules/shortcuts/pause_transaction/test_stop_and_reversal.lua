--- tests/unit/modules/shortcuts/pause_transaction/test_stop_and_reversal.lua

--- ==============================================================================
--- MODULE: Script-Control Stop And Reversal Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context

helpers.describe("script-control resume transaction is atomic", function()
	helpers.it("stop retains and retries an exact admission release refusal", function()
		with_context(nil, function(script_control, ctx)
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callback(true, "paused")
			local exact_fence = ctx.admission_fence
			ctx.admission_release_throws = 1

			helpers.assert_true(not script_control.stop(),
				"stop cannot report settlement while admission remains fenced")
			helpers.assert_true(ctx.admission_fence == exact_fence)
			helpers.assert_true(exact_fence.active)
			helpers.assert_true(script_control.stop(),
				"a later stop must retry the same retained fence")
			helpers.assert_nil(ctx.admission_fence)
			helpers.assert_true(ctx.admission_release_tokens[1] == exact_fence)
			helpers.assert_true(ctx.admission_release_tokens[2] == exact_fence)
		end)
	end)

	helpers.it("joins an already-dispatched native transition before stopping", function()
		-- PAUSE direction: the exact admission fence and callback must survive stop.
		do
			with_context(nil, function(script_control, ctx)
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				helpers.assert_eq(ctx.calls.karabiner_pause, 1)
				local exact_fence = ctx.admission_fence
				helpers.assert_eq(script_control.stop(), false,
					"stop cannot discard a dispatched native PAUSE owner")
				helpers.assert_true(script_control.is_pause_transition_pending())
				helpers.assert_true(ctx.admission_fence == exact_fence)
				helpers.assert_eq(ctx.calls.admission_release, nil)

				ctx.pause_callbacks[1](true, "paused-after-stop-refusal")
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				helpers.assert_true(script_control.stop(),
					"terminal native ownership must make the later stop reachable")
				ctx.pause_callbacks[1](true, "duplicate-paused")
				helpers.assert_eq(ctx.calls.keymap_pause, 1)
			end)
		end

		-- RESUME direction: stop may not release the fence ahead of native RESUMED.
		do
			with_context(nil, function(script_control, ctx)
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")
				local exact_fence = ctx.admission_fence
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				helpers.assert_eq(ctx.calls.karabiner_resume, 1)
				helpers.assert_eq(script_control.stop(), false,
					"stop cannot discard a dispatched native RESUME owner")
				helpers.assert_true(script_control.is_pause_transition_pending())
				helpers.assert_true(ctx.admission_fence == exact_fence)
				helpers.assert_eq(ctx.calls.admission_release, nil)

				ctx.resume_callbacks[1](true, "resumed-after-stop-refusal")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				helpers.assert_nil(ctx.admission_fence)
				helpers.assert_true(script_control.stop())
				ctx.resume_callbacks[1](true, "duplicate-resumed")
				helpers.assert_eq(ctx.calls.keymap_resume, 1)
			end)
		end
	end)

	helpers.it("queues the original target again while native rollback is pending", function()
		-- A PAUSE whose local half fails is already destined back to ACTIVE. A new
		-- PAUSE request during that native rollback must survive as a fresh attempt.
		do
			with_context(nil, function(script_control, ctx)
				ctx.pause_failure = { step = "shortcuts_pause", mode = "false" }
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "native-paused")
				helpers.assert_eq(ctx.calls.karabiner_resume, 1,
					"local PAUSE refusal must own native ACTIVE rollback")
				helpers.assert_true(script_control.pause_all(),
					"same target during rollback must be queued, not mistaken for satisfaction")
				ctx.pause_failure = nil
				ctx.resume_callbacks[1](true, "native-running")
				helpers.assert_true(script_control.is_pause_transition_pending(),
					"terminal rollback must dispatch the queued PAUSE")
				ctx.fire_deferred()
				helpers.assert_eq(ctx.calls.karabiner_pause, 2)
				ctx.pause_callbacks[2](true, "retry-paused")
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				helpers.assert_true(script_control.stop())
			end)
		end

		-- Symmetric RESUME retry while the failed activation is being re-paused.
		do
			with_context(nil, function(script_control, ctx)
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")
				ctx.resume_failure = { step = "shortcuts_resume", mode = "false" }
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callbacks[1](true, "native-resumed")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"local RESUME refusal must own native PAUSED rollback")
				helpers.assert_true(script_control.resume_all(),
					"same target during rollback must be retained as latest intent")
				ctx.resume_failure = nil
				ctx.pause_callbacks[2](true, "native-repaused")
				helpers.assert_true(script_control.is_pause_transition_pending(),
					"terminal rollback must dispatch the queued RESUME")
				ctx.fire_deferred()
				helpers.assert_eq(ctx.calls.karabiner_resume, 2)
				ctx.resume_callbacks[2](true, "retry-resumed")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				helpers.assert_true(script_control.stop())
			end)
		end
	end)

end)
