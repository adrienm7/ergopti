--- tests/unit/modules/llm/mlx/test_api_mlx_pause_ownership_discovery.lua

--- ==============================================================================
--- MODULE: MLX Warmup Pause Ownership Regression Tests
--- DESCRIPTION:
--- Exercises the real MLX controller, discovery state machine, HttpClient,
--- TimerScheduler, and ShellRunner against native-shaped asynchronous doubles.
--- Pause must fence every late completion before reporting exact settlement,
--- retain each refused capability for retry, and restart only a warmup that was
--- active before the pause transaction began.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.mlx.api_mlx_pause_ownership_fixture"] = nil
local Fixture = require("tests.support.modules.llm.mlx.api_mlx_pause_ownership_fixture")
local requests_matching = Fixture.requests_matching
local with_real_mlx_stack = Fixture.with_real_mlx_stack





helpers.describe("HS-012 real MLX discovery timer ownership", function()
	helpers.it("does not re-enter callbacks synchronously when paused or quiesced", function()
		with_real_mlx_stack(function(env)
			local callbacks = 0
			env.state.script_paused = true
			helpers.assert_eq(env.discovery.discover(function() callbacks = callbacks + 1 end), false)
			helpers.assert_eq(callbacks, 0,
				"paused refusal must not re-enter the rejected warmup callback")
			env.state.script_paused = false
			helpers.assert_true(env.discovery.stop())
			helpers.assert_eq(env.discovery.discover(function() callbacks = callbacks + 1 end), false)
			helpers.assert_eq(callbacks, 0,
				"quiesced refusal must not re-enter the rejected warmup callback")
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and retries a poll timer after " .. mode .. " cancellation", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.discovery.discover(function() end))
				helpers.assert_eq(#env.state.timers, 1,
					"positive control must arm the real discovery timer")
				local stale_timer = env.state.timers[1]
				env.state.timer_stop_mode = mode

				helpers.assert_eq(env.discovery.stop(), false)
				stale_timer.fire(true)
				helpers.assert_eq(#env.state.tasks, 0,
					"a logically revoked timer may never dispatch its curl successor")
				helpers.assert_eq(env.discovery.resume(), false,
					"the exact timer debt must survive until native stop settles")

				env.state.timer_stop_mode = "success"
				helpers.assert_true(env.discovery.resume())
				stale_timer.fire(true)
				helpers.assert_eq(#env.state.tasks, 0,
					"a late native delivery stays inert after cleanup retry")
				helpers.assert_true(env.discovery.discover(function() end))
				helpers.assert_eq(#env.state.timers, 2,
					"one successor may arm only after the predecessor settled")
				helpers.assert_true(env.discovery.stop())
			end)
		end)
	end
end)

