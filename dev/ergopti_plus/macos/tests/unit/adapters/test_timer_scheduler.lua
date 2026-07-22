--- tests/unit/adapters/test_timer_scheduler.lua

--- ==============================================================================
--- MODULE: TimerScheduler Adapter Unit Tests
--- DESCRIPTION:
--- Validates the TimerScheduler adapter contract: after(), every(), cancel(),
--- cancelAll(), and activeCount(). All hs.timer calls are stubbed so no real
--- OS timers are created — callbacks are triggered manually from the test.
--- ==============================================================================

local helpers = require("tests.helpers")


-- =============================================
-- =============================================
-- ======= 1/ Stub Setup =======================
-- =============================================
-- =============================================

-- The hs stub records timer.doAfter / timer.doEvery calls and exposes a
-- manual trigger so tests can fire callbacks synchronously.
local function make_timer_stub()
	local stub = {
		_pending = {},  -- { fn, stopped } entries
	}

	function stub.doAfter(_, fn)
		local t = { fn = fn, stopped = false }
		stub._pending[#stub._pending + 1] = t
		-- Expose a :stop() method on the returned handle
		return setmetatable({}, {
			__index = {
				stop = function() t.stopped = true end,
			}
		})
	end

	function stub.doEvery(_, fn)
		local t = { fn = fn, stopped = false, repeating = true }
		stub._pending[#stub._pending + 1] = t
		return setmetatable({}, {
			__index = {
				stop = function() t.stopped = true end,
			}
		})
	end

	-- Fires all pending (non-stopped) callbacks once.
	function stub.fire_all()
		for _, t in ipairs(stub._pending) do
			if not t.stopped then t.fn() end
		end
	end

	-- Fires the Nth pending callback (1-based).
	function stub.fire(n)
		local t = stub._pending[n]
		if t and not t.stopped then t.fn() end
	end

	function stub.reset()
		stub._pending = {}
	end

	return stub
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
		local h = TS.after(1, function() fired = true end)
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
end)

helpers.describe("TimerScheduler adapter — every()", function()
	helpers.it("does not mark handle fired after first firing (repeating)", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		local count = 0
		local h = TS.every(1, function() count = count + 1 end)
		helpers.assert_true(not h.fired, "repeating handle must not be pre-fired")
		timer_stub.fire(1)
		helpers.assert_eq(count, 1)
		-- h.fired remains false for repeating timers (only cancel() sets it)
		helpers.assert_true(not h.fired,
			"repeating handle must not auto-fire after one tick")
	end)

	helpers.it("isolates callback exceptions — does not propagate", function()
		local timer_stub = make_timer_stub()
		local TS = helpers.load_with_stubs("adapters.timer_scheduler",
			{ timer = timer_stub })
		TS.every(1, function() error("boom") end)
		-- Must not raise even though the callback throws
		local ok = pcall(function() timer_stub.fire(1) end)
		helpers.assert_true(ok, "adapter must swallow callback exceptions")
	end)
end)
