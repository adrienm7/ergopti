--- tests/unit/ui/menu/menu_llm/test_api_panel_validation_refusal.lua

--- ==============================================================================
--- MODULE: API Panel Validation Refusal Regression
--- DESCRIPTION:
--- A remote entry is staged only while its availability probe owns a terminal
--- callback. An immediate probe refusal restores the prior runtime identity,
--- releases the panel mutation lease, and reports the failed operation.
--- ==============================================================================

local helpers = require("tests.helpers")


helpers.describe("API panel validation acquisition", function()
	helpers.it("rolls back and releases the lease when availability refuses", function()
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
					return false
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
					return "OK", prompt_values[prompt_index]
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
			package.loaded["infra.manifest_menu"] = {
				render_rows = function(rows) return rows end,
			}
			package.loaded["ui.menu.menu_llm.api_panel"] = nil

			local panel = require("ui.menu.menu_llm.api_panel")
			local state = { llm_backend = "api", llm_model = previous_entry.model }
			local context = {
				state = state,
				paused = false,
				keymap = { reset_predictions = function() return true end },
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

			add_action()
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
end)
