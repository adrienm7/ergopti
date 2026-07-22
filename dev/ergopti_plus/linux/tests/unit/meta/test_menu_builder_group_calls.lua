--- tests/unit/meta/test_menu_builder_group_calls.lua

--- ==============================================================================
--- MODULE: Menu Builder Group-Call Regression Guard
--- DESCRIPTION:
--- Regression test for a method-call mismatch in modules/menu/menu_builder.lua.
---
--- ROOT CAUSE ENCODED:
--- The builder called config:is_group_enabled(group_name) / config:toggle_group(...)
--- with `:` (implicit self), but hotstrings_config defines them flat —
--- M.is_group_enabled(group_name) with no self param. So `:` passed the config
--- table itself as group_name and the real group name landed in an ignored
--- second argument: every group's enabled state was misread and toggling acted on
--- the wrong (table) key. Fixed by calling with `.`.
---
--- This test drives the public build() with a config whose group functions record
--- their first argument and asserts it is the group NAME string, never the config
--- table.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===================================================================
-- ===================================================================
-- ======= 1/ Behavioural: group funcs get the name, not self ========
-- ===================================================================
-- ===================================================================

helpers.describe("menu_builder: group toggles call hotstrings_config with the group name", function()
	helpers.it("is_group_enabled and toggle_group receive the group name string, not the config table", function()
		local enabled_args = {}
		local toggle_args = {}
		local mock_config = {
			get_groups = function() return { "code", "email" } end,
			is_group_enabled = function(gn) enabled_args[#enabled_args + 1] = gn; return true end,
			toggle_group = function(gn) toggle_args[#toggle_args + 1] = gn end,
			reload = function() end,
		}

		local mb = helpers.load_module("modules.menu.menu_builder")
		local items = mb.build({ config = mock_config, _version = "9.9.9" })

		-- is_group_enabled must have been called with the first group name.
		helpers.assert_true(#enabled_args >= 1, "is_group_enabled should be called for each group")
		helpers.assert_eq(enabled_args[1], "code", "is_group_enabled must receive the group name, not the config table")

		-- Find the "code" group item and invoke its toggle callback.
		-- Group items are now nested inside the Hotstrings submenu's
		-- `menu` array (hierarchical SNI menus). Search recursively.
		local toggled = false
		local function search(list)
			for _, item in ipairs(list) do
				if type(item.title) == "string" and item.title:find("code", 1, true) and type(item.fn) == "function" then
					item.fn()
					toggled = true
					return
				end
				if type(item.menu) == "table" then
					search(item.menu)
					if toggled then return end
				end
			end
		end
		search(items)
		helpers.assert_true(toggled, "the 'code' group item should be present with a toggle callback")
		helpers.assert_eq(toggle_args[1], "code", "toggle_group must receive the group name, not the config table")
	end)
end)
