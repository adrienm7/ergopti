--- tests/unit/modules/shortcuts/test_pause_transaction.lua

--- ==============================================================================
--- MODULE: Script-Control Pause Transaction Regression Tests
--- DESCRIPTION:
--- Drives the public pause/resume API across the script-control and Karabiner
--- boundary. Pause commits after PAUSED; resume commits only after the remap
--- layer reports RESUMED, publication, READY and input startup complete. Failed
--- or duplicated callbacks must never create a half-resumed driver.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context

local function count_notifications(ctx, title, kind)
	local count = 0
	for _, item in ipairs(ctx.notifications) do
		if item.title == title and item.kind == kind then count = count + 1 end
	end
	return count
end

local function has_error_containing(ctx, needle)
	for _, message in ipairs(ctx.errors) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

local function has_warning_containing(ctx, needle)
	for _, message in ipairs(ctx.warnings) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

local function assert_reversible_modules_running(ctx, context)
	for _, name in ipairs({
		"keymap", "shortcuts", "gestures", "mlx_warmup", "warmup_controller",
	}) do
		helpers.assert_eq(ctx.states[name], true,
			string.format("%s: reversible module '%s' must be restored", context, name))
	end
end





-- ===========================================
-- ===========================================
-- ======= 2/ ACK-Ordered Pause Commit =======
-- ===========================================
-- ===========================================

helpers.describe("script-control pause transaction waits for exact lease ACK", function()
	helpers.it("keeps every feature live until paced input is idle and cancels a queued reversal", function()
		with_context({ input_drain_deferred = true }, function(script_control, ctx)

			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(ctx.calls.input_drain, 1)
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, nil,
				"native pause must not overtake an owned paced replacement")
			helpers.assert_eq(ctx.calls.keymap_pause, nil)
			helpers.assert_eq(script_control.is_paused(), false)

			helpers.assert_true(script_control.resume_all(),
				"a rapid reversal must be accepted while the input drain owns pause")
			ctx.input_idle_callbacks[1]()
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, nil,
				"the queued resume must cancel pause before native publication")
			helpers.assert_eq(ctx.calls.keymap_pause, nil)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_nil(ctx.admission_fence,
				"a queued resume cancels pause before taking the admission fence")
			script_control.stop()
		end)
	end)

	helpers.it("does not publish or quiesce pause before PAUSED, then commits once", function()
		with_context(nil, function(script_control, ctx)

			script_control.pause_all()
			helpers.assert_not_nil(ctx.admission_fence,
				"the idle callback must close admission before native PAUSED is requested")
			helpers.assert_eq(script_control.is_paused(), false,
				"requesting pause must not publish a committed state")
			helpers.assert_eq(ctx.calls.karabiner_pause, nil,
				"the native transition request must be deferred off the caller/eventtap")
			helpers.assert_eq(ctx.calls.keymap_pause, nil,
				"Hammerspoon submodules must remain in their settled state before PAUSED")
			helpers.assert_eq(#ctx.pause_listener, 0, "listeners must wait for the exact ACK")
			helpers.assert_eq(#ctx.notifications, 0, "success notification must wait for the exact ACK")

			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, 1)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(ctx.calls.keymap_pause, nil)

			ctx.pause_callback(true, "paused")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(ctx.calls.keymap_pause, 1)
			helpers.assert_eq(ctx.calls.shortcuts_pause, 1)
			helpers.assert_eq(ctx.calls.gestures_pause, 1)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
			helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
			helpers.assert_not_nil(ctx.admission_fence,
				"committed pause retains the same admission owner until resume")

			ctx.pause_callback(true, "duplicate-paused")
			helpers.assert_eq(ctx.calls.keymap_pause, 1,
				"a duplicated native callback must not commit the pause twice")
			helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
			script_control.stop()
		end)
	end)
end)

