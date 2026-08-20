--- tests/unit/ui/menu/menu_llm/test_api_panel_persistence_gate.lua

--- ==============================================================================
--- MODULE: Regression — API menu publishes only after durable persistence
--- DESCRIPTION:
--- Drives the real Add action through validation, then rejects the asynchronous
--- persistence callback. No warmup or success UI may occur, and the staged
--- runtime identity must roll back.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("API panel durable persistence gate", function()
	helpers.it("rolls back a validated Add when Keychain persistence fails", function()
		local module_names = {
			"modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
			"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel",
		}
		local saved = {}
		for _, name in ipairs(module_names) do saved[name] = package.loaded[name] end

		local entries = {}
		local active_id = ""
		local persist_callback = nil
		local prompt_values = {
			"https://api.example.invalid/v1", "plain-secret", "model-a", "Entry A",
		}
		local prompt_index = 0
		local notifications = {}
		local warmups = 0
		local updates = 0

		local api_remote = {
			PROVIDER_ORDER = { "openai" },
			PROVIDERS = {
				openai = {
					label = "OpenAI", base_url = "https://api.example.invalid/v1",
					default_model = "model-a",
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
			check_availability = function(_model, on_available) on_available() end,
		}
		package.loaded["modules.llm"] = {
			api_remote = api_remote,
			persist_api_entries = function(callback)
				persist_callback = callback
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.logger"] = {
			debug = function() end, info = function() end, warn = function() end, error = function() end,
		}
		package.loaded["infra.dialog_util"] = {
			text_prompt = function()
				prompt_index = prompt_index + 1
				return "OK", prompt_values[prompt_index]
			end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, level)
				notifications[#notifications + 1] = { title = title, body = body, level = level }
				return true
			end,
		}
		package.loaded["infra.manifest_menu"] = { render_rows = function(rows) return rows end }
		package.loaded["ui.menu.menu_llm.api_panel"] = nil

		local ok, err = xpcall(function()
			local panel = require("ui.menu.menu_llm.api_panel")
			local state = { llm_backend = "api", llm_model = "previous-model" }
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
				if type(row.items) == "table" and row.items[1] then add_action = row.items[1].action end
			end
			helpers.assert_type(add_action, "function")
			add_action()
			helpers.assert_type(persist_callback, "function",
				"validated credentials must enter the async persistence gate")
			helpers.assert_eq(#entries, 1, "entry is staged only in runtime while persistence is pending")
			helpers.assert_eq(warmups, 0, "pending persistence must not warm the remote backend")
			helpers.assert_eq(updates, 0, "pending persistence must not publish a checked menu row")
			helpers.assert_eq(#notifications, 0, "pending persistence must not claim success")
			helpers.assert_eq(add_action(), false,
				"an action captured before Add A must reject Add B while A owns persistence")
			helpers.assert_eq(#entries, 1,
				"rejected Add B must not stage a rollback snapshot containing nondurable A")

			local _, busy_rows = panel.build(context)
			for _, row in ipairs(busy_rows) do
				if type(row.items) == "table" then
					helpers.assert_eq(row.disabled, true, "Add parent must be disabled while mutation is pending")
					helpers.assert_eq(row.items[1].disabled, true,
						"provider Add action must be disabled while mutation is pending")
					helpers.assert_eq(row.items[1].action, nil)
				elseif row.separator ~= true then
					helpers.assert_eq(row.disabled, true,
						"selection and delete siblings must share the mutation lease")
				end
			end
			local busy_picker = panel.build_model_picker(context)
			for _, row in ipairs(busy_picker) do
				if row.separator ~= true then
					helpers.assert_eq(row.disabled, true,
						"No Model and picker selection must share the mutation lease")
					helpers.assert_eq(row.action, nil)
				end
			end

			persist_callback(false, "keychain_encrypt_failed", false)
			helpers.assert_eq(#entries, 0, "failed persistence must restore the prior entry list")
			helpers.assert_eq(active_id, "", "failed persistence must restore the prior active id")
			helpers.assert_eq(state.llm_model, "previous-model")
			helpers.assert_eq(warmups, 0)
			helpers.assert_eq(updates, 1, "rollback should refresh the menu exactly once")
			for _, notification in ipairs(notifications) do
				helpers.assert_true(notification.title ~= "menu.llm.api_validated_title",
					"encryption failure must never emit the validated-success notification")
			end
			local _, released_rows = panel.build(context)
			for _, row in ipairs(released_rows) do
				if type(row.items) == "table" then
					helpers.assert_type(row.items[1].action, "function",
						"rollback must release the mutation lease for the next Add")
				end
			end
		end, debug.traceback)

		for _, name in ipairs(module_names) do package.loaded[name] = saved[name] end
		if not ok then error(err) end
	end)
end)
