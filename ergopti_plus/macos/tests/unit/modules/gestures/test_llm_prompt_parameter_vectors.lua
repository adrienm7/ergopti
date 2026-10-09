--- tests/unit/modules/gestures/test_llm_prompt_parameter_vectors.lua

--- ==============================================================================
--- MODULE: llm_prompt_prediction parameter replays the shared vectors (macOS)
--- DESCRIPTION:
--- The llm_prompt_prediction action takes an llm_prompt parameter:
--- "<profile_id>" or "<profile_id>|<count>". This replays
--- _shared/tests/corpus/action_parameters/llm_prompt_vectors.json, which the
--- Linux and Windows suites and the picker page replay too, through the real
--- gesture validator, and checks the native prompt lists the AI menu's prompts.
---
--- ROOT CAUSE ENCODED:
--- The parameter validator only knew URLs, wrap pairs and send-input values: a
--- prompt binding was refused, and the native prompt had no text for its kind.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local CORPUS = helpers.shared("tests/corpus/action_parameters/llm_prompt_vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the llm_prompt corpus is not valid JSON")
end

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
package.loaded["modules.gestures.engine"] = nil
package.loaded["modules.gestures.actions"] = nil
package.loaded["modules.gestures.conflicts"] = nil
local _gestures = helpers.load_with_stubs("modules.gestures")
local Actions = require("modules.gestures.actions")
local PromptAction = require("llm.prompt_action")

helpers.describe("llm_prompt_prediction parameter replays the shared llm_prompt corpus", function()
	local corpus = read_corpus()

	helpers.it("the parameter is declared and the corpus is loaded", function()
		helpers.assert_eq(Actions.get_action_parameter_spec("llm_prompt_prediction"), "llm_prompt")
		helpers.assert_true(#corpus.vectors >= 10, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("llm_prompt vector '" .. vector.id .. "'", function()
			local valid = vector.valid ~= false
			helpers.assert_eq(Actions.validate_action_parameter("llm_prompt_prediction", vector.value), valid,
				vector.id .. ": validation")
			local parsed = PromptAction.parse(vector.value)
			if valid then
				helpers.assert_eq(parsed.profile_id, vector.profile_id, vector.id .. ": profile id")
				helpers.assert_eq(parsed.num_predictions, vector.num_predictions, vector.id .. ": count")
				helpers.assert_eq(parsed.translation_target, vector.translation_target, vector.id .. ": target")
			else
				helpers.assert_nil(parsed, vector.id .. ": an invalid value names no prompt")
			end
		end)
	end
end)

helpers.describe("llm_prompt parameter: native prompt and refusal", function()
	helpers.it("lists every prompt of the AI menu, built-ins first, then custom ones", function()
		local Selector = require("llm.profile_selector")
		local builtins = Selector.load_built_in_profiles()
		for _, profile in ipairs(builtins) do profile.label = "Label of " .. profile.id end
		local custom = { id = "custom_42", label = "My {n} prompt{s}", system_single = "{context}" }
		local i18n = package.loaded["infra.i18n"]
		local saved_get = i18n.get
		local ok, err = pcall(helpers.with_fresh_modules, {
			"modules.llm", "modules.llm.prediction_engine", "ui.menu.menu_llm.profile_label",
		}, function()
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = { llm_num_predictions = 1 },
				BUILTIN_PROFILES = builtins,
				get_user_profiles = function() return { custom } end,
			}
			package.loaded["modules.llm.prediction_engine"] = {
				get_llm_runtime_setting = function(key)
					if key == "llm_num_predictions" then return true, 3 end
					return false, nil
				end,
			}
			i18n.get = function(key)
				if key == "dialog.gestures.param_llm_prompt" then return "Prompts:\n{1}" end
				return saved_get(key)
			end
			local choices = Actions.llm_prompt_choices()
			helpers.assert_eq(#choices, #builtins + 1, "every built-in and the custom prompt")
			for index, profile in ipairs(builtins) do
				helpers.assert_eq(choices[index].value, profile.id, "built-ins come first, in menu order")
			end
			helpers.assert_eq(choices[#choices].value, "custom_42")
			helpers.assert_eq(choices[#choices].label, "My 3 prompts",
				"labels are the menu's, with the AI menu's count")
			helpers.assert_eq(Actions.llm_prompt_default_count(), 3)

			local prompt = Actions.parameter_prompt("llm_prompt_prediction")
			helpers.assert_true(prompt:find("Prompts:\n", 1, true) == 1, "the localized template is used")
			helpers.assert_true(prompt:find("rewrite — Label of rewrite", 1, true) ~= nil,
				"each prompt is listed as '<id> — <label>': " .. prompt)
			helpers.assert_true(prompt:find("custom_42 — My 3 prompts", 1, true) ~= nil,
				"custom prompts are listed too")
		end)
		i18n.get = saved_get
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses with the llm_prompt error text", function()
		helpers.assert_eq(Actions.parameter_error("llm_prompt_prediction"),
			package.loaded["infra.i18n"].get("dialog.gestures.param_err_llm_prompt"))
	end)
end)
