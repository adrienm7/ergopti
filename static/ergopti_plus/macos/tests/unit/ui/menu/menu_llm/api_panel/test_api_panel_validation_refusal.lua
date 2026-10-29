--- tests/unit/ui/menu/menu_llm/api_panel/test_api_panel_validation_refusal.lua

--- ==============================================================================
--- MODULE: API Panel Validation Refusal Regression
--- DESCRIPTION:
--- A remote entry is staged only while its availability probe owns a terminal
--- callback. An immediate probe refusal restores the prior runtime identity,
--- releases the panel mutation lease, and reports the failed operation.
--- The add action answers the backend switch with a literal receipt: true once
--- the probe owns the entry, false on refusal (a nil receipt made the switch
--- log "API backend successor refused: nil" and abandon a dispatched probe).
--- ==============================================================================

local helpers = require("tests.helpers")


--- Builds the panel around a scripted availability probe and runs the add action.
--- @param check_result any What the stubbed check_availability returns.
--- @param assertions function Receives the action receipt and the fixture state.
local function run_add_action(check_result, assertions)
		helpers.with_fresh_modules({
			"modules.llm",
			"infra.i18n",
			"infra.logger",
			"infra.dialog_util",
			"infra.notifications",
			"infra.manifest_menu",
			"ui.menu.menu_llm.api_panel",
		}, function()
			local previous_entry = {
				id = "existing", provider = "openai", token = "old-secret",
				model = "old-model", label = "Existing",
			}
			local entries = { previous_entry }
			local active_id = previous_entry.id
			local prompt_values = {
				"https://api.example.invalid/v1", "new-secret", "new-model", "New entry",
			}
			local prompt_index = 0
			local validation_calls = 0
			local persistence_calls = 0
			local notifications = {}
			local updates = 0
			local warmups = 0

			local api_remote = {
				PROVIDER_ORDER = { "openai" },
				PROVIDERS = {
					openai = {
						label = "OpenAI",
						base_url = "https://api.example.invalid/v1",
						default_model = "new-model",
					},
				},
				get_entries = function() return entries end,
				set_entries = function(value) entries = value end,
				get_active_entry_id = function() return active_id end,
				set_active_entry_id = function(value) active_id = value end,
				get_active_entry = function()
					for _, entry in ipairs(entries) do
						if entry.id == active_id then return entry end
					end
					return nil
				end,
				check_availability = function()
					validation_calls = validation_calls + 1
					return check_result
				end,
			}
			package.loaded["modules.llm"] = {
				api_remote = api_remote,
				persist_api_entries = function()
					persistence_calls = persistence_calls + 1
				end,
			}
			package.loaded["infra.i18n"] = { get = function(key) return key end }
			package.loaded["infra.logger"] = {
				debug = function() end,
				info = function() end,
				warn = function() end,
				error = function() end,
			}
			package.loaded["infra.dialog_util"] = {
				text_prompt = function()
					prompt_index = prompt_index + 1
					return "button.ok", prompt_values[prompt_index]
				end,
			}
			package.loaded["infra.notifications"] = {
				notify = function(title, body, level)
					notifications[#notifications + 1] = {
						title = title, body = body, level = level,
					}
					return true
				end,
			}
			local command_renderer = assert(require("menu.renderer").new({
				platform = "hs",
				manifest_path = function() return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json" end,
				json_decode = require("adapters.json_codec").decode,
				i18n = {
			get = package.loaded["infra.i18n"].get,
			-- These command rows never request a translated section.
			section = function() return {} end,
		},
				logger = helpers.make_logger_stub(),
			}))
			package.loaded["infra.manifest_menu"] = {
				command_row = command_renderer.command_row,
				template_rows = command_renderer.template_rows,
			get_array = command_renderer.get_array,
				render_rows = function(rows) return rows end,
			}
			package.loaded["ui.menu.menu_llm.api_panel"] = nil

			local panel = require("ui.menu.menu_llm.api_panel")
			local state = { llm_backend = "api", llm_model = previous_entry.model }
			local context = {
				state = state,
				paused = false,
				is_paused = function() return false end,
				keymap = { reset_predictions_for_configuration = function() return true end },
				update_menu = function() updates = updates + 1 end,
				WarmupCtrl = { warmup = function() warmups = warmups + 1 end },
			}
			local _, rows = panel.build(context)
			local add_action = nil
			for _, row in ipairs(rows) do
				if type(row.items) == "table" and row.items[1] then
					add_action = row.items[1].action
				end
			end
			helpers.assert_type(add_action, "function")

			local receipt = add_action()
			assertions(receipt, {
				validation_calls = validation_calls, persistence_calls = persistence_calls,
				entries = entries, active_id = active_id, state = state,
				previous_entry = previous_entry, warmups = warmups, updates = updates,
				notifications = notifications, panel = panel, context = context,
			})
		end)
end

helpers.describe("API panel validation acquisition", function()
	helpers.it("rolls back and releases the lease when availability refuses", function()
		run_add_action(false, function(receipt, f)
			local validation_calls, persistence_calls = f.validation_calls, f.persistence_calls
			local entries, active_id, state = f.entries, f.active_id, f.state
			local previous_entry, warmups, updates = f.previous_entry, f.warmups, f.updates
			local notifications, panel, context = f.notifications, f.panel, f.context
			helpers.assert_true(receipt == false, "a refused probe must answer a literal false receipt")
			helpers.assert_eq(validation_calls, 1)
			helpers.assert_eq(persistence_calls, 0)
			helpers.assert_eq(#entries, 1)
			helpers.assert_true(entries[1] == previous_entry,
				"the exact prior entry list must be restored after launch refusal")
			helpers.assert_eq(active_id, previous_entry.id)
			helpers.assert_eq(state.llm_model, previous_entry.model)
			helpers.assert_eq(warmups, 0)
			helpers.assert_eq(updates, 1,
				"rollback must publish one rebuilt menu with the lease released")
			helpers.assert_eq(#notifications, 1)
			helpers.assert_eq(notifications[1].level, "error")

			local _, released_rows = panel.build(context)
			local released_add = nil
			for _, row in ipairs(released_rows) do
				if type(row.items) == "table" and row.items[1] then
					released_add = row.items[1]
				end
			end
			helpers.assert_eq(released_add.disabled, nil)
			helpers.assert_type(released_add.action, "function",
				"the refused probe must not strand the process-wide mutation lease")
		end)
	end)

	helpers.it("answers a literal true receipt once the probe owns the staged entry", function()
		run_add_action(true, function(receipt, f)
			helpers.assert_true(receipt == true,
				"the backend switch requires a literal true receipt from the add action")
			helpers.assert_eq(f.validation_calls, 1)
			helpers.assert_eq(#f.entries, 2, "the entry stays staged while its probe runs")
			helpers.assert_true(f.active_id ~= f.previous_entry.id)
			helpers.assert_eq(#f.notifications, 0)
		end)
	end)
end)
