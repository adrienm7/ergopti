--- tests/unit/infra/test_perf_counters.lua

--- ==============================================================================
--- MODULE: Performance Counters Tests
--- DESCRIPTION:
--- The permanent timing and count instrumentation must stay closed (no typed
--- text, no free-form names), cost one table increment while the logger is
--- above DEBUG, and report one never-collapsed evidence line per interval.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads fresh counters and a logger capturing every delivered line.
--- @param level number Logger minimum level.
--- @return table perf, table lines, table logger
local function fixture(level)
	package.loaded["logger"] = nil
	package.loaded["logger.shim"] = nil
	local logger = require("logger")
	local lines = {}
	logger.set_sink(function(line) lines[#lines + 1] = line end)
	logger.set_level(level)
	local perf = helpers.load_module("infra.perf_counters")
	perf._reset_for_test()
	return perf, lines, logger
end

helpers.describe("perf counters: closed names and aggregation", function()
	helpers.it("loads without reading the timings registry, as shell_runner workers require it", function()
		-- Child workers load shell_runner with a minimal logger shim: a registry
		-- parse at require time made every one of them exit on the missing logger level.
		-- A refused infra.timings raises here, failing the case, if require reads it.
		local perf = helpers.load_module_with_dependency("infra.perf_counters", "infra.timings", false)
		package.loaded["infra.perf_counters"] = nil
		helpers.assert_eq(type(perf.span), "function")
	end)

	helpers.it("rejects an unknown counter or span instead of opening a bucket", function()
		local perf = fixture(10)
		helpers.assert_throws(function() perf.count("typed.text") end)
		helpers.assert_throws(function() perf.span("typed.text", perf.clock()) end)
	end)

	helpers.it("adds counts and reports lifetime totals through snapshot", function()
		local perf = fixture(20)
		perf.count("input.events")
		perf.count("input.events", 4)
		helpers.assert_eq(perf.snapshot().counts["input.events"], 5)
		helpers.assert_eq(perf.snapshot().counts["input.key_events"], 0)
	end)
end)

helpers.describe("perf counters: spans are always timed", function()
	helpers.it("times a span at the production level, with no DEBUG needed", function()
		local perf = fixture(40)
		local started = perf.clock()
		helpers.assert_type(started, "number")
		perf.span("input.dispatch", started)
		local span = perf.snapshot().spans["input.dispatch"]
		helpers.assert_eq(span.n, 1, "a span at ERROR level must still be recorded")
		helpers.assert_true(span.sum_ms >= 0 and span.max_ms >= 0)
	end)

	helpers.it("refuses a span closed without a clock stamp", function()
		local perf = fixture(20)
		helpers.assert_throws(function() perf.span("input.dispatch", nil) end)
	end)

	--- Counts the Lua heap growth of 10000 counted and timed hot calls. The
	--- clock is stepped by clock_step_ms per read, not read from the machine: a
	--- CI container preempted for more than the 5 ms slow threshold during one
	--- iteration made that span slow, and its HotPath WARNING (about 1.5 KB of
	--- report tables and log text) failed the Arch row with 1.64 KB. A fast span
	--- is the code under test; the slow path allocates its warning by design.
	--- @param perf table Loaded perf counters.
	--- @param clock_step_ms number Milliseconds the clock advances per read.
	--- @return number grown_kb
	local function hot_call_growth(perf, clock_step_ms)
		-- The first closed span builds the slow-threshold table once; that
		-- lazy setup is not the hot call, so it happens before the count.
		perf.span("input.dispatch", perf.clock())
		local Monotonic = require("infra.monotonic")
		local machine_clock = Monotonic.now_ms
		local stepped = machine_clock()
		Monotonic.now_ms = function()
			stepped = stepped + clock_step_ms
			return stepped
		end
		-- LuaJIT's trace compiler allocates its IR on the Lua heap whenever it
		-- happens to record this loop, which made the count flaky (4 to 5 KB on
		-- the distribution rows). Only the interpreter's own allocations are
		-- the code under test, so the compiler is off while counting.
		local compiler = rawget(_G, "jit")
		if compiler then compiler.off() end
		local before = collectgarbage("count")
		collectgarbage("stop")
		local counted, failure = pcall(function()
			for _ = 1, 10000 do
				perf.count("input.events")
				perf.span("input.dispatch", perf.clock())
			end
		end)
		local grown = collectgarbage("count") - before
		collectgarbage("restart")
		if compiler then compiler.on() end
		Monotonic.now_ms = machine_clock
		if not counted then error(failure, 0) end
		return grown
	end

	helpers.it("a counted and timed hot call allocates nothing", function()
		local perf, lines = fixture(20)
		local grown = hot_call_growth(perf, 0.001)
		-- Counted allocation, not wall clock: a fast span builds no string.
		helpers.assert_true(grown < 1, "hot-path timing allocated " .. grown .. " KB")
		helpers.assert_eq(#lines, 0, "no span of the counted window may be slow")
	end)

	helpers.it("a preempted machine clock cannot make the hot-call count allocate", function()
		local perf, lines = fixture(20)
		local Monotonic = require("infra.monotonic")
		local machine_clock = Monotonic.now_ms
		local reads = 0
		-- Every 1000th read jumps 7 ms, as a descheduled CI container does.
		Monotonic.now_ms = function()
			reads = reads + 1
			return machine_clock() + math.floor(reads / 1000) * 7
		end
		local measured, result = pcall(hot_call_growth, perf, 0.001)
		Monotonic.now_ms = machine_clock
		if not measured then error(result, 0) end
		helpers.assert_true(result < 1, "a preempted span allocated " .. result .. " KB")
		helpers.assert_eq(#lines, 0, "the stepped clock must hide machine preemption")
	end)

	helpers.it("the hot-call count sees the slow-span warning allocation", function()
		-- Sensitivity check: the measurement is able to fail. Every span over
		-- the threshold builds and logs its report.
		local perf = fixture(20)
		local grown = hot_call_growth(perf, 6)
		helpers.assert_true(grown >= 1, "slow spans allocated only " .. grown .. " KB")
	end)

	helpers.it("reading the machine clock allocates nothing", function()
		local Monotonic = require("infra.monotonic")
		local compiler = rawget(_G, "jit")
		if compiler then compiler.off() end
		local before = collectgarbage("count")
		collectgarbage("stop")
		local read, failure = pcall(function()
			for _ = 1, 10000 do Monotonic.now_ms() end
		end)
		local grown = collectgarbage("count") - before
		collectgarbage("restart")
		if compiler then compiler.on() end
		if not read then error(failure, 0) end
		helpers.assert_true(grown < 1, "the monotonic clock allocated " .. grown .. " KB")
	end)
end)

helpers.describe("perf counters: slow segments", function()
	local Segments = require("hotpath_segments")
	local SLOW_MS = require("infra.timings").ms("logger", "hotpath_slow_ms")

	helpers.it("warns once with the name and duration when a segment exceeds its threshold", function()
		local perf, lines = fixture(30)
		perf.span("input.dispatch", perf.clock() - (SLOW_MS + 5))
		helpers.assert_eq(#lines, 1)
		helpers.assert_contains(lines[1], "[HotPath]")
		helpers.assert_contains(lines[1], "Slow input.dispatch: ")
		helpers.assert_eq(perf.snapshot().spans["input.dispatch"].slow, 1)
	end)

	helpers.it("warns for a 6 ms segment, the 5 ms threshold shared with Windows", function()
		local perf, lines = fixture(30)
		perf.span("input.dispatch", perf.clock() - 6)
		helpers.assert_eq(#lines, 1, "6 ms is over 5 ms; the old 20 ms threshold stayed silent")
	end)

	helpers.it("stays silent for a segment under its threshold", function()
		local perf, lines = fixture(10)
		perf.span("hotstring.match", perf.clock() - (SLOW_MS - 2))
		helpers.assert_eq(#lines, 0, "a healthy keystroke produces no log line")
		helpers.assert_eq(perf.snapshot().spans["hotstring.match"].slow, 0)
	end)

	helpers.it("never warns for a span that is not an inventory segment", function()
		local perf, lines = fixture(10)
		perf.span("loop.idle", perf.clock() - 5000)
		helpers.assert_eq(#lines, 0, "an idle wait is long by design")
		helpers.assert_eq(perf.snapshot().spans["loop.idle"].n, 1, "it is still timed")
	end)

	helpers.it("logs a repeating slow segment once per window yet counts every occurrence", function()
		local perf, lines = fixture(30)
		for _ = 1, 5 do perf.span("input.dispatch", perf.clock() - (SLOW_MS + 5)) end
		helpers.assert_eq(#lines, 1, "the repeats inside the window are not logged")
		helpers.assert_eq(perf.snapshot().spans["input.dispatch"].slow, 5, "the count stays exact")
		perf.span("hotstring.match", perf.clock() - (SLOW_MS + 5))
		helpers.assert_eq(#lines, 2, "another segment has its own window")
	end)

	helpers.it("reports the slow count in the interval summary", function()
		local perf, lines = fixture(20)
		perf.maybe_flush(0)
		perf.span("hotstring.expand", perf.clock() - 50)
		lines[#lines] = nil -- the warning itself
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS)
		helpers.assert_contains(lines[#lines], "hotstring.expand.slow=1")
	end)
end)

helpers.describe("perf counters: interval summary", function()
	helpers.it("emits one evidence line per interval with names and numbers only", function()
		local perf, lines = fixture(20)
		helpers.assert_eq(perf.maybe_flush(0), false, "the first call only opens the interval")
		perf.count("input.events", 3)
		perf.count("hotstring.matches")
		helpers.assert_eq(perf.maybe_flush(perf.FLUSH_INTERVAL_MS - 1), false)
		helpers.assert_eq(#lines, 0)
		helpers.assert_eq(perf.maybe_flush(perf.FLUSH_INTERVAL_MS), true)
		helpers.assert_eq(#lines, 1)
		helpers.assert_contains(lines[1], "input.events=3")
		helpers.assert_contains(lines[1], "hotstring.matches=1")
		helpers.assert_contains(lines[1], "heap=")
		helpers.assert_true(not lines[1]:find("input.key_events", 1, true), "zero counters stay out of the line")
	end)

	helpers.it("resets the interval but keeps lifetime totals", function()
		local perf, lines = fixture(20)
		perf.maybe_flush(0)
		perf.count("input.events", 2)
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS)
		perf.count("input.events", 5)
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS * 2)
		helpers.assert_contains(lines[2], "input.events=5")
		helpers.assert_eq(perf.snapshot().counts["input.events"], 7)
	end)

	helpers.it("carries the log-volume figures of the interval in the evidence record", function()
		local perf, lines, logger = fixture(20)
		logger.reset_volume()
		perf.maybe_flush(0)
		logger.debug("PerfTest", "below the threshold")
		logger.warn("PerfTest", "one warning")
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS)
		helpers.assert_contains(lines[2], "| log: debug=0 info=0 warn=1 error=0 dropped=1 suppressed=0 collapsed=0")
	end)

	helpers.it("is never collapsed when two identical intervals follow", function()
		local perf, lines = fixture(20)
		perf.maybe_flush(0)
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS)
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS * 2)
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS * 3)
		helpers.assert_eq(#lines, 3, "evidence records are exempt from the logger's suppression")
	end)
end)

helpers.describe("perf counters: nesting attribution", function()
	--- Loads fresh counters on a clock the case moves by hand.
	local function clocked()
		local clock = { now = 1000 }
		package.loaded["logger"] = nil
		package.loaded["logger.shim"] = nil
		local logger = require("logger")
		local lines = {}
		logger.set_sink(function(line) lines[#lines + 1] = line end)
		logger.set_level(30)
		local perf = helpers.load_module_with_dependency("infra.perf_counters", "infra.monotonic",
			{ now_ms = function() return clock.now end })
		perf._reset_for_test()
		return perf, lines, clock
	end

	helpers.it("reports a slow expansion with the dispatch around it and does not bill the dispatch", function()
		local perf, lines, clock = clocked()
		local dispatch = perf.clock()
		clock.now = clock.now + 1
		local expand = perf.clock()
		clock.now = clock.now + 12
		perf.span("hotstring.expand", expand)
		helpers.assert_eq(#lines, 0, "the child waits for its parent to be named")
		clock.now = clock.now + 1
		helpers.assert_eq(perf.span("input.dispatch", dispatch), 14, "the span still returns its wall clock")
		helpers.assert_eq(#lines, 1, "one line: the dispatch's own 2 ms is under the threshold")
		helpers.assert_contains(lines[1], "Slow hotstring.expand: 12.00 ms own, 12.00 ms total, parent input.dispatch")
		local spans = perf.snapshot().spans
		helpers.assert_eq(spans["hotstring.expand"].slow, 1)
		helpers.assert_eq(spans["input.dispatch"].slow, 0, "the dispatch is judged on its own time")
		helpers.assert_eq(spans["input.dispatch"].max_ms, 14, "the summary keeps the wall clock")
	end)

	helpers.it("names no parent when only an idle wait encloses the segment", function()
		local perf, lines, clock = clocked()
		local idle = perf.clock()
		local dispatch = perf.clock()
		clock.now = clock.now + 8
		perf.span("input.dispatch", dispatch)
		clock.now = clock.now + 100
		perf.span("loop.idle", idle)
		helpers.assert_eq(#lines, 1)
		helpers.assert_contains(lines[1], "Slow input.dispatch: 8.00 ms own, 8.00 ms total, parent none")
	end)
end)
