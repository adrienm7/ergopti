--- tests/unit/modules/diagnostics/test_crash_report_no_sync_probes.lua

--- ==============================================================================
--- MODULE: Regression — a crash report must not fork subprocesses by default
--- DESCRIPTION:
--- report() called ui.healthcheck.run() unconditionally. That probe forks seven
--- synchronous subprocesses (sysctl, vm_stat, uname, git) through hs.execute, and
--- report() is reached from an async callback on the SAME main run loop that
--- dispatches the CGEventTaps — so writing a crash report stalled the typing tap
--- for as long as the probes took.
---
--- The anti-freeze work that preceded this fix stopped at prompt_user: the modal
--- was moved off the hot path, and the surviving reporter path kept the probes.
--- This is the repo's usual shape — the guarantee was applied to the site that was
--- reported and not to the one beside it.
---
--- The in-memory ring buffer, which is the field anyone actually reads when
--- diagnosing, is still collected unconditionally. The OS trivia is available on
--- demand from Debug > Diagnostic and is now opt-in per call.
---
--- The test drives the real M.report with a healthcheck double that records
--- whether it was invoked, which is the observable that matters: whether a report
--- forks subprocesses on the run loop.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==============================================
-- ==============================================
-- ======= 1/ Healthcheck Probe Recorder ========
-- ==============================================
-- ==============================================

--- Loads the crash reporter with a healthcheck double counting run() calls.
--- @return table reporter, table probe
local function load_reporter()
	local probe = { runs = 0 }
	package.loaded["ui.healthcheck"] = {
		run = function()
			probe.runs = probe.runs + 1
			return { sys = {}, uptime_sec = 0, ports_validated = {}, failed_adapters = {} }
		end,
	}
	package.loaded["modules.diagnostics.crash_reporter"] = nil
	local CR = helpers.load_with_stubs("modules.diagnostics.crash_reporter")
	return CR, probe
end




-- ==============================================
-- ==============================================
-- ======= 2/ Probes Are Opt-In =================
-- ==============================================
-- ==============================================

helpers.describe("crash reports do not fork system probes on the run loop", function()
	helpers.it("does not run the healthcheck probe by default", function()
		local CR, probe = load_reporter()

		pcall(CR.report, "boom", { source = "test" })

		helpers.assert_eq(probe.runs, 0,
			"report() must not invoke ui.healthcheck.run() by default — it forks seven "
			.. "synchronous subprocesses on the same run loop that dispatches the typing "
			.. "event tap, so writing a crash report stalls typing")
	end)

	helpers.it("runs the probe when the caller explicitly asks for it", function()
		-- The data is still reachable: a caller that wants the OS trivia can opt in,
		-- which is what Debug > Diagnostic does.
		local CR, probe = load_reporter()

		pcall(CR.report, "boom", { source = "test", system_probes = true })

		helpers.assert_true(probe.runs >= 1,
			"an explicit context.system_probes = true must still collect the probe data, "
			.. "otherwise the diagnostic path loses information rather than deferring it")
	end)
end)
