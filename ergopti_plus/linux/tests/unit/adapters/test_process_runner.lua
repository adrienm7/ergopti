--- tests/unit/adapters/test_process_runner.lua

--- ==============================================================================
--- MODULE: Asynchronous Process Runner
--- DESCRIPTION:
--- The .keylayout converter runs through adapters/process_runner so the daemon,
--- which owns the grabbed keyboard, never waits on it (layout-registry-convert).
--- Driven through a controllable libuv double, these tests prove the run is
--- dispatched without blocking, reports its exit code and output once, tells a
--- program that cannot start (ENOENT) from one that fails, kills the process
--- group at its deadline, and refuses an ill-typed argument vector before
--- spawning anything.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Creates the minimum libuv process/pipe/timer surface the runner uses.
--- @param config table|nil { spawn_error?, refuse?, refusal?, refresh_error? }
--- @return table fake, table state
local function fake_luv(config)
	local options = config or {}
	local state = { kills = {}, spawns = {}, reads = 0, handles = {} }
	local fake = {}

	local function handle(kind)
		if options.allocation_nil_at == #state.handles + 1 then return nil end
		if options.allocation_failure_at == #state.handles + 1 then error("simulated allocation exception") end
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end

	function fake.new_pipe() return handle("pipe") end
	function fake.update_time() -- native void-style clock refresh; explicit simulated exception
		if options.refresh_error then error("simulated clock refresh failure") end
	end
	function fake.new_timer()
		state.timer = handle("timer")
		return state.timer
	end
	function fake.timer_start(timer, timeout_ms, repeat_ms, callback)
		if options.refuse == "timer" then return options.refusal, "simulated timer refusal", "EINVAL" end
		timer.timeout_ms = timeout_ms
		timer.callback = callback
		return 0
	end
	function fake.timer_stop(timer) timer.stopped = true; return true end
	function fake.read_start(pipe, callback)
		state.reads = state.reads + 1
		if (options.refuse == "stdout" and state.reads == 1)
			or (options.refuse == "stderr" and state.reads == 2) then
			return options.refusal, "simulated stream refusal", "EINVAL"
		end
		pipe.read_callback = callback
		return 0
	end
	function fake.read_stop(pipe) pipe.read_stopped = true; return true end
	function fake.is_closing(value) return value.closing end
	function fake.close(value) value.closing = true end
	function fake.kill(pid, signal)
		state.kills[#state.kills + 1] = { pid = pid, signal = signal }
		return true
	end
	function fake.spawn(program, spawn_options, callback)
		state.spawns[#state.spawns + 1] = { program = program, options = spawn_options }
		if options.spawn_error then return nil, options.spawn_error, "ENOENT" end
		state.options = spawn_options
		state.exit_callback = callback
		return handle("process"), 7001
	end

	function state.stdout(chunk) state.options.stdio[2].read_callback(nil, chunk) end
	function state.stderr(chunk) state.options.stdio[3].read_callback(nil, chunk) end
	function state.finish(code, signal)
		state.stdout(nil)
		state.stderr(nil)
		state.exit_callback(code, signal or 0)
	end
	return fake, state
end

--- Loads a fresh runner against one fake libuv instance.
--- @param config table|nil
--- @return table runner, table state
local function fresh_runner(config)
	local fake, state = fake_luv(config)
	local previous_luv = package.loaded["luv"]
	local previous = package.loaded["adapters.process_runner"]
	package.loaded["luv"] = fake
	package.loaded["adapters.process_runner"] = nil
	local runner = require("adapters.process_runner")
	package.loaded["luv"] = previous_luv
	package.loaded["adapters.process_runner"] = previous
	return runner, state
end

--- Runs one program and collects its terminal results.
local function start(runner, program, args, options)
	local results = {}
	local dispatched = runner.run(program, args, options, function(result)
		results[#results + 1] = result
	end)
	return dispatched, results
end

helpers.describe("process_runner: asynchronous argv processes", function()
	if pcall(require, "luv") and package.config:sub(1, 1) == "/" then
		helpers.it("linux-process-allocation: actual partial handles retire before refusal returns", function()
			local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
			local fixture = helpers.driver_root() .. "/tests/fixtures/native_process_allocations.lua"
			local result = os.execute(quote(assert(arg[-1])) .. " " .. quote(fixture))
			helpers.assert_true(result == true or result == 0, "native process allocation fixture must pass")
		end)
	end
	for _, mode in ipairs({ "raised", "nil" }) do
		for slot = 1, 3 do
			helpers.it("linux-process-allocation: " .. mode .. " constructor at " .. slot .. " releases prior handles", function()
				local config = {}
				config[mode == "raised" and "allocation_failure_at" or "allocation_nil_at"] = slot
				local runner, state = fresh_runner(config)
				local dispatched, results = start(runner, "python3", {}, {})
				helpers.assert_eq(dispatched, false)
				helpers.assert_eq(#results, 1)
				helpers.assert_eq(results[1].exit_code, -1)
				helpers.assert_eq(results[1].stdout, "")
				helpers.assert_eq(results[1].stderr, "")
				helpers.assert_eq(results[1].error, "libuv handle allocation failed")
				helpers.assert_true(results[1].not_found ~= true)
				helpers.assert_eq(#state.spawns, 0)
				helpers.assert_eq(state.reads, 0)
				helpers.assert_eq(#state.kills, 0)
				helpers.assert_eq(#state.handles, slot - 1)
				for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closing, "partial allocation must close") end
			end)
		end
	end

	for _, operation in ipairs({ "timer", "stdout", "stderr" }) do
		for _, receipt in ipairs({ "nil", "false" }) do
			helpers.it("linux-process-supervision: returned " .. receipt .. " from " .. operation .. " refuses dispatch once", function()
				local config = { refuse = operation }
				if receipt == "false" then config.refusal = false end
				local runner, state = fresh_runner(config)
				local dispatched, results = start(runner, "python3", {}, { timeout_ms = 100 })
				helpers.assert_eq(dispatched, false)
				helpers.assert_eq(#results, 1)
				helpers.assert_eq(results[1].exit_code, -1)
				helpers.assert_eq(results[1].error, "process supervision could not start")
				helpers.assert_eq(state.kills, { { pid = -7001, signal = "sigterm" }, { pid = -7001, signal = "sigkill" } })
				helpers.assert_true(state.timer.closing)
				helpers.assert_true(state.options.stdio[2].closing)
				helpers.assert_true(state.options.stdio[3].closing)
				state.exit_callback(0, 0)
				helpers.assert_eq(#results, 1, "late exit must not publish the refusal twice")
			end)
		end
	end

	helpers.it("linux-relative-clock: simulated refresh exception retires the owned child and handles", function()
		local runner, state = fresh_runner({ refresh_error = true })
		local dispatched, results = start(runner, "python3", { "slow.py" }, {})
		helpers.assert_eq(dispatched, false)
		helpers.assert_eq(#results, 1)
		helpers.assert_contains(results[1].error, "supervision could not start")
		helpers.assert_eq(state.kills, {
			{ pid = -7001, signal = "sigterm" },
			{ pid = -7001, signal = "sigkill" },
		})
		helpers.assert_true(state.timer.closing)
		helpers.assert_true(state.options.stdio[2].closing and state.options.stdio[3].closing)
		state.finish(0)
		helpers.assert_eq(#results, 1, "late native exit cannot publish twice")
	end)

	helpers.it("dispatches without waiting and reports the exit code and output once (layout-registry-convert)", function()
		local runner, state = fresh_runner()
		local dispatched, results = start(runner, "python3", { "-c", "print(1)" }, { timeout_ms = 5000 })
		helpers.assert_true(dispatched, "the child must be started")
		helpers.assert_eq(#results, 0, "nothing is reported before the child ends")
		helpers.assert_eq(state.spawns[1].program, "python3")
		helpers.assert_eq(state.spawns[1].options.args[2], "print(1)", "the argument vector reaches execve as given")
		helpers.assert_true(state.spawns[1].options.detached, "the child leads its own process group")
		helpers.assert_eq(state.timer.timeout_ms, 5000)
		state.stdout("1\n")
		state.stderr("warning\n")
		state.finish(0)
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].exit_code, 0)
		helpers.assert_eq(results[1].stdout, "1\n")
		helpers.assert_eq(results[1].stderr, "warning\n")
		helpers.assert_nil(results[1].error, "exit code 0 is a success")
		state.finish(0)
		helpers.assert_eq(#results, 1, "a late libuv callback must be inert")
	end)

	helpers.it("reports a failing program with its exit code (layout-registry-convert)", function()
		local runner, state = fresh_runner()
		local _, results = start(runner, "python3", { "convert.py" }, {})
		state.stderr("Traceback\n")
		state.finish(3)
		helpers.assert_eq(results[1].exit_code, 3)
		helpers.assert_contains(results[1].error, "exited with code 3")
		helpers.assert_eq(results[1].stderr, "Traceback\n")
		helpers.assert_true(results[1].not_found ~= true)
	end)

	helpers.it("reports a signalled child as failed (linux-signalled-child-exit)", function()
		local runner, state = fresh_runner()
		local _, results = start(runner, "python3", {}, {})
		state.finish(0, 15)
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].exit_code, 143, "libuv's zero exit code cannot hide SIGTERM")
		helpers.assert_contains(results[1].error, "143")
	end)

	helpers.it("tells a program that cannot start from one that fails (layout-registry-convert)", function()
		local runner = fresh_runner({ spawn_error = "ENOENT: no such file or directory" })
		local dispatched, results = start(runner, "python3", { "--version" }, {})
		helpers.assert_true(dispatched == false)
		helpers.assert_eq(#results, 1)
		helpers.assert_true(results[1].not_found, "ENOENT means the program is not installed")
		helpers.assert_contains(results[1].error, "cannot start python3")
	end)

	helpers.it("kills the process group at its deadline (layout-registry-convert)", function()
		local runner, state = fresh_runner()
		local _, results = start(runner, "python3", { "slow.py" }, { timeout_ms = 10 })
		state.timer.callback()
		helpers.assert_eq(#results, 1)
		helpers.assert_contains(results[1].error, "did not finish")
		helpers.assert_eq(state.kills[1].pid, -7001, "the whole group is signalled")
		state.finish(0)
		helpers.assert_eq(#results, 1, "the late exit must not publish a second result")
	end)

	helpers.it("refuses an ill-typed argument vector before spawning (layout-registry-convert)", function()
		local runner, state = fresh_runner()
		local dispatched, results = start(runner, "python3", { "--timeout", 5 }, {})
		helpers.assert_true(dispatched == false)
		helpers.assert_contains(results[1].error, "argument 2")
		helpers.assert_eq(#state.spawns, 0, "a refusal must cost no process")
	end)

	helpers.it("kills descendants after their leader exits (linux-orphaned-process-group)", function()
		local runner, state = fresh_runner()
		local _, results = start(runner, "sh", { "-c", "sleep 30 &" }, { timeout_ms = 10 })
		state.exit_callback(0, 0)
		helpers.assert_eq(#results, 0, "the descendant still owns the pipes")
		state.timer.callback()
		helpers.assert_eq(state.kills, {
			{ pid = -7001, signal = "sigterm" },
			{ pid = -7001, signal = "sigkill" },
		}, "a reaped leader does not mean the process group is empty")
		helpers.assert_eq(#results, 1)
		helpers.assert_contains(results[1].error, "did not finish")
		state.finish(0)
		helpers.assert_eq(#results, 1, "late EOF must not publish twice")
	end)
end)
