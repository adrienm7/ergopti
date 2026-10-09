--- tests/unit/modules/shortcuts/test_llm_language_parameter_vectors.lua

--- ==============================================================================
--- MODULE: llm_translate_selection parameter (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/translate_vectors.json, which the macOS
--- suite and the AutoHotkey port replay too: the binding values through the
--- gesture validator, the target language each resolves to, the prompt, the
--- user turn and the answer reading. Then pins what the binding editors receive
--- for the llm_language kind: the zenity prompt listing the languages, its
--- refusal, and the picker page's payload (the choices, "ui" first, and the
--- label).
---
--- ROOT CAUSE ENCODED:
--- validate_action_parameter raises on a kind it does not know, so a
--- configuration holding a translation binding could not even be loaded.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
local ACTION = "llm_translate_selection"

--- @param relative string Path under _shared/.
--- @return table decoded
local function read_json(relative)
	local fh = assert(io.open(SHARED .. relative, "r"), "cannot open " .. relative)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), relative .. " is not valid JSON")
end

local Gestures = helpers.load_module("modules.gestures.manager")
local Translate = require("llm.translate")
local Translation = require("modules.llm.translation")

helpers.describe("llm_language parameter replays the shared translate corpus", function()
	local corpus = read_json("tests/corpus/llm/translate_vectors.json")
	local config = read_json("modules/llm/translate.json")
	local names = read_json("data/locale_names.json")

	helpers.it("the translation action declares the llm_language parameter", function()
		helpers.assert_eq(Gestures.get_action_parameter_spec(ACTION), "llm_language")
		helpers.assert_true(#corpus.parse_vectors >= 5, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.parse_vectors) do
		helpers.it("parse vector '" .. vector.id .. "' through the gesture validator", function()
			helpers.assert_eq(Gestures.validate_action_parameter(ACTION, vector.value), vector.valid, vector.id)
		end)
	end

	for _, vector in ipairs(corpus.target_vectors) do
		helpers.it("target vector '" .. vector.id .. "'", function()
			local code = Translate.target_locale(Translate.parse(vector.value, config, names), config, vector.ui_locale)
			helpers.assert_eq(code, vector.locale, vector.id .. ": locale")
			helpers.assert_eq(Translate.language_name(code, names), vector.language, vector.id .. ": language")
		end)
	end

	for _, vector in ipairs(corpus.prompt_vectors) do
		helpers.it("prompt vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Translate.system_prompt(config, vector.language), vector.prompt, vector.id)
		end)
	end

	for _, vector in ipairs(corpus.user_text_vectors) do
		helpers.it("user text vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Translate.user_text(config, vector.text), vector.user_text, vector.id)
		end)
	end

	for _, vector in ipairs(corpus.extract_vectors) do
		helpers.it("extract vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Translate.extract(config, vector.block), vector.text, vector.id)
		end)
	end

	helpers.it("the driver's reader accepts the shipped files and refuses a broken one", function()
		local data = Translation.data()
		helpers.assert_true(data ~= nil, "translate.json and the locale files load")
		helpers.assert_eq(data.config.max_tokens, config.max_tokens)
		helpers.assert_eq(Translation.parse('{"tag":"TRANSLATION:"}', "{}", "{}"), nil,
			"an incomplete file is refused, never half used")
	end)
end)

helpers.describe("llm_language parameter: what the binding editors show", function()
	local names = read_json("data/locale_names.json")
	local order = read_json("data/locale_order.json")
	local config = read_json("modules/llm/translate.json")
	local i18n = require("infra.i18n")

	--- The label of the interface-language choice for the current locale.
	--- @return string
	local function ui_label()
		local template = i18n.get("llm.translate.ui_language")
		local name = names.locales[i18n.get_locale()].name
		local at = assert(template:find("{1}", 1, true), "the label names the interface language")
		return template:sub(1, at - 1) .. name .. template:sub(at + 3)
	end

	helpers.it("the native input prompt states the shared free-language byte limit", function()
		local prompt = Gestures.get_action_parameter_prompt(ACTION)
		helpers.assert_true(prompt:find("{1}", 1, true) == nil, "the placeholder is filled")
		local template = i18n.get("dialog.gestures.param_llm_language")
		local at = assert(template:find("{1}", 1, true))
		local expected = template:sub(1, at - 1) .. tostring(config.max_language_bytes) .. template:sub(at + 3)
		helpers.assert_eq(prompt, expected, "the native InputBox displays the shared byte limit")
	end)

	helpers.it("the refusal is the kind's own", function()
		helpers.assert_eq(Gestures.get_action_parameter_error(ACTION),
			i18n.get("dialog.gestures.param_err_llm_language"))
	end)

	helpers.it("the picker's editor gets the languages, \"ui\" first, and the label", function()
		local items = { { type = "action", id = ACTION, label = "Translate" } }
		helpers.assert_true(Gestures.set_action_parameter("tap_3", ACTION, "ja"))
		local fields = Gestures.get_picker_parameter_fields(items, "tap_3")
		helpers.assert_eq(items[1].parameter, "llm_language")
		helpers.assert_eq(items[1].parameterValue, "ja", "the value its binding holds")
		local choices = fields.language_choices
		helpers.assert_eq(#choices, 22, "the interface language and the 21 shipped locales")
		helpers.assert_eq(#choices, 1 + #order.order)
		helpers.assert_eq(choices[1].value, "ui")
		helpers.assert_eq(choices[1].label, ui_label())
		for index, code in ipairs(order.order) do
			helpers.assert_eq(choices[index + 1].value, code)
		end
		local strings = fields.parameter_strings
		helpers.assert_eq(strings.languageLabel, i18n.get("dialog.action_picker.language_label"))
		helpers.assert_eq(strings.prompts.llm_language, Gestures.get_action_parameter_prompt(ACTION))
		helpers.assert_eq(strings.errors.llm_language, Gestures.get_action_parameter_error(ACTION))
		helpers.assert_true(Gestures.set_action_parameter("tap_3", ACTION, "FR|invalid") == false,
			"an invalid value is refused")
		helpers.assert_eq(Gestures.get_action_parameter("tap_3", ACTION), "ja",
			"refusal preserves the existing binding")
		helpers.assert_true(Gestures.set_action_parameter("tap_3", ACTION, "Esperanto"),
			"a free language name is accepted through the actual binding owner")
		helpers.assert_eq(Gestures.get_action_parameter("tap_3", ACTION), "Esperanto")
	end)

	helpers.it("the bridge hands the page the language choices", function()
		local Bridge = helpers.load_module("ui.action_picker.bridge")
		local payload = Bridge.build_init_payload({
			items = {},
			language_choices = { { value = "ui", label = "Interface" } },
		})
		helpers.assert_eq(payload.languageChoices[1].value, "ui")
	end)
end)
