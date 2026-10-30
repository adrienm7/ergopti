--- tests/unit/modules/llm/remote/test_api_remote_thinking_off.lua

--- ==============================================================================
--- MODULE: Thinking Off In Every Linux Cloud Request
--- DESCRIPTION:
--- Every request body Linux sends to a cloud provider carries its model
--- family's reasoning control (thinking_off.json) through the provider's
--- thinking_dialect, whatever the format: predictions and the agent through
--- build_request, the screen reading through vision_request.send. A provider
--- refusing an added field with HTTP 400 gets the request once more without
--- it, and never again. A malformed dialect refuses its provider whole.
---
--- ROOT CAUSE ENCODED:
--- Only Cerebras' default model had its reasoning turned off, and only in
--- OpenAI-shape prediction bodies: a Claude 5, Gemini 2.5 or gpt-5.x model
--- spent the small prediction budget thinking, and the screen reading sent no
--- rule at all.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Loads the module over a scripted HTTP client.
--- @return table remote, table calls
local function load_remote()
	local calls = {}
	package.loaded["adapters.http_client"] = {
		get = function() return true end,
		post = function(url, headers, body, callback, options)
			calls[#calls + 1] = { url = url, body = body, callback = callback }
			return true
		end,
		cancel = function() return true end,
	}
	local remote = helpers.load_module("modules.llm.api_remote")
	remote._reset_for_test()
	return remote, calls
end

local function unload()
	package.loaded["adapters.http_client"] = nil
	package.loaded["modules.llm.api_remote"] = nil
	package.loaded["modules.llm.vision_request"] = nil
end

local MESSAGES = {
	{ role = "system", content = "Continue the text." },
	{ role = "user", content = "Bonjour, je voulais" },
}

--- Decodes the body build_request writes for a provider and model.
--- @return table body
local function body_for(provider, model)
	local remote = load_remote()
	local request = assert(remote.build_request({ provider = provider, model = model, token = "k" },
		MESSAGES, { max_tokens = 40 }))
	unload()
	return Json.decode(request.body)
end




-- =========================================
-- =========================================
-- ======= 1/ Every format =================
-- =========================================
-- =========================================

helpers.describe("api_remote: thinking off in every format (thinking-off-everywhere)", function()

	helpers.it("Anthropic: Claude Opus 5 thinks only when asked", function()
		local body = body_for("anthropic", "claude-opus-5")
		helpers.assert_eq(type(body.thinking), "table", "a thinking field is sent")
		helpers.assert_eq(body.thinking.type, "disabled")
	end)

	helpers.it("Anthropic: Claude Opus 5.5 cannot stop thinking, so its effort is the lowest", function()
		local body = body_for("anthropic", "claude-opus-5-5")
		helpers.assert_eq(body.thinking, nil, "disabled is a 400 on this model")
		helpers.assert_eq(body.output_config.effort, "low")
	end)

	helpers.it("Anthropic: Claude 4.x is sent as it is", function()
		local body = body_for("anthropic", "claude-haiku-4-5")
		helpers.assert_eq(body.thinking, nil)
		helpers.assert_eq(body.output_config, nil)
	end)

	helpers.it("Gemini: the budget lands inside the body's own generationConfig", function()
		local body = body_for("gemini", "gemini-2.5-flash")
		helpers.assert_eq(body.generationConfig.thinkingConfig.thinkingBudget, 0)
		helpers.assert_eq(body.generationConfig.maxOutputTokens, 40, "the merge keeps the token budget")
	end)

	helpers.it("OpenAI: gpt-5.1 is sent reasoning_effort none, gpt-4o nothing", function()
		helpers.assert_eq(body_for("openai", "gpt-5.1").reasoning_effort, "none")
		helpers.assert_eq(body_for("openai", "gpt-4o-mini").reasoning_effort, nil)
	end)

	helpers.it("Qwen3 is turned off on every provider, in that provider's dialect", function()
		helpers.assert_eq(body_for("groq", "qwen/qwen3.8-27b").reasoning_effort, "none")
		helpers.assert_eq(body_for("cerebras", "qwen-3.8-27b").reasoning_effort, "none")
		helpers.assert_eq(body_for("together", "Qwen/Qwen3-235B-A22B").reasoning.enabled, false)
		helpers.assert_eq(body_for("openrouter", "qwen/qwen3-32b").reasoning.enabled, false)
	end)

end)




-- =========================================
-- =========================================
-- ======= 2/ Screen reading ===============
-- =========================================
-- =========================================

helpers.describe("vision_request: thinking off in the screen reading", function()

	helpers.it("send() completes a cloud body with the provider's rule", function()
		local remote, calls = load_remote()
		package.loaded["modules.llm.vision_request"] = nil
		local VisionRequest = helpers.load_module("modules.llm.vision_request")
		local target = assert(remote.endpoint({ provider = "anthropic", token = "k" }, "claude-sonnet-5-5"))
		target.provider, target.model = "anthropic", "claude-sonnet-5-5"
		local body = { model = "claude-sonnet-5-5", max_tokens = 600, messages = {} }
		VisionRequest.send(target, body, function() end)
		unload()
		helpers.assert_eq(#calls, 1, "one request is sent")
		helpers.assert_eq(Json.decode(calls[1].body).thinking.type, "between_tools")
	end)

	helpers.it("resolve_target names the provider and model send() completes for", function()
		local source = assert(io.open("modules/llm/vision_request.lua", "r")):read("*a")
		local resolve = source:find("function M.resolve_target", 1, true)
		local named = source:find("target.provider, target.model = backend, model", 1, true)
		helpers.assert_true(resolve ~= nil and named ~= nil and named > resolve,
			"resolve_target must hand send() the provider and the model")
	end)

end)




-- =========================================
-- =========================================
-- ======= 3/ Catalogue ====================
-- =========================================
-- =========================================

helpers.describe("api_remote: a malformed thinking dialect refuses its provider", function()

	helpers.it("the provider is skipped, its neighbours kept", function()
		local remote = load_remote()
		local text = Json.encode({
			provider_order = { "good", "bad" },
			providers = {
				good = { label = "Good", base_url = "https://a.example", default_model = "m", format = "openai",
					thinking_dialect = { effort = { reasoning_effort = "$level" } } },
				bad = { label = "Bad", base_url = "https://b.example", default_model = "m", format = "openai",
					thinking_dialect = { effort = { reasoning_effort = "low" } } },
			},
			model_prices = {},
		})
		local catalogue = remote.parse_catalogue(text)
		unload()
		helpers.assert_eq(table.concat(catalogue.order, ","), "good")
		helpers.assert_true(catalogue.providers.good.thinking_dialect.effort ~= nil)
	end)

end)




-- =========================================
-- =========================================
-- ======= 4/ Refused fields ===============
-- =========================================
-- =========================================

helpers.describe("api_remote: a refused thinking field is dropped once and remembered", function()

	helpers.it("chat() sends the request once more without the field, then never with it", function()
		local remote, calls = load_remote()
		local answers = {}
		local entry = { provider = "deepseek", model = "deepseek-chat", token = "k" }
		remote.chat(entry, nil, MESSAGES, {}, nil, function(text, err) answers[#answers + 1] = { text, err } end)
		helpers.assert_eq(Json.decode(calls[1].body).thinking.type, "disabled", "the generic family turns thinking off")
		calls[1].callback({ ok = false, status = 400, error_body = Json.encode({ error = { message = "Unknown parameter: thinking" } }) })
		helpers.assert_eq(#calls, 2, "the request is sent once more")
		helpers.assert_eq(Json.decode(calls[2].body).thinking, nil, "without the refused field")
		helpers.assert_eq(#answers, 0, "a correction is not a failure")
		local request = assert(remote.build_request(entry, MESSAGES, {}))
		unload()
		helpers.assert_eq(Json.decode(request.body).thinking, nil, "the refusal is remembered")
	end)

	helpers.it("an unrelated HTTP 400 is not a refusal", function()
		local remote, calls = load_remote()
		local answers = 0
		remote.chat({ provider = "openai", model = "gpt-5.1", token = "k" }, nil, MESSAGES, {}, nil,
			function() answers = answers + 1 end)
		calls[1].callback({ ok = false, status = 400, error_body = Json.encode({ error = { message = "max_tokens is too large" } }) })
		unload()
		helpers.assert_eq(#calls, 1, "nothing is sent again")
		helpers.assert_eq(answers, 1, "the failure reaches the caller")
	end)

end)
