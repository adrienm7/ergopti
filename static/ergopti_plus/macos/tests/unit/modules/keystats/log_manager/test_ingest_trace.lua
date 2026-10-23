-- tests/unit/modules/keystats/log_manager/test_ingest_trace.lua

--- ==============================================================================
--- MODULE: Regression - a slow ingest tick names its dominant phase (issue #101)
--- DESCRIPTION:
--- The ingest timer held the Hammerspoon main thread for 1.0 to 1.4 s, which
--- delayed event taps and the Karabiner lease heartbeat, and the generic
--- slow-callback report could not say which phase dominated. The trace reports
--- one content-free line with per-phase milliseconds, only for a slow tick, at
--- most once per minute. ingest_once must charge every phase to the trace.
--- ==============================================================================

local helpers = require("tests.helpers")

local MS = 1000000

--- Builds a trace over a scripted clock and returns it with its emitted lines.
local function scripted(times_ms)
	local index = 0
	local lines = {}
	local Trace = helpers.load_with_stubs("modules.keystats.ingest_trace")
	Trace.reset_for_tests()
	local trace = Trace.begin(function()
		index = index + 1
		return (times_ms[index] or times_ms[#times_ms]) * MS
	end, function(line) lines[#lines + 1] = line end)
	return trace, lines, Trace
end

helpers.describe("keystats: slow ingest tick names its phase", function()
	helpers.it("emits one compact line charging each phase", function()
		-- clock reads: begin, foreign, commit, finish(notify mark), finish(total)
		local trace, lines = scripted({ 0, 100, 1300, 1310, 1310 })
		trace.count("entries", 7)
		trace.count("statements", 21)
		trace.mark("foreign")
		trace.mark("commit")
		helpers.assert_true(trace.finish(), "a 1.3 s tick must be reported")
		helpers.assert_eq(#lines, 1, "exactly one line")
		helpers.assert_true(lines[1]:find("Slow ingest tick 1310 ms", 1, true) ~= nil, lines[1])
		helpers.assert_true(lines[1]:find("foreign=100", 1, true) ~= nil, lines[1])
		helpers.assert_true(lines[1]:find("commit=1200", 1, true) ~= nil, lines[1])
		helpers.assert_true(lines[1]:find("entries=7 statements=21", 1, true) ~= nil, lines[1])
	end)

	helpers.it("stays silent for a fast tick", function()
		local trace, lines = scripted({ 0, 10, 20, 20 })
		trace.mark("foreign")
		helpers.assert_true(not trace.finish(), "a 20 ms tick is not reported")
		helpers.assert_eq(#lines, 0, "no line")
	end)

	helpers.it("rate-limits a persistently slow tick", function()
		local first, lines, Trace = scripted({ 0, 900, 900 })
		first.mark("apply")
		helpers.assert_true(first.finish(), "first slow tick reports")
		local ticks = { 1000, 1900, 1900 }
		local i = 0
		local again = Trace.begin(function() i = i + 1; return (ticks[i] or ticks[#ticks]) * MS end, function(line) lines[#lines + 1] = line end)
		again.mark("apply")
		helpers.assert_true(not again.finish(), "a second slow tick within a minute is suppressed")
		helpers.assert_eq(#lines, 1, "still one line")
	end)

	helpers.it("ingest_once charges the foreign rebuild, commit and append to the trace", function()
		local src = helpers.read_driver_source("local function _mark_aggregate_cache_rebuilt")
		local body = src:sub(src:find("function M.ingest_once()", 1, true), src:find("Verifies one native ingest timer", 1, true))
		local last = 0
		for _, needle in ipairs({
			'trace.mark("drain")', 'trace.mark("foreign")', 'trace.mark("outbox")',
			'trace.mark("read")', 'trace.mark("build")', 'trace.mark("apply")',
			'trace.mark("commit")', 'trace.mark("append")', "trace.finish()",
		}) do
			local pos = body:find(needle, last + 1, true)
			helpers.assert_true(pos ~= nil, "ingest_once must keep " .. needle .. " in phase order")
			last = pos
		end
	end)
end)
