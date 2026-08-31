--- tests/unit/adapters/test_shell_runner_start_rollback_ownership.lua

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.logger",
	"adapters.shell_runner",
}

local function with_runner(callback)
	local saved_hs = _G.hs
	local outcome = table.pack(xpcall(function()
		helpers.with_fresh_modules(OWNED_MODULES, function()
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local native = {
				tasks = {},
				start_mode = "true",
				start_running = true,
				start_chunk = false,
				start_chunk_return = nil,
				start_completion_before_chunk = false,
				terminate_mode = "true",
				start_completion = false,
				terminate_completion = false,
			}
			_G.hs = {
				execute = function() return "" end,
				timer = { doAfter = function(_, fn) fn() return true end },
				task = {},
			}
			_G.hs.task.new = function(_, on_done, on_chunk_or_args)
				local task_environment = { HOME = "/Users/tester" }
				local task = {
					on_done = on_done,
					on_chunk = type(on_chunk_or_args) == "function"
						and on_chunk_or_args or nil,
					running = false,
					start_calls = 0,
					terminate_calls = 0,
				}
				function task:environment()
					local copy = {}
					for key, value in pairs(task_environment) do copy[key] = value end
					return copy
				end
				function task:setEnvironment(candidate)
					task_environment = candidate
					return self
				end
				function task:start()
					self.start_calls = self.start_calls + 1
					self.running = native.start_running == true
					if native.start_completion
						and native.start_completion_before_chunk then
						self:complete(0, "sync", "")
					end
					if native.start_chunk and self.on_chunk then
						native.start_chunk_return =
							self.on_chunk(self, "sync-before-start", "")
					end
					if native.start_completion
						and native.start_completion_before_chunk ~= true then
						self:complete(0, "sync", "")
					end
					if native.start_mode == "throw" then error("synthetic start refusal") end
					if native.start_mode == "false" then return false end
					if native.start_mode == "nil" then return nil end
					return self
				end
				function task:terminate()
					self.terminate_calls = self.terminate_calls + 1
					if native.terminate_completion then self:complete(15, "", "") end
					if native.terminate_mode == "throw" then
						error("synthetic terminate refusal")
					end
					if native.terminate_mode == "false" then return false end
					if native.terminate_mode == "nil" then return nil end
					return self
				end
				function task:isRunning() return self.running end
				function task:complete(...)
					self.running = false
					return self.on_done(...)
				end
				function task:chunk(...)
					if type(self.on_chunk) ~= "function" then return nil end
					return self.on_chunk(self, ...)
				end
				native.tasks[#native.tasks + 1] = task
				return task
			end

			local ShellRunner = require("adapters.shell_runner")
			callback(ShellRunner, native)
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("ShellRunner exact start-refusal rollback ownership", function()
	for _, start_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("fences synchronous and late chunks after " .. start_mode
			.. " start refusal", function()
			with_runner(function(ShellRunner, native)
				native.start_mode = start_mode
				native.start_chunk = true
				native.terminate_mode = "false"
				local business_chunks = 0
				local business_terminals = 0
				local handle = ShellRunner.spawn("/fixture/stream-refusal", {},
					function() business_terminals = business_terminals + 1 end,
					function()
						business_chunks = business_chunks + 1
						return false
					end)
				local task = native.tasks[1]

				helpers.assert_eq(handle.start(), false)
				helpers.assert_eq(native.start_chunk_return, true,
					"the native stream may drain while business delivery stays fenced")
				helpers.assert_eq(business_chunks, 0)
				helpers.assert_eq(business_terminals, 0)
				helpers.assert_eq(task.terminate_calls, 1)
				helpers.assert_eq(handle.isSettled(), false)
				helpers.assert_eq(task:chunk("late-before-terminal", ""), true)
				helpers.assert_eq(business_chunks, 0)

				task:complete(15, "", "")
				helpers.assert_true(handle.isSettled())
				helpers.assert_eq(task:chunk("late-after-terminal", ""), true)
				helpers.assert_eq(task:chunk("duplicate-late", ""), true)
				helpers.assert_eq(business_chunks, 0)
				helpers.assert_eq(business_terminals, 0)
			end)
		end)
	end

	helpers.it("delivers a committed synchronous chunk once and fences terminal-late chunks",
		function()
			with_runner(function(ShellRunner, native)
				native.start_chunk = true
				local business_chunks = 0
				local business_terminals = 0
				local handle = ShellRunner.spawn("/fixture/stream-commit", {},
					function() business_terminals = business_terminals + 1 end,
					function()
						business_chunks = business_chunks + 1
						return true
					end)
				local task = native.tasks[1]

				helpers.assert_true(handle.start())
				helpers.assert_eq(native.start_chunk_return, true)
				helpers.assert_eq(business_chunks, 1)
				task:complete(0, "", "")
				helpers.assert_eq(business_terminals, 1)
				helpers.assert_eq(task:chunk("late", ""), true)
				helpers.assert_eq(task:chunk("duplicate", ""), true)
				helpers.assert_eq(business_chunks, 1)
				helpers.assert_eq(business_terminals, 1)
			end)
		end)

	helpers.it("terminates the exact task when committed chunk replay refuses", function()
		with_runner(function(ShellRunner, native)
			native.start_chunk = true
			native.terminate_mode = "false"
			local chunks = 0
			local terminals = 0
			local handle = ShellRunner.spawn("/fixture/replay-refusal", {},
				function() terminals = terminals + 1 end,
				function()
					chunks = chunks + 1
					return false
				end)
			local task = native.tasks[1]

			helpers.assert_true(handle.start())
			helpers.assert_eq(chunks, 1)
			helpers.assert_eq(task.terminate_calls, 1)
			helpers.assert_eq(handle.isSettled(), false)
			task:chunk("late while terminating", "")
			helpers.assert_eq(chunks, 1)
			task:complete(15, "", "")
			helpers.assert_true(handle.isSettled())
			helpers.assert_eq(terminals, 1)
		end)
	end)

	helpers.it("replays committed synchronous chunks before their buffered terminal",
		function()
			with_runner(function(ShellRunner, native)
				native.start_chunk = true
				native.start_completion = true
				local events = {}
				local handle = ShellRunner.spawn("/fixture/stream-order", {},
					function() events[#events + 1] = "done" end,
					function()
						events[#events + 1] = "chunk"
						return true
					end)

				helpers.assert_true(handle.start())
				helpers.assert_eq(events, { "chunk", "done" })
				helpers.assert_true(handle.isSettled())
			end)
		end)

	helpers.it("fences a synchronous chunk delivered after the buffered terminal",
		function()
			with_runner(function(ShellRunner, native)
				native.start_completion = true
				native.start_completion_before_chunk = true
				native.start_chunk = true
				local chunks = 0
				local terminals = 0
				local handle = ShellRunner.spawn("/fixture/terminal-first", {},
					function() terminals = terminals + 1 end,
					function()
						chunks = chunks + 1
						return true
					end)

				helpers.assert_true(handle.start())
				helpers.assert_eq(native.start_chunk_return, true)
				helpers.assert_eq(chunks, 0)
				helpers.assert_eq(terminals, 1)
				helpers.assert_true(handle.isSettled())
			end)
		end)

	for _, start_mode in ipairs({ "false", "nil", "throw" }) do
		for _, terminate_mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("retains one exact task for " .. start_mode .. " start x "
				.. terminate_mode .. " terminate", function()
				with_runner(function(ShellRunner, native)
					native.start_mode = start_mode
					native.terminate_mode = terminate_mode
					local business_terminals = 0
					local handle = ShellRunner.spawn("/fixture/bin", {}, function()
						business_terminals = business_terminals + 1
					end)
					local task = native.tasks[1]

					helpers.assert_eq(handle.start(), false)
					helpers.assert_eq(task.start_calls, 1)
					helpers.assert_eq(task.terminate_calls, 1)
					helpers.assert_eq(handle.isSettled(), false)
					helpers.assert_eq(ShellRunner._active_tasks[task], true)
					helpers.assert_eq(business_terminals, 0)

					local settlement_observers = 0
					helpers.assert_true(handle.onSettled(function()
						settlement_observers = settlement_observers + 1
					end))
					helpers.assert_eq(handle.start(), false,
						"rollback debt must refuse a second native start")
					helpers.assert_eq(task.start_calls, 1)
					helpers.assert_eq(handle.terminate(), false)
					helpers.assert_eq(task.terminate_calls, 2,
						"cleanup retry must target the identical task")

					native.terminate_mode = "true"
					local accepted, state = handle.terminate()
					helpers.assert_true(accepted)
					helpers.assert_eq(state, "pending")
					helpers.assert_eq(handle.isSettled(), false)
					task:complete(15, "late", "")
					task:complete(15, "duplicate", "")
					helpers.assert_true(handle.isSettled())
					helpers.assert_eq(ShellRunner._active_tasks[task], nil)
					helpers.assert_eq(settlement_observers, 1)
					helpers.assert_eq(business_terminals, 0,
						"a refused start can never authorize business completion")

					helpers.assert_true(handle.onSettled(function()
						settlement_observers = settlement_observers + 1
					end))
					helpers.assert_eq(settlement_observers, 2,
						"already-settled observers run synchronously once")
				end)
			end)
		end
	end

	helpers.it("buffers synchronous completion until the start decision", function()
		with_runner(function(ShellRunner, native)
			native.start_completion = true
			native.start_mode = "false"
			local terminals = 0
			local handle = ShellRunner.spawn("/fixture/refused", {}, function()
				terminals = terminals + 1
			end)
			helpers.assert_eq(handle.start(), false)
			helpers.assert_true(handle.isSettled())
			helpers.assert_eq(terminals, 0)

			native.start_mode = "true"
			local committed_terminals = 0
			local committed = ShellRunner.spawn("/fixture/committed", {}, function()
				committed_terminals = committed_terminals + 1
			end)
			helpers.assert_true(committed.start())
			helpers.assert_true(committed.isSettled())
			helpers.assert_eq(committed_terminals, 1)
		end)
	end)

	helpers.it("lets synchronous exact rollback settlement win every refusal shape", function()
		for _, start_mode in ipairs({ "false", "nil", "throw" }) do
			for _, terminate_mode in ipairs({ "false", "nil", "throw" }) do
				with_runner(function(ShellRunner, native)
					native.start_mode = start_mode
					native.terminate_mode = terminate_mode
					native.terminate_completion = true
					local terminals = 0
					local handle = ShellRunner.spawn("/fixture/sync-rollback", {}, function()
						terminals = terminals + 1
					end)
					helpers.assert_eq(handle.start(), false)
					helpers.assert_true(handle.isSettled())
					helpers.assert_eq(native.tasks[1].terminate_calls, 1)
					helpers.assert_eq(terminals, 0)
				end)
			end
		end
	end)

	helpers.it("releases a refused start only after exact not-running proof", function()
		with_runner(function(ShellRunner, native)
			native.start_mode = "nil"
			native.start_running = false
			native.terminate_mode = "throw"
			local terminals = 0
			local handle = ShellRunner.spawn("/fixture/clean-refusal", {}, function()
				terminals = terminals + 1
			end)
			local task = native.tasks[1]
			helpers.assert_eq(handle.start(), false)
			helpers.assert_eq(task.terminate_calls, 0)
			helpers.assert_true(handle.isSettled())
			helpers.assert_eq(ShellRunner._active_tasks[task], nil)
			task:complete(0, "hostile late terminal", "")
			helpers.assert_eq(terminals, 0)
		end)
	end)

	helpers.it("contains synchronous terminate completion and observer reentrance", function()
		with_runner(function(ShellRunner, native)
			local business_terminals = 0
			local handle = ShellRunner.spawn("/fixture/live", {}, function()
				business_terminals = business_terminals + 1
			end)
			helpers.assert_true(handle.start())
			local observations = 0
			handle.onSettled(function()
				observations = observations + 1
				handle.onSettled(function() observations = observations + 1 end)
			end)
			native.terminate_completion = true
			local accepted, state = handle.terminate()
			helpers.assert_true(accepted)
			helpers.assert_eq(state, "settled")
			helpers.assert_eq(observations, 2)
			helpers.assert_eq(business_terminals, 1)
			native.tasks[1]:complete(15, "duplicate", "")
			helpers.assert_eq(observations, 2)
			helpers.assert_eq(business_terminals, 1)
		end)
	end)

	for _, terminate_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("reports settled when committed terminate " .. terminate_mode
			.. " follows synchronous completion", function()
			with_runner(function(ShellRunner, native)
				native.terminate_mode = terminate_mode
				native.terminate_completion = true
				local terminals = 0
				local handle = ShellRunner.spawn("/fixture/sync-terminate", {}, function()
					terminals = terminals + 1
				end)
				helpers.assert_true(handle.start())
				local accepted, state = handle.terminate()
				helpers.assert_true(accepted)
				helpers.assert_eq(state, "settled")
				helpers.assert_true(handle.isSettled())
				helpers.assert_eq(terminals, 1)
			end)
		end)
	end

	helpers.it("returns exact refusal handles from open and applescript", function()
		with_runner(function(ShellRunner, native)
			native.start_mode = "false"
			native.terminate_mode = "false"
			local open_terminals = 0
			local open_started, open_handle = ShellRunner.open("/fixture/path", function()
				open_terminals = open_terminals + 1
			end)
			helpers.assert_eq(open_started, false)
			helpers.assert_true(type(open_handle) == "table")
			helpers.assert_eq(open_handle.isSettled(), false)
			helpers.assert_eq(open_terminals, 1)

			local apple_terminals = 0
			local apple_started, apple_handle = ShellRunner.applescript("return 1", function()
				apple_terminals = apple_terminals + 1
			end)
			helpers.assert_eq(apple_started, false)
			helpers.assert_true(type(apple_handle) == "table")
			helpers.assert_eq(apple_handle.isSettled(), false)
			helpers.assert_eq(apple_terminals, 1)

			local invalid_started, invalid_handle = ShellRunner.open("")
			helpers.assert_eq(invalid_started, false)
			helpers.assert_eq(invalid_handle, nil)
		end)
	end)
end)
