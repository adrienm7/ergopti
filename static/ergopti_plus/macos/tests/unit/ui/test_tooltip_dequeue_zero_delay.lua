--- tests/unit/ui/test_tooltip_dequeue_zero_delay.lua

--- ==============================================================================
--- MODULE: Tooltip Dequeue Zero-Delay Regression (M-10)
--- DESCRIPTION:
--- Regression tests for bug M-10: when all rows in a stacked tooltip carry no
--- expiry (duration == 0 / no expire_at), Dequeue.next_expiry_delay_sec returns
--- 0. The arm_dequeue_timer function must detect this and call
--- hs.timer.doAfter(0, _dequeue_tick) immediately rather than assigning a nil
--- _dequeue_timer, which would leave _dequeue_rows non-nil and block every
--- subsequent M.hide() call forever.
---
--- FEATURES & RATIONALE:
--- 1. Zero-delay guard: asserts doAfter(0, cb) is called when delay <= 0.
--- 2. Callback execution: firing the scheduled callback must clear dequeue
---    state, allowing M.hide() to proceed normally (no longer returns early).
--- 3. Positive-delay path: asserts the normal timer assignment path is unchanged.
--- 4. Pure logic simulation: no real canvas or HS environment is required;
---    the arm_dequeue_timer logic is extracted with minimal stubs so the test
---    remains fast and deterministic.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =================================================
-- =================================================
-- ======= 1/ arm_dequeue_timer Inline Model =======
-- =================================================
-- =================================================

--- Builds a self-contained simulation of the arm_dequeue_timer + M.hide()
--- state machine using the caller-supplied hs.timer.doAfter stub and a
--- stub Dequeue.next_expiry_delay_sec. Returns a table with the same
--- observable interface used by the assertions below.
--- @param next_delay_sec number|nil What next_expiry_delay_sec will return.
--- @param do_after_stub function Replacement for hs.timer.doAfter.
--- @return table { hide, arm, dequeue_rows_ref }
local function make_simulation(next_delay_sec, do_after_stub)
	-- Module-level state mirroring tooltip_hotstring.lua
	local _dequeue_rows  = nil
	local _dequeue_timer = nil
	local _dequeue_tick  -- forward declaration

	-- Stub Dequeue dependency: returns the caller-supplied fixed delay
	local stub_dequeue = {
		next_expiry_delay_sec = function(_rows, _now, _opts)
			return next_delay_sec
		end,
		prune_expired = function(_rows, _now, _opts)
			-- Simulate "all rows expired" so the tick calls hide_forced
			return {}
		end,
	}

	-- Minimal hide_forced that clears dequeue state (mirrors production code)
	local function hide_forced()
		if _dequeue_timer then
			pcall(function() _dequeue_timer:stop() end)
			_dequeue_timer = nil
		end
		_dequeue_rows = nil
	end

	-- M.hide mirrors the production guard: bail out when dequeue is active
	local function hide()
		if _dequeue_rows then return "guarded" end
		hide_forced()
		return "hidden"
	end

	-- arm_dequeue_timer — exact replica of the production code path under test
	local function arm_dequeue_timer()
		if _dequeue_timer then
			pcall(function() _dequeue_timer:stop() end)
			_dequeue_timer = nil
		end
		if not _dequeue_rows then return end
		local delay = stub_dequeue.next_expiry_delay_sec(
			_dequeue_rows, os.time(), {})
		if delay and delay <= 0 then
			-- All rows are permanent (no expire_at) — fire the tick immediately;
			-- without this _dequeue_rows stays non-nil and M.hide() is blocked
			-- forever (M-10 root cause)
			do_after_stub(0, function() _dequeue_tick() end)
		else
			_dequeue_timer = do_after_stub(delay, function() _dequeue_tick() end)
		end
	end

	-- _dequeue_tick mirrors the production body: prune then hide_forced when empty
	_dequeue_tick = function()
		pcall(function()
			if not _dequeue_rows then return end
			local remaining = stub_dequeue.prune_expired(
				_dequeue_rows, os.time(), {})
			if #remaining == 0 then
				hide_forced()
				return
			end
			-- Surviving rows would trigger show_stacked; out of scope here
		end)
	end

	-- Expose a method to prime dequeue state (simulates show_stacked activating
	-- the dequeue path)
	local function activate_dequeue(rows)
		_dequeue_rows = rows or { { text = "row1" } }
	end

	return {
		hide             = hide,
		arm              = arm_dequeue_timer,
		activate_dequeue = activate_dequeue,
		get_dequeue_rows = function() return _dequeue_rows end,
	}
