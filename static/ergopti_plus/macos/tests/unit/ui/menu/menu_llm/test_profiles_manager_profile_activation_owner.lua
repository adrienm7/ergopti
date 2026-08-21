--- tests/unit/ui/menu/menu_llm/test_profiles_manager_profile_activation_owner.lua

-- =============================================================================
-- MODULE: Profiles Manager Explicit-Intent Ownership
-- DESCRIPTION:
-- Proves that clone, create, and active-profile deletion route their resulting
-- profile selection through the transactional model-switcher owner, and that
-- Auto-detect propagates the same owner's exact terminal result.
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
	"ui.menu.menu_llm.model_switcher",
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
		local runtime_profile = options.active_profile or "basic"
		local notification_count = 0
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
		package.loaded["infra.notifications"] = {notify = function()
			notification_count = notification_count + 1
			return true
		end}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {llm_num_predictions = 1},
			BUILTIN_PROFILES = {
				{id = "basic", label = "Basic"},
				{id = "advanced", label = "Advanced"},
			},
			set_active_profile = function(profile_id)
				runtime_profiles[#runtime_profiles + 1] = profile_id
				runtime_profile = profile_id
				return true
			end,
			set_user_profiles = function() return true end,
			get_active_profile = function() return {id = runtime_profile} end,
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
			llm_backend = "ollama",
			llm_enabled = true,
			llm_active_profile = options.active_profile or "basic",
			llm_model = options.model ~= nil and options.model or "A",
			llm_model_power = 1,
			llm_model_ollama = options.model ~= nil and options.model or "A",
			llm_num_predictions = 1,
			llm_profile_shortcuts = {},
			llm_user_profiles = options.user_profiles or {},
		}
		local selections = {}
		local direct_saves = 0
		local direct_menus = 0
		local shortcut_clears = 0
		local recommendations = {}
		local deps = {
			state = state,
			script_control = {is_paused = function() return false end},
			set_llm_profile = function(profile_id, opts)
				selections[#selections + 1] = {
					id = profile_id,
					registry_size = #state.llm_user_profiles,
				}
				if options.selection_result == false then return false end
				state.llm_active_profile = profile_id
				if type(opts) == "table" and opts.defer_intent == true then
					local pending = true
					return true, {
						commit = function()
							if not pending then return false end
							pending = false
							return true
						end,
						cancel = function()
							if not pending then return false end
							pending = false
							return true
						end,
					}
				end
				return true
			end,
			apply_llm_profile_shortcut = function(_, _, _, opts)
				if type(opts) == "table" and opts.defer == true then
					return {
						publish = function() return true end,
						commit = function()
							shortcut_clears = shortcut_clears + 1
							return true
						end,
						restore = function() return true end,
						finish_rollback = function() return true end,
					}
				end
				return true
			end,
			apply_recommended_prompt_profile = function(opts)
				recommendations[#recommendations + 1] = opts
				return options.recommendation_result
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
		local models_mgr = {
			get_presets = function() return {} end,
			get_model_info = function() return {} end,
			get_actual_model_name = function(name) return name end,
			check_requirements = function() return false end,
		}
		if options.real_recommendation then
			package.loaded["ui.menu.menu_llm.model_switcher"] = nil
			local switcher = require("ui.menu.menu_llm.model_switcher").new({
				state = state,
				models_mgr = models_mgr,
				keymap = {},
				save_prefs = deps.save_prefs,
				update_menu = deps.update_menu,
			})
			deps.apply_recommended_prompt_profile = function(opts)
				return switcher.apply_recommended_prompt_profile(state.llm_model, opts)
			end
		end

		package.loaded["ui.menu.menu_llm.profiles_manager"] = nil
		local manager = require("ui.menu.menu_llm.profiles_manager").new(deps, models_mgr)
		body({
			manager = manager,
			state = state,
			selections = selections,
			direct_saves = function() return direct_saves end,
			direct_menus = function() return direct_menus end,
			shortcut_clears = function() return shortcut_clears end,
			recommendations = recommendations,
			notifications = function() return notification_count end,
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

	helpers.it("HS-031 propagates an Auto-detect refusal from the transaction owner", function()
		with_profiles_fixture({recommendation_result = false}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local auto_detect = find_row(rows, "menu.profiles.auto_detect")
			helpers.assert_type(auto_detect.action, "function")
			helpers.assert_eq(auto_detect.action(), false)
			helpers.assert_eq(#fixture.recommendations, 1)
			helpers.assert_eq(fixture.recommendations[1].force_dialog, true)
			helpers.assert_eq(fixture.recommendations[1].dialog_title,
				"menu.profiles.recommended_profile")
		end)
	end)

	helpers.it("HS-031 propagates a built-in profile refusal from the transaction owner", function()
		with_profiles_fixture({selection_result = false}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local basic = find_row(rows, "Basic")
			helpers.assert_type(basic.action, "function")
			helpers.assert_eq(basic.action(), false)
			helpers.assert_eq(fixture.selections, {{id = "basic", registry_size = 0}})
		end)
	end)

	helpers.it("HS-031 propagates a cloned-profile activation refusal", function()
		with_profiles_fixture({selection_result = false}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local clone = find_row(rows, "menu.profiles.clone_builtin")
			helpers.assert_type(clone.action, "function")
			helpers.assert_eq(clone.action(), false)
			helpers.assert_eq(#fixture.selections, 1)
			helpers.assert_eq(fixture.selections[1].registry_size, 1)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
		end)
	end)

	helpers.it("HS-031 makes No Model Auto-detect visibly fail through the real owners", function()
		with_profiles_fixture({model = "", real_recommendation = true}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local auto_detect = find_row(rows, "menu.profiles.auto_detect")
			helpers.assert_type(auto_detect.action, "function")
			helpers.assert_eq(auto_detect.action(), false)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(fixture.notifications(), 1)
			helpers.assert_eq(fixture.direct_saves(), 0)
			helpers.assert_eq(fixture.direct_menus(), 0)
		end)
	end)
end)

return true
