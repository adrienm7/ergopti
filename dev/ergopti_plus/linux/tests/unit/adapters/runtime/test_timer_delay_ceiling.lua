--- tests/unit/adapters/runtime/test_timer_delay_ceiling.lua

--- ==============================================================================
--- MODULE: Linux Timer Delay Ceiling
--- DESCRIPTION:
--- Replays the shared delay-ceiling corpus against every Linux boundary that
--- hands a relative delay to libuv or nanosleep: the TimerScheduler port, the
--- native timer owner, the event loop's deferred queue and sleep, and the
--- nanosleep binding. Native backends are recording doubles, so an admitted
--- 2^53 ms delay is observed without waiting for it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Logger = require("logger.shim")

--- Runs body while recording Logger.error calls on the shared logger table.
--- @param body function Replay returning reached.
--- @return boolean reached
--- @return boolean explained True when an error line was written.
local function with_errors(body)
	local original, errors = Logger.error, 0
	Logger.error = function() errors = errors + 1 end
	local ok, reached = pcall(body)
	Logger.error = original
	if not ok then error(reached, 0) end
	return reached, errors > 0
end

--- Loads a fresh TimerScheduler bound to a recording libuv double.
--- @return table scheduler
--- @return table arms Recorded timer_start delays.
local function scheduler_fixture()
	local arms = {}
	local backend = {
		update_time = function() end,
		new_timer = function() return {} end,
		timer_start = function(_, timeout) arms[#arms + 1] = timeout; return 0 end,
		timer_stop = function() return 0 end,
		close = function() end,
	}
	local previous_backend, previous_scheduler = package.loaded.luv, package.loaded["adapters.timer_scheduler"]
	package.loaded.luv, package.loaded["adapters.timer_scheduler"] = backend, nil
	local scheduler = require("adapters.timer_scheduler")
	package.loaded.luv, package.loaded["adapters.timer_scheduler"] = previous_backend, previous_scheduler
	return scheduler, arms
end

--- Replays one TimerScheduler method.
--- @param method string "after" or "every".
--- @return function replay
local function scheduler_replay(method)
	return function(seconds)
		local scheduler, arms = scheduler_fixture()
		local calls = 0
		local reached, explained = with_errors(function()
			local handle = scheduler[method](seconds, function() calls = calls + 1 end)
			helpers.assert_eq(handle.armed == true, #arms == 1, method .. " reports exactly what it armed")
			return #arms == 1
		end)
		helpers.assert_eq(calls, 0, method .. " never runs user work synchronously")
		scheduler.cancelAll()
		return reached, explained
	end
end

--- Replays the native timer owner every libuv timer arms through.
--- @param milliseconds number Delay.
--- @return boolean reached
--- @return boolean explained
local function native_timer_replay(milliseconds)
	local arms = 0
	local backend = {
		update_time = function() end,
		timer_start = function() arms = arms + 1; return 0 end,
	}
	local result, message = require("infra.native_timer").start(backend, {}, milliseconds, 0, function() end)
	helpers.assert_eq(result == 0, arms == 1, "the start receipt is the backend's own")
	return arms == 1, result == nil and type(message) == "string" and message ~= ""
end

--- Loads a fresh event loop whose nanosleep binding records instead of waiting.
--- @return table loop
--- @return table naps Recorded sleep durations in seconds.
local function event_loop_fixture()
	local naps = {}
	local fake_sleep = { bind = function() return function(seconds) naps[#naps + 1] = seconds end end }
	local loop = helpers.load_module_with_dependency("adapters.event_loop", "infra.native_sleep", fake_sleep)
	return loop, naps
end

--- Replays the deferred queue; a queued admitted delay is never run here.
--- @param milliseconds number Delay.
--- @return boolean reached
--- @return boolean explained
local function defer_replay(milliseconds)
	local loop = event_loop_fixture()
	return with_errors(function() return loop.defer(function() end, milliseconds) == true end)
end

--- Replays the event loop's blocking sleep.
--- @param milliseconds number Delay.
--- @return boolean reached
--- @return boolean explained
local function sleep_ms_replay(milliseconds)
	local loop, naps = event_loop_fixture()
	return with_errors(function()
		local completed = loop.sleep_ms(milliseconds)
		helpers.assert_eq(completed == true, #naps == 1, "sleep_ms reports exactly the wait it performed")
		return #naps == 1
	end)
end

--- Replays the shared nanosleep binding with a recording FFI double.
--- @param seconds number Delay.
--- @return boolean reached
--- @return boolean explained
local function native_sleep_replay(seconds)
	local calls = 0
	local ffi = {
		cdef = function() end,
		new = function() return { [0] = {} } end,
		errno = function() return 0 end,
		C = { nanosleep = function() calls = calls + 1; return 0 end },
	}
	local sleep = assert(helpers.load_module("infra.native_sleep").bind(ffi))
	local completed, detail = pcall(sleep, seconds)
	local refusal = not completed and tostring(detail) or nil
	helpers.assert_eq(refusal == nil, calls == 1, "nanosleep raises exactly when it refuses")
	return calls == 1, refusal ~= nil and refusal:find("ceiling", 1, true) ~= nil
end

local function non_negative(value) return value >= 0 end

require("test.timer_delay_ceiling_contract").register(helpers, require("infra.paths").shared, {
	{ name = "linux scheduler after", unit = "seconds", replay = scheduler_replay("after") },
	{ name = "linux scheduler every", unit = "seconds", replay = scheduler_replay("every") },
	{ name = "linux native timer start", unit = "milliseconds", replay = native_timer_replay },
	{ name = "linux event loop defer", unit = "milliseconds", replay = defer_replay, lower = non_negative },
	{ name = "linux event loop sleep_ms", unit = "milliseconds", replay = sleep_ms_replay, lower = non_negative },
	{ name = "linux native sleep", unit = "seconds", replay = native_sleep_replay },
})
