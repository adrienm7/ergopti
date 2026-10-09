--- tests/unit/modules/shortcuts/pause_transaction/test_resume_rollback.lua

--- ==============================================================================
--- MODULE: Script-Control Resume Rollback Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context
local Assertions = require("tests.support.pause_transaction_assertions")
local count_notifications = Assertions.count_notifications
local has_error_containing = Assertions.has_error_containing

helpers.describe("script-control resume transaction is atomic", function()
	helpers.it("rolls every partial local resume back before publishing any failure", function()
		local resume_steps = {
			{ step = "keymap_resume", label = "keymap.resume_processing", rollback = "keymap_pause" },
			{ step = "shortcuts_resume", label = "shortcuts.resume_bindings", rollback = "shortcuts_pause" },
			{ step = "gestures_resume", label = "gestures.resume", rollback = "gestures_pause" },
			{ step = "mlx_resume", label = "api_mlx.resume_warmup", rollback = "mlx_stop" },
			{ step = "warmup_resume", label = "warmup_controller.resume_warmup", rollback = "warmup_stop" },
		}
		local failure_modes = { "throw", "false" }

		for _, mode in ipairs(failure_modes) do
			for failed_index, failed_step in ipairs(resume_steps) do
				with_context({
					resume_failure = { step = failed_step.step, mode = mode },
				}, function(script_control, ctx)
					script_control.pause_all()
					ctx.fire_deferred()
					ctx.pause_callbacks[1](true, "paused")

					script_control.resume_all()
					ctx.fire_deferred()
					local resume_order_start = #ctx.call_order + 1
					ctx.resume_callback(true, "resumed")

					helpers.assert_eq(script_control.is_paused(), true,
						mode .. " from " .. failed_step.step .. " must preserve the committed pause state")
					helpers.assert_eq(ctx.calls.karabiner_pause, 2,
						"a partial local resume must immediately request a native re-pause")
					helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0,
						"partial local resume must never publish success")
					helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 0,
						"failure must remain unpublished until the native re-pause is acknowledged")
					helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
						"listeners must keep observing pause throughout local rollback")
					local failed_attempts = ctx.calls[failed_step.step]
					ctx.resume_callback(true, "duplicate-resumed")
					helpers.assert_eq(ctx.calls[failed_step.step], failed_attempts,
						"a duplicate RESUMED callback must not re-enter local activation during native rollback")
					helpers.assert_eq(ctx.calls.karabiner_pause, 2,
						"a duplicate RESUMED callback must not request a second rollback")

					for step_index, step in ipairs(resume_steps) do
						if step.rollback then
							local expected = step_index <= failed_index and 2 or 1
							helpers.assert_eq(ctx.calls[step.rollback], expected,
								step.rollback .. " must be the exact inverse for " .. failed_step.step)
						end
					end
					local expected_order = {}
					for step_index = 1, failed_index do
						expected_order[#expected_order + 1] = resume_steps[step_index].step
					end
					for step_index = failed_index, 1, -1 do
						expected_order[#expected_order + 1] = resume_steps[step_index].rollback
					end
					local actual_order = {}
					for index = resume_order_start, #ctx.call_order do
						actual_order[#actual_order + 1] = ctx.call_order[index]
					end
					helpers.assert_true(helpers.deep_equal(actual_order, expected_order),
						"rollback must apply exact inverses in reverse activation order")

					ctx.pause_callbacks[2](true, "re-paused")
					helpers.assert_eq(script_control.is_paused(), true)
					helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 1,
						"failure may be published only after native PAUSED")
					helpers.assert_true(has_error_containing(ctx, failed_step.label),
						"the root failing resume step must be named in the file logger")
					helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))

					ctx.resume_failure = nil
					script_control.resume_all()
					ctx.fire_deferred()
					ctx.resume_callback(true, "retry-resumed")
					helpers.assert_eq(script_control.is_paused(), false,
						"a clean retry after rollback must remain reachable")
					helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
					script_control.stop()
				end)
			end
		end
	end)

	helpers.it("retains local re-pause debt until the same-state PAUSE settles it", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_context({ no_integration = true }, function(script_control, ctx)
				helpers.assert_true(script_control.pause_all())
				helpers.assert_true(script_control.is_paused())
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)

				ctx.resume_failure = { step = "shortcuts_resume", mode = "false" }
				ctx.pause_failure = { step = "shortcuts_pause", mode = mode }
				helpers.assert_eq(script_control.resume_all(), false,
					mode .. " re-pause refusal must abort the local resume")
				helpers.assert_true(script_control.is_paused())
				helpers.assert_true(script_control.is_pause_transition_pending(),
					"terminal request state must retain the exact local rollback debt")
				helpers.assert_eq(ctx.calls.shortcuts_resume, 1)
				helpers.assert_eq(ctx.calls.shortcuts_pause, 2,
					"initial pause plus failed rollback must target the same owner")

				helpers.assert_eq(script_control.pause_all(), false,
					"PAUSE while already PAUSED must retry the retained local inverse")
				helpers.assert_eq(ctx.calls.shortcuts_pause, 3)
				helpers.assert_eq(ctx.calls.shortcuts_resume, 1,
					"debt settlement may not acquire a resume successor")
				helpers.assert_true(script_control.is_pause_transition_pending())

				ctx.pause_failure = nil
				helpers.assert_true(script_control.pause_all())
				helpers.assert_eq(ctx.calls.shortcuts_pause, 4)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false,
					"literal re-pause settlement must consume the debt")
				ctx.resume_failure = nil
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				helpers.assert_true(script_control.stop())
			end)
		end
	end)

	helpers.it("keeps re-pause debt visible after the native rollback callback", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_context(nil, function(script_control, ctx)
				helpers.assert_true(script_control.pause_all())
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")

				ctx.resume_failure = { step = "shortcuts_resume", mode = "false" }
				ctx.pause_failure = { step = "shortcuts_pause", mode = mode }
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callbacks[1](true, "native-resumed")
				helpers.assert_true(script_control.is_pause_transition_pending(),
					"native re-pause callback must still own the transition")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2)

				ctx.pause_callbacks[2](true, "native-repaused")
				helpers.assert_true(script_control.is_paused())
				helpers.assert_true(script_control.is_pause_transition_pending(),
					"local inverse debt must outlive the now-terminal native transaction")
				helpers.assert_eq(script_control.pause_all(), false)
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"same-state local recovery may not publish a redundant native pause")

				ctx.pause_failure = nil
				helpers.assert_true(script_control.pause_all())
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				ctx.resume_failure = nil
				helpers.assert_true(script_control.resume_all())
				ctx.fire_deferred()
				ctx.resume_callbacks[2](true, "retry-resumed")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				helpers.assert_true(script_control.stop())
			end)
		end
	end)

end)
