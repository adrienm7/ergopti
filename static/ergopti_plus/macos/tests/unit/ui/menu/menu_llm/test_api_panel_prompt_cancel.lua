--- tests/unit/ui/menu/menu_llm/test_api_panel_prompt_cancel.lua

--- ==============================================================================
--- MODULE: API Panel Prompt Cancellation Regression
--- DESCRIPTION:
--- Every field prompt preserves the distinction between an explicit Cancel and
--- an accepted empty value. Cancellation stops the Add flow before runtime state,
--- validation, persistence, or prediction identity can change.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"modules.llm",
	"infra.i18n",
	"infra.logger",
	"infra.dialog_util",
	"infra.notifications",
	"infra.manifest_menu",
	"ui.menu.menu_llm.api_panel",
}

local function run_add_fixture(prompt_result)
	local observations = nil
	helpers.with_fresh_modules(MODULES, function()
		local entries = {}
		local active_id = ""
		local prompt_calls = 0
		local validation_calls = 0
		local persistence_calls = 0
		local reset_calls = 0
		local staged_entry = nil
		local api_remote = {
			PROVIDER_ORDER = { "openai" },
			PROVIDERS = {
				openai = {
					label = "OpenAI",
					base_url = "https://api.example.invalid/v1",
					default_model = "default-model",
				},
			},
			get_entries = function() return entries end,
			set_entries = function(value) entries = value end,
			get_active_entry_id = function() return active_id end,
			set_active_entry_id = function(value) active_id = value end,
			get_active_entry = function() return nil end,
			check_availability = function(model)
				validation_calls = validation_calls + 1
				staged_entry = entries[1]
				return false, model
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
				prompt_calls = prompt_calls + 1
				return prompt_result(prompt_calls)
			end,
		}
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.manifest_menu"] = {
			render_rows = function(rows) return rows end,
		}
		package.loaded["ui.menu.menu_llm.api_panel"] = nil

		local panel = require("ui.menu.menu_llm.api_panel")
		local state = { llm_backend = "api", llm_model = "prior-model" }
		local _, rows = panel.build({
			state = state,
			paused = false,
			keymap = {
				reset_predictions = function()
					reset_calls = reset_calls + 1
					return true
				end,
			},
			update_menu = function() end,
			WarmupCtrl = { warmup = function() end },
		})
		local add_action = nil
		for _, row in ipairs(rows) do
			if type(row.items) == "table" and row.items[1] then
				add_action = row.items[1].action
			end
		end
		helpers.assert_type(add_action, "function")
		local result = add_action()
		observations = {
			result = result,
			prompt_calls = prompt_calls,
			validation_calls = validation_calls,
			persistence_calls = persistence_calls,
			reset_calls = reset_calls,
			entries = entries,
			active_id = active_id,
			model = state.llm_model,
			staged_entry = staged_entry,
		}
	end)
	return observations
end

helpers.describe("API panel prompt cancellation", function()
	for cancel_index = 1, 4 do
		helpers.it("aborts when field " .. tostring(cancel_index) .. " is cancelled", function()
			local values = {
				"https://api.example.invalid/v1", "secret", "custom-model", "Custom",
			}
			local got = run_add_fixture(function(index)
				if index == cancel_index then
					if index % 2 == 0 then return "ignored", "button.cancel" end
					return "button.cancel", "ignored"
				end
				return "OK", values[index]
			end)

			helpers.assert_eq(got.prompt_calls, cancel_index,
				"Cancel must stop before the next field prompt")
			helpers.assert_eq(got.validation_calls, 0)
			helpers.assert_eq(got.persistence_calls, 0)
			helpers.assert_eq(got.reset_calls, 0)
			helpers.assert_eq(#got.entries, 0)
			helpers.assert_eq(got.active_id, "")
			helpers.assert_eq(got.model, "prior-model")
			helpers.assert_true(got.result ~= true,
				"a cancelled action must not report a committed mutation")
		end)
	end

	helpers.it("keeps accepted empty optional fields distinct from Cancel", function()
		local values = { "", "secret", "", "" }
		local got = run_add_fixture(function(index)
			return "OK", values[index]
		end)

		helpers.assert_eq(got.prompt_calls, 4)
		helpers.assert_eq(got.validation_calls, 1)
		helpers.assert_eq(got.reset_calls, 1)
		helpers.assert_type(got.staged_entry, "table")
		helpers.assert_eq(got.staged_entry.base_url, "")
		helpers.assert_eq(got.staged_entry.model, "default-model")
		helpers.assert_eq(got.staged_entry.label, "OpenAI")
	end)
end)
