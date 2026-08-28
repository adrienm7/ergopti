--- tests/unit/ui/menu/menu_llm/test_llm_activation_save_gate.lua

--- ==============================================================================
--- MODULE: LLM Activation Preference Gate Regression
--- DESCRIPTION:
--- Drives the real top-level LLM menu callback. Candidate publication must
--- precede every backend bootstrap, requirements check, and success signal.
--- ==============================================================================

local helpers = require("tests.helpers")

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
			if options.ollama_bootstrap_throw then error("Ollama bootstrap exploded") end
			if options.ollama_bootstrap_return == "nil" then return nil end
			if options.ollama_bootstrap_return ~= nil then
				return options.ollama_bootstrap_return
			end
			return true
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

local function assert_rejected_activation(backend)
	local action, state, calls = build_fixture(backend, { false })
	action()
	helpers.assert_eq(state.llm_enabled, false)
	helpers.assert_eq(calls.saves, 1)
	helpers.assert_eq(calls.keymap_states, { true, false },
		"a rejected persistence write must reapply the previous prediction lock")
	helpers.assert_eq(calls.get_runtime_enabled(), false,
		"runtime predictions must match the last durable preference")
	helpers.assert_eq(calls.bootstrap, 0,
		"a rejected " .. backend .. " activation must not start dependency setup")
	helpers.assert_eq(calls.requirements, 0,
		"a rejected " .. backend .. " activation must not start model requirements")
	helpers.assert_eq(calls.notifications, 0,
		"a rejected " .. backend .. " activation must not announce success")
	helpers.assert_eq(calls.updates, 1,
		"a rejected " .. backend .. " activation must repaint the restored preference")
end

