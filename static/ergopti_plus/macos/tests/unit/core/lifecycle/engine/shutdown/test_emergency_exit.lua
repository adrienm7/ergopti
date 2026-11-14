--- tests/unit/core/lifecycle/engine/shutdown/test_emergency_exit.lua

--- ==============================================================================
--- MODULE: Bounded Emergency Exit Tests
--- DESCRIPTION:
--- Drives rejected, failed, and never-settling exact-fence exits and proves
--- each closes the process through one bounded fallback.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_emergency(logger_error)
	local noop = function() end
	package.loaded["core.logger.engine.logger"] = {
		start = noop, debug = noop, info = noop, warn = noop,
		error = logger_error or noop, success = noop, done = noop, trace = noop,
	}
	package.loaded["core.lifecycle.engine.shutdown.emergency_exit"] = nil
	return require("core.lifecycle.engine.shutdown.emergency_exit")
end

local function harness(request_exit, schedule_result, timer_stop_result)
	local calls = { exits = 0, timer_stops = 0 }
	local deadline_callback = nil
	local timer = {
		stop = function()
			calls.timer_stops = calls.timer_stops + 1
			if timer_stop_result == "raises" then error("synthetic timer stop failure") end
			if timer_stop_result == false then return false end
			return true
		end,
	}
	local options = {
		reason = "launcher_loss",
		deadline_seconds = 0.25,
		exit_code = 70,
		schedule = function(delay, callback)
			calls.delay = delay
			deadline_callback = callback
			if schedule_result == false then return nil end
			if schedule_result == "synchronous" then callback() end
			return timer
		end,
		request_exit = function(reason, code, on_aborted)
			calls.request_exit_code = code
			return request_exit(reason, code, on_aborted)
		end,
		exit = function(code)
			calls.exits = calls.exits + 1
			calls.exit_code = code
		end,
	}
	return options, calls, function() return deadline_callback end
end

helpers.describe("bounded emergency exit", function()
	helpers.it("refuses nonfinite or oversized deadlines before starting work (emergency-deadline-range)", function()
		for _, value in ipairs({ 0 / 0, math.huge, math.maxinteger }) do
			local emergency = load_emergency()
			local requests = 0
			local options, calls = harness(function() requests = requests + 1; return true end)
			options.deadline_seconds = value
			helpers.assert_eq(emergency.request(options), false)
			helpers.assert_eq(requests, 0)
			helpers.assert_eq(calls.delay, nil)
		end
	end)

	helpers.it("forces exit even when deadline diagnostics contain opaque errors (emergency-opaque-error)", function()
		local hostile = setmetatable({}, { __tostring = function() error("formatter failed") end })
		for _, scenario in ipairs({
			{ stop_raises = true, describe_raises = false },
			{ stop_raises = false, describe_raises = false },
			{ stop_raises = false, describe_raises = true },
		}) do
			local emergency = load_emergency()
			local options, calls = harness(function() return true end)
			local deadline
			options.schedule = function(_, callback)
				deadline = callback
				return { stop = function()
					if scenario.stop_raises then error(hostile) end
					return true
				end }
			end
			options.describe = function()
				if scenario.describe_raises then error(hostile) end
				return hostile
			end
			helpers.assert_true(emergency.request(options))
			helpers.assert_true(pcall(deadline), "a diagnostic error must not escape the watchdog")
			helpers.assert_eq(calls.exits, 1, "EOF must still revoke the exact lease")
		end
	end)

	helpers.it("forces EOF when an accepted exact fence never settles", function()
		local emergency = load_emergency()
		local options, calls, deadline = harness(function() return true end)

		helpers.assert_true(emergency.request(options))
		helpers.assert_eq(calls.exits, 0)
		helpers.assert_eq(calls.request_exit_code, 70,
			"the exact-fence path must preserve the internal-failure status too")
		deadline()()
		helpers.assert_eq(calls.exits, 1)
		helpers.assert_eq(calls.exit_code, 70,
			"internal failure must remain distinguishable from a normal user exit")
		helpers.assert_eq(calls.timer_stops, 1)
	end)

	helpers.it("forces EOF immediately when the controlled request is rejected", function()
		local emergency = load_emergency()
		local options, calls, deadline = harness(function() return false end)

		helpers.assert_true(emergency.request(options) == false)
		helpers.assert_eq(calls.exits, 1)
		deadline()()
		helpers.assert_eq(calls.exits, 1, "the retained deadline must not exit twice")
	end)

	helpers.it("forces EOF when the exact-fence abort callback fires", function()
		local emergency = load_emergency()
		local options, calls = harness(function(_, _, on_aborted)
			on_aborted("fallback unavailable")
			return true
		end)

		helpers.assert_true(emergency.request(options))
		helpers.assert_eq(calls.exits, 1)
	end)

	helpers.it("exits synchronously when no deadline timer can be retained", function()
		local emergency = load_emergency()
		local request_calls = 0
		local options, calls = harness(function()
			request_calls = request_calls + 1
			return true
		end, false)

		helpers.assert_true(emergency.request(options) == false)
		helpers.assert_eq(calls.exits, 1)
		helpers.assert_eq(request_calls, 0,
			"a failed deadline must exit before starting an unbounded async request")
	end)

	helpers.it("rejects a malformed deadline handle before starting the fence (emergency-deadline-handle)", function()
		for _, malformed in ipairs({ true, {} }) do
			local emergency = load_emergency()
			local request_calls = 0
			local options, calls = harness(function() request_calls = request_calls + 1; return true end)
			options.schedule = function() return malformed end
			helpers.assert_eq(emergency.request(options), false)
			helpers.assert_eq(calls.exits, 1, "an unproven deadline requires the EOF backstop")
			helpers.assert_eq(request_calls, 0)
		end
	end)

	helpers.it("does not retain or start work after an inline deadline fires", function()
		local emergency = load_emergency()
		local request_calls = 0
		local options, calls = harness(function()
			request_calls = request_calls + 1
			return true
		end, "synchronous")

		helpers.assert_true(emergency.request(options) == false)
		helpers.assert_eq(calls.exits, 1)
		helpers.assert_eq(calls.timer_stops, 1,
			"the handle returned after an inline fire must be stopped immediately")
		helpers.assert_eq(request_calls, 0,
			"an already-expired deadline must not start asynchronous fence work")
	end)

	helpers.it("the raw deadline exits even when timer stop and logger diagnostics fail", function()
		for _, stop_result in ipairs({ false, "raises" }) do
			local logger_calls = 0
			local emergency = load_emergency(function()
				logger_calls = logger_calls + 1
				error("synthetic logger failure")
			end)
			local options, calls, deadline = harness(
				function() return true end,
				nil,
				stop_result
			)

			helpers.assert_true(emergency.request(options))
			local callback_ok = pcall(deadline())
			if not callback_ok then
				error("hs.timer must not swallow a logger exception before the hard exit", 0)
			end
			helpers.assert_eq(calls.timer_stops, 1)
			helpers.assert_true(logger_calls >= 1,
				"the causal fixture must execute the failing diagnostic path")
			helpers.assert_eq(calls.exits, 1,
				"the deadline must invoke EOF exit regardless of diagnostic failures")
			helpers.assert_eq(calls.exit_code, 70)
		end
	end)
end)
