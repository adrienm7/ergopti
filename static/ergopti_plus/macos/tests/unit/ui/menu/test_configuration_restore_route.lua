--- tests/unit/ui/menu/test_configuration_restore_route.lua

--- ==============================================================================
--- MODULE: Configuration › Restore And Clear Route (macOS)
--- DESCRIPTION:
--- Boots the real ui.menu.start and proves the Configuration rows restore the
--- recommended values, or clear every category, through the global scope
--- composition over every category owner, never through the factory reset
--- that moves the whole configuration aside.
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
			-- Hotstrings take part like every config.toml category: a skipped one
			-- left its choices, delays and engine switch outside the restore.
			helpers.assert_eq(ids, { "gestures", "global", "hotstrings", "keyboard_layout", "llm", "metrics", "shortcuts" })
			for _, name in ipairs({ "backup_path", "paused", "refresh" }) do
				helpers.assert_type(requested.options[name], "function")
			end
			helpers.assert_nil(requested.options.confirm, "neither Configuration row asks")
			local previous_script = package.loaded["infra.script_scope"]
			local native_options, constructed = nil, 0
			local native_owner = {}
			package.loaded["infra.script_scope"] = { new = function(options)
				native_options, constructed = options, constructed + 1
				return native_owner
			end }
			local checked, failure = pcall(function()
				helpers.assert_eq(requested.options.owners.global(), native_owner)
				helpers.assert_eq(requested.options.owners.global(), native_owner)
				helpers.assert_eq(constructed, 1, "the factory retains the exact native cohort")
				helpers.assert_type(native_options.path, "string")
				helpers.assert_true(native_options.path ~= "")
				for _, name in ipairs({ "backup_path", "storage_backup_path", "paused", "capture_preferences", "admission" }) do
					helpers.assert_type(native_options[name], "function")
				end
				for _, name in ipairs({ "capture", "replace", "restore" }) do
					helpers.assert_type(native_options.checkpoint[name], "function")
				end
				local first = native_options.backup_path()
				helpers.assert_eq(native_options.storage_backup_path(), first .. ".settings")
				local second = native_options.backup_path()
				helpers.assert_true(first ~= second)
				helpers.assert_eq(native_options.storage_backup_path(), second .. ".settings")
			end)
			package.loaded["infra.script_scope"] = previous_script
			if not checked then error(failure) end
			-- « Tout effacer », beside it since 2026-09-30: the same composition,
			-- in clear mode, one transaction whose owners each back up first.
			helpers.assert_eq(actions.clear_to_system(), true)
			helpers.assert_eq(requested.mode, "clear")
			helpers.assert_type(actions.factory_reset, "function",
				"the factory reset stays exported, bound to no row")
		end)
		package.loaded["ui.menu.global_scope"] = saved
		if not ok then error(err, 0) end
	end)
end)

return true
