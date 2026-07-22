--- tests/unit/ui/test_menu_llm_bad_modifiers.lua

--- ==============================================================================
--- MODULE: Regression — LLM modifier menu tolerates wrong-typed settings (F-HIGH-6)
--- DESCRIPTION:
--- A corrupt / hand-edited / AHK-migrated hs.settings entry can store a STRING
--- (e.g. "shift+cmd") under llm_nav_modifiers / llm_val_modifiers where a table
--- is expected. The reads guarded only `== nil`, so the string survived into
--- format_shortcut_title and build_modifier_menu, which call
--- table.concat(mods, "+") — and table.concat on a string raises. Because the AI
--- submenu builder runs inside a pcall, that throw silently blanked the entire
--- LLM submenu from the menubar, leaving the user no way to configure LLM.
---
--- Fix: fail closed to the canonical DEFAULT_STATE on any non-table, and harden
--- both concat sites with a type guard BEFORE the concat. The reads and the local
--- builders are tested at source level (the builders are local + need deep deps).
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_src(rel)
	local path = helpers.driver_root() .. rel
	local fh = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "cannot open " .. tostring(path))
	local s = fh:read("*a"); fh:close()
	return s
end

helpers.describe("menu_llm: wrong-typed modifier settings fail closed (F-HIGH-6)", function()
	helpers.it("format_shortcut_title type-guards mods BEFORE table.concat", function()
		local src = read_src("ui/menu/menu_llm/init.lua")
		local fn = src:match("local function format_shortcut_title.-\nend")
		helpers.assert_true(fn ~= nil, "format_shortcut_title must be locatable")
		local guard_pos  = fn:find('type(mods) ~= "table"', 1, true)
		local concat_pos = fn:find("table.concat(mods", 1, true)
		helpers.assert_true(guard_pos ~= nil, "format_shortcut_title must type-guard mods (not just `not mods`)")
		helpers.assert_true(concat_pos ~= nil, "format_shortcut_title still concatenates mods")
		helpers.assert_true(guard_pos < concat_pos, "the non-table guard must precede table.concat(mods)")
	end)

	helpers.it("nav/val modifier reads fail closed to the default on a non-table", function()
		local src = read_src("ui/menu/menu_llm/init.lua")
		helpers.assert_true(src:find('type(nav_mods) ~= "table"', 1, true) ~= nil,
			"nav_mods read must guard against a non-table value, not only nil")
		helpers.assert_true(src:find('type(val_mods) ~= "table"', 1, true) ~= nil,
			"val_mods read must guard against a non-table value, not only nil")
	end)

	helpers.it("build_modifier_menu type-guards current_mods BEFORE table.concat", function()
		local src = read_src("ui/menu/menu_llm/settings_manager.lua")
		local guard_pos  = src:find('type(current_mods) ~= "table"', 1, true)
		local concat_pos = src:find("table.concat(current_mods", 1, true)
		helpers.assert_true(guard_pos ~= nil, "build_modifier_menu must type-guard current_mods")
		helpers.assert_true(concat_pos ~= nil and guard_pos < concat_pos,
			"the non-table guard must precede table.concat(current_mods)")
	end)
end)
