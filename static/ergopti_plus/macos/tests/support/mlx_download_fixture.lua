--- tests/support/mlx_download_fixture.lua

--- ==============================================================================
--- MODULE: MLX Download Fixture
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"hs",
	"adapters.shell_runner",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"modules.llm",
	"ui.download_window",
	"ui.download_window.javascript",
	"ui.ui_builder",
	"infra.paths",
	"infra.deferred_work",
	"ui.menu.menu_llm.model_switcher",
	"ui.menu.menu_llm.prediction_lock_registry",
	"ui.menu.menu_llm.models_manager_mlx_download",
	"ui.menu.menu_llm.models_manager_mlx_repo",
	"ui.menu.menu_llm.profile_label",
}

local function result_value(mode, fallback)
	if mode == nil or mode == "success" then return fallback end
	if mode == "false" then return false end
	if mode == "nil" then return nil end
	if mode == "throw" then error("injected native refusal") end
	return mode
end

local function with_fixture(plan, callback)
	plan = plan or {}
	local saved_hs = _G.hs
	local saved_open = io.open
	local saved_execute = os.execute
	local saved_remove = os.remove
	local saved_rename = os.rename
	local outcome = table.pack(xpcall(function()
			helpers.with_fresh_modules(MODULES, function()
			local records = {
				callback_labels = {},
				download_aborts = 0,
				download_retry_starts = 0,
				cancels = {},
				completions = {},
				gates = {},
				notifications = {},
				os_commands = {},
				pid_identity_probes = 0,
				raw_pid_signals = 0,
				verified_pid_signals = 0,
				verified_term_signals = 0,
				verified_kill_signals = 0,
				requirement_failures = {},
				requirement_successes = 0,
				saves = 0,
				server_starts = 0,
				successes = 0,
				timers = {},
				updates = {},
			}
			local controls = {
				exit_code = nil,
				files = {},
				tasks = {launcher = {}, tail = {}},
			}

			local function reenter_pause(kind, record_key)
				if kind == "requirement" then
					records[record_key] = controls.requirement_pause_join()
				elseif kind == "reattach" then
					records[record_key] = controls.pause_reattached_download()
				end
			end

			local function file_kind(path)
				if path:match("%.py$") then return "python" end
				if path:match("%.sh$") then return "launcher" end
				if path:match("hs_mlx_active_download%.json") then return "session" end
				if path:match("%.log%.exit$") then return "exit" end
				return "other"
			end

			local function boundary_mode(boundary, path)
				local modes = plan[boundary .. "_modes"]
				if type(modes) == "table" and modes[file_kind(path)] ~= nil then
					local configured = modes[file_kind(path)]
					if type(configured) == "table" and configured[1] ~= nil then
						return table.remove(configured, 1)
					end
					return configured
				end
				return plan[boundary .. "_mode"]
			end

			local function file_handle(path, mode)
				local handle = {path = path, mode = mode, closed = false}
				function handle:write(...)
					local refusal = boundary_mode("write", path)
					if refusal then return result_value(refusal, self) end
					local pieces = {}
					for index = 1, select("#", ...) do
						pieces[index] = tostring(select(index, ...))
					end
					controls.files[path] = (controls.files[path] or "") .. table.concat(pieces)
					return self
				end
				function handle:read(kind)
					if path:match("%.log%.exit$") then
						if controls.exit_code == nil then return nil end
						return tostring(controls.exit_code)
					end
					local value = controls.files[path]
					if kind == "*l" and type(value) == "string" then
						return value:match("[^\r\n]*")
					end
					return value
				end
				function handle:close()
					self.closed = true
					return result_value(boundary_mode("close", path), true)
				end
				return handle
			end

			io.open = function(path, mode)
				if mode == "r" and path:match("%.log%.exit$") then
					records.reattach_exit_probes =
						(records.reattach_exit_probes or 0) + 1
					if plan.pause_reattach_on_exit_probe
						== records.reattach_exit_probes then
						records.reentrant_reattach_probe_pause =
							controls.pause_reattached_download()
					end
				end
				local open_refusal = boundary_mode("open", path)
				if open_refusal then return result_value(open_refusal, file_handle(path, mode)) end
				if plan.fail_open == "python" and mode == "w" and path:match("%.py$") then
					return nil
				end
				if plan.fail_open == "launcher" and mode == "w" and path:match("%.sh$") then
					return nil
				end
				if mode == "r" and path:match("%.log%.exit$") then
					if controls.exit_code == nil then return nil end
					return file_handle(path, mode)
				end
				if mode == "r" and controls.files[path] == nil then return nil end
				return file_handle(path, mode)
			end

			local function pid_alive_result()
				local alive = plan.pid_alive
				if type(alive) == "table" then alive = table.remove(alive, 1) end
				return result_value(alive, false)
			end

			os.execute = function(command)
				records.os_commands[#records.os_commands + 1] = command
				if command:find("chmod", 1, true) then
					return result_value(plan.chmod_mode, true)
				end
				if command:find("MLX_EXPECTED_SCRIPT=", 1, true) then
					records.pid_identity_probes = records.pid_identity_probes + 1
					local alive = pid_alive_result()
					if alive ~= true and alive ~= 0 then return nil, "exit", 72 end
					if plan.pid_identity == false then return nil, "exit", 73 end
					if plan.pid_identity == "unknown" then return nil, "exit", 74 end
					local result = result_value(plan.kill_mode, true)
					if result == true or result == 0 then
						records.verified_pid_signals = records.verified_pid_signals + 1
						if command:find("kill %-TERM", 1, false) then
							records.verified_term_signals = records.verified_term_signals + 1
						elseif command:find("kill %-KILL", 1, false) then
							records.verified_kill_signals = records.verified_kill_signals + 1
						end
						return true, "exit", 0
					end
					return result
				end
				if command:find("kill %-0", 1, false) then
					if plan.pause_reattach_on_pid_probe == true
						and records.reentrant_reattach_pid_pause == nil then
						records.reentrant_reattach_pid_pause =
							controls.pause_reattached_download()
					end
					return pid_alive_result()
				end
				if command:find("kill %-TERM", 1, false)
					or command:find("kill %-KILL", 1, false) then
					records.raw_pid_signals = records.raw_pid_signals + 1
					return result_value(plan.kill_mode, true)
				end
				return true, "exit", 0
			end
			os.remove = function(path)
				local refusal = boundary_mode("remove", path)
				if refusal then return result_value(refusal, true) end
				controls.files[path] = nil
				return true
			end
			os.rename = function(from_path, to_path)
				local refusal = plan.rename_mode
				if type(plan.rename_sequence) == "table" and #plan.rename_sequence > 0 then
					refusal = table.remove(plan.rename_sequence, 1)
				end
				if refusal then return result_value(refusal, true) end
				controls.files[to_path] = controls.files[from_path]
				controls.files[from_path] = nil
				return true
			end

			local function task_behavior(kind)
				local configured = plan[kind]
				if type(configured) == "table" and configured[1] ~= nil then
					configured = table.remove(configured, 1)
				end
				if type(configured) == "string" then return {start = configured} end
				return configured or {}
			end

			local function timer_behavior(delay)
				if type(plan.timer_sequence) == "table" and #plan.timer_sequence > 0 then
					return table.remove(plan.timer_sequence, 1) or {}
				end
				if type(plan.timer_by_delay) == "table" then
					local configured = plan.timer_by_delay[delay]
					if type(configured) == "table" and configured[1] ~= nil then
						return table.remove(configured, 1) or {}
					end
					if configured ~= nil then return configured end
				end
				return {}
			end

			local hs_fixture = {
				json = {
					decode = function(raw)
						if type(raw) ~= "string" then return {} end
						return {
							model = raw:match('"model":"([^"]+)"'),
							log_path = raw:match('"log_path":"([^"]+)"'),
							exit_path = raw:match('"exit_path":"([^"]+)"'),
							script_path = raw:match('"script_path":"([^"]+)"'),
							repo = raw:match('"repo":"([^"]+)"'),
						}
					end,
					encode = function(value)
						return string.format(
							'{"model":"%s","log_path":"%s","exit_path":"%s","script_path":"%s","repo":"%s","pid":%s}',
							tostring(value.model or ""), tostring(value.log_path or ""),
							tostring(value.exit_path or ""), tostring(value.script_path or ""),
							tostring(value.repo or ""),
							tostring(value.pid or 0))
					end,
				},
				task = {},
				timer = {},
			}
			function hs_fixture.timer.new(delay, timer_callback)
				local behavior = timer_behavior(delay)
				if behavior.construct == "throw" then error("injected timer constructor failure") end
				if behavior.construct == "false" then return false end
				if behavior.construct == "nil" then return nil end
				local record = {delay = delay, callback = timer_callback, live = false,
					behavior = behavior}
				local handle = {}
				function handle:start()
					if self == nil then return false end
					if behavior.start == "throw_after_start" then
						record.live = true
						error("injected timer start failure after activation")
					end
					local result = result_value(behavior.start, self)
					if result ~= false and result ~= nil then record.live = true end
					if behavior.pause_on_start == true then
						records.reentrant_timer_pause =
							controls.requirement_pause_join()
					end
					if behavior.pause_reattach_on_start == true then
						records.reentrant_reattach_pause =
							controls.pause_reattached_download()
					end
					if behavior.fire_on_start then timer_callback() end
					return result
				end
				function handle:stop()
					if behavior.fire_on_stop then timer_callback() end
					local result = result_value(behavior.stop, self)
					if result ~= false and result ~= nil then record.live = false end
					return result
				end
				function handle:running()
					local reenter = behavior.reenter_on_running
					if type(reenter) == "function" then
						behavior.reenter_on_running = nil
						records.timer_running_reentry_result = reenter()
					end
					return record.live
				end
				record.handle = handle
				records.timers[#records.timers + 1] = record
				return handle
			end
			function hs_fixture.timer.doAfter(delay, timer_callback)
				local handle = hs_fixture.timer.new(delay, timer_callback)
				if handle and handle ~= false then handle:start() end
				return handle
			end

			function hs_fixture.task.new(path, on_done, on_stream, _args)
				local kind = path == "/usr/bin/tail" and "tail" or "launcher"
				local behavior = task_behavior(kind)
				if behavior.construct == "throw" then error("injected constructor failure") end
				if behavior.construct == "false" then return false end
				if behavior.construct == "nil" then return nil end
				local task = {kind = kind, done = on_done, stream = on_stream,
					behavior = behavior, running_state = false}
				function task:start()
					local start_mode = self.behavior.start
					local start_throws = start_mode == "throw"
						or start_mode == "throw_after_start"
					local start_result
					if start_throws ~= true then
						start_result = result_value(start_mode, self)
					end
					if self.behavior.running_after_start ~= nil then
						self.running_state = self.behavior.running_after_start == true
					elseif self.behavior.mutate_on_start == true
						or start_mode == "throw_after_start"
						or (start_result ~= false and start_result ~= nil) then
						self.running_state = true
					end
					if self.behavior.pause_on_start then
						reenter_pause(self.behavior.pause_on_start,
							"reentrant_" .. self.kind .. "_start_pause")
					end
					if self.behavior.stream_on_start
						and self.behavior.stream_after_complete_on_start ~= true then
						self.stream(self, self.behavior.stream_on_start, "")
					end
					if self.behavior.complete_on_start then
						self.running_state = false
						self.done(self.behavior.complete_code or 0, "", "")
					end
					if self.behavior.stream_on_start
						and self.behavior.stream_after_complete_on_start == true then
						self.stream(self, self.behavior.stream_on_start, "")
					end
					if self.kind == "tail"
						and self.behavior.pause_after_complete_on_start == true then
							records.reentrant_requirement_pause =
								controls.requirement_pause_join()
					end
					if self.kind == "tail"
						and self.behavior.pause_reattach_on_start == true then
						records.reentrant_reattach_tail_pause =
							controls.pause_reattached_download()
					end
					if start_throws then error("injected native refusal after activation") end
					return start_result
				end
				function task:terminate()
					if self.behavior.complete_on_terminate then
						self.running_state = false
						self.done(self.behavior.terminate_code or 15, "", "")
					end
					if self.behavior.terminate_stops == true then
						self.running_state = false
					end
					if self.behavior.pause_after_terminate then
						local pause_kind = self.behavior.pause_after_terminate
						self.behavior.pause_after_terminate = nil
						reenter_pause(pause_kind,
							"reentrant_" .. self.kind .. "_termination_pause")
					end
					return result_value(self.behavior.terminate, self)
				end
				function task:complete(code)
					self.running_state = false
					return self.done(code or 0, "", "")
				end
				function task:isRunning()
					local probe_mode = self.behavior.running_probe
					if type(probe_mode) == "table" then
						probe_mode = table.remove(probe_mode, 1)
					end
					return result_value(probe_mode, self.running_state)
				end
				function task:emit(text)
					return self.stream(self, text, "")
				end
				if behavior.pause_on_construct then
					reenter_pause(behavior.pause_on_construct,
						"reentrant_" .. kind .. "_construction_pause")
				end
				controls.tasks[kind][#controls.tasks[kind] + 1] = task
				return helpers.attach_native_task_environment(task)
			end

			_G.hs = hs_fixture
			package.loaded["hs"] = hs_fixture
			local logger_stub = helpers.make_logger_stub()
			local base_logger_callback = logger_stub.callback
			logger_stub.callback = function(log_name, label, fn, ...)
				records.callback_labels[#records.callback_labels + 1] = label
				local pause_label = plan.pause_on_logger_callback
					or plan.pause_on_update_icon
				if pause_label == label then
					local pause_kind = plan.logger_pause_kind
						or plan.update_icon_pause_kind or "requirement"
					local record_key = plan.logger_pause_record
						or "reentrant_update_icon_pause"
					plan.pause_on_logger_callback = nil
					plan.pause_on_update_icon = nil
					local args = table.pack(...)
					return base_logger_callback(log_name, label, function()
						local results = table.pack(fn(table.unpack(args, 1, args.n)))
						reenter_pause(pause_kind, record_key)
						return table.unpack(results, 1, results.n)
					end)
				end
				return base_logger_callback(log_name, label, fn, ...)
			end
			package.loaded["infra.logger"] = logger_stub
			package.loaded["infra.i18n"] = {
				get = function(key) return key end,
				format = function(key, value) return key .. ":" .. tostring(value) end,
			}
			package.loaded["infra.dialog_util"] = {
				block_alert = function() return "button.cancel" end,
			}
			package.loaded["infra.notifications"] = {
				notify = function(...)
					records.notifications[#records.notifications + 1] = table.pack(...)
					return true
				end,
			}
			package.loaded["ui.download_window"] = {
				session_id = function() return controls.window_session or 0 end,
				is_active = function() return controls.window ~= nil end,
				show = function(options)
					controls.window_session = (controls.window_session or 0) + 1
					controls.window = options
					return true
				end,
				update = function(...)
					records.updates[#records.updates + 1] = table.pack(...)
					if plan.pause_on_window_update then
						local kind = plan.pause_on_window_update
						plan.pause_on_window_update = nil
						reenter_pause(kind, "reentrant_window_update_pause")
					end
					return true
				end,
				complete = function(...)
					records.completions[#records.completions + 1] = table.pack(...)
					return true
				end,
			}
			if plan.real_window then
				_G.hs.timer.secondsSinceEpoch = function() return 100 end
				package.loaded["infra.paths"] = { shared = function()
					return helpers.driver_root() .. "../_shared"
				end }
				package.loaded["infra.deferred_work"] = { after = function() return true end }
				package.loaded["ui.ui_builder"] = {
					get_app_geometry = function() return { width = 460, height = 380 } end,
					show_webview = function(options)
						local native = { options = options }
						function native:evaluateJavaScript() return self end
						function native:delete() end
						controls.native_window = native
						options.on_webview_created(native)
						return native
					end,
				}
				_G.hs.webview = { usercontent = { new = function()
					return { setCallback = function() end }
				end } }
				_G.hs.screen = { mainScreen = function()
					return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
				end }
				_G.hs.drawing = { windowLevels = { floating = 1 } }
				package.loaded["ui.download_window.javascript"] = nil
				package.loaded["ui.download_window"] = nil
				controls.real_window = require("ui.download_window")
			end
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_num_predictions = 1},
				set_active_profile = function() return true end,
			}
			package.loaded["ui.menu.menu_llm.profile_label"] = {
				format = function(label) return label end,
			}

			local state = {
				llm_active_profile = "basic",
				llm_backend = "mlx",
				llm_enabled = true,
				llm_model = "A",
				llm_model_mlx = "A",
				llm_model_power = 1,
			}
			local deps = {
				active_tasks = {},
				state = state,
				keymap = {
					set_llm_model = function(model)
						records.runtime_model = model
						return true
					end,
					set_llm_display_model_name = function(model)
						records.display_model = model
						return true
					end,
					set_llm_enabled = function(enabled)
						records.gates[#records.gates + 1] = enabled
						return true
					end,
				},
				mark_download_aborted = function()
					records.download_aborts = records.download_aborts + 1
					return true
				end,
				clear_download_abort = function()
					records.download_retry_starts = records.download_retry_starts + 1
					return true
				end,
				update_icon = function() return true end,
				save_prefs = function()
					records.saves = records.saves + 1
					return result_value(plan.save_mode, true)
				end,
			}
			local obj = {}
			function obj.start_server(_, on_success, on_cancel)
				records.server_starts = records.server_starts + 1
				controls.server_success = on_success
				controls.server_cancel = on_cancel
				if plan.server_sync == "success" then on_success()
				elseif plan.server_sync == "failure" then on_cancel("server_failed") end
				return result_value(plan.server_mode, true)
			end
			local mixin = require("ui.menu.menu_llm.models_manager_mlx_download")
			mixin.install({
				obj = obj,
				deps = deps,
				presets = {},
				project_venv_python_escaped = "/fixture/python",
				invalidate_installed_cache = function()
					records.cache_invalidations = (records.cache_invalidations or 0) + 1
					return true
				end,
			})
			function obj.check_requirements(model, on_success, on_cancel, options)
				return obj.pull_model(model, "org/model", function(...)
					records.requirement_successes = records.requirement_successes + 1
					return on_success(...)
				end, function(reason, ...)
					records.requirement_failures[#records.requirement_failures + 1] = reason
					return on_cancel(reason, ...)
				end, options)
			end
			function obj.get_actual_model_name(model) return model end
			function obj.get_model_info() return {params = 1} end
			function obj.get_presets() return {} end

			local switcher
			if plan.real_switcher then
				package.loaded["ui.menu.menu_llm.model_switcher"] = nil
				switcher = require("ui.menu.menu_llm.model_switcher").new({
					state = state,
					models_mgr = obj,
					keymap = deps.keymap,
					save_prefs = deps.save_prefs,
					update_menu = function()
						records.menus = (records.menus or 0) + 1
						return true
					end,
				})
			end

			function controls.latest(kind)
				local tasks = controls.tasks[kind]
				return tasks[#tasks]
			end
			function controls.fire(delay)
				for _, timer in ipairs(records.timers) do
					if timer.live and (delay == nil or timer.delay == delay) then
						return timer.callback()
					end
				end
				return false
			end
			function controls.pull(model)
				local options = {is_current = function() return true end}
				if plan.requirement_lifecycle == true then
					options._requirement_lifecycle = {
						adopt = function(child, pause_join)
							controls.requirement_child = child
							controls.requirement_pause_join = pause_join
							return true
						end,
						settle = function(child)
							helpers.assert_eq(child, controls.requirement_child)
							records.requirement_settlements =
								(records.requirement_settlements or 0) + 1
							return true
						end,
					}
				end
				return obj.pull_model(model or "B", "org/model", function()
					if plan.pause_in_terminal == "success" then
						plan.pause_in_terminal = nil
						records.reentrant_server_terminal_pause =
							controls.requirement_pause_join()
						records.server_terminal_mutations =
							(records.server_terminal_mutations or 0) + 1
					end
					records.successes = records.successes + 1
					return true
				end, function(reason)
					if plan.pause_in_terminal == "failure" then
						plan.pause_in_terminal = nil
						records.reentrant_server_terminal_pause =
							controls.requirement_pause_join()
						records.server_terminal_mutations =
							(records.server_terminal_mutations or 0) + 1
					end
					records.cancels[#records.cancels + 1] = reason
					return true
				end, options)
			end
			function controls.reattach(repo)
				repo = repo or "org/model"
				local session = {
					model = "B",
					log_path = "/tmp/hs_mlx_dl_reattach.log",
					exit_path = "/tmp/hs_mlx_dl_reattach.log.exit",
					script_path = "/tmp/hs_mlx_dl_reattach.py",
					pid = 4242,
					repo = repo,
				}
				controls.files["/tmp/hs_mlx_active_download.json"] =
					'{"model":"B","log_path":"/tmp/hs_mlx_dl_reattach.log",'
					.. '"exit_path":"/tmp/hs_mlx_dl_reattach.log.exit",'
					.. '"script_path":"/tmp/hs_mlx_dl_reattach.py",'
					.. '"repo":"' .. repo .. '","pid":4242}'
				return obj.reattach_download(session)
			end
			function controls.pause_reattached_download()
				return obj.pause_reattached_download()
			end
			function controls.finish_download(code)
				controls.exit_code = code
				local tail = controls.latest("tail")
				helpers.assert_type(tail, "table", "the tail stage must exist")
				tail:complete(0)
				return controls.fire(0.5)
			end

			callback({
				controls = controls,
				deps = deps,
				obj = obj,
				records = records,
				state = state,
				switcher = switcher,
			})
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	io.open = saved_open
	os.execute = saved_execute
	os.remove = saved_remove
	os.rename = saved_rename
	if not outcome[1] then error(outcome[2]) end
end

local function assert_cancelled(fixture, reason)
	helpers.assert_eq(fixture.records.successes, 0)
	helpers.assert_eq(#fixture.records.cancels, 1)
	if reason ~= nil then helpers.assert_eq(fixture.records.cancels[1], reason) end
	helpers.assert_eq(fixture.state.llm_model, "A")
	helpers.assert_nil(fixture.records.runtime_model)
end

local function launch_detached_download(fixture)
	local launcher = fixture.controls.latest("launcher")
	helpers.assert_type(launcher, "table", "the detached launcher must be owned")
	launcher:emit("__DLPID__:4242\n")
	launcher:complete(0)
	return launcher
end

return {
	with_fixture = with_fixture,
	assert_cancelled = assert_cancelled,
	launch_detached_download = launch_detached_download,
}