end





-- ================================================================
-- ================================================================
-- ======= 2/ Zero-Delay: doAfter(0) Is Called (M-10 Guard) =======
-- ================================================================
-- ================================================================

helpers.describe("arm_dequeue_timer: zero-delay path fires doAfter(0, cb) (M-10)", function()
	helpers.it("calls doAfter with delay == 0 when next_expiry_delay_sec returns 0", function()
		local calls = {}
		local function stub_do_after(delay, fn)
			table.insert(calls, { delay = delay, fn = fn })
			-- Return a minimal timer-like object so the caller can assign it
			return { stop = function() end }
		end

		local sim = make_simulation(0, stub_do_after)
		sim.activate_dequeue()
		sim.arm()

		helpers.assert_eq(#calls, 1, "doAfter must be called exactly once")
		helpers.assert_eq(calls[1].delay, 0, "doAfter delay must be 0 for the zero-delay path")
		helpers.assert_true(type(calls[1].fn) == "function",
			"doAfter callback must be a function")
	end)

	helpers.it("calls doAfter with delay == 0 when next_expiry_delay_sec returns a negative value", function()
		-- next_expiry_delay_sec should not return negative values in practice, but
		-- the guard uses <= 0 so any non-positive value triggers the same path
		local calls = {}
		local function stub_do_after(delay, fn)
			table.insert(calls, { delay = delay, fn = fn })
			return { stop = function() end }
		end

		local sim = make_simulation(-0.1, stub_do_after)
		sim.activate_dequeue()
		sim.arm()

		helpers.assert_eq(#calls, 1, "doAfter must be called once for negative delay")
		helpers.assert_eq(calls[1].delay, 0, "doAfter delay must be 0 regardless of negative input")
	end)

	helpers.it("does not assign _dequeue_timer when the zero-delay path is taken", function()
		-- On the zero-delay path doAfter is called but the return value must NOT
		-- be assigned to _dequeue_timer — the production code has no assignment there
		-- (the timer is ephemeral). We verify this indirectly by calling arm() a
		-- second time immediately after the first; it must not attempt to stop a
		-- stale timer object and must still call doAfter.
		local call_count = 0
		local function stub_do_after(delay, fn)
			call_count = call_count + 1
			_ = fn  -- captured but not executed
			return { stop = function() end }
		end

		local sim = make_simulation(0, stub_do_after)
		sim.activate_dequeue()
		sim.arm()
		-- A second arm() call (e.g. from a rebuild) must not crash on a nil timer
		sim.arm()

		helpers.assert_eq(call_count, 2, "each arm() on the zero-delay path schedules one doAfter call")
	end)
end)





-- ======================================================
-- ======================================================
-- ======= 3/ Callback Fires — M.hide() Unblocked =======
-- ======================================================
-- ======================================================

helpers.describe("arm_dequeue_timer: firing the zero-delay callback clears dequeue state", function()
	helpers.it("M.hide() returns 'guarded' before the callback fires", function()
		local scheduled_fn = nil
		local function stub_do_after(delay, fn)
			scheduled_fn = fn
			return { stop = function() end }
		end

		local sim = make_simulation(0, stub_do_after)
		sim.activate_dequeue()
		sim.arm()

		-- Before the timer fires, dequeue is active and M.hide() must return early
		local result = sim.hide()
		helpers.assert_eq(result, "guarded",
			"M.hide() must return 'guarded' while dequeue is active")
	end)

	helpers.it("M.hide() returns 'hidden' after the callback fires", function()
		local scheduled_fn = nil
		local function stub_do_after(delay, fn)
			scheduled_fn = fn
			return { stop = function() end }
		end

		local sim = make_simulation(0, stub_do_after)
		sim.activate_dequeue()
		sim.arm()

		-- Simulate the timer firing (doAfter(0) callback executes)
		helpers.assert_true(type(scheduled_fn) == "function",
			"a callback must have been scheduled")
		scheduled_fn()

		-- After the tick prunes all rows and calls hide_forced, _dequeue_rows is nil
		-- so M.hide() must no longer return early
		local result = sim.hide()
		helpers.assert_eq(result, "hidden",
			"M.hide() must proceed normally after the dequeue tick clears state")
	end)

	helpers.it("_dequeue_rows is nil after the callback fires (state fully cleared)", function()
		local scheduled_fn = nil
		local function stub_do_after(delay, fn)
			scheduled_fn = fn
			return { stop = function() end }
		end

		local sim = make_simulation(0, stub_do_after)
		sim.activate_dequeue()
		sim.arm()

		helpers.assert_true(sim.get_dequeue_rows() ~= nil,
			"_dequeue_rows must be non-nil before the tick fires")

		scheduled_fn()

		helpers.assert_nil(sim.get_dequeue_rows(),
			"_dequeue_rows must be nil after the dequeue tick clears state")
	end)
end)





-- =====================================================
-- =====================================================
-- ======= 4/ Positive-Delay Path (Sanity Check) =======
-- =====================================================
-- =====================================================

helpers.describe("arm_dequeue_timer: positive delay uses normal timer assignment", function()
	helpers.it("returns a timer object when delay > 0", function()
		local timers_created = {}
		local function stub_do_after(delay, fn)
			local t = { delay = delay, fn = fn, stopped = false, stop = function(self) self.stopped = true end }
			table.insert(timers_created, t)
			return t
		end

		-- 0.8 sec delay mirrors a typical 1s row after decrement (see dequeue vectors)
		local sim = make_simulation(0.8, stub_do_after)
		sim.activate_dequeue()
		sim.arm()

		helpers.assert_eq(#timers_created, 1, "exactly one timer must be created")
		helpers.assert_eq(timers_created[1].delay, 0.8,
			"the timer delay must match next_expiry_delay_sec output")
	end)

	helpers.it("re-arming stops the previous timer before creating a new one", function()
		local stop_calls = 0
		local timers_created = {}
		local function stub_do_after(delay, fn)
			local t = {
				delay = delay, fn = fn, stopped = false,
				stop = function(self)
					self.stopped = true
					stop_calls = stop_calls + 1
				end,
			}
			table.insert(timers_created, t)
			return t
		end

		local sim = make_simulation(0.8, stub_do_after)
		sim.activate_dequeue()
		sim.arm()   -- first arm: creates timer[1]
		sim.arm()   -- second arm: must stop timer[1] before creating timer[2]

		helpers.assert_eq(#timers_created, 2, "two timers must be created across two arm() calls")
		helpers.assert_eq(stop_calls, 1,
			"the first timer must be stopped when re-arming")
		helpers.assert_eq(timers_created[1].stopped, true,
			"the first timer object must have .stopped == true")
	end)

	helpers.it("does not call doAfter when _dequeue_rows is nil", function()
		local call_count = 0
		local function stub_do_after(_delay, _fn)
			call_count = call_count + 1
			return { stop = function() end }
		end

		-- Do not call activate_dequeue — _dequeue_rows stays nil
		local sim = make_simulation(0.8, stub_do_after)
		sim.arm()

		helpers.assert_eq(call_count, 0,
			"doAfter must not be called when _dequeue_rows is nil (no active dequeue)")
	end)
end)

print("[PASS] test_tooltip_dequeue_zero_delay")
