--- tests/unit/modules/llm/mlx/test_api_mlx_pause_ownership_warmup.lua

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
local init_idle_real_warmup_controller = Fixture.init_idle_real_warmup_controller
local install_script_control_dependencies = Fixture.install_script_control_dependencies
local native_result = Fixture.native_result
local requests_matching = Fixture.requests_matching
local with_real_mlx_stack = Fixture.with_real_mlx_stack





helpers.describe("HS-012 real MLX warmup HTTP ownership", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the warmup POST and intention after " .. mode .. " cancellation", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				env.state.http_cancel_mode = mode

				helpers.assert_true(env.api.warmup("fixture-model", nil),
					"positive control must dispatch a real HttpClient warmup")
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 1)
				local late = warmup_requests[1]

				helpers.assert_eq(env.api.pause_warmup(), false,
					"pause may not publish over non-exact POST cancellation")
				helpers.assert_eq(late.cancel_calls, 1,
					"pause must attempt the exact warmup task once")
				helpers.assert_eq(env.api.resume_warmup(), false,
					"resume must retain the same POST while its native task is still live")
				helpers.assert_eq(late.cancel_calls, 2,
					"cleanup retry must target the same warmup task, never a sibling")

				late.deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_eq(env.api.is_ready(), false,
					"the real HttpClient generation must fence a late warmup response")
				helpers.assert_true(env.api.resume_warmup(),
					"the exact task terminal must settle the debt despite the old cancel refusal")
				helpers.assert_eq(late.cancel_calls, 2,
					"a terminal task must be retired without a meaningless third cancellation")
				warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"one terminally settled predecessor must restore the exact intention once")
				helpers.assert_true(warmup_requests[2].task ~= late.task,
					"the restored warmup must own a distinct successor task")
				late.deliver(200, [[{"choices":[{"text":"duplicate"}]}]])
				helpers.assert_eq(env.api.is_ready(), false,
					"a duplicate predecessor callback may not consume or publish the successor")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 2,
					"a duplicate predecessor callback may not dispatch a sibling")

				env.state.http_cancel_mode = "success"
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.resume_warmup())
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 2,
					"duplicate resume must not replay a consumed intention")
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	helpers.it("joins discovery through the public warmup pause owner", function()
		with_real_mlx_stack(function(env)
			helpers.assert_true(env.api.warmup("fixture-model", nil))
			helpers.assert_eq(#env.state.timers, 1,
				"warmup must enter the real discovery timer path")
			env.state.timers[1].fire()
			helpers.assert_eq(#env.state.tasks, 1,
				"the discovery continuation must dispatch one real ShellRunner task")
			local stale_task = env.state.tasks[1]
			env.state.task_terminate_mode = "false"

			helpers.assert_eq(env.api.pause_warmup(), false,
				"api_mlx must propagate discovery task refusal to the pause registry")
			helpers.assert_eq(env.api.resume_warmup(), false)
			env.state.task_terminate_mode = "success"
			helpers.assert_eq(env.api.resume_warmup(), false,
				"accepted SIGTERM is not exact settlement before task completion")
			stale_task.complete(0, [[{"data":[]}]], "")
			helpers.assert_eq(#env.state.http_requests, 0,
				"the late discovery completion must stay fenced by api_mlx pause")

			helpers.assert_true(env.api.resume_warmup())
			helpers.assert_eq(#env.state.timers, 2,
				"the active pre-pause discovery intention must restart exactly once")
			helpers.assert_eq(#env.state.tasks, 1,
				"the successor remains deferred until its new timer fires")
			helpers.assert_true(env.api.stop_warmup())
		end)
	end)

	helpers.it("never resurrects an inactive or explicitly stopped warmup", function()
		with_real_mlx_stack(function(env)
			local original_is_discovered = env.discovery.is_discovered
			env.discovery.is_discovered = function() return true end

			helpers.assert_true(env.api.pause_warmup())
			helpers.assert_true(env.api.resume_warmup())
			helpers.assert_eq(#env.state.http_requests, 0,
				"an inactive pre-pause owner must not invent a warmup request")

			helpers.assert_true(env.api.stop_warmup())
			helpers.assert_true(env.api.pause_warmup())
			helpers.assert_true(env.api.resume_warmup())
			helpers.assert_eq(env.api.warmup("disabled-model", nil), false,
				"pause/resume must preserve an explicit pre-pause stop")
			helpers.assert_eq(#env.state.http_requests, 0,
				"a stopped LLM backend must remain free of warmup POSTs")
			env.discovery.is_discovered = original_is_discovered
		end)
	end)

	helpers.it("stages active restart behind the real ScriptControl RESUMED commit", function()
		with_real_mlx_stack(function(env)
			local original_is_discovered = env.discovery.is_discovered
			env.discovery.is_discovered = function() return true end
			helpers.assert_true(env.api.warmup("fixture-model", nil))
			helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
				"positive control must own a real warmup POST before pause")

			install_script_control_dependencies()
			package.loaded["modules.shortcuts.script_control"] = nil
			local script_control = require("modules.shortcuts.script_control")
			helpers.assert_true(script_control.pause_all())
			helpers.assert_true(script_control.is_paused())
			helpers.assert_true(script_control.resume_all())
			helpers.assert_eq(script_control.is_paused(), false,
				"real ScriptControl must publish RESUMED before MLX activation")
			helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
				"resume owner may not dispatch native MLX work inside resume_all")

			local staged = env.state.timers[#env.state.timers]
			helpers.assert_eq(staged.delay, 0,
				"active MLX intent must own one exact next-tick stage")
			local timer_count = #env.state.timers
			helpers.assert_true(env.api.resume_warmup())
			helpers.assert_eq(#env.state.timers, timer_count,
				"duplicate resume must not arm a sibling stage")
			staged.fire()
			helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 2,
				"epoch-matched post-commit stage must restart exactly once")
			helpers.assert_true(env.api.stop_warmup())
			env.discovery.is_discovered = original_is_discovered
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("joins the staged timer when a later ScriptControl owner returns " .. mode, function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))
				local failures_left = 1
				install_script_control_dependencies({
					warmup_controller_resume = function()
						if failures_left == 0 then return true end
						failures_left = failures_left - 1
						return native_result(mode, "later resume owner exploded", true)
					end,
				})
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				env.state.timer_stop_mode = mode
				helpers.assert_eq(script_control.resume_all(), false,
					"later owner refusal must roll the staged MLX resume back")
				helpers.assert_true(script_control.is_paused())
				local stale_stage = env.state.timers[#env.state.timers]
				stale_stage.fire(true)
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"late staged callback must stay inert after logical rollback")

				env.state.timer_stop_mode = "success"
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= stale_stage,
					"retry must replace the exact settled stage, not reuse its callback")
				retry_stage.fire()
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 2,
					"retry may restore the active intention exactly once")
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("reoffers the committed warmup after " .. mode .. " timeout acquisition", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)

				install_script_control_dependencies()
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false,
					"positive control must commit the real global resume")
				local committed_stage = env.state.timers[#env.state.timers]

				env.state.next_timer_start_mode = mode
				committed_stage.fire()
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"refused warmup timeout acquisition must not dispatch a POST")
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= committed_stage,
					"post-commit refusal must retain intent through one successor stage")
				helpers.assert_eq(retry_stage.delay, 2,
					"retry must use the bounded warmup backoff, never synchronous recursion")

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"settled retry must dispatch the retained warmup exactly once")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				local timer_count = #env.state.timers
				helpers.assert_true(env.api.resume_warmup())
				helpers.assert_eq(#env.state.timers, timer_count,
					"consumed retry intent must not arm a duplicate stage")
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("recovers mutated timeout debt without a controller timer after " .. mode .. " rollback", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))

				package.loaded["modules.llm.warmup_controller"] = nil
				local real_controller = require("modules.llm.warmup_controller")
				helpers.assert_true(real_controller.init({
					core_llm = {
						is_backend_ready = env.api.is_ready,
						is_backend_load_failed = env.api.is_load_failed,
						get_current_model = function() return "fixture-model" end,
						get_backend = function() return "mlx" end,
						get_active_profile = function() return nil end,
						warmup_model = env.api.warmup,
					},
					get_llm_enabled = function() return true end,
				}))
				install_script_control_dependencies({
					warmup_controller = real_controller,
				})
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				local timer_count = #env.state.timers
				helpers.assert_true(script_control.resume_all())
				helpers.assert_eq(script_control.is_paused(), false)
				local committed_stage = env.state.timers[timer_count + 1]
				helpers.assert_eq(committed_stage.delay, 0)
				helpers.assert_eq(#env.state.timers, timer_count + 1,
					"real WarmupController pending=false must not invent a retry timer")

				env.state.next_timer_start_mode = "mutate_" .. mode
				env.state.next_timer_stop_mode = mode
				committed_stage.fire()
				local timeout_debt = env.state.timers[#env.state.timers]
				helpers.assert_true(timeout_debt ~= committed_stage,
					"mutating start refusal must retain the exact hard-timeout candidate")
				helpers.assert_true(timeout_debt.native:running(),
					"positive control must prove native activation preceded the refusal")
				helpers.assert_true(timeout_debt.stop_calls >= 2,
					"acquisition rollback and MLX quiesce must both retry the same owner")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"no POST successor may overlap retained timeout debt")
				helpers.assert_eq(#env.state.timers, timer_count + 2,
					"cleanup debt must suppress every native retry instead of adding a sibling")

				timeout_debt.stop_mode = "success"
				timeout_debt.fire(true)
				helpers.assert_eq(timeout_debt.native:running(), false,
					"late native delivery must first prove exact predecessor settlement")
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= timeout_debt,
					"settlement observer must own the retry without an external controller")
				helpers.assert_eq(retry_stage.delay, 2)
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"settlement notification alone may not dispatch native HTTP work")

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"one MLX-owned retry must re-offer the retained intent exactly once")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("recovers an internal HttpClient timeout debt after " .. mode .. " rollback", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))

				local real_controller = init_idle_real_warmup_controller(env)
				install_script_control_dependencies({ warmup_controller = real_controller })
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				local timer_count = #env.state.timers
				helpers.assert_true(script_control.resume_all())
				local committed_stage = env.state.timers[timer_count + 1]
				helpers.assert_eq(#env.state.timers, timer_count + 1,
					"idle real controller must leave MLX as the only restart owner")

				-- The API hard timeout commits; only HttpClient's own timeout
				-- activates and then refuses, including its exact rollback.
				env.state.timer_start_modes = { "success", "mutate_" .. mode }
				env.state.timer_stop_modes = { "success", mode }
				committed_stage.fire()
				local api_timeout = env.state.timers[#env.state.timers - 1]
				local http_timeout_debt = env.state.timers[#env.state.timers]
				helpers.assert_eq(api_timeout.native:running(), false,
					"API timeout must settle so only the private HttpClient debt remains")
				helpers.assert_true(http_timeout_debt.native:running(),
					"positive control must retain HttpClient's activated native timeout")
				helpers.assert_true(http_timeout_debt.stop_calls >= 2,
					"HttpClient and MLX quiesce must retry the same private capability")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
					"private timeout debt must block HTTP dispatch and every sibling retry")
				helpers.assert_eq(#env.state.timers, timer_count + 3)

				http_timeout_debt.stop_mode = "success"
				http_timeout_debt.fire(true)
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= http_timeout_debt,
					"HttpClient settlement must trigger the retained MLX snapshot itself")
				helpers.assert_eq(retry_stage.delay, 2)
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"private HttpClient settlement may produce exactly one warmup successor")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("recovers an internal Discovery timer debt after " .. mode .. " rollback", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))

				local real_controller = init_idle_real_warmup_controller(env)
				install_script_control_dependencies({ warmup_controller = real_controller })
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				local timer_count = #env.state.timers
				helpers.assert_true(script_control.resume_all())
				local committed_stage = env.state.timers[timer_count + 1]

				-- Re-enter the real discovery path. Its initial poll timer is the
				-- only owner allowed to remain after activation cleanup refuses.
				env.discovery.is_discovered = original_is_discovered
				env.state.timer_start_modes = { "mutate_" .. mode }
				env.state.timer_stop_modes = { mode }
				committed_stage.fire()
				local discovery_debt = env.state.timers[#env.state.timers]
				helpers.assert_true(discovery_debt.native:running(),
					"positive control must retain Discovery's native poll timer")
				helpers.assert_true(discovery_debt.stop_calls >= 3,
					"dispatch, quiesce, and composite observer must retry one exact poll")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)
				helpers.assert_eq(#env.state.tasks, 0,
					"no curl successor may overlap the retained discovery timer")
				helpers.assert_eq(#env.state.timers, timer_count + 2)

				env.discovery.is_discovered = function() return true end
				discovery_debt.stop_mode = "success"
				discovery_debt.fire(true)
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_true(retry_stage ~= discovery_debt,
					"Discovery composite settlement must re-offer the MLX snapshot")
				helpers.assert_eq(retry_stage.delay, 2)
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"settled discovery may produce exactly one warmup successor")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retries one clean post-commit stage acquisition after " .. mode, function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("fixture-model", nil))

				local real_controller = init_idle_real_warmup_controller(env)
				install_script_control_dependencies({ warmup_controller = real_controller })
				package.loaded["modules.shortcuts.script_control"] = nil
				local script_control = require("modules.shortcuts.script_control")
				helpers.assert_true(script_control.pause_all())
				local timer_count = #env.state.timers
				helpers.assert_true(script_control.resume_all())
				local committed_stage = env.state.timers[timer_count + 1]

				-- Warmup acquisition fails cleanly, then the first delayed stage
				-- acquisition fails cleanly too. One bounded acquisition retry owns
				-- the only future continuation; no external controller timer exists.
				env.state.timer_start_modes = { mode, mode, "success" }
				committed_stage.fire()
				local refused_stage = env.state.timers[#env.state.timers - 1]
				local retry_stage = env.state.timers[#env.state.timers]
				helpers.assert_eq(refused_stage.delay, 2,
					"positive control must hit the delayed-stage acquisition refusal")
				helpers.assert_eq(refused_stage.native:running(), false,
					"the refused stage must be clean, not settlement debt")
				helpers.assert_eq(retry_stage.delay, 2)
				helpers.assert_true(retry_stage.native:running(),
					"one bounded MLX-owned acquisition retry must remain live")
				helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1)

				retry_stage.fire()
				local warmup_requests = requests_matching(env.state, "/v1/completions")
				helpers.assert_eq(#warmup_requests, 2,
					"clean acquisition retry may restore the snapshot exactly once")
				warmup_requests[2].deliver(200, [[{"choices":[{"text":"ok"}]}]])
				helpers.assert_true(env.api.is_ready())
				helpers.assert_true(env.api.stop_warmup())
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end
end)

