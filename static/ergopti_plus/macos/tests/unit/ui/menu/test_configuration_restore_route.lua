--- tests/unit/ui/menu/test_configuration_restore_route.lua

--- ==============================================================================
--- MODULE: Configuration › Restore Recommended Values Route (macOS)
--- DESCRIPTION:
--- Boots the real ui.menu.start and proves the Configuration row restores the
--- recommended values through the global scope composition over every
--- category owner, never through the factory reset that moves the whole
--- configuration aside (which leaves the system behaviour, not the preset).
--- ==============================================================================

local helpers = require("tests.helpers")
local boot = require("tests.support.menu_boot_fixture").boot

helpers.describe("Configuration › Restore recommended values (macOS)", function()
	helpers.it("composes the category owners in recommended mode", function()
		local requested = {}
		local saved = package.loaded["ui.menu.global_scope"]
		local ok, err = pcall(function()
			local fixture = boot()
			local actions = fixture.global_actions()
			-- The owner is required on the first click, after the boot reloads.
			package.loaded["ui.menu.global_scope"] = { new = function(options)
				requested.options = options
				return { apply = function(mode) requested.mode = mode; return true end }
			end }
			helpers.assert_eq(actions.reset_defaults(), true)
			helpers.assert_eq(requested.mode, "recommended")
			local ids = {}
			for id, provider in pairs(requested.options.owners) do
				helpers.assert_type(provider, "function")
				ids[#ids + 1] = id
			end
			table.sort(ids)
			helpers.assert_eq(ids, { "gestures", "keyboard_layout", "llm", "metrics", "shortcuts" })
			for _, name in ipairs({ "backup_path", "confirm", "paused", "refresh" }) do
				helpers.assert_type(requested.options[name], "function")
			end
			helpers.assert_type(actions.factory_reset, "function",
				"the factory reset stays exported, bound to no row")
		end)
		package.loaded["ui.menu.global_scope"] = saved
		if not ok then error(err, 0) end
	end)
end)

return true
