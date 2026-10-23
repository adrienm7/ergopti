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
	helpers.it("rejects an unknown counter or span instead of opening a bucket", function()
		local perf = fixture(10)
		helpers.assert_throws(function() perf.count("typed.text") end)
		perf.refresh_timing()
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

helpers.describe("perf counters: level short-circuit", function()
	helpers.it("takes no clock reading and records no span above DEBUG", function()
		local perf = fixture(20)
		perf.refresh_timing()
		helpers.assert_nil(perf.clock(), "clock() must be nil while DEBUG is off")
		perf.span("input.dispatch", perf.clock())
		helpers.assert_eq(perf.snapshot().spans["input.dispatch"].n, 0)
	end)

	helpers.it("times spans once DEBUG is admitted", function()
		local perf = fixture(10)
		helpers.assert_true(perf.refresh_timing())
		local started = perf.clock()
		helpers.assert_type(started, "number")
		perf.span("input.dispatch", started)
		local span = perf.snapshot().spans["input.dispatch"]
		helpers.assert_eq(span.n, 1)
		helpers.assert_true(span.sum_ms >= 0 and span.max_ms >= 0)
	end)

	helpers.it("a counted hot call stays cheap with timing off", function()
		local perf = fixture(20)
		perf.refresh_timing()
		local before = collectgarbage("count")
		collectgarbage("stop")
		for _ = 1, 10000 do
			perf.count("input.events")
			perf.span("input.dispatch", perf.clock())
		end
		local grown = collectgarbage("count") - before
		collectgarbage("restart")
		-- Counted allocation, not wall clock: an off-level call allocates nothing.
		helpers.assert_true(grown < 4, "hot-path counting allocated " .. grown .. " KB")
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

	helpers.it("is never collapsed when two identical intervals follow", function()
		local perf, lines = fixture(20)
		perf.maybe_flush(0)
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS)
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS * 2)
		perf.maybe_flush(perf.FLUSH_INTERVAL_MS * 3)
		helpers.assert_eq(#lines, 3, "evidence records are exempt from the logger's suppression")
	end)
end)
