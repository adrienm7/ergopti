--- tests/unit/ui/menu/test_menu_extension_hotstrings.lua

--- ==============================================================================
--- MODULE: Hotstrings Menu — Extension Submenus (macOS)
--- DESCRIPTION:
--- The Hotstrings menu lists the hotstrings an extension brings under one
--- « Hotstrings <extension> » submenu in its extensions section. The Ergopti
--- layout extension binds SFB reduction and rolls there, under their historical
--- ids, instead of a « Disposition Ergopti » section of their own; without the
--- extension they are not listed at all.
--- ==============================================================================

local helpers = require("tests.helpers")

local ERGOPTI = {
	id = "ergopti", name = "Ergopti", toml_files = {},
	bound_files = {
		{ stem = "repeatcorrections", binding = { category = "magickey", sections = { "repeat_corrections" } } },
		{ stem = "rolls", binding = { category = "rolls" } },
		{ stem = "sfbsreduction", binding = { category = "sfbsreduction" } },
	},
}
local DEMO = { id = "demo", name = "Demo", toml_files = { { stem = "phrases" } }, bound_files = {} }

--- A menu context with the given loaded groups and discovery catalogue.
--- @param hotfiles table Loaded group names.
--- @param packs table Discovery catalogue.
--- @return table
local function context(hotfiles, packs)
	return { hotfiles = hotfiles, extension_packs = packs, get_group_name = function(name) return name end }
end

helpers.describe("Hotstrings menu: extension submenus", function()
	helpers.it("(ergopti-hotstrings-ext) lists SFB reduction and rolls under the Ergopti extension", function()
		local Builder = helpers.load_with_stubs("ui.menu.builder")
		local ctx = context({ "autocorrection", "magickey", "rolls", "sfbsreduction", "ext:demo:phrases" },
			{ DEMO, ERGOPTI })
		local by_extension, bound = Builder.bound_groups(ctx)
		helpers.assert_eq(bound, { rolls = true, sfbsreduction = true },
			"a section binding leaves the magic key among the common categories")
		local counts = {
			group_counts = { rolls = 7, sfbsreduction = 5 },
			ext_details = { { id = "demo", name = "Demo", total = 3, groups = { "ext:demo:phrases" } } },
		}
		helpers.assert_eq(Builder.extension_menus(ctx, counts, by_extension), {
			{ id = "demo", name = "Demo", groups = { "ext:demo:phrases" }, total = 3 },
			{ id = "ergopti", name = "Ergopti", groups = { "rolls", "sfbsreduction" }, total = 12 },
		})
		local source = helpers.read_driver_source("function M.extension_menus")
		helpers.assert_true(source:find('i18n.get("menu.extensions.hotstrings_of"), menu.name)', 1, true) ~= nil,
			"each submenu is labelled « Hotstrings <extension> »")
		helpers.assert_true(source:find('["hotstring_categories_ergopti"]', 1, true) == nil,
			"the « Disposition Ergopti » section is gone")
	end)

	helpers.it("(ergopti-hotstrings-ext) lists nothing for an extension that is not installed", function()
		local Builder = helpers.load_with_stubs("ui.menu.builder")
		local ctx = context({ "autocorrection", "magickey" }, {})
		local by_extension, bound = Builder.bound_groups(ctx)
		helpers.assert_eq(bound, {})
		helpers.assert_eq(Builder.extension_menus(ctx, { group_counts = {}, ext_details = {} }, by_extension), {})
	end)
end)
