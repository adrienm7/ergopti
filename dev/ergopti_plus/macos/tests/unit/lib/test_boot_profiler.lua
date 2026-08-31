--- tests/unit/lib/test_boot_profiler.lua

--- ==============================================================================
--- MODULE: boot_profiler Unit Tests
--- DESCRIPTION:
--- Validates the ported boot-phase profiler: begin() resets the origin, mark()
--- emits one INFO line per phase with the correct delta-since-previous and
--- running total, marks accumulate over time, and a mark fired before begin()
--- anchors the origin instead of logging a nonsensical total.
---
--- These encode the contract that lets the boot log alone reveal which startup
--- phase dominates — the whole reason the AHK driver shipped this tool.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Capture every Logger call the profiler makes so we can assert on level + args.
-- The fake is COMPLETE (all 8 variants + helpers) so any other module that loads
-- through it during this test never crashes on a missing method.
local captured = {}
local function reset_capture() captured = {} end
local _real_logger = package.loaded["infra.logger"]
local function noop() end
package.loaded["infra.logger"] = {
	info    = function(tag, fmt, ...) captured[#captured + 1] = { lvl = "info", tag = tag, fmt = fmt, args = { ... } } end,
	warn    = function(tag, fmt, ...) captured[#captured + 1] = { lvl = "warn", tag = tag, fmt = fmt, args = { ... } } end,
	debug   = noop, trace = noop, done = noop, start = noop, success = noop, error = noop,
	is_enabled = function() return true end,
	LEVELS  = { DEBUG = 1, INFO = 2, WARNING = 3, ERROR = 4 },
}

-- Drive independent wall and monotonic clocks. The wall clock deliberately
-- jumps during the first scenario so a duration consumer wired to
-- secondsSinceEpoch() fails while absoluteTime() remains deterministic.
local WALL_SEC = 0
local CLOCK_NS = 0
local orig_sse = hs.timer.secondsSinceEpoch
local orig_abs = hs.timer.absoluteTime
hs.timer.secondsSinceEpoch = function() return WALL_SEC end
hs.timer.absoluteTime = function() return CLOCK_NS end

-- Force fresh modules so the profiler state and TimerScheduler's monotonic
-- source mapper both start from these controlled clocks.
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["infra.boot_profiler"] = nil
local boot = require("infra.boot_profiler")

helpers.describe("infra.boot_profiler.mark", function()
	helpers.it("emits one INFO line per phase with delta and total in ms", function()
		reset_capture()
		WALL_SEC = 100.0
		CLOCK_NS = 1e12
		boot.begin()
		WALL_SEC = 50.0              -- NTP correction must not affect duration.
		CLOCK_NS = CLOCK_NS + 20e6   -- +20 ms monotonic.
		boot.mark("Phase A")
		WALL_SEC = 1000.0            -- A later wall-clock jump is also irrelevant.
		CLOCK_NS = CLOCK_NS + 50e6   -- +50 ms (total 70 ms).
		boot.mark("Phase B")

		-- captured[1] = begin's "Boot timing started." INFO line
		local a = captured[2]
		local b = captured[3]
		helpers.assert_eq(a.lvl, "info")
		helpers.assert_eq(a.args[1], "Phase A")
		helpers.assert_true(math.abs(a.args[2] - 20) < 0.5, "Phase A delta ≈ 20 ms")
		helpers.assert_true(math.abs(a.args[3] - 20) < 0.5, "Phase A total ≈ 20 ms")
		helpers.assert_eq(b.args[1], "Phase B")
		helpers.assert_true(math.abs(b.args[2] - 50) < 0.5, "Phase B delta ≈ 50 ms")
		helpers.assert_true(math.abs(b.args[3] - 70) < 0.5, "Phase B total ≈ 70 ms")
	end)

	helpers.it("begin() resets the origin so totals restart", function()
		reset_capture()
		CLOCK_NS = 5e9
		boot.begin()
		CLOCK_NS = CLOCK_NS + 100e6
		boot.mark("After reset")
		local m = captured[2]
		helpers.assert_true(math.abs(m.args[3] - 100) < 0.5, "total restarts from the new begin()")
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
		local m = captured[1]
		helpers.assert_true(m.args[2] >= 0 and m.args[2] < 0.5, "delta anchored to ~0")
		helpers.assert_true(m.args[3] >= 0 and m.args[3] < 0.5, "total anchored to ~0")
	end)
end)

-- Restore the real stub clocks and the real logger so later test files are
-- unaffected; drop the adapter so it re-captures the real logger on next load.
hs.timer.secondsSinceEpoch = orig_sse
hs.timer.absoluteTime = orig_abs
package.loaded["infra.logger"] = _real_logger
package.loaded["adapters.timer_scheduler"] = nil
