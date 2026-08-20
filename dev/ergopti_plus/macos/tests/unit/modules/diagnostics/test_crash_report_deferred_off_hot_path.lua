--- tests/unit/modules/diagnostics/test_crash_report_deferred_off_hot_path.lua

--- ==============================================================================
--- MODULE: Regression — a recoverable timer error never reaches the crash reporter
--- DESCRIPTION:
--- lib.logger._guard_timer_cb used to forward EVERY uncaught error in an hs.timer
--- callback to _G.ergopti_report_crash. That chain runs crash_reporter.report ->
--- ui.healthcheck.run (seven blocking hs.execute probes) -> crash_reporter.
--- prompt_user -> a modal alert. A modal runs a nested run loop that stalls the
--- main thread — every event tap, timer and hotkey with it — until a human clicks
--- it. 54 files use hs.timer, so ANY recoverable Lua error anywhere could freeze
--- the driver.
---
--- The earlier "fix" wrapped the reporter call in hs.timer.doAfter(0, ...). That
--- moves the call off the THROWING CALLBACK'S STACK FRAME but keeps it on the
--- SAME MAIN THREAD one run loop tick later. The stack frame was never the cause;
--- the synchronous nested modal loop is. infra/dialog_util.lua:57-58 documents this
--- directly: modal dialogs block the main thread and its runloop.
---
--- Fix: a throw inside a timer callback is RECOVERABLE by definition — the
--- callback is abandoned and the run loop carries on — so it goes to the
--- errors-only sink and stops there. The crash reporter stays reserved for
--- genuine uncaught fatals (PROJECT_MEMORY: errors-only-log-sink).
---
--- ROOT CAUSE ENCODED: the previous version of section 1 asserted only "not
--- called synchronously", which doAfter(0) satisfies while the freeze remains
--- fully intact — a false green. This version DRAINS EVERY PENDING TIMER before
--- asserting, so no amount of deferral can hide a reachable reporter.
--- ==============================================================================

local helpers = require("tests.helpers")

-- How many drain passes to run. More than one so a reporter re-deferred by its
-- own scheduled callback still gets caught.
local TIMER_DRAIN_PASSES = 3

--- Fires every still-armed timer recorded by the hs stub, repeatedly.
--- @param hs_stub table The Hammerspoon stub whose timer registry to drain.
local function drain_all_timers(hs_stub)
	for _ = 1, TIMER_DRAIN_PASSES do
		local timers = hs_stub.timer.__timers
		for i = 1, #timers do
			local t = timers[i]
			if t.running then pcall(function() t:fire() end) end
		end
	end
end





-- ====================================================================
-- ====================================================================
-- ======= 1/ Recoverable Timer Errors Stay Out of the Reporter =======
-- ====================================================================
-- ====================================================================

helpers.describe("logger: a recoverable timer-callback error never reaches the crash reporter", function()
	helpers.it("logs one ERROR/runtime line and leaves the reporter unreached even after every timer is drained", function()
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub

		package.loaded["infra.logger"] = nil
		local Logger = require("infra.logger")
		Logger.install_runtime_error_capture()

		local reported = false
		_G.ergopti_report_crash = function() reported = true end

		local captured = {}
		Logger.set_sink(function(line, variant)
			captured[#captured + 1] = { line = line, variant = variant }
		end)

		-- Fire a throwing timer callback through the guard. :fire() runs the guarded
		-- callback synchronously (xpcall + throw).
		local outer = hs.timer.doAfter(0, function() error("boom-recoverable") end)
		outer:fire()

		-- THE load-bearing step: drain every pending timer. A reporter call merely
		-- postponed by hs.timer.doAfter(0, ...) would run here and be caught — the
		-- old test stopped before this point and passed while the freeze remained.
		drain_all_timers(hs_stub)

		Logger.set_sink(nil)
		_G.ergopti_report_crash = nil

		helpers.assert_true(not reported,
			"a recoverable error in an hs.timer callback must NEVER reach the crash reporter — not "
			.. "synchronously and not one run loop tick later; the reporter ends in a modal that "
			.. "stalls the main thread and its runloop until a human dismisses it")

		local error_lines = 0
		for _, entry in ipairs(captured) do
			if entry.variant == "error"
				and entry.line:find("[ERROR] [runtime]", 1, true)
				and entry.line:find("boom-recoverable", 1, true) then
				error_lines = error_lines + 1
			end
		end
		helpers.assert_eq(error_lines, 1,
			"the abandoned callback must leave exactly one ERROR/runtime line in the errors-only sink "
			.. "— that sink, not crash_reports/, is where recoverable failures belong")
	end)
end)





-- ===========================================================================
-- ===========================================================================
-- ======= 2/ shell_runner.wrapped_on_done defers via hs.timer.doAfter =======
-- ===========================================================================
-- ===========================================================================

helpers.describe("shell_runner: crash report is deferred off the hs.task completion callback (F-HIGH-20)", function()
	helpers.it("does NOT invoke the reporter synchronously when on_done throws", function()
		local captured_completion_cb = nil
		local hs_overrides = {
			task = {
				new = function(_, cb, _args)
					captured_completion_cb = cb
					return {
						start     = function() if captured_completion_cb then captured_completion_cb(0, "", "") end end,
						isRunning = function() return false end,
						terminate = function() end,
					}
				end,
			},
		}

		package.loaded["adapters.shell_runner"] = nil
		local sr = helpers.load_with_stubs("adapters.shell_runner", hs_overrides)

		local reported = false
		_G.ergopti_report_crash = function() reported = true end

		local handle = sr.spawn("/usr/bin/true", {}, function()
			error("boom-from-on-done")
		end)
		handle.start()

		helpers.assert_true(not reported,
			"the crash reporter must NOT be invoked synchronously from wrapped_on_done's own stack frame (F-HIGH-20)")

		-- The deferred report must still be scheduled on a not-yet-fired hs.timer.
		local timers = hs.timer.__timers
		local nested = timers[#timers]
		helpers.assert_true(nested ~= nil and nested.running == true,
			"wrapped_on_done must schedule the deferred crash report via hs.timer.doAfter(0, ...)")

		nested:fire()
		helpers.assert_true(reported,
			"the crash reporter MUST still fire once the deferred timer runs — reporting must not be silently dropped")

		_G.ergopti_report_crash = nil
	end)
end)
