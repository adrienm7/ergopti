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

local function run_add_fixture(prompt_result, confirm_choice, seed_entries)
	local observations = nil
	helpers.with_fresh_modules(MODULES, function()
		local entries = seed_entries or {}
		local active_id = ""
		local prompt_calls = 0
		local validation_calls = 0
		local persistence_calls = 0
		local reset_calls = 0
		local staged_entry = nil
		local probe_calls = {}
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
			text_prompt = function()
				prompt_calls = prompt_calls + 1
				return prompt_result(prompt_calls)
			end,
			block_alert = function()
				return confirm_choice
			end,
		}
		package.loaded["infra.notifications"] = { notify = function() return true end }
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
		-- The entry rows after the add, the rows before the Add row
		local entry_labels = {}
		local _, rows_after = panel.build({
			state = state, paused = false, is_paused = function() return false end,
			keymap = { reset_predictions = function() return true end },
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

helpers.describe("API panel prompt cancellation", function()
	-- Three fields since the name one was retired (api-entry-auto-name)
	for cancel_index = 1, 3 do
		helpers.it("aborts when field " .. tostring(cancel_index) .. " is cancelled", function()
			local values = {
				"https://api.example.invalid/v1", "secret", "custom-model",
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
		local values = { "", "secret", "" }
		local got = run_add_fixture(function(index)
			return "OK", values[index]
		end)

		helpers.assert_eq(got.prompt_calls, 3, "URL, key and model: no name is asked (api-entry-auto-name)")
		helpers.assert_eq(got.validation_calls, 1)
		helpers.assert_eq(got.reset_calls, 1)
		helpers.assert_type(got.staged_entry, "table")
		helpers.assert_eq(got.staged_entry.base_url, "")
		helpers.assert_eq(got.staged_entry.model, "default-model")
		helpers.assert_nil(got.staged_entry.label, "no name is stored: the entry is named automatically")
		helpers.assert_eq(got.entry_labels, { "openai/default-model" })
	end)

	helpers.it("names a new entry apart from one of the same provider and model (api-entry-auto-name)", function()
		local values = { "", "secret", "" }
		local got = run_add_fixture(function(index)
			return "OK", values[index]
		end, "button.cancel", {
			{ id = "old", provider = "openai", model = "default-model", label = "Mon nom" },
		})

		helpers.assert_eq(#got.entries, 2, "the new entry must be staged")
		helpers.assert_eq(got.entry_labels, {
			"openai/default-model (api.example.invalid)",
			"openai/default-model (api.example.invalid, 2)",
		}, "another key at the same address is told apart by its order, and the stored label is not shown")
	end)

	helpers.it("offers a probe after add when confirmed", function()
		local values = { "", "secret", "" }
		local got = run_add_fixture(function(index)
			return "OK", values[index]
		end, "button.ok")

		helpers.assert_eq(#got.probe_calls, 1,
			"a confirmed offer must dispatch the probe on the new entry")
		helpers.assert_eq(got.probe_calls[1].entry.id, got.active_id,
			"the probe must target the just-created entry")
	end)

	helpers.it("skips the probe after add when declined", function()
		local values = { "", "secret", "" }
		local got = run_add_fixture(function(index)
			return "OK", values[index]
		end, "button.cancel")

		helpers.assert_eq(#got.probe_calls, 0,
			"a declined offer must persist without probing")
		helpers.assert_eq(#got.entries, 1,
			"declining the probe must not cancel the creation")
	end)
end)
