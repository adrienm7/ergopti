--- tests/unit/lib/test_crash_reporter_wired.lua

--- ==============================================================================
--- MODULE: Regression — uncaught runtime errors reach the crash reporter (F-HIGH-5)
--- DESCRIPTION:
--- _G.ergopti_report_crash was defined but never wired to any error hook, so the
--- whole crash_reporter module was unreachable dead code — a real crash (an
--- uncaught error in an hs.timer/eventtap callback, swallowed by Hammerspoon to
--- the Console) left no report on disk. The logger's runtime-error capture is the
--- one live error path, so the fix forwards from there to the global reporter
--- (debounced + re-entrancy-guarded).
---
--- This is a BEHAVIORAL test: it installs the runtime capture, drives a throwing
--- hs.timer callback through the guard, and asserts the reporter is invoked with
--- the original error — not merely that a line exists.
---
--- F-HIGH-20 follow-up: the reporter call is now deferred via a nested
--- hs.timer.doAfter(0, ...) (see lib/logger.lua _forward_crash) so it never runs
--- on the throwing callback's own stack frame — crash_reporter.prompt_user ends
--- in a synchronous, blocking hs.dialog.blockAlert. The test below fires that
--- nested timer explicitly to observe the (still-happening, just deferred) report.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("logger: uncaught timer-callback errors reach the crash reporter (F-HIGH-5)", function()
	helpers.it("forwards an uncaught hs.timer callback error to _G.ergopti_report_crash", function()
		package.loaded["lib.logger"] = nil
		local Logger = helpers.load_with_stubs("lib.logger")
		Logger.install_runtime_error_capture()  -- patches _G.hs.timer.doAfter to guard callbacks

		local reported = nil
		_G.ergopti_report_crash = function(err, ctx) reported = { err = err, ctx = ctx } end

		-- A timer callback that throws: the guard must log AND forward to the reporter.
		-- The hs stub's doAfter does not auto-run; fire the returned (guarded) timer.
		local t = _G.hs.timer.doAfter(0, function() error("boom-xyz") end)
		helpers.assert_true(type(t) == "table" and type(t.fire) == "function", "doAfter must return a fireable timer")
		t:fire()

		-- The report itself is deferred (F-HIGH-20) — must not have fired yet.
		helpers.assert_true(reported == nil,
			"the crash reporter must NOT be invoked synchronously on the throwing callback's own stack frame (F-HIGH-20)")

		-- Fire the nested doAfter(0, ...) timer the guard scheduled for the deferred report.
		local timers = _G.hs.timer.__timers
		local nested = timers[#timers]
		helpers.assert_true(nested ~= nil and nested.running == true,
			"a nested hs.timer.doAfter(0, ...) must have been scheduled for the deferred report")
		nested:fire()
		_G.ergopti_report_crash = nil  -- do not leak the global into later tests

		helpers.assert_true(reported ~= nil, "the crash reporter must be invoked for an uncaught timer-callback error")
		helpers.assert_true(tostring(reported.err):find("boom%-xyz") ~= nil,
			"the reported error must carry the original message")
		helpers.assert_true(type(reported.ctx) == "table" and reported.ctx.driver == "hammerspoon",
			"the reporter must receive a context table tagging the driver")
	end)

	helpers.it("does not invoke the reporter for a clean timer callback", function()
		package.loaded["lib.logger"] = nil
		local Logger = helpers.load_with_stubs("lib.logger")
		Logger.install_runtime_error_capture()

		local reported = false
		_G.ergopti_report_crash = function() reported = true end
		local t = _G.hs.timer.doAfter(0, function() end)  -- no error
		t:fire()
		_G.ergopti_report_crash = nil

		helpers.assert_true(not reported, "a clean timer callback must not trigger a crash report")
	end)
end)
