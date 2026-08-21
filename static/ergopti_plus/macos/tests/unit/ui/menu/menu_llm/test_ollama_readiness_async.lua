--- tests/unit/ui/menu/menu_llm/test_ollama_readiness_async.lua

-- =============================================================================
-- MODULE: Asynchronous Ollama Readiness Regression
-- DESCRIPTION:
-- Proves that readiness and daemon restart shell work is owned asynchronously,
-- generation-fenced, and terminal exactly once without blocking the Lua runloop.
-- =============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"infra.text_utils",
	"modules.llm.ollama_binary",
	"modules.llm.ollama_server_command",
	"adapters.task_lifecycle",
	"adapters.shell_runner",
	"adapters.timer_scheduler",
	"ui.download_window",
	"ui.menu.menu_llm.models_manager_ollama",
}

local function with_fixture(spec, body)
	spec = spec or {}
	local saved_modules = {}
	for _, name in ipairs(MODULES) do saved_modules[name] = package.loaded[name] end
	local saved_hs = _G.hs

	local ok, err = xpcall(function()
		local synchronous_exec_calls = 0
		local spawns = {}
		local timers = {}
		local native_tasks = {}
		local http_callbacks = {}
		local shared_system_checks = {}
		local notifications = {}
		local starts = spec.start_results or {}
		local synchronous_completions = spec.synchronous_completions or {}
		local native_synchronous_completions = spec.native_synchronous_completions or {}
		local timer_commits = spec.timer_commits or {}
		local task_starts = spec.task_start_results or {}
		local native_task_results = spec.native_task_results or {}
		local menu_updates = 0

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.notifications"] = {
			notify = function(...)
				notifications[#notifications + 1] = table.pack(...)
				return true
			end,
		}
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.text_utils"] = {
			shell_quote = function(value) return "'" .. tostring(value) .. "'" end,
		}
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

		package.loaded["adapters.shell_runner"] = {
			spawn = function(executable, args, on_done)
				local index = #spawns + 1
				local record = {
					executable = executable,
					args = args,
					starts = 0,
					completions = 0,
				}
				local handle = {}
				function handle.start()
					record.starts = record.starts + 1
					local completion = synchronous_completions[index]
					if completion ~= nil then
						on_done(table.unpack(completion, 1, completion.n or #completion))
					end
					if starts[index] == "nil" then return nil end
					return starts[index] ~= false
				end
				function handle.terminate() return true, "pending" end
				function record.complete(code, stdout, stderr)
					record.completions = record.completions + 1
					return on_done(code, stdout, stderr)
				end
				record.handle = handle
				spawns[index] = record
				return handle
			end,
		}

		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback)
				local index = #timers + 1
				local handle = {cancelled = false}
				local record = {delay = delay, handle = handle, fires = 0}
				function record.fire()
					record.fires = record.fires + 1
					return callback()
				end
				timers[index] = record
				return handle, timer_commits[index] ~= false
			end,
			cancel = function(handle)
				handle.cancelled = true
				return true
			end,
		}

		local manager
		package.loaded["adapters.task_lifecycle"] = {
			native = function(label, executable, on_done, args)
				local index = #native_tasks + 1
				if native_task_results[index] == false then return nil end
				if type(spec.on_native_construct) == "function" then
					spec.on_native_construct(manager, label)
				end
				local task = {
					index = index,
					label = label,
					executable = executable,
					args = args,
					on_done = on_done,
					starts = 0,
				}
				native_tasks[#native_tasks + 1] = task
				return task
			end,
			start = function(task)
				task.starts = task.starts + 1
				local completion = native_synchronous_completions[task.index]
				if completion ~= nil then
					task.on_done(table.unpack(completion, 1, completion.n or #completion))
				end
				if task_starts[task.index] == "nil" then return nil end
				return task_starts[task.index] ~= false
			end,
		}

		_G.hs = {
			execute = function()
				synchronous_exec_calls = synchronous_exec_calls + 1
				error("synchronous hs.execute is forbidden in readiness")
			end,
			timer = {
				doAfter = function() return {stop = function() return true end} end,
				secondsSinceEpoch = function() return 100 end,
			},
			json = {encode = function() return "{}" end},
			http = {asyncPost = function(url, body, headers, callback)
				http_callbacks[#http_callbacks + 1] = {
					url = url, body = body, headers = headers, callback = callback,
				}
				return true
			end},
			urlevent = {openURL = function() return true end},
		}

		package.loaded["ui.menu.menu_llm.models_manager_ollama"] = nil
		manager = require("ui.menu.menu_llm.models_manager_ollama").new({
			active_tasks = {},
			save_prefs = function() return true end,
			update_menu = function()
				menu_updates = menu_updates + 1
				return true
			end,
			shared_system_check = function(...)
				shared_system_checks[#shared_system_checks + 1] = table.pack(...)
				if type(spec.shared_system_check) == "function" then
					return spec.shared_system_check(...)
				end
				return false
			end,
			state = {},
			keymap = {},
		}, {}, function() return 0 end)

		body({
			manager = manager,
			spawns = spawns,
			timers = timers,
			native_tasks = native_tasks,
			http_callbacks = http_callbacks,
			shared_system_checks = shared_system_checks,
			notifications = notifications,
			menu_updates = function() return menu_updates end,
			synchronous_exec_calls = function() return synchronous_exec_calls end,
		})
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
	if not ok then error(err, 0) end
end

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
				{"-s", "--max-time", "5", "http://localhost:11434/api/version"})
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
			helpers.assert_eq(#fixture.spawns, 2)
			helpers.assert_eq(fixture.spawns[2].executable, "/bin/bash")
			helpers.assert_eq(fixture.spawns[2].args[1], "-c",
				"the shared restart must not run user login-profile startup")
			helpers.assert_eq(#fixture.timers, 0)
			fixture.spawns[2].complete(0, "", "")
			helpers.assert_eq(#fixture.timers, 1)
			helpers.assert_eq(fixture.timers[1].delay, 0.5)
			helpers.assert_eq(#fixture.spawns, 2,
				"retry work cannot run inline from the daemon completion")

			fixture.timers[1].fire()
			helpers.assert_eq(#fixture.spawns, 3)
			current = false
			fixture.spawns[3].complete(0, '{"version":"late"}', "")
			helpers.assert_eq(cancellations, {"stale"})
			helpers.assert_eq(#fixture.native_tasks, 0)
			fixture.spawns[3].complete(0, '{"version":"duplicate"}', "")
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
			fixture.spawns[2].complete(0, "", "")
			helpers.assert_eq(cancellations, {"retry_timer_refused"})
			helpers.assert_eq(#fixture.spawns, 2,
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
			helpers.assert_eq(#fixture.spawns, 2)
			helpers.assert_eq(fixture.spawns[2].executable, "/bin/bash")
			generation = 2
			local accepted_b = fixture.manager.check_requirements("B", function()
				b_successes = b_successes + 1
			end, function(reason)
				b_cancellations[#b_cancellations + 1] = reason
			end, {is_current = function() return generation == 2 end})

			helpers.assert_eq(accepted_b, true)
			helpers.assert_eq(#fixture.spawns, 2,
				"a joined waiter must adopt the exact daemon owner instead of probing or restarting again")
			fixture.spawns[2].complete(0, "", "")
			helpers.assert_eq(a_cancellations, {"stale"})
			helpers.assert_eq(b_cancellations, {})
			helpers.assert_eq(#fixture.timers, 1)
			fixture.spawns[2].complete(0, "", "duplicate")
			helpers.assert_eq(#fixture.timers, 1,
				"a duplicate restart completion cannot allocate a second retry owner")
			helpers.assert_eq(a_cancellations, {"stale"})

			fixture.timers[1].fire()
			helpers.assert_eq(#fixture.spawns, 3)
			fixture.spawns[3].complete(0, '{"version":"ready"}', "")
			helpers.assert_eq(#fixture.native_tasks, 1)
			fixture.native_tasks[1].on_done(0, "NAME ID\nB fixture\n", "")
			helpers.assert_eq(#fixture.http_callbacks, 1)
			fixture.http_callbacks[1].callback(200, "{}", {})
			fixture.http_callbacks[1].callback(200, "duplicate", {})
			fixture.spawns[3].complete(0, '{"version":"duplicate"}', "")

			helpers.assert_eq(b_successes, 1,
				"the current joined waiter must publish one outer success after duplicate completions")
			helpers.assert_eq(b_cancellations, {})
			helpers.assert_eq(a_cancellations, {"stale"})
			local restart_count = 0
			for _, spawn in ipairs(fixture.spawns) do
				if spawn.executable == "/bin/bash" then restart_count = restart_count + 1 end
			end
			helpers.assert_eq(restart_count, 1,
				"rapid A-to-B replacement must retain one shared daemon restart capability")
		end)
	end)

	helpers.it("HS-025 settles restart start refusal and nonzero completion exactly once", function()
		with_fixture({start_results = {true, false}}, function(fixture)
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			helpers.assert_eq(cancellations, {"restart_task_start_refused"})
			helpers.assert_eq(#fixture.timers, 0)
			fixture.spawns[2].complete(0, "", "")
			helpers.assert_eq(cancellations, {"restart_task_start_refused"},
				"a completion delivered after start refusal must remain inert")
		end)

		with_fixture({}, function(fixture)
			local cancellations = {}
			fixture.manager.check_requirements("demo", function() end, function(reason)
				cancellations[#cancellations + 1] = reason
			end, {is_current = function() return true end})
			fixture.spawns[1].complete(28, "", "timeout")
			fixture.spawns[2].complete(7, "", "restart failed")
			fixture.spawns[2].complete(0, "", "duplicate")
			helpers.assert_eq(cancellations, {"restart_failed"})
			helpers.assert_eq(#fixture.timers, 0,
				"a failed restart cannot schedule readiness work from a duplicate completion")
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
				native = function(label, executable, on_done, args)
					local task = {label = label, executable = executable, on_done = on_done, args = args}
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
					return task
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
				http = {asyncPost = function() return true end},
				urlevent = {openURL = function() return true end},
			}

			package.loaded["adapters.shell_runner"] = nil
			package.loaded["adapters.timer_scheduler"] = nil
			package.loaded["ui.menu.menu_llm.models_manager_ollama"] = nil
			local manager = require("ui.menu.menu_llm.models_manager_ollama").new({
				active_tasks = {}, state = {}, keymap = {},
				shared_system_check = function() return false end,
			}, {}, function() return 0 end)

			local accepted = manager.check_requirements("demo", function() end, function() end,
				{is_current = function() return true end})
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#shell_tasks, 1)
			helpers.assert_eq(shell_tasks[1].executable, "/usr/bin/curl")
			shell_tasks[1]:complete(28, "", "timeout")
			helpers.assert_eq(#shell_tasks, 2)
			helpers.assert_eq(shell_tasks[2].executable, "/bin/bash")
			shell_tasks[2]:complete(0, "", "")
			helpers.assert_eq(#native_timers, 1)
			helpers.assert_eq(native_timers[1]:running(), true)
			native_timers[1]:fire()
			helpers.assert_eq(native_timers[1]:running(), false,
				"the real TimerScheduler must settle its exact native retry handle before delivery")
			helpers.assert_eq(#shell_tasks, 3)
			shell_tasks[3]:complete(0, '{"version":"ready"}', "")
			helpers.assert_eq(#model_tasks, 1)
		end, debug.traceback)

		_G.hs = saved_hs
		for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
		if not ok then error(err, 0) end
	end)
end)

return true
