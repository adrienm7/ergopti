--- tests/unit/lib/test_crash_report_deferred_off_hot_path.lua

--- ==============================================================================
--- MODULE: Regression — crash report forwarding deferred off the hot callback (F-HIGH-20)
--- DESCRIPTION:
--- The F-HIGH-5 fix wired _G.ergopti_report_crash into every guarded hs.timer
--- callback (lib.logger._forward_crash) and every hs.task completion callback
--- (adapters.shell_runner.wrapped_on_done). Both call chains eventually reach
--- crash_reporter.prompt_user, which shows a SYNCHRONOUS, BLOCKING
--- hs.dialog.blockAlert. Calling the reporter inline — on the very stack frame
--- of the callback that just threw — froze the whole run loop until a human
--- dismissed a dialog, for ANY recoverable Lua error anywhere a guarded
--- hs.timer or hs.task callback is used (54 files use hs.timer alone).
---
--- Fix: both _forward_crash (lib/logger.lua) and wrapped_on_done
--- (adapters/shell_runner.lua) now schedule the reporter call via
--- hs.timer.doAfter(0, ...) instead of invoking it inline.
---
--- This is a BEHAVIORAL test using the real tests/stubs/hs.lua timer, whose
--- doAfter() returns a timer that must be explicitly :fire()'d — it does NOT
--- auto-run. This lets the test distinguish "deferred" from "synchronous":
--- if the reporter fired synchronously (the bug), it would already have been
--- called by the time the guarded callback / on_done returns. If it is
--- properly deferred (the fix), the reporter must NOT have been called until
--- an explicit second :fire() on the nested doAfter(0, ...) timer.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ================================================================
-- ====================================================================
-- ======= 1/ logger._forward_crash defers via hs.timer.doAfter =======
-- ====================================================================
-- ================================================================

helpers.describe("logger: crash report is deferred off the throwing timer callback (F-HIGH-20)", function()
	helpers.it("does NOT invoke the reporter synchronously — only after the nested doAfter(0) timer fires", function()
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub

		package.loaded["lib.logger"] = nil
		local Logger = require("lib.logger")
		Logger.install_runtime_error_capture()

		local reported = false
		_G.ergopti_report_crash = function() reported = true end

		-- Fire a throwing timer callback through the guard. The outer timer's
		-- :fire() call synchronously runs the guarded callback (xpcall + throw),
		-- which internally schedules the deferred reporter call via a NESTED
		-- hs.timer.doAfter(0, ...) — that nested timer is what must remain unfired.
		local outer = hs.timer.doAfter(0, function() error("boom-deferred") end)
		outer:fire()

		helpers.assert_true(not reported,
			"the crash reporter must NOT be invoked synchronously on the throwing callback's own stack frame (F-HIGH-20)")

		-- The nested doAfter(0, ...) timer must exist and, once fired, must be the
		-- thing that actually invokes the reporter — proving the report still
		-- eventually happens, just off the hot path.
		local timers = hs.timer.__timers
		local nested = timers[#timers]
		helpers.assert_true(nested ~= nil and nested.running == true,
			"a nested, still-armed hs.timer.doAfter(0, ...) must have been scheduled for the deferred report")

		nested:fire()
		helpers.assert_true(reported,
			"the crash reporter MUST still fire once the deferred timer is run — reporting must not be silently dropped")

		_G.ergopti_report_crash = nil
	end)
end)





-- =========================================================================
-- ===========================================================================
-- ======= 2/ shell_runner.wrapped_on_done defers via hs.timer.doAfter =======
-- ===========================================================================
-- =========================================================================

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
