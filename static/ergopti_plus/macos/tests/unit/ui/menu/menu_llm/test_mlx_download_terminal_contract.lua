--- tests/unit/ui/menu/menu_llm/test_mlx_download_terminal_contract.lua

--- Regression coverage for the stage-independent MLX download owner.

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"modules.llm",
	"ui.download_window",
	"ui.menu.menu_llm.model_switcher",
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

local function find_function_upvalue(fn, target, seen)
	if type(fn) ~= "function" then return nil end
	seen = seen or {}
	if seen[fn] then return nil end
	seen[fn] = true
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == target and type(value) == "function" then return value end
		if type(value) == "function" then
			local nested = find_function_upvalue(value, target, seen)
			if nested ~= nil then return nested end
		end
	end
	return nil
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
				show = function(options)
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

local function assert_switcher_failure(fixture, reason)
	helpers.assert_eq(fixture.records.gates, {false, true},
		"the real switcher must reopen predictions exactly once")
	helpers.assert_eq(fixture.records.requirement_successes, 0)
	helpers.assert_eq(#fixture.records.requirement_failures, 1)
	if reason ~= nil then
		helpers.assert_eq(fixture.records.requirement_failures[1], reason)
	end
	helpers.assert_eq(fixture.state.llm_model, "A")
	helpers.assert_eq(fixture.state.llm_model_mlx, "A")
	helpers.assert_eq(fixture.records.menus or 0, 0)
end

local function launch_detached_download(fixture)
	local launcher = fixture.controls.latest("launcher")
	helpers.assert_type(launcher, "table", "the detached launcher must be owned")
	launcher:emit("__DLPID__:4242\n")
	launcher:complete(0)
	return launcher
end

helpers.describe("HS-012 MLX timer replacement ownership", function()
	helpers.it("preserves a same-slot successor installed during native settlement", function()
		local poll_behavior = {}
		with_fixture({
			requirement_lifecycle = true,
			timer_by_delay = { [3] = poll_behavior },
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local owner = fixture.controls.requirement_child
			helpers.assert_type(owner, "table")
			local schedule_owner_timer = find_function_upvalue(
				fixture.obj.pull_model, "schedule_owner_timer")
			helpers.assert_type(schedule_owner_timer, "function")
			local predecessor = owner.timers.poll
			helpers.assert_type(predecessor, "table")
			local before = #fixture.records.timers

			poll_behavior.reenter_on_running = function()
				return schedule_owner_timer(owner, "poll", 3, function() return true end)
			end
			helpers.assert_eq(
				schedule_owner_timer(owner, "poll", 3, function() return true end), false,
				"the stale outer replacement must refuse its nested successor")
			helpers.assert_true(fixture.records.timer_running_reentry_result)
			helpers.assert_eq(#fixture.records.timers, before + 1,
				"the outer replacement must not publish a second successor")
			helpers.assert_true(owner.timers.poll ~= predecessor)
			helpers.assert_eq(fixture.records.timers[before + 1].live, true)
		end)
	end)
end)

local function assert_revoked_cleanup_timer_owned(fixture)
	local cleanup
	for _, timer in ipairs(fixture.records.timers) do
		if timer.delay == 0.25 and timer.live == true then cleanup = timer end
	end
	helpers.assert_not_nil(cleanup,
		"revocation must retain one live cleanup timer for the exact PID owner")
	for _, timer in ipairs(fixture.records.timers) do
		if timer.live == true then
			helpers.assert_true(timer.delay ~= 3 and timer.delay ~= 30,
				"revocation must not authorize poll/timeout business successors")
		end
	end
end

helpers.describe("HS-024 MLX download terminal owner", function()
	helpers.it("HS-024 rejects a busy slot through one failure terminal", function()
		with_fixture({}, function(fixture)
			fixture.deps.active_tasks.download = {marker = "existing"}
			helpers.assert_eq(fixture.controls.pull(), false)
			assert_cancelled(fixture, "busy")
		end)
	end)

	helpers.it("HS-024 user cancellation revokes late launcher success", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			helpers.assert_type(fixture.controls.window.on_cancel, "function")
			fixture.controls.window.on_cancel()
			assert_cancelled(fixture, "user_cancelled")

			launcher:complete(0)
			fixture.controls.fire(0.25)
			helpers.assert_eq(fixture.records.server_starts, 0)
			helpers.assert_eq(#fixture.records.cancels, 1)
		end)
	end)

	for _, failure in ipairs({
		{name = "python open", plan = {fail_open = "python"}, reason = "python_file_open_failed"},
		{name = "launcher open", plan = {fail_open = "launcher"}, reason = "launcher_file_open_failed"},
		{name = "launcher constructor false", plan = {launcher = {construct = "false"}}, reason = "launcher_construction_failed"},
		{name = "launcher constructor nil", plan = {launcher = {construct = "nil"}}, reason = "launcher_construction_failed"},
		{name = "launcher constructor throw", plan = {launcher = {construct = "throw"}}, reason = "launcher_construction_failed"},
		{name = "launcher start false", plan = {launcher = {start = "false"}}, reason = "launcher_start_refused"},
		{name = "launcher start nil", plan = {launcher = {start = "nil"}}, reason = "launcher_start_refused"},
		{name = "launcher start throw", plan = {launcher = {start = "throw"}}, reason = "launcher_start_refused"},
		{name = "sync completion then refused start", plan = {launcher = {
			stream_on_start = "__DLPID__:4242\n", complete_on_start = true,
			complete_code = 0, start = "false",
		}}, reason = "launcher_start_refused"},
	}) do
		helpers.it("HS-024 settles " .. failure.name .. " exactly once", function()
			with_fixture(failure.plan, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), false)
				assert_cancelled(fixture, failure.reason)
				local launcher = fixture.controls.latest("launcher")
				if launcher then launcher:complete(0) end
				helpers.assert_eq(#fixture.records.cancels, 1)
				helpers.assert_eq(fixture.records.server_starts, 0)
			end)
		end)
	end

	helpers.it("HS-024 launcher process failure settles once", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			fixture.controls.latest("launcher"):complete(1)
			assert_cancelled(fixture, "launcher_failed")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 tail " .. mode .. " refusal retains the same cleanup owner", function()
			local plan = {tail = {
				start = mode,
				stream_on_start = "__BYTES__:99\n",
				mutate_on_start = true,
			}, pid_alive = true}
			with_fixture(plan, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), true)
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				local stale_tail = fixture.controls.latest("tail")
				assert_cancelled(fixture, "tail_task_start_refused")
				helpers.assert_eq(#fixture.records.updates, 0,
					"a refused tail cannot publish its synchronous stream")
				local session_path = "/tmp/hs_mlx_active_download.json"
				local retained_session = fixture.controls.files[session_path]
				helpers.assert_type(retained_session, "string")
				helpers.assert_eq(retained_session:find('"model":"B"', 1, true) ~= nil, true)
				helpers.assert_eq(retained_session:find('"repo":"org/model"', 1, true) ~= nil, true)

				local second_cancels = 0
				local accepted = fixture.obj.pull_model("C", "org/other", nil, function(reason)
					second_cancels = second_cancels + 1
					helpers.assert_eq(reason, "busy")
				end, {is_current = function() return true end})
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(second_cancels, 1)
				helpers.assert_eq(fixture.controls.files[session_path], retained_session,
					"a busy successor cannot replace the live owner's session")

				plan.pid_alive = false
				assert_revoked_cleanup_timer_owned(fixture)
				fixture.controls.fire(0.25)
				helpers.assert_nil(fixture.controls.files[session_path])
				local tail_count = #fixture.controls.tasks.tail
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function(reason)
					second_cancels = second_cancels + 1
					helpers.assert_eq(reason, "busy")
				end, {is_current = function() return true end}), false,
					"a vanished PID cannot settle the still-live refused tail task")
				helpers.assert_eq(second_cancels, 2)
				helpers.assert_eq(#fixture.controls.tasks.tail, tail_count,
					"the refused tail must block every sibling until its exact terminal")

				stale_tail:complete(0)
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
					{is_current = function() return true end}), true)
				local successor_session = fixture.controls.files[session_path]
				helpers.assert_type(successor_session, "string")
				helpers.assert_eq(successor_session:find('"model":"C"', 1, true) ~= nil, true)
				helpers.assert_eq(successor_session:find('"repo":"org/other"', 1, true) ~= nil, true)

				stale_tail:emit("__BYTES__:100\n")
				helpers.assert_eq(#fixture.records.updates, 0,
					"late refused-tail chunks must remain inert")
				helpers.assert_eq(fixture.controls.files[session_path], successor_session,
					"a late callback cannot remove the successor's exact session")
				helpers.assert_eq(#fixture.records.cancels, 1)
				helpers.assert_eq(fixture.records.successes, 0)
				helpers.assert_eq(fixture.records.server_starts, 0)
			end)
		end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 launcher " .. mode
			.. " refusal discards synchronous business stream", function()
			with_fixture({launcher = {
				start = mode,
				stream_on_start = "launcher business\n",
				mutate_on_start = true,
			}}, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), false)
				helpers.assert_eq(#fixture.records.updates, 0)
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("late launcher business\n")
				helpers.assert_eq(#fixture.records.updates, 0)
			end)
		end)
	end

	helpers.it("HS-024 replays committed launcher and tail streams once", function()
		with_fixture({
			launcher = {stream_on_start = "launcher business\n"},
			tail = {stream_on_start = "__BYTES__:99\n"},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			helpers.assert_eq(#fixture.records.updates, 1)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			helpers.assert_eq(#fixture.records.updates, 2)
			launcher:emit("late launcher business\n")
			helpers.assert_eq(#fixture.records.updates, 2)
			local tail = fixture.controls.latest("tail")
			tail:complete(0)
			tail:emit("__BYTES__:100\n")
			helpers.assert_eq(#fixture.records.updates, 2)
		end)
	end)

	helpers.it("HS-024 drops a synchronous stream delivered after terminal", function()
		with_fixture({launcher = {
			start = "success",
			complete_on_start = true,
			complete_code = 1,
			stream_on_start = "post-terminal business\n",
			stream_after_complete_on_start = true,
		}}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			helpers.assert_eq(#fixture.records.updates, 0)
		end)
	end)

	helpers.it("HS-024 tail construction refusal retains the detached owner", function()
		local plan = {tail = {construct = "nil"}, pid_alive = true}
		with_fixture(plan, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			assert_cancelled(fixture, "tail_task_construction_failed")
			local session_path = "/tmp/hs_mlx_active_download.json"
			local retained_session = fixture.controls.files[session_path]
			helpers.assert_type(retained_session, "string")
			helpers.assert_eq(retained_session:find('"model":"B"', 1, true) ~= nil, true)
			helpers.assert_eq(retained_session:find('"repo":"org/model"', 1, true) ~= nil, true)

			local second_cancels = 0
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function(reason)
				second_cancels = second_cancels + 1
				helpers.assert_eq(reason, "busy")
			end, {is_current = function() return true end}), false)
			helpers.assert_eq(second_cancels, 1)
			helpers.assert_eq(fixture.controls.files[session_path], retained_session,
				"a busy successor cannot replace the live owner's session")

			plan.pid_alive = false
			assert_revoked_cleanup_timer_owned(fixture)
			fixture.controls.fire(0.25)
			helpers.assert_nil(fixture.controls.files[session_path])
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), true)
			local successor_session = fixture.controls.files[session_path]
			helpers.assert_type(successor_session, "string")
			helpers.assert_eq(successor_session:find('"model":"C"', 1, true) ~= nil, true)
			helpers.assert_eq(successor_session:find('"repo":"org/other"', 1, true) ~= nil, true)

			launcher:complete(0)
			helpers.assert_eq(fixture.controls.files[session_path], successor_session,
				"a late callback cannot remove the successor's exact session")
			helpers.assert_eq(#fixture.records.cancels, 1)
			helpers.assert_eq(fixture.records.successes, 0)
			helpers.assert_eq(fixture.records.server_starts, 0)
		end)
	end)

	helpers.it("HS-024 failed detached download has one terminal", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			fixture.controls.finish_download(1)
			assert_cancelled(fixture, "process_failed")
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_eq(#fixture.records.cancels, 1)
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 server dispatch " .. mode .. " refusal cannot publish", function()
			with_fixture({server_mode = mode}, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), true)
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				fixture.controls.finish_download(0)
				assert_cancelled(fixture, "server_start_refused")
				helpers.assert_eq(fixture.records.saves, 0)
			end)
		end)
	end

	helpers.it("HS-024 buffers synchronous server success until dispatch commits", function()
		with_fixture({server_mode = "false", server_sync = "success"}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			fixture.controls.finish_download(0)
			assert_cancelled(fixture, "server_start_refused")
		end)
	end)

	helpers.it("HS-024 success and duplicate callbacks settle once without child publication", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), true)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			fixture.controls.finish_download(0)
			helpers.assert_eq(fixture.records.successes, 0)
			fixture.controls.server_success()
			fixture.controls.server_cancel("late")
			fixture.controls.server_success()
			helpers.assert_eq(fixture.records.successes, 1)
			helpers.assert_eq(#fixture.records.cancels, 0)
			helpers.assert_eq(fixture.state.llm_model, "A")
			helpers.assert_nil(fixture.records.runtime_model)
			helpers.assert_eq(fixture.records.saves, 0)
		end)
	end)

	helpers.it("HS-024 releases the real switcher gate when the logical slot is busy", function()
		with_fixture({real_switcher = true}, function(fixture)
			fixture.deps.active_tasks.download = {marker = "existing"}
			helpers.assert_eq(fixture.switcher.switch_model("B"), false)
			assert_switcher_failure(fixture, "busy")
		end)
	end)

	for _, failure in ipairs({
		{name = "python open", plan = {fail_open = "python"}, reason = "python_file_open_failed"},
		{name = "launcher open", plan = {fail_open = "launcher"}, reason = "launcher_file_open_failed"},
		{name = "launcher construction", plan = {launcher = {construct = "nil"}}, reason = "launcher_construction_failed"},
		{name = "launcher start", plan = {launcher = {start = "false"}}, reason = "launcher_start_refused"},
	}) do
		helpers.it("HS-024 routes " .. failure.name .. " through the real switcher", function()
			failure.plan.real_switcher = true
			with_fixture(failure.plan, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), false)
				assert_switcher_failure(fixture, failure.reason)
			end)
		end)
	end

	helpers.it("HS-024 routes user cancellation through the real switcher once", function()
		with_fixture({real_switcher = true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			launch_detached_download(fixture)
			fixture.controls.window.on_cancel()
			assert_switcher_failure(fixture, "user_cancelled")
			fixture.controls.latest("launcher"):complete(0)
			helpers.assert_eq(#fixture.records.requirement_failures, 1)
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 routes tail start " .. mode .. " through the real switcher", function()
			with_fixture({real_switcher = true, tail = {start = mode}}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "tail_task_start_refused")
			end)
		end)
	end

	helpers.it("HS-024 routes launcher and detached process exits through the real switcher", function()
		with_fixture({real_switcher = true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			fixture.controls.latest("launcher"):complete(1)
			assert_switcher_failure(fixture, "launcher_failed")
		end)
		with_fixture({real_switcher = true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			launch_detached_download(fixture)
			fixture.controls.finish_download(1)
			assert_switcher_failure(fixture, "process_failed")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 routes server start " .. mode .. " through the real switcher", function()
			with_fixture({real_switcher = true, server_mode = mode}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				fixture.controls.finish_download(0)
				assert_switcher_failure(fixture, "server_start_refused")
			end)
		end)
	end

	helpers.it("HS-024 leaves identity publication to the real parent transaction", function()
		with_fixture({real_switcher = true, save_mode = "false"}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			launch_detached_download(fixture)
			fixture.controls.finish_download(0)
			helpers.assert_eq(fixture.records.gates, {false})
			fixture.controls.server_success()
			fixture.controls.server_success()
			helpers.assert_eq(fixture.records.gates, {false, true})
			helpers.assert_eq(fixture.records.requirement_successes, 1)
			helpers.assert_eq(#fixture.records.requirement_failures, 0)
			helpers.assert_eq(fixture.state.llm_model, "A")
			helpers.assert_eq(fixture.state.llm_model_mlx, "A")
			helpers.assert_eq(fixture.records.runtime_model, "A")
			helpers.assert_eq(fixture.records.saves, 2,
				"the parent must attempt candidate persistence and exact rollback")
		end)
	end)

	for _, boundary in ipairs({
		{kind = "python", field = "write_modes", reason = "python_file_write_failed"},
		{kind = "python", field = "close_modes", reason = "python_file_write_failed"},
		{kind = "launcher", field = "write_modes", reason = "launcher_file_write_failed"},
		{kind = "launcher", field = "close_modes", reason = "launcher_file_write_failed"},
		{kind = "session", field = "write_modes", reason = "session_write_failed"},
		{kind = "session", field = "close_modes", reason = "session_write_failed"},
	}) do
		for _, mode in ipairs({"false", "nil", "throw"}) do
			helpers.it(string.format("HS-024 settles %s %s refusal through the real switcher",
				boundary.kind, mode), function()
				local plan = {real_switcher = true}
				plan[boundary.field] = {[boundary.kind] = mode}
				with_fixture(plan, function(fixture)
					helpers.assert_eq(fixture.switcher.switch_model("B"), false)
					assert_switcher_failure(fixture, boundary.reason)
				end)
			end)
		end
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 settles atomic session publication " .. mode .. " refusal", function()
			with_fixture({real_switcher = true, rename_mode = mode}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), false)
				assert_switcher_failure(fixture, "session_write_failed")
			end)
		end)

		helpers.it("HS-024 settles launcher chmod " .. mode .. " refusal", function()
			with_fixture({real_switcher = true, chmod_mode = mode}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), false)
				assert_switcher_failure(fixture, "launcher_chmod_failed")
			end)
		end)
	end

	for _, boundary in ipairs({"write", "close", "rename"}) do
		for _, mode in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-024 retains detached cleanup after session PID "
				.. boundary .. " " .. mode .. " refusal", function()
				local plan = {real_switcher = true, pid_alive = true}
				if boundary == "rename" then
					plan.rename_sequence = {"success", mode}
				else
					plan[boundary .. "_modes"] = {session = {"success", mode}}
				end
				with_fixture(plan, function(fixture)
					helpers.assert_eq(fixture.switcher.switch_model("B"), true)
					fixture.controls.latest("launcher"):emit("__DLPID__:4242\n")
					assert_switcher_failure(fixture, "session_pid_write_failed")
					local second_cancels = 0
					helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function()
						second_cancels = second_cancels + 1
					end, {is_current = function() return true end}), false)
					helpers.assert_eq(second_cancels, 1)
				end)
			end)
		end
	end

	for _, behavior in ipairs({
		{construct = "false"}, {construct = "nil"}, {construct = "throw"},
		{start = "false"}, {start = "nil"}, {start = "throw"},
		{start = "throw_after_start"}, {fire_on_start = true},
	}) do
		helpers.it("HS-024 settles refused critical timer acquisition", function()
			with_fixture({real_switcher = true, timer_sequence = {behavior}}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "poll_timer_refused")
			end)
		end)
	end

	helpers.it("HS-024 settles timeout timer acquisition after the poll commits", function()
		with_fixture({real_switcher = true, timer_sequence = {{}, {construct = "nil"}}},
			function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "timeout_timer_refused")
			end)
	end)

	helpers.it("HS-024 settles a refused poll reschedule", function()
		with_fixture({real_switcher = true,
			timer_sequence = {{}, {}, {construct = "nil"}}}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			launch_detached_download(fixture)
			fixture.controls.fire(3)
			assert_switcher_failure(fixture, "poll_timer_refused")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 discovers a late PID after launcher cancellation " .. mode, function()
			local plan = {real_switcher = true, launcher = {terminate = mode},
				kill_mode = mode, pid_alive = true}
			with_fixture(plan, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				local launcher = fixture.controls.latest("launcher")
				fixture.controls.window.on_cancel()
				assert_switcher_failure(fixture, "user_cancelled")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				local second_cancels = 0
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function()
					second_cancels = second_cancels + 1
				end, {is_current = function() return true end}), false)
				helpers.assert_eq(second_cancels, 1)
				plan.pid_alive = false
				fixture.controls.fire(0.25)
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
					{is_current = function() return true end}), true)
				helpers.assert_eq(fixture.records.server_starts, 0)
			end)
		end)
	end

	helpers.it("HS-024 keeps one logical terminal across double Retry", function()
		with_fixture({real_switcher = true,
			launcher = {{complete_on_terminate = true}, {}}}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			local old_launcher = fixture.controls.latest("launcher")
			helpers.assert_eq(fixture.controls.window.on_retry(), true)
			helpers.assert_eq(fixture.controls.window.on_retry(), false)
			helpers.assert_eq(fixture.records.gates, {false})
			helpers.assert_eq(#fixture.records.requirement_failures, 0)
			fixture.controls.fire(0.05)
			helpers.assert_eq(#fixture.controls.tasks.launcher, 2)
			old_launcher:complete(0)
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4343\n")
			launcher:complete(0)
			fixture.controls.finish_download(0)
			fixture.controls.server_success()
			helpers.assert_eq(fixture.records.gates, {false, true})
			helpers.assert_eq(fixture.records.requirement_successes, 1)
			helpers.assert_eq(#fixture.records.requirement_failures, 0)
			helpers.assert_eq(fixture.state.llm_model, "B")
		end)
	end)

	helpers.it("HS-024 lets Cancel revoke a pending Retry handoff", function()
		with_fixture({real_switcher = true,
			launcher = {complete_on_terminate = true}}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			helpers.assert_eq(fixture.controls.window.on_retry(), true)
			fixture.controls.window.on_cancel()
			assert_switcher_failure(fixture, "user_cancelled")
			fixture.controls.fire(0.05)
			helpers.assert_eq(#fixture.controls.tasks.launcher, 1)
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 fences late tail success after cancellation " .. mode, function()
			local plan = {real_switcher = true, tail = {terminate = mode},
				pid_alive = false}
			with_fixture(plan, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				local tail = fixture.controls.latest("tail")
				fixture.controls.window.on_cancel()
				assert_switcher_failure(fixture, "user_cancelled")
				fixture.controls.exit_code = 0
				tail:complete(0)
				fixture.controls.fire(0.5)
				fixture.controls.fire(0.25)
				helpers.assert_eq(fixture.records.server_starts, 0)
				helpers.assert_eq(fixture.records.requirement_successes, 0)
				helpers.assert_eq(#fixture.records.requirement_failures, 1)
			end)
		end)
	end

	for _, mode in ipairs({"false", "nil"}) do
		helpers.it("HS-024 latches synchronous tail completion before " .. mode .. " start", function()
			with_fixture({real_switcher = true, tail = {
				complete_on_start = true, start = mode,
			}}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "tail_task_start_refused")
			end)
		end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 retains launcher construction debt after PAUSE " .. mode,
			function()
				with_fixture({
					requirement_lifecycle = true,
					launcher = {
						pause_on_construct = "requirement",
						terminate = mode,
					},
				}, function(fixture)
					helpers.assert_eq(fixture.controls.pull(), false)
					helpers.assert_eq(
						fixture.records.reentrant_launcher_construction_pause, false,
						"PAUSE cannot publish while launcher construction is on-stack")
					assert_cancelled(fixture, "script_paused")
					local exact_launcher = fixture.controls.latest("launcher")
					helpers.assert_type(exact_launcher, "table")
					helpers.assert_nil(fixture.deps.active_tasks.download,
						"an exact stopped proof settles a candidate that never started")
					helpers.assert_eq(fixture.records.requirement_settlements, 1)
					helpers.assert_eq(exact_launcher:complete(0), false,
						"late completion from the settled candidate must stay inert")
					helpers.assert_eq(fixture.records.requirement_settlements, 1)
				end)
			end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 revalidates launcher rollback after PAUSE " .. mode,
			function()
				with_fixture({
					requirement_lifecycle = true,
					launcher = {
						start = "false",
						mutate_on_start = true,
						pause_after_terminate = "requirement",
						terminate = mode,
					},
				}, function(fixture)
					helpers.assert_eq(fixture.controls.pull(), false)
					helpers.assert_eq(
						fixture.records.reentrant_launcher_termination_pause, false,
						"PAUSE cannot publish during exact launcher rollback")
					local refusal_icons = 0
					for _, label in ipairs(fixture.records.callback_labels) do
						if label == "MLX launcher-refusal icon reset" then
							refusal_icons = refusal_icons + 1
						end
					end
					helpers.assert_eq(refusal_icons, 0,
						"rollback PAUSE must fence failure UI")
					local exact_launcher = fixture.controls.latest("launcher")
					helpers.assert_eq(fixture.deps.active_tasks.download, exact_launcher)
					helpers.assert_eq(fixture.records.requirement_settlements or 0, 0)
					exact_launcher:complete(0)
					helpers.assert_eq(fixture.records.requirement_settlements, 1)
				end)
			end)
	end

	helpers.it("HS-012 rejects a truthy launcher start already proven stopped", function()
		with_fixture({launcher = {
			{running_after_start = false},
			{},
		}}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			assert_cancelled(fixture, "launcher_start_refused")
			helpers.assert_nil(fixture.deps.active_tasks.download)
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}))
		end)
	end)

	helpers.it("HS-012 rejects a truthy regular tail start already proven stopped", function()
		with_fixture({
			requirement_lifecycle = true,
			tail = {running_after_start = false},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			helpers.assert_eq(launcher:complete(0), false)
			assert_cancelled(fixture, "tail_task_start_refused")
			helpers.assert_nil(fixture.deps.active_tasks.download_tail)
			fixture.controls.fire(0.25)
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}))
		end)
	end)

	for _, probe_mode in ipairs({"nil", "throw", "non_boolean"}) do
		helpers.it("HS-012 fails closed on launcher liveness probe " .. probe_mode,
			function()
				with_fixture({launcher = {
					{
						running_probe = probe_mode,
						terminate = "false",
					},
					{},
				}}, function(fixture)
					helpers.assert_eq(fixture.controls.pull(), false)
					assert_cancelled(fixture, "launcher_start_refused")
					local exact_launcher = fixture.controls.latest("launcher")
					helpers.assert_eq(fixture.deps.active_tasks.download, exact_launcher,
						"an inconclusive liveness probe must retain the exact task")
					helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
						{is_current = function() return true end}), false)
					exact_launcher:complete(0)
					helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
						{is_current = function() return true end}))
				end)
			end)
	end

	helpers.it("HS-012 fails closed on regular tail non-boolean liveness", function()
		with_fixture({
			requirement_lifecycle = true,
			tail = {running_probe = "non_boolean", terminate = "false"},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			helpers.assert_eq(launcher:complete(0), false)
			assert_cancelled(fixture, "tail_task_start_refused")
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_eq(fixture.deps.active_tasks.download_tail, exact_tail)
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), false)
			exact_tail:complete(0)
			fixture.controls.fire(0.25)
			helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}))
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 consumes stopped proof after launcher terminate " .. mode,
			function()
				with_fixture({launcher = {
					terminate = mode,
					terminate_stops = true,
				}}, function(fixture)
					helpers.assert_true(fixture.controls.pull())
					helpers.assert_true(fixture.controls.window.on_cancel())
					helpers.assert_nil(fixture.deps.active_tasks.download)
					helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
						{is_current = function() return true end}))
				end)
			end)

		helpers.it("HS-012 consumes stopped proof after tail terminate " .. mode,
			function()
				with_fixture({
					requirement_lifecycle = true,
					tail = {terminate = mode, terminate_stops = true},
				}, function(fixture)
					helpers.assert_true(fixture.controls.pull())
					launch_detached_download(fixture)
					fixture.controls.requirement_child.partial.pid = nil
					helpers.assert_true(fixture.controls.window.on_cancel())
					helpers.assert_nil(fixture.deps.active_tasks.download_tail)
					helpers.assert_true(fixture.obj.pull_model("C", "org/other", nil, nil,
						{is_current = function() return true end}))
				end)
			end)
	end

	helpers.it("HS-012 fences launcher terminal UI after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_update_icon = "MLX launcher-failure icon reset",
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			helpers.assert_eq(launcher:complete(1), false)
			helpers.assert_eq(fixture.records.reentrant_update_icon_pause, false,
				"PAUSE cannot publish from inside the launcher terminal callback")
			assert_cancelled(fixture, "script_paused")
			helpers.assert_eq(#fixture.records.completions, 0,
				"a PAUSE-revoked terminal cannot update the download window")
			helpers.assert_eq(#fixture.records.notifications, 0,
				"a PAUSE-revoked terminal cannot notify after owner removal")
			helpers.assert_nil(fixture.controls.latest("tail"))
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	helpers.it("HS-012 fences buffered launcher terminal UI after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_update_icon = "MLX launcher-failure icon reset",
			launcher = {complete_on_start = true, complete_code = 1},
		}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			helpers.assert_eq(fixture.records.reentrant_update_icon_pause, false,
				"PAUSE cannot publish while buffered terminal work is replayed")
			assert_cancelled(fixture, "script_paused")
			helpers.assert_eq(#fixture.records.completions, 0)
			helpers.assert_eq(#fixture.records.notifications, 0)
			helpers.assert_nil(fixture.controls.latest("tail"))
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	helpers.it("HS-012 fences launcher stdout UI after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_window_update = "requirement",
			launcher = {complete_on_terminate = true},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			helpers.assert_eq(launcher:emit("launcher business\n"), false)
			helpers.assert_eq(fixture.records.reentrant_window_update_pause, false,
				"PAUSE cannot publish while launcher stdout is on-stack")
			assert_cancelled(fixture, "script_paused")
			local progress_icons = 0
			for _, label in ipairs(fixture.records.callback_labels) do
				if label == "MLX download progress icon" then
					progress_icons = progress_icons + 1
				end
			end
			helpers.assert_eq(progress_icons, 0,
				"the revoked stdout callback cannot publish its UI successor")
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	helpers.it("HS-012 fences buffered launcher stdout after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_window_update = "requirement",
			launcher = {
				stream_on_start = "launcher business\n",
				complete_on_terminate = true,
			},
		}, function(fixture)
			helpers.assert_eq(fixture.controls.pull(), false)
			helpers.assert_eq(fixture.records.reentrant_window_update_pause, false,
				"PAUSE cannot publish while buffered stdout is replayed")
			assert_cancelled(fixture, "script_paused")
			local progress_icons = 0
			for _, label in ipairs(fixture.records.callback_labels) do
				if label == "MLX download progress icon" then
					progress_icons = progress_icons + 1
				end
			end
			helpers.assert_eq(progress_icons, 0)
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	helpers.it("HS-012 fences tail stdout UI after nested PAUSE", function()
		with_fixture({
			requirement_lifecycle = true,
			pause_on_window_update = "requirement",
			pid_alive = false,
			tail = {complete_on_terminate = true},
		}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")
			fixture.controls.requirement_child.partial.pid = nil
			helpers.assert_eq(tail:emit("__BYTES__:99\n"), false)
			helpers.assert_eq(fixture.records.reentrant_window_update_pause, false,
				"PAUSE cannot publish while tail stdout is on-stack")
			assert_cancelled(fixture, "script_paused")
			local progress_icons = 0
			for _, label in ipairs(fixture.records.callback_labels) do
				if label == "MLX download progress icon" then
					progress_icons = progress_icons + 1
				end
			end
			helpers.assert_eq(progress_icons, 0,
				"the revoked tail callback cannot publish its UI successor")
		end)
	end)

	helpers.it("HS-012 fences tail terminal successor after nested PAUSE", function()
		local plan = {
			requirement_lifecycle = true,
			pid_alive = false,
		}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")
			fixture.controls.requirement_child.partial.pid = nil
			plan.pause_on_logger_callback = "MLX download freshness check"
			plan.logger_pause_record = "reentrant_tail_terminal_pause"
			helpers.assert_eq(tail:complete(0), false)
			helpers.assert_eq(fixture.records.reentrant_tail_terminal_pause, false,
				"PAUSE cannot publish while the tail terminal callback is on-stack")
			assert_cancelled(fixture, "script_paused")
			local live_tail_done = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 0.5 and timer.live == true then
					live_tail_done = live_tail_done + 1
				end
			end
			helpers.assert_eq(live_tail_done, 0,
				"the revoked terminal cannot retain a business successor")
		end)
	end)

	for _, action in ipairs({"cancel", "retry"}) do
		helpers.it("HS-012 keeps regular " .. action
			.. " UI callback joined through nested PAUSE", function()
			with_fixture({
				requirement_lifecycle = true,
				pause_on_update_icon = "MLX download cancellation icon reset",
				launcher = {complete_on_terminate = true},
			}, function(fixture)
				helpers.assert_true(fixture.controls.pull())
				local result
				if action == "cancel" then
					result = fixture.controls.window.on_cancel()
				else
					result = fixture.controls.window.on_retry()
				end
				helpers.assert_eq(result, false)
				helpers.assert_eq(
					fixture.records.reentrant_update_icon_pause, false,
					"nested PAUSE must wait for the complete UI callback")
				assert_cancelled(fixture, "script_paused")
				helpers.assert_eq(#fixture.records.notifications, 0)
				helpers.assert_eq(#fixture.records.completions, 0)
				local retry_timers = 0
				for _, timer in ipairs(fixture.records.timers) do
					if timer.delay == 0.05 then retry_timers = retry_timers + 1 end
				end
				helpers.assert_eq(retry_timers, 0,
					"nested PAUSE must fence the retry successor")
				helpers.assert_eq(fixture.records.requirement_settlements, 1)
			end)
		end)
	end

	for _, action in ipairs({"cancel", "retry"}) do
		helpers.it("HS-012 keeps reattach " .. action
			.. " UI callback joined through nested PAUSE", function()
			local plan = {
				pid_alive = true,
				tail = {complete_on_terminate = true},
			}
			if action == "cancel" then
				plan.pause_on_update_icon = "MLX reattach completion icon reset"
				plan.update_icon_pause_kind = "reattach"
			else
				plan.tail.pause_after_terminate = "reattach"
			end
			with_fixture(plan, function(fixture)
				helpers.assert_true(fixture.controls.reattach())
				local result
				if action == "cancel" then
					result = fixture.controls.window.on_cancel()
				else
					result = fixture.controls.window.on_retry()
				end
				helpers.assert_eq(result, false)
				local pause_result
				if action == "cancel" then
					pause_result = fixture.records.reentrant_update_icon_pause
				else
					pause_result = fixture.records.reentrant_tail_termination_pause
				end
				helpers.assert_eq(pause_result, false,
					"reattach PAUSE must wait for the complete UI callback")
				helpers.assert_eq(#fixture.records.notifications, 0,
					"a paused callback cannot publish a terminal notification")
				helpers.assert_eq(#fixture.records.completions, 0,
					"a paused callback cannot publish terminal window state")
				helpers.assert_nil(fixture.controls.latest("launcher"),
					"a paused retry cannot start its regular download successor")
			end)
		end)
	end

	helpers.it("HS-012 rejects a truthy stopped reattach tail before retry", function()
		local plan = {
			pid_alive = true,
			tail = {running_after_start = false},
		}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local stopped_tail = fixture.controls.latest("tail")
			helpers.assert_true(fixture.deps.active_tasks.download_tail ~= stopped_tail,
				"the stopped task cannot remain the monitor sentinel")
			helpers.assert_true(fixture.controls.window.on_retry())
			plan.pid_alive = false
			fixture.controls.fire(0.25)
			helpers.assert_not_nil(fixture.controls.latest("launcher"),
				"retry must hand off after the stopped tail is cleared")
		end)
	end)

	helpers.it("HS-012 retains reattach tail on non-boolean liveness", function()
		local plan = {
			pid_alive = true,
			tail = {running_probe = "non_boolean", terminate = "false"},
		}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_eq(fixture.deps.active_tasks.download_tail, exact_tail,
				"inconclusive liveness must retain the exact tail debt")
			helpers.assert_true(fixture.controls.window.on_retry())
			plan.pid_alive = false
			fixture.controls.exit_code = 1
			exact_tail:complete(0)
			fixture.controls.fire(0.25)
			helpers.assert_not_nil(fixture.controls.latest("launcher"),
				"the retry may hand off only after the exact tail settles")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 consumes stopped reattach tail after terminate " .. mode,
			function()
				local plan = {
					pid_alive = true,
					tail = {terminate = mode, terminate_stops = true},
				}
				with_fixture(plan, function(fixture)
					helpers.assert_true(fixture.controls.reattach())
					local exact_tail = fixture.controls.latest("tail")
					helpers.assert_true(fixture.controls.window.on_retry())
					helpers.assert_true(
						fixture.deps.active_tasks.download_tail ~= exact_tail,
						"exact stopped tail must yield to the monitor sentinel")
					plan.pid_alive = false
					fixture.controls.fire(0.25)
					helpers.assert_not_nil(fixture.controls.latest("launcher"))
				end)
			end)
	end

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-012 releases a cancelled retry timer after late " .. mode
			.. " stop debt settles", function()
			with_fixture({
				requirement_lifecycle = true,
				launcher = {complete_on_terminate = true},
				timer_by_delay = {
					[0.05] = {stop = mode},
				},
			}, function(fixture)
				helpers.assert_true(fixture.controls.pull())
				helpers.assert_true(fixture.controls.window.on_retry())
				local retry_timer
				for _, timer in ipairs(fixture.records.timers) do
					if timer.delay == 0.05 then retry_timer = timer break end
				end
				helpers.assert_not_nil(retry_timer)
				helpers.assert_eq(fixture.controls.window.on_cancel(), false)
				helpers.assert_eq(fixture.records.requirement_settlements or 0, 0,
					"the exact refused timer must remain registered")
				retry_timer.behavior.stop = "success"
				fixture.controls.fire(0.05)
				helpers.assert_eq(fixture.records.requirement_settlements, 1,
					"late exact settlement must release the revoked owner")
			end)
		end)
	end

	for _, dispatch in ipairs({"sync", "async"}) do
		for _, terminal in ipairs({"success", "failure"}) do
			helpers.it("HS-012 keeps " .. dispatch .. " server " .. terminal
				.. " terminal joined through callback return", function()
				local plan = {
					requirement_lifecycle = true,
					pause_in_terminal = terminal,
					pid_alive = false,
				}
				if dispatch == "sync" then plan.server_sync = terminal end
				with_fixture(plan, function(fixture)
					helpers.assert_true(fixture.controls.pull())
					launch_detached_download(fixture)
					fixture.controls.finish_download(0)
					if dispatch == "async" then
						if terminal == "success" then
							helpers.assert_true(fixture.controls.server_success())
						else
							helpers.assert_true(
								fixture.controls.server_cancel("server_failed"))
						end
					end
					helpers.assert_eq(fixture.records.reentrant_server_terminal_pause,
						false,
						"terminal PAUSE must wait for the complete server callback")
					helpers.assert_eq(fixture.records.server_terminal_mutations, 1)
					helpers.assert_eq(fixture.records.requirement_settlements, 1)
					helpers.assert_true(fixture.controls.requirement_pause_join(),
						"PAUSE may publish only after the callback mutation returns")
				end)
			end)
		end
	end

	helpers.it("HS-012 joins a requirement PAUSE re-entered by synchronous tail completion",
		function()
			local plan = {
				requirement_lifecycle = true,
				pid_alive = false,
				tail = {
					complete_on_start = true,
					pause_after_complete_on_start = true,
					terminate = "false",
				},
			}
			with_fixture(plan, function(fixture)
				helpers.assert_true(fixture.controls.pull())
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				helpers.assert_eq(fixture.records.reentrant_requirement_pause, false)
				assert_cancelled(fixture, "script_paused")
				local poll_or_timeout = 0
				for _, timer in ipairs(fixture.records.timers) do
					if timer.delay == 3 or timer.delay == 30 then
						poll_or_timeout = poll_or_timeout + 1
					end
				end
				helpers.assert_eq(poll_or_timeout, 0,
					"a revoked synchronous tail cannot arm poll or timeout successors")
				fixture.controls.fire(0.25)
				helpers.assert_eq(fixture.records.requirement_settlements, 1)
			end)
		end)

	helpers.it("HS-012 retains a poll timer published before reentrant PAUSE", function()
		local plan = {
			requirement_lifecycle = true,
			pid_alive = false,
			tail = { terminate = "false" },
			timer_by_delay = {
				[3] = { pause_on_start = true, stop = "false" },
			},
		}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			local launcher = fixture.controls.latest("launcher")
			launcher:emit("__DLPID__:4242\n")
			launcher:complete(0)
			helpers.assert_eq(fixture.records.reentrant_timer_pause, false)
			assert_cancelled(fixture, "script_paused")
			local poll
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 then poll = timer break end
			end
			helpers.assert_not_nil(poll)
			helpers.assert_true(poll.live,
				"the refused exact stop must retain the poll candidate")

			poll.behavior.stop = "success"
			helpers.assert_eq(fixture.controls.requirement_pause_join(), false,
				"the tail still owns physical settlement after the timer joins")
			helpers.assert_eq(poll.live, false)
			fixture.controls.latest("tail"):complete(0)
			helpers.assert_eq(fixture.records.requirement_settlements, 1)
		end)
	end)

	for _, mode in ipairs({"false", "throw"}) do
		helpers.it("HS-024 handles tail construction " .. mode .. " refusal", function()
			with_fixture({real_switcher = true, tail = {construct = mode}}, function(fixture)
				helpers.assert_eq(fixture.switcher.switch_model("B"), true)
				launch_detached_download(fixture)
				assert_switcher_failure(fixture, "tail_task_construction_failed")
			end)
		end)
	end

	for _, server_sync in ipairs({"success", "failure"}) do
		for _, mode in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-024 buffers synchronous server " .. server_sync
				.. " before " .. mode .. " dispatch", function()
				with_fixture({real_switcher = true, server_sync = server_sync,
					server_mode = mode}, function(fixture)
					helpers.assert_eq(fixture.switcher.switch_model("B"), true)
					launch_detached_download(fixture)
					fixture.controls.finish_download(0)
					assert_switcher_failure(fixture, "server_start_refused")
				end)
			end)
		end
	end

	helpers.it("HS-024 reattach reports an interrupted download when its PID is gone", function()
		with_fixture({pid_alive = false}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), false)
			helpers.assert_eq(#fixture.records.notifications, 1)
			local notification = fixture.records.notifications[1]
			helpers.assert_eq(notification[1], "mlx.download_interrupted")
			helpers.assert_eq(notification[2], "mlx.download_interrupted_body")
			helpers.assert_eq(notification[3], "error")
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.completions[1][1], false)
			helpers.assert_nil(fixture.deps.active_tasks.download_tail)
		end)
	end)

	helpers.it("HS-012 keeps RESUME parked when freshness re-enters PAUSE", function()
		with_fixture({pid_alive = true}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			helpers.assert_true(fixture.controls.pause_reattached_download())
			fixture.controls.fire(3)
			local nested_pause
			helpers.assert_eq(fixture.obj.resume_reattached_download({
				resume_is_current = function()
					nested_pause = fixture.controls.pause_reattached_download()
					return true
				end,
			}), false)
			helpers.assert_eq(nested_pause, false,
				"nested PAUSE must wait for the RESUME freshness callback")
			local live_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					live_poll_timers = live_poll_timers + 1
				end
			end
			helpers.assert_eq(live_poll_timers, 0,
				"a PAUSE-fenced RESUME cannot rearm parked work")
			helpers.assert_true(fixture.obj.resume_reattached_download({
				resume_is_current = function() return true end,
			}))
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					live_poll_timers = live_poll_timers + 1
				end
			end
			helpers.assert_eq(live_poll_timers, 1,
				"a later clean RESUME must rearm exactly one parked poll")
		end)
	end)

	helpers.it("HS-012 revalidates reattachment after a timer start re-enters PAUSE", function()
		with_fixture({
			pid_alive = true,
			timer_by_delay = {
				[3] = {{pause_reattach_on_start = true}, {}},
			},
		}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), false)
			helpers.assert_eq(fixture.records.reentrant_reattach_pause, false,
				"PAUSE cannot publish inside the exact poll-timer acquisition")
			helpers.assert_nil(fixture.controls.latest("tail"),
				"a paused reattach acquisition cannot start its tail successor")
			helpers.assert_nil(fixture.controls.window,
				"a paused reattach acquisition cannot publish its download window")
			local live_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					live_poll_timers = live_poll_timers + 1
				end
			end
			helpers.assert_eq(live_poll_timers, 0,
				"the rejected acquisition cannot leave a live business successor")
			helpers.assert_true(fixture.obj.has_reattached_download(),
				"the exact parked reattach owner must remain retryable")
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"the same PAUSE must settle after acquisition unwinds")
			helpers.assert_true(fixture.obj.resume_reattached_download())
			local retried_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					retried_poll_timers = retried_poll_timers + 1
				end
			end
			helpers.assert_eq(retried_poll_timers, 1,
				"RESUME must retry exactly one parked poll capability")
		end)
	end)

	helpers.it("HS-012 publishes the reattach callback before its PID probe", function()
		with_fixture({
			pid_alive = true,
			pause_reattach_on_pid_probe = true,
		}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), false)
			helpers.assert_eq(fixture.records.reentrant_reattach_pid_pause, false,
				"PAUSE cannot publish while the exact PID probe remains on-stack")
			helpers.assert_eq(#fixture.records.timers, 0,
				"the paused probe must fence its poll-timer successor")
			helpers.assert_nil(fixture.controls.latest("tail"))
			helpers.assert_nil(fixture.controls.window)
			helpers.assert_true(fixture.obj.has_reattached_download(),
				"the probe must retain the exact parked reattach owner")
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"retrying PAUSE after the probe unwinds must settle that owner")
		end)
	end)

	helpers.it("HS-012 parks a poll whose exit probe re-enters PAUSE", function()
		with_fixture({
			pid_alive = true,
			pause_reattach_on_exit_probe = 2,
		}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_type(exact_tail, "table")
			fixture.controls.fire(3)
			helpers.assert_eq(fixture.records.reentrant_reattach_probe_pause, false,
				"PAUSE cannot publish from inside the poll callback")
			local poll_timers = 0
			local live_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 then
					poll_timers = poll_timers + 1
					if timer.live == true then
						live_poll_timers = live_poll_timers + 1
					end
				end
			end
			helpers.assert_eq(poll_timers, 1,
				"the fenced probe must not construct a poll successor")
			helpers.assert_eq(live_poll_timers, 0)
			helpers.assert_eq(fixture.controls.latest("tail"), exact_tail,
				"the parked monitor must retain its exact tail identity")
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"retrying the same PAUSE after callback unwind must settle")
			helpers.assert_true(fixture.obj.resume_reattached_download())
			local retried_poll_timers = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 3 and timer.live == true then
					retried_poll_timers = retried_poll_timers + 1
				end
			end
			helpers.assert_eq(retried_poll_timers, 1,
				"RESUME must restore exactly the deferred poll successor")
		end)
	end)

	helpers.it("HS-012 withholds PAUSED while the reattached tail starts", function()
		with_fixture({
			pid_alive = true,
			tail = {pause_reattach_on_start = true},
		}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), false)
			helpers.assert_eq(fixture.records.reentrant_reattach_tail_pause, false,
				"PAUSE cannot publish while the exact tail start remains on-stack")
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_type(exact_tail, "table")
			helpers.assert_eq(fixture.deps.active_tasks.download_tail, exact_tail)
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"the same tail owner must settle after start unwinds")
			helpers.assert_true(fixture.obj.resume_reattached_download())
			helpers.assert_eq(fixture.controls.latest("tail"), exact_tail,
				"RESUME must retain the exact already-started tail")
		end)
	end)

	helpers.it("HS-012 retries the exact tail-completion timer after nested PAUSE", function()
		with_fixture({
			pid_alive = true,
			timer_by_delay = {
				[0.5] = {{pause_reattach_on_start = true}, {}},
			},
		}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local exact_tail = fixture.controls.latest("tail")
			helpers.assert_type(exact_tail, "table")
			helpers.assert_true(exact_tail:complete(0))
			helpers.assert_eq(fixture.records.reentrant_reattach_pause, false,
				"PAUSE cannot publish inside the tail-completion timer acquisition")
			local live_tail_done = 0
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 0.5 and timer.live == true then
					live_tail_done = live_tail_done + 1
				end
			end
			helpers.assert_eq(live_tail_done, 0,
				"the fenced acquisition cannot leave a live tail successor")
			helpers.assert_true(fixture.controls.pause_reattached_download(),
				"the same tail callback owner must settle after unwind")
			helpers.assert_true(fixture.obj.resume_reattached_download())
			for _, timer in ipairs(fixture.records.timers) do
				if timer.delay == 0.5 and timer.live == true then
					live_tail_done = live_tail_done + 1
				end
			end
			helpers.assert_eq(live_tail_done, 1,
				"RESUME must restore exactly the parked tail-completion capability")
		end)
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-024 reattach tail " .. mode
			.. " refusal discards synchronous stream", function()
			with_fixture({pid_alive = true, tail = {
				start = mode,
				stream_on_start = "__BYTES__:99\n",
				mutate_on_start = true,
			}}, function(fixture)
				helpers.assert_true(fixture.controls.reattach())
				helpers.assert_eq(#fixture.records.updates, 0)
				local tail = fixture.controls.latest("tail")
				tail:emit("__BYTES__:100\n")
				helpers.assert_eq(#fixture.records.updates, 0,
					"late refused reattach stream must remain inert")
			end)
		end)
	end

	helpers.it("HS-024 replays a committed reattach stream once", function()
		with_fixture({pid_alive = true, tail = {
			stream_on_start = "__BYTES__:99\n",
		}}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			helpers.assert_eq(#fixture.records.updates, 1)
			local tail = fixture.controls.latest("tail")
			tail:complete(0)
			tail:emit("__BYTES__:100\n")
			helpers.assert_eq(#fixture.records.updates, 1,
				"terminal reattach tail must fence late stream")
		end)
	end)

	helpers.it("HS-024 reattach cancellation retains owner and fences late success", function()
		local plan = {pid_alive = true, kill_mode = "false",
			tail = {terminate = "false"}}
		with_fixture(plan, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), true)
			local tail = fixture.controls.latest("tail")
			fixture.controls.window.on_cancel()
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.completions[1][1], false)
			tail:complete(0)
			fixture.controls.fire(0.5)
			helpers.assert_eq(fixture.records.server_starts, 0)
			local second_cancels = 0
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, function()
				second_cancels = second_cancels + 1
			end, {is_current = function() return true end}), false)
			helpers.assert_eq(second_cancels, 1)
			plan.pid_alive = false
			fixture.controls.fire(0.25)
			helpers.assert_eq(#fixture.records.completions, 1,
				"the revoked reattach owner cannot publish late success")
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), true)
		end)
	end)

	helpers.it("HS-024 reattach async success releases after the exact tail retires", function()
		with_fixture({pid_alive = true}, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), true)
			local tail = fixture.controls.latest("tail")
			fixture.controls.exit_code = 0
			fixture.controls.fire(3)
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.completions[1][1], true)
			helpers.assert_eq(fixture.deps.active_tasks.download_tail, tail,
				"the terminal owner must retain the still-live exact tail")

			tail:complete(0)
			helpers.assert_nil(fixture.deps.active_tasks.download_tail)
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), true)
			local session_path = "/tmp/hs_mlx_active_download.json"
			local successor_session = fixture.controls.files[session_path]
			helpers.assert_type(successor_session, "string")
			helpers.assert_eq(successor_session:find('"model":"C"', 1, true) ~= nil, true)

			tail:complete(0)
			helpers.assert_eq(fixture.controls.files[session_path], successor_session,
				"a duplicate retired-tail callback cannot remove the successor session")
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.server_starts, 0)
		end)
	end)
