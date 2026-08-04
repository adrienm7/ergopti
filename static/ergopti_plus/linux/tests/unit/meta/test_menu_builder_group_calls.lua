--- tests/unit/meta/test_menu_builder_group_calls.lua

--- ==============================================================================
--- MODULE: Menu Builder Group-Call Regression Guard
--- DESCRIPTION:
--- Regression test for a method-call mismatch in ui/menu/menu_builder.lua.
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

		local mb = helpers.load_module("ui.menu.menu_builder")
		local items = mb.build({ config = mock_config, _version = "9.9.9" })

		-- is_group_enabled must have been called with the first group name.
		helpers.assert_true(#enabled_args >= 1, "is_group_enabled should be called for each group")
		helpers.assert_eq(enabled_args[1], "code", "is_group_enabled must receive the group name, not the config table")

		-- Find the "code" category and invoke its gate toggle. A category is a
		-- SUBMENU now, not a single row: its first child is the enable/disable
		-- gate, and the rows under it are its sections. So the search descends to
		-- the category, then takes the first callable row inside it.
		local toggled = false
		local function search(list)
			for _, item in ipairs(list) do
				if type(item.title) == "string" and item.title:find("code", 1, true)
					and type(item.menu) == "table" then
					for _, row in ipairs(item.menu) do
						if type(row.fn) == "function" then
							row.fn()
							toggled = true
							return
						end
					end
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





-- ===================================================================
-- ===================================================================
-- ======= 2/ The same mistake, in the other consumer ================
-- ===================================================================
-- ===================================================================

helpers.describe("hotstrings config window: the bridge calls the same functions flat", function()

	helpers.it("passes the group name, not the config table", function()
		-- The identical defect, in the file the fix above did not reach. The
		-- config window's bridge called `state.config:is_group_enabled(g)`, so
		-- every category reported itself enabled and every toggle no-opped on the
		-- module's own string guard — a settings window whose switches did
		-- nothing. Its own test could not see it: the mock took a leading `self`,
		-- i.e. it was written to the buggy convention.
		local enabled_args, override_args = {}, {}
		local handler = helpers.load_module("ui.hotstrings_config_window.bridge")
		local state = {
			config = {
				get_groups        = function() return { "code", "email" } end,
				is_group_enabled  = function(gn) enabled_args[#enabled_args + 1] = gn; return true end,
				set_override      = function(cat, sec, field, value)
					override_args[#override_args + 1] = { cat = cat, sec = sec, field = field, value = value }
				end,
				reload            = function() return 0 end,
				mapping_count     = function() return 0 end,
				parse_error_count = function() return 0 end,
				get_config_dir    = function() return "/tmp" end,
			},
		}

		handler.on_message("ready", state)
		helpers.assert_true(#enabled_args >= 1, "the window asks whether each category is enabled")
		helpers.assert_eq(enabled_args[1], "code",
			"and it must ask about a category, not hand the module to itself")

		-- Re-pointed on 2026-08-05 from `toggle_group`, which the shared settings
		-- window has never sent — the category gate lives in the tray menu. The
		-- defect being guarded is the same one, on a path that actually runs: a
		-- colour change must name the category the user clicked, not pass the config
		-- module as the first argument.
		handler.on_message({ action = "set_color", category = "email", value = "#ff0000" }, state)
		helpers.assert_true(#override_args >= 1, "a colour change must reach the config module")
		helpers.assert_eq(override_args[1].cat, "email",
			"and it must name the category the user clicked, not hand the module to itself")
	end)

end)
