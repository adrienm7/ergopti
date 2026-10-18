--- tests/unit/adapters/runtime/test_timer_scheduler_every.lua

--- ==============================================================================
--- MODULE: TimerScheduler Adapter Unit Tests
--- DESCRIPTION:
--- Validates the TimerScheduler adapter contract: after(), every(), cancel(),
--- cancelAll(), and activeCount(). All native timer calls are stubbed so no real
--- OS timers are created — callbacks are triggered manually from the test.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.adapters.runtime.timer_scheduler_fixture"] = nil
local Fixture = require("tests.support.adapters.runtime.timer_scheduler_fixture")
local make_timer_stub = Fixture.make_timer_stub
local owned_registry_count = Fixture.owned_registry_count





helpers.describe("TimerScheduler adapter — every()", function()
	helpers.it("does not register a nil repeating timer as live", function()
		local timer_stub = make_timer_stub()
		timer_stub.new = function() return nil end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local handle, committed = TS.every(1, function() end)
		helpers.assert_eq(committed, false,
			"every() must explicitly report that no native timer was armed")
		helpers.assert_true(handle.fired,
			"a repeating schedule failure must return a terminal handle")
		helpers.assert_nil(handle.timer)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("retains and fences a timer whose start activates then raises", function()
		local timer_stub = make_timer_stub()
		local native = nil
		local start_calls = 0
		local stop_calls = 0
		local stop_refusals = 2
		local native_callback = nil
		timer_stub.new = function(_, callback)
			native_callback = callback
			native = {}
			function native:start()
				start_calls = start_calls + 1
				native_callback()
				error("active start failure")
			end
			function native:stop()
				stop_calls = stop_calls + 1
				if stop_refusals > 0 then
					stop_refusals = stop_refusals - 1
					return false
				end
				return self
			end
			return native
		end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local callback_count = 0
		local handle, committed = TS.every(1, function()
			callback_count = callback_count + 1
		end)

		helpers.assert_eq(committed, false,
			"a raising native start must never publish a committed repeating timer")
		helpers.assert_true(handle.timer == native,
			"the candidate must be published before start so cleanup can retain it")
		helpers.assert_eq(start_calls, 1,
			"a failed candidate must never be replaced by a hidden successor")
		helpers.assert_eq(stop_calls, 1,
			"the failed acquisition must immediately attempt exact rollback")
		helpers.assert_eq(TS.activeCount(), 1,
			"a refused rollback must remain scheduler-owned")
		native_callback()
		helpers.assert_eq(callback_count, 0,
			"both re-entrant and queued callbacks must be inert before commit")
		helpers.assert_eq(stop_calls, 2,
			"the inert queued delivery must retry the exact cleanup and expose its second refusal")
		helpers.assert_true(handle.timer == native,
			"the second refusal must retain the same native repeating candidate")
		helpers.assert_eq(TS.activeCount(), 1)
		helpers.assert_eq(TS.cancelAll(), true,
			"cancelAll must perform the remaining retry on the same retained candidate")
		helpers.assert_eq(start_calls, 1)
		helpers.assert_eq(stop_calls, 3)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("rolls back a timer whose native start returns false", function()
		local timer_stub = make_timer_stub()
		local native = nil
		local stop_calls = 0
		timer_stub.new = function(_, callback)
			native = {
				start = function(self)
					callback()
					return false
				end,
				stop = function(self)
					stop_calls = stop_calls + 1
					return self
				end,
			}
			return native
		end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local callback_count = 0
		local handle, committed = TS.every(1, function()
			callback_count = callback_count + 1
		end)

		helpers.assert_eq(committed, false)
		helpers.assert_true(handle.timer == nil,
			"a successful rollback must release the native capability")
		helpers.assert_true(handle.fired,
			"a fully rolled-back acquisition must return a terminal handle")
		helpers.assert_eq(stop_calls, 1)
		helpers.assert_eq(callback_count, 0,
			"a callback during uncommitted start must be fenced")
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("does not mark handle fired after first firing (repeating)", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local count = 0
		local h, committed = TS.every(1, function() count = count + 1 end)
		helpers.assert_eq(committed, true,
			"every() must explicitly report a live native timer")
		helpers.assert_true(not h.fired, "repeating handle must not be pre-fired")
		timer_stub.fire(1)
		helpers.assert_eq(count, 1)
		-- h.fired remains false for repeating timers (only cancel() sets it)
		helpers.assert_true(not h.fired,
			"repeating handle must not auto-fire after one tick")
	end)

	helpers.it("isolates callback exceptions and routes them to the file logger", function()
		local timer_stub = make_timer_stub()
		local previous_logger = package.loaded["infra.logger"]
		local logged_error = nil
		package.loaded["infra.logger"] = {
			error = function(_, message, ...)
				logged_error = string.format(message, ...)
			end,
		}
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		package.loaded["infra.logger"] = previous_logger
		TS.every(1, function() error("boom") end)
		-- Must not raise even though the callback throws
		-- The swallowing IS the subject, so the pcall stays. What it was missing:
		-- a scheduler that swallowed the exception AND stopped scheduling would pass,
		-- and every later timer in the session would silently never fire.
		local ok, err = pcall(function() timer_stub.fire(1) end)
		helpers.assert_true(ok, "adapter must swallow callback exceptions")
		helpers.assert_nil(err, "and must report none to the run loop")
		helpers.assert_eq(type(TS.after), "function",
			"and must still be able to schedule the next one")
		helpers.assert_true(type(logged_error) == "string"
			and logged_error:find("boom", 1, true) ~= nil,
			"the swallowed callback error must remain visible in the central file logger")
	end)
end)

helpers.describe("TimerScheduler adapter — monotonic clock", function()
	helpers.it("reports awake time independently of wall-clock sleep", function()
		local wall_sec = 100
		local awake_ns = 5000000000
		local timer_stub = make_timer_stub()
		timer_stub.secondsSinceEpoch = function() return wall_sec end
		timer_stub.absoluteTime = function() return awake_ns end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler", { timer = timer_stub })

		helpers.assert_eq(TS.awake_time(), 5,
			"awake time must be expressed in monotonic seconds")
		wall_sec = wall_sec + 600
		awake_ns = awake_ns + 1000000000
		helpers.assert_eq(TS.awake_time(), 6,
			"ten minutes of wall-clock sleep must consume only one awake second")
	end)

	helpers.it("rebases a recovered absolute clock after one fallback sample", function()
		local absolute_calls = 0
		local absolute_ns = 5000000000
		local timer_stub = make_timer_stub()
		timer_stub.secondsSinceEpoch = function() return 100 end
		timer_stub.absoluteTime = function()
			absolute_calls = absolute_calls + 1
			if absolute_calls == 1 then error("transient absolute clock failure") end
			local value = absolute_ns
			absolute_ns = absolute_ns + 10000000
			return value
		end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler", { timer = timer_stub })

		local fallback = TS.now_ns()
		local recovered = TS.now_ns()
		local advanced = TS.now_ns()
		helpers.assert_true(recovered >= fallback,
			"source recovery must preserve the published monotonic origin")
		helpers.assert_true(advanced > recovered,
			"later absolute-clock deltas must advance the rebased timeline")
	end)
end)

helpers.describe("TimerScheduler constructor rejection", function()
	helpers.it("rejects false or throwing constructors without leaking live ownership", function()
		for _, method in ipairs({ "after", "every" }) do
			for _, failure in ipairs({ "false", "throw" }) do
				local timer_stub = make_timer_stub()
				timer_stub.new = function()
					if failure == "throw" then error("constructor failed") end
					return false
				end
				local TS = helpers.load_with_stubs("adapters.timer_scheduler", { timer = timer_stub })
				local handle, committed = TS[method](1, function() end)
				local case = method .. "/" .. failure
				helpers.assert_eq(false, committed, "constructor failure must not commit (" .. case .. ")")
				helpers.assert_eq(0, owned_registry_count(TS),
					"constructor failure must leave no hidden live-set entry (" .. case .. ")")
				helpers.assert_eq(true, handle.fired, "rejected handle must be terminal (" .. case .. ")")
				helpers.assert_nil(handle.timer, "no malformed native value may be published (" .. case .. ")")
			end
		end
	end)
end)

helpers.describe("Hammerspoon timer stub contract", function()
	helpers.it("models timer.new as unstarted until start is called", function()
		local previous_stub = package.loaded["tests.stubs.hs"]
		package.loaded["tests.stubs.hs"] = nil
		local timer = require("tests.stubs.hs").timer
		package.loaded["tests.stubs.hs"] = previous_stub
		local callback_count = 0
		local candidate = timer.new(1, function() callback_count = callback_count + 1 end)

		helpers.assert_true(candidate.running == false,
			"the shared stub must not auto-start a timer.new candidate")
		candidate:fire()
		helpers.assert_eq(callback_count, 0,
			"an unstarted native candidate cannot fire")
		helpers.assert_true(candidate:start() == candidate)
		candidate:fire()
		helpers.assert_eq(callback_count, 1)
		helpers.assert_true(candidate:stop() == candidate,
			"the stub stop return must match Hammerspoon's chainable timer object")
	end)
end)
