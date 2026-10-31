--- tests/unit/ui/menu/menu_llm/api_panel/test_api_panel_account_address.lua

--- ==============================================================================
--- MODULE: API Panel Per-Account Address
--- DESCRIPTION:
--- A provider whose address names the user's account writes a template in
--- api_providers.json ("https://{resource}.openai.azure.com/openai/v1"). The
--- Add flow asks one value per placeholder instead of a URL, stores the filled
--- address as the entry's base_url, and refuses a value that would change the
--- host or an empty model, since such a provider has no default model.
---
--- ROOT CAUSE ENCODED:
--- These providers could only be reached through the generic OpenAI-compatible
--- entry, the user typing the whole address.
--- ==============================================================================

local helpers = require("tests.helpers")

local AZURE = {
	label = "Azure OpenAI",
	base_url = "https://{resource}.openai.azure.com/openai/v1",
	default_model = "",
}

local MODULES = {
	"modules.llm",
	"infra.i18n",
	"infra.logger",
	"infra.dialog_util",
	"infra.notifications",
	"infra.manifest_menu",
	"ui.menu.menu_llm.api_panel",
}

local function run_add_fixture(provider, prompt_result)
	local observations = nil
	helpers.with_fresh_modules(MODULES, function()
		local entries = {}
		local active_id = ""
		local prompt_calls = 0
		local prompt_texts = {}
		local notified = {}
		local validation_calls = 0
		local persistence_calls = 0
		local reset_calls = 0
		local staged_entry = nil
		local probe_calls = {}
		local api_remote = {
			PROVIDER_ORDER = { "azure" },
			PROVIDERS = { azure = provider },
			get_entries = function() return entries end,
			set_entries = function(value) entries = value end,
			get_active_entry_id = function() return active_id end,
			set_active_entry_id = function(value) active_id = value end,
			get_active_entry = function() return nil end,
			get_test_request_spec = function()
				return {
					system_prompt = "probe sys", user_text = "ping",
					temperature = 0, max_tokens = 16,
				}
			end,
			check_availability = function(model, on_ok)
				validation_calls = validation_calls + 1
				staged_entry = entries[1]
				if type(on_ok) == "function" then on_ok() end
				return true, model
			end,
			test_request = function(entry, spec, on_ok, on_fail)
				probe_calls[#probe_calls + 1] = {
					entry = entry, on_ok = on_ok, on_fail = on_fail,
				}
				return true
			end,
		}
		package.loaded["modules.llm"] = {
			api_remote = api_remote,
			persist_api_entries = function(callback)
				persistence_calls = persistence_calls + 1
				if type(callback) == "function" then callback(true, nil, true) end
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
			text_prompt = function(title, hint, default_val)
				prompt_calls = prompt_calls + 1
				prompt_texts[prompt_calls] = { title = title, hint = hint, default = default_val }
				return prompt_result(prompt_calls)
			end,
			block_alert = function()
				return "button.cancel"
			end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, text) notified[#notified + 1] = text; return true end,
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
		local state = { llm_backend = "api", llm_model = "prior-model" }
		local _, rows = panel.build({
			state = state,
			paused = false,
			is_paused = function() return false end,
			keymap = {
				reset_predictions_for_configuration = function()
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
		-- The entry rows after the add, the rows before the Add row
		local entry_labels = {}
		local _, rows_after = panel.build({
			state = state, paused = false, is_paused = function() return false end,
			keymap = { reset_predictions_for_configuration = function() return true end },
			update_menu = function() end,
			WarmupCtrl = { warmup = function() end },
		})
		for _, row in ipairs(rows_after) do
			if type(row.items) == "table" then break end
			entry_labels[#entry_labels + 1] = row.label
		end
		observations = {
			entry_labels = entry_labels,
			result = result,
			prompt_calls = prompt_calls,
			prompt_texts = prompt_texts,
			notified = notified,
			validation_calls = validation_calls,
			persistence_calls = persistence_calls,
			reset_calls = reset_calls,
			entries = entries,
			active_id = active_id,
			model = state.llm_model,
			staged_entry = staged_entry,
			probe_calls = probe_calls,
		}
	end)
	return observations
end

helpers.describe("API panel per-account address", function()
	helpers.it("asks the resource, the key and the model, and stages the filled address", function()
		local values = { "contoso", "azure-key", "my-deployment" }
		local got = run_add_fixture(AZURE, function(index) return "button.ok", values[index] end)
		helpers.assert_eq(got.prompt_calls, 3, "resource, key, model: no URL prompt")
		helpers.assert_eq(got.prompt_texts[1].hint, "menu.llm.api_prompt_field.resource")
		helpers.assert_eq(got.prompt_texts[1].default, "")
		helpers.assert_eq(got.prompt_texts[3].default, "", "no catalogue default model")
		helpers.assert_type(got.staged_entry, "table")
		helpers.assert_eq(got.staged_entry.base_url, "https://contoso.openai.azure.com/openai/v1")
		helpers.assert_eq(got.staged_entry.model, "my-deployment")
		helpers.assert_eq(got.validation_calls, 1)
	end)

	helpers.it("refuses a value that would change the host, before the key is asked", function()
		local values = { "evil.example/x?", "azure-key", "my-deployment" }
		local got = run_add_fixture(AZURE, function(index) return "button.ok", values[index] end)
		helpers.assert_eq(got.prompt_calls, 1)
		helpers.assert_eq(got.notified[1], "menu.llm.api_prompt_field_invalid")
		helpers.assert_eq(#got.entries, 0)
		helpers.assert_eq(got.validation_calls, 0)
	end)

	helpers.it("refuses an empty model, since none defaults", function()
		local values = { "contoso", "azure-key", "" }
		local got = run_add_fixture(AZURE, function(index) return "button.ok", values[index] end)
		helpers.assert_eq(got.prompt_calls, 3)
		helpers.assert_eq(#got.entries, 0)
		helpers.assert_eq(got.validation_calls, 0)
		helpers.assert_eq(got.notified[1], "menu.llm.api_prompt_model")
	end)
end)