end)






-- ==========================================================
-- ==========================================================
-- ======= HS-036/ Detached PID Identity & Exit Proof =======
-- ==========================================================
-- ==========================================================

local function assert_successor_admitted(fixture)
	helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
		{is_current = function() return true end}), true,
		"settled detached cleanup must release the single download slot")
end

helpers.describe("HS-036 detached download cleanup owns a process identity", function()
	helpers.it("trusts the current download exit file before any PID signal", function()
		with_fixture({pid_alive = true, pid_identity = true}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")
			fixture.controls.exit_code = 1

			fixture.controls.window.on_cancel()
			tail:complete(0)

			helpers.assert_eq(fixture.records.raw_pid_signals, 0,
				"an authoritative exit file must suppress the legacy raw PID signal")
			helpers.assert_eq(fixture.records.verified_pid_signals, 0,
				"an authoritative exit file must suppress even a verified PID signal")
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("trusts the reattached exit file before any PID signal", function()
		with_fixture({pid_alive = true, pid_identity = true}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local tail = fixture.controls.latest("tail")
			fixture.controls.exit_code = 1

			fixture.controls.window.on_cancel()
			tail:complete(0)

			helpers.assert_eq(fixture.records.raw_pid_signals, 0)
			helpers.assert_eq(fixture.records.verified_pid_signals, 0)
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("releases a current-download PID recycled by another process", function()
		with_fixture({pid_alive = true, pid_identity = false}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")

			fixture.controls.window.on_cancel()
			tail:complete(0)

			helpers.assert_eq(fixture.records.pid_identity_probes, 1,
				"cleanup must verify the exact Python script before signalling a live PID")
			helpers.assert_eq(fixture.records.raw_pid_signals, 0,
				"a recycled PID must never reach an unverified signal call")
			helpers.assert_eq(fixture.records.verified_pid_signals, 0,
				"a mismatched process identity must never receive a signal")
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("releases a reattached PID recycled by another process", function()
		with_fixture({pid_alive = true, pid_identity = false}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local tail = fixture.controls.latest("tail")

			fixture.controls.window.on_cancel()
			tail:complete(0)

			helpers.assert_eq(fixture.records.pid_identity_probes, 1)
			helpers.assert_eq(fixture.records.raw_pid_signals, 0)
			helpers.assert_eq(fixture.records.verified_pid_signals, 0)
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("bounds verified TERM retries before KILL escalation", function()
		local plan = {pid_alive = true, pid_identity = true}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")

			fixture.controls.window.on_cancel()
			for _ = 1, 3 do fixture.controls.fire(0.25) end
			helpers.assert_eq(fixture.records.verified_term_signals, 4,
				"cleanup must bound graceful termination attempts")
			helpers.assert_eq(fixture.records.verified_kill_signals, 0)

			fixture.controls.fire(0.25)
			helpers.assert_eq(fixture.records.verified_term_signals, 4)
			helpers.assert_eq(fixture.records.verified_kill_signals, 1,
				"a still-owned PID must escalate after the bounded TERM budget")
			helpers.assert_eq(fixture.records.raw_pid_signals, 0)

			plan.pid_alive = false
			fixture.controls.fire(0.25)
			tail:complete(0)
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("retains an inconclusive identity without signalling", function()
		local plan = {pid_alive = true, pid_identity = "unknown"}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")

			fixture.controls.window.on_cancel()
			tail:complete(0)
			helpers.assert_eq(fixture.records.verified_pid_signals, 0)
			helpers.assert_eq(fixture.records.raw_pid_signals, 0)
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), false,
				"an inconclusive identity must retain the cleanup owner")

			plan.pid_identity = false
			fixture.controls.fire(0.25)
			assert_successor_admitted(fixture)
		end)
	end)
end)





-- ======================================================
-- ======================================================
-- ======= HS-037/ Detached Repository Trust Gate =======
-- ======================================================
-- ======================================================

helpers.describe("HS-037 detached session repository identifiers are untrusted", function()
	local hostile_repositories = {
		"org/model'$(touch_HS037_PWN)'",
		"org/model`touch_HS037_PWN`",
		"org/model\"$(touch_HS037_PWN)\"",
		"org/mo del",
		"org/model\npayload",
		"org/model/extra",
	}

	for _, hostile_repo in ipairs(hostile_repositories) do
		helpers.it("refuses a hostile pull_model repository before acquisition", function()
			with_fixture({}, function(fixture)
				local cancellation_reason
				local accepted = fixture.obj.pull_model("B", hostile_repo, nil,
					function(reason)
						cancellation_reason = reason
						return true
					end, {is_current = function() return true end})

				helpers.assert_eq(accepted, false)
				helpers.assert_eq(cancellation_reason, "invalid_repo")
				helpers.assert_eq(#fixture.controls.tasks.launcher, 0)
				helpers.assert_eq(#fixture.controls.tasks.tail, 0)
				helpers.assert_eq(#fixture.records.timers, 0)
				helpers.assert_eq(#fixture.records.os_commands, 0)
				helpers.assert_nil(fixture.controls.window)
			end)
		end)
	end

	helpers.it("refuses a planted reattach repository at the retry handoff", function()
		local hostile_repo = "org/model'$(touch_HS037_PWN)'"
		with_fixture({
			pid_alive = true,
			pid_identity = false,
			tail = {running_after_start = false},
		}, function(fixture)
			helpers.assert_true(fixture.controls.reattach(hostile_repo))
			helpers.assert_true(fixture.controls.window.on_retry())
			helpers.assert_eq(#fixture.controls.tasks.launcher, 0,
				"retry must not construct a launcher from the planted repository")
			for path in pairs(fixture.controls.files) do
				helpers.assert_true(not path:match("%.py$") and not path:match("%.sh$"),
					"retry must not stage executable files from the planted repository")
			end
		end)
	end)
end)

return true
