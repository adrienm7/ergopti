--- tests/unit/ui/menu/menu_llm/test_model_switcher_backend_guard.lua

--- ==============================================================================
--- MODULE: Model Switch Backend Generation Guard Regression
--- DESCRIPTION:
--- Proves that a requirements callback captured for one backend cannot commit a
--- model after a sibling backend action has selected another backend.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("model switcher: backend changes invalidate pending requirements", function()
	helpers.it("discards a model callback after the backend changes without another model switch", function()
		local noop = function() end
		local pending_ok = nil
		local saves = 0
		local menu_updates = 0
		local model_setters = 0
		local prediction_states = {}

		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_num_predictions = 1 },
			set_active_profile = noop,
			set_llm_model_mlx = function() model_setters = model_setters + 1 end,
			set_llm_model_ollama = function() model_setters = model_setters + 1 end,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil

		local state = {
			llm_backend = "mlx",
			llm_enabled = true,
			llm_active_profile = "basic",
			llm_model = "old-model",
			llm_model_mlx = "old-model",
		}
		local models = {
			check_requirements = function(_, on_ok)
				pending_ok = on_ok
			end,
			get_presets = function() return {} end,
			get_model_info = function() return {} end,
			get_actual_model_name = function(name) return name end,
		}
		local switcher = require("ui.menu.menu_llm.model_switcher").new({
			state = state,
			models_mgr = models,
			keymap = {
				set_llm_enabled = function(enabled)
					prediction_states[#prediction_states + 1] = enabled
				end,
			},
			save_prefs = function()
				saves = saves + 1
				return true
			end,
			update_menu = function() menu_updates = menu_updates + 1 end,
		})

		switcher.switch_model("candidate-model")
		helpers.assert_type(pending_ok, "function",
			"switch_model must expose the pending requirements completion")

		-- A backend-menu action is a sibling operation: it does not initiate a
		-- second model switch, so the model request token alone cannot see it.
		state.llm_backend = "api"
		pending_ok()

		helpers.assert_eq(state.llm_model, "old-model",
			"a callback captured for MLX must not commit into the API backend")
		helpers.assert_eq(state.llm_model_mlx, "old-model",
			"the stale callback must not rewrite a per-backend model slot")
		helpers.assert_eq(model_setters, 0,
			"the stale callback must not mutate the core LLM model")
		helpers.assert_eq(saves, 0,
			"the stale callback must not publish a sibling backend transaction")
		helpers.assert_eq(menu_updates, 0,
			"the stale callback must not render a model that was never committed")
		helpers.assert_eq(prediction_states, { false, true },
			"discarding the abandoned MLX switch must release its prediction lock")
	end)

	helpers.it("(deferred-runtime-gate) does not restore a captured enabled state after the user disables LLM", function()
		local noop = function() end
		local pending_ok
		local prediction_states = {}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_num_predictions = 1 },
			set_active_profile = noop,
			set_llm_model_mlx = noop,
			set_llm_model_ollama = noop,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil

		local state = {
			llm_backend = "mlx",
			llm_enabled = true,
			llm_active_profile = "basic",
			llm_model = "old-model",
			llm_model_mlx = "old-model",
		}
		local switcher = require("ui.menu.menu_llm.model_switcher").new({
			state = state,
			models_mgr = {
				check_requirements = function(_, on_ok) pending_ok = on_ok end,
				get_presets = function() return {} end,
				get_model_info = function() return {} end,
				get_actual_model_name = function(name) return name end,
			},
			keymap = {
				set_llm_enabled = function(enabled)
					prediction_states[#prediction_states + 1] = enabled
				end,
				set_llm_model = noop,
				set_llm_display_model_name = noop,
			},
			save_prefs = function() return true end,
			update_menu = noop,
		})

		switcher.switch_model("candidate-model")
		helpers.assert_eq(prediction_states, { false },
			"MLX switch must really lock predictions before the interleaving")
		state.llm_enabled = false
		pending_ok()
		helpers.assert_eq(prediction_states, { false },
			"completion must not override the user's newer disabled choice")
	end)

	helpers.it("(deferred-runtime-gate) does not unlock predictions after pause closes the runtime gate", function()
		local noop = function() end
		local pending_ok
		local runtime_available = true
		local prediction_states = {}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_num_predictions = 1 },
			set_active_profile = noop,
			set_llm_model_mlx = noop,
			set_llm_model_ollama = noop,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil

		local state = {
			llm_backend = "mlx", llm_enabled = true,
			llm_active_profile = "basic", llm_model = "old-model",
		}
		local switcher = require("ui.menu.menu_llm.model_switcher").new({
			state = state,
			models_mgr = {
				check_requirements = function(_, on_ok) pending_ok = on_ok end,
				get_presets = function() return {} end,
				get_model_info = function() return {} end,
				get_actual_model_name = function(name) return name end,
			},
			keymap = {
				set_llm_enabled = function(enabled)
					prediction_states[#prediction_states + 1] = enabled
				end,
				set_llm_model = noop,
				set_llm_display_model_name = noop,
			},
			runtime_gate = function() return runtime_available end,
			save_prefs = function() return true end,
			update_menu = noop,
		})

		switcher.switch_model("candidate-model")
		runtime_available = false
		pending_ok()
		helpers.assert_eq(prediction_states, { false },
			"a completion arriving during pause cannot reopen the prediction engine")
	end)

	helpers.it("(no-model-runtime) No Model clears runtime identity and invalidates a pending switch", function()
		local noop = function() end
		local pending_ok
		local runtime_models = {}
		local display_models = {}
		local saves, updates = 0, 0
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.dialog_util"] = { block_alert = function() return false end }
		package.loaded["infra.notifications"] = { notify = noop }
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_num_predictions = 1 },
			set_active_profile = noop,
			set_llm_model_mlx = noop,
			set_llm_model_ollama = noop,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil

		local state = {
			llm_backend = "ollama",
			llm_enabled = true,
			llm_active_profile = "basic",
			llm_model = "old-model",
			llm_model_power = 2,
			llm_model_ollama = "old-model",
		}
		local switcher = require("ui.menu.menu_llm.model_switcher").new({
			state = state,
			models_mgr = {
				check_requirements = function(_, on_ok) pending_ok = on_ok end,
				get_presets = function() return {} end,
				get_model_info = function() return {} end,
				get_actual_model_name = function(name) return "actual:" .. tostring(name) end,
			},
			keymap = {
				set_llm_enabled = noop,
				set_llm_model = function(model) runtime_models[#runtime_models + 1] = model end,
				set_llm_display_model_name = function(model) display_models[#display_models + 1] = model end,
			},
			save_prefs = function() saves = saves + 1; return true end,
			update_menu = function() updates = updates + 1 end,
		})

		switcher.switch_model("candidate-model")
		helpers.assert_eq(type(pending_ok), "function")
		helpers.assert_eq(switcher.disable_model(), true)
		pending_ok()
		helpers.assert_eq(state.llm_model, "")
		helpers.assert_eq(state.llm_model_power, nil)
		helpers.assert_eq(runtime_models, { "" })
		helpers.assert_eq(display_models, { "" })
		helpers.assert_eq(saves, 1)
		helpers.assert_eq(updates, 1,
			"the stale requirements callback must not publish its candidate")
	end)

	helpers.it("releases the MLX prediction lock when success cleanup throws (HS-016)", function()
		local noop = function() end
		local pending_ok
		local prediction_states = {}
		local errors = {}
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...)
			errors[#errors + 1] = string.format(message, ...)
		end
		logger.callback = function(_, label, fn, ...)
			local results = table.pack(xpcall(fn, debug.traceback, ...))
			if not results[1] then
				errors[#errors + 1] = "Callback '" .. tostring(label)
					.. "' raised: " .. tostring(results[2])
			end
			return table.unpack(results, 1, results.n)
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.dialog_util"] = {block_alert = function() return false end}
		package.loaded["infra.notifications"] = {notify = noop}
		package.loaded["ui.menu.menu_llm.profile_label"] = {
			format = function(label) return label end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {llm_num_predictions = 1},
			set_active_profile = noop,
			set_llm_model_mlx = noop,
			set_llm_model_ollama = noop,
		}
		package.loaded["ui.menu.menu_llm.model_switcher"] = nil

		local state = {
			llm_backend = "mlx", llm_enabled = true,
			llm_active_profile = "basic", llm_model = "old-model",
		}
		local switcher = require("ui.menu.menu_llm.model_switcher").new({
			state = state,
			models_mgr = {
				check_requirements = function(_, on_ok) pending_ok = on_ok end,
				get_presets = function() return {} end,
				get_model_info = function() return {} end,
				get_actual_model_name = function(name) return name end,
			},
			keymap = {
				set_llm_enabled = function(enabled)
					prediction_states[#prediction_states + 1] = enabled
				end,
				set_llm_model = noop,
				set_llm_display_model_name = noop,
			},
			save_prefs = function() return true end,
			update_menu = function() error("menu refresh exploded") end,
		})

		switcher.switch_model("candidate-model")
		local call_ok, callback_result = pcall(pending_ok)

		helpers.assert_true(call_ok,
			"the manager success continuation must contain its cleanup exception")
		helpers.assert_eq(callback_result, false,
			"a failed success continuation cannot publish a truthful success")
		helpers.assert_eq(prediction_states, {false, true},
			"prediction unlock is mandatory cleanup even after update_menu throws")
		helpers.assert_eq(#errors, 1)
		helpers.assert_contains(errors[1], "Model-switch menu refresh")
		helpers.assert_contains(errors[1], "menu refresh exploded")
		helpers.assert_contains(errors[1], "stack traceback")
	end)
end)

return true
