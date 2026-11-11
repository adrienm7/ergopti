--- tests/unit/infra/test_perf_spans.lua

--- ==============================================================================
--- MODULE: Timing Spans Tests
--- DESCRIPTION:
--- The paths a person waits on carry paired debug lines and their figures
--- reach a field log: trace()/done() spans, a key's age from its kernel stamp,
--- millisecond line timestamps, the boot's load phase, and the last interval
--- summary at shutdown. Each case fails on the code before the instrumentation:
--- no span lines, ":000" on every line, a load phase nobody measured, a short
--- session whose counters never reached the log.
--- ==============================================================================

local helpers = require("tests.support.logger_fixture").helpers({
	"infra.perf_counters", "infra.boot_profiler", "infra.phase_stats", "infra.logger_sink",
})

--- Loads fresh counters and a logger capturing every delivered line.
--- @param level number Logger minimum level.
--- @return table perf, table lines
local function fixture(level)
	package.loaded["logger"] = nil
	package.loaded["logger.shim"] = nil
	local logger = require("logger")
	local lines = {}
	logger.set_sink(function(line) lines[#lines + 1] = line end)
	logger.set_level(level)
	local perf = helpers.load_module("infra.perf_counters")
	perf._reset_for_test()
	return perf, lines
end

--- Returns the lines that contain `needle`.
local function matching(lines, needle)
	local found = {}
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then found[#found + 1] = line end
	end
	return found
end

helpers.describe("timing spans: paired debug lines", function()
	helpers.it("writes a TRACE and a DONE with the span's duration at DEBUG", function()
		local perf, lines = fixture(10)
		local started = perf.trace("tray.fill")
		local elapsed = perf.done("tray.fill", started, "branch root/3, 12 row(s)")
		helpers.assert_type(elapsed, "number")
		local traced = matching(lines, "[Span] tray.fill…")
		local done = matching(lines, "[Span] tray.fill done in ")
		helpers.assert_eq(#traced, 1, "one TRACE line: " .. table.concat(lines, " | "))
		helpers.assert_eq(#done, 1, "one DONE line")
		helpers.assert_contains(traced[1], "[TRACE]")
		helpers.assert_contains(done[1], "[DONE]")
		helpers.assert_contains(done[1], " ms (branch root/3, 12 row(s)).")
		helpers.assert_eq(perf.snapshot().spans["tray.fill"].n, 1)
	end)

	helpers.it("records the span but writes nothing below DEBUG", function()
		local perf, lines = fixture(20)
		perf.done("layout.switch", perf.trace("layout.switch"))
		helpers.assert_eq(#matching(lines, "[Span]"), 0, "no span line at INFO")
		helpers.assert_eq(perf.snapshot().spans["layout.switch"].n, 1, "the aggregate still counts it")
	end)

	helpers.it("refuses an undeclared span name", function()
		local perf = fixture(10)
		helpers.assert_throws(function() perf.trace("typed.text") end)
		helpers.assert_throws(function() perf.record("typed.text", 1) end)
	end)
end)

helpers.describe("timing spans: key age from the kernel stamp", function()
	helpers.it("records a press's age on the wall clock and drops a stepped clock", function()
		local perf = fixture(20)
		local luv = require("luv")
		local seconds, microseconds = luv.gettimeofday()
		local now_us = seconds * 1000000 + microseconds
		perf.record_age("input.latency", now_us - 2500)
		local span = perf.snapshot().spans["input.latency"]
		helpers.assert_eq(span.n, 1)
		helpers.assert_true(span.max_ms >= 2.5 and span.max_ms < 1000, "age in ms: " .. tostring(span.max_ms))
		perf.record_age("input.latency", now_us + 60 * 1000000)
		helpers.assert_eq(perf.snapshot().spans["input.latency"].n, 1, "a stamp in the future measures nothing")
	end)

	helpers.it("names the key's age in the interval summary", function()
		local perf, lines = fixture(20)
		perf.record("input.latency", 3.25)
		perf.flush_now()
		local summary = matching(lines, "[PerfCounters] Interval")
		helpers.assert_eq(#summary, 1)
		helpers.assert_contains(summary[1], "input.latency=1/3.25/3.25ms")
	end)
end)

helpers.describe("timing spans: millisecond line timestamps", function()
	helpers.it("stamps each line with its milliseconds", function()
		local Sink = helpers.load_module("infra.logger_sink")
		local stamp = Sink.timestamp_provider(function() return 1790000000, 123456 end)
		helpers.assert_eq(stamp(), os.date("%Y-%m-%d %H:%M:%S", 1790000000) .. ":123")
		local later = Sink.timestamp_provider(function() return 1790000001, 999 end)
		helpers.assert_eq(later(), os.date("%Y-%m-%d %H:%M:%S", 1790000001) .. ":000")
	end)

	helpers.it("binds luv's wall clock in production", function()
		local Sink = helpers.load_module("infra.logger_sink")
		local stamp = Sink.timestamp_provider()
		helpers.assert_type(stamp, "function", "luv is installed on the unit lane")
		helpers.assert_true(stamp():match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d:%d%d%d$") ~= nil)
	end)
end)

helpers.describe("timing spans: the boot's load phase", function()
	local STAT = "4242 (luajit ergopti (x) y) S 1 4242 4242 0 -1 4194560 3000 0 0 0 30 6 0 0 20 0 1 0 "
		.. "123450 30000000 4000 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0"

	helpers.it("reads the process age from /proc even with spaces and parentheses in its name", function()
		local profiler = helpers.load_module("infra.boot_profiler")
		local age = profiler.process_age_ms(function(path)
			if path == "/proc/uptime" then return "1235.00 9000.00\n" end
			if path == "/proc/self/stat" then return STAT end
		end)
		-- Started at tick 123450 (1234.50 s of uptime), read at 1235.00 s.
		helpers.assert_eq(math.floor(age + 0.5), 500)
		helpers.assert_nil(profiler.process_age_ms(function() return nil end), "unreadable /proc says nothing")
	end)

	helpers.it("names the load phase in the boot summary", function()
		package.loaded["logger"] = nil
		package.loaded["logger.shim"] = nil
		local logger = require("logger")
		local lines = {}
		logger.set_sink(function(line) lines[#lines + 1] = line end)
		logger.set_level(20)
		local profiler = helpers.load_module("infra.boot_profiler")
		profiler._reset_for_test()
		profiler.begin()
		profiler.stage("config"); profiler.stage_done("config")
		profiler.complete()
		local started = matching(lines, "Boot timing started, ")
		helpers.assert_eq(#started, 1, "the process age is read on this Linux host: " .. table.concat(lines, " | "))
		helpers.assert_contains(started[1], " ms after the process")
		local summary = matching(lines, "Boot summary: ")
		helpers.assert_eq(#summary, 1)
		helpers.assert_true(summary[1]:match(" heap=%d+KB load=%d+ms stages: ") ~= nil, summary[1])
	end)
end)

helpers.describe("timing spans: wiring in the daemon", function()
	local function source(path)
		local handle = assert(io.open(helpers.driver_root() .. "/" .. path, "rb"))
		local text = handle:read("*a")
		handle:close()
		return text
	end

	helpers.it("emits the last interval summary at exit, before the final flush", function()
		local entry = source("ergopti_hotstrings.lua")
		local flushed = entry:find('require("infra.perf_counters").flush_now()', 1, true)
		local exiting = entry:find('Logger.info(LOG, "Daemon exiting.")', 1, true)
		helpers.assert_not_nil(flushed, "the shutdown path never flushed the counters")
		helpers.assert_true(flushed < exiting)
	end)

	helpers.it("times the stages the boot summary used to leave between two stages", function()
		local entry = source("ergopti_hotstrings.lua")
		for _, stage in ipairs({ "callbacks", "watchers" }) do
			helpers.assert_contains(entry, 'BootProfiler.stage("' .. stage .. '")')
			helpers.assert_contains(entry, 'BootProfiler.stage_done("' .. stage .. '")')
		end
	end)

	helpers.it("times each tray branch, the layout switch and the catalogue reload", function()
		helpers.assert_contains(source("platform/tray/appindicator.lua"), 'Perf.done("tray.fill"')
		helpers.assert_contains(source("ergopti_hotstrings.lua"), '.done("layout.switch"')
		helpers.assert_contains(source("infra/reload_outcome.lua"), 'Perf.done("config.reload"')
		helpers.assert_contains(source("adapters/keyboard_hook.lua"), 'Perf.record_age("input.latency"')
	end)
end)
