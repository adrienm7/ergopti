--- tests/support/llm_activation_fixture.lua

--- ==============================================================================
--- MODULE: LLM Activation Fixture
--- DESCRIPTION:
--- Owns direct injections and cached consumers for construction and callback work.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"infra.logger",
	"infra.notifications",
	"infra.i18n",
	"ui.menu.shortcut_utils",
	"modules.llm",
	"ui.menu.menu_llm.models_manager",
	"ui.menu.menu_llm.profiles_manager",
	"ui.menu.menu_llm.settings_manager",
	"ui.menu.menu_llm.temperature_panel",
	"ui.menu.menu_llm.streaming_panel",
	"ui.menu.menu_llm.warmup_controller",
	"ui.menu.menu_llm.backend_panel",
	"ui.menu.menu_llm.trigger_panel",
	"ui.menu.menu_llm.api_panel",
	"ui.menu.menu_llm.models_selector",
	"ui.menu.menu_llm.model_switcher",
	"modules.llm.api_mlx",
	"ui.menu.menu_llm.startup_controller",
	"ui.menu.menu_llm.trigger_orchestrator",
	"ui.menu.menu_llm.menu_layout",
	"infra.manifest_menu",
	"modules.llm.mlx_deps_checker",
	"modules.llm.ollama_deps_checker",
	"adapters.timer_scheduler",
	"ui.menu.menu_llm.activation_pause_owner",
	"adapters.event_provenance",
	"adapters.synthetic_input",
	"infra.keycodes",
	"modules.gestures.engine",
	"modules.gestures.actions",
	"adapters.key_state",
	"modules.llm.warmup_controller",
	"modules.llm.api_ollama",
	"modules.llm.api_remote",
	"ui.wpm.wpm_menubar",
	"ui.wpm.wpm_widget",
	"platform.remap.onboarding",
	"ui.tooltip",
	"modules.shortcuts.script_control",
	"ui.menu.menu_llm",
	"ui.menu.menu_llm.prediction_lock_registry",
	"ui.menu.menu_llm.profile_label",
	"infra.dialog_util",
	"adapters.shell_runner",
	"infra.deferred_work",
}

