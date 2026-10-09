--- tests/unit/adapters/test_shell_runner_run_async.lua

--- ==============================================================================
--- MODULE: Asynchronous Child Processes (Linux)
--- DESCRIPTION:
--- shell_runner.run_async runs a program without a shell and without blocking
--- the event loop that reads the grabbed keyboard (the diagnostics probes run
--- kanata and df through it). Driven over a fake libuv:
--- 1. without libuv it refuses instead of falling back to a blocking call;
--- 2. it answers once, after the child exited and both pipes ended;
--- 3. its deadline stops the child's whole process group and answers
---    "timeout" once, and a late exit adds nothing;
--- 4. a cancelled run stops the group and answers nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A libuv double that records the child it starts.
--- @param config string|table|nil Spawn error or explicit simulated admission refusal.
--- @return table luv, table state
local function fake_luv(config)
	local options = type(config) == "table" and config or { spawn_error = config }
	local state = { kills = {}, handles = {}, allocations = 0, spawns = 0, reads = 0 }
	local luv = {}
	local function handle(kind)
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end
	local function refusal()
		if options.refusal == "raised" then error("explicitly simulated native admission failure") end
		if options.refusal == "false" then return false, "simulated admission refusal" end
		return nil, "simulated admission refusal"
	end
	local function allocate(kind)
		state.allocations = state.allocations + 1
		if options.allocation_at == state.allocations then return refusal() end
		return handle(kind)
	end
	function luv.new_pipe() return allocate("pipe") end
	function luv.update_time() end -- native void-style clock refresh
	function luv.new_timer() state.timer = allocate("timer"); return state.timer end
	function luv.timer_start(timer, timeout_ms, _, callback)
		if options.start == "timer" then return refusal() end
		timer.timeout_ms, timer.callback = timeout_ms, callback
		return 0
	end
	function luv.timer_stop(timer) timer.stopped = true; return true end
	function luv.read_start(pipe, callback)
		state.reads = state.reads + 1
		if (options.start == "stdout" and state.reads == 1)
			or (options.start == "stderr" and state.reads == 2) then return refusal() end
		pipe.read_callback = callback
		return 0
	end
	function luv.read_stop(pipe) pipe.stopped = true; return true end
	function luv.is_closing(value) return value.closing end
	function luv.close(value) value.closing = true end
	function luv.kill(pid, signal) state.kills[#state.kills + 1] = { pid = pid, signal = signal }; return true end
	function luv.spawn(command, spawn_options, on_exit)
		state.spawns = state.spawns + 1
		state.command, state.options, state.on_exit = command, spawn_options, on_exit
		if options.spawn_error then return nil, options.spawn_error end
		state.process = handle("process")
		return state.process, 4321
	end
	function state.stdout(chunk) state.options.stdio[2].read_callback(nil, chunk) end
	function state.finish(code, signal)
		state.options.stdio[2].read_callback(nil, nil)
		state.options.stdio[3].read_callback(nil, nil)
		state.on_exit(code, signal or 0)
	end
	return luv, state
end

--- Loads a fresh runner against a libuv double, or without libuv.
--- @param luv table|nil
--- @return table runner
local function fresh_runner(luv)
	local previous_luv, previous_preload = package.loaded["luv"], package.preload["luv"]
	local previous_runner = package.loaded["adapters.shell_runner"]
	package.loaded["luv"] = luv
	if not luv then package.preload["luv"] = function() error("no libuv here") end end
	package.loaded["adapters.shell_runner"] = nil
	local runner = require("adapters.shell_runner")
	package.loaded["luv"], package.preload["luv"] = previous_luv, previous_preload
	package.loaded["adapters.shell_runner"] = previous_runner
	return runner
end

helpers.describe("shell_runner.run_async (linux)", function()
	for _, receipt in ipairs({ "nil", "false", "raised" }) do
		for allocation = 1, 3 do
			helpers.it("linux-shell-async-admission: allocation " .. allocation .. " " .. receipt .. " refuses without losing earlier handles", function()
				local luv, state = fake_luv({ allocation_at = allocation, refusal = receipt })
				local runner, callbacks = fresh_runner(luv), 0
				local returned, token, reason = pcall(runner.run_async, "df", {}, { timeout_ms = 1000 },
					function() callbacks = callbacks + 1 end)
				helpers.assert_true(returned, "explicit constructor refusal must not escape the admission transaction")
				helpers.assert_nil(token)
				helpers.assert_contains(reason, "allocation")
				helpers.assert_eq(callbacks, 0)
				helpers.assert_eq(state.spawns, 0, "constructor refusal must precede child dispatch")
				helpers.assert_eq(#state.handles, allocation - 1, "fixture must acquire every preceding native allocation")
				for _, value in ipairs(state.handles) do helpers.assert_true(value.closing, "earlier allocation was lost") end
			end)
		end
		for _, operation in ipairs({ "timer", "stdout", "stderr" }) do
			helpers.it("linux-shell-async-admission: " .. operation .. " " .. receipt .. " refuses once and retires the acquired run", function()
				local luv, state = fake_luv({ start = operation, refusal = receipt })
				local runner, callbacks = fresh_runner(luv), 0
				local returned, token, reason = pcall(runner.run_async, "df", {}, { timeout_ms = 1000 },
					function() callbacks = callbacks + 1 end)
				helpers.assert_true(returned, "explicit start refusal must stay inside the admission transaction")
				helpers.assert_nil(token)
				helpers.assert_contains(reason, "activation failed")
				helpers.assert_eq(callbacks, 0, "nil/error and callback must not report the same refusal twice")
				helpers.assert_true(state.timer.stopped)
				if operation == "timer" then
					helpers.assert_eq(state.spawns, 0)
					helpers.assert_eq(#state.handles, 3)
					helpers.assert_eq(#state.kills, 0)
				else
					helpers.assert_eq(state.spawns, 1)
					helpers.assert_eq(#state.handles, 4)
					helpers.assert_eq(state.reads, operation == "stdout" and 1 or 2, "stop admission at the failed reader")
					helpers.assert_eq(state.kills, {
						{ pid = -4321, signal = "sigterm" }, { pid = -4321, signal = "sigkill" },
					})
					helpers.assert_eq(state.process.closing, false, "a started child must remain owned until its late exit")
					state.on_exit(0, 0)
					helpers.assert_true(state.process.closing)
					state.on_exit(0, 0)
					helpers.assert_eq(callbacks, 0, "late exit must preserve the silent refusal")
				end
				for _, value in ipairs(state.handles) do helpers.assert_true(value.closing, "admission left an owned handle") end
			end)
		end
	end

	if pcall(require, "luv") and package.config:sub(1, 1) == "/" then
		helpers.it("linux-shell-async-admission: actual children and handles retire on five explicit native refusal seams", function()
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_shell_async_admission.lua"
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native ShellRunner admission fixture must pass")
		end)
	end

	helpers.it("refuses a failed spawn without calling back (linux-spawn-refusal-once)", function()
		local luv, state = fake_luv("ENOENT: no such file or directory")
		local runner = fresh_runner(luv)
		local answers = 0
		local handle, err = runner.run_async("missing-program", {}, { timeout_ms = 1000 },
			function() answers = answers + 1 end)
		helpers.assert_nil(handle)
		helpers.assert_eq(answers, 0, "the caller handles a refused dispatch through the return value")
		helpers.assert_contains(err, "ENOENT", "the refusal must retain libuv's cause")
		helpers.assert_true(state.timer.stopped)
		helpers.assert_true(state.timer.closing)
		helpers.assert_true(state.options.stdio[2].closing)
		helpers.assert_true(state.options.stdio[3].closing)
	end)

	helpers.it("refuses without libuv instead of blocking the event loop", function()
		local runner = fresh_runner(nil)
		helpers.assert_eq(runner.HAS_ASYNC, false)
		local called = false
		local handle, err = runner.run_async("df", { "-Pk", "/tmp" }, { timeout_ms = 1000 },
			function() called = true end)
		helpers.assert_nil(handle)
		helpers.assert_contains(err, "libuv")
		helpers.assert_eq(called, false)
	end)

	helpers.it("answers once with the output after the child exited and both pipes ended", function()
		local luv, state = fake_luv()
		local runner = fresh_runner(luv)
		local answers = {}
		local handle = runner.run_async("kanata", { "--version" }, { timeout_ms = 4000 },
			function(result) answers[#answers + 1] = result end)
		helpers.assert_true(handle ~= nil)
		helpers.assert_eq(state.command, "kanata")
		helpers.assert_eq(state.options.args, { "--version" })
		helpers.assert_eq(state.timer.timeout_ms, 4000)
		state.stdout("kanata 1.7.0\n")
		helpers.assert_eq(#answers, 0, "nothing is answered before the child exits")
		state.finish(0)
		helpers.assert_eq(#answers, 1)
		helpers.assert_eq(answers[1].ok, true)
		helpers.assert_eq(answers[1].stdout, "kanata 1.7.0\n")
	end)

	helpers.it("stops the process group at its deadline and answers timeout once", function()
		local luv, state = fake_luv()
		local runner = fresh_runner(luv)
		local answers = {}
		runner.run_async("df", { "-Pk", "/tmp" }, { timeout_ms = 10 }, function(result) answers[#answers + 1] = result end)
		state.timer.callback()
		helpers.assert_eq(state.kills, {
			{ pid = -4321, signal = "sigterm" },
			{ pid = -4321, signal = "sigkill" },
		})
		helpers.assert_eq(#answers, 1)
		helpers.assert_eq(answers[1].error, "timeout")
		state.finish(143)
		helpers.assert_eq(#answers, 1, "a late exit must not answer a second time")
	end)

	helpers.it("a cancelled run stops the group and answers nothing", function()
		local luv, state = fake_luv()
		local runner = fresh_runner(luv)
		local answers = 0
		local handle = runner.run_async("df", { "-Pk", "/tmp" }, { timeout_ms = 1000 }, function() answers = answers + 1 end)
		handle.cancel()
		helpers.assert_eq(state.kills, {
			{ pid = -4321, signal = "sigterm" },
			{ pid = -4321, signal = "sigkill" },
		})
		state.finish(143)
		helpers.assert_eq(answers, 0)
	end)

	helpers.it("forces group retirement after SIGTERM (linux-sigterm-resistant-child)", function()
		local luv, state = fake_luv()
		local runner = fresh_runner(luv)
		runner.run_async("sh", { "-c", "trap '' TERM; sleep 30" }, { timeout_ms = 10 }, function() end)
		state.timer.callback()
		helpers.assert_eq(state.kills[2], { pid = -4321, signal = "sigkill" },
			"the deadline must also retire a SIGTERM-resistant process")
		state.finish(0)
	end)

	helpers.it("reports a signalled child as failed (linux-signalled-child-exit)", function()
		local luv, state = fake_luv()
		local runner = fresh_runner(luv)
		local answers = {}
		runner.run_async("python3", {}, { timeout_ms = 1000 },
			function(result) answers[#answers + 1] = result end)
		state.finish(0, 15)
		helpers.assert_eq(#answers, 1)
		helpers.assert_eq(answers[1].ok, false, "libuv's zero exit code cannot hide SIGTERM")
		helpers.assert_eq(answers[1].code, 143)
		helpers.assert_contains(answers[1].error, "143")
	end)

	helpers.it("stops descendants after their leader exits (linux-orphaned-process-group)", function()
		local luv, state = fake_luv()
		local runner = fresh_runner(luv)
		local answers = {}
		runner.run_async("sh", { "-c", "sleep 30 &" }, { timeout_ms = 10 },
			function(result) answers[#answers + 1] = result end)
		state.on_exit(0, 0)
		helpers.assert_eq(#answers, 0, "the descendant still owns the pipes")
		state.timer.callback()
		helpers.assert_eq(state.kills[1], { pid = -4321, signal = "sigterm" },
			"a reaped leader does not mean the process group is empty")
		helpers.assert_eq(#answers, 1)
		helpers.assert_eq(answers[1].error, "timeout")
		state.finish(0)
		helpers.assert_eq(#answers, 1, "late EOF must not publish twice")
	end)

	helpers.it("cancels descendants after their leader exits (linux-orphaned-process-group)", function()
		local luv, state = fake_luv()
		local runner = fresh_runner(luv)
		local answers = 0
		local handle = runner.run_async("sh", { "-c", "sleep 30 &" }, { timeout_ms = 1000 },
			function() answers = answers + 1 end)
		state.on_exit(0, 0)
		handle.cancel()
		helpers.assert_eq(state.kills[1], { pid = -4321, signal = "sigterm" })
		state.finish(0)
		helpers.assert_eq(answers, 0)
	end)

	helpers.it("refuses a run without a positive deadline", function()
		local luv = fake_luv()
		local runner = fresh_runner(luv)
		local handle, err = runner.run_async("df", {}, {}, function() end)
		helpers.assert_nil(handle)
		helpers.assert_contains(err, "timeout_ms")
	end)
end)
