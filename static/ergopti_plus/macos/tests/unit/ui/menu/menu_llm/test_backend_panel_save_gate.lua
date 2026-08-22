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
		local runtime_backend = "ollama"

		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_model_mlx = "mlx-default", llm_model_ollama = "ollama-default" },
			get_backend = function() return runtime_backend end,
			set_backend = function(value)
				effects.backend_setters = effects.backend_setters + 1
				runtime_backend = value
				return true
			end,
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
			runtime_backend = case.current
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

	helpers.it("keeps MLX published until an accepted stop reaches its callback (HS-008)", function()
		for _, target in ipairs({ "ollama", "api" }) do
			for _, mode in ipairs({ "false", "nil", "throw", "accepted" }) do
				local noop = function() return true end
				local effects = { saves = 0, stops = 0, publishes = 0, executes = 0,
					warmups = 0, model_switches = 0 }
				local events = {}
				local pending_settlement
				local stop_kind
				local runtime_backend = "mlx"
				package.loaded["modules.llm"] = {
					DEFAULT_STATE = { llm_model_mlx = "mlx-default", llm_model_ollama = "ollama-default" },
					get_backend = function() return runtime_backend end,
					set_backend = function(value)
						runtime_backend = value
						effects.publishes = effects.publishes + 1
						events[#events + 1] = "publish"
						return true
					end,
					load_api_entries = noop,
				}
				package.loaded["infra.i18n"] = { get = function(key) return key end }
				package.loaded["infra.logger"] = {
					debug = noop, info = noop, warn = noop, error = noop,
				}
				package.loaded["infra.manifest_menu"] = {
					render_rows = function(rows) return rows end,
				}
				package.loaded["modules.llm.mlx_deps_checker"] = { check_and_install_deps = noop }
				package.loaded["modules.llm.ollama_deps_checker"] = { check_and_install_deps = noop }
				package.loaded["modules.llm.api_mlx"] = { get_port = function() return 3460 end }

				local previous_execute = os.execute
				local previous_hs_execute = hs.execute
				os.execute = function()
					effects.executes = effects.executes + 1
					return true
				end
				hs.execute = function() return "arm64" end
				package.loaded["ui.menu.menu_llm.backend_panel"] = nil
				local BackendPanel = require("ui.menu.menu_llm.backend_panel")
				local state = {
					llm_backend = "mlx",
					llm_model = "current-model",
					llm_model_mlx = "mlx-model",
					llm_model_ollama = "ollama-model",
				}
				local _, rows = BackendPanel.build({
					state = state,
					keymap = {set_llm_backend_name = function() return true end},
					paused = false,
					models_mgr = {
						stop_mlx_server_if_needed = function(callback, opts)
							effects.stops = effects.stops + 1
							stop_kind = type(opts) == "table" and opts.kind or nil
							if mode == "throw" then error("fixture stop failure") end
							if mode == "false" then return false end
							if mode == "nil" then return nil end
							pending_settlement = function()
								events[#events + 1] = "cleanup_proved"
								return callback()
							end
							return true
						end,
					},
					get_display_model_name = function(name) return name end,
					switch_model = function()
						effects.model_switches = effects.model_switches + 1
						return true
					end,
					disable_model = function() return true end,
					save_prefs = function()
						effects.saves = effects.saves + 1
						return true
					end,
					update_menu = noop,
					WarmupCtrl = { warmup = function()
						effects.warmups = effects.warmups + 1
						return true
					end },
					reset_llm_health_status = noop,
				})
				local action = rows[target == "ollama" and 2 or 3].action
				local accepted = action()
				os.execute = previous_execute
				hs.execute = previous_hs_execute

				if mode == "accepted" then
					helpers.assert_eq(accepted, true)
					helpers.assert_eq(stop_kind, "backend")
					helpers.assert_eq(state.llm_backend, "mlx",
						"signal acceptance cannot publish the successor backend")
					helpers.assert_eq(runtime_backend, target,
						"the strict core identity must be acquired before stopping MLX")
					helpers.assert_eq(effects.publishes, 1)
					helpers.assert_eq(effects.executes, 0)
					helpers.assert_eq(type(pending_settlement), "function")
					-- Reinstall the execute double while the deferred callback commits.
					os.execute = function()
						effects.executes = effects.executes + 1
						return true
					end
					pending_settlement()
					os.execute = previous_execute
					helpers.assert_eq(state.llm_backend, target)
					helpers.assert_eq(effects.publishes, 1)
					helpers.assert_eq(events[1], "publish",
						"core acquisition must precede the destructive server stop")
					helpers.assert_eq(events[2], "cleanup_proved")
				else
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(state.llm_backend, "mlx")
					helpers.assert_eq(runtime_backend, "mlx")
					helpers.assert_eq(effects.publishes, 2,
						"a refused stop must compensate its acquired core identity")
					helpers.assert_eq(effects.executes, 0)
					helpers.assert_eq(pending_settlement, nil)
				end
			end
		end
	end)

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rejects mutate-then-" .. mode
			.. " core backend publication before state, preferences, or health", function()
			local noop = function() return true end
			local state = {
				llm_backend = "ollama",
				llm_model = "current-model",
				llm_model_mlx = "mlx-model",
				llm_model_ollama = "ollama-model",
			}
			local runtime_backend = "ollama"
			local persisted_backend = "ollama"
			local setter_calls = 0
			local effects = {health = 0, warmups = 0, menus = 0, executes = 0}
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {
					llm_model_mlx = "mlx-default",
					llm_model_ollama = "ollama-default",
				},
				get_backend = function() return runtime_backend end,
				set_backend = function(value)
					setter_calls = setter_calls + 1
					runtime_backend = value
					if setter_calls == 1 then
						if mode == "throw" then error("injected backend refusal") end
						if mode == "nil" then return nil end
						return false
					end
					return true
				end,
				load_api_entries = noop,
			}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_menu"] = {
				render_rows = function(rows) return rows end,
			}
			package.loaded["modules.llm.mlx_deps_checker"] = {
				check_and_install_deps = noop,
			}
			package.loaded["modules.llm.ollama_deps_checker"] = {
				check_and_install_deps = noop,
			}

			local previous_execute = os.execute
			local previous_hs_execute = hs.execute
			os.execute = function()
				effects.executes = effects.executes + 1
				return true
			end
			hs.execute = function() return "arm64" end
			package.loaded["ui.menu.menu_llm.backend_panel"] = nil
			local BackendPanel = require("ui.menu.menu_llm.backend_panel")
			local _, rows = BackendPanel.build({
				state = state,
				keymap = {set_llm_backend_name = function() return true end},
				paused = false,
				models_mgr = {},
				get_display_model_name = function(name) return name end,
				switch_model = noop,
				save_prefs = function()
					persisted_backend = state.llm_backend
					return true
				end,
				update_menu = function()
					effects.menus = effects.menus + 1
					return true
				end,
				WarmupCtrl = {warmup = function()
					effects.warmups = effects.warmups + 1
					return true
				end},
				reset_llm_health_status = function()
					effects.health = effects.health + 1
					return true
				end,
			})
			local result = rows[3].action()
			os.execute = previous_execute
			hs.execute = previous_hs_execute

			helpers.assert_eq(result, false)
			helpers.assert_eq(state.llm_backend, "ollama")
			helpers.assert_eq(runtime_backend, "ollama")
			helpers.assert_eq(persisted_backend, "ollama")
			helpers.assert_eq(setter_calls, 2,
				"the mutate-then-refuse setter must be compensated exactly once")
			helpers.assert_eq(effects.health, 0)
			helpers.assert_eq(effects.warmups, 0)
			helpers.assert_eq(effects.menus, 0)
			helpers.assert_eq(effects.executes, 0)
		end)
	end

	for _, rollback_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains backend rollback debt after " .. rollback_mode
			.. " until an exact retry", function()
			local state = {
				llm_backend = "ollama",
				llm_model = "current-model",
				llm_model_mlx = "mlx-model",
				llm_model_ollama = "ollama-model",
			}
			local runtime_backend = "ollama"
			local persisted_backend = "ollama"
			local setter_calls = 0
			local save_calls = 0
			local health_calls = 0
			local warmups = 0
			local function refuse_rollback()
				if rollback_mode == "throw" then error("injected rollback refusal") end
				if rollback_mode == "nil" then return nil end
				return false
			end
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {
					llm_model_mlx = "mlx-default",
					llm_model_ollama = "ollama-default",
				},
				get_backend = function() return runtime_backend end,
				set_backend = function(value)
					setter_calls = setter_calls + 1
					runtime_backend = value
					if setter_calls == 1 then return false end
					if setter_calls == 2 or setter_calls == 3 then
						return refuse_rollback()
					end
					return true
				end,
				load_api_entries = function() return true end,
			}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_menu"] = {
				render_rows = function(rows) return rows end,
			}
			package.loaded["modules.llm.mlx_deps_checker"] = {
				check_and_install_deps = function() return true end,
			}
			package.loaded["modules.llm.ollama_deps_checker"] = {
				check_and_install_deps = function() return true end,
			}

			local previous_execute = os.execute
			local previous_hs_execute = hs.execute
			os.execute = function() return true end
			hs.execute = function() return "arm64" end
			package.loaded["ui.menu.menu_llm.backend_panel"] = nil
			local BackendPanel = require("ui.menu.menu_llm.backend_panel")
			local _, rows = BackendPanel.build({
				state = state,
				keymap = {set_llm_backend_name = function() return true end},
				paused = false,
				models_mgr = {},
				get_display_model_name = function(name) return name end,
				switch_model = function() return true end,
				save_prefs = function()
					save_calls = save_calls + 1
					persisted_backend = state.llm_backend
					return true
				end,
				update_menu = function() return true end,
				WarmupCtrl = {warmup = function()
					warmups = warmups + 1
					return true
				end},
				reset_llm_health_status = function()
					health_calls = health_calls + 1
					return true
				end,
			})
			local action = rows[3].action
			helpers.assert_eq(action(), false)
			helpers.assert_eq(action(), false,
				"a sibling must stop while exact rollback still refuses")
			helpers.assert_eq(state.llm_backend, "ollama")
			helpers.assert_eq(runtime_backend, "ollama")
			helpers.assert_eq(persisted_backend, "ollama")
			helpers.assert_eq(save_calls, 1,
				"unsettled runtime debt must block the sibling before its preflight")
			helpers.assert_eq(health_calls, 0)
			helpers.assert_eq(warmups, 0)

			helpers.assert_eq(action(), true)
			os.execute = previous_execute
			hs.execute = previous_hs_execute
			helpers.assert_eq(state.llm_backend, "api")
			helpers.assert_eq(runtime_backend, "api")
			helpers.assert_eq(persisted_backend, "api")
			helpers.assert_eq(setter_calls, 5)
			helpers.assert_eq(save_calls, 3)
			helpers.assert_eq(health_calls, 1)
			helpers.assert_eq(warmups, 1)
		end)
	end

	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("proves the target core identity before an MLX stop on " .. mode, function()
			local state = {
				llm_backend = "mlx",
				llm_model = "current-model",
				llm_model_mlx = "mlx-model",
				llm_model_ollama = "ollama-model",
			}
			local runtime_backend = "mlx"
			local persisted_backend = "mlx"
			local setter_calls = 0
			local stops = 0
			local health = 0
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {
					llm_model_mlx = "mlx-default",
					llm_model_ollama = "ollama-default",
				},
				get_backend = function() return runtime_backend end,
				set_backend = function(value)
					setter_calls = setter_calls + 1
					runtime_backend = value
					if setter_calls == 1 then
						if mode == "throw" then error("injected core refusal") end
						if mode == "nil" then return nil end
						return false
					end
					return true
				end,
				load_api_entries = function() return true end,
			}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_menu"] = {
				render_rows = function(rows) return rows end,
			}
			package.loaded["modules.llm.mlx_deps_checker"] = {
				check_and_install_deps = function() return true end,
			}
			package.loaded["modules.llm.ollama_deps_checker"] = {
				check_and_install_deps = function() return true end,
			}
			package.loaded["ui.menu.menu_llm.backend_panel"] = nil
			local BackendPanel = require("ui.menu.menu_llm.backend_panel")
			local _, rows = BackendPanel.build({
				state = state,
				keymap = {},
				paused = false,
				models_mgr = {stop_mlx_server_if_needed = function()
					stops = stops + 1
					return true
				end},
				get_display_model_name = function(name) return name end,
				switch_model = function() return true end,
				save_prefs = function()
					persisted_backend = state.llm_backend
					return true
				end,
				update_menu = function() return true end,
				WarmupCtrl = {warmup = function() return true end},
				reset_llm_health_status = function()
					health = health + 1
					return true
				end,
			})

			helpers.assert_eq(rows[3].action(), false)
			helpers.assert_eq(stops, 0,
				"a destructive stop cannot precede exact core acquisition")
			helpers.assert_eq(setter_calls, 2)
			helpers.assert_eq(state.llm_backend, "mlx")
			helpers.assert_eq(runtime_backend, "mlx")
			helpers.assert_eq(persisted_backend, "mlx")
			helpers.assert_eq(health, 0)
		end)
	end

	helpers.it("keeps an accepted MLX stop authoritative across a refused sibling", function()
		local state = {
			llm_backend = "mlx",
			llm_model = "current-model",
			llm_model_mlx = "mlx-model",
			llm_model_ollama = "ollama-model",
		}
		local runtime_backend = "mlx"
		local persisted_backend = "mlx"
		local setter_calls = 0
		local save_calls = 0
		local stop_calls = 0
		local warmups = 0
		local terminal
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = {
				llm_model_mlx = "mlx-default",
				llm_model_ollama = "ollama-default",
			},
			get_backend = function() return runtime_backend end,
			set_backend = function(value)
				setter_calls = setter_calls + 1
				runtime_backend = value
				return true
			end,
			load_api_entries = function() return true end,
		}
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
		}
		package.loaded["modules.llm.mlx_deps_checker"] = {
			check_and_install_deps = function() return true end,
		}
		package.loaded["modules.llm.ollama_deps_checker"] = {
			check_and_install_deps = function() return true end,
		}
		package.loaded["ui.menu.menu_llm.backend_panel"] = nil
		local BackendPanel = require("ui.menu.menu_llm.backend_panel")
		local _, rows = BackendPanel.build({
			state = state,
			keymap = {set_llm_backend_name = function() return true end},
			paused = false,
			models_mgr = {stop_mlx_server_if_needed = function(callback)
				stop_calls = stop_calls + 1
				terminal = callback
				return true
			end},
			get_display_model_name = function(name) return name end,
			switch_model = function() return true end,
			save_prefs = function()
				save_calls = save_calls + 1
				persisted_backend = state.llm_backend
				return true
			end,
			update_menu = function() return true end,
			WarmupCtrl = {warmup = function()
				warmups = warmups + 1
				return true
			end},
			reset_llm_health_status = function() return true end,
		})

		helpers.assert_eq(rows[3].action(), true)
		helpers.assert_eq(runtime_backend, "api")
		helpers.assert_eq(state.llm_backend, "mlx")
		helpers.assert_eq(persisted_backend, "mlx")
		helpers.assert_eq(warmups, 0)
		helpers.assert_eq(rows[2].action(), false,
			"a sibling cannot replace an accepted stop before its terminal")
		helpers.assert_eq(stop_calls, 1)
		helpers.assert_eq(setter_calls, 1,
			"the refused sibling cannot rearm the old core identity")
		helpers.assert_eq(save_calls, 1,
			"the refused sibling cannot publish preferences")
		helpers.assert_eq(terminal(), true)
		helpers.assert_eq(state.llm_backend, "api")
		helpers.assert_eq(runtime_backend, "api")
		helpers.assert_eq(persisted_backend, "api")
		helpers.assert_eq(warmups, 1)
	end)

	for _, boundary in ipairs({ "preflight", "core", "save", "health" }) do
		helpers.it("refuses a reentrant successor inside the " .. boundary
			.. " boundary", function()
			local state = {
				llm_backend = "api",
				llm_model = "current-model",
				llm_model_mlx = "mlx-model",
				llm_model_ollama = "ollama-model",
			}
			local runtime_backend = "api"
			local persisted_backend = "api"
			local rows
			local reentered = false
			local nested_result
			local setter_log = {}
			local save_log = {}
			local function reenter_once()
				if reentered then return end
				reentered = true
				nested_result = rows[2].action()
			end
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {
					llm_model_mlx = "mlx-default",
					llm_model_ollama = "ollama-default",
				},
				get_backend = function() return runtime_backend end,
				set_backend = function(value)
					setter_log[#setter_log + 1] = value
					runtime_backend = value
					if boundary == "core" and value == "mlx" and not reentered then
						reenter_once()
						return false
					end
					return true
				end,
				load_api_entries = function() return true end,
			}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_menu"] = {
				render_rows = function(items) return items end,
			}
			package.loaded["modules.llm.mlx_deps_checker"] = {
				check_and_install_deps = function() return true end,
			}
			package.loaded["modules.llm.ollama_deps_checker"] = {
				check_and_install_deps = function() return true end,
			}
			package.loaded["ui.menu.menu_llm.backend_panel"] = nil
			local BackendPanel = require("ui.menu.menu_llm.backend_panel")
			local save_calls = 0
			local _, built_rows = BackendPanel.build({
				state = state,
				keymap = {},
				paused = false,
				models_mgr = {},
				get_display_model_name = function(name) return name end,
				switch_model = function() return true end,
				save_prefs = function()
					save_calls = save_calls + 1
					local detached_snapshot = state.llm_backend
					if boundary == "preflight" and save_calls == 1 then
						reenter_once()
						persisted_backend = detached_snapshot
						save_log[#save_log + 1] = persisted_backend
						return false
					elseif boundary == "save" and detached_snapshot == "mlx"
						and not reentered then
						reenter_once()
						persisted_backend = detached_snapshot
						save_log[#save_log + 1] = persisted_backend
						return false
					end
					persisted_backend = detached_snapshot
					save_log[#save_log + 1] = persisted_backend
					return true
				end,
				update_menu = function() return true end,
				WarmupCtrl = {warmup = function() return true end},
				reset_llm_health_status = function()
					if boundary == "health" and state.llm_backend == "mlx"
						and not reentered then
						reenter_once()
						error("injected health refusal")
					end
					return true
				end,
			})
			rows = built_rows

			helpers.assert_eq(rows[1].action(), false)
			helpers.assert_eq(nested_result, false,
				"an opaque outer callback must fence nested selections on-stack")
			helpers.assert_eq(state.llm_backend, "api")
			helpers.assert_eq(runtime_backend, "api")
			helpers.assert_eq(persisted_backend, "api")
			if #setter_log > 0 then
				helpers.assert_eq(setter_log[#setter_log], "api",
					"the refused outer must end on the prior runtime identity")
			end
			helpers.assert_eq(save_log[#save_log], "api",
				"the refused outer must end on the prior durable identity")
		end)
	end

	local strict_successor_cases = {
		{stage = "mlx_deps", target = "mlx"},
		{stage = "ollama_deps", target = "ollama"},
		{stage = "health", target = "mlx"},
		{stage = "label", target = "mlx"},
		{stage = "model", target = "mlx"},
		{stage = "disable", target = "ollama", no_model = true},
		{stage = "api_entries", target = "api"},
		{stage = "menu", target = "api"},
		{stage = "warmup", target = "api"},
	}

	for _, case in ipairs(strict_successor_cases) do
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			helpers.it("requires literal true from backend successor " .. case.stage
				.. " on " .. mode, function()
			local previous_backend = case.target == "api" and "ollama" or "api"
			local state = {
				llm_backend = previous_backend,
				llm_model = "old-model",
				llm_model_mlx = "mlx-model",
				llm_model_ollama = case.no_model and "" or "ollama-model",
			}
			local runtime_backend = previous_backend
			local persisted_backend = previous_backend
			local runtime_label = previous_backend == "ollama" and "Ollama 🦙" or "API 🌐"
			local rendered_backend = previous_backend
			local refused = false
			local effects = {
				deps = 0,
				health = 0,
				labels = 0,
				models = 0,
				disables = 0,
				api_entries = 0,
				menus = 0,
				warmups = 0,
				executes = 0,
			}
			local function exact_result(stage)
				if case.stage ~= stage or refused then return true end
				refused = true
				if mode == "throw" then error("injected " .. stage .. " refusal") end
				if mode == "nil" then return nil end
				return false
			end
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {
					llm_model_mlx = "mlx-default",
					llm_model_ollama = "ollama-default",
				},
				get_backend = function() return runtime_backend end,
				set_backend = function(value)
					runtime_backend = value
					return true
				end,
				load_api_entries = function()
					effects.api_entries = effects.api_entries + 1
					return exact_result("api_entries")
				end,
			}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_menu"] = {
				render_rows = function(items) return items end,
			}
			package.loaded["modules.llm.mlx_deps_checker"] = {
				check_and_install_deps = function()
					effects.deps = effects.deps + 1
					return exact_result("mlx_deps")
				end,
			}
			package.loaded["modules.llm.ollama_deps_checker"] = {
				check_and_install_deps = function()
					effects.deps = effects.deps + 1
					return exact_result("ollama_deps")
				end,
			}

			local previous_execute = os.execute
			local previous_hs_execute = hs.execute
			os.execute = function()
				effects.executes = effects.executes + 1
				return true
			end
			hs.execute = function() return "arm64" end
			package.loaded["ui.menu.menu_llm.backend_panel"] = nil
			local BackendPanel = require("ui.menu.menu_llm.backend_panel")
			local _, rows = BackendPanel.build({
				state = state,
				keymap = {set_llm_backend_name = function(value)
					effects.labels = effects.labels + 1
					runtime_label = value
					return exact_result("label")
				end},
				paused = false,
				models_mgr = {},
				get_display_model_name = function(name) return name end,
				switch_model = function()
					effects.models = effects.models + 1
					return exact_result("model")
				end,
				disable_model = function()
					effects.disables = effects.disables + 1
					return exact_result("disable")
				end,
				save_prefs = function()
					persisted_backend = state.llm_backend
					return true
				end,
				update_menu = function()
					effects.menus = effects.menus + 1
					rendered_backend = state.llm_backend
					return exact_result("menu")
				end,
				WarmupCtrl = {warmup = function()
					effects.warmups = effects.warmups + 1
					return exact_result("warmup")
				end},
				reset_llm_health_status = function()
					effects.health = effects.health + 1
					return exact_result("health")
				end,
			})
			local row_index = case.target == "mlx" and 1
				or case.target == "ollama" and 2 or 3
			local result = rows[row_index].action()
			os.execute = previous_execute
			hs.execute = previous_hs_execute

			helpers.assert_eq(result, false)
			helpers.assert_eq(refused, true,
				"the injected strict successor must be reached")
			helpers.assert_eq(state.llm_backend, previous_backend)
			helpers.assert_eq(runtime_backend, previous_backend)
			helpers.assert_eq(persisted_backend, previous_backend)
			if effects.labels > 0 then
				helpers.assert_eq(runtime_label,
					previous_backend == "ollama" and "Ollama 🦙" or "API 🌐")
			end
			if effects.menus > 0 then
				helpers.assert_eq(rendered_backend, previous_backend)
			end
			helpers.assert_eq(effects.executes, 0,
				"destructive local-server cleanup cannot follow a refused successor")
		end)
		end
	end
end)

return true
