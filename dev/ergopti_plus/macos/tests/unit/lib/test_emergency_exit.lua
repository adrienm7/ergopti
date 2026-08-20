--- tests/unit/lib/test_emergency_exit.lua

--- ==============================================================================
--- MODULE: Bounded Emergency Exit Tests
--- DESCRIPTION:
--- Drives rejected, failed, and never-settling exact-fence exits and proves
--- each closes the process through one bounded fallback.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_emergency(logger_error)
	local noop = function() end
	package.loaded["infra.logger"] = {
		start = noop, debug = noop, info = noop, warn = noop,
		error = logger_error or noop, success = noop, done = noop, trace = noop,
	}
	package.loaded["infra.emergency_exit"] = nil
	return require("infra.emergency_exit")
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
