--- tests/unit/ui/menu/menu_llm/ollama/test_ollama_readiness_async_asynchronous.lua

-- =============================================================================
-- MODULE: Asynchronous Ollama Readiness Regression
-- DESCRIPTION:
-- Proves that readiness and delegated native daemon work is owned asynchronously,
-- generation-fenced, and terminal exactly once without blocking the Lua runloop.
-- Also proves that a requirement request receives every terminal from the real
-- pull continuation that it dispatches.
-- =============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.ollama.ollama_readiness_async_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.ollama.ollama_readiness_async_fixture")
local MODULES = Fixture.MODULES
local accept_model_download = Fixture.accept_model_download
local foreground_fixture = Fixture.foreground_fixture
local publish_daemon_ready = Fixture.publish_daemon_ready
local retire_daemon = Fixture.retire_daemon
local start_missing_model_pull = Fixture.start_missing_model_pull
local with_fixture = Fixture.with_fixture





helpers.describe("HS-025 Ollama readiness is asynchronous and generation-owned", function()
	helpers.it("HS-025 returns before the first readiness curl completes", function()
		with_fixture({}, function(fixture)
			local successes, cancellations = 0, {}
			local accepted = fixture.manager.check_requirements("demo", function()
				successes = successes + 1
			end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})

			helpers.assert_eq(accepted, true)
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
			helpers.assert_eq(#fixture.spawns, 1)
			helpers.assert_eq(fixture.spawns[1].executable, "/usr/bin/curl")
			helpers.assert_eq(fixture.spawns[1].args,
				{"-s", "--max-time", "5", "http://127.0.0.1:11434/api/version"})
			helpers.assert_eq(successes, 0)
			helpers.assert_eq(cancellations, {})
			helpers.assert_eq(#fixture.native_tasks, 0)

			fixture.spawns[1].complete(0, '{"version":"0.9"}', "")
			helpers.assert_eq(#fixture.native_tasks, 1,
				"readiness success may construct the model-list task only after completion")
			helpers.assert_contains(fixture.native_tasks[1].label, "requirement check")
			fixture.spawns[1].complete(0, '{"version":"duplicate"}', "")
			helpers.assert_eq(#fixture.native_tasks, 1,
				"duplicate native completion cannot advance the owner twice")
	end)
	end)

	helpers.it("HS-025 retries off-runloop and drops a stale success exactly once", function()
		with_fixture({}, function(fixture)
			local current = true
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return current end})

			fixture.spawns[1].complete(28, "", "timeout")
			helpers.assert_eq(#fixture.spawns, 1)
			helpers.assert_eq(#fixture.daemon.tasks, 1)
			helpers.assert_eq(fixture.daemon.tasks[1].executable, "/bin/sh")
			helpers.assert_eq(fixture.daemon.tasks[1].arguments[1], "-c",
				"the native foreground owner must not run user login-profile startup")
			helpers.assert_eq(#fixture.timers, 0)
			publish_daemon_ready(fixture.daemon)
			helpers.assert_eq(#fixture.timers, 1)
			helpers.assert_eq(fixture.timers[1].delay, 0.5)
			helpers.assert_eq(#fixture.spawns, 1,
				"retry work cannot run inline from the daemon completion")

			fixture.timers[1].fire()
			helpers.assert_eq(#fixture.spawns, 2)
			current = false
			fixture.spawns[2].complete(0, '{"version":"late"}', "")
			helpers.assert_eq(cancellations, {"stale"})
			helpers.assert_eq(#fixture.native_tasks, 0)
			fixture.spawns[2].complete(0, '{"version":"duplicate"}', "")
			helpers.assert_eq(cancellations, {"stale"})
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
	end)
	end)

	helpers.it("HS-025 reports readiness task start refusal synchronously", function()
		with_fixture({start_results = {false}}, function(fixture)
			local cancellations = {}
			local accepted = fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(cancellations, {"readiness_probe_start_refused"})
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
	end)
	end)

	helpers.it("HS-025 does not publish a synchronous completion before start commits", function()
		with_fixture({
			start_results = {"nil"},
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
		}, function(fixture)
			local cancellations = {}
			local accepted = fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(cancellations, {"readiness_probe_start_refused"})
			helpers.assert_eq(#fixture.native_tasks, 0,
				"an inline readiness result cannot construct model work before start commits")
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
	end)
		with_fixture({
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
		}, function(fixture)
			local accepted = fixture.manager.check_requirements("demo", function() end, function() end,
				{is_current = function() return true end})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.native_tasks, 1,
				"a buffered inline completion must advance exactly once after start commits")
		end)
	end)

	helpers.it("HS-025 reports retry timer refusal without inline fallback", function()
		with_fixture({timer_commits = {false}}, function(fixture)
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			publish_daemon_ready(fixture.daemon)
			helpers.assert_eq(cancellations, {"retry_timer_refused"})
			helpers.assert_eq(#fixture.spawns, 1,
				"a refused timer cannot burst the next readiness probe inline")
			helpers.assert_eq(fixture.synchronous_exec_calls(), 0)
		end)
	end)

	helpers.it("HS-025 joins a replacement waiter without launching a second daemon", function()
		with_fixture({}, function(fixture)
			local generation = 1
			local a_cancellations = {}
			local b_successes, b_cancellations = 0, {}
			local accepted_a = fixture.manager.check_requirements("A", function() end, function(reason)
				a_cancellations[#a_cancellations + 1] = reason
			end, {is_current = function() return generation == 1 end})
			helpers.assert_eq(accepted_a, true)

			fixture.spawns[1].complete(28, "", "timeout")
			helpers.assert_eq(#fixture.spawns, 1)
			helpers.assert_eq(#fixture.daemon.tasks, 1)
			helpers.assert_eq(fixture.daemon.tasks[1].executable, "/bin/sh")
			generation = 2
			local accepted_b = fixture.manager.check_requirements("B", function()
				b_successes = b_successes + 1
			end, function(reason)
				b_cancellations[#b_cancellations + 1] = reason
			end, {is_current = function() return generation == 2 end})

			helpers.assert_eq(accepted_b, true)
			helpers.assert_eq(#fixture.spawns, 1,
				"a joined waiter must adopt the exact daemon owner instead of probing or restarting again")
			publish_daemon_ready(fixture.daemon)
			helpers.assert_eq(a_cancellations, {"stale"})
			helpers.assert_eq(b_cancellations, {})
			helpers.assert_eq(#fixture.timers, 1)
			-- Repeat the original physical observation with the same complete READY
			-- state; it cannot republish business readiness or create a new timer.
			for _, observer in ipairs(fixture.daemon.tasks[1].observers) do observer() end
			helpers.assert_eq(#fixture.timers, 1,
				"a duplicate restart completion cannot allocate a second retry owner")
			helpers.assert_eq(a_cancellations, {"stale"})

			fixture.timers[1].fire()
			helpers.assert_eq(#fixture.spawns, 2)
			fixture.spawns[2].complete(0, '{"version":"ready"}', "")
			helpers.assert_eq(#fixture.native_tasks, 1)
			fixture.native_tasks[1].on_done(0, "NAME ID\nB fixture\n", "")
			helpers.assert_eq(#fixture.http_callbacks, 1)
			fixture.http_callbacks[1].callback(200, "{}", {})
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			fixture.spawns[2].complete(0, '{"version":"duplicate"}', "")

			helpers.assert_eq(b_successes, 1,
				"the current joined waiter must publish one outer success after duplicate completions")
			helpers.assert_eq(b_cancellations, {})
			helpers.assert_eq(a_cancellations, {"stale"})
			local restart_count = #fixture.daemon.tasks
			helpers.assert_eq(restart_count, 1,
				"rapid A-to-B replacement must retain one shared daemon restart capability")
		end)
	end)

	helpers.it("HS-025 settles restart start refusal and nonzero completion exactly once", function()
		with_fixture({daemon_start_result = false}, function(fixture)
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			helpers.assert_eq(cancellations, {"server task start"})
			helpers.assert_eq(fixture.daemon.tasks[1].settled, false,
				"start refusal retains the exact partial foreground transport")
			helpers.assert_eq(#fixture.timers, 0)
			retire_daemon(fixture.daemon, 78)
			helpers.assert_eq(cancellations, {"server task start"},
				"a completion delivered after start refusal must remain inert")
		end)

		with_fixture({}, function(fixture)
			local cancellations, details = {}, {}
			fixture.manager.check_requirements("demo", function() end, function(reason, detail)
				cancellations[#cancellations + 1] = reason
				details[#details + 1] = detail
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			-- The native protocol permits only the authentic refusal status78
			-- before READY; arbitrary exit7 without that receipt is retained debt.
			retire_daemon(fixture.daemon, 78, function()
				helpers.assert_eq(cancellations, {},
					"RETIRED alone cannot deliver the native terminal before physical settlement")
				helpers.assert_eq(#fixture.timers, 0)
				helpers.assert_eq(fixture.daemon.tasks[1].settled, false)
			end)
			fixture.daemon.tasks[1].complete(78, "", "duplicate")
			-- A failed restart leaves nothing at the endpoint: one reason for every
			-- caller (llm-enable-unreachable-local), the step that gave up as detail
			helpers.assert_eq(cancellations, {require("modules.llm.ollama_endpoint").UNREACHABLE})
			helpers.assert_eq(details, {"restart_failed"})
			helpers.assert_eq(#fixture.timers, 0,
				"a failed restart cannot schedule readiness work from a duplicate completion")
		end)
		with_fixture({}, function(fixture)
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			-- Preserve the original nonzero7 input independently: exit alone
			-- cannot certify a new native lifecycle that omitted RETIRED.
			fixture.daemon.tasks[1].complete(7, "", "native exit without receipt")
			helpers.assert_eq(cancellations, {"native lifecycle receipt unsettled"})
			helpers.assert_eq(#fixture.timers, 0)
			helpers.assert_eq(fixture.daemon.tasks[1].settled, true,
				"transport exit is observed but the native retirement receipt is absent")
			local refused = {}
			helpers.assert_eq(fixture.manager.check_requirements("next", function() end,
				function(reason) refused[#refused + 1] = reason end,
				{is_current = function() return true end}), false)
			helpers.assert_eq(refused, {"prior_operation_unsettled"})
			helpers.assert_eq(#fixture.daemon.tasks, 1,
				"a physical exit cannot replace the missing native retirement authority")
		end)
	end)

	helpers.it("HS-025 releases the old readiness owner before a terminal callback reenters", function()
		local reentered = false
		local reentry_accepted = nil
		with_fixture({
			on_native_construct = function(manager, label)
				if reentered or label ~= "Ollama model requirement check" then return end
				reentered = true
				reentry_accepted = manager.check_requirements("B", function() end,
					function() end, {is_current = function() return true end})
			end,
		}, function(fixture)
			local accepted = fixture.manager.check_requirements("A", function() end,
				function() end, {is_current = function() return true end})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.spawns, 1)
			fixture.spawns[1].complete(0, '{"version":"ready"}', "")
			helpers.assert_eq(reentry_accepted, true)
			helpers.assert_eq(#fixture.spawns, 2,
				"a terminal callback must acquire a fresh owner after the predecessor releases")
			fixture.spawns[1].complete(0, '{"version":"duplicate"}', "")
			helpers.assert_eq(#fixture.spawns, 2,
				"the old completion cannot overwrite or duplicate the reentrant owner")
		end)
	end)

	helpers.it("HS-025 reports delete readiness refusal to the user", function()
		with_fixture({start_results = {false}}, function(fixture)
			local accepted = fixture.manager.delete_model("demo")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#fixture.native_tasks, 0)
			helpers.assert_eq(#fixture.notifications, 1,
				"a refused readiness probe must not turn delete into a silent no-op")
			helpers.assert_eq(fixture.notifications[1][1], "ollama.delete_fail_title")
			helpers.assert_eq(fixture.notifications[1][3], "error")
			fixture.spawns[1].complete(0, '{"version":"late"}', "")
			helpers.assert_eq(#fixture.notifications, 1,
				"a late completion after refusal cannot duplicate the delete failure")
	end)
	end)

	helpers.it("HS-025 commits delete output only after the native start commits", function()
		with_fixture({
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
			native_synchronous_completions = {
				table.pack(0, "", ""),
			},
			task_start_results = {false},
		}, function(fixture)
			local accepted = fixture.manager.delete_model("demo")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#fixture.native_tasks, 1)
			helpers.assert_eq(fixture.menu_updates(), 0,
				"a pre-commit completion cannot publish a menu refresh")
			helpers.assert_eq(#fixture.notifications, 1,
				"start refusal must publish one failure and no provisional success")
			helpers.assert_eq(fixture.notifications[1][1], "ollama.delete_fail_title")
			fixture.native_tasks[1].on_done(0, "", "")
			helpers.assert_eq(#fixture.notifications, 1,
				"a late completion after start refusal must remain inert")
			helpers.assert_eq(fixture.menu_updates(), 0)
		end)

		with_fixture({
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
			native_synchronous_completions = {
				table.pack(0, "", ""),
			},
		}, function(fixture)
			local accepted = fixture.manager.delete_model("demo")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.notifications, 1)
			helpers.assert_eq(fixture.notifications[1][1], "ollama.deleted_title")
			helpers.assert_eq(fixture.menu_updates(), 1)
			fixture.native_tasks[1].on_done(0, "", "")
			helpers.assert_eq(#fixture.notifications, 1,
				"duplicate native completion must not republish deletion success")
			helpers.assert_eq(fixture.menu_updates(), 1)
		end)
	end)

	helpers.it("HS-025 reports delete task construction refusal once", function()
		with_fixture({
			synchronous_completions = {
				table.pack(0, '{"version":"inline"}', ""),
			},
			native_task_results = {false},
		}, function(fixture)
			local accepted = fixture.manager.delete_model("demo")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#fixture.native_tasks, 0)
			helpers.assert_eq(#fixture.notifications, 1)
			helpers.assert_eq(fixture.notifications[1][1], "ollama.delete_fail_title")
			helpers.assert_eq(fixture.menu_updates(), 0)
		end)
	end)

	helpers.it("HS-025 composes the real ShellRunner and TimerScheduler ownership contracts", function()
		local saved_modules = {}
		for _, name in ipairs(MODULES) do saved_modules[name] = package.loaded[name] end
		local saved_hs = _G.hs
		local ok, err = xpcall(function()
			local shell_tasks = {}
			local native_timers = {}
			local model_tasks = {}
			local daemon = foreground_fixture({})
			package.loaded["modules.llm.api_ollama"] = daemon.api

			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.notifications"] = {notify = function() return true end}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.text_utils"] = {shell_quote = function(value) return tostring(value) end}
			package.loaded["modules.llm.ollama_binary"] = {
				resolve = function() return "/opt/homebrew/bin/ollama" end,
			}
			package.loaded["modules.llm.ollama_server_command"] = {
				build = function() return "exec /opt/homebrew/bin/ollama serve" end,
			}
			package.loaded["ui.download_window"] = {
				show = function() return true end,
				update = function() return true end,
				complete = function() return true end,
			}
			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, executable, on_done, on_chunk_or_args, args)
					local on_stream = type(on_chunk_or_args) == "function"
						and on_chunk_or_args or nil
					local argv = on_stream and (args or {}) or on_chunk_or_args
					local task = {
						label = label,
						executable = executable,
						on_done = on_done,
						on_stream = on_stream,
						args = argv,
					}
					model_tasks[#model_tasks + 1] = task
					return task
				end,
				start = function() return true end,
			}

			_G.hs = {
				execute = function() error("real readiness adapters must not call hs.execute") end,
				task = {new = function(executable, on_done, args)
					local task = {executable = executable, args = args, running_state = false}
					function task:start()
						self.running_state = true
						return self
					end
					function task:terminate()
						self.running_state = false
						return self
					end
					function task:complete(exit_code, stdout, stderr)
						self.running_state = false
						return on_done(exit_code, stdout, stderr)
					end
					shell_tasks[#shell_tasks + 1] = task
					return helpers.attach_native_task_environment(task)
				end},
				timer = {
					new = function(delay, callback)
						local timer = {delay = delay, running_state = false}
						function timer:start()
							self.running_state = true
							return self
						end
						function timer:stop()
							self.running_state = false
							return self
						end
						function timer:running() return self.running_state end
						function timer:fire() return callback() end
						native_timers[#native_timers + 1] = timer
						return timer
					end,
					doAfter = function() return {stop = function() return true end} end,
					secondsSinceEpoch = function() return 100 end,
				},
				json = {encode = function() return "{}" end},
				http = {asyncPost = function() return nil end},
				urlevent = {openURL = function() return true end},
			}

			package.loaded["adapters.shell_runner"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			package.loaded["ui.menu.menu_llm.models_manager_ollama"] = nil
			local manager = require("ui.menu.menu_llm.models_manager_ollama").new({
				active_tasks = {}, state = {}, keymap = {},
				shared_system_check = function() return false end,
			}, {}, function() return 0 end)
			helpers.assert_eq(#native_timers, 1)
			helpers.assert_eq(
				require("adapters.timer_scheduler").cancelAll(), true)
			helpers.assert_eq(native_timers[1]:running(), false)
			table.remove(native_timers, 1)

			local accepted = manager.check_requirements("demo", function() end, function() end,
				{is_current = function() return true end})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#shell_tasks, 1)
			helpers.assert_eq(shell_tasks[1].executable, "/usr/bin/curl")
			shell_tasks[1]:complete(28, "", "timeout")
			helpers.assert_eq(#shell_tasks, 1)
			helpers.assert_eq(#daemon.tasks, 1)
			publish_daemon_ready(daemon)
			helpers.assert_eq(#native_timers, 1)
			helpers.assert_eq(native_timers[1]:running(), true)
			native_timers[1]:fire()
			helpers.assert_eq(native_timers[1]:running(), false,
				"the real TimerScheduler must settle its exact native retry handle before delivery")
			helpers.assert_eq(#shell_tasks, 2)
			shell_tasks[2]:complete(0, '{"version":"ready"}', "")
			helpers.assert_eq(#model_tasks, 1)
		end, debug.traceback)

		_G.hs = saved_hs
		for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("HS-035 Ollama requirement pull terminal delivery", function()
	helpers.it("(HS-035-process-failure) forwards a pull process failure exactly once", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.native_tasks, 2)
			helpers.assert_eq(fixture.native_tasks[2].args, {"pull", "missing-model"})
			helpers.assert_type(fixture.native_tasks[2].on_stream, "function")
			fixture.native_tasks[2].on_stream(nil, "", "pull failed")
			fixture.native_tasks[2].on_done(2, "", "pull failed")
			fixture.native_tasks[2].on_done(2, "", "duplicate")
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"process_failed"})
		end)
	end)

	helpers.it("(HS-035-user-cancel) forwards user cancellation after native settlement", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			local progress = fixture.download_options()
			helpers.assert_type(progress, "table")
			helpers.assert_type(progress.on_cancel, "function")
			helpers.assert_eq(progress.on_cancel(), true)
			helpers.assert_eq(terminal.failures, 0,
				"termination request is not process settlement")
			fixture.native_tasks[2].on_done(15, "", "")
			fixture.native_tasks[2].on_done(15, "", "duplicate")
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"user_cancelled"})
		end)
	end)

	helpers.it("(HS-035-construction-refusal) preserves the child construction reason", function()
		with_fixture({
			shared_system_check = accept_model_download,
			native_task_results = {[2] = false},
		}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.native_tasks, 1)
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"task_construction_failed"})
		end)
	end)

	helpers.it("(HS-035-start-refusal) preserves the child start reason", function()
		with_fixture({
			shared_system_check = accept_model_download,
			task_start_results = {[2] = false},
		}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#fixture.native_tasks, 2)
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"task_start_refused"})
		end)
	end)

	helpers.it("(HS-035-stale-duplicate) forwards one stale terminal from late pull completion", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local freshness = {current = true}
			local accepted, terminal = start_missing_model_pull(fixture, freshness)
			helpers.assert_eq(accepted, true)
			freshness.current = false
			fixture.native_tasks[2].on_done(0, "", "")
			fixture.native_tasks[2].on_done(0, "", "duplicate")
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"stale"})
			helpers.assert_eq(#fixture.http_callbacks, 0)
		end)
	end)

	helpers.it("(HS-035-loadability-stale-duplicate) rejects a late loadability success", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local freshness = {current = true}
			local accepted, terminal = start_missing_model_pull(fixture, freshness)
			helpers.assert_eq(accepted, true)
			fixture.native_tasks[2].on_done(0, "", "")
			helpers.assert_eq(#fixture.http_callbacks, 1)
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 0)

			freshness.current = false
			fixture.http_callbacks[1].callback(200, "{}", {})
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			fixture.native_tasks[2].on_done(0, "", "duplicate")
			helpers.assert_eq(terminal.successes, 0)
			helpers.assert_eq(terminal.failures, 1)
			helpers.assert_eq(terminal.reasons, {"stale"})
		end)
	end)

	helpers.it("(HS-035-success-duplicate) forwards one success after loadability", function()
		with_fixture({shared_system_check = accept_model_download}, function(fixture)
			local accepted, terminal = start_missing_model_pull(fixture, {current = true})
			helpers.assert_eq(accepted, true)
			fixture.native_tasks[2].on_done(0, "", "")
			helpers.assert_eq(terminal.successes, 0,
				"pull completion alone cannot bypass the loadability boundary")
			helpers.assert_eq(#fixture.http_callbacks, 1)
			fixture.http_callbacks[1].callback(200, "{}", {})
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			fixture.native_tasks[2].on_done(0, "", "duplicate")
			helpers.assert_eq(terminal.successes, 1)
			helpers.assert_eq(terminal.failures, 0)
			helpers.assert_eq(terminal.reasons, {})
		end)
	end)
end)
