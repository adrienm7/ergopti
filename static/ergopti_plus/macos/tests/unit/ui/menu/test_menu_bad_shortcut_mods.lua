--- tests/unit/ui/menu/test_menu_bad_shortcut_mods.lua

--- ==============================================================================
--- MODULE: Regression — string-typed shortcut.mods no longer crashes menus (M-13)
--- DESCRIPTION:
--- Shortcuts persisted to disk before the coerce_mods fix stored .mods as a plain
--- string (e.g. mods="ctrl") instead of a table. ipairs and table.concat both
--- raise on non-table values, which crashed the hotstrings and metrics submenu
--- builders silently (pcall in the menu tick).
---
--- Fix: coerce_mods() wraps both callsites in menu_hotstrings.lua and
--- menu_metrics.lua — { mods="ctrl" } is treated as { mods={"ctrl"} }.
---
--- Tests:
---   Source checks: coerce_mods helper present in both files.
---   Source checks: no bare ipairs(sc.mods) / table.concat(sc.mods) remaining.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src(rel_path)
	local path = helpers.driver_root() .. rel_path
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, rel_path .. " must be readable")
	local src = fh:read("*a"); fh:close()
	return src
end





-- ===================================================================================
-- ===================================================================================
-- ======= 1/ Source: coerce_mods present in menu_hotstrings and menu_metrics =======
-- ===================================================================================
-- ===================================================================================

helpers.describe("M-13: coerce_mods helper present (source)", function()

	helpers.it("menu_hotstrings.lua defines coerce_mods", function()
		local src = read_src("ui/menu/menu_hotstrings.lua")
		helpers.assert_true(src:find("coerce_mods", 1, true) ~= nil,
			"menu_hotstrings.lua must define coerce_mods to handle string-typed .mods")
	end)

	helpers.it("menu_metrics.lua defines coerce_mods", function()
		local src = read_src("ui/menu/menu_metrics.lua")
		helpers.assert_true(src:find("coerce_mods", 1, true) ~= nil,
			"menu_metrics.lua must define coerce_mods to handle string-typed .mods")
	end)
end)





-- ======================================================================================
-- ======================================================================================
-- ======= 2/ Source: no bare ipairs(sc.mods) or table.concat(sc.mods) remaining =======
-- ======================================================================================
-- ======================================================================================

helpers.describe("M-13: no unguarded sc.mods usage remaining (source)", function()

	helpers.it("menu_hotstrings.lua: ipairs(sc.mods) replaced by coerce_mods", function()
		local src = read_src("ui/menu/menu_hotstrings.lua")
		-- ipairs(sc.mods ...) without coerce_mods wrapping is the crash pattern
		local bare = src:find("ipairs(sc%.mods")
		helpers.assert_true(bare == nil,
			"menu_hotstrings.lua must not call ipairs(sc.mods) directly — use coerce_mods(sc.mods)")
	end)

	helpers.it("menu_hotstrings.lua: table.concat(sc.mods ...) replaced by coerce_mods", function()
		local src = read_src("ui/menu/menu_hotstrings.lua")
		local bare = src:find("table%.concat%(sc%.mods")
		helpers.assert_true(bare == nil,
			"menu_hotstrings.lua must not call table.concat(sc.mods,...) directly — use coerce_mods(sc.mods)")
	end)

	helpers.it("menu_metrics.lua: no bare ipairs on .mods fields", function()
		local src = read_src("ui/menu/menu_metrics.lua")
		-- Check both known field names used in metrics
		local bare1 = src:find("ipairs(state%.metrics_shortcut%.mods")
		local bare2 = src:find("ipairs(state%.apps_time_shortcut%.mods")
		helpers.assert_true(bare1 == nil and bare2 == nil,
			"menu_metrics.lua must not call ipairs on .mods directly — use coerce_mods")
	end)

	helpers.it("menu_metrics.lua: no bare table.concat on .mods fields", function()
		local src = read_src("ui/menu/menu_metrics.lua")
		local bare1 = src:find("table%.concat%(state%.metrics_shortcut%.mods")
		local bare2 = src:find("table%.concat%(state%.apps_time_shortcut%.mods")
		helpers.assert_true(bare1 == nil and bare2 == nil,
			"menu_metrics.lua must not call table.concat on .mods directly — use coerce_mods")
	end)
end)
