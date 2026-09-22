--- tests/unit/ui/test_menu_languages_and_global_separator.lua

--- ==============================================================================
--- MODULE: Hotstring Language Header And Global Actions Separator (Linux)
--- DESCRIPTION:
--- Two layout fixes to menus the three drivers render from the shared manifest.
---
--- The language packs were one bare « Français (n) » row among the neutral
--- categories, which users read as one more category and overlooked. They now
--- sit under a « Hotstrings par langue » header, behind a separator, and each
--- row starts with its locale's flag from the shared locale table.
---
--- « Nettoyer les réglages inutilisés » edits the configuration file while the
--- three rows above it switch features; a separator now sets it apart.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A hotstrings config double that declares the French language pack.
--- @return table
local function fake_config()
	return {
		get_groups = function() return { "rolls" } end,
		is_group_enabled = function() return true end,
		toggle_group = function() end,
		enable_all = function() end,
		disable_all = function() end,
		is_section_enabled = function() return true end,
		get_category = function() return nil end,
		get_categories = function() return {} end,
		language_packs = function()
			return { { id = "french", locale = "fr", categories = { "autocorrection" } } }
		end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}
end

--- Whether a built row is a separator.
--- @param row table|nil
--- @return boolean
local function is_separator(row)
	return type(row) == "table" and (row.separator == true or row.title == "-")
end

--- The submenu holding a row whose title contains `needle`.
--- @param items table
--- @param needle string
--- @return table|nil rows, number|nil index
local function submenu_with(items, needle)
	for _, item in ipairs(items or {}) do
		if type(item.menu) == "table" then
			for index, row in ipairs(item.menu) do
				if type(row.title) == "string" and row.title:find(needle, 1, true) then
					return item.menu, index
				end
			end
		end
	end
	return nil, nil
end

helpers.describe("tray layout (linux): language header and global separator", function()
	helpers.it("hotstring languages: header, separator and flag before the language row", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local i18n = require("infra.i18n")
		local rows, at = submenu_with(mb.build({ config = fake_config(), _version = "9.9.9" }), "Français")
		helpers.assert_true(rows ~= nil, "the French language pack row must be drawn")
		helpers.assert_eq(rows[at].title:sub(1, #"🇫🇷 Français"), "🇫🇷 Français",
			"the language row starts with the locale's flag, from the shared locale table")
		local header = rows[at - 1] and rows[at - 1].title or ""
		helpers.assert_true(header:find(i18n.get("menu.hotstrings.header_languages"), 1, true) ~= nil,
			"a « Hotstrings par langue » header must precede the language rows, got '" .. header .. "'")
		helpers.assert_true(is_separator(rows[at - 2]), "and a separator must precede that header")
	end)

	helpers.it("global actions: a separator precedes the unused-settings cleanup", function()
		local mb = helpers.load_module("ui.menu.menu_builder")
		local label = require("infra.i18n").get("menu.global.clean_unused_keys")
		local rows, at = submenu_with(mb.build({ _version = "9.9.9", on_quit = function() end }), label)
		helpers.assert_true(rows ~= nil and at > 1, "the cleanup row must follow the other global actions")
		helpers.assert_true(is_separator(rows[at - 1]),
			"a separator must precede « Nettoyer les réglages inutilisés »")
	end)
end)
