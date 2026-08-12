--- tests/unit/ui/menu/menu_llm/test_backend_panel_save_gate.lua

--- ==============================================================================
--- MODULE: Backend Panel Preference Gate Regression
--- DESCRIPTION:
--- Drives all three real backend menu actions and proves a rejected preference
--- write cannot start, stop, warm, kill, or switch any backend resource.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("backend panel: external effects wait for preference commit", function()
	helpers.it("keeps MLX, Ollama, and API external effects at zero on writer false", function()
		local noop = function() end
		local effects = {
			deps = 0,
			stops = 0,
			executes = 0,
			warmups = 0,
			model_switches = 0,
			backend_setters = 0,
		}

		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_model_mlx = "mlx-default", llm_model_ollama = "ollama-default" },
			set_backend = function() effects.backend_setters = effects.backend_setters + 1 end,
			load_api_entries = noop,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.logger"] = {
			debug = noop, info = noop, warn = noop, error = noop,
		}
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
		}
		package.loaded["modules.llm.mlx_deps_checker"] = {
			check_and_install_deps = function() effects.deps = effects.deps + 1 end,
		}
		package.loaded["modules.llm.ollama_deps_checker"] = {
			check_and_install_deps = function() effects.deps = effects.deps + 1 end,
		}
		package.loaded["modules.llm.api_mlx"] = { get_port = function() return 3460 end }

		local previous_execute = os.execute
		os.execute = function()
			effects.executes = effects.executes + 1
			return true
		end
		local previous_hs_execute = hs.execute
		hs.execute = function() return "arm64" end

		package.loaded["ui.menu.menu_llm.backend_panel"] = nil
		local BackendPanel = require("ui.menu.menu_llm.backend_panel")
		local cases = {
			{ target = "mlx", current = "ollama", index = 1 },
			{ target = "ollama", current = "mlx", index = 2 },
			{ target = "api", current = "mlx", index = 3 },
		}
		local action_errors = {}
		local state_errors = {}
		for _, case in ipairs(cases) do
			local state = {
				llm_backend = case.current,
				llm_model = "current-model",
				llm_model_mlx = "mlx-model",
				llm_model_ollama = "ollama-model",
			}
			local models = {
				stop_mlx_server_if_needed = function() effects.stops = effects.stops + 1 end,
			}
			local _, rows = BackendPanel.build({
				state = state,
				keymap = {},
				paused = false,
				models_mgr = models,
				get_display_model_name = function(name) return name end,
				switch_model = function() effects.model_switches = effects.model_switches + 1 end,
				save_prefs = function()
					-- Mirrors the production transaction's state rollback.
					state.llm_backend = case.current
					return false
				end,
				update_menu = noop,
				WarmupCtrl = {
					warmup = function() effects.warmups = effects.warmups + 1 end,
				},
				reset_llm_health_status = noop,
			})
			local action = rows[case.index] and rows[case.index].action
			if type(action) ~= "function" then
				action_errors[#action_errors + 1] = case.target .. " action missing"
			else
				local ok, err = pcall(action)
				if not ok then action_errors[#action_errors + 1] = case.target .. ": " .. tostring(err) end
			end
			if state.llm_backend ~= case.current then
				state_errors[#state_errors + 1] = case.target
			end
		end

		os.execute = previous_execute
		hs.execute = previous_hs_execute

		helpers.assert_eq(action_errors, {}, "every backend callback must execute in the fixture")
		helpers.assert_eq(state_errors, {}, "every rejected backend choice must be rolled back")
		helpers.assert_eq(effects.deps, 0, "no backend dependency bootstrap may start")
		helpers.assert_eq(effects.stops, 0, "no local backend may be stopped")
		helpers.assert_eq(effects.executes, 0, "no process kill command may run")
		helpers.assert_eq(effects.warmups, 0, "no API warmup may start")
		helpers.assert_eq(effects.model_switches, 0, "no model switch may start")
		helpers.assert_eq(effects.backend_setters, 0, "the live backend must remain unchanged")
	end)
end)

return true
