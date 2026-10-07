--- tests/support/llm_activation_fixture.lua

--- ==============================================================================
--- MODULE: LLM Activation Fixture
--- DESCRIPTION:
--- Owns direct injections and cached consumers for construction and callback work.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"adapters.http_client",
	"ui.menu.menu_llm.ollama_enable_probe",
	"llm.enable_admission",
	"infra.logger",
	"infra.manifest_reader",
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
	"ui.menu.menu_llm.runtime_install_offer",
	"ui.menu.menu_llm.mlx_repair_offer",
	"modules.llm.mlx_bootstrap_diagnosis",
	"modules.llm.backend_detector",
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
	"ui.menu.menu_llm.local_server_panel",
	"ui.menu.menu_llm.unreachable_backend_offer",
	"modules.llm.local_servers",
	"modules.llm.ollama_endpoint",
}

-- The local OpenAI-compatible servers of _shared/modules/llm/local_servers.json
local LOCAL_SERVER_ORDER = { "omlx", "lmstudio", "llamacpp", "jan" }
local LOCAL_SERVERS = {
	omlx = { label = "oMLX", base_url = "http://localhost:8000/v1" },
	lmstudio = { label = "LM Studio", base_url = "http://localhost:1234/v1" },
	llamacpp = { label = "llama.cpp / LocalAI", base_url = "http://localhost:8080/v1" },
	jan = { label = "Jan", base_url = "http://localhost:1337/v1" },
}

