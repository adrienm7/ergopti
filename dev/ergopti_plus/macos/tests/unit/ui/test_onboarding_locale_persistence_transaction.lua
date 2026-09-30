--- tests/unit/ui/test_onboarding_locale_persistence_transaction.lua

--- ==============================================================================
--- MODULE: Onboarding Locale Persistence Transaction Tests
--- DESCRIPTION:
--- Drives the real onboarding finish-message handler with controlled persistence
--- boundaries. A locale write refusal must stop config publication, notification
--- and reload scheduling instead of vanishing inside a bare pcall.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_finish = require("tests.support.onboarding_finish_fixture").with_finish

-- A valid finish payload: the language and one declined category switch.
local ANSWERS = {
	locale = "de",
	config_dir = "",
	operations = { { path = "gestures.enabled", value = false } },
}





-- ========================================
-- ========================================
-- ======= 1/ Exact Commit Boundary =======
-- ========================================
-- ========================================

helpers.describe("onboarding locale persistence is a required commit boundary", function()
	helpers.it("stops every success-only side effect on false, nil, and throw", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_finish({ answers = ANSWERS, locale = mode }, function(state)
				helpers.assert_eq(state.locale_switches, 1)
				helpers.assert_eq(state.locale_persists, 1)
				helpers.assert_eq(#state.writes, 0,
					mode .. " persistence must stop config publication")
				helpers.assert_eq(state.notifications, 0)
				helpers.assert_eq(state.deferred, 0,
					mode .. " persistence must not schedule the final reload")
				helpers.assert_eq(#state.alerts, 1)
				helpers.assert_eq(state.alerts[1].body,
					"onboarding.error.locale_persist_failed")
			end)
		end
	end)

	helpers.it("continues exactly once after an explicit persistence acknowledgement", function()
		with_finish({ answers = ANSWERS, locale = "true" }, function(state)
			helpers.assert_eq(state.locale_persists, 1)
			helpers.assert_eq(#state.writes, 1)
			helpers.assert_eq(state.notifications, 1)
			helpers.assert_eq(state.deferred, 1)
			helpers.assert_eq(#state.alerts, 0)
		end)
	end)

	helpers.it("refuses invalid answers before persisting the language", function()
		local invalid = {
			{ locale = "xx", config_dir = "", operations = {} },
			{ locale = "de", config_dir = "", operations = { { path = "script.log_level", value = "DEBUG" } } },
			{ locale = "de", config_dir = "", operations = { { path = "gestures.enabled", value = "false" } } },
			{ locale = "de", operations = {} },
			{ locale = "de", config_dir = "" },
		}
		for _, answers in ipairs(invalid) do
			with_finish({ answers = answers }, function(state)
				helpers.assert_eq(state.locale_persists, 0, "a refused payload changes no language")
				helpers.assert_eq(#state.writes, 0)
				helpers.assert_eq(state.deferred, 0)
				helpers.assert_eq(#state.alerts, 1)
				helpers.assert_eq(state.alerts[1].body, "onboarding.error.invalid_answers")
			end)
		end
	end)
end)
