--- tests/unit/ui/menu/menu_llm/test_model_switcher_manager_generation.lua

--- ==============================================================================
--- MODULE: Model Manager Generation-Fence Regression
--- DESCRIPTION:
--- Exercises the real MLX and Ollama manager continuations around reordered
--- native completions. A superseded model operation must stop at each exercised
--- continuation and deliver its registered stale handoff at most once.
---
--- FEATURES & RATIONALE:
--- 1. End-to-end MLX switch ordering: the real requirements manager receives
---    the switcher's live generation predicate rather than a final-callback fake.
--- 2. Yield-boundary coverage: delayed prompts, server readiness, and completed
---    pulls are driven after their operation becomes stale.
--- 3. Scoped settlement: the exercised backend-stale path reaches its registered
---    handoff once. General pull terminals and pause/resume ownership remain the
---    separate `HS-010`, `HS-012`, and `HS-024` work.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ====================================
-- ====================================
-- ======= 1/ Fixture Utilities =======
-- ====================================
-- ====================================

--- Runs one fixture with an isolated module graph and exact global restoration.
--- @param module_names string[] Modules owned by the fixture.
--- @param hs_fixture table Native Hammerspoon double captured by subjects.
--- @param callback function Fixture body.
local function with_fixture(module_names, hs_fixture, callback)
	local saved_hs = _G.hs
	local outcome = table.pack(xpcall(function()
		helpers.with_fresh_modules(module_names, function()
			_G.hs = hs_fixture
			package.loaded["hs"] = hs_fixture
			callback()
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	if not outcome[1] then error(outcome[2], 0) end
end

--- Installs the common callback-safe logger and identity dependencies.
--- @return table Logger double.
local function install_common_stubs()
	local logger = helpers.make_logger_stub()
	logger.UNIFIED_LOG_FILE = "/tmp/ergopti-hs007.log"
	package.loaded["infra.logger"] = logger
	package.loaded["infra.i18n"] = {get = function(key) return key end}
	package.loaded["infra.notifications"] = {notify = function() end}
	package.loaded["modules.llm.api_common"] = {
		protected_call = function(callback, _, ...)
			if type(callback) ~= "function" then return nil end
			return xpcall(callback, debug.traceback, ...)
		end,
	}
	return logger
end

--- Builds the actual MLX requirements manager with native tasks under test control.
--- @param task_records table Captures native requirement completions.
--- @param start_records table Captures server targets accepted by the manager.
--- @return table manager
local function build_mlx_requirements_manager(task_records, start_records)
	install_common_stubs()
	package.loaded["infra.fs_dir"] = {entries = function() return {} end}
	package.loaded["modules.llm.api_mlx"] = {get_port = function() return 8080 end}
	package.loaded["modules.llm.mlx_deps_checker"] = {}
	package.loaded["ui.menu.menu_llm.models_manager_mlx_hf"] = {
		install = function(ctx)
			ctx.obj.get_mlx_repo = function(name) return "fixture/" .. tostring(name) end
		end,
	}
	package.loaded["ui.menu.menu_llm.models_manager_mlx_server"] = {
		install = function(ctx)
			ctx.obj.start_server = function(target, on_success)
				start_records[#start_records + 1] = target
				if type(on_success) == "function" then on_success() end
				return true
			end
		end,
	}
	package.loaded["ui.menu.menu_llm.models_manager_mlx_download"] = {
		install = function(ctx)
			ctx.obj.pull_model = function(target)
				start_records[#start_records + 1] = "pull:" .. tostring(target)
				return true
			end
		end,
	}
	package.loaded["adapters.task_lifecycle"] = {
		native = function(label, _, on_done)
			local task = {label = label, on_done = on_done}
			task_records[#task_records + 1] = task
			return task
		end,
		start = function() return true end,
	}

	local manager = require("ui.menu.menu_llm.models_manager_mlx").new({
		active_tasks = {},
		state = {llm_backend = "mlx"},
		update_icon = function() return true end,
		reset_menubar = function() return true end,
		save_prefs = function() return true end,
		update_menu = function() return true end,
	}, {})
	manager.get_installed_models = function()
		return {A = true, B = true, expired = true}
	end
	return manager
end





-- ==========================================
-- ==========================================
-- ======= 2/ Requirements Generation =======
-- ==========================================
-- ==========================================

helpers.describe("model manager generation fences", function()
	helpers.it("(HS-007-backend-stale) delivers one stale handoff from a real MLX check", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications", "infra.fs_dir",
			"modules.llm.api_common", "modules.llm.api_mlx",
			"modules.llm.mlx_deps_checker", "modules.llm",
			"adapters.task_lifecycle", "infra.dialog_util",
			"ui.menu.menu_llm.profile_label", "ui.menu.menu_llm.model_switcher",
			"ui.menu.menu_llm.models_manager_mlx_hf",
			"ui.menu.menu_llm.models_manager_mlx_server",
			"ui.menu.menu_llm.models_manager_mlx_download",
			"ui.menu.menu_llm.models_manager_mlx",
		}
		local hs_fixture = {
			fs = {attributes = function() return "file" end},
			timer = {secondsSinceEpoch = function() return 0 end},
		}
		with_fixture(modules, hs_fixture, function()
			local tasks, starts = {}, {}
			local manager = build_mlx_requirements_manager(tasks, starts)
			local prediction_states = {}
			local state = {
				llm_backend = "mlx", llm_enabled = true,
				llm_active_profile = "basic", llm_model = "old",
			}
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_num_predictions = 1},
				set_active_profile = function() end,
				set_llm_model_mlx = function() end,
				set_llm_model_ollama = function() end,
			}
			package.loaded["infra.dialog_util"] = {block_alert = function() return false end}
			package.loaded["ui.menu.menu_llm.profile_label"] = {
				format = function(label) return label end,
			}
			package.loaded["ui.menu.menu_llm.model_switcher"] = nil
			local switcher = require("ui.menu.menu_llm.model_switcher").new({
				state = state,
				models_mgr = {
					check_requirements = manager.check_requirements,
					get_presets = function() return {} end,
					get_model_info = function() return {} end,
					get_actual_model_name = function(name) return name end,
				},
				keymap = {
					set_llm_enabled = function(enabled)
						prediction_states[#prediction_states + 1] = enabled
					end,
					set_llm_model = function() end,
					set_llm_display_model_name = function() end,
				},
				save_prefs = function() return true end,
				update_menu = function() return true end,
			})

			switcher.switch_model("A")
			helpers.assert_eq(#tasks, 1)
			state.llm_backend = "api"
			tasks[1].on_done(0, "")
			tasks[1].on_done(0, "")

			helpers.assert_eq(starts, {},
				"a backend-stale requirement completion cannot start an MLX server")
			helpers.assert_eq(prediction_states, {false, true},
				"this backend-stale request must reach its registered handoff once")
		end)
	end)

	helpers.it("(HS-007-mlx-a-b-order) prevents late A from reaching the server after B commits", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications", "infra.fs_dir",
			"modules.llm.api_common", "modules.llm.api_mlx",
			"modules.llm.mlx_deps_checker", "modules.llm",
			"adapters.task_lifecycle", "infra.dialog_util",
			"ui.menu.menu_llm.profile_label", "ui.menu.menu_llm.model_switcher",
			"ui.menu.menu_llm.models_manager_mlx_hf",
			"ui.menu.menu_llm.models_manager_mlx_server",
			"ui.menu.menu_llm.models_manager_mlx_download",
			"ui.menu.menu_llm.models_manager_mlx",
		}
		local hs_fixture = {
			fs = {attributes = function() return "file" end},
			timer = {secondsSinceEpoch = function() return 0 end},
		}
		with_fixture(modules, hs_fixture, function()
			local tasks, starts = {}, {}
			local manager = build_mlx_requirements_manager(tasks, starts)
			local prediction_states = {}
			local state = {
				llm_backend = "mlx", llm_enabled = true,
				llm_active_profile = "basic", llm_model = "old",
			}
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_num_predictions = 1},
				set_active_profile = function() end,
				set_llm_model_mlx = function() end,
				set_llm_model_ollama = function() end,
			}
			package.loaded["infra.dialog_util"] = {block_alert = function() return false end}
			package.loaded["ui.menu.menu_llm.profile_label"] = {
				format = function(label) return label end,
			}
			package.loaded["ui.menu.menu_llm.model_switcher"] = nil
			local switcher = require("ui.menu.menu_llm.model_switcher").new({
				state = state,
				models_mgr = {
					check_requirements = manager.check_requirements,
					get_presets = function() return {} end,
					get_model_info = function() return {} end,
					get_actual_model_name = function(name) return name end,
				},
				keymap = {
					set_llm_enabled = function(enabled)
						prediction_states[#prediction_states + 1] = enabled
					end,
					set_llm_model = function() end,
					set_llm_display_model_name = function() end,
				},
				save_prefs = function() return true end,
				update_menu = function() return true end,
			})

			switcher.switch_model("A")
			switcher.switch_model("B")
			helpers.assert_eq(#tasks, 2)
			tasks[2].on_done(0, "")
			tasks[1].on_done(0, "")

			helpers.assert_eq(starts, {"B"},
				"the superseded A continuation must not terminate or replace B")
			helpers.assert_eq(state.llm_model, "B")
			helpers.assert_eq(prediction_states, {false, false, true},
				"B alone produces the final enable transition in this reordered case")
		end)
	end)

	helpers.it("(HS-007-dispatch-stale) deduplicates a stale handoff and false dispatch result", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications",
			"modules.llm", "infra.dialog_util", "ui.menu.menu_llm.profile_label",
			"ui.menu.menu_llm.model_switcher",
		}
		with_fixture(modules, {}, function()
			install_common_stubs()
			local prediction_states = {}
			local state = {
				llm_backend = "mlx", llm_enabled = true,
				llm_active_profile = "basic", llm_model = "old",
			}
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_num_predictions = 1},
				set_active_profile = function() end,
				set_llm_model_mlx = function() end,
				set_llm_model_ollama = function() end,
			}
			package.loaded["infra.dialog_util"] = {block_alert = function() return false end}
			package.loaded["ui.menu.menu_llm.profile_label"] = {
				format = function(label) return label end,
			}
			package.loaded["ui.menu.menu_llm.model_switcher"] = nil
			local switcher = require("ui.menu.menu_llm.model_switcher").new({
				state = state,
				models_mgr = {
					check_requirements = function(_, _, on_cancel)
						on_cancel("refused")
						return false
					end,
					get_presets = function() return {} end,
					get_model_info = function() return {} end,
					get_actual_model_name = function(name) return name end,
				},
				keymap = {
					set_llm_enabled = function(enabled)
						prediction_states[#prediction_states + 1] = enabled
					end,
					set_llm_model = function() end,
					set_llm_display_model_name = function() end,
				},
				save_prefs = function() return true end,
				update_menu = function() return true end,
			})

			switcher.switch_model("A")

			helpers.assert_eq(prediction_states, {false, true},
				"a synchronous stale handoff followed by false must enable once in this request")
		end)
	end)

	helpers.it("(HS-007-ollama-a-b-order) prevents late absent A from prompting or pulling after B commits", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications", "infra.text_utils",
			"modules.llm", "modules.llm.ollama_binary", "modules.llm.ollama_server_command",
			"adapters.shell_runner", "adapters.task_lifecycle", "adapters.timer_scheduler",
			"infra.dialog_util", "ui.download_window",
			"ui.menu.menu_llm.profile_label", "ui.menu.menu_llm.model_switcher",
			"ui.menu.menu_llm.models_manager_ollama",
		}
		local list_tasks = {}
		local load_callbacks = {}
		local readiness_tasks = {}
		local hs_fixture = {
			execute = function() error("Ollama readiness must not use hs.execute") end,
			http = {asyncPost = function(_, _, _, callback)
				load_callbacks[#load_callbacks + 1] = callback
			end},
			json = {encode = function() return "{}" end},
			timer = {
				doAfter = function() return {stop = function() end} end,
				secondsSinceEpoch = function() return 0 end,
			},
			urlevent = {openURL = function() end},
		}
		with_fixture(modules, hs_fixture, function()
			install_common_stubs()
			package.loaded["infra.text_utils"] = {shell_quote = function(value) return value end}
			package.loaded["modules.llm.ollama_binary"] = {
				resolve = function() return "/fixture/ollama" end,
			}
			package.loaded["modules.llm.ollama_server_command"] = {
				build = function() return "fixture" end,
			}
			package.loaded["ui.download_window"] = {
				show = function() end, update = function() end, complete = function() end,
			}
			package.loaded["adapters.shell_runner"] = {
				spawn = function(executable, args, on_done)
					local task = {executable = executable, args = args, on_done = on_done}
					function task.start() return true end
					function task.terminate() return true, "pending" end
					readiness_tasks[#readiness_tasks + 1] = task
					return task
				end,
			}
			package.loaded["adapters.timer_scheduler"] = {
				after = function() error("healthy readiness must not schedule a retry") end,
				cancel = function() return true end,
			}
			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, _, on_done)
					local task = {label = label, on_done = on_done}
					function task:start() return true end
					function task:terminate() return true end
					if label == "Ollama model requirement check" then
						list_tasks[#list_tasks + 1] = task
					end
					return task
				end,
				start = function(task) return task:start() == true end,
			}

			local prediction_states, runtime_models = {}, {}
			local prompts, pulls, saves = 0, 0, 0
			local state = {
				llm_backend = "ollama", llm_enabled = true,
				llm_active_profile = "basic", llm_model = "old",
			}
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_num_predictions = 1},
				set_active_profile = function() end,
				set_llm_model_mlx = function() end,
				set_llm_model_ollama = function() end,
			}
			package.loaded["infra.dialog_util"] = {block_alert = function() return false end}
			package.loaded["ui.menu.menu_llm.profile_label"] = {
				format = function(label) return label end,
			}
			local manager_deps = {
				active_tasks = {}, state = state,
				shared_system_check = function(_, _, _, do_download)
					prompts = prompts + 1
					return do_download()
				end,
			}
			local manager = require("ui.menu.menu_llm.models_manager_ollama")
				.new(manager_deps, {}, function() return 8 end)
			manager.pull_model = function(target)
				pulls = pulls + 1
				return target ~= nil
			end
			package.loaded["ui.menu.menu_llm.model_switcher"] = nil
			local switcher = require("ui.menu.menu_llm.model_switcher").new({
				state = state,
				models_mgr = {
					check_requirements = manager.check_requirements,
					get_presets = function() return {} end,
					get_model_info = function() return {} end,
					get_actual_model_name = function(name) return name end,
				},
				keymap = {
					set_llm_enabled = function(enabled)
						prediction_states[#prediction_states + 1] = enabled
					end,
					set_llm_model = function(model)
						runtime_models[#runtime_models + 1] = model
					end,
					set_llm_display_model_name = function() end,
				},
				save_prefs = function() saves = saves + 1; return true end,
				update_menu = function() return true end,
			})

			switcher.switch_model("A")
			helpers.assert_eq(#readiness_tasks, 1)
			readiness_tasks[1].on_done(0, '{"version":"fixture"}', "")
			helpers.assert_eq(#list_tasks, 1)
			switcher.switch_model("B")
			helpers.assert_eq(#readiness_tasks, 2)
			readiness_tasks[2].on_done(0, '{"version":"fixture"}', "")
			helpers.assert_eq(#list_tasks, 2)
			list_tasks[2].on_done(0, "NAME ID\nB fixture\n")
			helpers.assert_eq(#load_callbacks, 1)
			load_callbacks[1](200, "{}", {})
			list_tasks[1].on_done(0, "NAME ID\n")

			helpers.assert_eq(state.llm_model, "B")
			helpers.assert_eq(runtime_models, {"B"})
			helpers.assert_eq(saves, 1)
			helpers.assert_eq(prompts, 0,
				"the stale absent model must not reach the hardware prompt")
			helpers.assert_eq(pulls, 0,
				"the stale absent model must not dispatch a pull")
			helpers.assert_eq(prediction_states, {},
				"this Ollama path must emit no MLX enable transition")
		end)
	end)

	helpers.it("(HS-007-invalidation-stale) invokes one stale callback after a native check expires", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications", "infra.fs_dir",
			"modules.llm.api_common", "modules.llm.api_mlx",
			"modules.llm.mlx_deps_checker", "adapters.task_lifecycle",
			"ui.menu.menu_llm.models_manager_mlx_hf",
			"ui.menu.menu_llm.models_manager_mlx_server",
			"ui.menu.menu_llm.models_manager_mlx_download",
			"ui.menu.menu_llm.models_manager_mlx",
		}
		local hs_fixture = {
			fs = {attributes = function() return "file" end},
			timer = {secondsSinceEpoch = function() return 0 end},
		}
		with_fixture(modules, hs_fixture, function()
			local tasks, starts = {}, {}
			local manager = build_mlx_requirements_manager(tasks, starts)
			local generation_expired = false
			local successes, cancellations = 0, 0
			manager.check_requirements("expired",
				function() successes = successes + 1 end,
				function() cancellations = cancellations + 1 end,
				{is_current = function() return not generation_expired end})
			generation_expired = true
			tasks[1].on_done(0, "")
			tasks[1].on_done(0, "")

			helpers.assert_eq(successes, 0)
			helpers.assert_eq(cancellations, 1,
				"the expired native completion must invoke its stale callback once")
			helpers.assert_eq(starts, {})
		end)
	end)



	-- =============================================
	-- ===== 2.1) Deferred Prompt Generation =====
	-- =============================================

	helpers.it("(HS-007-delayed-prompt-yield) drops a hardware prompt after its generation expires", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.dialog_util", "infra.paths",
			"modules.llm", "ui.menu.menu_llm.models_manager_ollama",
			"ui.menu.menu_llm.models_manager_mlx", "ui.menu.menu_llm.models_manager",
		}
		local timers = {}
		local focus_calls = 0
		local hs_fixture = {
			execute = function(command)
				if command:find("memsize", 1, true) then return tostring(16 * 1024 * 1024 * 1024) end
				return "100"
			end,
			focus = function() focus_calls = focus_calls + 1 end,
			json = {decode = function()
				return {{families = {{models = {{name = "A", urls = {ollama = "A"}}}}}}}
			end},
			timer = {doAfter = function(_, callback)
				timers[#timers + 1] = callback
				return {stop = function() end}
			end},
		}
		with_fixture(modules, hs_fixture, function()
			install_common_stubs()
			local prompts, downloads, cancellations = 0, 0, 0
			package.loaded["infra.dialog_util"] = {block_alert = function()
				prompts = prompts + 1
				return "menu.llm.btn_download"
			end}
			package.loaded["infra.paths"] = {
				shared_llm_path = function() return helpers.shared("modules/llm/models.json") end,
			}
			package.loaded["modules.llm"] = {get_backend = function() return "ollama" end}
			package.loaded["ui.menu.menu_llm.models_manager_ollama"] = {
				new = function() return {} end,
			}
			package.loaded["ui.menu.menu_llm.models_manager_mlx"] = {
				new = function() return {} end,
			}
			local deps = {update_icon = function() end, reset_menubar = function() end}
			require("ui.menu.menu_llm.models_manager").new(deps)
			local current = true
			deps.shared_system_check("A", "Ollama", "A",
				function() downloads = downloads + 1; return true end,
				function() cancellations = cancellations + 1 end,
				{is_current = function() return current end})
			helpers.assert_eq(#timers, 1)
			current = false
			timers[1]()
			timers[1]()

			helpers.assert_eq(prompts, 0,
				"a stale delayed system check must not show a modal prompt")
			helpers.assert_eq(downloads, 0,
				"a stale delayed system check must not dispatch a pull")
			helpers.assert_eq(focus_calls, 0,
				"a stale delayed system check must not steal application focus")
			helpers.assert_eq(cancellations, 1,
				"the discarded prompt continuation must invoke its stale callback once")
		end)
	end)

	helpers.it("(HS-007-freshness-fail-closed) rejects nil and throwing generation predicates", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications",
			"modules.llm.api_common", "modules.llm.api_mlx",
			"adapters.task_lifecycle", "ui.menu.menu_llm.models_manager_mlx_server",
		}
		local native_calls, execute_calls = 0, 0
		local hs_fixture = {
			execute = function() execute_calls = execute_calls + 1; return "" end,
			json = {decode = function() return {data = {}} end},
			timer = {doAfter = function() return {stop = function() end} end},
		}
		with_fixture(modules, hs_fixture, function()
			install_common_stubs()
			package.loaded["modules.llm.api_mlx"] = {
				get_port = function() return 8080 end,
				reset_endpoints = function() end,
				set_model_hf_path = function() end,
				set_active_server_pgid = function() end,
				mark_load_failed = function() end,
			}
			package.loaded["adapters.task_lifecycle"] = {
				native = function()
					native_calls = native_calls + 1
					return nil
				end,
				start = function() return false end,
			}
			local obj = {get_mlx_repo = function() return "fixture/A" end}
			require("ui.menu.menu_llm.models_manager_mlx_server").install({
				obj = obj,
				deps = {active_tasks = {}},
				project_venv_python_escaped = "/fixture/python",
				active_tasks_gc_root = {},
			})

			local predicates = {
				function() return nil end,
				function() error("generation probe failed") end,
			}
			for _, predicate in ipairs(predicates) do
				local successes, cancellations = 0, 0
				local accepted = obj.start_server("A",
					function() successes = successes + 1 end,
					function(reason)
						helpers.assert_eq(reason, "stale")
						cancellations = cancellations + 1
					end,
					{is_current = predicate})
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(successes, 0)
				helpers.assert_eq(cancellations, 1)
			end
			helpers.assert_eq(native_calls, 0,
				"an indeterminate generation cannot construct native work")
			helpers.assert_eq(execute_calls, 0,
				"an indeterminate generation cannot reach the adoption probe")
		end)
	end)



	-- ============================================
	-- ===== 2.2) Native Completion Generation =====
	-- ============================================

	helpers.it("(HS-007-mlx-readiness-yield) prevents stale readiness from publishing server state", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications",
			"modules.llm.api_common", "modules.llm.api_mlx",
			"adapters.task_lifecycle", "ui.menu.menu_llm.models_manager_mlx_server",
		}
		local readiness_done
		local server_task
		local hs_fixture = {
			execute = function() return "" end,
			json = {decode = function() return {data = {{id = "fixture/A"}}} end},
			timer = {doAfter = function(_, callback)
				return {callback = callback, stop = function() end}
			end},
		}
		with_fixture(modules, hs_fixture, function()
			install_common_stubs()
			package.loaded["modules.llm.api_mlx"] = {
				get_port = function() return 8080 end,
				reset_endpoints = function() end,
				set_model_hf_path = function() end,
				set_active_server_pgid = function() end,
				mark_load_failed = function() end,
			}
			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, _, on_done)
					local task = {running = false, terminate_calls = 0}
					function task:start() self.running = true; return true end
					function task:isRunning() return self.running end
					function task:terminate()
						self.terminate_calls = self.terminate_calls + 1
						self.running = false
						return true
					end
					if label == "MLX readiness probe" then readiness_done = on_done end
					if label == "MLX server launch" then server_task = task end
					return task
				end,
				start = function(task) return task:start() == true end,
			}
			local obj = {get_mlx_repo = function() return "fixture/A" end}
			local deps = {active_tasks = {}}
			require("ui.menu.menu_llm.models_manager_mlx_server").install({
				obj = obj,
				deps = deps,
				project_venv_python_escaped = "/fixture/python",
				active_tasks_gc_root = {},
			})
			local current = true
			local successes, cancellations = 0, 0
			obj.start_server("A",
				function() successes = successes + 1 end,
				function() cancellations = cancellations + 1 end,
				{is_current = function() return current end, silent_notifications = true})
			helpers.assert_type(readiness_done, "function")
			helpers.assert_not_nil(server_task)
			current = false
			readiness_done(0, "ready")
			readiness_done(0, "ready")

			helpers.assert_eq(successes, 0,
				"a stale readiness probe cannot publish success")
			helpers.assert_eq(cancellations, 1,
				"the stale readiness path must invoke its registered callback once")
			helpers.assert_true(obj._server_ready ~= true,
				"a stale readiness probe cannot mark the server ready")
		end)
	end)

	helpers.it("(HS-007-mlx-download-publication-yield) drops stale detached-download continuations", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications",
			"adapters.task_lifecycle", "ui.download_window",
			"ui.menu.menu_llm.models_manager_mlx_download",
		}
		local saved_io_open = io.open
		local saved_os_execute = os.execute
		local saved_os_remove = os.remove
		local ok, err = xpcall(function()
			local timers = {}
			local tasks = {}
			local fake_files = {}
			local exit_available = false
			local current = true
			local hs_fixture = {
				json = {
					decode = function(raw)
						return {
							log_path = raw:match('"log_path":"([^"]+)"'),
							model = raw:match('"model":"([^"]+)"'),
							repo = raw:match('"repo":"([^"]+)"'),
						}
					end,
					encode = function(value)
						return string.format(
							'{"model":"%s","log_path":"%s","repo":"%s","pid":%s}',
							tostring(value.model), tostring(value.log_path),
							tostring(value.repo), tostring(value.pid))
					end,
				},
				timer = {doAfter = function(delay, callback)
					timers[#timers + 1] = {delay = delay, callback = callback}
					return {stop = function() end}
				end},
			}
			with_fixture(modules, hs_fixture, function()
				install_common_stubs()
				local notifications = 0
				local completions = 0
				package.loaded["infra.notifications"] = {
					notify = function() notifications = notifications + 1 end,
				}
				package.loaded["ui.download_window"] = {
					show = function() end,
					update = function() end,
					complete = function() completions = completions + 1 end,
				}
				package.loaded["adapters.task_lifecycle"] = {
					native = function(label, _, on_done, on_stream)
						local task = {
							label = label, on_done = on_done, on_stream = on_stream,
							terminate_calls = 0,
						}
						function task:start() return true end
						function task:terminate()
							self.terminate_calls = self.terminate_calls + 1
							return true
						end
						tasks[#tasks + 1] = task
						return task
					end,
					start = function(task) return task:start() == true end,
				}

				io.open = function(path, mode)
					if mode == "w" then
						local chunks = {}
						return {
							write = function(_, ...)
								for index = 1, select("#", ...) do
									chunks[#chunks + 1] = tostring(select(index, ...))
								end
								return true
							end,
							close = function() fake_files[path] = table.concat(chunks) end,
						}
					end
					if path:match("%.exit$") and exit_available then
						current = false
						return {read = function() return "0" end, close = function() end}
					end
					local content = fake_files[path]
					if content == nil then return nil end
					return {read = function() return content end, close = function() end}
				end
				os.execute = function() return true end
				os.remove = function(path) fake_files[path] = nil; return true end

				local state = {llm_model = "B"}
				local runtime_sets, saves, invalidations, starts, icon_updates = 0, 0, 0, 0, 0
				local deps = {
					active_tasks = {}, state = state,
					update_icon = function() icon_updates = icon_updates + 1; return true end,
					save_prefs = function() saves = saves + 1; return true end,
					keymap = {set_llm_model = function() runtime_sets = runtime_sets + 1 end},
				}
				local obj = {start_server = function() starts = starts + 1; return true end}
				require("ui.menu.menu_llm.models_manager_mlx_download").install({
					obj = obj, deps = deps, presets = {},
					project_venv_python_escaped = "/fixture/python",
					invalidate_installed_cache = function()
						invalidations = invalidations + 1
					end,
				})
				local successes, cancellations = 0, 0
				helpers.assert_eq(obj.pull_model("A", "fixture/A",
					function() successes = successes + 1 end,
					function() cancellations = cancellations + 1 end,
					{is_current = function() return current end}), true)

				local launcher
				for _, task in ipairs(tasks) do
					if task.label == "MLX detached download launcher" then launcher = task end
				end
				helpers.assert_not_nil(launcher)
				launcher.on_stream(nil, "__DLPID__:123\n", "")
				launcher.on_done(0, "", "")
				helpers.assert_not_nil(deps.active_tasks["download_tail"])

				-- Ignore setup UI. The exit-file observation below is the async yield:
				-- it invalidates the generation between the poll guard and publication.
				notifications, completions, icon_updates = 0, 0, 0
				exit_available = true
				local poll
				for _, timer in ipairs(timers) do
					if timer.delay == 3 then poll = timer.callback; break end
				end
				helpers.assert_type(poll, "function")
				poll()
				poll()

				helpers.assert_eq(state.llm_model, "B")
				helpers.assert_eq(runtime_sets, 0)
				helpers.assert_eq(saves, 0)
				helpers.assert_eq(invalidations, 0)
				helpers.assert_eq(starts, 0)
				helpers.assert_eq(notifications, 0)
				helpers.assert_eq(completions, 0)
				helpers.assert_eq(icon_updates, 0)
				helpers.assert_eq(successes, 0)
				helpers.assert_eq(cancellations, 1,
					"the stale detached completion must invoke its registered callback once")
				helpers.assert_nil(deps.active_tasks["download_tail"])

				-- Start another exact owner, then expire it in its launcher stream.
				-- Its cleanup must not reset shared UI that a successor may already own.
				current = true
				helpers.assert_eq(obj.pull_model("C", "fixture/C",
					function() successes = successes + 1 end,
					function() cancellations = cancellations + 1 end,
					{is_current = function() return current end}), true)
				local stale_launcher = tasks[#tasks]
				helpers.assert_eq(stale_launcher.label, "MLX detached download launcher")
				notifications, completions, icon_updates = 0, 0, 0
				current = false
				helpers.assert_eq(stale_launcher.on_stream(nil, "progress", ""), false)
				helpers.assert_eq(stale_launcher.terminate_calls, 1)
				helpers.assert_nil(deps.active_tasks["download"])
				helpers.assert_eq(icon_updates, 0,
					"stale A cleanup must not overwrite a successor's shared icon")
				helpers.assert_eq(notifications, 0)
				helpers.assert_eq(completions, 0)
				helpers.assert_eq(successes, 0)
				helpers.assert_eq(cancellations, 2,
					"each exercised expired operation must invoke its callback once")
			end)
		end, debug.traceback)
		io.open = saved_io_open
		os.execute = saved_os_execute
		os.remove = saved_os_remove
		if not ok then error(err, 0) end
	end)

	helpers.it("(HS-007-ollama-pull-publication-yield) refuses a successor before UI and drops stale completion", function()
		local modules = {
			"hs", "infra.logger", "infra.i18n", "infra.notifications", "infra.text_utils",
			"modules.llm.ollama_binary", "modules.llm.ollama_server_command",
			"adapters.task_lifecycle", "ui.download_window",
			"ui.menu.menu_llm.models_manager_ollama",
		}
		local pull_done
		local pull_tasks, progress_shows = {}, 0
		local http_posts = 0
		local notifications = 0
		local hs_fixture = {
			execute = function() return "", true end,
			http = {asyncPost = function() http_posts = http_posts + 1 end},
			json = {encode = function() return "{}" end},
			timer = {
				doAfter = function() return {stop = function() end} end,
				secondsSinceEpoch = function() return 0 end,
			},
			urlevent = {openURL = function() end},
		}
		with_fixture(modules, hs_fixture, function()
			install_common_stubs()
			package.loaded["infra.notifications"] = {
				notify = function() notifications = notifications + 1 end,
			}
			package.loaded["infra.text_utils"] = {shell_quote = function(value) return value end}
			package.loaded["modules.llm.ollama_binary"] = {
				resolve = function() return "/fixture/ollama" end,
			}
			package.loaded["modules.llm.ollama_server_command"] = {
				build = function() return "fixture" end,
			}
			package.loaded["ui.download_window"] = {
				show = function() progress_shows = progress_shows + 1 end,
				update = function() end, complete = function() end,
			}
			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, _, on_done)
					local task = {}
					function task:start() return true end
					function task:terminate() return true end
					if label == "Ollama model pull" then
						pull_done = on_done
						pull_tasks[#pull_tasks + 1] = task
					end
					return task
				end,
				start = function(task) return task:start() == true end,
			}
			local state = {llm_model = "B"}
			local runtime_sets, display_sets, saves = 0, 0, 0
			local active_tasks = {}
			local manager = require("ui.menu.menu_llm.models_manager_ollama").new({
				active_tasks = active_tasks, state = state,
				keymap = {
					set_llm_model = function() runtime_sets = runtime_sets + 1 end,
					set_llm_display_model_name = function() display_sets = display_sets + 1 end,
				},
				save_prefs = function() saves = saves + 1; return true end,
			}, {}, function() return 8 end)
			local current = true
			local successes, cancellations = 0, 0
			helpers.assert_eq(manager.pull_model("A", "A",
				function() successes = successes + 1 end,
				function() cancellations = cancellations + 1 end,
				{is_current = function() return current end}), true)
			helpers.assert_type(pull_done, "function")
			local first_task = active_tasks["ollama_pull"]
			helpers.assert_not_nil(first_task)

			-- Generation isolation needs a stable predecessor slot. Full cancellation
			-- and termination settlement remain the separate HS-010 contract.
			helpers.assert_eq(manager.pull_model("C", "C", nil, nil,
				{is_current = function() return true end}), false)
			helpers.assert_eq(#pull_tasks, 1,
				"the refused successor must not construct a second native task")
			helpers.assert_eq(progress_shows, 1,
				"the refused successor must not replace the predecessor progress UI")
			helpers.assert_true(active_tasks["ollama_pull"] == first_task,
				"the refused successor must not overwrite the predecessor task slot")

			current = false
			pull_done(0)
			pull_done(0)

			helpers.assert_eq(state.llm_model, "B",
				"a stale pull cannot overwrite the newer model identity")
			helpers.assert_eq(runtime_sets, 0)
			helpers.assert_eq(display_sets, 0)
			helpers.assert_eq(saves, 0)
			helpers.assert_eq(http_posts, 0,
				"a stale pull cannot dispatch a loadability request")
			helpers.assert_eq(notifications, 0,
				"a stale pull completion cannot announce the obsolete model")
			helpers.assert_eq(successes, 0)
			helpers.assert_eq(cancellations, 1,
				"the stale pull completion must invoke its registered callback once")
		end)
	end)
end)

return true