local function build_fixture(backend, save_results, options)
	-- Bind the real shared row policy before the fixture installs its menu port.
	local native_renderer = require("infra.manifest_menu")
	options = options or {}
	local noop = function() end
	local calls = {
		version_requests = {},
		service_repairs = 0,
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
		debug = noop, info = noop, warn = noop, error = noop, done = noop,
		start = noop, success = noop,
		callback = function(_, _, callback, ...)
			return xpcall(callback, debug.traceback, ...)
		end,
	}
	calls.runtime_notices = {}
	calls.offers = 0
	calls.notices = {}
	package.loaded["infra.notifications"] = {
		notify = function(message, body, kind, on_click)
			calls.notices[#calls.notices + 1] = { title = message, body = body, kind = kind, on_click = on_click }
			if message == "notify.llm_enabled" or message == "notify.llm_disabled" then
				calls.notifications = calls.notifications + 1
			elseif message == "ollama.runtime_missing_title"
				or message == "mlx.runtime_missing_title" then
				calls.runtime_notices[#calls.runtime_notices + 1] = body
			end
			return true
		end,
	}
	-- The Ollama download offer: the choice is the button label, as i18n echoes keys.
	-- The unreachable-backend error picks through options.offer_pick(dialog),
	-- which returns the chosen index, or nil to keep the AI off.
	calls.offer_dialogs = {}
	package.loaded["infra.dialog_util"] = {
		block_alert = function()
			calls.offers = calls.offers + 1
			return options.ollama_offer_choice or "ollama.offer_website"
		end,
		choose = function(title, message, choices, cancel_label, ok_label)
			local dialog = {
				title = title, message = message, choices = choices,
				cancel = cancel_label, ok = ok_label,
			}
			calls.offer_dialogs[#calls.offer_dialogs + 1] = dialog
			if type(options.offer_pick) ~= "function" then return nil end
			return options.offer_pick(dialog)
		end,
	}
	-- format keeps its arguments visible: "key|arg1|arg2"
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		format = function(key, ...)
			local parts = { key }
			local args = table.pack(...)
			for index = 1, args.n do parts[#parts + 1] = tostring(args[index]) end
			return table.concat(parts, "|")
		end,
	}
	-- The local servers answer only once swept, as a real sweep publishes them
	calls.sweeps = 0
	local swept = false
	local function local_verdict(id)
		local models = type(options.local_servers_up) == "table" and options.local_servers_up[id] or nil
		if not swept or models == nil then
			return { status = "down", base_url = LOCAL_SERVERS[id].base_url, models = {} }
		end
		return { status = "up", base_url = LOCAL_SERVERS[id].base_url, models = models }
	end
	package.loaded["modules.llm.local_servers"] = {
		ORDER = LOCAL_SERVER_ORDER,
		SERVERS = LOCAL_SERVERS,
		STATUS_UP = "up",
		STATUS_NEEDS_KEY = "needs_key",
		STATUS_DOWN = "down",
		result = local_verdict,
		detected = function()
			local ids = {}
			for _, id in ipairs(LOCAL_SERVER_ORDER) do
				if local_verdict(id).status ~= "down" then ids[#ids + 1] = id end
			end
			return ids
		end,
	}
	-- The engine menu's switch to a server: stores its entry, selects the API backend
	calls.server_switches = {}
	package.loaded["ui.menu.menu_llm.local_server_panel"] = {
		rows = function() return {} end,
		set_agent_context = noop,
		use_server = function(id, model, on_selected)
			calls.server_switches[#calls.server_switches + 1] = { id = id, model = model }
			state.llm_backend = "api"
			runtime_backend = "api"
			if type(on_selected) == "function" then on_selected(true) end
			return true
		end,
	}
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["modules.llm"] = {
		api_remote = {
			detect_local_servers = function(on_done)
				calls.sweeps = calls.sweeps + 1
				swept = true
				if type(on_done) == "function" then on_done(true) end
				return true
			end,
		},
		DEFAULT_STATE = {
			llm_enabled = false,
			llm_backend = "ollama",
			llm_ollama_port = 11434,
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
			return { scope_idle = function() return true end, get_menu_item = function() return {} end }
		end,
	}
	package.loaded["ui.menu.menu_llm.settings_manager"] = {
		new = function()
			calls.settings_constructed = (calls.settings_constructed or 0) + 1
			return {
				scope_idle = function() return options.scope_blocked ~= true end,
				build_nav_modifier_menu = function() return {} end,
				build_val_modifier_menu = function() return {} end,
				set_context_length = noop,
				reset_context_length = noop,
				set_min_words = noop,
				reset_min_words = noop,
				set_max_words = noop,
				reset_max_words = noop,
				set_temperature = function() calls.temperature_sets = (calls.temperature_sets or 0) + 1; return true end,
				reset_temperature = function() calls.temperature_resets = (calls.temperature_resets or 0) + 1; return true end,
				apply_setting_transaction = function(request) calls.temperature_request = request; return true end,
			}
		end,
	}
	-- The genuine panel binds the fixture's callbacks after its manifest port exists.
	package.loaded["ui.menu.menu_llm.temperature_panel"] = nil
	package.loaded["ui.menu.menu_llm.streaming_panel"] = { build = function() return {} end }
	package.loaded["ui.menu.menu_llm.warmup_controller"] = { warmup = noop }
	package.loaded["ui.menu.menu_llm.backend_panel"] = {
		scope_idle = function() return true end,
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
					scope_idle = function() return true end,
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
	package.loaded["ui.menu.menu_llm.startup_controller"] = {
		new = function(ctx)
			calls.startup_ctx = ctx
			return noop, function() return true end
		end,
	}
	package.loaded["ui.menu.menu_llm.trigger_orchestrator"] = {
		new = function()
			return {
				bind_hotkey = noop,
				activate_hotkey = noop,
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
	local presentation_renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
		json_decode = require("adapters.json_codec").decode,
		i18n = { get = package.loaded["infra.i18n"].get, section = package.loaded["infra.i18n"].get },
		logger = package.loaded["infra.logger"],
	}))
	package.loaded["infra.manifest_menu"] = {
		check_row = native_renderer.check_row,
		native_child_rows = native_renderer.native_child_rows,
		template_rows = presentation_renderer.template_rows,
		get_array = presentation_renderer.get_array,
		render_rows = function(rows, slot)
			if slot == "llm_generation_settings" then return native_renderer.render_rows(rows, slot) end
			return rows
		end,
		-- The render context is kept so a test can hand it to the real renderer.
		build = function(_key, _category, _handlers, _groups, render_ctx)
			calls.render_ctx = render_ctx
			return {}
		end,
	}
	-- The menu reaches the MLX runtime only through its selection entry.
	local function mlx_selection_bootstrap(callback)
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
	end
	package.loaded["modules.llm.mlx_deps_checker"] = {
		install_for_selection = mlx_selection_bootstrap,
		runtime_installed = function() return options.mlx_installed == true end,
		-- A failed selection opens the repair offer with the checker's cause.
		get_failure_cause = function() return nil end,
	}
	calls.ollama_installs = 0
	package.loaded["modules.llm.ollama_deps_checker"] = {
		-- An installed Ollama is reused, so enabling offers no download unless
		-- a case sets ollama_installed = false.
		provisioning_idle = function() return options.provisioning_debt ~= true end,
		runtime_available = function() return options.ollama_installed ~= false end,
		is_task_running = function() return false end,
		install_for_selection = function(callback)
			calls.ollama_installs = calls.ollama_installs + 1
			calls.bootstrap_callback = callback
			if options.ollama_bootstrap_throw then
				calls.ollama_bootstrap_outcome = "throw"
				error("Ollama installation exploded")
			end
			local receipt = options.ollama_bootstrap_return
			if receipt == "nil" then receipt = nil elseif receipt == nil then receipt = true end
			calls.ollama_bootstrap_outcome = type(receipt)
			calls.ollama_bootstrap_receipt = receipt
			return receipt
		end,
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

	package.loaded["modules.llm"].configuration_idle = function() return true end
	package.loaded["adapters.http_client"] = {
		new = function()
			local active = false
			local observers = {}
			return {
				get = function(url, _, callback)
					calls.version_requests[#calls.version_requests + 1] = url
					active = true
					calls.version_callback = function(result)
						active = false
						callback(result)
						local pending = observers
						observers = {}
						for _, observer in ipairs(pending) do observer() end
					end
					if options.version_deferred ~= true then
						calls.version_callback((options.version_receipts and options.version_receipts[#calls.version_requests])
							or options.version_receipt or {
							ok = options.ollama_installed ~= false,
							status = options.ollama_installed == false and 0 or 200,
							body = '{"version":"fixture-version"}',
						})
					end
					return strict_result(options.version_dispatch_mode, "version dispatch")
				end,
				cancel = function()
					if strict_result(options.version_cancel_mode, "version cancel") ~= true then return false end
					active = false
					return true
				end,
				onSettled = function(observer)
					if active then observers[#observers + 1] = observer else observer() end
					return true
				end,
			}
		end,
	}
	local service = package.loaded["modules.llm.api_ollama"] or {}
	service.startup_idle = function() return options.startup_debt ~= true end
	service.ensure_running = function(context)
		calls.service_repairs = calls.service_repairs + 1
		calls.service_authorized = context.is_authorized
		calls.service_callback = context.on_settled
		if options.service_deferred ~= true then
			context.on_settled(options.service_receipt ~= false)
		end
		return strict_result(options.service_dispatch_mode, "service repair dispatch")
	end
	package.loaded["modules.llm.api_ollama"] = service

	package.loaded["ui.menu.menu_llm.runtime_install_offer"] = nil
	calls.temperature_builder = require("ui.menu.menu_llm.temperature_panel").build
	package.loaded["ui.menu.menu_llm"] = nil
	MenuLLM = require("ui.menu.menu_llm")
	deps = {
		state = state,
		keymap = {
			get_llm_enabled = function() return runtime_enabled end,
			-- The live-mode submenu reads the engine's live prompt: never on here
			get_live_prompt = function() return nil end,
			set_live_prompt = function() return false end,
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
	helpers.assert_nil(item.action, "the IA parent row opens a submenu and must carry no action")
	local toggle = calls.render_ctx and calls.render_ctx.commands
		and calls.render_ctx.commands["llm_toggle"]
	helpers.assert_type(toggle, "function")
	calls.last_attempted_enabled = function() return last_attempted_enabled end
	return toggle, state, calls
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
