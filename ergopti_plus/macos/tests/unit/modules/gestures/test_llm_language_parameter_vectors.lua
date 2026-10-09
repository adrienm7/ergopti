--- tests/unit/modules/gestures/test_llm_language_parameter_vectors.lua

--- ==============================================================================
--- MODULE: llm_translate_selection parameter replays the shared translate vectors (macOS)
--- DESCRIPTION:
--- The llm_translate_selection action takes an llm_language parameter: "ui"
--- (the interface language) or a shipped locale code. This replays the parse
--- vectors of _shared/tests/corpus/llm/translate_vectors.json through the real
--- gesture validator, and checks the native prompt and the picker's choices
--- list the interface language first, named natively, then every shipped locale
--- in the language menu's order.
---
--- ROOT CAUSE ENCODED:
--- The parameter validator knew no llm_language kind: a translation binding
--- was refused and the native prompt had no text for it.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
package.loaded["modules.gestures.engine"] = nil
package.loaded["modules.gestures.actions"] = nil
package.loaded["modules.gestures.conflicts"] = nil
package.loaded["modules.llm.selection_translation"] = nil
local _gestures = helpers.load_with_stubs("modules.gestures")
local Actions = require("modules.gestures.actions")

local ACTION = "llm_translate_selection"

helpers.describe("llm_translate_selection parameter replays the shared translate corpus", function()
	local corpus = read_json("tests/corpus/llm/translate_vectors.json")

	helpers.it("the action declares the llm_language parameter", function()
		helpers.assert_eq(Actions.get_action_parameter_spec(ACTION), "llm_language")
		helpers.assert_true(#corpus.parse_vectors >= 8, "the corpus must hold its parse vectors")
	end)

	for _, vector in ipairs(corpus.parse_vectors) do
		helpers.it("llm_language vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Actions.validate_action_parameter(ACTION, vector.value), vector.valid,
				vector.id .. ": validation")
		end)
	end
end)

helpers.describe("llm_language parameter: native prompt, picker choices and refusal", function()
	--- Runs `scenario` with the interface language `ui_locale` and localized
	--- templates for the prompt and the interface-language choice.
	--- @param ui_locale string
	--- @param scenario function
	local function with_interface(ui_locale, scenario)
		local i18n = package.loaded["infra.i18n"]
		local saved_get, saved_format, saved_locale = i18n.get, i18n.format, i18n.get_locale
		i18n.get_locale = function() return ui_locale end
		i18n.get = function(key)
			if key == "dialog.gestures.param_llm_language" then return "Languages:\n{1}" end
			return saved_get(key)
		end
		i18n.format = function(key, ...)
			if key == "llm.translate.ui_language" then return "Menu language (" .. tostring((...)) .. ")" end
			return saved_format(key, ...)
		end
		local ok, err = pcall(scenario)
		i18n.get, i18n.format, i18n.get_locale = saved_get, saved_format, saved_locale
		if not ok then error(err, 0) end
	end

	helpers.it("lists the interface language first, then every shipped locale in menu order", function()
		local names = read_json("data/locale_names.json")
		local order = read_json("data/locale_order.json").order
		with_interface("fr", function()
			local choices = Actions.llm_language_choices()
			helpers.assert_eq(#choices, 22, "the interface language and the 21 shipped locales")
			helpers.assert_eq(#choices, 1 + #order)
			helpers.assert_eq(choices[1].value, "ui", "the interface language comes first")
			helpers.assert_eq(choices[1].label, "Menu language (Français)", "named natively")
			for index, code in ipairs(order) do
				helpers.assert_eq(choices[index + 1].value, code, "language menu order")
				helpers.assert_eq(choices[index + 1].label, names.locales[code].flag .. " " .. names.locales[code].name)
			end

			local prompt = Actions.parameter_prompt(ACTION)
			helpers.assert_eq(prompt, "Languages:\n" .. tostring(read_json("modules/llm/translate.json").max_language_bytes),
				"the InputBox substitutes the declared byte limit instead of a locale catalogue")
		end)
	end)

	helpers.it("names the current interface language", function()
		with_interface("ja", function()
			helpers.assert_eq(Actions.llm_language_choices()[1].label, "Menu language (日本語)")
		end)
	end)

	helpers.it("refuses with the llm_language error text", function()
		helpers.assert_eq(Actions.parameter_error(ACTION),
			package.loaded["infra.i18n"].get("dialog.gestures.param_err_llm_language"))
	end)
end)