helpers.describe("script-control: bindings child cleanup debt", function()
	helpers.it("settles pixel debt while preserving an originally OFF bindings layer", function()
		local calls = { pause = 0, resume = 0 }
		local debt = true
		with_context({
			shortcuts_factory = function()
				return {
					is_bindings_started = function() return false end,
					has_bindings_pause_debt = function() return debt end,
					pause_bindings = function()
						calls.pause = calls.pause + 1
						debt = false
						return true
					end,
					resume_bindings = function()
						calls.resume = calls.resume + 1
						return true
					end,
					release_bindings_pause_claim = function() return true end,
				}
			end,
		}, function(script_control, ctx)

			helpers.assert_eq(script_control.pause_all(), true)
			ctx.fire_deferred()
			ctx.pause_callback(true, "paused")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(calls.pause, 1)
			helpers.assert_eq(debt, false)

			helpers.assert_eq(script_control.resume_all(), true)
			ctx.fire_deferred()
			ctx.resume_callback(true, "resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(calls.resume, 0,
				"cleanup-only debt must not resurrect bindings that were OFF before pause")
			script_control.stop()
		end)
	end)

	for _, mode in ipairs({ "nil", "throw" }) do
		helpers.it("rejects an ambiguous bindings-debt snapshot after " .. mode, function()
			local pause_calls = 0
			with_context({
				shortcuts_factory = function()
					return {
						is_bindings_started = function() return false end,
						has_bindings_pause_debt = function()
							if mode == "throw" then error("synthetic debt query failure") end
							return nil
						end,
						pause_bindings = function()
							pause_calls = pause_calls + 1
							return true
						end,
						resume_bindings = function() return true end,
						release_bindings_pause_claim = function() return true end,
					}
				end,
			}, function(script_control, ctx)

				helpers.assert_eq(script_control.pause_all(), true,
					"the public request reports controller admission, not local settlement")
				ctx.fire_deferred()
				ctx.pause_callback(true, "native-paused")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_eq(pause_calls, 0,
					"an ambiguous ownership query must fail before cleanup mutation")
				helpers.assert_eq(ctx.calls.karabiner_resume, 1,
					"the already-paused native layer must be rolled back")
				ctx.resume_callback(true, "native-running")
				script_control.stop()
			end)
		end)
	end

	helpers.it("does not duplicate a reversible shortcut debt with cleanup-only work", function()
		local calls = { pause = 0, resume = 0 }
		local started = true
		local debt = false
		local rollback_refusals = 1
		with_context({
			pause_failure = { step = "mlx_stop", mode = "false" },
			shortcuts_factory = function()
				return {
					is_bindings_started = function() return started end,
					has_bindings_pause_debt = function() return debt end,
					pause_bindings = function()
						calls.pause = calls.pause + 1
						started = false
						debt = false
						return true
					end,
					resume_bindings = function()
						calls.resume = calls.resume + 1
						if rollback_refusals > 0 then
							rollback_refusals = rollback_refusals - 1
							debt = true
							return false
						end
						started = true
						debt = false
						return true
					end,
				}
			end,
		}, function(script_control, ctx)

			script_control.pause_all()
			ctx.fire_deferred()
			ctx.pause_callback(true, "first-native-paused")
			helpers.assert_eq(calls.pause, 1)
			helpers.assert_eq(calls.resume, 1)
			helpers.assert_eq(debt, true)
			helpers.assert_eq(ctx.calls.karabiner_resume, 1)
			ctx.resume_callback(true, "first-native-rollback")

			ctx.pause_failure = nil
			helpers.assert_eq(script_control.pause_all(), true)
			ctx.fire_deferred()
			ctx.pause_callback(true, "retry-native-paused")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(calls.pause, 2,
				"the retained reversible owner must be quiesced once, not once per debt label")

			script_control.resume_all()
			ctx.fire_deferred()
			ctx.resume_callback(true, "final-native-resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(calls.resume, 2)
			helpers.assert_eq(started, true,
				"the original ON intent must survive the retained reversible debt")
			script_control.stop()
		end)
	end)
end)




-- ===========================================
-- ===========================================
-- ======= 3/ Pause Failure Is Atomic ========
-- ===========================================
-- ===========================================

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





-- ============================================
-- ============================================
-- ======= 4/ Resume Failure Is Atomic ========
-- ============================================
-- ============================================

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

	helpers.it("never publishes RESUMED before exact admission release settles", function()
		for _, mode in ipairs({ "false", "throw" }) do
			local options = mode == "false"
				and { admission_release_failures = 1 }
				or { admission_release_throws = 1 }
			with_context(options, function(script_control, ctx)
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callback(true, "paused")
				local exact_fence = ctx.admission_fence

				script_control.resume_all()
				ctx.fire_deferred()
				ctx.resume_callback(true, "resumed")
				helpers.assert_eq(script_control.is_paused(), true,
					mode .. " admission release must roll local activation back to PAUSED")
				helpers.assert_true(ctx.admission_fence == exact_fence,
					"the exact refused fence remains owned for retry")
				helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0)
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
					"listeners may not observe RESUMED before admission reopens")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"native RESUMED must be rolled back when admission cannot reopen")

				ctx.pause_callbacks[2](true, "re-paused")
				helpers.assert_true(ctx.admission_fence == exact_fence)
				script_control.resume_all()
				ctx.fire_deferred()
				ctx.resume_callbacks[2](true, "retry-resumed")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_nil(ctx.admission_fence)
				helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
				script_control.stop()
			end)
		end
	end)

	helpers.it("keeps no-integration resume private until the exact fence releases", function()
		with_context({
			integration_enabled = false,
			admission_release_failures = 1,
		}, function(script_control, ctx)
			script_control.pause_all()
			local exact_fence = ctx.admission_fence
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))

			script_control.resume_all()
			helpers.assert_eq(script_control.is_paused(), true,
				"local-only resume must roll back when admission release returns false")
			helpers.assert_true(ctx.admission_fence == exact_fence)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
			helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0)

			script_control.resume_all()
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_nil(ctx.admission_fence)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
			script_control.stop()
		end)
	end)

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

	helpers.it("tracks a late pause-owner registration whose inverse also refuses", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_context({ no_integration = true }, function(script_control)
				helpers.assert_true(script_control.pause_all())
				local pause_mode = mode
				local resume_mode = mode
				local pause_calls = 0
				local resume_calls = 0
				local function result_for(current, label)
					if current == "throw" then error(label .. " exploded") end
					if current == "false" then return false end
					if current == "nil" then return nil end
					return true
				end
				local owner = {
					pause = function()
						pause_calls = pause_calls + 1
						return result_for(pause_mode, "late owner pause")
					end,
					resume = function()
						resume_calls = resume_calls + 1
						return result_for(resume_mode, "late owner resume")
					end,
				}

				helpers.assert_true(script_control.register_pause_owner("llm_activation", owner),
					"failed registration rollback must remain globally owned")
				helpers.assert_eq(pause_calls, 1)
				helpers.assert_eq(resume_calls, 1)
				helpers.assert_true(script_control.is_pause_transition_pending())
				helpers.assert_eq(script_control.pause_all(), false)
				helpers.assert_eq(pause_calls, 2)
				helpers.assert_eq(resume_calls, 1,
					"same-state debt retry may not activate the late owner")

				pause_mode = "true"
				helpers.assert_true(script_control.pause_all())
				helpers.assert_eq(pause_calls, 3)
				helpers.assert_eq(script_control.is_pause_transition_pending(), false)
				resume_mode = "true"
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(resume_calls, 2)
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_true(script_control.stop())
			end)
		end
	end)

	helpers.it("rejects a PAUSE snapshot when a callback registers a new owner", function()
		with_context({ no_integration = true }, function(script_control, ctx)
			local active = true
			local pause_calls = 0
			local resume_calls = 0
			local owner = {
				pause = function()
					pause_calls = pause_calls + 1
					active = false
					return true
				end,
				resume = function()
					resume_calls = resume_calls + 1
					active = true
					return true
				end,
			}
			ctx.hooks.keymap_pause = function()
				ctx.hooks.keymap_pause = nil
				helpers.assert_true(script_control.register_pause_owner("llm_activation", owner))
			end

			helpers.assert_true(script_control.pause_all(),
				"the public request reports accepted input-drain ownership")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(count_notifications(ctx, "script_control.pause_failed", "error"), 1,
				"the synchronously refused local commit must still be reported")
			helpers.assert_eq(pause_calls, 0,
				"registration while still ACTIVE must not pretend the new owner was paused")
			helpers.assert_eq(resume_calls, 0)
			helpers.assert_eq(active, true)
			helpers.assert_eq(ctx.calls.keymap_pause, 1)
			helpers.assert_eq(ctx.calls.keymap_resume, 1,
				"the stale PAUSE snapshot must roll its exact applied mutation back")

			helpers.assert_true(script_control.pause_all(),
				"the next PAUSE must inventory and quiesce the retained owner")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(pause_calls, 1)
			helpers.assert_eq(active, false)
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(resume_calls, 1)
			helpers.assert_eq(active, true)
			helpers.assert_true(script_control.stop())
		end)
	end)

	helpers.it("rejects a RESUME snapshot when a callback registers a paused owner", function()
		with_context({ no_integration = true }, function(script_control, ctx)
			helpers.assert_true(script_control.pause_all())
			local active = true
			local pause_calls = 0
			local resume_calls = 0
			local owner = {
				pause = function()
					pause_calls = pause_calls + 1
					active = false
					return true
				end,
				resume = function()
					resume_calls = resume_calls + 1
					active = true
					return true
				end,
			}
			ctx.hooks.keymap_resume = function()
				ctx.hooks.keymap_resume = nil
				helpers.assert_true(script_control.register_pause_owner("llm_activation", owner))
			end

			helpers.assert_eq(script_control.resume_all(), false,
				"a RESUME may not clear a ledger that grew inside an owner callback")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(pause_calls, 1,
				"registration under PAUSED must quiesce the new owner immediately")
			helpers.assert_eq(resume_calls, 0,
				"the omitted owner may not be activated by the stale snapshot")
			helpers.assert_eq(active, false)
			helpers.assert_eq(ctx.calls.keymap_resume, 1)
			helpers.assert_eq(ctx.calls.keymap_pause, 2,
				"the already applied resume step must be rolled back exactly")

			helpers.assert_true(script_control.resume_all(),
				"the next RESUME must include the newly appended owner")
			helpers.assert_eq(resume_calls, 1)
			helpers.assert_eq(active, true)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_true(script_control.stop())
		end)
	end)

	helpers.it("retains every resumed owner when admission and exact re-pause refuse", function()
		for _, release_mode in ipairs({ "false", "throw" }) do
			for _, pause_mode in ipairs({ "false", "nil", "throw" }) do
				local options = release_mode == "false"
					and { admission_release_failures = 1 }
					or { admission_release_throws = 1 }
				with_context(options, function(script_control, ctx)
					helpers.assert_true(script_control.pause_all())
					ctx.fire_deferred()
					ctx.pause_callbacks[1](true, "paused")
					local exact_fence = ctx.admission_fence

					ctx.pause_failure = { step = "shortcuts_pause", mode = pause_mode }
					helpers.assert_true(script_control.resume_all())
					ctx.fire_deferred()
					ctx.resume_callbacks[1](true, "native-resumed")
					helpers.assert_eq(script_control.is_paused(), true)
					helpers.assert_true(script_control.is_pause_transition_pending(),
						"native rollback and local re-pause debt must remain observable")
					helpers.assert_true(ctx.admission_fence == exact_fence)
					helpers.assert_eq(ctx.calls.shortcuts_pause, 2,
						"fallback must target the same owner that committed the original PAUSE")
					helpers.assert_eq(ctx.calls.shortcuts_resume, 1,
						"re-pause debt may not reacquire an activation successor")
					helpers.assert_eq(ctx.calls.karabiner_pause, 2)

					ctx.pause_callbacks[2](true, "native-repaused")
					helpers.assert_true(script_control.is_pause_transition_pending(),
						"terminal native re-pause may not consume unresolved local ownership")
					helpers.assert_eq(script_control.pause_all(), false,
						"same-state PAUSE must retry the retained owner without a successor")
					helpers.assert_eq(ctx.calls.shortcuts_pause, 3)
					helpers.assert_eq(ctx.calls.shortcuts_resume, 1)
					helpers.assert_eq(ctx.calls.karabiner_pause, 2,
						"local debt recovery must not publish a redundant native request")

					ctx.pause_failure = nil
					helpers.assert_true(script_control.pause_all())
					helpers.assert_eq(ctx.calls.shortcuts_pause, 4)
					helpers.assert_eq(script_control.is_pause_transition_pending(), false)
					helpers.assert_true(script_control.resume_all())
					ctx.fire_deferred()
					ctx.resume_callbacks[2](true, "retry-resumed")
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_nil(ctx.admission_fence)
					helpers.assert_true(ctx.admission_release_tokens[1] == exact_fence)
					helpers.assert_true(ctx.admission_release_tokens[2] == exact_fence)
					helpers.assert_true(script_control.stop())
				end)
			end
		end
	end)

	helpers.it("does not replay one-way PAUSE cleanup after admission release refusal", function()
		for _, owner in ipairs({
			{ step = "keymap_reset", label = "prediction reset" },
			{ step = "tooltip_hide", label = "tooltip dismissal" },
		}) do
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				with_context({ admission_release_failures = 1 }, function(script_control, ctx)
					helpers.assert_true(script_control.pause_all())
					ctx.fire_deferred()
					ctx.pause_callbacks[1](true, "paused")
					helpers.assert_eq(ctx.calls[owner.step], 1,
						"positive control must commit the original " .. owner.label)

					ctx.pause_failure = { step = owner.step, mode = mode }
					helpers.assert_true(script_control.resume_all())
					ctx.fire_deferred()
					ctx.resume_callbacks[1](true, "native-resumed")
					helpers.assert_eq(ctx.calls[owner.step], 1,
						owner.label .. " was never resumed and must not be acquired again")
					helpers.assert_eq(script_control.is_paused(), true)
					helpers.assert_true(script_control.is_pause_transition_pending(),
						"native re-pause must remain owned until its callback settles")

					ctx.pause_callbacks[2](true, "native-repaused")
					helpers.assert_eq(script_control.is_pause_transition_pending(), false)
					helpers.assert_eq(ctx.calls[owner.step], 1,
						"terminal native compensation may not replay one-way work")
					ctx.pause_failure = nil
					helpers.assert_true(script_control.resume_all())
					ctx.fire_deferred()
					ctx.resume_callbacks[2](true, "retry-resumed")
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(ctx.calls[owner.step], 1)
					helpers.assert_true(script_control.stop())
				end)
			end
		end
	end)

	helpers.it("keeps optional keylogger resync failures outside the activation transaction", function()
		for _, mode in ipairs({ "false", "throw" }) do
			with_context({
				resume_failure = { step = "keylogger_resync", mode = mode },
			}, function(script_control, ctx)
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")

				script_control.resume_all()
				ctx.fire_deferred()
				ctx.resume_callback(true, "resumed")

				helpers.assert_eq(ctx.calls.keylogger_resync, 1,
					"resume must still attempt the optional context refresh")
				helpers.assert_eq(script_control.is_paused(), false,
					"metrics OFF/uninitialized keylogger must not block an otherwise complete resume")
				helpers.assert_eq(ctx.calls.karabiner_pause, 1,
					"a non-activating optional failure must not roll native remapping back")
				helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
				helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 0)
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
				helpers.assert_true(has_warning_containing(ctx, "keylogger.resync_context"),
					"the optional failure must remain visible in the file logger")
				script_control.stop()
			end)
		end
	end)

	helpers.it("serializes a rapid pause then resume without overlapping native input", function()
		with_context(nil, function(script_control, ctx)
			script_control.pause_all()
			script_control.resume_all()
			ctx.fire_deferred()

			helpers.assert_eq(ctx.calls.karabiner_pause, 1)
			helpers.assert_eq(ctx.calls.karabiner_resume, nil,
				"the reversal must wait for PAUSED instead of overlapping controller input")
			ctx.pause_callback(true, "paused")
			helpers.assert_eq(script_control.is_paused(), true)

			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_resume, 1)
			ctx.resume_callback(true, "resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(ctx.calls.keymap_pause, 1)
			helpers.assert_eq(ctx.calls.keymap_resume, 1)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
			script_control.stop()
		end)
	end)
end)
