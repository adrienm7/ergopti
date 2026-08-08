--- tests/unit/ui/menu/test_hotstring_bulk_actions_execute.lua

--- ==============================================================================
--- MODULE: Regression -- whole-tree hotstring commands execute
--- DESCRIPTION:
--- The hotstring provider emits row data (`label` / `action`), while the
--- manifest renderer consumes registered commands (`title` / `fn`).  The bridge
--- between them read `.fn`, silently replaced the missing value with an empty
--- function, and therefore rendered two healthy-looking rows that never reached
--- the provider callback.
---
--- This test drives the complete provider -> builder -> manifest renderer path
--- and clicks both rendered rows.  Merely scanning for either field would be a
--- false green: both spellings can exist while the bridge still reads the wrong
--- one.
--- ==============================================================================

local helpers = require("tests.helpers")

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

helpers.describe("hotstring whole-tree commands: provider actions reach clicks", function()
	helpers.it("executes both provider actions through the rendered menu", function()
		local builder = helpers.load_with_stubs("ui.menu.builder")
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
				build_bulk_actions = function()
					return {
						{
							label = "menu.hotstrings.enable_all",
							action = function() fired[#fired + 1] = "enable" end,
						},
						{
							label = "menu.hotstrings.disable_all",
							action = function() fired[#fired + 1] = "disable" end,
						},
					}
				end,
			},
		}

		local ok, menu = pcall(builder.generate, ctx, menu_mods, make_actions())
		helpers.assert_true(ok, "building the user-visible menu must not raise")
		helpers.assert_eq(type(menu), "table", "builder.generate must return menu rows")

		local enable_row = find_row(menu, "menu.hotstrings.enable_all")
		local disable_row = find_row(menu, "menu.hotstrings.disable_all")
		helpers.assert_eq(type(enable_row and enable_row.fn), "function",
			"the rendered enable-all row must carry the provider action")
		helpers.assert_eq(type(disable_row and disable_row.fn), "function",
			"the rendered disable-all row must carry the provider action")

		enable_row.fn()
		disable_row.fn()
		helpers.assert_eq(table.concat(fired, ","), "enable,disable",
			"clicking both rendered commands must execute the provider callbacks; "
				.. "an empty fallback function is a silent user-visible no-op")
	end)

	helpers.it("the real provider updates every applicable section exactly once", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local enabled_sections = {}
		local disabled_sections = {}
		local enabled_groups = {}
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
				enable_section = function(group, section)
					enabled_sections[#enabled_sections + 1] = group .. "/" .. section
				end,
				disable_section = function(group, section)
					disabled_sections[#disabled_sections + 1] = group .. "/" .. section
				end,
				enable_group = function(group)
					enabled_groups[#enabled_groups + 1] = group
				end,
				start = function() starts = starts + 1 end,
			},
			save_prefs = function() saves = saves + 1 end,
			updateMenu = function() rebuilds = rebuilds + 1 end,
		}

		local rows = hotstrings.build_bulk_actions(ctx)
		helpers.assert_eq(type(rows[1] and rows[1].action), "function",
			"the enabled provider row must expose an action")
		helpers.assert_eq(type(rows[2] and rows[2].action), "function",
			"the disabled provider row must expose an action")

		rows[1].action()
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

		rows[2].action()
		helpers.assert_eq(table.concat(disabled_sections, ","),
			"alpha/one,alpha/two,beta/three",
			"disable-all must visit the same real-section set as enable-all")
		helpers.assert_eq(saves, 2, "each bulk click must add exactly one persistence write")
		helpers.assert_eq(rebuilds, 2, "each bulk click must add exactly one menu rebuild")
	end)
end)
