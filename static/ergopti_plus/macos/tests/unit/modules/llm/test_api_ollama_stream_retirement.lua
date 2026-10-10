--- tests/unit/modules/llm/test_api_ollama_stream_retirement.lua

--- ==============================================================================
--- MODULE: Ollama streaming retirement ownership regressions
--- DESCRIPTION:
--- Drives the production controller and ShellRunner with controlled native task
--- ports. Accepted termination is pending until the exact task completes.
--- ==============================================================================

local helpers = require("tests.helpers")

local function upvalue(fn, target)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if name == target then return value end
		if not name then break end
	end
	error("missing production upvalue: " .. target)
end

local function exists(path)
	local file = io.open(path, "r")
	if not file then return false end
	file:close()
	return true
end

local function with_stream(callback)
	helpers.with_stub_scope({ "modules.llm.api_ollama", "adapters.shell_runner" }, function()
		local api = helpers.load_with_stubs("modules.llm.api_ollama")
		local stream = upvalue(api.fetch_batch, "post_and_parse_streaming")
		local runner = upvalue(stream, "ShellRunner")
		local scheduler = upvalue(stream, "TimerScheduler")
		local original_new = hs.task.new
		local original_spawn = runner.spawn
		local original_after = scheduler.after
		local fixture = { tasks = {}, handles = {}, business_done = {}, timers = {}, failures = 0,
			successes = 0, partials = 0, start_mode = "true" }

		hs.task.new = function(_, done, _, args)
			local environment = { HOME = "/Users/fixture" }
			local task = { done = done, running = false, terminate_calls = 0 }
			for index, arg in ipairs(args) do
				if arg == "--data-binary" then task.payload = args[index + 1]:sub(2) end
			end
			function task:environment() return environment end
			function task:setEnvironment(value) environment = value; return self end
			function task:isRunning() return self.running end
			function task:start()
				self.running = true
				if fixture.start_mode == "false" then return false end
				if fixture.start_mode == "throw" then error("CONTROLLED_START_REFUSAL") end
				return self
			end
			function task:terminate()
				self.terminate_calls = self.terminate_calls + 1
				return self
			end
			function task:complete(code)
				self.running = false
				self.done(code or 15, "", "")
			end
			fixture.tasks[#fixture.tasks + 1] = task
			return task
		end
		runner.spawn = function(executable, args, done, chunk)
			fixture.business_done[#fixture.business_done + 1] = done
			local handle = original_spawn(executable, args, done, chunk)
			fixture.handles[#fixture.handles + 1] = handle
			return handle
		end
		scheduler.after = function(_, timer)
			fixture.timers[#fixture.timers + 1] = timer
			return { timer = {} }, true
		end
		function fixture.request()
			stream("fixture-model", "", "typed context", "", 0.2, 8, 1, false,
				function() fixture.successes = fixture.successes + 1 end,
				function() fixture.failures = fixture.failures + 1 end, {},
				function() fixture.partials = fixture.partials + 1 end)
		end
		function fixture.slot() return upvalue(api.cancel_streaming, "_active_stream_task") end
		local outcome = table.pack(xpcall(function() callback(api, fixture) end, debug.traceback))
		-- Retire the exact controlled tasks even when a regression assertion fails.
		for _, task in ipairs(fixture.tasks) do
			if task.running then task:complete() end
			if task.payload and exists(task.payload) then os.remove(task.payload) end
		end
		hs.task.new = original_new
		runner.spawn = original_spawn
		scheduler.after = original_after
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("Ollama stream retirement ownership", function()
	helpers.it("(stream-pending-retirement) retains the task and payload until exact completion", function()
		with_stream(function(api, fixture)
			fixture.request()
			local task, handle = fixture.tasks[1], fixture.handles[1]
			helpers.assert_true(exists(task.payload))
			helpers.assert_eq(api.cancel_streaming(), false)
			helpers.assert_eq(fixture.slot(), handle)
			helpers.assert_eq(handle.isSettled(), false)
			fixture.request()
			helpers.assert_eq(#fixture.tasks, 1, "pending retirement must fence successor acquisition")
			helpers.assert_eq(fixture.failures, 1)
			fixture.timers[1]()
			helpers.assert_true(exists(task.payload), "the original cleanup clock cannot erase live input")
			task:complete()
			helpers.assert_true(handle.isSettled())
			helpers.assert_eq(fixture.slot(), nil)
			helpers.assert_eq(exists(task.payload), false)
			helpers.assert_eq(fixture.failures, 1, "a revoked generation cannot publish a late failure")
			helpers.assert_eq(fixture.successes, 0)
			helpers.assert_eq(fixture.partials, 0)
			fixture.request()
			helpers.assert_eq(#fixture.tasks, 2)
		end)
	end)

	helpers.it("(stream-premature-completion) refuses a callback before original physical settlement", function()
		with_stream(function(_, fixture)
			fixture.request()
			local task, handle = fixture.tasks[1], fixture.handles[1]
			fixture.business_done[1](0, "", "")
			helpers.assert_eq(handle.isSettled(), false)
			helpers.assert_eq(fixture.slot(), handle)
			helpers.assert_true(exists(task.payload))
			helpers.assert_eq(fixture.failures, 0)
			task:complete()
			helpers.assert_eq(fixture.slot(), nil)
			helpers.assert_eq(fixture.failures, 1)
		end)
	end)

	helpers.it("(stream-bare-termination) refuses bare true without a settlement receipt", function()
		with_stream(function(api, fixture)
			fixture.request()
			local handle = fixture.handles[1]
			handle.terminate = function() return true end
			helpers.assert_eq(api.cancel_streaming(), false)
			helpers.assert_eq(fixture.slot(), handle)
			helpers.assert_true(exists(fixture.tasks[1].payload))
		end)
	end)

	helpers.it("(stream-forged-settlement) rejects settled status while the original task remains live", function()
		with_stream(function(api, fixture)
			fixture.request()
			local handle = fixture.handles[1]
			handle.terminate = function() return true, "settled" end
			helpers.assert_eq(api.cancel_streaming(), false)
			helpers.assert_eq(handle.isSettled(), false)
			helpers.assert_eq(fixture.slot(), handle)
			helpers.assert_true(exists(fixture.tasks[1].payload))
		end)
	end)

	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("(stream-uncommitted-retirement) retains physical cleanup after " .. mode .. " start", function()
			with_stream(function(_, fixture)
				fixture.start_mode = mode
				fixture.request()
				local task, handle = fixture.tasks[1], fixture.handles[1]
				helpers.assert_eq(fixture.failures, 1)
				helpers.assert_eq(fixture.slot(), handle)
				helpers.assert_eq(handle.isSettled(), false)
				helpers.assert_true(exists(task.payload))
				fixture.request()
				helpers.assert_eq(#fixture.tasks, 1)
				task:complete()
				helpers.assert_true(handle.isSettled())
				helpers.assert_eq(fixture.slot(), nil, "settlement observer cleans up suppressed business completion")
				helpers.assert_eq(exists(task.payload), false)
				helpers.assert_eq(fixture.failures, 2)
			end)
		end)
	end

	helpers.it("(stream-stale-completion) cannot release a successor from an old callback", function()
		with_stream(function(api, fixture)
			fixture.request()
			api.cancel_streaming()
			fixture.tasks[1]:complete()
			fixture.request()
			local successor = fixture.handles[2]
			fixture.business_done[1](15, "", "")
			helpers.assert_eq(fixture.slot(), successor)
			helpers.assert_true(exists(fixture.tasks[2].payload))
			helpers.assert_eq(fixture.failures, 0)
		end)
	end)
end)
