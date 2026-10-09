--- tests/unit/lib/test_boot_profiler.lua

--- ==============================================================================
--- MODULE: boot_profiler Unit Tests
--- DESCRIPTION:
--- Validates the boot-phase profiler: begin() resets the origin, stage() opens
--- a named stage with a START line, mark() closes it with a SUCCESS line that
--- carries the stage duration, the delta since the previous mark and the
--- running total, and every one of those lines also reaches the synchronous
--- boot journal. current_stage() names the stage a fatal abort interrupted
--- (boot-stage-trail).
---
--- These encode the contract that lets the boot log alone reveal which startup
--- phase dominates, and where a boot died.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Capture every Logger call the profiler makes so we can assert on level + args.
-- The fake is COMPLETE (all 8 variants + helpers) so any other module that loads
-- through it during this test never crashes on a missing method.
local captured = {}
local function reset_capture() captured = {} end
local _real_logger = package.loaded["infra.logger"]
local function capture(lvl)
	return function(tag, fmt, ...)
		captured[#captured + 1] = { lvl = lvl, tag = tag, fmt = fmt, args = { ... } }
	end
end
local function noop() end
package.loaded["infra.logger"] = {
	info    = capture("info"),
	warn    = capture("warn"),
	start   = capture("start"),
	success = capture("success"),
	debug   = noop, trace = noop, done = noop, error = noop,
	is_enabled = function() return true end,
	LEVELS  = { DEBUG = 1, INFO = 2, WARNING = 3, ERROR = 4 },
	FALLBACK_BOOT_LOG_FILE = "/journal/fallback.log",
}

-- Journal writes are captured by path instead of touching real files.
local journal = {}
local function fake_open(path)
	return {
		write = function(_, text)
			journal[#journal + 1] = { path = path, text = text }
			return true
		end,
		flush = function() return true end,
		close = function() return true end,
	}
end

-- Drive independent wall and monotonic clocks. The wall clock deliberately
-- jumps during the first scenario so a duration consumer wired to
-- secondsSinceEpoch() fails while absoluteTime() remains deterministic.
local WALL_SEC = 0
local CLOCK_NS = 0
local orig_sse = hs.timer.secondsSinceEpoch
local orig_abs = hs.timer.absoluteTime
hs.timer.secondsSinceEpoch = function() return WALL_SEC end
hs.timer.absoluteTime = function() return CLOCK_NS end

-- Force fresh modules so the profiler state, the journal and TimerScheduler's
-- monotonic source mapper all start from these controlled clocks.
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["adapters.boot_journal"] = nil
package.loaded["infra.boot_profiler"] = nil
local BootJournal = require("adapters.boot_journal")
local boot = require("infra.boot_profiler")

local LAUNCHER_LOG = "/journal/launcher.log"
local function configure_journal()
	journal = {}
	BootJournal.configure_for_tests({
		open = fake_open,
		clock = function() return "T" end,
		getenv = function(name)
			if name == BootJournal.LAUNCHER_LOG_ENV then return LAUNCHER_LOG end
			return nil
		end,
	})
end

--- Journal lines written to one path.
local function journal_lines(path)
	local lines = {}
	for _, entry in ipairs(journal) do
		if entry.path == path then lines[#lines + 1] = entry.text end
	end
	return lines
end

--- First captured record of one level.
local function first(lvl)
	for _, record in ipairs(captured) do
		if record.lvl == lvl then return record end
	end
	return nil
end

helpers.describe("infra.boot_profiler stages (boot-stage-trail)", function()
	helpers.it("closes each stage with its duration, delta and total in ms", function()
		configure_journal()
		reset_capture()
		WALL_SEC = 100.0
		CLOCK_NS = 1e12
		boot.begin()
		boot.stage("Phase A")
		WALL_SEC = 50.0              -- NTP correction must not affect duration.
		CLOCK_NS = CLOCK_NS + 20e6   -- +20 ms monotonic.
		boot.mark("Phase A")
		boot.stage("Phase B")
		WALL_SEC = 1000.0            -- A later wall-clock jump is also irrelevant.
		CLOCK_NS = CLOCK_NS + 50e6   -- +50 ms (total 70 ms).
		boot.mark("Phase B")

		local successes = {}
		for _, record in ipairs(captured) do
			if record.lvl == "success" then successes[#successes + 1] = record end
		end
		local a, b = successes[1], successes[2]
		helpers.assert_eq(a.args[1], "Phase A")
		helpers.assert_true(math.abs(a.args[2] - 20) < 0.5, "Phase A duration ≈ 20 ms")
		helpers.assert_true(math.abs(a.args[3] - 20) < 0.5, "Phase A delta ≈ 20 ms")
		helpers.assert_true(math.abs(a.args[4] - 20) < 0.5, "Phase A total ≈ 20 ms")
		helpers.assert_eq(b.args[1], "Phase B")
		helpers.assert_true(math.abs(b.args[3] - 50) < 0.5, "Phase B delta ≈ 50 ms")
		helpers.assert_true(math.abs(b.args[4] - 70) < 0.5, "Phase B total ≈ 70 ms")
	end)

	helpers.it("every stage produces a START and a SUCCESS line in the log and the journal", function()
		configure_journal()
		reset_capture()
		CLOCK_NS = 3e9
		boot.begin()
		boot.stage("Path: log file open")
		CLOCK_NS = CLOCK_NS + 4e6
		boot.mark("Path: log file open")

		local start = first("start")
		helpers.assert_true(start ~= nil and start.args[1] == "Path: log file open",
			"stage() must emit a START line naming the stage")
		helpers.assert_eq(first("success").args[1], "Path: log file open")
		local fallback = table.concat(journal_lines("/journal/fallback.log"))
		helpers.assert_contains(fallback, "T [START] [init] Boot stage started: Path: log file open.\n")
		helpers.assert_contains(fallback, "T [SUCCESS] [init] Boot stage completed: Path: log file open in 4.0 ms")
		helpers.assert_contains(table.concat(journal_lines(LAUNCHER_LOG)),
			"[T] embedded Hammerspoon boot START: Boot stage started: Path: log file open.\n")
	end)

	helpers.it("stops copying stages to launcher.log once the user log folder is ready", function()
		configure_journal()
		boot.begin()
		BootJournal.set_user_log_ready(true)
		boot.stage("Keymap engine started")
		boot.mark("Keymap engine started")
		helpers.assert_eq(#journal_lines(LAUNCHER_LOG), 1, "only begin() preceded readiness")
		helpers.assert_contains(table.concat(journal_lines("/journal/fallback.log")),
			"Boot stage completed: Keymap engine started")
	end)

	helpers.it("names the interrupted stage for a fatal report", function()
		configure_journal()
		package.loaded["infra.boot_profiler"] = nil
		local fresh = require("infra.boot_profiler")
		helpers.assert_eq(fresh.current_stage(), "before boot timing")
		fresh.begin()
		fresh.stage("UI: karabiner.init")
		helpers.assert_eq(fresh.current_stage(), "UI: karabiner.init")
		fresh.mark("UI: karabiner.init")
		helpers.assert_eq(fresh.current_stage(), "after UI: karabiner.init")
		helpers.assert_eq(fresh.is_complete(), false)
		fresh.complete()
		helpers.assert_eq(fresh.is_complete(), true)
	end)

	helpers.it("records the whole boot duration once", function()
		configure_journal()
		reset_capture()
		CLOCK_NS = 7e9
		boot.begin()
		CLOCK_NS = CLOCK_NS + 1234e6
		boot.complete()
		local done = first("success")
		helpers.assert_eq(done.fmt, "Boot complete in %.0f ms.")
		helpers.assert_true(math.abs(done.args[1] - 1234) < 0.5, "boot complete ≈ 1234 ms")
		helpers.assert_contains(table.concat(journal_lines("/journal/fallback.log")), "Boot complete in 1234 ms.")
	end)

	helpers.it("warns when a mark closes no matching open stage", function()
		configure_journal()
		reset_capture()
		boot.begin()
		boot.mark("Never opened")
		local warning = first("warn")
		helpers.assert_true(warning ~= nil and warning.args[1] == "Never opened",
			"an unpaired mark must be visible in the log")
	end)

	helpers.it("elapsed_ms reports the running total without logging", function()
		CLOCK_NS = 200e9
		boot.begin()
		reset_capture()
		CLOCK_NS = CLOCK_NS + 250e6
		local e = boot.elapsed_ms()
		helpers.assert_true(math.abs(e - 250) < 0.5, "elapsed ≈ 250 ms")
		helpers.assert_eq(#captured, 0, "elapsed_ms must not emit a log line")
	end)

	helpers.it("a mark before begin() anchors the origin (no huge/negative total)", function()
		-- Fresh module instance to guarantee _start == 0 (never began).
		package.loaded["infra.boot_profiler"] = nil
		local fresh = require("infra.boot_profiler")
		reset_capture()
		CLOCK_NS = 999e9
		fresh.mark("Orphan mark")
		local m = first("success")
		helpers.assert_true(m.args[3] >= 0 and m.args[3] < 0.5, "delta anchored to ~0")
		helpers.assert_true(m.args[4] >= 0 and m.args[4] < 0.5, "total anchored to ~0")
	end)
end)

-- Restore the real stub clocks, journal and logger so later test files are
-- unaffected; drop the adapters so they re-capture the real logger on next load.
BootJournal.configure_for_tests(nil)
hs.timer.secondsSinceEpoch = orig_sse
hs.timer.absoluteTime = orig_abs
package.loaded["infra.logger"] = _real_logger
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["adapters.boot_journal"] = nil
package.loaded["infra.boot_profiler"] = nil
