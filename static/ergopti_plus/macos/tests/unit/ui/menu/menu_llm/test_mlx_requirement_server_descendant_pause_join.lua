--- tests/unit/ui/menu/menu_llm/test_mlx_requirement_server_descendant_pause_join.lua

local helpers = require("tests.helpers")

local MODULES = {
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"modules.llm.api_common",
	"modules.llm.api_mlx",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"ui.menu.menu_llm.requirement_operation_registry",
	"ui.menu.menu_llm.models_manager_mlx_server",
}

local function notify_settled(handle)
	local observers = handle.observers or {}
	handle.observers = {}
	for _, observer in ipairs(observers) do observer() end
end

local function with_fixture(callback)
	local saved_hs = _G.hs
	local saved_execute = os.execute
	local saved_modules = {}
	for _, name in ipairs(MODULES) do saved_modules[name] = package.loaded[name] end
	local outcome = table.pack(xpcall(function()
		local native = {
			tasks = {},
			start_modes = {},
			cancel_mode = "true",
			timers = {},
		}
		local logger_stub = helpers.make_logger_stub()
		logger_stub.UNIFIED_LOG_FILE = "/tmp/ergopti-test.log"
		package.loaded["infra.logger"] = logger_stub
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["modules.llm.api_common"] = {
			protected_call = function(fn, _, ...)
				if type(fn) ~= "function" then return false end
				return xpcall(fn, debug.traceback, ...)
			end,
		}
		package.loaded["modules.llm.api_mlx"] = {
			get_port = function() return 8080 end,
			reset_endpoints = function() return true end,
			set_active_server_pgid = function() return true end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			after = function(delay, callback_fn)
				local handle = {
					delay = delay,
					callback = callback_fn,
					timer = {},
					observers = {},
					cancel_calls = 0,
				}
				native.timers[#native.timers + 1] = handle
				return handle, true
			end,
			cancel = function(handle)
				handle.cancel_calls = handle.cancel_calls + 1
				if handle.timer ~= nil then
					handle.timer = nil
					notify_settled(handle)
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

		_G.hs = {
			json = {
				decode = function(body)
					if type(body) == "string" and body:find("fixture-model", 1, true) then
						return { data = {{ id = "fixture-model" }} }
					end
					return { data = {} }
				end,
			},
			task = {},
		}
		_G.hs.task.new = function(_, on_done, on_chunk_or_args, args)
			local task = {
				index = #native.tasks + 1,
				on_done = on_done,
				on_chunk = type(on_chunk_or_args) == "function"
					and on_chunk_or_args or nil,
				args = type(on_chunk_or_args) == "function"
					and (args or {}) or on_chunk_or_args,
				running = false,
				start_calls = 0,
				terminate_calls = 0,
			}
			function task:start()
				self.start_calls = self.start_calls + 1
				local mode = native.start_modes[self.index] or "true"
				self.running = mode ~= "false_clean"
				if mode == "throw" then error("synthetic server start") end
				if mode == "false" or mode == "false_clean" then return false end
				if mode == "nil" then return nil end
				return self
			end
			function task:terminate()
				self.terminate_calls = self.terminate_calls + 1
				if native.cancel_mode == "throw" then error("synthetic server terminate") end
				if native.cancel_mode == "false" then return false end
				if native.cancel_mode == "nil" then return nil end
				return self
			end
			function task:isRunning() return self.running end
			function task:complete(...)
				self.running = false
				return self.on_done(...)
			end
			native.tasks[#native.tasks + 1] = task
			return helpers.attach_native_task_environment(task)
		end

		package.loaded["adapters.task_lifecycle"] = nil
		os.execute = function() return true, "exit", 0 end
		local obj = {
			get_mlx_repo = function() return "fixture/repo" end,
		}
		local deps = { active_tasks = {} }
		local gc_root = {}
		require("ui.menu.menu_llm.models_manager_mlx_server").install({
			obj = obj,
			deps = deps,
			project_venv_python_escaped = "/fixture/python",
			active_tasks_gc_root = gc_root,
		})
		local registry = require("ui.menu.menu_llm.requirement_operation_registry").new({
			backend = "MLX server fixture",
			require_owned = true,
		})
		callback({
			native = native,
			obj = obj,
			deps = deps,
			gc_root = gc_root,
			registry = registry,
		})
	end, debug.traceback))
	_G.hs = saved_hs
	os.execute = saved_execute
	for _, name in ipairs(MODULES) do package.loaded[name] = saved_modules[name] end
	if not outcome[1] then error(outcome[2], 0) end
end

local function begin_server(fixture, capability)
	local operation, reason = fixture.registry.begin(capability)
	if operation == nil then return nil, reason end
	local terminal = { success = 0, cancel = 0 }
	local accepted = fixture.obj.start_server("fixture-model", function()
		return operation.finish(function()
			terminal.success = terminal.success + 1
			return true
		end, "fixture success")
	end, function()
		return operation.finish(function()
			terminal.cancel = terminal.cancel + 1
			return true
		end, "fixture cancel")
	end, {
		_requirement_lifecycle = operation.lifecycle,
		is_current = function() return operation.is_authorized() end,
	})
	return {
		accepted = accepted,
		operation = operation,
		terminal = terminal,
	}
end

helpers.describe("HS-012 MLX server/readiness requirement descendants", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains exact server and readiness owners after " .. mode, function()
			with_fixture(function(fixture)
				local activation = fixture.registry.create_owner("activation")
				local model = fixture.registry.create_owner("model")
				local startup = fixture.registry.create_owner("startup")
				local request = begin_server(fixture, startup)
				helpers.assert_true(request.accepted)
				local server_task, readiness_task =
					fixture.native.tasks[1], fixture.native.tasks[2]
				helpers.assert_true(server_task.running)
				helpers.assert_true(readiness_task.running)

				helpers.assert_eq(fixture.registry.pause(activation), true)
				helpers.assert_eq(fixture.registry.pause(model), true)
				helpers.assert_eq(server_task.terminate_calls, 0,
					"foreign owners cannot claim startup descendants")
				fixture.native.cancel_mode = mode
				helpers.assert_eq(fixture.registry.pause(startup), false)
				helpers.assert_eq(server_task.terminate_calls, 1)
				helpers.assert_eq(readiness_task.terminate_calls, 1)
				helpers.assert_eq(fixture.registry.pause(startup), false)
				helpers.assert_eq(server_task.terminate_calls, 2)
				helpers.assert_eq(readiness_task.terminate_calls, 2)
				helpers.assert_eq(#fixture.native.tasks, 2)

				readiness_task:complete(0, '{"data":[{"id":"fixture-model"}]}', "")
				readiness_task:complete(0, "duplicate", "")
				server_task:complete(15, "", "")
				server_task:complete(15, "duplicate", "")
				helpers.assert_eq(request.terminal.success, 0)
				helpers.assert_eq(request.terminal.cancel, 0)
				helpers.assert_eq(fixture.registry.pause(startup), true)
			end)
		end)
	end

	helpers.it("detaches the stable server only after readiness terminal", function()
		with_fixture(function(fixture)
			local capability = fixture.registry.create_owner("model")
			local request = begin_server(fixture, capability)
			local server_task, readiness_task =
				fixture.native.tasks[1], fixture.native.tasks[2]
			readiness_task:complete(0,
				'{"data":[{"id":"fixture-model"}]}', "")
			helpers.assert_eq(request.terminal.success, 1)
			helpers.assert_eq(fixture.registry.pause(capability), true)
			helpers.assert_eq(server_task.terminate_calls, 0,
				"a ready stable server is no longer requirement cleanup debt")
		end)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("blocks a successor after mutate-then-" .. mode .. " server start", function()
			with_fixture(function(fixture)
				fixture.native.start_modes[1] = mode
				fixture.native.cancel_mode = "false"
				local capability = fixture.registry.create_owner("startup")
				local request = begin_server(fixture, capability)
				helpers.assert_eq(request.accepted, false)
				local server_task = fixture.native.tasks[1]
				helpers.assert_eq(server_task.terminate_calls, 1)
				helpers.assert_eq(fixture.gc_root["mlx_server"], server_task)
				local successor, reason = fixture.registry.begin(capability)
				helpers.assert_eq(successor, nil)
				helpers.assert_eq(reason, "prior_operation_unsettled")
				server_task:complete(15, "", "")
				local fresh = fixture.registry.begin(capability)
				helpers.assert_true(type(fresh) == "table")
			end)
		end)
	end

	helpers.it("accepts exact not-running proof on clean server start refusal", function()
		with_fixture(function(fixture)
			fixture.native.start_modes[1] = "false_clean"
			fixture.native.cancel_mode = "throw"
			local capability = fixture.registry.create_owner("model")
			local request = begin_server(fixture, capability)
			helpers.assert_eq(request.accepted, false)
			helpers.assert_eq(fixture.native.tasks[1].terminate_calls, 0)
			local fresh = fixture.registry.begin(capability)
			helpers.assert_true(type(fresh) == "table")
		end)
	end)
end)
