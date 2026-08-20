--- tests/unit/adapters/test_timer_scheduler.lua

--- ==============================================================================
--- MODULE: TimerScheduler Adapter Unit Tests
--- DESCRIPTION:
--- Validates the TimerScheduler adapter contract: after(), every(), cancel(),
--- cancelAll(), and activeCount(). All native timer calls are stubbed so no real
--- OS timers are created — callbacks are triggered manually from the test.
--- ==============================================================================

local helpers = require("tests.helpers")


-- =============================================
-- =============================================
-- ======= 1/ Stub Setup =======================
-- =============================================
-- =============================================

-- The hs stub records timer.new calls and exposes a
-- manual trigger so tests can fire callbacks synchronously.
local function make_timer_stub()
	local stub = {
		_pending = {},  -- { fn, stopped } entries
	}

	function stub.doAfter()
		error("TimerScheduler.after() must own timer.new/start transactionally")
	end

	function stub.new(_, fn)
		local t = {
			fn = fn,
			stopped = false,
			running = false,
			repeating = true,
			start_calls = 0,
			stop_calls = 0,
		}
		stub._pending[#stub._pending + 1] = t
		local native
		native = setmetatable({}, {
			__index = {
				start = function()
					t.start_calls = t.start_calls + 1
					t.running = true
					return native
				end,
				stop = function()
					t.stop_calls = t.stop_calls + 1
					t.stopped = true
					t.running = false
					return native
				end,
			}
		})
		t.native = native
		return native
	end

	function stub.doEvery()
		error("TimerScheduler.every() must own timer.new/start transactionally")
	end

	-- Fires all pending (non-stopped) callbacks once.
	function stub.fire_all()
		for _, t in ipairs(stub._pending) do
			if not t.stopped and (not t.repeating or t.running) then t.fn() end
		end
	end

	-- Fires the Nth pending callback (1-based).
	function stub.fire(n)
		local t = stub._pending[n]
		if t and not t.stopped and (not t.repeating or t.running) then t.fn() end
	end

	function stub.reset()
		stub._pending = {}
	end

	return stub
end

--- Counts exact scheduler ownership rather than trusting activeCount(), whose
--- public definition intentionally ignores entries with no native timer field.
--- This catches a malformed constructor result published into the strong live
--- registry even when that bad value is itself false.
local function owned_registry_count(TS)
	for index = 1, 20 do
		local name, value = debug.getupvalue(TS.cancelAll, index)
		if name == "_live_timers" then
			local count = 0
			for _ in pairs(value) do count = count + 1 end
			return count
		end
		if name == nil then break end
	end
	error("TimerScheduler live registry upvalue not found")
end


-- ================================================
-- ================================================
-- ======= 2/ Tests ================================
-- ================================================
-- ================================================

helpers.describe("TimerScheduler adapter — after()", function()
	helpers.it("fires callback and marks handle fired", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local fired = false
		local h, committed = TS.after(1, function() fired = true end)
		helpers.assert_true(committed == true,
			"after() must explicitly report that the native timer committed")
		helpers.assert_true(not h.fired, "handle should not be fired yet")
		timer_stub.fire(1)
		helpers.assert_true(fired, "callback should have fired")
		helpers.assert_true(h.fired, "handle.fired should be true after callback")
	end)

	helpers.it("returns an opaque handle with fired=false initially", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local h = TS.after(0.5, function() end)
		helpers.assert_true(type(h) == "table", "handle must be a table")
		helpers.assert_true(h.fired == false, "handle.fired must start false")
	end)

	helpers.it("increments activeCount while handle is live", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		helpers.assert_eq(TS.activeCount(), 0)
		TS.after(1, function() end)
		TS.after(2, function() end)
		helpers.assert_eq(TS.activeCount(), 2)
	end)

	helpers.it("decrements activeCount after firing", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		TS.after(1, function() end)
		helpers.assert_eq(TS.activeCount(), 1)
		timer_stub.fire(1)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("does not register a nil native timer as live", function()
		local timer_stub = make_timer_stub()
		timer_stub.new = function() return nil end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local handle, committed = TS.after(1, function() end)
		helpers.assert_true(committed == false,
			"after() must explicitly report that no native timer was armed")
		helpers.assert_true(handle.fired,
			"a schedule failure must return a terminal handle")
		helpers.assert_nil(handle.timer)
		helpers.assert_eq(TS.activeCount(), 0,
			"a nil native handle cannot be retained as a live timer")
	end)

	helpers.it("rejects a one-shot candidate delivered synchronously during start", function()
		local timer_stub = make_timer_stub()
		local stop_calls = 0
		timer_stub.new = function(_, callback)
			return {
				start = function(self)
					callback()
					return self
				end,
				stop = function(self)
					stop_calls = stop_calls + 1
					return self
				end,
			}
		end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local callback_count = 0
		local handle, committed = TS.after(0, function()
			callback_count = callback_count + 1
		end)

		helpers.assert_eq(committed, false,
			"a delivery consumed before publication cannot be called a live one-shot timer")
		helpers.assert_eq(callback_count, 0,
			"uncommitted native delivery must never escape to user code")
		helpers.assert_eq(stop_calls, 1)
		helpers.assert_nil(handle.timer)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("rejects a truthy start that leaves the native timer stopped", function()
		local timer_stub = make_timer_stub()
		local active = false
		local stop_calls = 0
		local native = nil
		timer_stub.new = function()
			native = {
				start = function(self) return self end,
				stop = function(self)
					stop_calls = stop_calls + 1
					active = false
					return self
				end,
				running = function() return active end,
			}
			return native
		end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local handle, committed = TS.after(1, function() end)

		helpers.assert_eq(committed, false,
			"a chainable start return cannot certify a timer that is not running")
		helpers.assert_eq(stop_calls, 1,
			"state-probe refusal must roll back the exact native candidate")
		helpers.assert_nil(handle.timer)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("retains and fences a one-shot timer whose start activates then raises", function()
		local timer_stub = make_timer_stub()
		local native = nil
		local native_callback = nil
		local start_calls = 0
		local stop_calls = 0
		local stop_refusals = 2
		timer_stub.new = function(_, callback)
			native_callback = callback
			native = {}
			function native:start()
				start_calls = start_calls + 1
				error("active one-shot start failure")
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
		local handle, committed = TS.after(0, function()
			callback_count = callback_count + 1
		end)

		helpers.assert_eq(committed, false,
			"a raising native start must never publish a committed one-shot timer")
		helpers.assert_true(handle.timer == native,
			"the exact candidate must be owned before start can activate then raise")
		helpers.assert_eq(start_calls, 1,
			"a failed candidate must never be replaced by a hidden successor")
		helpers.assert_eq(stop_calls, 1,
			"failed acquisition must immediately attempt exact rollback")
		helpers.assert_eq(TS.activeCount(), 1,
			"a refused rollback must remain scheduler-owned")
		native_callback()
		helpers.assert_eq(callback_count, 0,
			"callbacks from an uncommitted one-shot candidate must be inert")
		helpers.assert_eq(TS.cancelAll(), false,
			"cancelAll must expose a second explicit cleanup refusal")
		helpers.assert_eq(TS.cancelAll(), true,
			"cancelAll must retry the same retained candidate to completion")
		helpers.assert_eq(start_calls, 1)
		helpers.assert_eq(stop_calls, 3)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("delivers once and retains exact cleanup debt when stop refuses at fire", function()
		local timer_stub = make_timer_stub()
		local native = nil
		local native_callback = nil
		local stop_calls = 0
		timer_stub.new = function(_, callback)
			native_callback = callback
			native = {
				start = function(self) return self end,
				stop = function(self)
					stop_calls = stop_calls + 1
					if stop_calls == 1 then return false end
					return self
				end,
			}
			return native
		end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local callback_count = 0
		local handle, committed = TS.after(0, function()
			callback_count = callback_count + 1
		end)

		helpers.assert_eq(committed, true)
		native_callback()
		helpers.assert_eq(callback_count, 1,
			"a due one-shot callback must still be delivered when native stop refuses")
		helpers.assert_true(handle.timer == native,
			"the exact repeating native candidate must remain owned as cleanup debt")
		helpers.assert_eq(TS.activeCount(), 1,
			"fired cleanup debt is still a live native capability")
		native_callback()
		helpers.assert_eq(callback_count, 1,
			"a refused native stop must never repeat the user callback")
		helpers.assert_eq(TS.cancelAll(), true,
			"cleanup must retry the exact candidate after its one delivery")
		helpers.assert_eq(stop_calls, 2)
		helpers.assert_nil(handle.timer)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("retries fired cleanup debt without suppressing an unrelated sibling", function()
		local timer_stub = make_timer_stub()
		local first_callback = nil
		local constructor_calls = 0
		local stop_calls = 0
		timer_stub.new = function(_, callback)
			constructor_calls = constructor_calls + 1
			if constructor_calls == 1 then
				first_callback = callback
				return {
					start = function(self) return self end,
					stop = function(self)
						stop_calls = stop_calls + 1
						if stop_calls < 3 then return false end
						return self
					end,
				}
			end
			return {
				start = function(self) return self end,
				stop = function(self) return self end,
			}
		end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local sibling_handle = nil
		local sibling_committed = nil
		local first, committed = TS.after(0, function()
			sibling_handle, sibling_committed = TS.after(1, function() end)
		end)

		helpers.assert_eq(committed, true)
		first_callback()
		helpers.assert_eq(stop_calls, 2,
			"the callback-side acquisition boundary must retry exact cleanup once")
		helpers.assert_eq(constructor_calls, 2,
			"cleanup debt is fenced and retained, but must not suppress an unrelated timer")
		helpers.assert_eq(sibling_committed, true)
		helpers.assert_true(type(sibling_handle) == "table" and sibling_handle.timer ~= nil,
			"the unrelated sibling must still own its committed native capability")
		helpers.assert_true(first.timer ~= nil,
			"the exact first capability remains scheduler-owned while stop refuses")

		first_callback()
		helpers.assert_eq(stop_calls, 3,
			"a later native delivery must autonomously retry cleanup without user work")
		helpers.assert_nil(first.timer)
		local successor, successor_committed = TS.after(1, function() end)
		helpers.assert_eq(successor_committed, true,
			"new acquisition may resume only after the prior exact capability settled")
		helpers.assert_eq(constructor_calls, 3)
		helpers.assert_true(successor.timer ~= nil)
	end)
end)

helpers.describe("TimerScheduler adapter — cancel()", function()
	helpers.it("marks handle fired and stops the OS timer", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local called = false
		local h = TS.after(10, function() called = true end)
		TS.cancel(h)
		helpers.assert_true(h.fired, "handle.fired must be true after cancel()")
		-- Verify callback is not called even if the OS timer fires (stopped)
		timer_stub.fire(1)
		helpers.assert_true(not called, "cancelled callback must not fire")
	end)

	helpers.it("is a no-op on nil", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		-- Must not throw
		TS.cancel(nil)
	end)

	helpers.it("is a no-op on already-fired handle", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local h = TS.after(0, function() end)
		timer_stub.fire(1)
		helpers.assert_true(h.fired)
		-- Second cancel must not throw
		TS.cancel(h)
	end)

	helpers.it("decrements activeCount", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local h = TS.after(5, function() end)
		helpers.assert_eq(TS.activeCount(), 1)
		TS.cancel(h)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("retains a timer whose native stop throws, then retries it", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local h = TS.after(5, function() end)
		local original_stop = h.timer.stop
		local attempts = 0
		function h.timer:stop()
			attempts = attempts + 1
			if attempts == 1 then error("synthetic stop failure") end
			return original_stop(self)
		end

		helpers.assert_eq(TS.cancel(h), false,
			"a native stop failure must not be certified as cancellation")
		helpers.assert_true(not h.fired,
			"the retry capability must not be marked terminal after failure")
		helpers.assert_eq(TS.activeCount(), 1,
			"the scheduler must retain ownership of the live timer")
		helpers.assert_eq(TS.cancel(h), true)
		helpers.assert_eq(attempts, 2)
		helpers.assert_true(h.fired)
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("treats an explicit false native stop as retryable cleanup debt", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local callback_count = 0
		local h = TS.every(5, function() callback_count = callback_count + 1 end)
		local stop_attempts = 0
		function h.timer:stop()
			stop_attempts = stop_attempts + 1
			if stop_attempts == 1 then return false end
			timer_stub._pending[1].stopped = true
			timer_stub._pending[1].running = false
			return self
		end

		helpers.assert_eq(TS.cancel(h), false,
			"an explicit false stop result must not certify native release")
		helpers.assert_eq(TS.activeCount(), 1,
			"the exact native capability must remain owned for retry")
		timer_stub._pending[1].fn()
		helpers.assert_eq(callback_count, 0,
			"a cancellation-debt timer must already be logically inert")
		helpers.assert_eq(TS.cancel(h), true)
		helpers.assert_eq(stop_attempts, 2,
			"retry must target the same native timer instead of a successor")
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("retains a truthy stop that leaves the native timer running", function()
		local timer_stub = make_timer_stub()
		local active = false
		local stop_attempts = 0
		local native = nil
		timer_stub.new = function(_, callback)
			native = {
				start = function(self)
					active = true
					return self
				end,
				stop = function(self)
					stop_attempts = stop_attempts + 1
					if stop_attempts > 1 then active = false end
					return self
				end,
				running = function() return active end,
				callback = callback,
			}
			return native
		end
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local callback_count = 0
		local handle, committed = TS.every(5, function()
			callback_count = callback_count + 1
		end)
		helpers.assert_eq(committed, true)

		helpers.assert_eq(TS.cancel(handle), false,
			"a truthy stop return cannot certify a timer whose running() stays true")
		helpers.assert_true(handle.timer == native,
			"the exact still-running candidate must remain owned for retry")
		native.callback()
		helpers.assert_eq(callback_count, 0,
			"retained stop debt must already be callback-inert")
		helpers.assert_eq(TS.cancel(handle), true)
		helpers.assert_eq(stop_attempts, 2)
		helpers.assert_nil(handle.timer)
	end)
end)

helpers.describe("TimerScheduler adapter — cancelAll()", function()
	helpers.it("cancels all live handles", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		TS.after(1, function() end)
		TS.after(2, function() end)
		TS.every(3, function() end)
		helpers.assert_eq(TS.activeCount(), 3)
		TS.cancelAll()
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("is safe to call when no timers are active", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		-- Must not throw
		TS.cancelAll()
		helpers.assert_eq(TS.activeCount(), 0)
	end)

	helpers.it("continues siblings and retains only failed native stops", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local failed = TS.after(1, function() end)
		local sibling = TS.after(2, function() end)
		local original_stop = failed.timer.stop
		local attempts = 0
		function failed.timer:stop()
			attempts = attempts + 1
			if attempts == 1 then error("synthetic stop failure") end
			return original_stop(self)
		end

		helpers.assert_eq(TS.cancelAll(), false)
		helpers.assert_true(not failed.fired,
			"the failed timer must stay retryable")
		helpers.assert_true(sibling.fired,
			"one failure must not prevent sibling cleanup")
		helpers.assert_eq(TS.activeCount(), 1)
		helpers.assert_eq(TS.cancelAll(), true)
		helpers.assert_eq(attempts, 2)
		helpers.assert_eq(TS.activeCount(), 0)
	end)
end)

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
		helpers.assert_eq(TS.cancelAll(), false,
			"cancelAll must expose a second explicit cleanup refusal")
		helpers.assert_eq(TS.cancelAll(), true,
			"cancelAll must retry the same retained candidate to completion")
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
