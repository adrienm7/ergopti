--- tests/unit/menu/ui/shortcuts/test_bad_shortcut_mods.lua

--- ==============================================================================
--- MODULE: Regression — no menu reads a stored shortcut's modifiers (M-13)
--- DESCRIPTION:
--- Shortcuts persisted before the coerce_mods fix stored .mods as a plain
--- string, which crashed the hotstrings and metrics submenu builders. The
--- metrics rows left on 2026-10-01 and the personal hotstrings' legacy editor
--- shortcut (« Ctrl+★ opens the editor ») left on 2026-11-21, when Ctrl+★ became
--- the ordinary secondary_star slot. So no menu builder reads a stored .mods,
--- and none can crash on one.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("M-13: no menu reads a stored shortcut's modifiers (source)", function()
	helpers.it("the personal hotstrings menu keeps no editor shortcut", function()
		local src = helpers.read_driver_source("local function split_personal_ext_stem") -- hotstrings/ui/menu/custom.lua
		helpers.assert_true(src:find("custom_editor_shortcut", 1, true) == nil,
			"the legacy editor shortcut left: Ctrl+★ is the ordinary secondary_star slot")
		helpers.assert_true(src:find("%.mods") == nil, "the personal hotstrings menu reads no stored .mods")
	end)

	helpers.it("menu_metrics.lua reads no stored shortcut modifiers", function()
		local src = helpers.read_driver_source("\"dialog.metrics.security_warning_title\"") -- ui/menu/menu_metrics.lua
		helpers.assert_true(src:find("%.mods") == nil,
			"menu_metrics.lua draws no shortcut row, so it must not read a stored .mods")
	end)
end)
