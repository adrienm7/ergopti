--- tests/support/ui/menu/menu_llm/profiles/profiles_manager_profile_activation_owner_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_profiles_manager_profile_activation_owner
--- DESCRIPTION:
--- Prelude shared by the test_profiles_manager_profile_activation_owner_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.timer_scheduler",
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
		local timers = {}
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
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_, callback)
				local handle = { callback = callback, timer = {} }
				timers[#timers + 1] = handle
				return handle, true
			end,
			onSettled = function(handle, callback) handle.on_settled = callback; return true end,
			cancel = function(handle) handle.timer = nil; if handle.on_settled then handle.on_settled() end; return true end,
		}
		local renderer = assert(require("menu.renderer").new({
			platform = "hs",
			manifest_path = function()
				return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json"
			end,
			json_decode = require("json").decode,
			i18n = package.loaded["infra.i18n"],
			logger = package.loaded["infra.logger"],
		}))
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
			command_row = renderer.command_row,
			template_rows = renderer.template_rows,
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
		_G.hs = {}

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
			dispatch = function(row)
				local result = row.action()
				while #timers > 0 do
					local timer = table.remove(timers, 1)
					if timer.timer then
						timer.callback()
						timer.timer = nil
						if timer.on_settled then timer.on_settled() end
					end
				end
				return result
			end,
			manager = manager,
			native_dependencies = deps,
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

return {
	MODULES = MODULES,
	find_row = find_row,
	with_profiles_fixture = with_profiles_fixture,
}
