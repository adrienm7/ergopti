--- tests/unit/platform/remap/test_paused_script_control_option_only.lua

--- ==============================================================================
--- MODULE: Regression — paused script-control rules gate on the real option key
--- DESCRIPTION:
--- Audit finding F-H6 (resolved per the maintainer's intent). While paused the
--- remap layer is OFF, so the user reaches the script-control shortcuts with the
--- REAL option key — option+Enter (un-pause), option+Backspace (reload),
--- option+Escape (quit). The paused rules must therefore gate on the real option
--- key ONLY and must NOT include a right_command variant: the real rcmd is not used
--- while paused, and a right_command+Backspace/Escape rule would shadow native macOS
--- chords (e.g. Cmd+Delete = delete-to-line-start).
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")
local Generator = helpers.load_with_stubs("platform.remap.generator")
local TEST_LEASE_TOKEN = "0123456789abcdef0123456789abcdef"

helpers.describe("paused script-control rules use the real option key, not rcmd", function()
	helpers.it("every paused rule gates on option and never on right_command", function()
		local rules = Generator.build_paused_script_control_rules(TEST_LEASE_TOKEN)
		helpers.assert_true(#rules > 0, "expected paused script-control rules")
		for _, rule in ipairs(rules) do
			local mand = rule.manipulators[1].from.modifiers.mandatory
			local set = {}
			for _, m in ipairs(mand) do set[m] = true end
			helpers.assert_true(set.option == true, "paused rule must require the real option key")
			helpers.assert_true(set.right_command == nil,
				"paused rule must NOT gate on right_command (rcmd is untouched while paused; would shadow native chords)")
		end
	end)
end)
