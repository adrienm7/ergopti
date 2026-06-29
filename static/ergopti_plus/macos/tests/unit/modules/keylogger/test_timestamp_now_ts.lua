--- tests/unit/modules/keylogger/test_timestamp_now_ts.lua

--- ==============================================================================
--- MODULE: Regression — keylogger timestamp uses ONE wall clock for s and .mmm
--- DESCRIPTION:
--- Audit finding F-L1. The four _now_ts copies took the seconds from os.date (wall
--- time) but the .mmm fraction from (hs.timer.absoluteTime()/1e6) % 1000 — a
--- boot-relative counter unrelated to the wall-clock second. The fraction was
--- meaningless and non-monotonic within a second. Fix: a single shared helper that
--- derives BOTH fields from the same wall-clock reading (TimerScheduler.now()).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("keylogger timestamp.now_ts derives s and .mmm from one clock", function()
	local function load_with_clock(epoch)
		package.loaded["adapters.timer_scheduler"] = { now = function() return epoch end }
		package.loaded["modules.keylogger.timestamp"] = nil
		return require("modules.keylogger.timestamp")
	end

	helpers.it("the .mmm fraction matches the stubbed wall-clock fraction", function()
		local ts = load_with_clock(1700000000.250).now_ts()
		helpers.assert_true(ts:sub(-4) == ".250", "fraction must be the wall-clock .250, got: " .. ts)
		-- The seconds field must be os.date of the SAME epoch (same clock).
		helpers.assert_eq(ts:sub(1, 19), os.date("%Y-%m-%d %H:%M:%S", 1700000000))
	end)

	helpers.it("is lexicographically non-decreasing for an increasing wall clock", function()
		-- Within the SAME wall-clock second, a later reading must sort later. The bug
		-- made the fraction decrease arbitrarily within a second (boot-clock mod 1000),
		-- so two in-order reads could produce a decreasing timestamp string.
		local a = load_with_clock(1700000000.250).now_ts()
		local b = load_with_clock(1700000000.750).now_ts()
		helpers.assert_eq(a:sub(1, 19), b:sub(1, 19))  -- same second
		helpers.assert_true(a < b, "the later same-second reading must sort later: " .. a .. " vs " .. b)
		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["modules.keylogger.timestamp"] = nil
	end)
end)
