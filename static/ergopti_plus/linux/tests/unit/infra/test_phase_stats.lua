--- tests/unit/infra/test_phase_stats.lua

--- ==============================================================================
--- MODULE: Phase Stats Tests (Linux driver)
--- DESCRIPTION:
--- The Linux PhaseStats must keep the figures of the shared core, flush one
--- never-collapsed evidence line per family on the event loop's tick, and time
--- every child process the shell runner reports as process.<program>, the
--- phases the macOS driver already records.
--- ==============================================================================

local helpers = require("tests.helpers")

local MS = 1e6

--- Loads fresh stats and a logger capturing every delivered line.
--- @param level number Logger minimum level.
--- @return table stats, table lines
local function fixture(level)
	package.loaded["logger"] = nil
	package.loaded["logger.shim"] = nil
	local logger = require("logger")
	local lines = {}
	logger.set_sink(function(line) lines[#lines + 1] = line end)
	logger.set_level(level)
	local stats = helpers.load_module("infra.phase_stats")
	stats._reset_for_test()
	return stats, lines
end

helpers.describe("phase stats: recording", function()
	helpers.it("keeps count, total and maximum per phase", function()
		local stats = fixture(20)
		stats.add("process.curl", 1 * MS)
		stats.add("process.curl", 3 * MS)
		local figures = stats.figures("process.curl")
		helpers.assert_eq(figures.n, 2)
		helpers.assert_true(math.abs(figures.total_ms - 4) < 1e-9)
		helpers.assert_true(math.abs(figures.max_ms - 3) < 1e-9)
	end)

	helpers.it("closes a phase opened with now() on the monotonic clock", function()
		local stats = fixture(20)
		local ns = 100 * MS
		stats.use_clock(function() return ns end)
		local started = stats.now()
		ns = 107 * MS
		helpers.assert_true(math.abs(stats.stop("boot.stage", started) - 7) < 1e-9)
	end)
end)

helpers.describe("phase stats: interval summary", function()
	helpers.it("emits one evidence line per family plus the memory line", function()
		local stats, lines = fixture(20)
		stats.add("process.xdotool", 2 * MS)
		stats.add("boot.stage", 40 * MS)
		stats.count("process.timeouts")
		helpers.assert_eq(stats.flush(300), 3, "boot, process and memory")
		helpers.assert_contains(lines[1], "Phase summary [boot] over 300 s")
		helpers.assert_contains(lines[2], "[process]")
		helpers.assert_contains(lines[2], "xdotool n=1")
		helpers.assert_contains(lines[2], "#timeouts=1")
		helpers.assert_contains(lines[3], "Memory snapshot")
	end)

	helpers.it("formats nothing below INFO but still clears the figures", function()
		local stats, lines = fixture(30)
		stats.add("process.curl", 1 * MS)
		helpers.assert_eq(stats.flush(300), 0)
		helpers.assert_eq(#lines, 0)
		helpers.assert_nil(stats.figures("process.curl"))
	end)

	helpers.it("flushes on the event loop tick once an interval has elapsed", function()
		local stats, lines = fixture(20)
		helpers.assert_eq(stats.maybe_flush(0), false, "the first tick only opens the interval")
		stats.add("process.curl", 1 * MS)
		helpers.assert_eq(stats.maybe_flush(stats.DEFAULT_INTERVAL_SEC * 1000 - 1), false)
		helpers.assert_eq(#lines, 0)
		helpers.assert_eq(stats.maybe_flush(stats.DEFAULT_INTERVAL_SEC * 1000), true)
		helpers.assert_contains(lines[1], "Phase summary [process]")
		helpers.assert_nil(stats.figures("process.curl"), "the interval starts empty")
	end)
end)

helpers.describe("phase stats: child processes", function()
	helpers.it("times a synchronous child as process.<program> through the shell runner", function()
		local stats = fixture(20)
		local runner = helpers.load_module("adapters.shell_runner")
		helpers.assert_true(runner.run("true"))
		local figures = stats.figures("process.true")
		helpers.assert_not_nil(figures, "the runner must record the child's duration")
		helpers.assert_eq(figures.n, 1)
	end)

	helpers.it("names the program, never the command line", function()
		local stats, lines = fixture(20)
		local runner = helpers.load_module("adapters.shell_runner")
		runner.run("true --secret-argument-4711")
		stats.flush(300)
		helpers.assert_true(not table.concat(lines, "\n"):find("4711", 1, true),
			"an argument must not reach a phase name")
	end)
end)
