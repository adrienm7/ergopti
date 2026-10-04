--- tests/unit/modules/shortcuts/test_llm_vision_parameter_vectors.lua

--- ==============================================================================
--- MODULE: llm_screen_region / llm_screen_full / llm_screen_error parameter (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/vision_vectors.json, which the macOS suite
--- and the AutoHotkey port replay too: the binding values through the gesture
--- validator, the model each resolves to, every request body and the answer
--- reading. Then pins what the binding editors receive for the llm_vision
--- kind: the zenity prompt listing the backends, its refusal, and the picker
--- page's payload (backend choices with their default models, labels).
---
--- ROOT CAUSE ENCODED:
--- validate_action_parameter raises on a kind it does not know, so a
--- configuration holding a screen-action binding could not even be loaded.
--- The catalogue now holds providers that read no image (Backboard's message
--- carries none, Jev is no chat model): the editors must not offer them.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
local ACTIONS = { "llm_screen_region", "llm_screen_full", "llm_screen_error" }
-- The provider formats whose requests carry no image
local NO_IMAGE_FORMATS = { backboard = true, decisions = true }

--- @param relative string Path under _shared/.
--- @return table decoded
local function read_json(relative)
	local fh = assert(io.open(SHARED .. relative, "r"), "cannot open " .. relative)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), relative .. " is not valid JSON")
end

--- Compares two decoded JSON values structurally.
--- @return boolean equal, string|nil where
local function deep_equal(a, b, where)
	where = where or "$"
	if type(a) ~= type(b) then return false, where .. ": " .. type(a) .. " vs " .. type(b) end
	if type(a) ~= "table" then return a == b, a == b and nil or (where .. ": " .. tostring(a) .. " vs " .. tostring(b)) end
	for k, v in pairs(a) do
		local ok, why = deep_equal(v, b[k], where .. "." .. tostring(k))
		if not ok then return false, why end
	end
	for k in pairs(b) do
		if a[k] == nil then return false, where .. "." .. tostring(k) .. " is missing" end
	end
	return true
end

local Gestures = helpers.load_module("modules.gestures.manager")
local Vision = require("llm.vision")
local VisionRequest = require("modules.llm.vision_request")

