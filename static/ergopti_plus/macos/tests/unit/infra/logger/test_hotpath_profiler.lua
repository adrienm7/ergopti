--- tests/unit/infra/logger/test_hotpath_profiler.lua

--- ==============================================================================
--- MODULE: hotpath_profiler Unit Tests
--- DESCRIPTION:
--- Validates the ported per-keystroke hot-path profiler: it logs a WARNING with
--- the offending label/detail ONLY when a segment exceeds the slow threshold,
--- stays silent (and cheap) for fast segments, honours a runtime threshold
--- override, and always returns the measured duration in milliseconds.
---
--- This encodes the tripwire contract: normal typing must produce zero log
--- noise while a genuine hitch surfaces with context for diagnosis.
--- ==============================================================================

local helpers = require("tests.helpers")

local captured = {}
local function reset_capture() captured = {} end
local _real_logger = package.loaded["infra.logger"]
local function noop() end
package.loaded["infra.logger"] = {
	info    = noop,
	warn    = function(tag, fmt, ...) captured[#captured + 1] = { tag = tag, fmt = fmt, args = { ... } } end,
	debug   = noop, trace = noop, done = noop, start = noop, success = noop, error = noop,
	is_enabled = function() return true end,
	LEVELS  = { DEBUG = 1, INFO = 2, WARNING = 3, ERROR = 4 },
}

package.loaded["adapters.timer_scheduler"] = nil
package.loaded["infra.hotpath_profiler"] = nil
local hot = require("infra.hotpath_profiler")

-- Controllable nanosecond clock, restored at file end.
local NS        = 0
local orig_abs  = hs.timer.absoluteTime
hs.timer.absoluteTime = function() return NS end

local NS_PER_MS = 1e6

helpers.describe("infra.hotpath_profiler.log_if_slow", function()
	helpers.it("logs a WARNING when the segment exceeds the threshold", function()
		reset_capture()
		NS = 1000 * NS_PER_MS
		local t0 = hot.now()
		NS = t0 + 25 * NS_PER_MS          -- 25 ms elapsed (> 5 ms default)
		local elapsed = hot.log_if_slow("keydown", t0, "char=a")
		helpers.assert_eq(#captured, 1, "one WARNING expected for a slow segment")
		helpers.assert_eq(captured[1].args[1], "keydown")
		helpers.assert_true(math.abs(captured[1].args[2] - 25) < 0.01, "logged elapsed ≈ 25 ms")
		helpers.assert_eq(captured[1].args[3], "char=a")
		helpers.assert_true(math.abs(elapsed - 25) < 0.01, "returned elapsed ≈ 25 ms")
	end)

	helpers.it("logs a WARNING from 6 ms, the threshold shared with Windows", function()
		reset_capture()
		NS = 1200 * NS_PER_MS
		local t0 = hot.now()
		NS = t0 + 6 * NS_PER_MS
		hot.log_if_slow("hotstring.match", t0, "char=six")
		helpers.assert_eq(#captured, 1, "6 ms is over 5 ms; the old 20 ms threshold stayed silent")
	end)

	helpers.it("stays silent for transient scheduler jitter below the default budget", function()
		reset_capture()
		NS = 1500 * NS_PER_MS
		local t0 = hot.now()
		NS = t0 + 3 * NS_PER_MS           -- 3 ms elapsed (< 5 ms default)
		hot.log_if_slow("keydown", t0, "char=jitter")
		helpers.assert_eq(#captured, 0, "3 ms scheduler jitter must not emit a WARNING")
	end)

	helpers.it("stays silent for a fast segment below the threshold", function()
		reset_capture()
		NS = 2000 * NS_PER_MS
		local t0 = hot.now()
		NS = t0 + 1 * NS_PER_MS            -- 1 ms elapsed (< 5 ms default)
		local elapsed = hot.log_if_slow("keydown", t0, "char=b")
		helpers.assert_eq(#captured, 0, "no WARNING for a fast segment")
		helpers.assert_true(math.abs(elapsed - 1) < 0.01, "still returns the measured duration")
	end)

	helpers.it("honours a runtime threshold override", function()
		reset_capture()
		hot.set_threshold_ms(0.5)          -- tighten the tripwire
		NS = 30000 * NS_PER_MS          -- past the log window of the first test
		local t0 = hot.now()
		NS = t0 + 1 * NS_PER_MS            -- 1 ms now trips the 0.5 ms threshold
		hot.log_if_slow("keydown", t0, "char=c")
		helpers.assert_eq(#captured, 1, "1 ms must trip a 0.5 ms threshold")
		hot.set_threshold_ms(5.0)          -- restore default for any later use
	end)

	helpers.it("logs a repeating slow segment once per window and reports what it withheld", function()
		reset_capture()
		local Segments = require("hotpath_segments")
		local function slow_at(at_ms, detail)
			NS = at_ms * NS_PER_MS
			local t0 = hot.now()
			NS = t0 + 25 * NS_PER_MS
			hot.log_if_slow("hotstring.match", t0, detail)
		end
		slow_at(100000, "first")
		slow_at(100100, "second")
		slow_at(100200, "third")
		helpers.assert_eq(#captured, 1, "only the first occurrence of a window is logged")
		slow_at(100000 + Segments.LOG_WINDOW_MS + 1000, "next window")
		helpers.assert_eq(#captured, 2, "the next window logs again")
		helpers.assert_eq(captured[2].args[4], 2, "the line says how many repeats it replaces")
	end)

	helpers.it("throttles each segment on its own", function()
		reset_capture()
		local function slow(label, at_ms)
			NS = at_ms * NS_PER_MS
			local t0 = hot.now()
			NS = t0 + 25 * NS_PER_MS
			hot.log_if_slow(label, t0, "")
		end
		slow("hotstring.match", 200000)
		slow("hotstring.expand", 200010)
		helpers.assert_eq(#captured, 2, "a second segment is not hidden by the first")
	end)
end)

hs.timer.absoluteTime = orig_abs
package.loaded["infra.logger"] = _real_logger
package.loaded["adapters.timer_scheduler"] = nil
