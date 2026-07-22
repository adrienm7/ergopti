--- tests/unit/modules/shortcuts/test_resume_rearms_warmup.lua

--- ==============================================================================
--- MODULE: Regression — resume re-arms the LLM warmup it killed on pause
--- DESCRIPTION:
--- Audit finding F-M6. pause_all() correctly calls warmup_controller.stop() (which
--- bumps the warmup generation so the in-flight try_warmup self-discards) so the
--- backend is not POSTed during pause. But resume_all() was asymmetric: it never
--- re-armed warmup. If pause landed during the LLM cold-start window, the warmup
--- chain was killed mid-flight, the backend finished loading with no probe in
--- flight, and api.is_ready() stayed false — predictions were then silently dead
--- for the rest of the session (the readiness flag is only ever set true by a
--- successful warmup, and perform_check never triggers warmup itself).
---
--- Fix: resume_all() re-arms via schedule_warmup_with_retry (self-guarding: no-ops
--- when the LLM is off / model unresolved / backend already ready).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("script_control pause/resume warmup symmetry", function()
	helpers.it("pause stops the warmup chain AND resume re-arms it", function()
		local calls = { stop = 0, rearm = 0 }
		package.loaded["modules.llm.warmup_controller"] = {
			stop = function() calls.stop = calls.stop + 1 end,
			schedule_warmup_with_retry = function(_reason) calls.rearm = calls.rearm + 1 end,
		}

		local SC = helpers.load_with_stubs("modules.shortcuts.script_control")

		SC.pause_all()
		helpers.assert_true(calls.stop >= 1, "pause_all must stop the warmup chain")

		SC.resume_all()
		-- The regression: this was 0 because resume_all never re-armed warmup, so a
		-- cold backend killed at pause stayed un-probed for the rest of the session.
		helpers.assert_true(calls.rearm >= 1, "resume_all must re-arm the warmup chain")

		package.loaded["modules.llm.warmup_controller"] = nil
		package.loaded["modules.shortcuts.script_control"] = nil
	end)
end)