helpers.describe("llm_vision parameter replays the shared vision corpus", function()
	local corpus = read_json("tests/corpus/llm/vision_vectors.json")
	local config = read_json("modules/llm/vision.json")

	helpers.it("every screen action declares the llm_vision parameter", function()
		for _, action in ipairs(ACTIONS) do
			helpers.assert_eq(Gestures.get_action_parameter_spec(action), "llm_vision", action)
		end
		helpers.assert_true(#corpus.parse_vectors >= 5, "the corpus must hold its vectors")
	end)

	for _, vector in ipairs(corpus.parse_vectors) do
		helpers.it("parse vector '" .. vector.id .. "' through the gesture validator", function()
			local valid = vector.valid ~= false
			for _, action in ipairs(ACTIONS) do
				helpers.assert_eq(Gestures.validate_action_parameter(action, vector.value), valid,
					vector.id .. ": " .. action)
			end
			local parsed = Vision.parse(vector.value)
			if not valid then
				helpers.assert_eq(parsed, nil, vector.id)
				return
			end
			helpers.assert_eq(parsed.backend, vector.backend, vector.id .. ": backend")
			helpers.assert_eq(parsed.model, vector.model, vector.id .. ": model")
		end)
	end

	for _, vector in ipairs(corpus.model_vectors) do
		helpers.it("model vector '" .. vector.id .. "' against the shipped vision.json", function()
			helpers.assert_eq(Vision.resolve_model(Vision.parse(vector.value), VisionRequest.config()), vector.model,
				vector.id)
		end)
	end

	for _, vector in ipairs(corpus.request_vectors) do
		helpers.it("request vector '" .. vector.id .. "'", function()
			local ok, why = deep_equal(Vision.build_request(vector.format, vector.spec), vector.body)
			helpers.assert_true(ok, vector.id .. ": " .. tostring(why))
		end)
	end

	for _, vector in ipairs(corpus.extract_vectors) do
		helpers.it("extract vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Vision.extract(vector.block, vector.tag), vector.text, vector.id)
		end)
	end

	helpers.it("the driver's configuration reader accepts the shipped vision.json unchanged", function()
		local loaded = VisionRequest.config()
		helpers.assert_true(loaded ~= nil, "vision.json loads")
		helpers.assert_eq(loaded.max_image_edge, config.max_image_edge)
		helpers.assert_eq(#loaded.answers, #config.answers)
		helpers.assert_eq(#loaded.error_answers, #config.error_answers)
		local without_error_answers = {}
		for key, value in pairs(config) do without_error_answers[key] = value end
		without_error_answers.error_answers = nil
		helpers.assert_eq(VisionRequest.parse_config(json.encode(without_error_answers)), nil,
			"a file without llm_screen_error's answers is refused")
		helpers.assert_eq(VisionRequest.parse_config('{"screen_tag":"SCREEN:"}'), nil,
			"an incomplete file is refused, never half used")
	end)
end)

helpers.describe("llm_vision parameter: what the binding editors show", function()
	local providers = read_json("modules/llm/api_providers.json")
	local config = read_json("modules/llm/vision.json")
	local i18n = require("infra.i18n")
	-- The providers a screen action may name, in catalogue order
	local vision_ids, excluded = {}, {}
	for _, id in ipairs(providers.provider_order) do
		if NO_IMAGE_FORMATS[providers.providers[id].format] then
			excluded[#excluded + 1] = id
		else
			vision_ids[#vision_ids + 1] = id
		end
	end

	-- Local API capabilities extend the ordinary provider list in shared order.
	local local_catalogue = read_json("modules/llm/local_servers.json")
	for _, id in ipairs({ "omlx", "lmstudio", "llamacpp", "jan" }) do
		vision_ids[#vision_ids + 1] = id
		providers.providers[id] = { label = local_catalogue.servers[id].label, format = "openai" }
	end

	helpers.it("the shared catalogue holds providers that read no image", function()
		helpers.assert_true(#excluded >= 3, "backboard and the two Jev providers: " .. table.concat(excluded, ","))
	end)

	helpers.it("the zenity prompt lists local first, then every provider in catalogue order", function()
		local prompt = Gestures.get_action_parameter_prompt("llm_screen_region")
		helpers.assert_true(prompt:find("{1}", 1, true) == nil, "the placeholder is filled")
		local expected = { "local \226\128\148 " .. i18n.get("llm.vision.local_backend") }
		for _, id in ipairs(vision_ids) do
			expected[#expected + 1] = id .. " \226\128\148 " .. providers.providers[id].label
		end
		local listing = table.concat(expected, "\n")
		helpers.assert_true(prompt:find(listing, 1, true) ~= nil, "the backends, one per line: " .. prompt)
		for _, id in ipairs(excluded) do
			helpers.assert_true(prompt:find("\n" .. id .. " \226\128\148 ", 1, true) == nil, id .. " is not offered")
		end
	end)

	helpers.it("the refusal is the kind's own", function()
		helpers.assert_eq(Gestures.get_action_parameter_error("llm_screen_full"),
			i18n.get("dialog.gestures.param_err_llm_vision"))
	end)

	helpers.it("the picker's editor gets the backends with their default models and the labels", function()
		local items = {
			{ type = "action", id = "llm_screen_region", label = "Region" },
			{ type = "action", id = "llm_screen_full", label = "Full" },
		}
		helpers.assert_true(Gestures.set_action_parameter("tap_3", "llm_screen_region", "openai|gpt-4.1-mini"))
		local fields = Gestures.get_picker_parameter_fields(items, "tap_3")
		helpers.assert_eq(items[1].parameter, "llm_vision")
		helpers.assert_eq(items[1].parameterValue, "openai|gpt-4.1-mini", "the value its binding holds")
		helpers.assert_eq(items[2].parameterValue, "", "the other action holds nothing yet")
		local choices = fields.vision_choices
		helpers.assert_eq(#choices, 1 + #vision_ids, "local and every provider that reads images")
		helpers.assert_eq(choices[1].value, "local")
		helpers.assert_eq(choices[1].label, i18n.get("llm.vision.local_backend"))
		helpers.assert_eq(choices[1].defaultModel, config.default_models["local"])
		for index, id in ipairs(vision_ids) do
			local choice = choices[index + 1]
			helpers.assert_eq(choice.value, id)
			helpers.assert_eq(choice.label, providers.providers[id].label)
			helpers.assert_eq(choice.defaultModel, config.default_models[id] or "", id .. ": default model or \"\"")
		end
		local strings = fields.parameter_strings
		helpers.assert_eq(strings.prompts.llm_vision, Gestures.get_action_parameter_prompt("llm_screen_region"))
		helpers.assert_eq(strings.errors.llm_vision, Gestures.get_action_parameter_error("llm_screen_region"))
		helpers.assert_eq(strings.visionProviderLabel, i18n.get("dialog.action_picker.vision_provider_label"))
		helpers.assert_eq(strings.visionModelLabel, i18n.get("dialog.action_picker.vision_model_label"))
		helpers.assert_eq(strings.visionModelRequired, i18n.get("dialog.action_picker.vision_model_required"))
		helpers.assert_true(strings.visionModelDefault:find("{1}", 1, true) ~= nil,
			"the page fills the default model itself")
	end)

	helpers.it("the bridge hands the page the vision choices", function()
		local Bridge = helpers.load_module("ui.action_picker.bridge")
		local payload = Bridge.build_init_payload({
			items = {},
			vision_choices = { { value = "local", label = "Local", defaultModel = "m" } },
		})
		helpers.assert_eq(payload.visionChoices[1].defaultModel, "m")
	end)
end)
