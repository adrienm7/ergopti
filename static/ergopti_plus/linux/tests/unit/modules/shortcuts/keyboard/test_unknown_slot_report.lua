--- tests/unit/modules/shortcuts/keyboard/test_unknown_slot_report.lua

--- ==============================================================================
--- MODULE: An Unknown Keyboard Slot Is Reported And Offered For Cleanup
--- DESCRIPTION:
--- A key under [shortcuts.keyboard] that no slot owns (an id an older build
--- used, a typo) is outdated configuration: named once and offered by the
--- config cleanup, never skipped without a word.
---
--- ROOT CAUSE ENCODED:
--- The owner walked the stored assignments and consumed only the slots it owns;
--- any other key was ignored with no log line, and because the section is a
--- declared dynamic namespace the unused-key scan never listed it either, so a
--- binding lost to a renamed id was invisible.
--- ==============================================================================

local helpers = require("tests.helpers")
local ConfigOutdated = require("config_outdated")

helpers.describe("Linux keyboard slots: unknown ids (unknown-slot-report)", function()
	helpers.it("(unknown-slot-report) names an unowned id and keeps an owned id quiet", function()
		ConfigOutdated.reset_for_tests()
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
		local shortcuts = require("modules.shortcuts.keyboard_shortcuts")
		local document = { shortcuts = { keyboard = { no_such_slot = "select_line", ctrl_g = "select_line" } } }
		local reported = ConfigOutdated.collect_reports(function()
			shortcuts.configuration_paths(document)
		end)
		helpers.assert_true(reported["shortcuts.keyboard.no_such_slot"] == true,
			"the unknown id must be offered by the cleanup")
		helpers.assert_nil(reported["shortcuts.keyboard.ctrl_g"], "an owned slot is not outdated")
		package.loaded["modules.shortcuts.keyboard_shortcuts"] = nil
	end)
end)
