--- static/ergopti_plus/macos/tests/unit/ui/menu/test_log_level_emojis.lua
---
--- DESCRIPTION:
--- Verifies that log level menu items include their respective emojis.

local helpers = require("tests.helpers")

helpers.describe("Menu — log level emojis", function()
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n    = require("infra.i18n")
	local Logger  = require("infra.logger")

	helpers.it("includes correct emojis in log level selection labels", function()
		local old_level = Logger.current_level
		Logger.set_level("INFO")

		-- We need to mock the environment for build_debug_menu
		local actions = {
			set_log_level = function() end,
			open_logs = function() end,
			open_today_log = function() end,
			open_error_log = function() end,
			open_console = function() end,
			open_today_log = function() end,
			open_error_log = function() end,
			show_setup_wizard = function() end,
			open_paths = function() end,
			reload = function() end,
			quit = function() end,
		}
		
		-- Mock i18n.get to return keys for easier verification
		local i18n = require("infra.i18n")
		local old_get = i18n.get
		i18n.get = function(k) return k end
		-- Also need this for builder.lua line 488
		i18n.build_language_menu_items = function() return {} end
		
		-- Trigger menu building via M.generate
		local ctx = {
			config = { log_level = 2 }, -- INFO
		}
		local menu_mods = {}
		local menu = builder.generate(ctx, menu_mods, actions)
		
		-- Find the Debug menu first
		local debug_menu_item = nil
		for _, item in ipairs(menu) do
			if item.title == "menu.debug.title" then
				debug_menu_item = item
				break
			end
		end
		helpers.assert_true(debug_menu_item ~= nil, "debug menu item should exist")

		-- Find the Log level item within the Debug menu
		local log_level_item = nil
		-- In builder.lua, load_debug_menu falls back to DEBUG_MENU_FALLBACK
		-- which has "log_level" at index 3 (after console and ---)
		for _, item in ipairs(debug_menu_item.menu) do
			if item.title:find("menu.debug.log_level") then
				log_level_item = item
				break
			end
		end
		
		helpers.assert_true(log_level_item ~= nil, "log level submenu item should exist")
		
		-- Check the parent label (it should now have an emoji)
		local current_lvl_name = "INFO" -- Default in logger.lua mock or real
		local expected_parent_prefix = "menu.debug.log_level : "
		helpers.assert_true(log_level_item.title:find(expected_parent_prefix) ~= nil, "parent label should contain the key")
		helpers.assert_true(log_level_item.title:find("ℹ️") ~= nil, "parent label should contain the emoji for INFO")
		
		-- Check submenu items
		local sub_menu = log_level_item.menu
		local found = { DEBUG = false, INFO = false, WARNING = false, ERROR = false }
		local emojis = { DEBUG = "🐛", INFO = "ℹ️", WARNING = "⚠️", ERROR = "❌" }
		
		for _, item in ipairs(sub_menu) do
			for lvl, emoji in pairs(emojis) do
				if item.title:find(lvl) then
					helpers.assert_true(item.title:find(emoji) ~= nil, "item " .. lvl .. " should have emoji " .. emoji)
					found[lvl] = true
				end
			end
		end
		
		for lvl, ok in pairs(found) do
			helpers.assert_true(ok, "log level " .. lvl .. " item was not found in submenu")
		end
		
		i18n.get = old_get
		Logger.current_level = old_level
	end)
end)
