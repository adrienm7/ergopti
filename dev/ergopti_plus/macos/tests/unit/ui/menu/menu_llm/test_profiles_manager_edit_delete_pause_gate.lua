--- tests/unit/ui/menu/menu_llm/test_profiles_manager_edit_delete_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — custom profile Edit/Delete rows stay clickable while paused (F-MED-12)
--- DESCRIPTION:
--- The custom (user-created) profile submenu has four rows: "Use this profile",
--- "Set shortcut", "Edit…" and "Delete…". The first two correctly gate on the
--- pause flag (disabled = paused or nil, fn = not paused and ... or nil) — but
--- Edit and Delete, added later, carried neither the `disabled` field nor the
--- `not paused` guard on `fn`, so both stayed clickable while the script was
--- paused, unlike every sibling row in the same submenu.
---
--- Fix: gate Edit and Delete the same way the sibling rows already do.
---
--- This test builds the menu with paused=true via ProfilesManager.new(deps,
--- models_mgr).get_menu_item() and asserts the custom profile's Edit and Delete
--- rows are disabled=true — it fails before the fix (disabled is nil) and
--- passes after.
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

helpers.describe("profiles_manager: custom profile Edit/Delete rows are pause-gated (F-MED-12)", function()
	helpers.it("Edit and Delete rows are disabled=true when paused", function()
		ensure_real_llm_module()
		local ProfilesManager = helpers.load_with_stubs("ui.menu.menu_llm.profiles_manager")
		local i18n = require("infra.i18n")
		-- The real i18n stub from load_with_stubs returns the key verbatim, so
		-- we can match on the canonical key strings below.

		local deps = make_deps(true)
		local mgr = ProfilesManager.new(deps, nil)
		local root_item = mgr.get_menu_item()
		helpers.assert_true(type(root_item) == "table" and type(root_item.menu) == "table",
			"get_menu_item() must return a table with a .menu submenu")

		local custom_row = find_by_title(root_item.menu, "My Custom Profile")
		helpers.assert_true(custom_row ~= nil, "the custom profile row must be present")
		helpers.assert_true(type(custom_row.menu) == "table", "the custom profile row must have its own submenu")

		local edit_row   = find_by_title(custom_row.menu, i18n.get("menu.profiles.edit_profile"))
		local delete_row = find_by_title(custom_row.menu, i18n.get("menu.profiles.delete_profile"))
		helpers.assert_true(edit_row ~= nil, "the Edit row must be present in the custom profile submenu")
		helpers.assert_true(delete_row ~= nil, "the Delete row must be present in the custom profile submenu")

		helpers.assert_eq(edit_row.disabled, true,
			"the Edit row must be disabled=true when paused, matching its sibling rows (F-MED-12)")
		helpers.assert_eq(delete_row.disabled, true,
			"the Delete row must be disabled=true when paused, matching its sibling rows (F-MED-12)")
		helpers.assert_nil(edit_row.fn, "the Edit row's fn must be nil (not just disabled) while paused")
		helpers.assert_nil(delete_row.fn, "the Delete row's fn must be nil (not just disabled) while paused")
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