helpers.describe("LLM activation: external work waits for preference commit", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 aborts factory construction after backend setter " .. mode, function()
			local action, state, calls = build_fixture("ollama", {true}, {
				backend_setter_mode = mode,
				runtime_backend = "mlx",
			})
			helpers.assert_eq(action, nil)
			helpers.assert_eq(state.llm_backend, "ollama")
			helpers.assert_eq(calls.runtime_backend(), "mlx",
				"the mutate-then-refuse backend setter must be compensated")
			helpers.assert_eq(calls.backend_setters, 2)
			helpers.assert_eq(calls.models_constructed or 0, 0)
			helpers.assert_eq(calls.switchers_constructed or 0, 0)
			helpers.assert_eq(#calls.display_models, 0)
		end)

		helpers.it("HS-012 blocks display successors after model setter " .. mode, function()
			local action, state, calls = build_fixture("ollama", {true}, {
				model_setter_mode = mode,
				runtime_backend = "api",
			})
			helpers.assert_eq(action, nil)
			helpers.assert_eq(state.llm_model, "candidate-model")
			helpers.assert_eq(calls.model_setters, 2,
				"the mutate-then-refuse model setter must be compensated")
			helpers.assert_eq(calls.runtime_model(), "old-runtime",
				"compensation must restore the observed runtime predecessor, not the target preference")
			helpers.assert_eq(calls.runtime_backend(), "api",
				"a failed model acquisition must compensate the already-committed backend")
			helpers.assert_eq(calls.backend_setters, 2)
			helpers.assert_eq(calls.models_constructed, 1,
				"the resolver manager is the only allowed construction")
			helpers.assert_eq(calls.settings_constructed or 0, 0)
			helpers.assert_eq(calls.switchers_constructed or 0, 0)
			helpers.assert_eq(#calls.display_models, 0)
			helpers.assert_eq(calls.power_resolutions or 0, 0)
		end)
	end

	helpers.it("HS-012 yields backend compensation to a direct Core successor", function()
		local action, _, calls = build_fixture("ollama", {true}, {
			backend_setter_mode = "false",
			backend_direct_successor = true,
			backend_direct_successor_target = "mlx",
			runtime_backend = "api",
		})
		helpers.assert_eq(action, nil)
		helpers.assert_eq(calls.nested_backend_result(), true)
		helpers.assert_eq(calls.backend_setters, 2,
			"the stale predecessor must not issue a third setter call over Core B")
		helpers.assert_eq(calls.runtime_backend(), "mlx")
		helpers.assert_eq(calls.models_constructed or 0, 0)
	end)

	helpers.it("HS-012 refuses a reentrant backend factory before stale rollback can clobber it", function()
		local action, _, calls = build_fixture("ollama", {true}, {
			backend_setter_mode = "false",
			backend_reenter = true,
			backend_reenter_target = "mlx",
			runtime_backend = "api",
		})
		helpers.assert_eq(action, nil)
		helpers.assert_eq(calls.backend_setters, 2,
			"only the outer candidate and its exact predecessor compensation may reach Core")
		helpers.assert_eq(calls.runtime_backend(), "api")
		local nested = calls.nested_factory_result()
		helpers.assert_type(nested, "table")
		helpers.assert_eq(nested.build_item, nil,
			"the nested successor must fail closed while the predecessor callback is on-stack")
		helpers.assert_eq(calls.models_constructed or 0, 0,
			"neither refused factory may construct a model manager")
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 compensates No Model setter " .. mode .. " before successors", function()
			local action, state, calls = build_fixture("ollama", {true}, {
				model = "",
				no_model_setter_mode = mode,
				runtime_model = "old-runtime",
				runtime_backend = "api",
			})
			helpers.assert_eq(action, nil)
			helpers.assert_eq(state.llm_model, "")
			helpers.assert_eq(calls.runtime_models, {"", "old-runtime"})
			helpers.assert_eq(calls.runtime_model(), "old-runtime")
			helpers.assert_eq(calls.runtime_backend(), "api")
			helpers.assert_eq(calls.backend_setters, 2)
			helpers.assert_eq(calls.models_constructed, 1)
			helpers.assert_eq(calls.settings_constructed or 0, 0)
			helpers.assert_eq(calls.switchers_constructed or 0, 0)
			helpers.assert_eq(#calls.display_models, 0)
			helpers.assert_eq(calls.power_resolutions or 0, 0)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("HS-012 compensates startup identities after profile constructor "
			.. mode, function()
			local action, _, calls = build_fixture("ollama", {true}, {
				profile_constructor_mode = mode,
				runtime_backend = "api",
				runtime_model = "old-runtime",
			})
			helpers.assert_eq(action, nil)
			helpers.assert_eq(calls.profiles_constructed, 1)
			helpers.assert_eq(calls.runtime_model(), "old-runtime")
			helpers.assert_eq(calls.model_setters, 2)
			helpers.assert_eq(calls.runtime_backend(), "api")
			helpers.assert_eq(calls.backend_setters, 2)
			helpers.assert_eq(calls.runtime_display_model(), "old-display",
				"a refused initial profile identity must preserve the displayed predecessor")
			for _, displayed_model in ipairs(calls.display_models) do
				helpers.assert_eq(displayed_model, "old-display",
					"only exact predecessor compensation may reach the display boundary")
			end
		end)
	end

	helpers.it("HS-034 forwards the live candidate recovery owner through the real factory", function()
		local candidate_calls = 0
		local _, _, calls = build_fixture("ollama", {}, {
			candidate_recovery_gate = function()
				candidate_calls = candidate_calls + 1
				return false
			end,
		})
		helpers.assert_type(calls.switcher_ctx.profile_mutation_gate, "function")
		helpers.assert_eq(calls.switcher_ctx.profile_mutation_gate(), false)
		helpers.assert_eq(candidate_calls, 1)

		calls.profile_deps.settle_profile_candidate_recovery = function()
			error("dynamic candidate gate", 0)
		end
		local throw_ok, throw_error = pcall(calls.switcher_ctx.profile_mutation_gate)
		helpers.assert_eq(throw_ok, false)
		helpers.assert_true(tostring(throw_error):find("dynamic candidate gate", 1, true) ~= nil)

		calls.profile_deps.settle_profile_candidate_recovery = function() return true end
		helpers.assert_eq(calls.switcher_ctx.profile_mutation_gate(), true)
	end)

	helpers.it("HS-034 wires the live candidate gate to real switch and No Model entrypoints", function()
		local candidate_calls = 0
		local gate_result = false
		local _, _, calls = build_fixture("ollama", {}, {
			real_switcher = true,
			candidate_recovery_gate = function()
				candidate_calls = candidate_calls + 1
				return gate_result
			end,
		})
		local selector = calls.models_selector_ctx
		helpers.assert_type(selector and selector.switch_model, "function")
		helpers.assert_type(selector and selector.disable_model, "function")
		local runtime_before = #calls.runtime_models
		local display_before = #calls.display_models

		helpers.assert_eq(selector.switch_model("replacement"), false)
		helpers.assert_eq(selector.disable_model(), false)
		helpers.assert_eq(candidate_calls, 2)
		helpers.assert_eq(calls.requirements, 0)
		helpers.assert_eq(#calls.runtime_models, runtime_before)
		helpers.assert_eq(#calls.display_models, display_before)
		helpers.assert_eq(calls.saves, 0)
		helpers.assert_eq(calls.updates, 0)
	end)

	helpers.it("HS-034 rechecks the live factory gate at a real pending-model continuation", function()
		local gate_result = true
		local _, state, calls = build_fixture("ollama", {}, {
			real_switcher = true,
			candidate_recovery_gate = function() return gate_result end,
		})
		local selector = calls.models_selector_ctx
		local runtime_before = #calls.runtime_models
		local display_before = #calls.display_models
		helpers.assert_eq(selector.switch_model("replacement"), true)
		helpers.assert_eq(calls.requirements, 1)
		helpers.assert_type(calls.requirements_ok, "function")

		gate_result = false
		helpers.assert_eq(calls.requirements_ok(), false)
		helpers.assert_eq(state.llm_model, "candidate-model")
		helpers.assert_eq(#calls.runtime_models, runtime_before)
		helpers.assert_eq(#calls.display_models, display_before)
		helpers.assert_eq(calls.saves, 0)
		helpers.assert_eq(calls.updates, 0)
	end)

	helpers.it("HS-033 wires both recovery owners through the real MenuLLM factory", function()
		local false_calls = 0
		local _, _, calls = build_fixture("ollama", {}, {
			delete_recovery_gate = function()
				false_calls = false_calls + 1
				return false
			end,
		})
		helpers.assert_true(calls.profile_deps == calls.root_deps,
			"ProfilesManager must receive the exact shared dependency table")
		helpers.assert_type(calls.switcher_ctx.profile_mutation_gate, "function")
		helpers.assert_eq(calls.switcher_ctx.profile_mutation_gate(), false)
		helpers.assert_eq(false_calls, 1)

		local throwing_gate = function() error("dynamic Delete gate", 0) end
		calls.profile_deps.settle_profile_delete_recovery = throwing_gate
		local throw_ok, throw_error = pcall(calls.switcher_ctx.profile_mutation_gate)
		helpers.assert_eq(throw_ok, false)
		helpers.assert_true(tostring(throw_error):find("dynamic Delete gate", 1, true) ~= nil)

		local true_calls = 0
		local true_gate = function()
			true_calls = true_calls + 1
			return true
		end
		calls.profile_deps.settle_profile_delete_recovery = true_gate
		helpers.assert_eq(calls.switcher_ctx.profile_mutation_gate(), true)
		helpers.assert_eq(true_calls, 1,
			"the forwarding closure must read the live callback after construction")
		helpers.assert_true(calls.profile_deps.settle_llm_switcher_recovery
			== calls.switcher_settlement,
			"ProfilesManager must receive the exact ModelSwitcher settlement owner")
	end)

	helpers.it("HS-031 propagates the recommended-profile result through the menu adapter", function()
		local _, _, calls = build_fixture("ollama", {}, {recommendation_result = false})
		helpers.assert_type(calls.profile_deps, "table")
		helpers.assert_type(calls.profile_deps.apply_recommended_prompt_profile, "function")
		helpers.assert_eq(calls.profile_deps.apply_recommended_prompt_profile({force_dialog = true}), false)
	end)

	helpers.it("(no-model-runtime) reapplies a persisted No Model identity after reload", function()
		local _, state, calls = build_fixture("ollama", {}, { model = "" })
		helpers.assert_eq(state.llm_model, "")
		helpers.assert_eq(calls.runtime_models, { "" },
			"startup must override the prediction engine's backend default")
		helpers.assert_eq(calls.display_models, { "" })
	end)

	helpers.it("keeps Ollama inert when the writer returns false", function()
		assert_rejected_activation("ollama")
	end)

	helpers.it("keeps MLX inert when the writer returns false", function()
		assert_rejected_activation("mlx")
	end)

	helpers.it("compensates a committed MLX enable when bootstrap fails", function()
		local action, state, calls = build_fixture("mlx", { true, true })
		action()
		helpers.assert_eq(state.llm_enabled, true)
		helpers.assert_eq(calls.saves, 1,
			"the enabled candidate must be durable before MLX setup starts")
		helpers.assert_eq(calls.bootstrap, 1)
		helpers.assert_type(calls.bootstrap_callback, "function")
		helpers.assert_eq(calls.notifications, 0,
			"activation success must wait for the asynchronous prerequisite")

		calls.bootstrap_callback(false)

		helpers.assert_eq(state.llm_enabled, false,
			"failed MLX setup must restore the disabled preference")
		helpers.assert_eq(calls.saves, 2,
			"failed MLX setup must durably compensate the earlier enable")
		helpers.assert_eq(calls.keymap_states, { true, false })
		helpers.assert_eq(calls.requirements, 0)
		helpers.assert_eq(calls.notifications, 0)
	end)

	helpers.it("fails closed when the compensating MLX disable cannot commit", function()
		local action, state, calls = build_fixture("mlx", { true, false })
		action()
		calls.bootstrap_callback(false)

		helpers.assert_eq(state.llm_enabled, true,
			"rollback of a rejected compensation must restore the last durable enabled state")
		helpers.assert_eq(calls.last_attempted_enabled(), false,
			"the callback must still attempt the compensating disable")
		helpers.assert_eq(calls.saves, 2)
		helpers.assert_eq(calls.notifications, 0,
			"a backend that failed bootstrap must never announce activation success")
		helpers.assert_eq(calls.requirements, 0)
	end)

	helpers.it("discards an MLX completion after a sibling backend switch", function()
		local action, state, calls = build_fixture("mlx", { true })
		action()
		helpers.assert_eq(calls.bootstrap, 1)

		state.llm_backend = "api"
		calls.bootstrap_callback(true)

		helpers.assert_eq(calls.requirements, 0,
			"an MLX callback must not start requirements under the replacement backend")
		helpers.assert_eq(calls.notifications, 0,
			"an MLX callback must not announce success after its backend was replaced")
		helpers.assert_eq(calls.updates, 0,
			"the stale callback must not publish its obsolete activation result")
	end)

	helpers.it("contains a directly raised MLX bootstrap and compensates the enable", function()
		local action, state, calls = build_fixture("mlx", { true, true }, {
			bootstrap_throw = true,
		})
		action()
		helpers.assert_eq(state.llm_enabled, false)
		helpers.assert_eq(calls.saves, 2)
		helpers.assert_eq(calls.keymap_states, { true, false })
		helpers.assert_eq(calls.requirements, 0)
		helpers.assert_eq(calls.notifications, 0)
	end)

	helpers.it("contains a directly raised requirements dispatch and compensates Ollama", function()
		local action, state, calls = build_fixture("ollama", { true, true }, {
			requirements_throw = true,
		})
		action()
		helpers.assert_eq(state.llm_enabled, false)
		helpers.assert_eq(calls.saves, 2)
		helpers.assert_eq(calls.keymap_states, { true, false })
		helpers.assert_eq(calls.requirements, 1)
		helpers.assert_eq(calls.notifications, 0)
	end)

	helpers.it("fails closed before persistence when the keymap enable setter raises", function()
		local action, state, calls = build_fixture("ollama", { true }, {
			keymap_throw_on = true,
		})
		action()
		helpers.assert_eq(state.llm_enabled, false)
		helpers.assert_eq(calls.saves, 0,
			"a candidate whose runtime could not apply must never be persisted")
		helpers.assert_eq(calls.bootstrap, 0)
		helpers.assert_eq(calls.requirements, 0)
		helpers.assert_eq(calls.notifications, 0)
	end)

	helpers.it("settles an MLX activation exactly once when the checker callbacks twice", function()
		local action, state, calls = build_fixture("mlx", { true }, {
			bootstrap_double_success = true,
		})
		action()
		helpers.assert_eq(state.llm_enabled, true)
		helpers.assert_eq(calls.saves, 1)
		helpers.assert_eq(calls.requirements, 1,
			"a duplicate success callback must not start requirements twice")
		helpers.assert_eq(calls.notifications, 1,
			"a duplicate success callback must not announce activation twice")
		helpers.assert_eq(calls.updates, 1,
			"a duplicate success callback must not repaint twice")
	end)

	helpers.it("does not compensate twice when the checker callbacks then raises", function()
		local action, state, calls = build_fixture("mlx", { true, true }, {
			bootstrap_fail_then_throw = true,
		})
		action()
		helpers.assert_eq(state.llm_enabled, false)
		helpers.assert_eq(calls.saves, 2,
			"callback(false) followed by throw must perform one compensating save")
		helpers.assert_eq(calls.keymap_states, { true, false })
		helpers.assert_eq(calls.requirements, 0)
		helpers.assert_eq(calls.notifications, 0)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("buffers synchronous requirements success until dispatch " .. mode
			.. " settles", function()
			local options = { requirements_sync_success = true }
			if mode == "throw" then
				options.requirements_throw = true
			else
				options.requirements_mode = mode
			end
			local action, state, calls = build_fixture("ollama", { true, true }, options)

			helpers.assert_eq(action(), false)
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(calls.saves, 2)
			helpers.assert_eq(calls.keymap_states, { true, false })
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_eq(calls.notifications, 0,
				"a synchronous terminal cannot publish before literal dispatch acceptance")
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("requires exact Ollama dependency settlement after " .. mode, function()
			local options = {}
			if mode == "throw" then
				options.ollama_bootstrap_throw = true
			else
				options.ollama_bootstrap_return = mode == "false" and false or "nil"
			end
			local action, state, calls = build_fixture("ollama", { true, true }, options)

			helpers.assert_eq(action(), false)
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(calls.saves, 2)
			helpers.assert_eq(calls.requirements, 0)
			helpers.assert_eq(calls.notifications, 0)
		end)
	end

	helpers.it("stages an MLX bootstrap continuation until real ScriptControl commits RESUMED", function()
		local action, state, calls = build_fixture("mlx", { true }, {
			real_script_control = true,
		})
		local script_control = calls.script_control
		helpers.assert_eq(action(), true)
		local bootstrap_callback = calls.bootstrap_callback

		helpers.assert_eq(script_control.pause_all(), true)
		helpers.assert_eq(script_control.is_paused(), true)
		helpers.assert_eq(bootstrap_callback(true), true)
		helpers.assert_eq(calls.requirements, 0,
			"the bootstrap terminal must be retained while activation is fenced")

		helpers.assert_eq(script_control.resume_all(), true)
		helpers.assert_eq(script_control.is_paused(), false)
		helpers.assert_eq(#calls.resume_timers, 1)
		local committed_stage = calls.resume_timers[1]
		committed_stage.timer = nil
		committed_stage.callback()
		helpers.assert_eq(calls.requirements, 1)
		helpers.assert_type(calls.requirements_opts.is_current, "function")
		helpers.assert_eq(calls.requirements_opts.is_current(), true)
		helpers.assert_eq(calls.notifications, 1)
		helpers.assert_eq(committed_stage.callback(), nil)
		helpers.assert_eq(calls.requirements, 1,
			"a duplicate post-commit stage cannot dispatch a sibling")
		helpers.assert_eq(state.llm_enabled, true)
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains the exact activation stage when rollback cancel returns "
			.. mode, function()
			local action, _, calls = build_fixture("mlx", { true }, {
				real_script_control = true,
			})
			local script_control = calls.script_control
			local resume_failures = 1
			helpers.assert_eq(script_control.register_pause_owner("llm_model_switcher", {
				pause = function() return true end,
				resume = function()
					if resume_failures == 0 then return true end
					resume_failures = resume_failures - 1
					if mode == "throw" then error("later resume owner exploded") end
					if mode == "false" then return false end
					return nil
				end,
			}), true)
			helpers.assert_eq(action(), true)
			helpers.assert_eq(script_control.pause_all(), true)
			calls.bootstrap_callback(true)

			calls.set_timer_cancel_mode(mode)
			helpers.assert_eq(script_control.resume_all(), false)
			helpers.assert_eq(script_control.is_paused(), true)
			local retained_stage = calls.resume_timers[1]
			helpers.assert_eq(calls.timer_cancel_handles[1], retained_stage)
			retained_stage.callback()
			helpers.assert_eq(calls.requirements, 0)

			calls.set_timer_cancel_mode("true")
			helpers.assert_eq(script_control.resume_all(), true)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(calls.timer_cancel_handles[#calls.timer_cancel_handles],
				retained_stage, "resume retry must settle the same timer handle")
			helpers.assert_eq(#calls.resume_timers, 2)
			local successor = calls.resume_timers[2]
			successor.timer = nil
			successor.callback()
			helpers.assert_eq(calls.requirements, 1)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("replays a requirements success after a later pause owner " .. mode, function()
			local action, state, calls = build_fixture("ollama", { true, true, true }, {
				real_script_control = true,
			})
			local script_control = calls.script_control
			helpers.assert_eq(action(), true)
			helpers.assert_eq(calls.requirements, 1)
			helpers.assert_eq(calls.notifications, 1)

			helpers.assert_eq(script_control.register_pause_owner("llm_model_switcher", {
				pause = function()
					calls.requirements_ok()
					if mode == "throw" then error("later pause owner exploded") end
					if mode == "false" then return false end
					return nil
				end,
				resume = function() return true end,
			}), true)
			helpers.assert_eq(script_control.pause_all(), true,
				"the synchronous drain accepts the request before local rollback reports failure")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(calls.requirements, 1,
				"the manager's consumed success may not be redispatched")
			helpers.assert_eq(calls.requirements_ok(), false,
				"the retained terminal must remain one-shot after rollback")

			helpers.assert_eq(action(), true)
			helpers.assert_eq(state.llm_enabled, false)
			helpers.assert_eq(action(), true,
				"the completed activation token must not block the next enable")
			helpers.assert_eq(calls.requirements, 2)
		end)
	end

	helpers.it("settles a token superseded by Disable All before the next enable", function()
		local action, state, calls = build_fixture("mlx", { true, true })
		helpers.assert_eq(action(), true)
		local stale_bootstrap = calls.bootstrap_callback
		state.llm_enabled = false
		helpers.assert_eq(calls.handler.set_llm_preference_runtime(false), true)
		helpers.assert_eq(calls.get_runtime_enabled(), false)
		helpers.assert_eq(stale_bootstrap(true), true)
		helpers.assert_eq(calls.requirements, 0)
		helpers.assert_eq(calls.notifications, 0)

		helpers.assert_eq(action(), true,
			"a shared disable must not leave an activation token that rejects begin")
		helpers.assert_eq(calls.bootstrap, 2)
		local replacement_bootstrap = calls.bootstrap_callback
		helpers.assert_true(replacement_bootstrap ~= stale_bootstrap)
		helpers.assert_eq(replacement_bootstrap(true), true)
		helpers.assert_eq(calls.requirements, 1)
		helpers.assert_eq(calls.notifications, 1)
		helpers.assert_eq(state.llm_enabled, true)
	end)
end)

return true
