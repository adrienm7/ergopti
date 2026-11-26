--- tests/unit/menu/hotstrings/test_family_check.lua

--- ==============================================================================
--- MODULE: A Hotstring Family Is Never « Checked (0) »
--- DESCRIPTION:
--- The real tray over the bundled catalogue and the real configuration owner:
--- a category whose gate is open while none of its sections is ticked reads
--- « Autocorrection (0) » and is drawn unchecked; once a section is ticked it
--- counts its hotstrings and is drawn checked. Maintainer decision of
--- 2026-11-25, after the Arch tester read « Autocorrection (0) » ticked.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The category rows of the Hotstrings submenu, title → checked.
--- @param tick_sections boolean Whether every section is ticked first.
--- @return table rows
local function category_rows(tick_sections)
	local Config = helpers.load_module("hotstrings.engine.catalogue.config")
	helpers.assert_true(Config.init(helpers.load_module("hotstrings.engine.engine").new(), nil, function() end))
	helpers.assert_eq(select(2, Config.load_all(nil, true)), true, "the bundled catalogue loads")
	for _, group in ipairs(Config.get_groups()) do
		helpers.assert_true(Config.enable_group(group), "the gate opens")
		local category = Config.get_category(group)
		for name in pairs(category and category.sections or {}) do
			if Config.is_section_checked(group, name) ~= tick_sections then
				helpers.assert_true(Config.toggle_section(group, name))
			end
		end
	end
	local rows = {}
	local tree = helpers.load_module("menu.ui.builder.builder").build({
		paused = false, is_paused = function() return false end, config = Config, on_menu_changed = function() end,
	})
	for _, top in ipairs(tree) do
		if type(top.menu) == "table" and top.title:find("Hotstrings", 1, true) then
			for _, row in ipairs(top.menu) do
				if type(row.menu) == "table" and row.title:match("%(%d+%)") and row.checked ~= nil then
					rows[row.title] = row.checked
				end
			end
		end
	end
	return rows
end

helpers.describe("hotstring family check (family-check-not-zero)", function()
	helpers.it("the shared rule: an open gate with no active hotstring is not checked", function()
		local Labels = require("menu.engine.labels")
		helpers.assert_eq(Labels.family_checked(true, 0), false)
		helpers.assert_eq(Labels.family_checked(true, 3), true)
		helpers.assert_eq(Labels.family_checked(false, 3), false)
		helpers.assert_eq(Labels.family_checked(true, nil), false)
	end)

	helpers.it("draws an open family with nothing active unchecked, never « checked (0) »", function()
		local rows, count = category_rows(false), 0
		for title, checked in pairs(rows) do
			count = count + 1
			helpers.assert_true(title:match("%(0%)$") ~= nil, "no section ticked yet: " .. title)
			helpers.assert_eq(checked, false, title)
		end
		helpers.assert_true(count >= 2, "the walk reached the category rows")
	end)

	helpers.it("checks a family once one of its hotstrings is active", function()
		local rows, count = category_rows(true), 0
		for title, checked in pairs(rows) do
			count = count + 1
			helpers.assert_true(title:match("%(0%)$") == nil, "every section ticked: " .. title)
			helpers.assert_eq(checked, true, title)
		end
		helpers.assert_true(count >= 2, "the walk reached the category rows")
	end)
end)
