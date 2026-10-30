--- tests/unit/ui/menu/keyboard_layout/test_menu_keyboard_layout_stage_phases.lua

--- ==============================================================================
--- MODULE: Regression — the keyboard-layout row names its slow stage
--- DESCRIPTION:
--- The keyboard-layout row costs 42 ms in most menu rebuilds on a field Mac
--- but 100 to 420 ms in others (2026-10-30 report), and the main-thread hold
--- line could only say `menu_item.keyboard_layout`. Each build stage is now a
--- named phase, so the hold report's phase list says which one is slow.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.keyboard_layout.menu_keyboard_layout_reaches_tray_fixture"] = nil
local Fixture = require("tests.support.ui.menu.keyboard_layout.menu_keyboard_layout_reaches_tray_fixture")

helpers.describe("Keyboard layout row build stages", function()
	helpers.it("records each stage as a phase, in build order", function()
		local PhaseStats = require("infra.phase_stats")
		local original, stopped = PhaseStats.stop, {}
		PhaseStats.stop = function(name, started, ...)
			if type(name) == "string" and name:find("^menu_keyboard_layout%.") then stopped[#stopped + 1] = name end
			return original(name, started, ...)
		end
		local ok, row = pcall(Fixture.tray_row, Fixture.make_ctx())
		PhaseStats.stop = original
		assert(ok, row)
		helpers.assert_true(type(row) == "table" and type(row.menu) == "table" and #row.menu > 0,
			"the timed build must still reach the tray populated")
		helpers.assert_eq(stopped, {
			"menu_keyboard_layout.sources", "menu_keyboard_layout.bundles",
			"menu_keyboard_layout.variants", "menu_keyboard_layout.rows",
		})
	end)
end)
