--- tests/unit/ui/menu/menu_llm/test_ollama_pull_parent_transaction.lua

--- ================================================================================
--- MODULE: Ollama Pull Parent Transaction Regression
--- DESCRIPTION:
--- Exercises the real Ollama pull manager beneath the real model switcher so a
--- completed download cannot publish model identity below the parent transaction.
---
--- FEATURES & RATIONALE:
--- 1. Parent Refusal: A rejected preference save restores every model identity.
--- 2. Single Publisher: A successful pull stays publication-free until the
---    loadability callback hands ownership to the model switcher.
--- ================================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"hs",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"infra.text_utils",
	"modules.llm",
	"modules.llm.ollama_binary",
	"modules.llm.ollama_server_command",
	"adapters.shell_runner",
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"ui.download_window",
	"ui.menu.menu_llm.profile_label",
	"ui.menu.menu_llm.model_switcher",
	"ui.menu.menu_llm.models_manager_ollama",
}





-- ====================================
-- ====================================
-- ======= 1/ Fixture Utilities =======
-- ====================================
-- ====================================

--- Copies the model identity fields observed by persistence and menu rendering.
--- @param state table Mutable application state.
--- @return table identity Detached identity snapshot.
local function copy_identity(state)
	return {
		model = state.llm_model,
		model_ollama = state.llm_model_ollama,
		model_power = state.llm_model_power,
	}
end

