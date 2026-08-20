--- tests/meta/test_i18n_stub_isolation.lua

--- ==============================================================================
--- MODULE: Regression — menu i18n stub contamination is isolated (F-T1)
--- DESCRIPTION:
--- The full run.lua suite was order/GC-dependently RED at menu_karabiner.lua:317
--- (`attempt to call a nil value (field 'section')`): ~10 test files install a
--- section-LESS `package.loaded["infra.i18n"] = { get = ... }` at module scope, and a
--- menu builder cached under one of them leaked into a later menu test. A flaky red
--- suite masks real regressions. Fix: load_with_stubs drops every cached ui.menu.*
--- module so menu builders always re-bind THIS test's canonical (section-capable)
--- lib.i18n stub.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("load_with_stubs isolates menu modules from a leaked i18n stub", function()
	helpers.it("clears cached ui.menu.* and restores a section-capable lib.i18n stub", function()
		-- Simulate a polluting predecessor: a section-LESS i18n stub + menu modules
		-- cached under it (the exact contamination that flaked the suite).
		package.loaded["infra.i18n"] = { get = function(k) return k end }   -- NO section/decorate_section
		package.loaded["ui.menu.menu_remap"] = "STALE_CONTAMINATED"
		package.loaded["ui.menu.menu_utils"]     = "STALE_CONTAMINATED"

		-- Any load_with_stubs call must drop the cached menu modules and reinstall the
		-- canonical i18n stub.
		helpers.load_with_stubs("infra.logger")

		helpers.assert_nil(package.loaded["ui.menu.menu_remap"])
		helpers.assert_nil(package.loaded["ui.menu.menu_utils"])
		helpers.assert_eq(type(package.loaded["infra.i18n"].section), "function")
		helpers.assert_eq(type(package.loaded["infra.i18n"].decorate_section), "function")
	end)
end)
