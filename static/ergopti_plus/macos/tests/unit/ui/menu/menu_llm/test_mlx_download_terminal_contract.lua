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
				cancels = {},
				completions = {},
				gates = {},
				notifications = {},
				os_commands = {},
				requirement_failures = {},
				requirement_successes = 0,
				saves = 0,
				server_starts = 0,
				successes = 0,
				timers = {},
			}
			local controls = {
				exit_code = nil,
				files = {},
				tasks = {launcher = {}, tail = {}},
			}

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

			os.execute = function(command)
				records.os_commands[#records.os_commands + 1] = command
				if command:find("chmod", 1, true) then
					return result_value(plan.chmod_mode, true)
				end
				if command:find("kill %-0", 1, false) then
					local alive = plan.pid_alive
					if type(alive) == "table" then
						local next_value = table.remove(alive, 1)
						return result_value(next_value, false)
					end
					return result_value(alive, false)
				end
				if command:find("kill %-TERM", 1, false) then
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
							repo = raw:match('"repo":"([^"]+)"'),
						}
					end,
					encode = function(value)
						return string.format(
							'{"model":"%s","log_path":"%s","exit_path":"%s","repo":"%s","pid":%s}',
							tostring(value.model or ""), tostring(value.log_path or ""),
							tostring(value.exit_path or ""), tostring(value.repo or ""),
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
					if behavior.fire_on_start then timer_callback() end
					return result
				end
				function handle:stop()
					if behavior.fire_on_stop then timer_callback() end
					local result = result_value(behavior.stop, self)
					if result ~= false and result ~= nil then record.live = false end
					return result
				end
				function handle:running() return record.live end
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
					if self.behavior.start == "throw_after_start" then
						self.running_state = true
						error("injected native refusal after activation")
					end
					local start_result = result_value(self.behavior.start, self)
					if start_result ~= false and start_result ~= nil then
						self.running_state = true
					end
					if self.behavior.stream_on_start then
						self.stream(self, self.behavior.stream_on_start, "")
					end
					if self.behavior.complete_on_start then
						self.running_state = false
						self.done(self.behavior.complete_code or 0, "", "")
					end
					return start_result
				end
				function task:terminate()
					if self.behavior.complete_on_terminate then
						self.running_state = false
						self.done(self.behavior.terminate_code or 15, "", "")
					end
					return result_value(self.behavior.terminate, self)
				end
				function task:complete(code)
					self.running_state = false
					return self.done(code or 0, "", "")
				end
				function task:isRunning() return self.running_state end
				function task:emit(text)
					return self.stream(self, text, "")
				end
				controls.tasks[kind][#controls.tasks[kind] + 1] = task
				return task
			end

			_G.hs = hs_fixture
			package.loaded["hs"] = hs_fixture
			package.loaded["infra.logger"] = helpers.make_logger_stub()
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
				update = function() return true end,
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
				return obj.pull_model(model or "B", "org/model", function()
					records.successes = records.successes + 1
					return true
				end, function(reason)
					records.cancels[#records.cancels + 1] = reason
					return true
				end, {is_current = function() return true end})
			end
			function controls.reattach()
				local session = {
					model = "B",
					log_path = "/tmp/hs_mlx_dl_reattach.log",
					exit_path = "/tmp/hs_mlx_dl_reattach.log.exit",
					pid = 4242,
					repo = "org/model",
				}
				controls.files["/tmp/hs_mlx_active_download.json"] =
					'{"model":"B","log_path":"/tmp/hs_mlx_dl_reattach.log",'
					.. '"exit_path":"/tmp/hs_mlx_dl_reattach.log.exit",'
					.. '"repo":"org/model","pid":4242}'
				return obj.reattach_download(session)
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
			local plan = {tail = {start = mode}, pid_alive = true}
			with_fixture(plan, function(fixture)
				helpers.assert_eq(fixture.controls.pull(), true)
				local launcher = fixture.controls.latest("launcher")
				launcher:emit("__DLPID__:4242\n")
				launcher:complete(0)
				local stale_tail = fixture.controls.latest("tail")
				assert_cancelled(fixture, "tail_task_start_refused")
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
				fixture.controls.fire(0.25)
				helpers.assert_nil(fixture.controls.files[session_path])
				helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
					{is_current = function() return true end}), true)
				local successor_session = fixture.controls.files[session_path]
				helpers.assert_type(successor_session, "string")
				helpers.assert_eq(successor_session:find('"model":"C"', 1, true) ~= nil, true)
				helpers.assert_eq(successor_session:find('"repo":"org/other"', 1, true) ~= nil, true)

				stale_tail:complete(0)
				helpers.assert_eq(fixture.controls.files[session_path], successor_session,
					"a late callback cannot remove the successor's exact session")
				helpers.assert_eq(#fixture.records.cancels, 1)
				helpers.assert_eq(fixture.records.successes, 0)
				helpers.assert_eq(fixture.records.server_starts, 0)
			end)
		end)
	end

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

	helpers.it("HS-024 reattach cancellation retains owner and fences late success", function()
		local plan = {pid_alive = true, kill_mode = "false",
			tail = {terminate = "false"}}
		with_fixture(plan, function(fixture)
			helpers.assert_eq(fixture.controls.reattach(), true)
			local tail = fixture.controls.latest("tail")
			fixture.controls.window.on_cancel()
			helpers.assert_eq(#fixture.records.completions, 1)
			helpers.assert_eq(fixture.records.completions[1][1], false)
			fixture.controls.exit_code = 0
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

return true
