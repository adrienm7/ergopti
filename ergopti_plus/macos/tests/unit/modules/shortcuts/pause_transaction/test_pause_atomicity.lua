--- tests/unit/modules/shortcuts/pause_transaction/test_pause_atomicity.lua

--- ==============================================================================
--- MODULE: Script-Control Pause Atomicity Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context
local Assertions = require("tests.support.pause_transaction_assertions")
local count_notifications = Assertions.count_notifications
local has_error_containing = Assertions.has_error_containing
local assert_reversible_modules_running = Assertions.assert_reversible_modules_running

helpers.describe("script-control pause transaction is atomic", function()
	helpers.it("rolls an originally-OFF shortcut claim back without starting children", function()
		local calls = { pause = 0, release = 0, resume = 0 }
		with_context({
			pause_failure = { step = "gestures_pause", mode = "false" },
			shortcuts_factory = function()
				return {
					is_bindings_started = function() return false end,
					pause_bindings = function(parent)
						helpers.assert_eq(parent, "script_control")
						calls.pause = calls.pause + 1
						return true
					end,
					resume_bindings = function()
						calls.resume = calls.resume + 1
						return true
					end,
					release_bindings_pause_claim = function(parent)
						helpers.assert_eq(parent, "script_control")
						calls.release = calls.release + 1
						return true
					end,
				}
			end,
		}, function(script_control, ctx)

			helpers.assert_eq(script_control.pause_all(), true)
			ctx.fire_deferred()
			ctx.pause_callback(true, "native-paused")
			helpers.assert_eq(calls.pause, 1)
			helpers.assert_eq(calls.release, 1,
				"failed PAUSE must release only the OFF snapshot's global claim")
			helpers.assert_eq(calls.resume, 0,
				"rollback must not manufacture a shortcut ON transition")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(ctx.calls.karabiner_resume, 1)
			ctx.resume_callback(true, "native-running")
			script_control.stop()
		end)
	end)

	local pause_steps = {
		{ step = "keymap_pause", label = "keymap.pause_processing", rollback = "keymap_resume" },
		{ step = "shortcuts_pause", label = "shortcuts.pause_bindings", rollback = "shortcuts_resume" },
		{ step = "gestures_pause", label = "gestures.suspend", rollback = "gestures_resume" },
		{ step = "mlx_stop", label = "api_mlx.stop_warmup", rollback = "mlx_resume" },
		{ step = "warmup_stop", label = "warmup_controller.pause_warmup", rollback = "warmup_resume" },
		-- These three operations deliberately have no inverse. Re-opening a stale
		-- prediction/tooltip is unsafe, and Ollama stop_warmup only invalidates one
		-- in-flight generation without disabling readiness or a retry chain. They
		-- remain REQUIRED, however: a throw/false must still abort PAUSED and roll
		-- every reversible module back to its exact pre-pause state.
		{ step = "ollama_stop", label = "api_ollama.stop_warmup" },
		{ step = "keymap_reset", label = "keymap.reset_predictions" },
		{ step = "tooltip_hide", label = "tooltip.hide_forced" },
	}

	helpers.it("reopens admission only after a refused native pause settles", function()
		with_context(nil, function(script_control, ctx)
			helpers.assert_true(script_control.pause_all())
			helpers.assert_not_nil(ctx.admission_fence)
			ctx.fire_deferred()
			ctx.pause_callback(false, "native pause refused")

			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_nil(ctx.admission_fence,
				"failed PAUSED acknowledgement must roll admission back exactly")
			helpers.assert_eq(ctx.calls.admission_release, 1)
			helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1)
			script_control.stop()
		end)
	end)

	helpers.it("fails closed when the Karabiner enabled-state probe is not boolean", function()
		for _, mode in ipairs({ "nil", "non_boolean" }) do
			with_context({ get_enabled_mode = mode }, function(script_control, ctx)
				helpers.assert_true(script_control.pause_all())
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(#ctx.call_order, 0,
					"an ambiguous native snapshot may not mutate local owners")
				helpers.assert_eq(ctx.calls.karabiner_pause, nil,
					"an ambiguous native snapshot may not dispatch a transition")
				helpers.assert_eq(ctx.calls.admission_release, 1)
				helpers.assert_nil(ctx.admission_fence,
					"a clean preflight refusal must release the exact admission fence")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}))
				helpers.assert_eq(count_notifications(ctx,
					"script_control.pause_failed", "error"), 1)
				helpers.assert_true(script_control.stop())
			end)
		end
	end)

	helpers.it("reuses a retained preflight fence on the next explicit pause", function()
		local cases = {
			{
				name = "false",
				options = { get_enabled_throws = true, admission_release_failures = 1 },
			},
			{
				name = "throw",
				options = { get_enabled_throws = true, admission_release_throws = 1 },
			},
			{
				name = "nil probe / false release",
				options = { get_enabled_mode = "nil", admission_release_failures = 1 },
			},
			{
				name = "non-boolean probe / throw release",
				options = { get_enabled_mode = "non_boolean", admission_release_throws = 1 },
			},
		}
		for _, case in ipairs(cases) do
			with_context(case.options, function(script_control, ctx)
				helpers.assert_true(script_control.pause_all())
				local exact_fence = ctx.admission_fence
				helpers.assert_not_nil(exact_fence,
					case.name .. " release refusal must retain the acquired fence")
				helpers.assert_eq(ctx.calls.admission_release, 1,
					"preflight failure must attempt exact rollback immediately")
				helpers.assert_true(ctx.admission_release_tokens[1] == exact_fence)
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}))
				helpers.assert_eq(count_notifications(ctx,
					"script_control.pause_failed", "error"), 1)

				case.options.get_enabled_throws = false
				case.options.get_enabled_mode = nil
				helpers.assert_true(script_control.pause_all(),
					case.name .. " retained fence must keep explicit pause retry reachable")
				helpers.assert_eq(ctx.calls.input_drain, 1,
					"the exact retained fence already owns the idle-to-PAUSED boundary")
				helpers.assert_eq(ctx.calls.admission_acquire, 1,
					"retry must never request a second fence while the first remains active")
				helpers.assert_true(ctx.admission_fence == exact_fence)
				ctx.fire_deferred()
				helpers.assert_eq(ctx.calls.karabiner_pause, 1)
				ctx.pause_callback(true, "retry-paused")
				helpers.assert_eq(script_control.is_paused(), true)
				helpers.assert_true(ctx.admission_fence == exact_fence,
					"successful PAUSED commit retains the same fence until resume")
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
				helpers.assert_eq(count_notifications(ctx,
					"script_control.paused", "warning"), 1)
				helpers.assert_eq(count_notifications(ctx,
					"script_control.pause_failed", "error"), 1,
					"the successful retry must not republish the prior failure")
				helpers.assert_true(script_control.stop())
			end)
		end
	end)

	helpers.it("rolls every partial local pause back before publishing any PAUSED state", function()
		for _, mode in ipairs({ "throw", "false" }) do
			for failed_index, failed_step in ipairs(pause_steps) do
				with_context({
					pause_failure = { step = failed_step.step, mode = mode },
				}, function(script_control, ctx)

					script_control.pause_all()
					ctx.fire_deferred()
					local pause_order_start = #ctx.call_order + 1
					ctx.pause_callbacks[1](true, "paused")

					helpers.assert_eq(script_control.is_paused(), false,
						mode .. " from " .. failed_step.step .. " must preserve the running state")
					helpers.assert_eq(ctx.calls.karabiner_resume, 1,
						"a partial local pause must immediately request native RESUMED rollback")
					helpers.assert_eq(ctx.native_state, "paused",
						"the rollback must remain pending until native RESUMED is acknowledged")
					helpers.assert_not_nil(ctx.admission_fence,
						"local pause failure must keep admission closed through native rollback")
					helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 0,
						"partial local pause must never publish PAUSED")
					helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 0,
						"failure must remain unpublished until native rollback settles")
					helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}),
						"listeners must never observe the uncommitted PAUSED state")
					assert_reversible_modules_running(ctx, mode .. " from " .. failed_step.step)

					local expected_order = {}
					for step_index = 1, failed_index do
						expected_order[#expected_order + 1] = pause_steps[step_index].step
					end
					for step_index = failed_index, 1, -1 do
						local rollback = pause_steps[step_index].rollback
						if rollback then expected_order[#expected_order + 1] = rollback end
					end
					local actual_order = {}
					for index = pause_order_start, #ctx.call_order do
						actual_order[#actual_order + 1] = ctx.call_order[index]
					end
					helpers.assert_true(helpers.deep_equal(actual_order, expected_order),
						"pause rollback must include the failing mutator and invert in reverse order")

					local failed_attempts = ctx.calls[failed_step.step]
					ctx.pause_callbacks[1](true, "duplicate-paused")
					helpers.assert_eq(ctx.calls[failed_step.step], failed_attempts,
						"a duplicate PAUSED callback must not re-enter local quiescence during rollback")
					helpers.assert_eq(ctx.calls.karabiner_resume, 1,
						"a duplicate PAUSED callback must not request another native rollback")

					ctx.resume_callbacks[1](true, "running-restored")
					helpers.assert_eq(ctx.native_state, "running")
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_nil(ctx.admission_fence,
						"only the settled RESUMED rollback may reopen admission")
					helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1,
						"pause failure may be published only after native RESUMED")
					helpers.assert_true(has_error_containing(ctx, failed_step.label),
						"the root failing pause step must be named in the file logger")
					helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}))

					ctx.pause_failure = nil
					script_control.pause_all()
					ctx.fire_deferred()
					ctx.pause_callbacks[2](true, "retry-paused")
					helpers.assert_eq(script_control.is_paused(), true,
						"a clean retry after rollback must remain reachable")
					helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
					helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
					script_control.stop()
				end)
			end
		end
	end)

	helpers.it("preflights inverse APIs before mutating the first pause subsystem", function()
		local cases = {
			{ inverse = "keymap_resume", label = "keymap.pause_processing" },
			{ inverse = "shortcuts_resume", label = "shortcuts.pause_bindings" },
			{ inverse = "gestures_resume", label = "gestures.suspend" },
			{ inverse = "mlx_resume", label = "api_mlx.stop_warmup" },
			{ inverse = "warmup_resume", label = "warmup_controller.pause_warmup" },
		}
		for _, case in ipairs(cases) do
			with_context({ missing_inverse = case.inverse }, function(script_control, ctx)
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")

				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(#ctx.call_order, 0,
					"every inverse must be preflighted before the first forward mutator runs")
				helpers.assert_eq(ctx.calls.karabiner_resume, 1,
					"native PAUSED must be rolled back after local preflight failure")
				ctx.resume_callbacks[1](true, "running-restored")
				helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1)
				helpers.assert_true(has_error_containing(ctx, case.label .. " has no inverse rollback"))
				assert_reversible_modules_running(ctx, "missing inverse preflight: " .. case.inverse)
				script_control.stop()
			end)
		end
	end)

	helpers.it("contains snapshot errors before any pause mutator can run", function()
		local cases = {
			{ step = "shortcuts_snapshot", label = "shortcuts.is_bindings_started" },
			{ step = "gestures_snapshot", label = "gestures.is_enabled" },
		}
		for _, mode in ipairs({ "throw", "non_boolean" }) do
			for _, case in ipairs(cases) do
				with_context({
					snapshot_failure = { step = case.step, mode = mode },
				}, function(script_control, ctx)
					script_control.pause_all()
					ctx.fire_deferred()
					ctx.pause_callbacks[1](true, "paused")

					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(#ctx.call_order, 0,
						"snapshot failure must happen before the first quiescence mutator")
					helpers.assert_eq(ctx.calls.karabiner_resume, 1)
					helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 0)
					ctx.resume_callbacks[1](true, "running-restored")
					helpers.assert_true(has_error_containing(ctx, case.label),
						"the failing snapshot must be named in the file logger")
					helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1)
					assert_reversible_modules_running(ctx, mode .. " snapshot: " .. case.step)
					script_control.stop()
				end)
			end
		end
	end)

	helpers.it("never invents PAUSED when native rollback settles fail-closed", function()
		with_context({
			pause_failure = { step = "keymap_pause", mode = "false" },
		}, function(script_control, ctx)
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callbacks[1](true, "paused")
			ctx.resume_callbacks[1](false, "resume-failed-closed")

			helpers.assert_eq(ctx.native_state, "paused",
				"failed native rollback must remain honestly modelled as PAUSED")
			helpers.assert_eq(script_control.is_paused(), false,
				"local quiescence failed, so script-control must not invent a PAUSED commit")
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, {}))
			helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 0)
			helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1)
			assert_reversible_modules_running(ctx, "fail-closed native rollback")

			ctx.pause_failure = nil
			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callbacks[2](true, "retry-paused")
			helpers.assert_eq(script_control.is_paused(), true,
				"the known native PAUSED state must permit a clean local pause retry")
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
			script_control.stop()
		end)
	end)
end)
