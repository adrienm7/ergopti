--- tests/unit/ai/ui/menu/shortcuts/test_bad_modifiers.lua

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

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_src(selector)
	local s = helpers.read_driver_source(selector)
	return s
end

helpers.describe("menu_llm: wrong-typed modifier settings fail closed (F-HIGH-6)", function()
	helpers.it("format_shortcut_title type-guards mods BEFORE naming them", function()
		local src = read_src("local function format_shortcut_title") -- ai/ui/menu/init.lua
		local fn = src:match("local function format_shortcut_title.-\nend")
		helpers.assert_true(fn ~= nil, "format_shortcut_title must be locatable")
		local guard_pos  = fn:find('type(mods) ~= "table"', 1, true)
		-- The modifiers are named from the key name table (format_mods), which
		-- iterates them as a table just as table.concat did.
		local use_pos = fn:find("format_mods(mods", 1, true)
		helpers.assert_true(guard_pos ~= nil, "format_shortcut_title must type-guard mods (not just `not mods`)")
		helpers.assert_true(use_pos ~= nil, "format_shortcut_title still names mods")
		helpers.assert_true(guard_pos < use_pos, "the non-table guard must precede format_mods(mods)")
	end)

	helpers.it("nav/val modifier reads fail closed to the default on a non-table", function()
		local src = read_src("local function format_shortcut_title") -- ai/ui/menu/init.lua
		helpers.assert_true(src:find('type(nav_mods) ~= "table"', 1, true) ~= nil,
			"nav_mods read must guard against a non-table value, not only nil")
		helpers.assert_true(src:find('type(val_mods) ~= "table"', 1, true) ~= nil,
			"val_mods read must guard against a non-table value, not only nil")
	end)

	helpers.it("build_modifier_menu type-guards current_mods BEFORE table.concat", function()
		local src = read_src("local function generic_numeric_prompt") -- ai/ui/menu/settings_manager.lua
		-- The guard validates the whole array (a table holding a non-string also
		-- raises in table.concat), then falls back on any invalid value.
		local guard_pos  = src:find('local valid = type(current_mods) == "table"', 1, true)
		local element_pos = src:find('type(value) ~= "string"', guard_pos or 1, true)
		local fallback_pos = src:find("if not valid then", guard_pos or 1, true)
		local concat_pos = src:find("table.concat(current_mods", 1, true)
		helpers.assert_true(guard_pos ~= nil, "build_modifier_menu must type-guard current_mods")
		helpers.assert_true(element_pos ~= nil, "build_modifier_menu must reject non-string modifiers")
		helpers.assert_true(fallback_pos ~= nil, "an invalid current_mods must fall back to the default")
		helpers.assert_true(concat_pos ~= nil and guard_pos < element_pos and element_pos < fallback_pos
			and fallback_pos < concat_pos, "the array guard must precede table.concat(current_mods)")
	end)
end)
