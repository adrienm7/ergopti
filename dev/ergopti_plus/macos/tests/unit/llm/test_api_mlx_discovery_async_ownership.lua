--- tests/unit/llm/test_api_mlx_discovery_async_ownership.lua

--- ==============================================================================
--- MODULE: MLX Discovery Async Ownership Regression Tests
--- DESCRIPTION:
--- Proves that timer/task construction failures close the current discovery
--- cycle transactionally. Every queued caller must be answered exactly once,
--- and a later caller must be able to start a fresh cycle instead of waiting
--- forever behind an in-flight latch whose native work never started.
--- ==============================================================================

local helpers = require("tests.helpers")

local function snapshot_modules()
	return {
		http_client = package.loaded["adapters.http_client"],
		shell_runner = package.loaded["adapters.shell_runner"],
		timer_scheduler = package.loaded["adapters.timer_scheduler"],
		discovery = package.loaded["modules.llm.api_mlx_discovery"],
		hs_module = package.loaded["hs"],
		global_hs = rawget(_G, "hs"),
	}
end


--- Loads the real discovery module against deterministic async adapters.
--- @param options table|nil Fault outcomes for scheduler and task starts.
--- @return table env Behavioral controls and observations.
local function make_env(options)
	options = options or {}
	local env = {
		now = 1000,
		next_timer_id = 0,
		schedule_calls = 0,
		start_calls = 0,
		terminate_calls = 0,
		timers = {},
		tasks = {},
	}

	package.loaded["adapters.timer_scheduler"] = {
		now = function() return env.now end,
		after = function(delay, callback)
			env.schedule_calls = env.schedule_calls + 1
			local outcome = (options.schedule_outcomes or {})[env.schedule_calls] or "success"
			if outcome == "throw" then error("SCHEDULER_THROW_" .. env.schedule_calls) end
			if outcome == "false" then
				env.next_timer_id = env.next_timer_id + 1
				-- A native arm failure still returns an opaque cancellation token;
				-- the explicit second result is the only ownership proof.
				return { id = env.next_timer_id }, false
			end

			env.next_timer_id = env.next_timer_id + 1
			-- The public TimerScheduler contract makes this token opaque. The fake's
			-- bookkeeping lives beside it so production cannot pass by inspecting
			-- adapter-private fields such as `timer` or `fired`.
			local handle = { id = env.next_timer_id }
			env.timers[#env.timers + 1] = {
				handle = handle,
				delay = delay,
				callback = callback,
				active = true,
			}
			return handle, true
		end,
		cancel = function(handle)
			for _, timer in ipairs(env.timers) do
				if timer.handle == handle then timer.active = false end
			end
			-- The port contract declares cancel() void.
			return nil
		end,
		activeCount = function()
			local count = 0
			for _, timer in ipairs(env.timers) do
				if timer.active then count = count + 1 end
			end
			return count
		end,
	}

	package.loaded["adapters.shell_runner"] = {
		spawn = function(_executable, _args, on_done)
			local task = { on_done = on_done }
			task.start = function()
				env.start_calls = env.start_calls + 1
				local outcome = (options.start_outcomes or {})[env.start_calls] or "success"
				if outcome == "throw" then error("TASK_START_THROW_" .. env.start_calls) end
				return outcome ~= "false"
			end
			task.terminate = function()
				env.terminate_calls = env.terminate_calls + 1
				return true
			end
			env.tasks[#env.tasks + 1] = task
			return task
		end,
	}

	package.loaded["adapters.http_client"] = {
		new = function()
			return {
				post = function(_url, _headers, _payload, callback)
					callback({ status = 404, body = "" })
				end,
			}
		end,
	}

	package.loaded["modules.llm.api_mlx_discovery"] = nil
	local discovery = helpers.load_with_stubs("modules.llm.api_mlx_discovery")
	discovery.init({ base_url = "http://127.0.0.1:8080" })
	env.discovery = discovery

	function env.fire_next_timer()
		for _, timer in ipairs(env.timers) do
			if timer.active then
				timer.active = false
				return pcall(timer.callback)
			end
		end
		return false, "no pending timer"
	end

	function env.pending_timer_count()
		local count = 0
		for _, timer in ipairs(env.timers) do
			if timer.active then count = count + 1 end
		end
		return count
	end

	function env.complete_task(index, exit_code, stdout)
		local task = assert(env.tasks[index], "missing task " .. tostring(index))
		return pcall(task.on_done, exit_code, stdout or "", "")
	end

	return env
end


--- Restores every shared module slot even when a behavioral assertion throws.
--- Explicit assignments are intentional: the suite-wide shell-runner hygiene
--- gate must be able to prove that the stub cannot leak into the next test file.
--- @param saved table Snapshot returned by snapshot_modules().
local function restore_modules(saved)
	package.loaded["adapters.http_client"] = saved.http_client
	package.loaded["adapters.shell_runner"] = saved.shell_runner
	package.loaded["adapters.timer_scheduler"] = saved.timer_scheduler
	package.loaded["modules.llm.api_mlx_discovery"] = saved.discovery
	package.loaded["hs"] = saved.hs_module
	_G.hs = saved.global_hs
end


--- Runs one fault scenario with finally-style package/global restoration.
--- @param options table Fault outcomes passed to make_env().
--- @param fn function Test body receiving the isolated environment.
local function with_env(options, fn)
	local saved = snapshot_modules()
	local ok, err = xpcall(function() fn(make_env(options)) end, debug.traceback)
	restore_modules(saved)
	if not ok then error(err, 0) end
end


--- Queues two original waiters; the first reproduces api_mlx.warmup() by
--- re-entering discover() from inside the completion fan-out.
--- @param env table Controlled environment.
--- @param callbacks table Mutable { original, retry } counters.
local function queue_reentrant_waiters(env, callbacks)
	env.discovery.discover(function()
		callbacks.original = callbacks.original + 1
		env.discovery.discover(function() callbacks.retry = callbacks.retry + 1 end)
	end)
	env.discovery.discover(function() callbacks.original = callbacks.original + 1 end)
end


--- Proves the re-entrant waiter owns exactly one fresh deferred retry, then
--- drives that retry through a normal 404 completion so its callback is visible.
--- @param env table Controlled environment.
--- @param callbacks table Mutable counters from queue_reentrant_waiters().
--- @param starts_before integer Task starts before firing the retry timer.
--- @param expected_schedule_calls integer Exact scheduler call count.
--- @param expected_original_before integer Original waiters answered synchronously.
local function assert_reentrant_retry_started(
	env, callbacks, starts_before, expected_schedule_calls, expected_original_before
)
	helpers.assert_eq(callbacks.original, expected_original_before,
		"the failed cycle must answer every original waiter already queued before retrying")
	helpers.assert_eq(env.pending_timer_count(), 1,
		"callback re-entry must own exactly one fresh deferred retry timer")
	helpers.assert_eq(env.schedule_calls, expected_schedule_calls,
		"callback fan-out must coalesce onto one retry schedule")

	local fired, fire_err = env.fire_next_timer()
	helpers.assert_true(fired, "the retry timer callback must be contained: " .. tostring(fire_err))
	helpers.assert_eq(env.start_calls, starts_before + 1,
		"the re-entrant retry must reach one new native task start")

	local completed, completion_err = env.complete_task(#env.tasks, 0, "{}")
	helpers.assert_true(completed,
		"the retry completion must remain contained: " .. tostring(completion_err))
	helpers.assert_eq(callbacks.original, 2,
		"an original waiter queued after a synchronous failure must join the retry cycle")
	helpers.assert_eq(callbacks.retry, 1,
		"the callback queued by the production-style re-entry must not be stranded")
end


helpers.describe("MLX discovery async ownership", function()
	for _, outcome in ipairs({ "false", "throw" }) do
		helpers.it("recovers and preserves callback fan-out when task start returns " .. outcome, function()
			with_env({ start_outcomes = { outcome, "success" } }, function(env)
				local callbacks = { original = 0, retry = 0 }
				queue_reentrant_waiters(env, callbacks)

				local fired, fire_err = env.fire_next_timer()
				helpers.assert_true(fired, "task start failure must not escape its timer: " .. tostring(fire_err))
				helpers.assert_eq(env.terminate_calls, 1,
					"the exact task whose start failed must be revoked before ownership is released")

				assert_reentrant_retry_started(env, callbacks, 1, 2, 2)
			end)
		end)
	end

	for _, outcome in ipairs({ "false", "throw" }) do
		helpers.it("recovers when the initial scheduler returns " .. outcome, function()
			with_env({ schedule_outcomes = { outcome, "success" } }, function(env)
				local callbacks = { original = 0, retry = 0 }
				-- Any escaped scheduler error fails with_env after it restores package.loaded.
				queue_reentrant_waiters(env, callbacks)
				assert_reentrant_retry_started(env, callbacks, 0, 2, 1)
			end)
		end)
	end

	for _, outcome in ipairs({ "false", "throw" }) do
		helpers.it("recovers and preserves callback fan-out when the rearm scheduler returns " .. outcome, function()
			with_env({ schedule_outcomes = { "success", outcome, "success" } }, function(env)
				local callbacks = { original = 0, retry = 0 }
				queue_reentrant_waiters(env, callbacks)
				helpers.assert_true(env.fire_next_timer())
				helpers.assert_eq(env.start_calls, 1, "the first poll task must start")

				local completed, completion_err = env.complete_task(1, 1, "")
				helpers.assert_true(completed,
					"rearm scheduler failure must be contained in task completion: " .. tostring(completion_err))

				assert_reentrant_retry_started(env, callbacks, 1, 3, 2)
			end)
		end)
	end

	helpers.it("bounds callback re-entry when the scheduler remains unavailable", function()
		with_env({ schedule_outcomes = { "false", "false", "success" } }, function(env)
			local callback_calls = 0
			local retry
			retry = function()
				callback_calls = callback_calls + 1
				env.discovery.discover(retry)
			end

			-- A stack overflow or escaped scheduler error fails with_env directly;
			-- the exact bounded counts below prove that execution returned normally.
			env.discovery.discover(retry)
			helpers.assert_eq(env.schedule_calls, 2,
				"one failed cycle may make one bounded recovery attempt, never an unbounded recursion")
			helpers.assert_eq(callback_calls, 2,
				"both bounded failed cycles must answer the production-style waiter")
			helpers.assert_eq(env.pending_timer_count(), 0,
				"a scheduler that rejected both attempts cannot own a timer")

			-- Once an external signal arrives after the scheduler recovers, the queued
			-- waiter and the new caller coalesce onto one live cycle.
			env.discovery.discover(function() end)
			helpers.assert_eq(env.schedule_calls, 3)
			helpers.assert_eq(env.pending_timer_count(), 1)
		end)
	end)

	helpers.it("continues callback fan-out when one waiting callback throws", function()
		with_env({ start_outcomes = { "false" } }, function(env)
			local second_callback_calls = 0
			env.discovery.discover(function() error("CALLBACK_THROW") end)
			env.discovery.discover(function() second_callback_calls = second_callback_calls + 1 end)

			local fired, fire_err = env.fire_next_timer()
			helpers.assert_true(fired, "a throwing waiter must remain contained: " .. tostring(fire_err))
			helpers.assert_eq(second_callback_calls, 1,
				"one bad waiter must not prevent later queued callbacks from running")
		end)
	end)
end)
