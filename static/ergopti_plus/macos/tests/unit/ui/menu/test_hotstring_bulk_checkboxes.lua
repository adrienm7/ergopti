--- tests/unit/ui/menu/test_hotstring_bulk_checkboxes.lua

--- ==============================================================================
--- MODULE: Regression — every hotstring bulk control is one checkbox
--- DESCRIPTION:
--- A hotstring category submenu opens with its gate, then offers one control for
--- all of its sections; a language submenu, the personal submenu and the top of
--- the Hotstrings menu each offer one control for every section under them. Each
--- is a checkbox: one label, ticked from the state it governs, and a click that
--- switches everything to the other side.
---
--- WHY IT EXISTS: the gate alternated between « ✅ Activée (cliquer pour
--- désactiver) » and « ❌ Désactivée (cliquer pour activer) », and the sections
--- came with a « Tout activer » / « Tout désactiver » pair — two keys and two
--- rows for one control, and a state the user could only read from the words.
--- Built from the real providers over a keymap double, so the tick and the batch
--- the click sends are what is asserted, not the labels alone.
--- ==============================================================================

local helpers = require("tests.helpers")

local RETIRED = {
	"menu.hotstrings.category_on", "menu.hotstrings.category_off",
	"menu.hotstrings.enable_all", "menu.hotstrings.disable_all",
}