local function build_fixture(backend, save_results, options)
	options = options or {}
	local noop = function() end
	local calls = {
		bootstrap = 0,
		requirements = 0,
		notifications = 0,
		updates = 0,
		saves = 0,
		keymap_states = {},
		runtime_models = {},
		display_models = {},
		pause_owners = {},
		resume_timers = {},
		timer_cancel_handles = {},
	}
	local paused = false
	local pause_epoch = 0
	local state = {
		llm_enabled = false,
		llm_backend = backend,
		llm_model = options.model ~= nil and options.model or "candidate-model",
		llm_num_predictions = 1,
		llm_min_words = 1,
		llm_max_words = 16,
		llm_context_length = 2048,
		llm_temperature = 0.1,
		llm_reset_on_nav = true,
		llm_active_profile = "basic",
		llm_profile_shortcuts = {},
		llm_trigger_shortcut = false,
	}
	local last_attempted_enabled = false
	local runtime_enabled = false
	local runtime_backend = options.runtime_backend or backend
	local runtime_model = options.runtime_model or "old-runtime"
	local runtime_display_model = options.runtime_display_model or "old-display"
	local MenuLLM, deps
	local nested_factory_result
	local nested_backend_result
	local timer_cancel_mode = "true"
	local function strict_result(mode, label)
		if mode == "throw" then error(label .. " injected refusal") end
		if mode == "nil" then return nil end
		if mode == "false" then return false end
		return true
	end
	local backend_setter
	backend_setter = function(value)
		calls.backend_setters = (calls.backend_setters or 0) + 1
		local call_index = calls.backend_setters
		runtime_backend = value
		local mode = call_index == 1 and options.backend_setter_mode or nil
		if call_index == 1 and options.backend_direct_successor == true then
			nested_backend_result = backend_setter(
				options.backend_direct_successor_target or "mlx")
		end
		if call_index == 1 and options.backend_reenter == true then
			local nested_state = {}
			for key, item in pairs(state) do nested_state[key] = item end
			nested_state.llm_backend = options.backend_reenter_target or "mlx"
			nested_state.llm_model = nil
			local nested_deps = {}
			for key, item in pairs(deps) do nested_deps[key] = item end
			nested_deps.state = nested_state
			nested_deps.active_tasks = {}
			nested_factory_result = MenuLLM.create(nested_deps)
		end
		return strict_result(mode, "backend setter")
	end

	package.loaded["infra.logger"] = {
		debug = noop, info = noop, warn = noop, error = noop,
		callback = function(_, _, callback, ...)
			return xpcall(callback, debug.traceback, ...)
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(message)
			if message == "notify.llm_enabled" or message == "notify.llm_disabled" then
				calls.notifications = calls.notifications + 1
			end
			return true
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = {
			llm_enabled = false,
			llm_backend = "ollama",
			llm_model_mlx = "",
			llm_model_ollama = "",
			llm_num_predictions = 1,
			llm_min_words = 1,
			llm_max_words = 16,
			llm_context_length = 2048,
			llm_temperature = 0.1,
			llm_nav_modifiers = {},
			llm_val_modifiers = {},
		},
		set_backend = backend_setter,
		get_backend = function() return runtime_backend end,
		get_current_model = function() return runtime_model end,
		set_llm_model_mlx = function(value)
			calls.model_setters = (calls.model_setters or 0) + 1
			runtime_model = value
			local mode = calls.model_setters == 1 and options.model_setter_mode or nil
			return strict_result(mode, "model setter")
		end,
		set_llm_model_ollama = function(value)
			calls.model_setters = (calls.model_setters or 0) + 1
			runtime_model = value
			local mode = calls.model_setters == 1 and options.model_setter_mode or nil
			return strict_result(mode, "model setter")
		end,
	}

	local models = {
		create_requirement_owner = function() return {} end,
		pause_requirements = function() return true, false end,
		get_presets = function() return {} end,
		get_actual_model_name = function(name) return name end,
		get_model_info = function() return {} end,
		get_model_ram = function() return 0 end,
		check_requirements = function(_, on_ok, on_fail, requirement_opts)
			calls.requirements = calls.requirements + 1
			calls.requirements_ok = on_ok
			calls.requirements_fail = on_fail
			calls.requirements_opts = requirement_opts
			if options.requirements_sync_success then on_ok() end
			if options.requirements_sync_cancel then on_fail(options.requirements_sync_cancel) end
			if options.requirements_throw then error("requirements exploded") end
			if options.requirements_mode == "false" then return false end
			if options.requirements_mode == "nil" then return nil end
			return true
		end,
	}
	package.loaded["ui.menu.menu_llm.models_manager"] = { new = function()
		calls.models_constructed = (calls.models_constructed or 0) + 1
		return models
	end }
	package.loaded["ui.menu.menu_llm.profiles_manager"] = {
		new = function(deps)
			calls.profiles_constructed = (calls.profiles_constructed or 0) + 1
			calls.profile_deps = deps
			if type(options.delete_recovery_gate) == "function" then
				deps.settle_profile_delete_recovery = options.delete_recovery_gate
			end
			if type(options.candidate_recovery_gate) == "function" then
				deps.settle_profile_candidate_recovery = options.candidate_recovery_gate
			end
			if options.profile_constructor_mode ~= nil then
				return strict_result(options.profile_constructor_mode,
					"profile constructor")
			end
			return { get_menu_item = function() return {} end }
		end,
	}
	package.loaded["ui.menu.menu_llm.settings_manager"] = {
		new = function()
			calls.settings_constructed = (calls.settings_constructed or 0) + 1
			return {
				build_nav_modifier_menu = function() return {} end,
				build_val_modifier_menu = function() return {} end,
			}
		end,
	}
	package.loaded["ui.menu.menu_llm.temperature_panel"] = { build = noop }
	package.loaded["ui.menu.menu_llm.streaming_panel"] = { build = function() return {} end }
	package.loaded["ui.menu.menu_llm.warmup_controller"] = { warmup = noop }
	package.loaded["ui.menu.menu_llm.backend_panel"] = {
		is_apple_silicon = function() return false end,
		build = function() return "backend", {} end,
	}
	package.loaded["ui.menu.menu_llm.trigger_panel"] = { build = function() return {} end }
	package.loaded["ui.menu.menu_llm.api_panel"] = {
		build = function() return nil, nil end,
		build_model_picker = function() return {} end,
	}
	package.loaded["ui.menu.menu_llm.models_selector"] = {
		build = function(ctx)
			calls.models_selector_ctx = ctx
			return {}
		end,
	}
	if options.real_switcher then
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil
	else
		package.loaded["ui.menu.menu_llm.model_switcher"] = {
			new = function(ctx)
				calls.switchers_constructed = (calls.switchers_constructed or 0) + 1
				calls.switcher_ctx = ctx
				local settle_recovery_debts = function() return true end
				calls.switcher_settlement = settle_recovery_debts
				return {
					switch_model = noop,
					disable_model = noop,
					set_llm_profile = noop,
					settle_recovery_debts = settle_recovery_debts,
					apply_recommended_prompt_profile = function()
						return options.recommendation_result
					end,
					get_display_model_name = function(name) return name end,
					get_model_power_level = function()
						calls.power_resolutions = (calls.power_resolutions or 0) + 1
						return 1
					end,
					guarded_check_requirements = noop,
				}
			end,
		}
	end
	package.loaded["modules.llm.api_mlx"] = {}
	package.loaded["ui.menu.menu_llm.startup_controller"] = { new = function() return noop end }
	package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = {
		new = function()
			return {
				bind_hotkey = noop,
				activate_hotkey = noop,
				apply_llm_shortcut = noop,
				apply_llm_profile_shortcut = noop,
				restore_shortcuts = function() return true end,
			}
		end,
	}
	package.loaded["ui.menu.menu_llm.menu_layout"] = {
		row_ids = function() return {} end,
		row_disabled = function() return false end,
		has_health_dot = function() return false end,
	}
	package.loaded["infra.manifest_menu"] = {
		render_rows = function(rows) return rows end,
		build = function() return {} end,
	}
	package.loaded["modules.llm.mlx_deps_checker"] = {
		check_and_install_deps = function(callback)
			calls.bootstrap = calls.bootstrap + 1
			if options.bootstrap_throw then error("bootstrap exploded") end
			if options.bootstrap_double_success then
				callback(true)
				callback(true)
				if options.bootstrap_return ~= nil then return options.bootstrap_return end
				return true
			end
			if options.bootstrap_fail_then_throw then
				callback(false)
				error("bootstrap exploded after callback")
			end
			calls.bootstrap_callback = callback
			if options.bootstrap_return == "nil" then return nil end
			if options.bootstrap_return ~= nil then return options.bootstrap_return end
			return true
		end,
	}
	package.loaded["modules.llm.ollama_deps_checker"] = {
		check_and_install_deps = function(callback)
			calls.bootstrap = calls.bootstrap + 1
			calls.bootstrap_callback = callback
			if options.ollama_bootstrap_throw then
				calls.ollama_bootstrap_outcome = "throw"
				error("Ollama bootstrap exploded")
			end
			local receipt = options.ollama_bootstrap_return
			if receipt == "nil" then
				receipt = nil
			elseif receipt == nil then
				receipt = true
			end
			calls.ollama_bootstrap_outcome = type(receipt)
			calls.ollama_bootstrap_receipt = receipt
			return receipt
		end,
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, callback)
			local handle = { timer = {}, callback = callback, observers = {} }
			calls.resume_timers[#calls.resume_timers + 1] = handle
			return handle, true
		end,
		cancel = function(handle)
			calls.timer_cancel_handles[#calls.timer_cancel_handles + 1] = handle
			if timer_cancel_mode == "throw" then error("resume timer cancellation exploded") end
			if timer_cancel_mode == "false" then return false end
			if timer_cancel_mode == "nil" then return nil end
			handle.timer = nil
			local observers = handle.observers
			handle.observers = {}
			for _, observer in ipairs(observers) do observer() end
			return true
		end,
		onSettled = function(handle, observer)
			if handle.timer == nil then observer(); return true end
			handle.observers[#handle.observers + 1] = observer
			return true
		end,
	}
	package.loaded["ui.menu.menu_llm.activation_pause_owner"] = nil

	local script_control
	if options.real_script_control then
		local admission_fence = nil
		package.loaded["adapters.event_provenance"] = {
			mark = function() return true end,
			is_synthetic = function() return false end,
		}
		package.loaded["adapters.synthetic_input"] = {
			when_idle = function(callback) callback(); return true end,
			acquire_admission_fence = function()
				if admission_fence ~= nil then return nil end
				admission_fence = {}
				return admission_fence
			end,
			release_admission_fence = function(token)
				if token ~= admission_fence then return false end
				admission_fence = nil
				return true
			end,
			defer_after_callback = function(_, callback) return callback() end,
		}
		package.loaded["infra.keycodes"] = {
			F13_KARABINER_RETURN = 106,
			F14_KARABINER_BACKSPACE = 107,
			F15_KARABINER_ESCAPE = 108,
			BACKSPACE = 51,
			RETURN = 36,
			ESCAPE = 53,
		}
		package.loaded["modules.gestures.engine"] = {}
		package.loaded["modules.gestures.actions"] = {
			get_label = function(name) return name end,
			execute_single = function() return true end,
			SG_NAMES = {},
			AX_NAMES = {},
		}
		package.loaded["adapters.key_state"] = {
			is_right_altgr_held = function() return false end,
			describe_held_modifiers = function() return "(none)" end,
		}
		package.loaded["modules.llm.api_mlx"] = {
			pause_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
		package.loaded["modules.llm.warmup_controller"] = {
			pause_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
		package.loaded["modules.llm.api_ollama"] = {
			pause_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
		package.loaded["modules.llm.api_remote"] = {
			pause_warmup = function() return true end,
			resume_warmup = function() return true end,
		}
		package.loaded["ui.wpm.wpm_menubar"] = {
			is_running = function() return false end,
			stop = function() return true end,
			resume_after_pause = function() return true end,
		}
		package.loaded["ui.wpm.wpm_widget"] = {
			is_running = function() return false end,
			stop = function() return true end,
			resume_after_pause = function() return true end,
		}
		package.loaded["platform.remap.onboarding"] = {
			stop = function() return true end,
		}
		package.loaded["ui.tooltip"] = {
			hide_forced = function() return true end,
		}
		package.loaded["modules.shortcuts.script_control"] = nil
		script_control = require("modules.shortcuts.script_control")
	else
		script_control = {
			is_paused = function() return paused end,
			get_pause_epoch = function() return pause_epoch end,
			register_pause_owner = function(name, owner)
				calls.pause_owners[name] = owner
				return options.registration_result ~= false
			end,
		}
	end

	package.loaded["ui.menu.menu_llm"] = nil
	MenuLLM = require("ui.menu.menu_llm")
	deps = {
		state = state,
		keymap = {
			get_llm_enabled = function() return runtime_enabled end,
			set_llm_enabled = function(value)
				calls.keymap_states[#calls.keymap_states + 1] = value
				if options.keymap_throw_on == value then error("keymap setter exploded") end
				runtime_enabled = value == true
				return true
			end,
			set_llm_model = function(value)
				calls.runtime_models[#calls.runtime_models + 1] = value
				runtime_model = value
				local mode = #calls.runtime_models == 1
					and options.no_model_setter_mode or nil
				return strict_result(mode, "No Model setter")
			end,
			set_llm_display_model_name = function(value)
				calls.display_models[#calls.display_models + 1] = value
				runtime_display_model = value
			end,
		},
		save_prefs = function()
			calls.saves = calls.saves + 1
			last_attempted_enabled = state.llm_enabled
			return save_results[calls.saves]
		end,
		update_menu = function() calls.updates = calls.updates + 1 end,
		active_tasks = {},
		script_control = script_control,
	}
	calls.set_paused = function(value) paused = value == true end
	calls.set_pause_epoch = function(value) pause_epoch = value end
	calls.set_timer_cancel_mode = function(value) timer_cancel_mode = value end
	calls.get_runtime_enabled = function() return runtime_enabled end
	calls.root_deps = deps
	calls.script_control = script_control
	local handler = MenuLLM.create(deps)
	calls.handler = handler
	calls.runtime_backend = function() return runtime_backend end
	calls.runtime_model = function() return runtime_model end
	calls.runtime_display_model = function() return runtime_display_model end
	calls.nested_factory_result = function() return nested_factory_result end
	calls.nested_backend_result = function() return nested_backend_result end
	if type(handler.build_item) ~= "function" then
		return nil, state, calls
	end
	local item = handler.build_item()
	helpers.assert_type(item.action, "function")
	calls.last_attempted_enabled = function() return last_attempted_enabled end
	return item.action, state, calls
end

--- Runs all fixture work before restoring the exact predecessor module cache.
--- @param backend string Backend identity.
--- @param save_results table Ordered persistence receipts.
--- @param options table|nil Fault injection and runtime options.
--- @param callback function Receives action, state and observed calls.
return function(backend, save_results, options, callback)
	return helpers.with_fresh_modules(OWNED_MODULES, function()
		return callback(build_fixture(backend, save_results, options))
	end)
end
