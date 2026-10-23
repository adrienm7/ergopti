--- tests/unit/adapters/runtime/test_event_loop_idle_wait.lua

--- ==============================================================================
--- MODULE: Event Loop Idle Wait Tests
--- DESCRIPTION:
--- libuv polls with a zero timeout while an idle handle is active, so the luv
--- loop used to spin a whole core (measured 99.997 % of one core, 180 000 idle
--- ticks per second, with nothing to do). The tick now yields: it sleeps on the
--- input descriptors when the daemon supplies a wait, and a fixed millisecond
--- otherwise. The ceilings below count idle ticks over a real libuv run, which
--- are two orders of magnitude apart, so they hold on a loaded machine.
--- ==============================================================================

local helpers = require("tests.helpers")
local ok_luv, luv = pcall(require, "luv")

--- Runs the real loop for `window_ms` and counts its idle ticks.
--- @param options table Extra run options (idleWait).
--- @param window_ms number Run length.
--- @return number ticks, table loop
local function count_ticks(options, window_ms)
	local loop = helpers.load_module("adapters.event_loop")
	local ticks, started = 0, luv.hrtime()
	local run_options = { onIdle = function()
		ticks = ticks + 1
		if (luv.hrtime() - started) / 1e6 >= window_ms then loop.stop() end
	end }
	for key, value in pairs(options or {}) do run_options[key] = value end
	loop.run(run_options)
	return ticks, loop
end

if not ok_luv then
	helpers.describe("event loop idle wait", function()
		helpers.it("needs the real luv backend", function()
			helpers.assert_true(false, "the unit lane installs luv; this module measures its real loop")
		end)
	end)
	return
end

helpers.describe("event loop idle wait: the luv idle tick yields", function()
	helpers.it("does not spin without an input wait (about a millisecond per tick)", function()
		local ticks = count_ticks(nil, 300)
		helpers.assert_true(ticks > 0)
		-- A spinning loop ran tens of thousands of ticks in this window.
		helpers.assert_true(ticks < 5000, "idle loop spun: " .. ticks .. " ticks in 300 ms")
	end)

	helpers.it("sleeps in the supplied wait and passes it the cadence bound", function()
		local sleep = require("infra.native_sleep").bind(require("ffi"))
		local requested = {}
		local ticks = count_ticks({ idleWait = function(timeout_ms)
			requested[#requested + 1] = timeout_ms
			sleep(timeout_ms / 1000)
			return false
		end }, 300)
		helpers.assert_true(#requested > 0, "the wait was never consulted")
		helpers.assert_eq(requested[1], 8, "bounded by the loop's cadence")
		helpers.assert_true(ticks < 500, "wait did not slow the tick: " .. ticks .. " ticks")
	end)

	helpers.it("counts input wakes and quiet waits", function()
		local loop = helpers.load_module("adapters.event_loop")
		local perf = require("infra.perf_counters")
		perf._reset_for_test()
		local answers, calls = { true, false, true }, 0
		loop.run({
			onIdle = function() if calls >= #answers then loop.stop() end end,
			idleWait = function() calls = calls + 1; return answers[calls] end,
		})
		local counts = perf.snapshot().counts
		helpers.assert_eq(counts["loop.idle_wakes_input"], 2)
		helpers.assert_eq(counts["loop.idle_timeouts"], 1)
	end)

	helpers.it("falls back to the fixed yield when the wait declines", function()
		local declined = 0
		local ticks = count_ticks({ idleWait = function() declined = declined + 1; return nil end }, 300)
		helpers.assert_true(declined > 0)
		helpers.assert_true(ticks < 5000, "declined wait spun the loop: " .. ticks .. " ticks")
	end)

	helpers.it("drops a raising wait after one report and keeps running", function()
		local raised = 0
		local ticks = count_ticks({ idleWait = function() raised = raised + 1; error("wait refused") end }, 200)
		helpers.assert_eq(raised, 1, "a raising wait must be dropped, not retried on every tick")
		helpers.assert_true(ticks > 1 and ticks < 5000)
	end)

	helpers.it("returns at once when a callback stops the loop", function()
		local loop = helpers.load_module("adapters.event_loop")
		local waited = 0
		loop.run({ onIdle = function() loop.stop() end, idleWait = function() waited = waited + 1; return false end })
		helpers.assert_eq(waited, 0, "stop() must not be followed by a wait")
	end)

	helpers.it("refuses a wait that is not a function", function()
		local loop = helpers.load_module("adapters.event_loop")
		helpers.assert_throws(function() loop.run({ onIdle = function() end, idleWait = 8 }) end)
		helpers.assert_true(not loop.isRunning())
	end)
end)
