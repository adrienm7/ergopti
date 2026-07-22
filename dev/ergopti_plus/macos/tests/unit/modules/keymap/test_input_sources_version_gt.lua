--- tests/unit/modules/keymap/test_input_sources_version_gt.lua

--- ==============================================================================
--- MODULE: input_sources.resolve_installed_ergopti_version Regression Test
--- DESCRIPTION:
--- Root-cause guard for the `version_gt` nil-global crash in
--- modules/keymap/input_sources.lua. The module's resolve_installed_ergopti_version()
--- (and, through it, ergopti_in_active_layouts() and the keyboard-layout submenu
--- builder) calls `version_gt(...)` WITHOUT importing it from layout_install — it
--- only pulls highest_installed / path_exists / the dir constants out of `install`.
--- The bare `version_gt` therefore resolves to a nil global, so the call path
--- raises "attempt to call a nil value (global 'version_gt')" the moment BOTH a
--- user-scope AND a system-scope Ergopti bundle are installed (the only state in
--- which the `if user_best and system_best` branch is taken).
---
--- This crash is silent in the default test suite because no test exercises the
--- both-dirs-installed state, and at runtime it fires inside the menu-build path
--- (pcall'd by the menubar), so the keyboard-layout submenu simply fails to build
--- with the error swallowed to the HS Console.
---
--- The test installs a layout_install stub reporting a bundle in BOTH directories,
--- then asserts resolve_installed_ergopti_version() returns the version WITHOUT
--- raising. It fails (pcall=false) before the fix and passes after version_gt is
--- imported.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =========================================================
--- =========================================================
-- ======= 1/ Both-Scope Install Reaches version_gt ========
--- =========================================================
-- =========================================================

helpers.describe("input_sources.resolve_installed_ergopti_version", function()
	helpers.it("does not crash when both user and system bundles are installed", function()
		-- load_with_stubs() resets the hs stub AND nils both keymap layout modules
		-- (helpers/init.lua), so install our layout_install stub AFTER it and require
		-- input_sources by hand so the stub is the one captured at its require-time.
		helpers.load_with_stubs("lib.logger")

		-- Stub the install layer: report an Ergopti bundle in BOTH scopes so the
		-- `if user_best and system_best then` branch (the one calling version_gt) is taken.
		package.loaded["modules.keymap.layout_install"] = {
			USER_LAYOUTS_DIR   = "/Users/x/Library/Keyboard Layouts/",
			SYSTEM_LAYOUTS_DIR = "/Library/Keyboard Layouts/",
			highest_installed  = function(dir)
				if dir == "/Library/Keyboard Layouts/" then
					return { name = "Ergopti_v2.2.2.bundle", version = { 2, 2, 2 } }
				end
				return { name = "Ergopti_v2.2.1.bundle", version = { 2, 2, 1 } }
			end,
			path_exists = function() return true end,
			-- Mirror the real layout_install export surface: input_sources must pull
			-- version_gt from here. Omitting it is exactly the production bug.
			version_gt = function(a, b)
				for i = 1, math.max(#a, #b) do
					local ai, bi = a[i] or 0, b[i] or 0
					if ai ~= bi then return ai > bi end
				end
				return false
			end,
		}
		package.loaded["modules.keymap.input_sources"] = nil
		local input_sources = require("modules.keymap.input_sources")

		local ok, result = pcall(input_sources.resolve_installed_ergopti_version)
		helpers.assert_true(ok,
			"resolve_installed_ergopti_version() raised — version_gt not imported into input_sources.lua: "
				.. tostring(result))
		-- When fixed it returns the higher of the two versions ({2,2,2}).
		helpers.assert_true(type(result) == "table" and result[3] == 2,
			"expected highest installed version {2,2,2}, got " .. tostring(result))
	end)
end)
