--- tests/unit/modules/gestures/test_llm_vision_parameter_vectors.lua

--- ==============================================================================
--- MODULE: llm_screen_* parameter replays the shared vision vectors (macOS)
--- DESCRIPTION:
--- The llm_screen_region and llm_screen_full actions take an llm_vision
--- parameter: "<backend>" or "<backend>|<model>". This replays the parse
--- vectors of _shared/tests/corpus/llm/vision_vectors.json through the real
--- gesture validator, and checks the native prompt and the picker's choices
--- list the local server first, then the API providers that take an image
--- (not Backboard, not a decisions provider) in catalogue order.
---
--- ROOT CAUSE ENCODED:
--- The parameter validator knew no llm_vision kind: a screen-reading binding
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
local _gestures = helpers.load_with_stubs("modules.gestures")
local Actions = require("modules.gestures.actions")

helpers.describe("llm_screen_* parameter replays the shared vision corpus", function()
	local corpus = read_json("tests/corpus/llm/vision_vectors.json")

	helpers.it("both actions declare the llm_vision parameter", function()
		helpers.assert_eq(Actions.get_action_parameter_spec("llm_screen_region"), "llm_vision")
		helpers.assert_eq(Actions.get_action_parameter_spec("llm_screen_full"), "llm_vision")
		helpers.assert_true(#corpus.parse_vectors >= 10, "the corpus must hold its parse vectors")
	end)

	for _, vector in ipairs(corpus.parse_vectors) do
		helpers.it("llm_vision vector '" .. vector.id .. "'", function()
			local valid = vector.valid ~= false
			for _, action in ipairs({ "llm_screen_region", "llm_screen_full" }) do
				helpers.assert_eq(Actions.validate_action_parameter(action, vector.value), valid,
					vector.id .. ": " .. action .. " validation")
			end
		end)
	end
end)

helpers.describe("llm_vision parameter: native prompt, picker choices and refusal", function()
	helpers.it("lists the local server, then every vision provider in catalogue order", function()
		local config = read_json("modules/llm/vision.json")
		local catalogue = read_json("modules/llm/api_providers.json")
		local i18n = package.loaded["infra.i18n"]
		local saved_get = i18n.get
		local ok, err = pcall(helpers.with_fresh_modules, { "modules.llm.api_remote" }, function()
			package.loaded["modules.llm.api_remote"] = {
				PROVIDER_ORDER = catalogue.provider_order,
				PROVIDERS = catalogue.providers,
			}
			i18n.get = function(key)
				if key == "dialog.gestures.param_llm_vision" then return "Backends:\n{1}" end
				if key == "llm.vision.local_backend" then return "Local server" end
				return saved_get(key)
			end
			local choices = Actions.llm_vision_choices()
			-- Backboard carries no image and a decisions provider (Jev) is no
			-- chat model: neither takes a vision request
			local vision_order = {}
			for _, provider_id in ipairs(catalogue.provider_order) do
				local format = catalogue.providers[provider_id].format
				if format ~= "backboard" and format ~= "decisions" then vision_order[#vision_order + 1] = provider_id end
			end
			helpers.assert_true(#vision_order < #catalogue.provider_order, "the catalogue holds non-vision providers")
			helpers.assert_eq(#choices, 1 + #vision_order, "the local server and every vision provider")
			helpers.assert_eq(choices[1].value, "local", "the local server comes first")
			helpers.assert_eq(choices[1].label, "Local server")
			helpers.assert_eq(choices[1].defaultModel, config.default_models["local"])
			for index, provider_id in ipairs(vision_order) do
				local choice = choices[index + 1]
				helpers.assert_eq(choice.value, provider_id, "catalogue order")
				helpers.assert_eq(choice.label, catalogue.providers[provider_id].label)
				helpers.assert_eq(choice.defaultModel, config.default_models[provider_id] or "",
					provider_id .. ": the default vision model, or none")
			end

			local prompt = Actions.parameter_prompt("llm_screen_region")
			helpers.assert_true(prompt:find("Backends:\nlocal — Local server\n", 1, true) == 1,
				"the localized template, the local server on the first line: " .. prompt)
			helpers.assert_true(prompt:find("anthropic — " .. catalogue.providers.anthropic.label, 1, true) ~= nil,
				"each provider is listed as '<id> — <label>': " .. prompt)
			helpers.assert_true(prompt:find("groq — Groq", 1, true) ~= nil, "a new openai-format provider is listed")
			for _, excluded in ipairs({ "backboard", "typesafe", "openrouter_jev" }) do
				helpers.assert_true(prompt:find("\n" .. excluded .. " — ", 1, true) == nil,
					excluded .. " takes no vision request: " .. prompt)
			end
		end)
		i18n.get = saved_get
		if not ok then error(err, 0) end
	end)

	helpers.it("refuses with the llm_vision error text", function()
		helpers.assert_eq(Actions.parameter_error("llm_screen_full"),
			package.loaded["infra.i18n"].get("dialog.gestures.param_err_llm_vision"))
	end)
end)
