--- tests/unit/layouts/engine/test_input_sources_version_gt.lua

--- ==============================================================================
--- MODULE: input_sources.resolve_installed_ergopti_version Regression Test
--- DESCRIPTION:
--- Root-cause guard for the `version_gt` nil-global crash in
--- layouts/engine/input_sources.lua. The module's resolve_installed_ergopti_version()
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
		helpers.load_with_stubs("core.logger.engine.logger")

		-- Stub the install layer: report an Ergopti bundle in BOTH scopes so the
		-- `if user_best and system_best then` branch (the one calling version_gt) is taken.
		package.loaded["layouts.engine.registry.install"] = {
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
		package.loaded["layouts.engine.input_sources"] = nil
		local input_sources = require("layouts.engine.input_sources")

		local ok, result = pcall(input_sources.resolve_installed_ergopti_version)
		helpers.assert_true(ok,
			"resolve_installed_ergopti_version() raised — version_gt not imported into input_sources.lua: "
				.. tostring(result))
		-- When fixed it returns the higher of the two versions ({2,2,2}).
		helpers.assert_true(type(result) == "table" and result[3] == 2,
			"expected highest installed version {2,2,2}, got " .. tostring(result))
	end)

	-- The layout menu listed both Keyboard Layouts scopes up to four times per
	-- rebuild (57-415 ms stage spikes on a field Mac); it now reads them once
	-- and hands that snapshot to every reader, which must then list nothing.
	helpers.it("reads no folder when the caller hands both scopes in", function()
		helpers.load_with_stubs("core.logger.engine.logger")
		local listings = 0
		package.loaded["layouts.engine.registry.install"] = {
			USER_LAYOUTS_DIR   = "/Users/x/Library/Keyboard Layouts/",
			SYSTEM_LAYOUTS_DIR = "/Library/Keyboard Layouts/",
			highest_installed  = function() listings = listings + 1; return nil end,
			path_exists = function() return true end,
			version_gt = function(a, b) return a[3] > b[3] end,
			bundle_variants = function(path)
				helpers.assert_eq(path, "/Library/Keyboard Layouts/Ergopti_v2.2.2.bundle", "system scope first")
				return { { name = "Ergopti_v2_2_2_plus", tis_id = "com.apple.keylayout.ergopti.plus" } }
			end,
		}
		package.loaded["layouts.engine.input_sources"] = nil
		local input_sources = require("layouts.engine.input_sources")
		local installed = {
			system = { name = "Ergopti_v2.2.2.bundle", version = { 2, 2, 2 } },
			user   = { name = "Ergopti_v2.2.1.bundle", version = { 2, 2, 1 } },
		}
		local map, variants = input_sources.build_kl_name_to_tis_id(installed)
		helpers.assert_eq(map.Ergopti_v2_2_2_plus, "com.apple.keylayout.ergopti.plus")
		helpers.assert_eq(#variants, 1, "the variants the map was built from are handed back for reuse")
		helpers.assert_eq(input_sources.resolve_installed_ergopti_version(installed)[3], 2)
		local state = input_sources.ergopti_in_active_layouts({ { id = "com.apple.keylayout.ergopti.plus", name = "Ergopti+" } },
			installed)
		helpers.assert_eq(state.version[3], 2)
		helpers.assert_eq(input_sources.build_kl_name_to_tis_id({}), nil, "an empty snapshot means no bundle")
		helpers.assert_eq(listings, 0, "a snapshot must never be listed again")
		input_sources.resolve_installed_ergopti_version()
		helpers.assert_eq(listings, 2, "without a snapshot both scopes are still read")
	end)
end)
