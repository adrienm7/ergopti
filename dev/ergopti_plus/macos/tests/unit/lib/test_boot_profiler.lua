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
local _real_logger = package.loaded["lib.logger"]
local function noop() end
package.loaded["lib.logger"] = {
	info    = function(tag, fmt, ...) captured[#captured + 1] = { lvl = "info", tag = tag, fmt = fmt, args = { ... } } end,
	warn    = function(tag, fmt, ...) captured[#captured + 1] = { lvl = "warn", tag = tag, fmt = fmt, args = { ... } } end,
	debug   = noop, trace = noop, done = noop, start = noop, success = noop, error = noop,
	is_enabled = function() return true end,
	LEVELS  = { DEBUG = 1, INFO = 2, WARNING = 3, ERROR = 4 },
}

-- Force a fresh module so its module-level _start/_last reset for this file.
-- Also drop the adapter so it re-captures the fake logger for this run.
package.loaded["adapters.timer_scheduler"] = nil
package.loaded["lib.boot_profiler"] = nil
local boot = require("lib.boot_profiler")

-- Drive a controllable wall-clock so deltas are deterministic. Saved and
-- restored at file end so later test files keep the real stub clock.
local CLOCK_SEC      = 0
local orig_sse       = hs.timer.secondsSinceEpoch
hs.timer.secondsSinceEpoch = function() return CLOCK_SEC end

helpers.describe("lib.boot_profiler.mark", function()
	helpers.it("emits one INFO line per phase with delta and total in ms", function()
		reset_capture()
		CLOCK_SEC = 100.0
		boot.begin()                 -- origin at 100.0 s; emits a "started" line
		CLOCK_SEC = 100.020          -- +20 ms
		boot.mark("Phase A")
		CLOCK_SEC = 100.070          -- +50 ms (total 70 ms)
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
		CLOCK_SEC = 5.0
		boot.begin()
		CLOCK_SEC = 5.100
		boot.mark("After reset")
		local m = captured[2]
		helpers.assert_true(math.abs(m.args[3] - 100) < 0.5, "total restarts from the new begin()")
	end)

	helpers.it("elapsed_ms reports the running total without logging", function()
		CLOCK_SEC = 200.0
		boot.begin()
		reset_capture()
		CLOCK_SEC = 200.250
		local e = boot.elapsed_ms()
		helpers.assert_true(math.abs(e - 250) < 0.5, "elapsed ≈ 250 ms")
		helpers.assert_eq(#captured, 0, "elapsed_ms must not emit a log line")
	end)

	helpers.it("a mark before begin() anchors the origin (no huge/negative total)", function()
		-- Fresh module instance to guarantee _start == 0 (never began).
		package.loaded["lib.boot_profiler"] = nil
		local fresh = require("lib.boot_profiler")
		reset_capture()
		CLOCK_SEC = 999.0
		fresh.mark("Orphan mark")
		local m = captured[1]
		helpers.assert_true(m.args[2] >= 0 and m.args[2] < 0.5, "delta anchored to ~0")
		helpers.assert_true(m.args[3] >= 0 and m.args[3] < 0.5, "total anchored to ~0")
	end)
end)

-- Restore the real stub clock and the real logger so later test files are
-- unaffected; drop the adapter so it re-captures the real logger on next load.
hs.timer.secondsSinceEpoch = orig_sse
package.loaded["lib.logger"] = _real_logger
package.loaded["adapters.timer_scheduler"] = nil
