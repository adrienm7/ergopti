--- infra/field_check_apple_shortcuts.lua

--- ==============================================================================
--- MODULE: Field Check, Apple Shortcuts Action
--- DESCRIPTION:
--- The field run's check of the run_apple_shortcut action, with no person:
--- the Shortcuts library is listed through the action's own owner and
--- command-line transport, then the shortcut named TEST_SHORTCUT is run end to
--- end when the library holds one. A library without it skips the run by
--- name: the maintainer creates it once (a shortcut that does nothing).
---
--- FEATURES & RATIONALE:
--- 1. The real path: modules/gestures/apple_shortcut_action, so a pass proves
---    the listing, the identifier revalidation and the bounded invocation the
---    user's bindings rely on.
--- 2. Nothing the user typed is reported: the steps carry counts and closed
---    categories, never a shortcut name.
--- ==============================================================================

local Report = require("field_check_report")

local M = {}

local PASS, FAIL, INFO, SKIP = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO, Report.STATE_SKIP

--- The shortcut the field run invokes when the library holds it.
M.TEST_SHORTCUT = "Ergopti Field Test"

-- The action parent the field run's invocation is owned by.
M.PARENT = "gestures"

--- Lists the library, then runs the test shortcut when it is there.
--- ports.apple_shortcut_action() -> modules/gestures/apple_shortcut_action.
function M.apple_shortcuts(ports, report, finish)
	local Action = ports.apple_shortcut_action()
	local accepted, refused = Action.list(function(rows, reason)
		if not rows then
			report.step("shortcuts_listed", FAIL, reason or "refused")
			report.step("field_test_shortcut", SKIP, "no_listing")
			return finish()
		end
		report.step("shortcuts_listed", PASS, #rows)
		local test
		for _, row in ipairs(rows) do
			if row.name == M.TEST_SHORTCUT then test = row end
		end
		if not test then
			report.step("field_test_shortcut", SKIP, "absent")
			return finish()
		end
		report.step("field_test_shortcut", INFO, "present")
		local started = Action.run({ id = test.id, name = test.name, input = "none", output = "none" }, M.PARENT, 0,
			function(success, category)
				report.step("field_test_run", success and PASS or FAIL, category)
				finish()
			end)
		if not started then
			report.step("field_test_run", FAIL, "not_started")
			finish()
		end
	end)
	if not accepted then
		report.step("shortcuts_listed", FAIL, refused or "refused")
		report.step("field_test_shortcut", SKIP, "no_listing")
		finish()
	end
end

return M
