--- static/ergopti_plus/macos/tests/unit/ui/menu/test_log_level_emojis.lua
---
--- DESCRIPTION:
--- Verifies that log level menu items include their respective emojis.

local helpers = require("tests.unit.helpers")

helpers.describe("Menu — log level emojis", function()
	local builder = helpers.load_with_stubs("ui.menu.builder")
	local i18n    = require("lib.i18n")
	local Logger  = require("lib.logger")

	helpers.it("includes correct emojis in log level selection labels", function()
		-- We need to mock the environment for build_debug_menu
		local actions = {
			set_log_level = function() end,
			open_logs = function() end,
			open_today_log = function() end,
			open_error_log = function() end
		}
		
		-- Mock i18n.get to return keys for easier verification
		local old_get = i18n.get
		i18n.get = function(k) return k end
		
		-- Trigger menu building (this typically builds the log_level_items table)
		-- Since builder.lua defines log_level_emoji as a local inside a function,
		-- we verify the output labels of build_debug_menu.
		local menu = builder.build_debug_menu(actions)
		
		local log_level_item = nil
		for _, item in ipairs(menu) do
			if item.menu then -- The log level item has a sub-menu
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
	end)
end)
