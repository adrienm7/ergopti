--- tests/unit/ui/menu/test_hotstring_bulk_checkboxes.lua

--- ==============================================================================
--- MODULE: Regression — explicit categories and independent bulk selection
--- DESCRIPTION:
--- Category commands set their requested posture through one atomic owner, keep
--- the root engine stopped, and withhold UI publication after refused saves.
--- Language, personal and whole-tree section controls retain their existing
--- independent checkbox contracts until their own scoped migration.
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
			set_category_scope_enabled = function(names, enabled, publish)
				batches[#batches + 1] = { names = names, enabled = enabled }
				return publish()
			end,
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
		for _, enabled in ipairs({ true, false }) do
			helpers.it("a category offers the explicit scope command " .. tostring(enabled)
				.. " behind group gate " .. tostring(posture), function()
				local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
				local ctx, batches = context(not posture, posture)
				ctx.state.keymap = false
				local starts, saves, updates = 0, 0, 0
				ctx.keymap.start = function() starts = starts + 1; return true end
				ctx.save_prefs = function() saves = saves + 1; return true end
				ctx.updateMenu = function() updates = updates + 1 end
				local rows = hotstrings.build_groups(ctx, nil, { group_counts = {} })
				local sub = rows[1] and rows[1].submenu
				helpers.assert_true(type(sub) == "table", "the rendered category child must survive intact")
				helpers.assert_eq(sub[1].title, "menu.hotstrings.scope_enable_all")
				helpers.assert_eq(sub[2].title, "menu.hotstrings.scope_disable_all")
				helpers.assert_nil(sub[1].checked, "an explicit command is not a state switch")
				helpers.assert_nil(sub[2].checked, "both commands remain available in either posture")
				sub[enabled and 1 or 2].fn()
				helpers.assert_eq(#batches, 1, "one click is one category-owner transaction")
				helpers.assert_eq(batches[1], { names = { "alpha" }, enabled = enabled })
				helpers.assert_eq(ctx.state.hotstrings.alpha, enabled, "persist the selected category gate")
				helpers.assert_eq({ saves, updates, starts }, { 1, 1, 0 })
				helpers.assert_eq(ctx.state.keymap, false, "editing a category never starts the root engine")
			end)
		end

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

	helpers.it("a paused script can choose its next category without starting capture", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ctx, batches = context(true, true)
		ctx.paused = true
		ctx.state.keymap = false
		local starts = 0
		ctx.keymap.start = function() starts = starts + 1; return true end
		local sub = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu
		helpers.assert_eq(type(sub[2].fn), "function", "selection is separate from input capture")
		sub[2].fn()
		helpers.assert_eq(batches[1].enabled, false)
		helpers.assert_eq(starts, 0)
		helpers.assert_eq(ctx.paused, true)
		helpers.assert_eq(ctx.state.keymap, false)
	end)

	for _, enabled in ipairs({ true, false }) do
		for _, refusal in ipairs({ "false", "nil", "throw" }) do
			helpers.it("a refused category save " .. refusal .. " restores posture " .. tostring(enabled), function()
				local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
				local ctx, batches = context(not enabled, not enabled)
				ctx.state.hotstrings.alpha = not enabled
				ctx.state.hotstrings.beta = true
				ctx.state.keymap = false
				local saves, updates = 0, 0
				ctx.save_prefs = function()
					saves = saves + 1
					if refusal == "throw" then error("category save fixture refused") end
					if refusal == "false" then return false end
					return nil
				end
				ctx.updateMenu = function() updates = updates + 1 end
				local sub = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu
				sub[enabled and 1 or 2].fn()
				helpers.assert_eq(#batches, 1, "the category owner received one requested mutation")
				helpers.assert_eq(saves, 1)
				helpers.assert_eq(updates, 0, "a refused save is never acknowledged by rebuilding the tray")
				helpers.assert_eq(ctx.state.hotstrings, { alpha = not enabled, beta = true })
				helpers.assert_eq(ctx.state.keymap, false)
			end)
		end
	end

	helpers.it("a refused tray refresh cannot undo an acknowledged category save", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ctx, batches = context(false, false)
		ctx.state.hotstrings.alpha = false
		local saved_choice, refreshes
		ctx.save_prefs = function() saved_choice = ctx.state.hotstrings.alpha; return true end
		ctx.updateMenu = function() refreshes = (refreshes or 0) + 1; error("tray refresh fixture refused") end
		local sub = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu
		sub[1].fn()
		helpers.assert_eq(#batches, 1)
		helpers.assert_eq(saved_choice, true)
		helpers.assert_eq(refreshes, 1)
		helpers.assert_eq(ctx.state.hotstrings.alpha, true,
			"a UI failure cannot make the public choice disagree with the committed file and registry")
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
