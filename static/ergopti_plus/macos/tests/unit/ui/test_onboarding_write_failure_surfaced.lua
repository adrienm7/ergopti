--- tests/unit/ui/test_onboarding_write_failure_surfaced.lua

--- ==============================================================================
--- MODULE: Regression — a failed onboarding write must not report success
--- DESCRIPTION:
--- The first-run wizard silently discarded the user's answers when the write
--- failed.
---
--- ROOT CAUSE ENCODED:
--- commit() wrapped the write in a pcall whose closure had no `return`, and
--- toml_codec's batch_write never raises on I/O failure: it RETURNS false plus a
--- reason. The wizard therefore logged success and called hs.reload() with
--- nothing on disk. The finish handler is now driven end to end: every way the
--- writer can refuse (false, nil, a raise) and an unreadable destination must
--- surface an error and schedule no reload.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_finish = require("tests.support.onboarding_finish_fixture").with_finish

-- A valid finish payload whose rows reach the writer.
local ANSWERS = {
	locale = "en",
	config_dir = "",
	operations = { { path = "llm.enabled", value = true }, { path = "hotstrings.trigger_char", value = "ù" } },
}

--- Asserts the refusal every failed commit must produce.
--- @param state table Fixture state.
--- @param detail string|nil Text the error dialog must quote.
local function assert_refused(state, detail)
	helpers.assert_eq(state.notifications, 0, "no success notification")
	helpers.assert_eq(state.deferred, 0, "no reload over unwritten answers")
	helpers.assert_eq(#state.alerts, 1)
	helpers.assert_true(state.alerts[1].body:find("onboarding.error.write_failed", 1, true) ~= nil)
	if detail then
		helpers.assert_true(state.alerts[1].body:find(detail, 1, true) ~= nil,
			"the writer's own reason reaches the dialog: " .. state.alerts[1].body)
	end
end





-- ===============================================
-- ===============================================
-- ======= 1/ Every Failure Mode Surfaces ========
-- ===============================================
-- ===============================================

helpers.describe("onboarding surfaces a write that failed without raising", function()
	helpers.it("reports failure when batch_write RETURNS false", function()
		with_finish({ answers = ANSWERS, write = "false" }, function(state)
			helpers.assert_eq(#state.writes, 1)
			assert_refused(state, "rename failed")
		end)
	end)

	helpers.it("reports failure when batch_write returns nil", function()
		with_finish({ answers = ANSWERS, write = "nil" }, function(state)
			assert_refused(state)
		end)
	end)

	helpers.it("still reports failure when batch_write raises", function()
		with_finish({ answers = ANSWERS, write = "throw" }, function(state)
			assert_refused(state, "disk on fire")
		end)
	end)

	helpers.it("reports success only when the write is confirmed, with the answers as rows", function()
		with_finish({ answers = ANSWERS, write = "true" }, function(state)
			helpers.assert_eq(#state.writes, 1)
			helpers.assert_eq(state.writes[1].path, "/virtual/onboarding-config.toml")
			helpers.assert_eq(state.writes[1].rows, {
				{ section = "llm", key = "enabled", value = true },
				{ section = "hotstrings", key = "trigger_char", value = "ù" },
			})
			helpers.assert_eq(state.notifications, 1)
			helpers.assert_eq(state.deferred, 1)
			helpers.assert_eq(#state.alerts, 0)
		end)
	end)

	helpers.it("refuses a dangling destination before invoking batch_write", function()
		with_finish({
			answers = ANSWERS,
			read = function() return nil, "error", "dangling final symlink" end,
		}, function(state)
			helpers.assert_eq(#state.writes, 0,
				"onboarding must not let a lower writer replace a dangling symlink")
			assert_refused(state, "dangling final symlink")
		end)
	end)
end)
