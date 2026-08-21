--- tests/unit/ui/menu/menu_llm/test_profiles_manager_profile_activation_owner.lua

-- =============================================================================
-- MODULE: Profiles Manager Explicit-Intent Ownership
-- DESCRIPTION:
-- Proves that clone, create, and active-profile deletion route their resulting
-- profile selection through the transactional model-switcher owner.
-- =============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.manifest_menu",
	"infra.notifications",
	"modules.llm",
	"ui.menu.menu_llm.profile_label",
	"ui.menu.menu_llm.profiles_manager",
	"ui.menu.shortcut_utils",
	"ui.prompt_editor",
}

local function find_row(rows, label)
	for _, row in ipairs(rows or {}) do
		if row.label == label then return row end
	end
	return nil
end

local function with_profiles_fixture(options, body)
	options = options or {}
	local saved_hs = _G.hs
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end

	local ok, err = xpcall(function()
		local runtime_profiles = {}
		package.loaded["infra.dialog_util"] = {
			block_alert = function() return "button.delete" end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
		}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
		}
		package.loaded["infra.notifications"] = {notify = function() return true end}
		package.loaded["modules.llm"] = {
			BUILTIN_PROFILES = {
				{id = "basic", label = "Basic"},
				{id = "advanced", label = "Advanced"},
			},
			set_active_profile = function(profile_id)
				runtime_profiles[#runtime_profiles + 1] = profile_id
				return true
			end,
		}
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {prompt_shortcut = function() end}
		package.loaded["ui.prompt_editor"] = {
			open = function(profile, callback)
				if profile == nil then
					callback({id = "user_created", label = "Created"})
				end
				return true
			end,
		}
		_G.hs = {
			timer = {
				doAfter = function(_, callback)
					callback()
					return {stop = function() return true end}
				end,
			},
		}

		local state = {
			llm_active_profile = options.active_profile or "basic",
			llm_num_predictions = 1,
			llm_profile_shortcuts = {},
			llm_user_profiles = options.user_profiles or {},
		}
		local selections = {}
		local direct_saves = 0
		local direct_menus = 0
		local shortcut_clears = 0
		local deps = {
			state = state,
			script_control = {is_paused = function() return false end},
			set_llm_profile = function(profile_id)
				selections[#selections + 1] = {
					id = profile_id,
					registry_size = #state.llm_user_profiles,
				}
				if options.selection_result == false then return false end
				state.llm_active_profile = profile_id
				return true
			end,
			apply_llm_profile_shortcut = function()
				shortcut_clears = shortcut_clears + 1
				return true
			end,
			save_prefs = function()
				direct_saves = direct_saves + 1
				return true
			end,
			update_menu = function()
				direct_menus = direct_menus + 1
				return true
			end,
		}

		package.loaded["ui.menu.menu_llm.profiles_manager"] = nil
		local manager = require("ui.menu.menu_llm.profiles_manager").new(deps, {
			get_model_info = function() return {} end,
		})
		body({
			manager = manager,
			state = state,
			selections = selections,
			direct_saves = function() return direct_saves end,
			direct_menus = function() return direct_menus end,
			shortcut_clears = function() return shortcut_clears end,
		})
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("HS-029 profiles manager activation ownership", function()
	helpers.it("HS-029 routes cloned-profile activation through the intent owner", function()
		with_profiles_fixture({}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local clone = find_row(rows, "menu.profiles.clone_builtin")
			helpers.assert_type(clone.action, "function")
			clone.action()
			helpers.assert_eq(#fixture.selections, 1)
			helpers.assert_true(fixture.selections[1].id:match("^user_basic_") ~= nil)
			helpers.assert_eq(fixture.selections[1].registry_size, 1,
				"the new profile must be resolvable before activation")
			helpers.assert_eq(fixture.direct_saves(), 0)
			helpers.assert_eq(fixture.direct_menus(), 0)
		end)
	end)

	helpers.it("HS-029 routes created-profile activation through the intent owner", function()
		with_profiles_fixture({}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local create = find_row(rows, "menu.profiles.create_profile")
			helpers.assert_type(create.action, "function")
			create.action()
			helpers.assert_eq(fixture.selections, {{id = "user_created", registry_size = 1}})
			helpers.assert_eq(fixture.state.llm_active_profile, "user_created")
			helpers.assert_eq(fixture.direct_saves(), 0)
			helpers.assert_eq(fixture.direct_menus(), 0)
		end)
	end)

	helpers.it("HS-029 commits basic before removing the active custom profile", function()
		with_profiles_fixture({
			active_profile = "user_custom",
			user_profiles = {{id = "user_custom", label = "Custom"}},
		}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local custom = find_row(rows, "Custom")
			local delete = find_row(custom.items, "menu.profiles.delete_profile")
			helpers.assert_type(delete.action, "function")
			delete.action()
			helpers.assert_eq(fixture.selections, {{id = "basic", registry_size = 1}},
				"the fallback intent must commit while the old profile is still resolvable")
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(fixture.shortcut_clears(), 1)
			helpers.assert_eq(fixture.direct_saves(), 1,
				"registry deletion remains a separate persistence boundary")
			helpers.assert_eq(fixture.direct_menus(), 1)
		end)
	end)

	helpers.it("HS-029 preserves an active profile when fallback intent is refused", function()
		local profile = {id = "user_custom", label = "Custom"}
		with_profiles_fixture({
			active_profile = "user_custom",
			selection_result = false,
			user_profiles = {profile},
		}, function(fixture)
			local custom = find_row(fixture.manager.get_menu_item().menu, "Custom")
			local delete = find_row(custom.items, "menu.profiles.delete_profile")
			helpers.assert_type(delete.action, "function")
			helpers.assert_eq(delete.action(), false)
			helpers.assert_eq(fixture.selections, {{id = "basic", registry_size = 1}})
			helpers.assert_eq(fixture.state.llm_active_profile, "user_custom")
			helpers.assert_eq(fixture.state.llm_user_profiles, {profile})
			helpers.assert_eq(fixture.shortcut_clears(), 0)
			helpers.assert_eq(fixture.direct_saves(), 0)
			helpers.assert_eq(fixture.direct_menus(), 0)
		end)
	end)
end)

return true
