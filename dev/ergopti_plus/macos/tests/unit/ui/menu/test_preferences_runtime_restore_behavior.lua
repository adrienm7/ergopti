--- tests/unit/ui/menu/test_preferences_runtime_restore_behavior.lua

--- ==============================================================================
--- MODULE: Preference Runtime Restore Behavioral Regression
--- DESCRIPTION:
--- Runs a rejected transaction through the real rollback and menu-state sync to
--- prove backend labels, ChatGPT URL, and a disabled editor shortcut are restored.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu preference rollback: restore runtime-owned values", function()
	helpers.it("restores backend labels, ChatGPT URL, and a disabled editor shortcut", function()
		helpers.load_with_stubs("infra.logger")
		local noop = function() end
		package.loaded["infra.logger"] = {
			debug = noop, info = noop, warn = noop, error = noop,
		}
		package.loaded["ui.menu.keymap_lifecycle"] = {
			ensure_started = function() return true end,
		}
		package.loaded["modules.keylogger.text_cipher"] = { set_enabled = noop }
		package.loaded["ui.menu.preferences_transaction"] = nil
		package.loaded["ui.menu.menu_state"] = nil
		local Transaction = require("ui.menu.preferences_transaction")
		local MenuState = require("ui.menu.menu_state")

		local state = {
			hotstrings = {},
			keymap = false,
			shortcuts = false,
			llm_backend = "mlx",
			llm_model = "committed-display-model",
			chatgpt_url = "https://committed.example.test/",
			custom_editor_shortcut = false,
			keylogger_enabled = false,
			keylogger_encrypt = false,
		}
		local observed = {
			core_backends = {},
			backend_labels = {},
			display_labels = {},
			chatgpt_urls = {},
			editor_clears = 0,
			editor_sets = 0,
		}
		local deps = {
			keymap = {
				set_llm_backend_name = function(value)
					observed.backend_labels[#observed.backend_labels + 1] = value
				end,
				set_llm_display_model_name = function(value)
					observed.display_labels[#observed.display_labels + 1] = value
				end,
			},
			hotstring_editor = {
				clear_shortcut = function() observed.editor_clears = observed.editor_clears + 1 end,
				set_shortcut = function() observed.editor_sets = observed.editor_sets + 1 end,
			},
			core_mods = {
				llm = {
					set_backend = function(value)
						observed.core_backends[#observed.core_backends + 1] = value
					end,
				},
				shortcuts_mod = {
					pause_bindings = function() return true end,
					set_chatgpt_url = function(value)
						observed.chatgpt_urls[#observed.chatgpt_urls + 1] = value
					end,
				},
			},
			apply_metrics_shortcut = function() return true end,
			apply_apps_time_shortcut = function() return true end,
			save_prefs = function() return true end,
		}

		local save = Transaction.bind({
			save = function() return false end,
		}, {
			path = "/virtual/config.toml",
			state = state,
			hotfiles = {},
			core_modules = deps.core_mods,
			initial_state = state,
			initial_preferences = state,
			restore_runtime = function(snapshot)
				return MenuState.sync_state_to_modules(state, snapshot, false, deps)
			end,
		})

		state.llm_backend = "api"
		state.llm_model = "rejected-display-model"
		state.chatgpt_url = "https://rejected.example.test/"
		state.custom_editor_shortcut = { mods = { "cmd" }, key = "x" }

		helpers.assert_eq(save(), false)
		helpers.assert_eq(state.llm_backend, "mlx")
		helpers.assert_eq(state.llm_model, "committed-display-model")
		helpers.assert_eq(state.chatgpt_url, "https://committed.example.test/")
		helpers.assert_eq(state.custom_editor_shortcut, false)
		helpers.assert_eq(observed.core_backends, { "mlx" },
			"rollback must restore the core LLM backend before downstream setters")
		helpers.assert_eq(observed.backend_labels, { "MLX 🚀" },
			"rollback must restore the backend's display label")
		helpers.assert_eq(observed.display_labels, { "committed-display-model" },
			"rollback must restore the committed model display label")
		helpers.assert_eq(observed.chatgpt_urls, { "https://committed.example.test/" },
			"rollback must restore the live Ctrl+G target")
		helpers.assert_eq(observed.editor_clears, 1,
			"a committed false editor shortcut must clear the rejected live binding")
		helpers.assert_eq(observed.editor_sets, 0,
			"rollback must not recreate a shortcut whose committed value is false")
	end)
end)

return true