helpers.describe("HS-012 MLX endpoint reset joins predecessor owners", function()
	helpers.it("discards an old staged snapshot before a model switch", function()
		with_real_mlx_stack(function(env)
			local original_is_discovered = env.discovery.is_discovered
			env.discovery.is_discovered = function() return true end
			helpers.assert_true(env.api.warmup("old-model", nil))
			env.state.script_paused = true
			env.state.pause_epoch = 1
			helpers.assert_true(env.api.pause_warmup())
			helpers.assert_true(env.api.resume_warmup())
			local old_stage = env.state.timers[#env.state.timers]
			env.state.script_paused = false

			helpers.assert_true(env.api.reset_endpoints())
			old_stage.fire(true)
			helpers.assert_eq(#requests_matching(env.state, "/v1/completions"), 1,
				"reset must fence the pre-switch staged callback")
			helpers.assert_true(env.api.warmup("new-model", nil),
				"committed global resume must admit the successor identity")

			env.state.script_paused = true
			env.state.pause_epoch = 2
			helpers.assert_true(env.api.pause_warmup())
			helpers.assert_true(env.api.resume_warmup())
			local new_stage = env.state.timers[#env.state.timers]
			env.state.script_paused = false
			new_stage.fire()
			local requests = requests_matching(env.state, "/v1/completions")
			helpers.assert_eq(#requests, 3)
			helpers.assert_true(requests[3].body:find("new-model", 1, true) ~= nil,
				"the next pause may replay only the successor model snapshot")
			helpers.assert_true(requests[3].body:find("old-model", 1, true) == nil)
			helpers.assert_true(env.api.stop_warmup())
			env.discovery.is_discovered = original_is_discovered
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps the old port authoritative after " .. mode .. " reset refusal", function()
			with_real_mlx_stack(function(env)
				local old_port = env.api.get_port()
				local old_url = env.api.get_base_url()
				local original_reset = env.api.reset_endpoints
				env.api.reset_endpoints = function()
					return native_result(mode, "synthetic endpoint reset failure", true)
				end
				helpers.assert_eq(env.api.set_port(old_port + 1), false)
				helpers.assert_eq(env.api.get_port(), old_port,
					"set_port must not publish a successor address over reset debt")
				helpers.assert_eq(env.api.get_base_url(), old_url)
				env.api.reset_endpoints = original_reset
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact PGID guard after " .. mode .. " timer cancellation", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.api.reset_endpoints())
				local predecessor = env.state.timers[#env.state.timers]
				local timer_count = #env.state.timers
				env.state.timer_stop_mode = mode
				helpers.assert_eq(env.api.reset_endpoints(), false)
				helpers.assert_eq(#env.state.timers, timer_count,
					"a refused PGID cancel must block its replacement")
				predecessor.fire(true)
				env.state.timer_stop_mode = "success"
				helpers.assert_true(env.api.reset_endpoints())
				helpers.assert_eq(#env.state.timers, timer_count + 1,
					"one successor PGID guard may arm after exact retry")
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("propagates discovery reset " .. mode .. " and blocks the PGID successor", function()
			with_real_mlx_stack(function(env)
				helpers.assert_true(env.discovery.discover(function() end))
				local predecessor = env.state.timers[1]
				env.state.timer_stop_mode = mode
				helpers.assert_eq(env.api.reset_endpoints(), false)
				helpers.assert_eq(#env.state.timers, 1,
					"discovery debt must block the new PGID timeout")
				predecessor.fire(true)
				env.state.timer_stop_mode = "success"
				helpers.assert_true(env.api.reset_endpoints())
				helpers.assert_eq(#env.state.timers, 2)
				helpers.assert_eq(#env.state.tasks, 0,
					"late predecessor poll must remain inert after reset generation change")
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("refuses PGID successor publication after " .. mode .. " warmup cancellation", function()
			with_real_mlx_stack(function(env)
				local original_is_discovered = env.discovery.is_discovered
				env.discovery.is_discovered = function() return true end
				helpers.assert_true(env.api.warmup("old-model", nil))
				local old_request = requests_matching(env.state, "/v1/completions")[1]
				local timer_count = #env.state.timers
				env.state.http_cancel_mode = mode

				helpers.assert_eq(env.api.reset_endpoints(), false)
				helpers.assert_eq(#env.state.timers, timer_count,
					"reset refusal must not arm the new PGID timeout over old HTTP debt")
				old_request.deliver(200, [[{"choices":[{"text":"late"}]}]])
				helpers.assert_eq(env.api.is_ready(), false,
					"late predecessor POST must remain generation-fenced")

				env.state.http_cancel_mode = "success"
				helpers.assert_true(env.api.reset_endpoints())
				helpers.assert_eq(#env.state.timers, timer_count + 1,
					"one PGID guard may arm only after every predecessor joined")
				env.discovery.is_discovered = original_is_discovered
			end)
		end)
	end
end)
