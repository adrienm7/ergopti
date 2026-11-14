--- tests/unit/ui/menu/menu_llm/profiles/test_profiles_manager_edit_delete_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — custom profile rows while paused (EDD-1)
--- DESCRIPTION:
--- A pause stops typing, not configuration (EDD-1, maintainer 2026-11-12):
--- a custom profile's Use, Edit and Delete rows stay live while paused, and
--- only "Set shortcut" waits for resume because it binds a hotkey. F-MED-12
--- had greyed Edit and Delete under the pause to match their siblings; the
--- siblings now follow EDD-1 instead.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a minimal fake deps table satisfying profiles_manager.lua's I/O contract,
--- with one custom (user) profile already present so the Edit/Delete submenu exists.
--- @param paused boolean Whether the script is currently paused.
--- @return table deps
local function make_deps(paused)
	return {
		state = {
			llm_active_profile  = "basic",
			llm_num_predictions = 1,
			llm_user_profiles   = {
				{ id = "user_custom_1", label = "My Custom Profile", system_single = "hello" },
			},
		},
		script_control = {
			is_paused = function() return paused end,
		},
		save_prefs   = function() end,
		update_menu  = function() end,
	}
end

--- Finds the menu item whose title equals `title` in a flat item list.
--- @param items table Array of hs.menubar item tables.
--- @param title string Exact title to match.
--- @return table|nil
local function find_by_title(items, title)
	for _, item in ipairs(items) do
		if item.title == title then return item end
	end
	return nil
end

--- Several other test files in this suite install partial modules.llm.* stubs
--- (e.g. missing set_active_profile / get_stop_sequences) via package.loaded
--- and never restore them. load_with_stubs does not clear "modules.llm.*"
--- (only the module under test and a short allow-list), so
--- profiles_manager.lua's `require("modules.llm")` — which transitively
--- requires modules.llm.api_common / api_ollama / api_mlx — would otherwise
--- silently inherit whatever stale stub a previous test left behind. Drop
--- every cached modules.llm* entry so the whole require chain reloads fresh.
local function ensure_real_llm_module()
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^modules%.llm") then
			package.loaded[name] = nil
		end
	end
end

helpers.describe("profiles_manager: custom profile rows while paused (EDD-1)", function()
	helpers.it("Edit and Delete stay live while paused, the shortcut row waits", function()
		ensure_real_llm_module()
		local ProfilesManager = helpers.load_with_stubs("ui.menu.menu_llm.profiles_manager")
		local i18n = require("infra.i18n")
		local deps = make_deps(true)
		local mgr = ProfilesManager.new(deps, nil)
		local root_item = mgr.get_menu_item()
		local custom_row = find_by_title(root_item.menu, "My Custom Profile")
		helpers.assert_true(custom_row ~= nil and type(custom_row.menu) == "table",
			"the custom profile row and its submenu must be present")
		local edit_row   = find_by_title(custom_row.menu, i18n.get("menu.profiles.edit_profile"))
		local delete_row = find_by_title(custom_row.menu, i18n.get("menu.profiles.delete_profile"))
		local shortcut_row = find_by_title(custom_row.menu, i18n.get("menu.profiles.shortcut_prefix"))
		helpers.assert_true(edit_row.disabled ~= true and type(edit_row.fn) == "function", "Edit stays live while paused")
		helpers.assert_true(delete_row.disabled ~= true and type(delete_row.fn) == "function", "Delete stays live while paused")
		helpers.assert_eq(shortcut_row.disabled, true, "a shortcut binds a hotkey: it waits for resume")
		helpers.assert_nil(shortcut_row.fn)
	end)

	helpers.it("Edit and Delete rows are enabled when not paused (positive control)", function()
		ensure_real_llm_module()
		local ProfilesManager = helpers.load_with_stubs("ui.menu.menu_llm.profiles_manager")
		local i18n = require("infra.i18n")

		local deps = make_deps(false)
		local mgr = ProfilesManager.new(deps, nil)
		local root_item = mgr.get_menu_item()

		local custom_row = find_by_title(root_item.menu, "My Custom Profile")
		helpers.assert_true(custom_row ~= nil, "the custom profile row must be present")

		local edit_row   = find_by_title(custom_row.menu, i18n.get("menu.profiles.edit_profile"))
		local delete_row = find_by_title(custom_row.menu, i18n.get("menu.profiles.delete_profile"))

		helpers.assert_true(edit_row.disabled ~= true, "the Edit row must not be disabled when not paused")
		helpers.assert_true(delete_row.disabled ~= true, "the Delete row must not be disabled when not paused")
		helpers.assert_true(type(edit_row.fn) == "function", "the Edit row's fn must be callable when not paused")
		helpers.assert_true(type(delete_row.fn) == "function", "the Delete row's fn must be callable when not paused")
	end)
end)
