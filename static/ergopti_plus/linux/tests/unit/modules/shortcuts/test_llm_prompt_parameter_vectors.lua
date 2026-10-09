--- tests/unit/modules/shortcuts/test_llm_prompt_parameter_vectors.lua

--- ==============================================================================
--- MODULE: llm_prompt_prediction parameter (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/action_parameters/llm_prompt_vectors.json, which
--- the macOS and Windows suites and the picker page replay too, through the
--- gesture validator, and pins what the binding editors receive for the kind:
--- the zenity prompt listing the prompts, its refusal, and the picker page's
--- payload (prompt choices, menu count, "edit the current action").
---
--- ROOT CAUSE ENCODED:
--- validate_action_parameter raised on an unknown kind, so a configuration
--- holding an llm_prompt binding could not even be loaded, and the picker was
--- told the kind of text/key/shortcut rows only, so its "edit the current
--- action" button could never reopen a URL, a wrap pair or a prompt.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/action_parameters/llm_prompt_vectors.json"
local ACTION = "llm_prompt_prediction"

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the llm_prompt corpus is not valid JSON")
end

local Gestures = helpers.load_module("modules.gestures.manager")
local PromptAction = require("llm.prompt_action")

--- Runs body over a fresh profile registry on isolated AI preferences.
--- @param body function
--- @param initial table|nil Stored preference values.
local function with_profiles(body, initial)
	local ProfileSettings = require("modules.llm.profile_settings")
	ProfileSettings._reset()
	local ok, err = pcall(PreferencesFixture.with, function() body(ProfileSettings) end,
		{ initial = initial })
	ProfileSettings._reset()
	if not ok then error(err, 0) end
end

helpers.describe("llm_prompt_prediction parameter replays the shared llm_prompt corpus", function()
	local corpus = read_corpus()

	helpers.it("the parameter is declared by the generated catalogue", function()
		helpers.assert_eq(Gestures.get_action_parameter_spec(ACTION), "llm_prompt")
		helpers.assert_true(#corpus.vectors >= 10, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("llm_prompt vector '" .. vector.id .. "'", function()
			local valid = vector.valid ~= false
			helpers.assert_eq(Gestures.validate_action_parameter(ACTION, vector.value), valid,
				vector.id .. ": validation")
			local parsed = PromptAction.parse(vector.value)
			if not valid then
				helpers.assert_eq(parsed, nil, vector.id .. ": an invalid value names no prompt")
				return
			end
			helpers.assert_eq(parsed.profile_id, vector.profile_id, vector.id .. ": profile id")
			helpers.assert_eq(parsed.num_predictions, vector.num_predictions, vector.id .. ": count")
				helpers.assert_eq(parsed.translation_target, vector.translation_target, vector.id .. ": target")
		end)
	end

	helpers.it("accepts a prompt that does not exist yet: existence is a run-time question", function()
		helpers.assert_true(Gestures.validate_action_parameter(ACTION, "user_deleted_long_ago|4"),
			"deleting a custom prompt must not make its bindings unloadable")
	end)
end)

helpers.describe("llm_prompt_prediction parameter: what the binding editors show", function()
	helpers.it("the zenity prompt lists every prompt as '<id> — <label>'", function()
		with_profiles(function()
			local prompt = Gestures.get_action_parameter_prompt(ACTION)
			helpers.assert_true(prompt:find("{1}", 1, true) == nil, "the placeholder is filled: " .. prompt)
			for _, id in ipairs({ "raw", "basic", "advanced", "batch_advanced", "rewrite" }) do
				helpers.assert_true(prompt:find("\n" .. id .. " \226\128\148 ", 1, true) ~= nil
					or prompt:find("^" .. id .. " \226\128\148 ") ~= nil,
					"the prompt lists '" .. id .. "': " .. prompt)
			end
			helpers.assert_true(prompt:find("rewrite \226\128\148 "
				.. require("infra.i18n").get("llm.profile.rewrite.label"), 1, true) ~= nil,
				"each line carries the menu label")
		end)
	end)

	helpers.it("the refusal is the kind's own", function()
		helpers.assert_eq(Gestures.get_action_parameter_error(ACTION),
			require("infra.i18n").get("dialog.gestures.param_err_llm_prompt"))
	end)

	helpers.it("the picker's editor gets every parameterized row, the prompt choices and the menu count", function()
		with_profiles(function()
			local items = {
				{ type = "heading", level = 1, text = "AI" },
				{ type = "action", id = ACTION, label = "Prompt" },
				{ type = "action", id = "open_url", label = "Open a link" },
				{ type = "action", id = "wrap_selection", label = "Wrap" },
				{ type = "action", id = "llm_predict_rewrite", label = "Rewrite" },
			}
			helpers.assert_true(Gestures.set_action_parameter("tap_3", ACTION, "rewrite|2"))
			local fields = Gestures.get_picker_parameter_fields(items, "tap_3")
			helpers.assert_eq(items[2].parameter, "llm_prompt", "the prompt row names its kind")
			helpers.assert_eq(items[2].parameterValue, "rewrite|2", "and the value its binding holds")
			helpers.assert_eq(items[3].parameter, "url", "a URL row is marked too, for 'edit current'")
			helpers.assert_eq(items[4].parameter, "wrap_pair", "and a wrap-pair row")
			helpers.assert_eq(items[5].parameter, nil, "a preset takes no parameter")
			helpers.assert_eq(items[1].parameter, nil, "a heading takes nothing")
			helpers.assert_eq(fields.default_count, 3, "the AI menu's prediction count")
			local ids = {}
			for index, choice in ipairs(fields.prompt_choices) do ids[index] = choice.value end
			helpers.assert_eq(table.concat(ids, ","), "raw,basic,advanced,batch_advanced,rewrite,tone_familiar,tone_neutral,tone_formal,tone_very_formal,translate_en,translate_ja,user_mine",
				"the built-ins in menu order, then the user's own")
			helpers.assert_eq(fields.prompt_choices[12].label, "Mine", "a user prompt shows its own label")
			helpers.assert_eq(fields.prompt_choices[5].label,
				require("infra.i18n").get("llm.profile.rewrite.label"), "a built-in shows its menu label")
			helpers.assert_eq(fields.parameter_strings.prompts.llm_prompt,
				Gestures.get_action_parameter_prompt(ACTION))
			helpers.assert_eq(fields.parameter_strings.errors.llm_prompt,
				Gestures.get_action_parameter_error(ACTION))
			helpers.assert_eq(fields.parameter_strings.prompts.url, nil, "the page does not edit a URL")
			local i18n = require("infra.i18n")
			helpers.assert_eq(fields.edit_current_label, i18n.get("dialog.action_picker.edit_current"))
			helpers.assert_eq(fields.parameter_strings.promptLabel, i18n.get("dialog.action_picker.prompt_label"))
			helpers.assert_eq(fields.parameter_strings.countLabel, i18n.get("dialog.action_picker.count_label"))
			helpers.assert_true(fields.parameter_strings.countDefault:find("{1}", 1, true) ~= nil,
				"the page fills the default count itself")
		end, {
			["llm.profiles.num_predictions"] = 3,
			["llm.user_profiles"] = require("modules.llm.profile_registry_codec").encode({
				{ id = "user_mine", label = "Mine", system_single = "Continue.", batch = false },
			}),
		})
	end)

	helpers.it("the bridge hands the page the prompt choices, the count and the edit label", function()
		local Bridge = helpers.load_module("ui.action_picker.bridge")
		local payload = Bridge.build_init_payload({
			items = {},
			prompt_choices = { { value = "rewrite", label = "Rewrite" } },
			default_count = 4,
			edit_current_label = "Edit",
		})
		helpers.assert_eq(payload.promptChoices[1].value, "rewrite")
		helpers.assert_eq(payload.defaultCount, 4)
		helpers.assert_eq(payload.editCurrentLabel, "Edit")
	end)
end)

helpers.describe("llm_prompt_prediction parameter: the dispatcher hands the stored value over", function()
	helpers.it("runs the handler with the binding's own value", function()
		local G = helpers.load_module("modules.gestures.manager")
		local seen = {}
		G.init({ enabled = false, action_handlers = {
			[ACTION] = function(binding, parameter) seen[#seen + 1] = { binding, parameter } end,
		} })
		helpers.assert_true(G.set_action_parameter("tap_3", ACTION, "rewrite|2"))
		G.execute_action(ACTION, "tap_3")
		helpers.assert_eq(#seen, 1, "a valid stored value runs the action")
		helpers.assert_eq(seen[1][2], "rewrite|2", "with the value stored for that binding")
	end)
end)