--- A context whose groups each carry two real sections, a separator and a
--- module placeholder.
--- @param sections_on boolean Whether every section is on.
--- @param group_on boolean Whether every group gate is on.
--- @param files table|nil Hotstring files, default { "alpha.toml" }.
--- @return table ctx, table batches
local function context(sections_on, group_on, files)
	local batches = {}
	local function sections_of()
		return {
			{ name = "one" },
			{ name = "-" },
			{ name = "module", is_module_placeholder = true },
			{ name = "two" },
		}
	end
	local ctx = {
		paused = false,
		hotfiles = files or { "alpha.toml" },
		get_group_name = function(path) return (path:gsub("%.toml$", "")) end,
		state = { hotstrings = {}, keymap = true, sections_order_overrides = {} },
		applyTriggerChar = function(value) return value end,
		keymap = {
			is_group_enabled = function() return group_on end,
			get_sections = function() return sections_of() end,
			is_section_enabled = function() return sections_on end,
			set_groups_sections_enabled = function(changes, enabled)
				batches[#batches + 1] = { changes = changes, enabled = enabled }
				return true
			end,
			start = function() return true end,
			is_started = function() return true end,
		},
		save_prefs = function() return true end,
		updateMenu = function() end,
		notify_feature = function() end,
	}
	return ctx, batches
end

--- The row of `rows` labelled `key`.
--- @param rows table
--- @param key string
--- @return table|nil
local function row_labelled(rows, key)
	for _, row in ipairs(rows or {}) do
		if row.label == key then return row end
	end
	return nil
end

--- Asserts that no row of `rows`, at any depth, still draws a retired label.
--- @param rows table
--- @param where string
local function assert_no_retired(rows, where)
	local seen = 0
	local function walk(list)
		for _, row in ipairs(list or {}) do
			if type(row.label) == "string" then
				seen = seen + 1
				for _, retired in ipairs(RETIRED) do
					helpers.assert_true(row.label ~= retired, where .. " still draws the retired '" .. retired .. "' row")
				end
			end
			walk(row.items)
		end
	end
	walk(rows)
	helpers.assert_true(seen > 0, where .. " drew no labelled row, so the absence proves nothing")
end

helpers.describe("hotstring bulk controls are one checkbox each", function()
	for _, posture in ipairs({ true, false }) do
		helpers.it("a category submenu opens with its gate, ticked " .. tostring(posture), function()
			local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
			local ctx = context(true, posture)
			local rows = hotstrings.build_groups(ctx, nil, { group_counts = {} })
			local sub = rows[1] and rows[1].items
			helpers.assert_true(type(sub) == "table", "the category must open a submenu")
			helpers.assert_eq(sub[1].label, "menu.hotstrings.category_enable", "the gate is the first row")
			helpers.assert_eq(sub[1].checked, posture, "the gate is a checkbox ticked from the group gate")
			helpers.assert_eq(type(sub[1].action), "function", "the gate must be clickable")
			assert_no_retired(rows, "the category submenu")
		end)

		helpers.it("a category offers one « all sections » checkbox, ticked " .. tostring(posture), function()
			local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
			local ctx, batches = context(posture, true)
			local rows = hotstrings.build_groups(ctx, nil, { group_counts = {} })
			local all = row_labelled(rows[1].items, "menu.hotstrings.enable_all_sections")
			helpers.assert_true(all ~= nil, "the category submenu must offer one control for all its sections")
			helpers.assert_eq(all.checked, posture, "it is ticked exactly when every section is on")
			all.action()
			helpers.assert_eq(#batches, 1, "one click is one batch")
			helpers.assert_eq(batches[1].enabled, not posture, "the click switches every section to the other side")
			helpers.assert_eq(batches[1].changes[1].sections, { "one", "two" },
				"every real section, and neither the separator nor the module placeholder")
		end)

		helpers.it("a language submenu opens with one checkbox, ticked " .. tostring(posture), function()
			local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
			local ctx, batches = context(posture, posture)
			local rows = hotstrings.build_language_bulk_actions(ctx, { "alpha" })
			helpers.assert_eq(#rows, 1, "the pair is one row")
			helpers.assert_eq(rows[1].label, "menu.hotstrings.enable_all_sections")
			helpers.assert_eq(rows[1].checked, posture, "ticked exactly when every category and section is on")
			rows[1].action()
			helpers.assert_eq(#batches, 1, "one click is one batch")
			helpers.assert_eq(batches[1].enabled, not posture, "the click switches the whole language")
		end)

		helpers.it("the top of the menu has one switch for every section, ticked " .. tostring(posture), function()
			local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
			local ctx, batches = context(posture, posture, { "alpha.toml", "beta.toml" })
			local switch = hotstrings.all_sections_switch(ctx)
			helpers.assert_eq(switch.checked, posture, "ticked exactly when every group and section is on")
			helpers.assert_eq(type(switch.action), "function", "the switch must act")
			switch.action()
			helpers.assert_eq(#batches, 1, "one click is one batch")
			helpers.assert_eq(batches[1].enabled, not posture, "the click switches the whole tree")
			helpers.assert_eq(#batches[1].changes, 2, "every group is in the batch")
		end)
	end

	helpers.it("one group with a section off leaves every « all » checkbox unticked", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ctx = context(true, true, { "alpha.toml", "beta.toml" })
		ctx.keymap.is_section_enabled = function(group, section)
			return not (group == "beta" and section == "two")
		end
		helpers.assert_eq(hotstrings.all_sections_switch(ctx).checked, false,
			"« all on » means all of them: one section off is not all")
		local rows = hotstrings.build_language_bulk_actions(ctx, { "alpha", "beta" })
		helpers.assert_eq(rows[1].checked, false, "the language checkbox reads every one of its groups")
		helpers.assert_eq(hotstrings.build_language_bulk_actions(ctx, { "alpha" })[1].checked, true,
			"and only its own groups")
	end)

	helpers.it("a paused script greys every checkbox and gives it no click", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ctx = context(true, true)
		ctx.paused = true
		local sub = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].items
		local all = row_labelled(sub, "menu.hotstrings.enable_all_sections")
		helpers.assert_eq(sub[1].disabled, true, "the gate is greyed while paused")
		helpers.assert_nil(sub[1].action, "and cannot be clicked")
		helpers.assert_eq(all.disabled, true, "the « all sections » checkbox is greyed while paused")
		helpers.assert_nil(all.action, "and cannot be clicked")
		helpers.assert_eq(all.checked, true, "the tick still says what is on")
	end)

	helpers.it("the personal submenu offers one « all sections » checkbox per group", function()
		local custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
		local ctx, batches = context(true, true, { "personal.toml" })
		ctx.state.trigger_char = "★"
		ctx.hotstring_editor = { open = function() end }
		local built = custom.build_custom(ctx, { group_counts = {} })
		helpers.assert_eq(built.items[1].label, "menu.hotstrings.category_enable",
			"the personal submenu opens with its gate")
		helpers.assert_eq(built.items[1].checked, true, "ticked from the personal and custom gates")
		local all = row_labelled(built.items, "menu.hotstrings.enable_all_sections")
		helpers.assert_true(all ~= nil, "the personal sections must have one « all » checkbox")
		helpers.assert_eq(all.checked, true, "every personal section is on")
		all.action()
		helpers.assert_eq(#batches, 1, "one click is one batch")
		helpers.assert_eq(batches[1].enabled, false, "a ticked checkbox switches its sections off")
		assert_no_retired(built.items, "the personal submenu")
	end)
end)
