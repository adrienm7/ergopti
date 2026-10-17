--- tests/unit/ui/menu/test_hotstring_bulk_actions_execute.lua

--- ==============================================================================
--- MODULE: Regression -- hotstring bulk commands execute
--- DESCRIPTION:
--- The Hotstrings menu drew a whole-tree « all sections » checkbox that switched
--- on the packs of every language at once; it is gone on every driver since
--- 2026-10-17 (hotstrings-menu-no-whole-tree). The first test renders the real
--- menu and proves no such row is drawn even when a provider still offers one.
--- The bulk writer that remains, a language's « all sections » checkbox, must
--- visit every real section once and publish nothing when the keymap refuses
--- to start.
--- ==============================================================================

local helpers = require("tests.helpers")
local CaptionFixture = require("tests.support.hotstrings_parent_caption_fixture")

local function make_actions()
	return {
		set_log_level     = function() end,
		open_logs         = function() end,
		open_today_log    = function() end,
		open_error_log    = function() end,
		open_console      = function() end,
		show_setup_wizard = function() end,
		open_paths        = function() end,
		reload            = function() end,
		quit              = function() end,
		enable_all        = function() end,
		disable_all       = function() end,
		reset_defaults    = function() end,
	}
end

--- Finds a rendered hs.menubar row recursively.
--- @param rows table
--- @param title string
--- @return table|nil
local function find_row(rows, title)
	for _, row in ipairs(rows or {}) do
		if row.title == title then return row end
		local nested = type(row.menu) == "table" and find_row(row.menu, title) or nil
		if nested then return nested end
	end
	return nil
end

--- The language « all sections » checkbox of `groups`, as the tray draws it.
--- @param hotstrings table The real provider module.
--- @param ctx table Menu context.
--- @param groups table Array of group names.
--- @return table { checked = boolean, action = function|nil }
local function language_switch(hotstrings, ctx, groups)
	local row = hotstrings.build_language_bulk_actions(ctx, groups)[1]
	return { checked = row.checked, action = row.action }
end

