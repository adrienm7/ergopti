--- tests/unit/adapters/runtime/test_timer_delay_ceiling.lua

--- ==============================================================================
--- MODULE: macOS Timer Delay Ceiling
--- DESCRIPTION:
--- Replays the shared delay-ceiling corpus against the Hammerspoon
--- TimerScheduler: after(), every() and the blocking sleep_us(). hs.timer is a
--- recording stub, so an admitted 2^53 ms delay is observed without waiting.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.adapters.runtime.timer_scheduler_fixture"] = nil
local Fixture = require("tests.support.adapters.runtime.timer_scheduler_fixture")

--- Loads a fresh scheduler and records every Logger.error it writes.
--- @param timer_stub table hs.timer stub.
--- @return table scheduler
--- @return function restore Restores the logger and returns the error count.
local function load_scheduler(timer_stub)
	local scheduler = helpers.load_with_stubs("adapters.timer_scheduler", { timer = timer_stub })
	local logger = assert(package.loaded["infra.logger"], "the scheduler's logger must be loaded")
	local original, errors = logger.error, 0
	logger.error = function() errors = errors + 1 end
	return scheduler, function()
		logger.error = original
		return errors
	end
end

--- Replays one scheduler method; reached means hs.timer received the delay.
--- @param method string "after" or "every".
--- @return function replay
local function scheduler_replay(method)
	return function(seconds)
		local timer_stub = Fixture.make_timer_stub()
		local scheduler, restore = load_scheduler(timer_stub)
		local calls = 0
		local ok, handle, committed = pcall(scheduler[method], seconds, function() calls = calls + 1 end)
		local errors = restore()
		if not ok then error(handle, 0) end
		helpers.assert_eq(committed == true, #timer_stub._pending == 1, method .. " reports exactly what it armed")
		helpers.assert_eq(calls, 0, method .. " never runs user work synchronously")
		if committed ~= true then helpers.assert_true(handle.fired == true and handle.timer == nil) end
		scheduler.cancelAll()
		return #timer_stub._pending == 1, errors > 0
	end
end

--- Replays the blocking sleep; reached means hs.timer.usleep was called.
--- @param seconds number Delay.
--- @return boolean reached
--- @return boolean explained
local function sleep_replay(seconds)
	local timer_stub, sleeps = Fixture.make_timer_stub(), 0
	timer_stub.usleep = function() sleeps = sleeps + 1 end
	local scheduler, restore = load_scheduler(timer_stub)
	local ok, detail = pcall(scheduler.sleep_us, seconds * 1e6)
	local errors = restore()
	if not ok then error(detail, 0) end
	return sleeps == 1, errors > 0
end

require("test.timer_delay_ceiling_contract").register(helpers, helpers.shared, {
	{ name = "macos scheduler after", unit = "seconds", replay = scheduler_replay("after") },
	{ name = "macos scheduler every", unit = "seconds", replay = scheduler_replay("every") },
	{ name = "macos scheduler sleep_us", unit = "seconds", replay = sleep_replay,
		lower = function(seconds) return seconds > 0 end },
})
