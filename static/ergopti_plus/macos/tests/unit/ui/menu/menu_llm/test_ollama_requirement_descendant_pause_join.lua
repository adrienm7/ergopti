--- tests/unit/ui/menu/menu_llm/test_ollama_requirement_descendant_pause_join.lua

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"hs",
	"tests.stubs.hs",
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"infra.text_utils",
	"infra.keycodes",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"adapters.key_state",
	"adapters.shell_runner",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"adapters.http_client",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"modules.keylogger",
	"modules.llm",
	"modules.llm.api_mlx",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"modules.llm.warmup_controller",
	"modules.llm.ollama_binary",
	"modules.llm.ollama_server_command",
	"modules.shortcuts.script_control",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"ui.tooltip",
	"ui.download_window",
	"ui.menu.menu_llm.requirement_operation_registry",
	"ui.menu.menu_llm.models_manager_ollama",
}

local function notify_observers(owner)
	local observers = owner.observers or {}
	owner.observers = {}
	for _, observer in ipairs(observers) do observer() end
end

local function with_fixture(callback)
	local saved_hs = _G.hs
	local outcome = table.pack(xpcall(function()
		helpers.with_fresh_modules(OWNED_MODULES, function()
			package.loaded["tests.stubs.hs"] = nil
			local hs_fixture = require("tests.stubs.hs")
			hs_fixture.__reset()
			_G.hs = hs_fixture
			package.loaded["hs"] = hs_fixture

			local native = {
				commands = {},
				tasks = {},
				timers = {},
				http_clients = {},
				cancel_mode = "true",
				task_start_mode = "true",
				timer_cancel_mode = "true",
				http_cancel_mode = "true",
				reenter_retry = false,
				download_options = nil,
				download_updates = 0,
				download_messages = {},
				task_stream_on_start = {},
				task_complete_on_start = {},
				task_stream_after_complete = {},
				shared_system_mode = "dispatch",
			}

			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.notifications"] = {
				notify = function() return true end,
			}
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.text_utils"] = {
				shell_quote = function(value) return "'" .. tostring(value) .. "'" end,
			}
			package.loaded["modules.llm.ollama_binary"] = {
				resolve = function() return "/fixture/ollama" end,
			}
			package.loaded["modules.llm.ollama_server_command"] = {
				build = function() return "exec /fixture/ollama serve" end,
			}

			package.loaded["adapters.shell_runner"] = {
				spawn = function(executable, args, on_done)
					local record = {
						executable = executable,
						args = args,
						on_done = on_done,
						started = false,
						settled = false,
						terminate_calls = 0,
						observers = {},
					}
					local handle = {}
					function handle.start()
						record.started = true
						return true
					end
					function handle.terminate()
						record.terminate_calls = record.terminate_calls + 1
						if native.cancel_mode == "throw" then error("command terminate") end
						if native.cancel_mode == "false" then return false, "refused" end
						if native.cancel_mode == "nil" then return nil, "refused" end
						return true, record.settled and "settled" or "pending"
					end
					function handle.isSettled() return record.settled end
					function handle.onSettled(observer)
						if record.settled then observer() else
							record.observers[#record.observers + 1] = observer
						end
						return true
					end
					function record.complete(...)
						local first = not record.settled
						if first then record.settled = true end
						local result = on_done(...)
						if first then notify_observers(record) end
						return result
					end
					record.handle = handle
					native.commands[#native.commands + 1] = record
					return handle
				end,
			}

			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, executable, on_done, on_chunk_or_args, args)
					local task = {
						label = label,
						executable = executable,
						on_done = on_done,
						on_chunk = type(on_chunk_or_args) == "function"
							and on_chunk_or_args or nil,
						args = type(on_chunk_or_args) == "function"
							and (args or {}) or on_chunk_or_args,
						running = false,
						terminate_calls = 0,
					}
					function task:terminate()
						self.terminate_calls = self.terminate_calls + 1
						if native.cancel_mode == "throw" then error("task terminate") end
						if native.cancel_mode == "false" then return false end
						if native.cancel_mode == "nil" then return nil end
						return self
					end
					function task:isRunning() return self.running end
					function task:complete(...)
						self.running = false
						return self.on_done(...)
					end
					function task:emit(stdout, stderr)
						if type(self.on_chunk) ~= "function" then return nil end
						return self.on_chunk(self, stdout, stderr or "")
					end
					native.tasks[#native.tasks + 1] = task
					return task
				end,
				start = function(task)
					task.running = true
					local stream = native.task_stream_on_start[task.label]
					local complete = native.task_complete_on_start[task.label]
					if stream ~= nil and native.task_stream_after_complete[task.label] ~= true then
						task.start_stream_result = task:emit(stream, "")
					end
					if complete ~= nil then task:complete(complete) end
					if stream ~= nil and native.task_stream_after_complete[task.label] == true then
						task.start_stream_result = task:emit(stream, "")
					end
					if native.task_start_mode == "throw" then
						native.task_start_raised = true
						return false
					end
					if native.task_start_mode == "false" then return false end
					if native.task_start_mode == "nil" then return nil end
					return true
				end,
			}

			package.loaded["adapters.timer_scheduler"] = {
				every = function(delay, timer_callback)
					return {
						delay = delay,
						timer = {},
						callback = timer_callback,
						cancel_calls = 0,
						observers = {},
					}, true
				end,
					after = function(delay, timer_callback)
						local handle = {
							delay = delay,
							timer = {},
						callback = timer_callback,
							cancel_calls = 0,
							observers = {},
							fire_stop_mode = nil,
						}
						function handle:fire()
							if self.timer == nil then return false end
							local mode = self.fire_stop_mode or "true"
							if mode == "true" then
								self.timer = nil
								notify_observers(self)
							end
							return self.callback()
						end
						function handle:settle()
							if self.timer ~= nil then
								self.timer = nil
								notify_observers(self)
							end
							return true
						end
						native.timers[#native.timers + 1] = handle
						if type(native.timer_after_hook) == "function" then
							native.timer_after_hook(handle)
						end
						return handle, true
					end,
				cancel = function(handle)
					handle.cancel_calls = handle.cancel_calls + 1
					local mode = handle.cancel_mode or native.timer_cancel_mode
					if mode == "throw" then error("timer cancel") end
					if mode == "false" then return false end
					if mode == "nil" then return nil end
					if handle.timer ~= nil then
						handle.timer = nil
						notify_observers(handle)
					end
					return true
				end,
				onSettled = function(handle, observer)
					if handle.timer == nil then observer() else
						handle.observers[#handle.observers + 1] = observer
					end
					return true
				end,
			}

			package.loaded["adapters.http_client"] = {
				new = function()
					local client = { settled = false, observers = {}, cancel_calls = 0 }
					function client.post(url, headers, body, on_done)
						client.url, client.headers, client.body = url, headers, body
						client.on_done = on_done
						return true
					end
					function client.cancel()
						client.cancel_calls = client.cancel_calls + 1
						if native.http_cancel_mode == "throw" then error("http cancel") end
						if native.http_cancel_mode == "false" then return false end
						if native.http_cancel_mode == "nil" then return nil end
						if not client.settled then
							client.settled = true
							notify_observers(client)
						end
						return true
					end
					function client.onSettled(observer)
						if client.settled then observer() else
							client.observers[#client.observers + 1] = observer
						end
						return true
					end
					function client.complete(result)
						local callback_result = client.on_done(result)
						if not client.settled then
							client.settled = true
							notify_observers(client)
						end
						return callback_result
					end
					native.http_clients[#native.http_clients + 1] = client
					return client
				end,
			}

			package.loaded["ui.download_window"] = {
				show = function(options)
					native.download_options = options
					return true
				end,
				update = function(_, _, _, message)
					native.download_updates = native.download_updates + 1
					native.download_messages[#native.download_messages + 1] = message
					return true
				end,
				complete = function()
					if native.reenter_retry and native.download_options
						and type(native.download_options.on_retry) == "function" then
						native.reenter_retry = false
						native.download_options.on_retry()
					end
					return true
				end,
			}

			local admission_fence = nil
			package.loaded["infra.keycodes"] = {
				F13_KARABINER_RETURN = 106,
				F14_KARABINER_BACKSPACE = 107,
				F15_KARABINER_ESCAPE = 108,
				BACKSPACE = 51, RETURN = 36, ESCAPE = 53,
			}
			package.loaded["adapters.event_provenance"] = {
				STATUS_UNREADABLE = "unreadable",
				classify_with_fence = function() return nil, "physical", nil end,
			}
			package.loaded["adapters.synthetic_input"] = {
				when_idle = function(fn) fn() return true end,
				acquire_admission_fence = function()
					if admission_fence then return nil end
					admission_fence = {}
					return admission_fence
				end,
				release_admission_fence = function(token)
					if token ~= admission_fence then return false end
					admission_fence = nil
					return true
				end,
				admission_open = function() return admission_fence == nil end,
				defer_after_callback = function(_, fn) return fn() == true end,
			}
			package.loaded["adapters.key_state"] = {
				is_right_altgr_held = function() return false end,
				describe_held_modifiers = function() return "(none)" end,
			}
			package.loaded["modules.gestures.engine"] = {}
			package.loaded["modules.gestures.actions"] = {
				get_label = function(name) return name end,
				execute_single = function() return true end,
				SG_NAMES = { "none", "script_pause_toggle" }, AX_NAMES = {},
			}
			for _, module_name in ipairs({
				"modules.llm", "modules.llm.api_mlx", "modules.llm.api_ollama",
				"modules.llm.api_remote", "modules.llm.warmup_controller",
			}) do
				package.loaded[module_name] = {
					pause_warmup = function() return true end,
					resume_warmup = function() return true end,
				}
			end
			for _, module_name in ipairs({ "ui.wpm.wpm_menubar", "ui.wpm.wpm_widget" }) do
				package.loaded[module_name] = {
					is_running = function() return false end,
					stop = function() return true end,
					resume_after_pause = function() return true end,
				}
			end
			package.loaded["platform.remap.onboarding"] = { stop = function() return true end }
			package.loaded["ui.tooltip"] = { hide_forced = function() return true end }
			package.loaded["modules.keylogger"] = {
				resync_context = function() return true end,
				log_shortcut = function() return true end,
			}

			local script_control = require("modules.shortcuts.script_control")
			helpers.assert_true(script_control.start({
				pause_processing = function() return true end,
				resume_processing = function() return true end,
				reset_predictions = function() return true end,
				reset_predictions_for_pause = function() return true end,
			}, {
				is_bindings_started = function() return false end,
				pause_bindings = function() return true end,
				resume_bindings = function() return true end,
				release_bindings_pause_claim = function() return true end,
			}, {
				is_enabled = function() return false end,
				suspend = function() return true end,
				resume = function() return true end,
			}))

			native.menu_updates = 0
			local maintenance_trace = {
				pause_calls = 0,
				pause_results = {},
				resume_calls = 0,
			}
			local manager_control = {
				is_paused = function() return script_control.is_paused() end,
				is_pause_transition_pending = function()
					return script_control.is_pause_transition_pending()
				end,
				register_pause_owner = function(owner_name, owner)
					maintenance_trace.owner_name = owner_name
					maintenance_trace.owner = owner
					return script_control.register_pause_owner(owner_name, {
						pause = function()
							maintenance_trace.pause_calls =
								maintenance_trace.pause_calls + 1
							local result = owner.pause()
							maintenance_trace.pause_results[
								#maintenance_trace.pause_results + 1] = result
							return result
						end,
						resume = function()
							maintenance_trace.resume_calls =
								maintenance_trace.resume_calls + 1
							return owner.resume()
						end,
					})
				end,
			}
			local manager = require("ui.menu.menu_llm.models_manager_ollama").new({
				active_tasks = {},
				state = {},
				keymap = {},
				script_control = manager_control,
				save_prefs = function() return true end,
				update_menu = function()
					native.menu_updates = native.menu_updates + 1
					return true
				end,
				shared_system_check = function(_, _, _, start_download)
					if native.shared_system_mode == "nil" then return nil end
					return start_download()
				end,
			}, {{ families = {{ models = {{
				name = "fixture-model",
				urls = { ollama = "https://ollama.com/library/fixture-model" },
			}} }} }}, function() return 0 end)
			helpers.assert_eq(maintenance_trace.owner_name,
				"ollama_model_maintenance")
			helpers.assert_type(maintenance_trace.owner, "table")
			helpers.assert_type(maintenance_trace.owner.pause, "function")
			helpers.assert_type(maintenance_trace.owner.resume, "function")

			local capabilities = {
				activation = manager.create_requirement_owner("activation"),
				model = manager.create_requirement_owner("model"),
				startup = manager.create_requirement_owner("startup"),
			}
			local pause_counts = { activation = 0, model = 0, startup = 0 }
			local requirement_pause_results = {}
			for _, item in ipairs({
				{ key = "activation", name = "llm_activation" },
				{ key = "model", name = "llm_model_switcher" },
				{ key = "startup", name = "llm_startup" },
			}) do
				-- Publish each capability identity directly into its callback closure;
				-- the pause inventory must never depend on loop-variable semantics.
				local owner_key = item.key
				local owner_name = item.name
				helpers.assert_true(script_control.register_pause_owner(owner_name, {
					pause = function()
						pause_counts[owner_key] = pause_counts[owner_key] + 1
						local settled, had_operations =
							manager.pause_requirements(capabilities[owner_key])
						requirement_pause_results[owner_key] = {
							settled = settled,
							had_operations = had_operations,
						}
						return settled == true
					end,
					resume = function() return true end,
				}))
			end

			callback({
				hs = hs_fixture,
				native = native,
				manager = manager,
				script_control = script_control,
				capabilities = capabilities,
				pause_counts = pause_counts,
				requirement_pause_results = requirement_pause_results,
				maintenance_trace = maintenance_trace,
			})
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	if not outcome[1] then error(outcome[2], 0) end
end

local function dispatch(fixture, owner_key, terminal)
	terminal = terminal or { success = 0, cancel = 0 }
	local accepted = fixture.manager.check_requirements("fixture-model", function()
		terminal.success = terminal.success + 1
		return true
	end, function()
		terminal.cancel = terminal.cancel + 1
		return true
	end, {
		requirement_owner = fixture.capabilities[owner_key],
		is_current = function() return true end,
	})
	return accepted, terminal
end

helpers.describe("HS-012 Ollama requirement descendants join ScriptControl pause", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("keeps startup readiness provenance after " .. mode .. " cancellation", function()
			with_fixture(function(fixture)
				local accepted, terminal = dispatch(fixture, "startup")
				helpers.assert_true(accepted)
				local command = fixture.native.commands[1]
				fixture.native.cancel_mode = mode
				helpers.assert_eq(fixture.script_control.pause_all(), true,
					"the public request is accepted even when its inline drain retains debt")
				helpers.assert_eq(fixture.script_control.is_paused(), false)
				helpers.assert_eq(fixture.maintenance_trace.pause_calls, 1)
				helpers.assert_eq(fixture.maintenance_trace.pause_results[1], true,
					"the exact initial timer must settle before descendant traversal")
				helpers.assert_eq(fixture.native.timers[1].cancel_calls, 1)
				helpers.assert_eq(fixture.pause_counts.activation, 1)
				helpers.assert_eq(fixture.pause_counts.model, 1)
				helpers.assert_eq(fixture.pause_counts.startup, 1)
				helpers.assert_eq(
					fixture.requirement_pause_results.startup.had_operations, true)
				helpers.assert_eq(
					fixture.requirement_pause_results.startup.settled, false)
				helpers.assert_eq(command.terminate_calls, 1)
				helpers.assert_eq(#fixture.native.commands, 1,
					"cleanup debt cannot dispatch a successor")

				helpers.assert_eq(fixture.script_control.pause_all(), true)
				helpers.assert_eq(fixture.script_control.is_paused(), false)
				helpers.assert_eq(command.terminate_calls, 2)
				command.complete(0, '{"version":"late"}', "")
				command.complete(0, '{"version":"duplicate"}', "")
				helpers.assert_eq(#fixture.native.tasks, 0)
				helpers.assert_eq(terminal.success, 0)
				helpers.assert_eq(terminal.cancel, 0)
				helpers.assert_true(fixture.script_control.pause_all())
				helpers.assert_true(fixture.script_control.is_paused())
				helpers.assert_true(fixture.script_control.resume_all())

				local model_accepted = dispatch(fixture, "model")
				helpers.assert_true(model_accepted)
				helpers.assert_eq(#fixture.native.commands, 2,
					"only a fresh post-RESUME owner may dispatch readiness")
				helpers.assert_true(fixture.script_control.stop())
			end)
		end)
	end

	helpers.it("joins the exact model-list task before PAUSED", function()
		with_fixture(function(fixture)
			local _, terminal = dispatch(fixture, "activation")
			fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
			local list_task = fixture.native.tasks[1]
			helpers.assert_contains(list_task.label, "requirement check")
			fixture.native.cancel_mode = "false"
			helpers.assert_eq(fixture.script_control.pause_all(), true)
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_eq(list_task.terminate_calls, 1)
			helpers.assert_eq(fixture.script_control.pause_all(), true)
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_eq(list_task.terminate_calls, 2)
			list_task:complete(0, "NAME ID\nfixture-model fixture\n", "")
			list_task:complete(0, "duplicate", "")
			helpers.assert_eq(#fixture.native.http_clients, 0)
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.stop())
		end)
	end)

	helpers.it("rejects a nil shared system-check admission", function()
		with_fixture(function(fixture)
			fixture.native.shared_system_mode = "nil"
			local _, terminal = dispatch(fixture, "activation")
			fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
			fixture.native.tasks[1]:complete(0, "NAME ID\n", "")
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 1)
			helpers.assert_eq(#fixture.native.tasks, 1,
				"nil must not be normalized into a committed pull successor")
			helpers.assert_eq(#fixture.native.http_clients, 0)
			helpers.assert_eq(fixture.native.download_updates, 0)
			helpers.assert_true(fixture.script_control.stop())
		end)
	end)

	helpers.it("joins loadability HTTP and fences its late terminal", function()
		with_fixture(function(fixture)
			local _, terminal = dispatch(fixture, "model")
			fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
			fixture.native.tasks[1]:complete(0,
				"NAME ID\nfixture-model fixture\n", "")
			local client = fixture.native.http_clients[1]
			fixture.native.http_cancel_mode = "nil"
			helpers.assert_eq(fixture.script_control.pause_all(), true)
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_eq(client.cancel_calls, 1)
			helpers.assert_eq(fixture.script_control.pause_all(), true)
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_eq(client.cancel_calls, 2)
			client.complete({ status = 200, body = "{}", headers = {} })
			client.complete({ status = 200, body = "duplicate", headers = {} })
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 0)
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.stop())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("discards synchronous pull stream after " .. mode
			.. " start refusal", function()
			with_fixture(function(fixture)
				local _, terminal = dispatch(fixture, "model")
				fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
				local list_task = fixture.native.tasks[1]
				fixture.native.task_start_mode = mode
				fixture.native.cancel_mode = "false"
				fixture.native.task_stream_on_start["Ollama model pull"] =
					"pull business before commit\n"
				list_task:complete(0, "NAME ID\n", "")
				local pull_task = fixture.native.tasks[2]
				helpers.assert_not_nil(pull_task)
				helpers.assert_eq(pull_task.start_stream_result, true)
				helpers.assert_eq(fixture.native.download_updates, 1,
					"the initial progress message is the only authorized update")
				helpers.assert_eq(fixture.native.download_messages[1],
					"ollama.downloading")
				helpers.assert_eq(pull_task.terminate_calls, 1)
				pull_task:emit("late refused pull business\n", "")
				helpers.assert_eq(fixture.native.download_updates, 1)
				pull_task:complete(15, "", "")
				pull_task:emit("post-terminal pull business\n", "")
				helpers.assert_eq(fixture.native.download_updates, 1)
				helpers.assert_eq(terminal.success, 0)
			end)
		end)
	end

	helpers.it("replays one committed pull stream and fences terminal-late chunks", function()
		with_fixture(function(fixture)
			dispatch(fixture, "model")
			fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
			fixture.native.task_stream_on_start["Ollama model pull"] =
				"committed pull business\n"
			fixture.native.tasks[1]:complete(0, "NAME ID\n", "")
			local pull_task = fixture.native.tasks[2]
			helpers.assert_eq(fixture.native.download_updates, 2)
			helpers.assert_eq(fixture.native.download_messages[2],
				"committed pull business")
			pull_task:complete(15, "", "")
			pull_task:emit("late pull business\n", "")
			helpers.assert_eq(fixture.native.download_updates, 2)
		end)
	end)

	helpers.it("drops a pull chunk delivered synchronously after completion", function()
		with_fixture(function(fixture)
			dispatch(fixture, "model")
			fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
			fixture.native.task_stream_on_start["Ollama model pull"] =
				"post-terminal pull business\n"
			fixture.native.task_complete_on_start["Ollama model pull"] = 1
			fixture.native.task_stream_after_complete["Ollama model pull"] = true
			fixture.native.tasks[1]:complete(0, "NAME ID\n", "")
			helpers.assert_eq(fixture.native.download_updates, 1,
				"terminal-first start keeps only the initial progress update")
		end)
	end)

	helpers.it("joins pull and its reentrant retry timer without a successor", function()
		with_fixture(function(fixture)
			local _, terminal = dispatch(fixture, "startup")
			fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
			fixture.native.tasks[1]:complete(0, "NAME ID\n", "")
			local pull_task = fixture.native.tasks[2]
			helpers.assert_contains(pull_task.label, "model pull")
			fixture.native.reenter_retry = true
			pull_task:complete(1, "", "connection refused")
			local retry = fixture.native.timers[#fixture.native.timers]
			helpers.assert_true(type(retry) == "table")
			retry.cancel_mode = "throw"
			helpers.assert_eq(fixture.script_control.pause_all(), true)
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_eq(retry.cancel_calls, 1)
			helpers.assert_eq(fixture.script_control.pause_all(), true)
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_eq(retry.cancel_calls, 2)
			helpers.assert_eq(#fixture.native.tasks, 2)
			retry.timer = nil
			notify_observers(retry)
			helpers.assert_eq(#fixture.native.tasks, 2,
				"a revoked retry terminal cannot launch another pull")
			helpers.assert_eq(terminal.success, 0)
			helpers.assert_eq(terminal.cancel, 0)
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.stop())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("defers pull retry after natural one-shot stop " .. mode, function()
			with_fixture(function(fixture)
				dispatch(fixture, "startup")
				fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
				fixture.native.tasks[1]:complete(0, "NAME ID\n", "")
				local pull_task = fixture.native.tasks[2]
				fixture.native.reenter_retry = true
				pull_task:complete(1, "", "connection refused")
				local retry = fixture.native.timers[#fixture.native.timers]
				retry.fire_stop_mode = mode
				retry:fire()
				helpers.assert_eq(#fixture.native.tasks, 2,
					"live pull retry timer cannot launch a sibling task")
				retry:fire()
				helpers.assert_eq(#fixture.native.tasks, 2)
				retry:settle()
				helpers.assert_eq(#fixture.native.tasks, 3,
					"exact timer settlement launches one fresh pull")
				retry.callback()
				helpers.assert_eq(#fixture.native.tasks, 3)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("publishes pull retry before reentrant PAUSE with cancel "
			.. mode, function()
			with_fixture(function(fixture)
				dispatch(fixture, "startup")
				fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
				fixture.native.tasks[1]:complete(0, "NAME ID\n", "")
				local pull_task = fixture.native.tasks[2]
				fixture.native.reenter_retry = true
				fixture.native.timer_after_hook = function(handle)
					fixture.native.timer_after_hook = nil
					handle.cancel_mode = mode
					fixture.reentrant_pull_pause = fixture.script_control.pause_all()
				end
				pull_task:complete(1, "", "connection refused")
				local retry = fixture.native.timers[#fixture.native.timers]
				helpers.assert_eq(fixture.reentrant_pull_pause, true)
				helpers.assert_eq(fixture.script_control.is_paused(), false)
				helpers.assert_eq(retry.cancel_calls, 1)
				helpers.assert_eq(#fixture.native.tasks, 2)

				retry.cancel_mode = "true"
				helpers.assert_true(fixture.script_control.pause_all())
				helpers.assert_true(fixture.script_control.is_paused())
				retry.callback()
				helpers.assert_eq(#fixture.native.tasks, 2)
				helpers.assert_true(fixture.script_control.resume_all())
				helpers.assert_true(dispatch(fixture, "startup"))
				helpers.assert_eq(#fixture.native.commands, 2,
					"RESUME admits one fresh readiness operation")
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("defers readiness retry after natural one-shot stop " .. mode,
			function()
				with_fixture(function(fixture)
					dispatch(fixture, "startup")
					fixture.native.commands[1].complete(1, "", "offline")
					fixture.native.commands[2].complete(0, "", "")
					local retry = fixture.native.timers[#fixture.native.timers]
					retry.fire_stop_mode = mode
					retry:fire()
					helpers.assert_eq(#fixture.native.commands, 2,
						"a live fired timer cannot dispatch its readiness successor")
					retry:fire()
					helpers.assert_eq(#fixture.native.commands, 2,
						"duplicate delivery remains cleanup-only")
					retry:settle()
					helpers.assert_eq(#fixture.native.commands, 3,
						"exact timer settlement authorizes one retry probe")
					retry.callback()
					helpers.assert_eq(#fixture.native.commands, 3,
						"late timer callback cannot dispatch a sibling probe")
				end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("publishes readiness retry before reentrant PAUSE with cancel "
			.. mode, function()
			with_fixture(function(fixture)
				dispatch(fixture, "startup")
					fixture.native.commands[1].complete(1, "", "offline")
					fixture.native.timer_after_hook = function(handle)
						fixture.native.timer_after_hook = nil
						handle.cancel_mode = mode
						fixture.reentrant_pause = fixture.script_control.pause_all()
						handle.acquired_during_pause = true
					end
					fixture.native.commands[2].complete(0, "", "")
					local retry = fixture.native.timers[#fixture.native.timers]
					helpers.assert_eq(fixture.reentrant_pause, true)
					helpers.assert_eq(fixture.script_control.is_paused(), false)
					helpers.assert_true(retry.timer ~= nil)
					helpers.assert_eq(retry.cancel_calls, 1)
					helpers.assert_eq(#fixture.native.commands, 2)

					retry.cancel_mode = "true"
					helpers.assert_true(fixture.script_control.pause_all())
					helpers.assert_true(fixture.script_control.is_paused())
					helpers.assert_eq(retry.timer, nil)
					retry.callback()
					helpers.assert_eq(#fixture.native.commands, 2,
						"revoked acquisition cannot dispatch after settlement")
					helpers.assert_true(fixture.script_control.resume_all())
					helpers.assert_true(dispatch(fixture, "startup"))
					helpers.assert_eq(#fixture.native.commands, 3,
						"RESUME admits one fresh readiness operation")
				end)
		end)
	end

	helpers.it("joins the initial installed-model refresh task and fences its late cache", function()
		with_fixture(function(fixture)
			local initial_timer = fixture.native.timers[1]
			helpers.assert_eq(initial_timer.delay, 0)
			helpers.assert_true(initial_timer:fire())
			local refresh_task = fixture.native.tasks[1]
			helpers.assert_contains(refresh_task.label, "installed-model refresh")

			fixture.native.cancel_mode = "false"
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(
				fixture.script_control.is_pause_transition_pending())
			helpers.assert_eq(refresh_task.terminate_calls, 1)
			refresh_task:complete(0, "NAME ID\nlate:latest fixture\n", "")
			helpers.assert_true(
				fixture.script_control.is_pause_transition_pending(),
				"physical settlement alone cannot reopen a rolled-back PAUSE owner")
			helpers.assert_eq(fixture.manager.get_installed_models()["late:latest"], nil,
				"a revoked refresh terminal must not populate the cache")
			helpers.assert_eq(#fixture.native.tasks, 1,
				"the pending pause transition must refuse a replacement refresh")
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
			helpers.assert_true(fixture.script_control.resume_all())

			fixture.manager.get_installed_models()
			helpers.assert_eq(#fixture.native.tasks, 2)
			fixture.native.tasks[2]:complete(0,
				"NAME ID\nfresh:latest fixture\n", "")
			helpers.assert_true(
				fixture.manager.get_installed_models()["fresh:latest"] == true)
			helpers.assert_true(fixture.script_control.stop())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("defers initial refresh after natural one-shot stop " .. mode,
			function()
				with_fixture(function(fixture)
					local initial_timer = fixture.native.timers[1]
					initial_timer.fire_stop_mode = mode
					initial_timer:fire()
					helpers.assert_true(initial_timer.timer ~= nil)
					helpers.assert_eq(#fixture.native.tasks, 0,
						"refresh task must wait for exact native timer settlement")
					fixture.manager.get_installed_models()
					helpers.assert_eq(#fixture.native.tasks, 0,
						"live timer owner must block a replacement refresh")

					initial_timer:settle()
					helpers.assert_eq(#fixture.native.tasks, 1)
					initial_timer.callback()
					helpers.assert_eq(#fixture.native.tasks, 1,
						"late one-shot delivery cannot launch a sibling refresh")
					fixture.native.tasks[1]:complete(0,
						"NAME ID\nfresh:latest fixture\n", "")
					helpers.assert_true(
						fixture.manager.get_installed_models()["fresh:latest"] == true)
				end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact initial refresh task after " .. mode
			.. " start refusal", function()
			with_fixture(function(fixture)
				fixture.native.task_start_mode = mode
				fixture.native.cancel_mode = "false"
				local initial_timer = fixture.native.timers[1]
				helpers.assert_eq(initial_timer:fire(), false)
				local refused_task = fixture.native.tasks[1]
				helpers.assert_true(refused_task.running,
					"the native-faithful double mutates before refusing start")
				helpers.assert_eq(refused_task.terminate_calls, 1)

				fixture.manager.get_installed_models()
				helpers.assert_eq(#fixture.native.tasks, 1,
					"cleanup debt must block a replacement refresh")
				helpers.assert_eq(refused_task.terminate_calls, 2,
					"successor admission retries the identical retained task")
				refused_task:complete(0,
					"NAME ID\nlate:latest fixture\n", "")
				fixture.native.task_start_mode = "true"
				fixture.native.cancel_mode = "true"
				helpers.assert_eq(fixture.manager.get_installed_models()["late:latest"], nil)
				helpers.assert_eq(#fixture.native.tasks, 2)
				fixture.native.tasks[2]:complete(0,
					"NAME ID\nfresh:latest fixture\n", "")
				helpers.assert_true(
					fixture.manager.get_installed_models()["fresh:latest"] == true)
				helpers.assert_true(fixture.script_control.stop())
			end)
		end)
	end

	helpers.it("joins Ollama deletion and fences its late menu publication", function()
		with_fixture(function(fixture)
			helpers.assert_true(fixture.manager.delete_model("fixture-model"))
			fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
			local delete_task = fixture.native.tasks[1]
			helpers.assert_contains(delete_task.label, "model delete")

			fixture.native.cancel_mode = "false"
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_eq(fixture.script_control.is_paused(), false)
			helpers.assert_true(
				fixture.script_control.is_pause_transition_pending())
			helpers.assert_eq(delete_task.terminate_calls, 1)
			delete_task:complete(0, "deleted", "")
			helpers.assert_eq(fixture.native.menu_updates, 0,
				"a revoked deletion terminal must not refresh the menu")
			helpers.assert_true(fixture.script_control.pause_all())
			helpers.assert_true(fixture.script_control.is_paused())
			helpers.assert_true(fixture.script_control.stop())
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact Ollama deletion task after " .. mode
			.. " start refusal", function()
			with_fixture(function(fixture)
				fixture.native.task_start_mode = mode
				fixture.native.cancel_mode = "false"
				helpers.assert_true(fixture.manager.delete_model("fixture-model"))
				fixture.native.commands[1].complete(0, '{"version":"ready"}', "")
				local refused_task = fixture.native.tasks[1]
				helpers.assert_true(refused_task.running)
				helpers.assert_eq(refused_task.terminate_calls, 1)
				helpers.assert_eq(fixture.native.menu_updates, 0)

				helpers.assert_eq(fixture.manager.delete_model("fixture-model"), false)
				helpers.assert_eq(#fixture.native.commands, 1,
					"cleanup debt must block a replacement deletion")
				helpers.assert_eq(refused_task.terminate_calls, 2)
				refused_task:complete(0, "late", "")
				helpers.assert_eq(fixture.native.menu_updates, 0)

				fixture.native.task_start_mode = "true"
				fixture.native.cancel_mode = "true"
				helpers.assert_true(fixture.manager.delete_model("fixture-model"))
				helpers.assert_eq(#fixture.native.commands, 2)
				fixture.native.commands[2].complete(0, '{"version":"ready"}', "")
				helpers.assert_eq(#fixture.native.tasks, 2)
				fixture.native.tasks[2]:complete(0, "deleted", "")
				helpers.assert_eq(fixture.native.menu_updates, 1)
				helpers.assert_true(fixture.script_control.stop())
			end)
		end)
	end
end)
