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
	}
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
	local committed_enabled = false
	local last_attempted_enabled = false

	package.loaded["infra.logger"] = {
		debug = noop, info = noop, warn = noop, error = noop,
	}
	package.loaded["infra.notifications"] = {
		notify = function() calls.notifications = calls.notifications + 1 end,
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
		set_backend = noop,
		set_llm_model_mlx = noop,
		set_llm_model_ollama = noop,
	}

	local models = {
		get_presets = function() return {} end,
		get_actual_model_name = function(name) return name end,
		get_model_info = function() return {} end,
		get_model_ram = function() return 0 end,
		check_requirements = function()
			calls.requirements = calls.requirements + 1
			if options.requirements_throw then error("requirements exploded") end
		end,
	}
	package.loaded["ui.menu.menu_llm.models_manager"] = { new = function() return models end }
	package.loaded["ui.menu.menu_llm.profiles_manager"] = {
		new = function(deps)
			calls.profile_deps = deps
			if type(options.delete_recovery_gate) == "function" then
				deps.settle_profile_delete_recovery = options.delete_recovery_gate
			end
			return { get_menu_item = function() return {} end }
		end,
	}
	package.loaded["ui.menu.menu_llm.settings_manager"] = {
		new = function()
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
	package.loaded["ui.menu.menu_llm.models_selector"] = { build = function() return {} end }
	package.loaded["ui.menu.menu_llm.model_switcher"] = {
		new = function(ctx)
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
				get_model_power_level = function() return 1 end,
				guarded_check_requirements = noop,
			}
		end,
	}
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
				return
			end
			if options.bootstrap_fail_then_throw then
				callback(false)
				error("bootstrap exploded after callback")
			end
			calls.bootstrap_callback = callback
		end,
	}
	package.loaded["modules.llm.ollama_deps_checker"] = {
		check_and_install_deps = function()
			calls.bootstrap = calls.bootstrap + 1
		end,
	}

	package.loaded["ui.menu.menu_llm"] = nil
	local MenuLLM = require("ui.menu.menu_llm")
	local deps = {
		state = state,
		keymap = {
			set_llm_enabled = function(value)
				calls.keymap_states[#calls.keymap_states + 1] = value
				if options.keymap_throw_on == value then error("keymap setter exploded") end
			end,
			set_llm_model = function(value)
				calls.runtime_models[#calls.runtime_models + 1] = value
			end,
			set_llm_display_model_name = function(value)
				calls.display_models[#calls.display_models + 1] = value
			end,
		},
		save_prefs = function()
			calls.saves = calls.saves + 1
			last_attempted_enabled = state.llm_enabled
			local result = save_results[calls.saves]
			if result == true then
				committed_enabled = state.llm_enabled
			else
				state.llm_enabled = committed_enabled
			end
			return result
		end,
		update_menu = function() calls.updates = calls.updates + 1 end,
		active_tasks = {},
	}
	calls.root_deps = deps
	local handler = MenuLLM.create(deps)
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
	helpers.assert_eq(calls.bootstrap, 0,
		"a rejected " .. backend .. " activation must not start dependency setup")
	helpers.assert_eq(calls.requirements, 0,
		"a rejected " .. backend .. " activation must not start model requirements")
	helpers.assert_eq(calls.notifications, 0,
		"a rejected " .. backend .. " activation must not announce success")
	helpers.assert_eq(calls.updates, 0,
		"a rejected " .. backend .. " activation must not publish an enabled menu")
end

helpers.describe("LLM activation: external work waits for preference commit", function()
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
end)

return true
