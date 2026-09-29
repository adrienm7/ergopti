--- tests/unit/ui/test_menu_extension_hotstrings.lua

--- ==============================================================================
--- MODULE: Hotstrings Menu — Extension Submenus (Linux)
--- DESCRIPTION:
--- The Hotstrings menu lists the hotstrings an extension brings under one
--- « Hotstrings <extension> » submenu in its extensions section. The Ergopti
--- layout extension binds SFB reduction and rolls there, under their historical
--- ids, instead of a « Disposition Ergopti » section of their own; without the
--- extension they are not listed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A hotstrings config double whose loaded categories name their extension.
--- @param with_ergopti boolean Whether the Ergopti extension supplied its categories.
--- @return table
local function fake_config(with_ergopti)
	local ergopti = { id = "ergopti", name = "Ergopti" }
	local categories = {
		magickey = { id = "magickey", count = 3, sections_order = { "symbols" },
			sections = { symbols = { count = 3 } } },
	}
	if with_ergopti then
		categories.magickey.count = 17
		categories.magickey.sections_order = { "repeat_corrections", "symbols" }
		categories.magickey.sections.repeat_corrections = { count = 14, extension = ergopti }
		categories.sfbsreduction = { id = "sfbsreduction", count = 5, extension = ergopti,
			sections_order = { "comma" }, sections = { comma = { count = 5 } } }
		categories.rolls = { id = "rolls", count = 7, extension = ergopti,
			sections_order = { "hc" }, sections = { hc = { count = 7 } } }
	end
	return {
		get_groups = function()
			local out = { "magickey" }
			if with_ergopti then out[#out + 1] = "rolls"; out[#out + 1] = "sfbsreduction" end
			return out
		end,
		is_group_enabled = function() return true end,
		toggle_group = function() end,
		enable_all = function() end,
		disable_all = function() end,
		is_section_enabled = function() return true end,
		get_category = function(id) return categories[id] end,
		get_categories = function() return categories end,
		language_packs = function() return {} end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
end

--- Every row title of a built tree, depth first.
--- @param items table
--- @param out table|nil
--- @return table
local function titles(items, out)
	out = out or {}
	for _, item in ipairs(items or {}) do
		if type(item.title) == "string" then out[#out + 1] = item end
		if type(item.menu) == "table" then titles(item.menu, out) end
	end
	return out
end

--- The first row whose title starts with `prefix`.
--- @param items table
--- @param prefix string
--- @return table|nil
local function row_starting(items, prefix)
	for _, row in ipairs(titles(items)) do
		if row.title:sub(1, #prefix) == prefix then return row end
	end
	return nil
end

helpers.describe("Hotstrings menu (linux): extension submenus", function()
	helpers.it("(ergopti-hotstrings-ext) lists SFB reduction and rolls in a Hotstrings Ergopti submenu", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local i18n = require("infra.i18n")
		local label = string.format(i18n.get("menu.extensions.hotstrings_of"), "Ergopti")
		local row = row_starting(mb.build({ config = fake_config(true), _version = "9.9.9" }), label)
		helpers.assert_true(row ~= nil, "the « " .. label .. " » submenu must be drawn")
		local inside = {}
		for _, child in ipairs(row.menu or {}) do inside[#inside + 1] = child.title end
		local text = table.concat(inside, "|")
		-- The rows are the categories' own submenus, labelled by their category.
		helpers.assert_true(text:find(" (7)", 1, true) ~= nil, "rolls: " .. text)
		helpers.assert_true(text:find(" (5)", 1, true) ~= nil, "SFB reduction: " .. text)
		helpers.assert_true(text:find("repeat_corrections (14)", 1, true) ~= nil, "repeat corrections: " .. text)
		-- The menu manifest's order, which Windows walks too and every driver
		-- listed before the move, although rolls loads first here.
		helpers.assert_true(text:find(" (5)", 1, true) < text:find(" (7)", 1, true),
			"SFB reduction comes before rolls: " .. text)
	end)

	helpers.it("(ergopti-hotstrings-ext) takes the repeat corrections out of the magic key submenu", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local built = mb.build({ config = fake_config(true), _version = "9.9.9" })
		local label = string.format(require("infra.i18n").get("menu.extensions.hotstrings_of"), "Ergopti")
		local seen = 0
		for _, row in ipairs(titles(built)) do
			if row.title:find("repeat_corrections", 1, true) then seen = seen + 1 end
		end
		helpers.assert_eq(seen, 1, "the section is drawn once, in the Ergopti submenu")
		helpers.assert_true(row_starting(built, label) ~= nil)
		local symbols = row_starting(built, "symbols (3)")
		helpers.assert_true(symbols ~= nil, "the magic key keeps its own sections")
	end)

	helpers.it("(ergopti-hotstrings-ext) draws no Ergopti submenu when the extension is not installed", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local i18n = require("infra.i18n")
		local label = string.format(i18n.get("menu.extensions.hotstrings_of"), "Ergopti")
		helpers.assert_nil(row_starting(mb.build({ config = fake_config(false), _version = "9.9.9" }), label))
	end)
end)
