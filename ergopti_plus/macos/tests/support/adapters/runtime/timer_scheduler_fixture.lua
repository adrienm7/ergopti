--- tests/support/adapters/runtime/timer_scheduler_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_timer_scheduler
--- DESCRIPTION:
--- Prelude shared by the test_timer_scheduler_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
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

return {
	make_timer_stub = make_timer_stub,
	owned_registry_count = owned_registry_count,
}
