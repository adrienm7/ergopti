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
		local runtime_registry = {}
		local registry_calls = 0
		local active_calls = 0
		local runtime_profile = options.active_profile or "basic"
		local notification_count = 0
		local error_count = 0
		local editor_calls = 0
		package.loaded["infra.dialog_util"] = {
			block_alert = function() return "button.delete" end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			section = function(key) return key end,
		}
		local logger = helpers.make_logger_stub()
		logger.error = function() error_count = error_count + 1 end
		package.loaded["infra.logger"] = logger
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
				active_calls = active_calls + 1
				runtime_profiles[#runtime_profiles + 1] = profile_id
				runtime_profile = profile_id
				local refuse = options.active_setter_mode ~= nil
					and active_calls == (options.active_setter_occurrence or 1)
				if refuse and options.active_setter_mode == "throw" then
					error("injected active-profile refusal")
				end
				if refuse and options.active_setter_mode == "nil" then return nil end
				if refuse and options.active_setter_mode == "false" then return false end
				return true
			end,
			set_user_profiles = function(profiles)
				registry_calls = registry_calls + 1
				runtime_registry = profiles
				local refuse = options.registry_setter_mode ~= nil
					and registry_calls == (options.registry_setter_occurrence or 1)
				if refuse and options.registry_setter_mode == "throw" then
					error("injected user-profile refusal")
				end
				if refuse and options.registry_setter_mode == "nil" then return nil end
				if refuse and options.registry_setter_mode == "false" then return false end
				return true
			end,
			get_active_profile = function() return {id = runtime_profile} end,
		}
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["ui.menu.shortcut_utils"] = {prompt_shortcut = function() end}
		package.loaded["ui.prompt_editor"] = {
			open = function(profile, callback)
				editor_calls = editor_calls + 1
				if profile == nil then
					callback({id = "user_created", label = "Created"})
				elseif options.edit_update_label ~= nil then
					callback({id = profile.id, label = options.edit_update_label})
				elseif type(options.edit_update) == "table" then
					callback(options.edit_update)
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
		local manager
		local save_hook_fired = false
		local function strict_result(mode, label)
			if mode == "throw" then error("injected " .. label .. " refusal") end
			if mode == "nil" then return nil end
			if mode == "false" then return false end
			return true
		end
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
				if not save_hook_fired and type(options.save_hook) == "function" then
					save_hook_fired = true
					options.save_hook(manager)
				end
				if options.save_mode ~= nil
					and direct_saves == (options.save_occurrence or 1) then
					return strict_result(options.save_mode, "profile save")
				end
				return true
			end,
			update_menu = function()
				direct_menus = direct_menus + 1
				if options.menu_mode ~= nil
					and direct_menus == (options.menu_occurrence or 1) then
					return strict_result(options.menu_mode, "profile menu")
				end
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
		manager = require("ui.menu.menu_llm.profiles_manager").new(deps, models_mgr)
		body({
			manager = manager,
			state = state,
			selections = selections,
			direct_saves = function() return direct_saves end,
			direct_menus = function() return direct_menus end,
			shortcut_clears = function() return shortcut_clears end,
			recommendations = recommendations,
			notifications = function() return notification_count end,
			runtime_profiles = runtime_profiles,
			runtime_registry = function() return runtime_registry end,
			registry_calls = function() return registry_calls end,
			active_calls = function() return active_calls end,
			errors = function() return error_count end,
			editor_calls = function() return editor_calls end,
		})
	end, debug.traceback)

	_G.hs = saved_hs
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("HS-029 profiles manager activation ownership", function()
	for _, setter in ipairs({"registry", "active"}) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("HS-012 refuses a live manager after initial " .. setter
				.. " setter " .. mode, function()
				local options = {
					active_profile = "user_custom",
					user_profiles = {{id = "user_custom", label = "Custom"}},
				}
				options[setter .. "_setter_mode"] = mode
				with_profiles_fixture(options, function(fixture)
					helpers.assert_eq(fixture.manager, nil)
					if setter == "registry" then
						helpers.assert_eq(fixture.active_calls(), 0,
							"active identity cannot follow a refused registry")
					end
					helpers.assert_true(fixture.errors() >= 2)
				end)
			end)
		end
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 stops edited-profile publication after active setter "
			.. mode, function()
			with_profiles_fixture({
				active_profile = "user_custom",
				active_setter_mode = mode,
				active_setter_occurrence = 2,
				user_profiles = {{id = "user_custom", label = "Custom"}},
				edit_update = {id = "user_custom", label = "Updated"},
			}, function(fixture)
				local rows = fixture.manager.get_menu_item().menu
				local custom = find_row(rows, "Custom")
				local edit = find_row(custom.items, "menu.profiles.edit_profile")
				helpers.assert_type(edit.action, "function")
				edit.action()
				helpers.assert_eq(#fixture.runtime_profiles, 3,
					"the refused active identity must be reasserted exactly")
				helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Custom")
				helpers.assert_eq(fixture.runtime_registry()[1].label, "Custom")
				helpers.assert_eq(fixture.direct_saves(), 0,
					"a refused identity cannot publish edited preferences")
				helpers.assert_eq(fixture.direct_menus(), 0)
				helpers.assert_eq(fixture.notifications(), 0)
				helpers.assert_true(fixture.errors() >= 1)
			end)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 rolls back edited registry setter " .. mode, function()
			with_profiles_fixture({
				active_profile = "user_custom",
				registry_setter_mode = mode,
				registry_setter_occurrence = 2,
				user_profiles = {{id = "user_custom", label = "Custom"}},
				edit_update = {id = "user_custom", label = "Updated"},
			}, function(fixture)
				local rows = fixture.manager.get_menu_item().menu
				local custom = find_row(rows, "Custom")
				local edit = find_row(custom.items, "menu.profiles.edit_profile")
				helpers.assert_eq(edit.action(), true,
					"the editor timer owns dispatch even when its callback rejects")
				helpers.assert_eq(fixture.registry_calls(), 3)
				helpers.assert_eq(fixture.active_calls(), 1,
					"active publication cannot follow a refused candidate registry")
				helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Custom")
				helpers.assert_eq(fixture.runtime_registry()[1].label, "Custom")
				helpers.assert_eq(fixture.direct_saves(), 0)
				helpers.assert_eq(fixture.direct_menus(), 0)
			end)
		end)
	end

	for _, boundary in ipairs({"save", "menu"}) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("HS-012 rolls back edited profile after " .. boundary
				.. " boundary " .. mode, function()
			local options = {
				active_profile = "user_custom",
				user_profiles = {{id = "user_custom", label = "Custom"}},
				edit_update = {id = "user_custom", label = "Updated"},
			}
			options[boundary .. "_mode"] = mode
			with_profiles_fixture(options, function(fixture)
				local rows = fixture.manager.get_menu_item().menu
				local custom = find_row(rows, "Custom")
				local edit = find_row(custom.items, "menu.profiles.edit_profile")
				helpers.assert_eq(edit.action(), true)
				helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Custom")
				helpers.assert_eq(fixture.runtime_registry()[1].label, "Custom")
				helpers.assert_eq(fixture.active_calls(),
					boundary == "save" and 4 or 5,
					"rollback must reassert the prior active identity after opaque callbacks")
				helpers.assert_eq(fixture.notifications(), 0)
				if boundary == "save" then
					helpers.assert_eq(fixture.direct_saves(), 2)
					helpers.assert_eq(fixture.direct_menus(), 0)
				else
					helpers.assert_eq(fixture.direct_saves(), 2)
					helpers.assert_eq(fixture.direct_menus(), 2)
				end
			end)
		end)
		end
	end

	helpers.it("HS-012 fences a nested edit for the full opaque save boundary", function()
		local nested_dispatched = false
		with_profiles_fixture({
			active_profile = "user_custom",
			user_profiles = {{id = "user_custom", label = "Custom"}},
			edit_update = {id = "user_custom", label = "Updated"},
			save_hook = function(manager)
				local rows = manager.get_menu_item().menu
				local updated = find_row(rows, "Updated")
				local edit = find_row(updated.items, "menu.profiles.edit_profile")
				nested_dispatched = edit.action()
			end,
		}, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			local custom = find_row(rows, "Custom")
			local edit = find_row(custom.items, "menu.profiles.edit_profile")
			helpers.assert_eq(edit.action(), true)
			helpers.assert_eq(nested_dispatched, false,
				"the nested edit must be refused before it can acquire a timer")
			helpers.assert_eq(fixture.editor_calls(), 1,
				"the nested edit must stop before reopening its opaque editor callback")
			helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Updated")
			helpers.assert_eq(fixture.runtime_registry()[1].label, "Updated")
			helpers.assert_eq(fixture.notifications(), 1)
		end)
	end)

	for _, setter in ipairs({"registry", "active"}) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("HS-012 rolls back cloned-profile edit " .. setter
				.. " setter " .. mode, function()
				local options = {edit_update_label = "Updated clone"}
				options[setter .. "_setter_mode"] = mode
				options[setter .. "_setter_occurrence"] = setter == "registry" and 3 or 2
				with_profiles_fixture(options, function(fixture)
					local rows = fixture.manager.get_menu_item().menu
					local clone = find_row(rows, "menu.profiles.clone_builtin")
					helpers.assert_eq(clone.action(), true)
					helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
					helpers.assert_true(
						fixture.state.llm_user_profiles[1].label ~= "Updated clone")
					helpers.assert_true(
						fixture.runtime_registry()[1].label ~= "Updated clone")
					helpers.assert_eq(fixture.direct_saves(), 0)
					helpers.assert_eq(fixture.direct_menus(), 0)
					if setter == "registry" then
						helpers.assert_eq(fixture.registry_calls(), 4)
					else
						helpers.assert_eq(fixture.active_calls(), 3)
					end
				end)
			end)
		end
	end

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
