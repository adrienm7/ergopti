--- tests/unit/ui/test_hotstring_bulk_checkboxes.lua

--- ==============================================================================
--- MODULE: Regression — explicit category commands and scope checkboxes
--- DESCRIPTION:
--- Standard categories dispatch the requested full-enable/full-disable posture
--- through one owner, including dynamic families. Language and whole-tree controls retain their
--- separate checkbox behavior until their scoped migration.
--- The whole tray is built from the real builder over a recording config, so the
--- tick and the write each click sends are what is asserted.
--- ==============================================================================

local helpers = require("tests.helpers")

local LANGUAGE_CATEGORY = "en_typos"

--- A hotstrings config double: two neutral categories and one language pack,
--- each with two sections.
--- @param gates_on boolean Every category gate.
--- @param sections_on boolean Every section tick.
--- @return table config, table log
local function fake_config(gates_on, sections_on)
	local log = { set_categories_sections = {}, scoped = {}, toggled = {} }
	local categories = {}
	for _, id in ipairs({ "autocorrection", "rolls", LANGUAGE_CATEGORY }) do
		categories[id] = {
			id = id, count = 3, sections_order = { "first", "second" },
			sections = { first = { count = 1 }, second = { count = 2 } },
		}
	end
	return {
		get_groups = function() return { "autocorrection", "rolls", LANGUAGE_CATEGORY } end,
		get_categories = function() return categories end,
		get_category = function(id) return categories[id] end,
		language_packs = function()
			return { { id = "en", locale = "en", categories = { "typos" } } }
		end,
		is_group_enabled = function() return gates_on end,
		is_section_enabled = function() return gates_on and sections_on end,
		is_section_checked = function() return sections_on end,
		active_count = function() return 0 end,
		toggle_group = function(id) log.toggled[#log.toggled + 1] = id end,
		set_category_scope_enabled = function(ids, on)
			log.scoped[#log.scoped + 1] = { ids = ids, on = on }
			return true
		end,
		set_categories_sections = function(ids, on)
			local copy = {}
			for _, id in ipairs(ids) do copy[#copy + 1] = id end
			table.sort(copy)
			log.set_categories_sections[#log.set_categories_sections + 1] = { ids = copy, on = on }
			return true
		end,
		enable_all = function() end,
		disable_all = function() end,
		resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
		get_global_delay = function() return 0.75 end,
		has_global_delay_override = function() return false end,
	}, log
end

--- A dynamic-hotstrings manager double with two rule families.
--- @param on boolean The category gate.
--- @param families_on boolean Every family.
--- @return table dyn, table log
local function fake_dyn(on, families_on)
	local log = { set_enabled = {}, rules = {}, scoped = {} }
	return {
		is_enabled = function() return on end,
		active_count = function() return 0 end,
		set_enabled = function(value) log.set_enabled[#log.set_enabled + 1] = value end,
		set_scope_enabled = function(value, config)
			log.scoped[#log.scoped + 1] = { on = value, config = config }
			return true
		end,
		rule_families = function()
			return {
				{ section = "dates", label = "Dates", enabled = families_on },
				{ section = "tags", label = "Tags", enabled = families_on },
			}
		end,
		set_rule_enabled = function(section, value) log.rules[#log.rules + 1] = { section = section, on = value } end,
	}, log
end

--- The Hotstrings submenu of the whole tray.
--- @param config table
--- @param dyn table|nil Dynamic-hotstrings manager double.
--- @return table|nil
local function hotstrings_menu(config, dyn, paused, snapshot_paused)
	local mb = helpers.load_module("ui.menu.menu_builder")
	local i18n = require("infra.i18n")
	local title = i18n.get("menu.hotstrings.title")
	local ctx = { config = config, _version = "9.9.9", dyn_hotstrings = dyn or fake_dyn(true, true),
		-- A live getter can change after the menu snapshot was constructed.
		paused = snapshot_paused == true, is_paused = function() return paused == true end,
		on_toggle_pause = function() error("dynamic bulk selection must not toggle capture") end }
	for _, item in ipairs(mb.build(ctx) or {}) do
		if type(item.title) == "string" and item.title:sub(1, #title) == title then
			return item.menu, item
		end
	end
	return nil
end

--- The row of `rows` titled with the translation of `key`, or whose title
--- starts with it.
--- @param rows table
--- @param key string
--- @return table|nil
local function row_for(rows, key)
	local text = require("infra.i18n").get(key)
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:sub(1, #text) == text then return row end
	end
	return nil
end

--- Asserts that no row of the tree still draws a retired label.
--- @param rows table
local function assert_no_retired(rows)
	local i18n = require("infra.i18n")
	local retired = {}
	for _, key in ipairs({ "menu.hotstrings.category_on", "menu.hotstrings.category_off",
		"menu.hotstrings.enable_all", "menu.hotstrings.disable_all" }) do
		retired[i18n.get(key)] = key
	end
	local seen = 0
	local function walk(list)
		for _, row in ipairs(list or {}) do
			if type(row.title) == "string" then
				seen = seen + 1
				helpers.assert_nil(retired[row.title], "the tray still draws the retired row " .. tostring(retired[row.title]))
			end
			walk(row.menu)
		end
	end
	walk(rows)
	helpers.assert_true(seen > 10, "the walk must have seen the tree, or the absence proves nothing")
end

helpers.describe("hotstring bulk controls are one checkbox each (linux)", function()
	for _, posture in ipairs({ true, false }) do
		for _, enabled in ipairs({ true, false }) do
			helpers.it("bulk checkbox: category command " .. tostring(enabled)
				.. " with previous gate " .. tostring(posture), function()
				local config, log = fake_config(posture, not posture)
				local menu = hotstrings_menu(config)
				local category = row_for(menu, "category.autocorrection") or row_for(menu, "autocorrection")
				helpers.assert_true(category ~= nil and type(category.menu) == "table")
				local row = category.menu[enabled and 1 or 2]
				helpers.assert_eq(row.title, require("infra.i18n").get(enabled
					and "menu.hotstrings.scope_enable_all" or "menu.hotstrings.scope_disable_all"))
				helpers.assert_nil(row.checked)
				row.fn()
				helpers.assert_eq(log.scoped, { { ids = { "autocorrection" }, on = enabled } })
				helpers.assert_eq(log.set_categories_sections, {}, "one scope owner replaces both old mutations")
				helpers.assert_eq(log.toggled, {})
			end)
		end

		helpers.it("bulk checkbox:a language opens with one checkbox, ticked " .. tostring(posture), function()
			local config, log = fake_config(posture, posture)
			local menu = hotstrings_menu(config)
			local language
			for _, row in ipairs(menu) do
				if type(row.menu) == "table" and row_for(row.menu, "menu.hotstrings.enable_all_sections")
					and row_for(row.menu, "menu.hotstrings.enable_all_sections") == row.menu[1] then
					language = row
				end
			end
			helpers.assert_true(language ~= nil, "a language submenu must open with its « all sections » checkbox")
			local all = language.menu[1]
			helpers.assert_eq(all.checked, posture, "ticked exactly when every category and section is on")
			all.fn()
			helpers.assert_eq(#log.set_categories_sections, 1, "one click is one write for the whole language")
			helpers.assert_eq(log.set_categories_sections[1].ids, { LANGUAGE_CATEGORY })
			helpers.assert_eq(log.set_categories_sections[1].on, not posture)
		end)

		for _, enabled in ipairs({ true, false }) do
			for _, paused in ipairs({ true, false }) do
				helpers.it("dynamic bulk menu: explicit " .. tostring(enabled) .. " from " .. tostring(posture)
					.. " paused " .. tostring(paused), function()
					local config = fake_config(false, true)
					local dyn, log = fake_dyn(posture, not posture)
					local menu = hotstrings_menu(config, dyn, paused)
					local category = row_for(menu, "category.dynamic_hotstrings")
					helpers.assert_true(category ~= nil and type(category.menu) == "table")
					helpers.assert_eq(category.checked, posture, "effective category state stays visible")
					for index, key in ipairs({ "menu.hotstrings.scope_enable_all", "menu.hotstrings.scope_disable_all" }) do
						helpers.assert_eq(category.menu[index].title, require("infra.i18n").get(key))
						helpers.assert_nil(category.menu[index].checked, "explicit requests are commands")
						helpers.assert_eq(category.menu[index].disabled == true, false, "the bulk request is independent of its closed category gate")
					end
					helpers.assert_nil(row_for(category.menu, "menu.hotstrings.category_enable"), "no duplicate category gate")
					helpers.assert_nil(row_for(category.menu, "menu.hotstrings.enable_all_sections"), "no multi-write family checkbox")
					helpers.assert_not_nil(row_for(category.menu, "menu.shortcuts.edit_personal_info"), "personal editor remains available")
					category.menu[enabled and 1 or 2].fn()
					helpers.assert_eq(log.scoped, { { on = enabled, config = config } }, "one request to the transactional owner")
					helpers.assert_eq(log.set_enabled, {}, "no separate master write")
					helpers.assert_eq(log.rules, {}, "no loop of per-family writes")
				end)
			end
		end

		helpers.it("bulk checkbox:the Hotstrings menu has one checkbox for every section, ticked " .. tostring(posture), function()
			local config, log = fake_config(posture, posture)
			local menu = hotstrings_menu(config)
			local all = row_for(menu, "menu.hotstrings.enable_all_sections")
			helpers.assert_true(all ~= nil, "the top of the menu must offer one « all sections » checkbox")
			helpers.assert_eq(all.checked, posture, "ticked exactly when every category and section is on")
			all.fn()
			helpers.assert_eq(#log.set_categories_sections, 1, "one click is one write")
			helpers.assert_eq(log.set_categories_sections[1].ids, { "autocorrection", LANGUAGE_CATEGORY, "rolls" },
				"every category, in one write")
			helpers.assert_eq(log.set_categories_sections[1].on, not posture)
			assert_no_retired(menu)
		end)
	end
end)

helpers.describe("dynamic bulk menu: pause ownership", function()
	helpers.it("dynamic bulk menu: paused snapshot keeps the feature disabled without starting capture", function()
		local config = fake_config(false, true)
		local dyn, log = fake_dyn(true, true)
		local menu, row = hotstrings_menu(config, dyn, true, true)
		helpers.assert_nil(menu, "the existing paused top-level policy strips feature descendants")
		helpers.assert_true(row.disabled)
		helpers.assert_nil(row.fn)
		helpers.assert_eq(log.scoped, {})
		helpers.assert_eq(log.rules, {})
		helpers.assert_eq(log.set_enabled, {})
	end)
end)