--- Runs the real manager and switcher with controllable native completions.
--- @param save_results boolean[] Ordered preference boundary results.
--- @param callback function Fixture body.
local function with_fixture(save_results, callback)
	local saved_hs = _G.hs
	local outcome = table.pack(xpcall(function()
		helpers.with_fresh_modules(MODULES, function()
			local pull_done
			local loadability_callbacks = {}
			local records = {
				runtime_models = {},
				display_models = {},
				prediction_states = {},
				saves = 0,
				menus = 0,
				terminals = {},
			}
			local state = {
				llm_backend = "ollama",
				llm_enabled = true,
				llm_active_profile = "basic",
				llm_num_predictions = 1,
				llm_model = "A",
				llm_model_ollama = "A",
				llm_model_power = 1,
			}
			local runtime = {
				model = "A",
				display_model = "A",
				enabled = true,
			}
			local persisted = copy_identity(state)
			local rendered = copy_identity(state)
			local logger = helpers.make_logger_stub()
			logger.UNIFIED_LOG_FILE = "/tmp/ergopti-hs032.log"
			local base_callback = logger.callback
			logger.callback = function(log_name, label, native_callback, ...)
				local ok, result = base_callback(log_name, label, native_callback, ...)
				if label == "Ollama requirement success" then
					records.terminals[#records.terminals + 1] = ok and result ~= false
						and "success" or "failure"
				elseif label == "Ollama requirement cancellation" then
					records.terminals[#records.terminals + 1] = "failure"
				end
				return ok, result
			end

			local hs_fixture = {
				execute = function() return "", true end,
				http = {
					asyncPost = function(_, _, _, done)
						loadability_callbacks[#loadability_callbacks + 1] = done
					end,
				},
				json = {encode = function() return "{}" end},
				timer = {
					doAfter = function()
						return {stop = function() return true end}
					end,
					secondsSinceEpoch = function() return 0 end,
				},
				urlevent = {openURL = function() return true end},
			}
			_G.hs = hs_fixture
			package.loaded["hs"] = hs_fixture
			package.loaded["infra.logger"] = logger
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.notifications"] = {notify = function() return true end}
			package.loaded["infra.text_utils"] = {shell_quote = function(value) return value end}
			package.loaded["infra.dialog_util"] = {block_alert = function() return "button.cancel" end}
			package.loaded["modules.llm.ollama_binary"] = {
				resolve = function() return "/fixture/ollama" end,
			}
			package.loaded["modules.llm.ollama_server_command"] = {
				build = function() return "fixture" end,
			}
			package.loaded["adapters.shell_runner"] = {
				spawn = function(_, _, done)
					return {
						start = function()
							done(0, "{\"version\":\"fixture\"}", "")
							return true
						end,
					}
				end,
			}
			package.loaded["adapters.timer_scheduler"] = {}
			package.loaded["ui.download_window"] = {
				show = function() return true end,
				update = function() return true end,
				complete = function() return true end,
			}
			package.loaded["ui.menu.menu_llm.profile_label"] = {
				format = function(label) return label end,
			}
			package.loaded["adapters.task_lifecycle"] = {
				native = function(label, _, on_done)
					local task = {label = label, on_done = on_done}
					if label == "Ollama model pull" then pull_done = on_done end
					task.terminate = function() return true end
					return task
				end,
				start = function(task)
					if task.label == "Ollama model requirement check" then
						task.on_done(0, "NAME ID SIZE MODIFIED\nA fixture 1 GB now\n")
					end
					return true
				end,
			}

			local keymap = {
				set_llm_enabled = function(enabled)
					records.prediction_states[#records.prediction_states + 1] = enabled
					runtime.enabled = enabled
					return true
				end,
				set_llm_model = function(model)
					records.runtime_models[#records.runtime_models + 1] = model
					runtime.model = model
					return true
				end,
				set_llm_display_model_name = function(model)
					records.display_models[#records.display_models + 1] = model
					runtime.display_model = model
					return true
				end,
			}
			local function save_prefs()
				records.saves = records.saves + 1
				local accepted = save_results[records.saves]
				if accepted ~= true then return false end
				persisted = copy_identity(state)
				return true
			end
			local function update_menu()
				records.menus = records.menus + 1
				rendered = copy_identity(state)
				return true
			end

			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_num_predictions = 1},
				set_active_profile = function() return true end,
			}
			local presets = {{families = {{models = {
				{name = "A", urls = {ollama = "https://ollama.com/library/A"}},
				{name = "B", urls = {ollama = "https://ollama.com/library/B"}},
			}}}}}
			local manager = require("ui.menu.menu_llm.models_manager_ollama").new({
				active_tasks = {},
				state = state,
				keymap = keymap,
				save_prefs = save_prefs,
			}, presets, function() return 8 end)
			manager.get_actual_model_name = function(name) return name end
			manager.get_model_info = function() return {params = 1, type = "chat"} end
			manager.get_presets = function() return presets end

			local switcher = require("ui.menu.menu_llm.model_switcher").new({
				state = state,
				models_mgr = manager,
				keymap = keymap,
				save_prefs = save_prefs,
				update_menu = update_menu,
			})
			callback({
				loadability_callbacks = loadability_callbacks,
				persisted = function() return persisted end,
				pull_done = function(...)
					helpers.assert_type(pull_done, "function")
					return pull_done(...)
				end,
				records = records,
				rendered = function() return rendered end,
				runtime = runtime,
				state = state,
				switcher = switcher,
			})
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	if not outcome[1] then error(outcome[2], 0) end
end

--- Asserts that every observable owner still presents model A.
--- @param fixture table Active test fixture.
local function assert_model_a(fixture)
	helpers.assert_eq(fixture.state.llm_model, "A")
	helpers.assert_eq(fixture.state.llm_model_ollama, "A")
	helpers.assert_eq(fixture.state.llm_model_power, 1)
	helpers.assert_eq(fixture.runtime.model, "A")
	helpers.assert_eq(fixture.runtime.display_model, "A")
	helpers.assert_eq(fixture.persisted().model, "A")
	helpers.assert_eq(fixture.persisted().model_ollama, "A")
	helpers.assert_eq(fixture.persisted().model_power, 1)
	helpers.assert_eq(fixture.rendered().model, "A")
	helpers.assert_eq(fixture.rendered().model_ollama, "A")
	helpers.assert_eq(fixture.rendered().model_power, 1)
end





-- ===========================================
-- ===========================================
-- ======= 2/ Parent Publication Owner =======
-- ===========================================
-- ===========================================

helpers.describe("Ollama pull parent transaction", function()
	helpers.it("(HS-032-parent-refusal) restores A after the parent preference boundary refuses B", function()
		with_fixture({false, true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			fixture.pull_done(0)
			if fixture.loadability_callbacks[1] then
				fixture.loadability_callbacks[1](200, "{}", {})
			end

			assert_model_a(fixture)
			helpers.assert_eq(#fixture.loadability_callbacks, 1,
				"a completed pull must hand off through one loadability boundary")
			helpers.assert_eq(fixture.records.runtime_models, {"B", "A"})
			helpers.assert_eq(fixture.records.display_models, {"B", "A"})
			helpers.assert_eq(fixture.records.saves, 2,
				"the refused parent save must be followed by one rollback save")
			helpers.assert_eq(fixture.records.menus, 0,
				"a rejected model identity must never reach menu publication")
			helpers.assert_eq(fixture.records.terminals, {"failure"},
				"the pull handoff must settle exactly once as a parent failure")
		end)
	end)

	helpers.it("(HS-032-parent-success-owner) publishes B once only after loadability succeeds", function()
		with_fixture({true}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			fixture.pull_done(0)

			assert_model_a(fixture)
			helpers.assert_eq(fixture.records.runtime_models, {},
				"the manager must not publish runtime identity after process completion")
			helpers.assert_eq(fixture.records.display_models, {},
				"the manager must not publish display identity after process completion")
			helpers.assert_eq(fixture.records.saves, 0,
				"the manager must not persist model identity before the parent transaction")
			helpers.assert_eq(fixture.records.menus, 0)
			helpers.assert_eq(fixture.records.terminals, {})
			helpers.assert_eq(#fixture.loadability_callbacks, 1,
				"process completion must continue through the loadability boundary")

			fixture.loadability_callbacks[1](200, "{}", {})
			helpers.assert_eq(fixture.state.llm_model, "B")
			helpers.assert_eq(fixture.state.llm_model_ollama, "B")
			helpers.assert_eq(fixture.runtime.model, "B")
			helpers.assert_eq(fixture.runtime.display_model, "B")
			helpers.assert_eq(fixture.persisted().model, "B")
			helpers.assert_eq(fixture.rendered().model, "B")
			helpers.assert_eq(fixture.records.runtime_models, {"B"})
			helpers.assert_eq(fixture.records.display_models, {"B"})
			helpers.assert_eq(fixture.records.saves, 1)
			helpers.assert_eq(fixture.records.menus, 1)
			helpers.assert_eq(fixture.records.terminals, {"success"})
		end)
	end)
end)

return true