helpers.describe("hotstring bulk commands: no whole-tree row, language actions reach clicks", function()
	helpers.it("the rendered Hotstrings menu draws no whole-tree « all sections » row", CaptionFixture.scoped(function()
		local translator = helpers.load_with_stubs("infra.i18n")
		CaptionFixture.install(translator)
		package.loaded["ui.menu.builder"] = nil
		local builder = require("ui.menu.builder")
		local fired = {}
		local ctx = {
			config       = { log_level = 2 },
			paused       = false,
			hotfiles     = {},
			state        = { hotstrings = {} },
			save_prefs   = function() end,
			updateMenu   = function() end,
		}
		local menu_mods = {
			hotstrings = {
				all_sections_switch = function()
					return {
						checked = true,
						action = function() fired[#fired + 1] = "switch" end,
					}
				end,
			},
		}

		local ok, menu = pcall(builder.generate, ctx, menu_mods, make_actions())
		helpers.assert_true(ok, "building the user-visible menu must not raise")
		helpers.assert_eq(type(menu), "table", "builder.generate must return menu rows")

		helpers.assert_nil(find_row(menu, "menu.hotstrings.enable_all_sections"),
			"the Hotstrings menu must not draw a row that switches every language at once")
		helpers.assert_nil(find_row(menu, "menu.hotstrings.enable_all"), "the retired enable-all row is gone")
		helpers.assert_nil(find_row(menu, "menu.hotstrings.disable_all"), "the retired disable-all row is gone")
		helpers.assert_eq(#fired, 0, "nothing reached a whole-tree writer")
	end))

	helpers.it("the language checkbox updates every applicable section exactly once", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local enabled_sections = {}
		local disabled_sections = {}
		local enabled_groups = {}
		local section_on = {}
		local starts, saves, rebuilds = 0, 0, 0
		local sections = {
			alpha = {
				{ name = "one" },
				{ name = "-" },
				{ name = "module", is_module_placeholder = true },
				{ name = "two" },
			},
			beta = { { name = "three" } },
		}
		local ctx = {
			paused = false,
			hotfiles = { "alpha.toml", "beta.toml" },
			get_group_name = function(path) return path:gsub("%.toml$", "") end,
			state = { hotstrings = {}, keymap = false },
			keymap = {
				get_sections = function(group) return sections[group] end,
				is_section_enabled = function(group, section) return section_on[group .. "/" .. section] == true end,
				set_groups_sections_enabled = function(changes, enabled)
					for _, change in ipairs(changes) do
						for _, section in ipairs(change.sections) do
							local target = enabled and enabled_sections or disabled_sections
							target[#target + 1] = change.name .. "/" .. section
							section_on[change.name .. "/" .. section] = enabled
						end
						if change.enable_group then
							enabled_groups[#enabled_groups + 1] = change.name
						end
					end
					return true
				end,
				start = function() starts = starts + 1; return true end,
			},
			save_prefs = function() saves = saves + 1; return true end,
			updateMenu = function() rebuilds = rebuilds + 1 end,
		}

		-- Every section is off, so the switch is unticked and its click enables.
		local switch = language_switch(hotstrings, ctx, { "alpha", "beta" })
		helpers.assert_eq(switch.checked, false, "nothing is on yet")
		helpers.assert_eq(type(switch.action), "function", "the switch must expose an action")

		switch.action()
		helpers.assert_eq(table.concat(enabled_sections, ","),
			"alpha/one,alpha/two,beta/three",
			"enable-all must visit every real section and skip separators/placeholders")
		helpers.assert_eq(table.concat(enabled_groups, ","), "alpha,beta",
			"enable-all must lift every group gate")
		helpers.assert_true(ctx.state.hotstrings.alpha and ctx.state.hotstrings.beta,
			"the persisted group state must agree with the engine")
		helpers.assert_eq(starts, 1,
			"enabling from a stopped keymap starts the engine once, after the section walk")
		helpers.assert_eq(saves, 1, "one bulk click must persist exactly once")
		helpers.assert_eq(rebuilds, 1, "one bulk click must rebuild the menu exactly once")

		-- Rebuilt, as the menu is after every click: now ticked, so it disables.
		switch = language_switch(hotstrings, ctx, { "alpha", "beta" })
		helpers.assert_eq(switch.checked, true, "every group and section is on after the enabling click")
		switch.action()
		helpers.assert_eq(table.concat(disabled_sections, ","),
			"alpha/one,alpha/two,beta/three",
			"disable-all must visit the same real-section set as enable-all")
		helpers.assert_eq(saves, 2, "each bulk click must add exactly one persistence write")
		helpers.assert_eq(rebuilds, 2, "each bulk click must add exactly one menu rebuild")
	end)

	helpers.it("publishes no hotstring mutation when keymap start is refused", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local starts, mutations, saves, rebuilds = 0, 0, 0, 0
		local state = { hotstrings = {}, keymap = false }
		local ctx = {
			paused = false,
			hotfiles = { "alpha.toml" },
			get_group_name = function() return "alpha" end,
			state = state,
			keymap = {
				start = function() starts = starts + 1; return false end,
				get_sections = function() mutations = mutations + 1; return { { name = "one" } } end,
				enable_section = function() mutations = mutations + 1 end,
				enable_group = function() mutations = mutations + 1 end,
			},
			save_prefs = function() saves = saves + 1; return true end,
			updateMenu = function() rebuilds = rebuilds + 1 end,
		}

		-- Building the switch reads the sections for its tick; only what the click
		-- does afterwards is under test.
		local switch = language_switch(hotstrings, ctx, { "alpha" })
		helpers.assert_eq(switch.checked, false, "nothing is on, so the click enables")
		mutations = 0
		switch.action()
		helpers.assert_eq(starts, 1, "the user action must attempt exactly one strict start")
		helpers.assert_eq(mutations, 0,
			"sections and groups must remain untouched when no typing tap owns them")
		helpers.assert_eq(state.keymap, false, "the menu must not publish a false enabled state")
		helpers.assert_eq(next(state.hotstrings), nil, "no group state may be published")
		helpers.assert_eq(saves, 0, "a refused action must not persist a lie")
		helpers.assert_eq(rebuilds, 0, "a refused action must not render an enabled checkmark")
	end)
end)
