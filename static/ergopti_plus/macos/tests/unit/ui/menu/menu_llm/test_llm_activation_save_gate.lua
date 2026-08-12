--- tests/unit/ui/menu/menu_llm/test_llm_activation_save_gate.lua

--- ==============================================================================
--- MODULE: LLM Activation Preference Gate Regression
--- DESCRIPTION:
--- Drives the real top-level LLM menu callback and proves a rejected preference
--- publication cannot launch backend setup, requirements, or user notifications.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("LLM activation: external work waits for preference commit", function()
	helpers.it("does not bootstrap or check requirements when the writer returns false", function()
		local noop = function() end
		local calls = { bootstrap = 0, requirements = 0, notifications = 0, updates = 0 }
		local state = {
			llm_enabled = false,
			llm_backend = "ollama",
			llm_model = "candidate-model",
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
			end,
		}
		package.loaded["ui.menu.menu_llm.models_manager"] = {
			new = function() return models end,
		}
		package.loaded["ui.menu.menu_llm.profiles_manager"] = {
			new = function()
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
			new = function()
				return {
					switch_model = noop,
					set_llm_profile = noop,
					apply_recommended_prompt_profile = noop,
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
		package.loaded["modules.llm.mlx_deps_checker"] = { check_and_install_deps = noop }
		package.loaded["modules.llm.ollama_deps_checker"] = {
			check_and_install_deps = function()
				calls.bootstrap = calls.bootstrap + 1
			end,
		}

		package.loaded["ui.menu.menu_llm"] = nil
		local MenuLLM = require("ui.menu.menu_llm")
		local handler = MenuLLM.create({
			state = state,
			keymap = { set_llm_enabled = noop },
			save_prefs = function()
				-- Mirrors the production transaction's in-place rollback.
				state.llm_enabled = false
				return false
			end,
			update_menu = function() calls.updates = calls.updates + 1 end,
			active_tasks = {},
		})
		local item = handler.build_item()
		helpers.assert_type(item.action, "function")

		item.action()

		helpers.assert_eq(state.llm_enabled, false)
		helpers.assert_eq(calls.bootstrap, 0,
			"a rejected activation must not start backend dependency setup")
		helpers.assert_eq(calls.requirements, 0,
			"a rejected activation must not start model requirements")
		helpers.assert_eq(calls.notifications, 0,
			"a rejected activation must not announce success")
		helpers.assert_eq(calls.updates, 0,
			"a rejected activation must not publish an enabled menu")
	end)
end)

return true
