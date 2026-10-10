-- static/ergopti_plus/macos/tests/support/real_lease_shell_runner_fixture.lua
--- It never invokes a business callback directly or substitutes ShellRunner.spawn.
local helpers = require("tests.helpers")
local M = {}
local UUIDS = { "00112233-4455-6677-8899-aabbccddeeff", "ffeeddcc-bbaa-9988-7766-554433221100" }

function M.with_fixture(body, options)
	options = options or {}
	local saved, old_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local ok, failure = xpcall(function()
		local ctx = { tasks = {}, timers = {}, clock = 0, uuid_index = 0, settings = {} }
		for _, name in ipairs({ "adapters.shell_runner", "adapters.storage", "adapters.task_environment",
			"infra.deferred_work", "platform.remap.lease_controller" }) do package.loaded[name] = nil end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["platform.remap.ke_paths"] = { CLI = "/test/karabiner_cli" }
		package.loaded["platform.remap.lease_helper"] = { resolve = function()
			return "/test/ErgoptiPlus", nil
		end }
		local function timer(delay, fn, repeating)
			local handle = { delay = delay, fn = fn, repeating = repeating, cancelled = false, fired = false }
			ctx.timers[#ctx.timers + 1] = handle
			return handle, true
		end
		package.loaded["adapters.timer_scheduler"] = {
			awake_time = function() return ctx.clock end,
			after = function(delay, fn) return timer(delay, fn, false) end,
			every = function(delay, fn) return timer(delay, fn, true) end,
			cancel = function(handle) handle.cancelled = true; return true end,
		}
		local native_new = function(executable, done, chunk_or_arguments, arguments)
			local chunk = type(chunk_or_arguments) == "function" and chunk_or_arguments or nil
			local args = chunk and arguments or chunk_or_arguments
			local task = { executable = executable, args = args, inputs = {}, running = false,
				start_calls = 0, terminate_calls = 0, eof_calls = 0,
				env = { PATH = "/usr/bin:/bin", HOME = "/test", ERGOPTI_LOG_TOKEN = "synthetic" } }
			-- These are the native constructor callbacks, not the controller callbacks.
			ctx.tasks[#ctx.tasks + 1] = task
			function task:environment() local copy = {}; for key, value in pairs(self.env) do copy[key] = value end; return copy end
			function task:setEnvironment(value) self.env = value; return self end
			function task:start()
				self.start_calls = self.start_calls + 1
				self.running = true
				if self.args[1] == "--karabiner-lease-worker" and options.start_failure then
					helpers.assert_true(type(chunk) == "function", "actual native worker stream registered")
					chunk(self, "READY\n", "")
					if options.start_failure == "throw" then error("synthetic native start refusal") end
					if options.start_failure == "false" then return false end
					if options.start_failure == "nil" then return nil end
					if options.start_failure == "foreign" then return {} end
				end
				return self
			end
			function task:isRunning() return self.running end
			function task:setInput(value) self.inputs[#self.inputs + 1] = value; return self end
			function task:closeInput() self.eof_calls = self.eof_calls + 1; return self end
			function task:terminate() self.terminate_calls = self.terminate_calls + 1; return self end
			function task:emit(value)
				helpers.assert_true(type(chunk) == "function", "native constructor installed stream callback")
				return chunk(self, value, "")
			end
			function task:final(value)
				helpers.assert_eq(self.running, false, "final nil is delivered after genuine native completion")
				helpers.assert_true(type(chunk) == "function", "native constructor installed stream callback")
				return chunk(nil, value, "")
			end
			function task:complete(code, stdout)
				self.running = false
				return done(code or 0, stdout or "", "")
			end
			return task
		end
		local controller = helpers.load_with_stubs("platform.remap.lease_controller", {
			task = { new = native_new },
			host = { uuid = function() ctx.uuid_index = ctx.uuid_index + 1; return UUIDS[ctx.uuid_index] end },
			settings = {
				get = function(key) return ctx.settings[key] end,
				set = function(key, value) ctx.settings[key] = value; return true end,
			},
		})
		local runner = require("adapters.shell_runner")
		helpers.assert_true(type(runner.spawn_private) == "function", "real shared adapter loaded")
		helpers.assert_true(controller.init())
		function ctx.live_timer(delay)
			for _, handle in ipairs(ctx.timers) do
				if handle.delay == delay and not handle.cancelled and not handle.fired then return handle end
			end
			error("no live native timer port for expected delay")
		end
		function ctx.fire(handle)
			helpers.assert_eq(handle.cancelled, false)
			helpers.assert_eq(handle.fired, false)
			ctx.clock = ctx.clock + handle.delay
			handle.fired = true
			handle.fn()
		end
		body(controller, ctx, runner)
	end, debug.traceback)
	_G.hs = old_hs
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

return M