helpers.describe("HS-192 MLX discovery callback withdrawal", function()
	helpers.it("fans out every waiter queued behind one real probe", function()
		with_real_mlx_stack(function(env)
			local first_calls = 0
			local second_calls = 0
			helpers.assert_true(env.discovery.discover(function() first_calls = first_calls + 1 end))
			helpers.assert_true(env.discovery.discover(function() second_calls = second_calls + 1 end))

			env.state.timers[1].fire()
			env.state.tasks[1].complete(0, [[{"data":[]}]], "")
			local completion_probe = requests_matching(env.state, "/v1/completions")[1]
			helpers.assert_not_nil(completion_probe)
			completion_probe.deliver(200, [[{"choices":[]}]])

			helpers.assert_eq(first_calls, 1)
			helpers.assert_eq(second_calls, 1)
		end)
	end)

	helpers.it("withdraws identity-matched waiters after concurrent index shifts", function()
		with_real_mlx_stack(function(env)
			helpers.assert_true(env.discovery.discover())
			local stale_timer = env.state.timers[1]
			stale_timer.stop_mode = "false"
			helpers.assert_eq(env.discovery.reset(), false,
				"positive control must retain one stale poll timer")

			local original_stop = stale_timer.native.stop
			stale_timer.native.stop = function()
				coroutine.yield("cancel_pending")
				return false
			end
			local a_calls = 0
			local b_calls = 0
			local waiter_a = coroutine.create(function()
				return env.discovery.discover(function() a_calls = a_calls + 1 end)
			end)
			local waiter_b = coroutine.create(function()
				return env.discovery.discover(function() b_calls = b_calls + 1 end)
			end)

			local ok_a, state_a = coroutine.resume(waiter_a)
			local ok_b, state_b = coroutine.resume(waiter_b)
			helpers.assert_eq(ok_a, true)
			helpers.assert_eq(ok_b, true)
			helpers.assert_eq(state_a, "cancel_pending")
			helpers.assert_eq(state_b, "cancel_pending")
			local done_a, accepted_a = coroutine.resume(waiter_a)
			local done_b, accepted_b = coroutine.resume(waiter_b)
			helpers.assert_eq(done_a, true)
			helpers.assert_eq(done_b, true)
			helpers.assert_eq(accepted_a, false)
			helpers.assert_eq(accepted_b, false)

			stale_timer.stop_mode = "success"
			stale_timer.native.stop = original_stop
			helpers.assert_true(env.discovery.discover(),
				"one fresh cycle must start after the retained timer settles")
			env.state.timers[#env.state.timers].fire()
			env.state.tasks[#env.state.tasks].complete(0, [[{"data":[]}]], "")
			local completion_probe = requests_matching(env.state, "/v1/completions")[1]
			helpers.assert_not_nil(completion_probe,
				"positive control must reach the real completion-route probe")
			completion_probe.deliver(200, [[{"choices":[]}]])

			helpers.assert_eq(a_calls, 0)
			helpers.assert_eq(b_calls, 0,
				"a refused waiter shifted to another index must not fire from a future cycle")
		end)
	end)
end)

helpers.describe("HS-012 real MLX discovery task and POST ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins the poll task across " .. mode .. " termination and late completion", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.discovery.discover(function() end))
				env.state.timers[1].fire()
				helpers.assert_eq(#env.state.tasks, 1,
					"positive control must dispatch the real ShellRunner poll task")
				local stale_task = env.state.tasks[1]
				env.state.task_terminate_mode = mode

				helpers.assert_eq(env.discovery.stop(), false)
				helpers.assert_eq(env.discovery.resume(), false)
				env.state.task_terminate_mode = "success"
				helpers.assert_eq(env.discovery.resume(), false,
					"SIGTERM acceptance remains pending until the exact completion callback")
				stale_task.complete(0, [[{"data":[]}]], "")
				helpers.assert_true(env.discovery.resume())
				helpers.assert_eq(#env.state.http_requests, 0,
					"a task completion from the revoked generation must not start POST probes")
			end)
		end)

		helpers.it("retains the discovery POST after " .. mode .. " cancellation", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.discovery.discover(function() end))
				env.state.timers[1].fire()
				env.state.tasks[1].complete(0, [[{"data":[]}]], "")
				local probes = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#probes, 1,
					"positive control must dispatch the real discovery HttpClient POST")
				local stale_probe = probes[1]
				env.state.http_cancel_mode = mode

				helpers.assert_eq(env.discovery.stop(), false)
				helpers.assert_eq(stale_probe.cancel_calls, 1,
					"stop must attempt the exact discovery POST once")
				helpers.assert_eq(env.discovery.resume(), false,
					"resume must retain the same discovery POST while its task is still live")
				helpers.assert_eq(stale_probe.cancel_calls, 2,
					"cleanup retry must target the same discovery task, never a sibling")

				stale_probe.deliver(200, [[{"choices":[]}]])
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"a late POST callback must not dispatch another candidate route")
				helpers.assert_eq(env.discovery.is_discovered(), false,
					"a revoked probe callback must not publish route readiness")
				helpers.assert_true(env.discovery.resume(),
					"the exact task terminal must settle discovery despite the old cancel refusal")
				helpers.assert_eq(stale_probe.cancel_calls, 2,
					"a terminal discovery task must not be cancelled again")
				stale_probe.deliver(200, [[{"choices":[]}]])
				helpers.assert_true(env.discovery.resume(),
					"duplicate terminal delivery and resume must remain idempotent")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"settling cleanup debt alone must never create a successor POST")
				env.state.http_cancel_mode = "success"
			end)
		end)
	end
end)
