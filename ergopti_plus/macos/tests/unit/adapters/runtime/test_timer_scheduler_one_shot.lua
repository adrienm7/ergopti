--- tests/unit/adapters/runtime/test_timer_scheduler_one_shot.lua

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
		helpers.assert_eq(stop_calls, 2,
			"the inert native delivery must retry the exact cleanup and expose its second refusal")
		helpers.assert_true(handle.timer == native,
			"the second refusal must retain the same native one-shot candidate")
		helpers.assert_eq(TS.activeCount(), 1)
		helpers.assert_eq(TS.cancelAll(), true,
			"cancelAll must perform the remaining retry on the same retained candidate")
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
	helpers.it("notifies exact settlement after an uncommitted native delivery", function()
		for _, start_mode in ipairs({ "false", "nil", "throw" }) do
			for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
				local active = false
				local native_callback = nil
				local current_stop_mode = stop_mode
				local user_calls = 0
				local observer_calls = 0
				local native = nil
				local timer_stub = {
					new = function(_, callback)
						native_callback = callback
						native = {
							start = function(self)
								active = true
								if start_mode == "throw" then error("start refused") end
								if start_mode == "nil" then return nil end
								return false
							end,
							stop = function(self)
								if current_stop_mode == "throw" then error("stop refused") end
								if current_stop_mode == "nil" then return nil end
								if current_stop_mode == "false" then return false end
								active = false
								return self
							end,
							running = function() return active end,
						}
						return native
					end,
					secondsSinceEpoch = function() return 0 end,
				}
				local TS = helpers.load_with_stubs("adapters.timer_scheduler",
					{ timer = timer_stub })
				local handle, committed = TS.after(0, function()
					user_calls = user_calls + 1
				end)
				local case = start_mode .. "/" .. stop_mode

				helpers.assert_eq(committed, false, case)
				helpers.assert_true(handle.timer == native,
					"rollback debt must retain the exact timer (" .. case .. ")")
				helpers.assert_eq(TS.onSettled(handle, function()
					observer_calls = observer_calls + 1
				end), true, case)
				current_stop_mode = "success"
				native_callback()
				helpers.assert_eq(user_calls, 0,
					"uncommitted delivery must stay inert (" .. case .. ")")
				helpers.assert_eq(observer_calls, 1,
					"native delivery must settle one observer (" .. case .. ")")
				helpers.assert_nil(handle.timer, case)
				native_callback()
				helpers.assert_eq(observer_calls, 1,
					"duplicate native delivery cannot redeliver settlement (" .. case .. ")")
				local immediate = 0
				helpers.assert_eq(TS.onSettled(handle, function()
					immediate = immediate + 1
				end), true, case)
				helpers.assert_eq(immediate, 1,
					"an already-settled handle must notify synchronously once (" .. case .. ")")
			end
		end
	end)

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
