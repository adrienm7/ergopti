--- tests/unit/lib/test_crash_reporter_wired.lua

--- ==============================================================================
--- MODULE: Regression — the crash reporter is reachable, but ONLY for real crashes
--- DESCRIPTION:
--- Two invariants live here, and they pull in opposite directions.
---
--- F-HIGH-5 (still enforced): `_G.ergopti_report_crash` must never become
--- unreachable dead code. It was once defined but wired to nothing, so a genuine
--- crash left no report on disk. Its live entry point is now
--- `adapters/shell_runner.lua` `report_callback_throw`, which forwards a throw
--- from an hs.task completion/streaming callback — see section 3.
---
--- 2026-07-20 audit (H-06, superseding the old F-HIGH-5 wiring): the logger's
--- timer guard used to forward EVERY uncaught timer-callback error to the same
--- reporter. That was wrong on two counts. A throw inside an hs.timer callback is
--- RECOVERABLE — the callback is abandoned and the run loop continues — so per
--- the errors-only-log-sink contract it belongs in the errors sink, not in
--- crash_reports/. And the reporter's tail ran a synchronous modal dialog, whose
--- nested run loop starves the CGEventTap: a single recoverable error froze all
--- remapping until a human clicked. Deferring it by `hs.timer.doAfter(0, …)` did
--- not help, because that stays on the same main thread one tick later — the
--- freeze was the modal, never the stack frame.
---
--- So: a timer-callback throw must reach the errors sink and NOT the reporter
--- (section 1); a clean callback must reach neither (section 2); and the reporter
--- must still be reachable from the task-failure path (section 3), or F-HIGH-5
--- silently regresses.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("logger: a recoverable timer-callback error must NOT reach the crash reporter (audit H-06)", function()
	helpers.it("logs an uncaught hs.timer callback error to the errors sink instead of reporting a crash", function()
		package.loaded["lib.logger"] = nil
		local Logger = helpers.load_with_stubs("lib.logger")
		Logger.install_runtime_error_capture()  -- patches _G.hs.timer.doAfter to guard callbacks

		local reported = nil
		_G.ergopti_report_crash = function(err, ctx) reported = { err = err, ctx = ctx } end

		-- Capture every formatted line so the ERROR can be asserted on directly
		-- rather than inferred from the absence of a crash report.
		local lines = {}
		Logger.set_sink(function(line) lines[#lines + 1] = line end)

		local t = _G.hs.timer.doAfter(0, function() error("boom-xyz") end)
		helpers.assert_true(type(t) == "table" and type(t.fire) == "function", "doAfter must return a fireable timer")
		t:fire()

		-- Drain every timer the guard could have scheduled. The pre-fix code
		-- deferred the reporter through a nested doAfter(0, …), so draining is
		-- what makes this assertion meaningful: without it the test would pass
		-- against the unfixed code simply because the nested timer had not run.
		local timers = _G.hs.timer.__timers or {}
		for _ = 1, 3 do
			for _, timer in ipairs(timers) do
				if timer and timer.running and type(timer.fire) == "function" then pcall(function() timer:fire() end) end
			end
		end

		Logger.set_sink(nil)
		_G.ergopti_report_crash = nil  -- do not leak the global into later tests

		helpers.assert_true(reported == nil,
			"a RECOVERABLE timer-callback throw must never reach the crash reporter — its tail opens a modal that freezes the run loop (audit H-06)")

		local error_lines = 0
		for _, line in ipairs(lines) do
			if line:find("[ERROR]", 1, true) and line:find("runtime", 1, true) and line:find("boom-xyz", 1, true) then
				error_lines = error_lines + 1
			end
		end
		helpers.assert_eq(error_lines, 1,
			"the throw must still be visible: exactly one [ERROR] [runtime] line carrying the original message")
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

helpers.describe("shell_runner: the crash reporter stays reachable for genuine task failures (F-HIGH-5)", function()
	helpers.it("forwards an hs.task callback throw to _G.ergopti_report_crash", function()
		-- This is the invariant the old logger wiring used to carry. If this ever
		-- fails, crash_reporter has become unreachable dead code again and a real
		-- crash leaves nothing on disk — exactly the F-HIGH-5 regression.
		package.loaded["adapters.shell_runner"] = nil
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner")

		local reported = nil
		_G.ergopti_report_crash = function(ctx) reported = ctx end

		-- Capture the completion callback hs.task was built with, then invoke it
		-- with a consumer callback that throws.
		local captured_on_done = nil
		_G.hs.task = _G.hs.task or {}
		local orig_new = _G.hs.task.new
		_G.hs.task.new = function(_exe, on_done, ...)
			captured_on_done = on_done
			return { start = function() return true end, terminate = function() end }
		end

		local handle = ShellRunner.spawn("/bin/echo", { "hi" }, function() error("task-boom") end)
		handle.start()
		helpers.assert_true(type(captured_on_done) == "function", "spawn must build an hs.task with a completion callback")
		captured_on_done(0, "", "")

		local timers = _G.hs.timer.__timers or {}
		for _ = 1, 3 do
			for _, timer in ipairs(timers) do
				if timer and timer.running and type(timer.fire) == "function" then pcall(function() timer:fire() end) end
			end
		end

		_G.hs.task.new = orig_new
		_G.ergopti_report_crash = nil

		helpers.assert_true(reported ~= nil,
			"a throw inside an hs.task callback must still reach the crash reporter — it is the one live path left (F-HIGH-5)")
		helpers.assert_true(tostring(reported):find("task%-boom") ~= nil,
			"the forwarded context must carry the original error message")
	end)
end)
