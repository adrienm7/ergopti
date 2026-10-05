--- tests/unit/modules/llm/test_api_remote.lua

--- ==============================================================================
--- MODULE: Remote LLM Providers On Linux
--- DESCRIPTION:
--- Linux predicted through a local Ollama only: a hosted API such as Cerebras
--- could not be used at all. These tests pin the wire contract the macOS and
--- Windows drivers already follow, read from the same shared catalogue, and
--- the transport's behaviour on success, refusal and cancellation.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Loads the module over a scripted HTTP client.
--- @return table remote, table calls
local function load_remote()
	local calls = {}
	package.loaded["adapters.http_client"] = {
		get = function(url, headers, options, callback)
			calls.probes = calls.probes or {}
			calls.probes[#calls.probes + 1] = { url = url, headers = headers, callback = callback, options = options }
			return true
		end,
		post = function(url, headers, body, callback, options)
			calls[#calls + 1] = { url = url, headers = headers, body = body, callback = callback, options = options }
			return true
		end,
		cancel = function(owner) calls.cancelled = owner; return true end,
	}
	local remote = helpers.load_module("modules.llm.api_remote")
	remote._reset_for_test()
	return remote, calls
end

local function unload()
	package.loaded["adapters.http_client"] = nil
	package.loaded["modules.llm.api_remote"] = nil
end

local MESSAGES = {
	{ role = "system", content = "Continue the text." },
	{ role = "user", content = "Bonjour, je voulais" },
}




-- =========================================
-- =========================================
-- ======= 1/ Catalogue ====================
-- =========================================
-- =========================================

helpers.describe("api_remote: the shared provider catalogue", function()

	helpers.it("loads Cerebras with its per-model extras", function()
		local remote = load_remote()
		local cerebras = remote.provider("cerebras")
		unload()
		helpers.assert_true(cerebras ~= nil, "Cerebras is in the shared catalogue")
		helpers.assert_eq(cerebras.format, "openai")
		helpers.assert_eq(cerebras.base_url, "https://api.cerebras.ai/v1")
		helpers.assert_true(next(cerebras.model_extras) ~= nil, "its model_extras are kept")
	end)

	helpers.it("keeps only the valid providers of the shared validation corpus, once each", function()
		local remote = load_remote()
		local fh = assert(io.open("../_shared/tests/corpus/api_provider_catalog_validation.json", "r"))
		local catalogue = remote.parse_catalogue(fh:read("*a"))
		fh:close()
		unload()
		helpers.assert_eq(table.concat(catalogue.order, ","), "valid,openai_compat")
	end)

	helpers.it("exposes the shared connectivity probe", function()
		local remote = load_remote()
		local spec = remote.test_request_spec()
		unload()
		helpers.assert_true(spec ~= nil and spec.max_tokens >= 1 and spec.system_prompt ~= "")
	end)

end)




-- =========================================
-- =========================================
-- ======= 2/ Requests =====================
-- =========================================
-- =========================================

helpers.describe("api_remote: requests follow each provider's contract", function()

	helpers.it("Cerebras: bearer key, chat completions, catalogue extras, no streaming", function()
		local remote = load_remote()
		local provider = remote.provider("cerebras")
		local request = assert(remote.build_request({ provider = "cerebras", token = "csk-1" }, MESSAGES,
			{ temperature = 0.2, max_tokens = 40 }))
		unload()
		helpers.assert_eq(request.url, "https://api.cerebras.ai/v1/chat/completions")
		helpers.assert_eq(request.headers.Authorization, "Bearer csk-1")
		local body = Json.decode(request.body)
		helpers.assert_eq(body.model, provider.default_model)
		helpers.assert_eq(body.stream, false)
		helpers.assert_eq(body.max_tokens, 40)
		helpers.assert_eq(body.messages[1].role, "system")
		helpers.assert_eq(body.messages[2].content, "Bonjour, je voulais")
		for field, value in pairs(provider.model_extras[provider.default_model] or {}) do
			helpers.assert_eq(body[field], value, "catalogue extra " .. field .. " is sent")
		end
	end)

	helpers.it("omits an empty system turn (the raw profile)", function()
		local remote = load_remote()
		local request = assert(remote.build_request({ provider = "cerebras", token = "k" },
			{ { role = "user", content = "texte" } }, {}))
		unload()
		local body = Json.decode(request.body)
		helpers.assert_eq(#body.messages, 1)
		helpers.assert_eq(body.messages[1].role, "user")
	end)

	helpers.it("Anthropic: x-api-key and a pinned version, system apart", function()
		local remote = load_remote()
		local request = assert(remote.build_request({ provider = "anthropic", token = "sk-ant" }, MESSAGES, {}))
		unload()
		helpers.assert_eq(request.url, "https://api.anthropic.com/v1/messages")
		helpers.assert_eq(request.headers["x-api-key"], "sk-ant")
		helpers.assert_true(request.headers["anthropic-version"] ~= nil)
		helpers.assert_eq(request.headers.Authorization, nil)
		helpers.assert_eq(Json.decode(request.body).system, "Continue the text.")
	end)

	helpers.it("Gemini: the key is encoded into the URL and a models/ prefix is dropped", function()
		local remote = load_remote()
		local request = assert(remote.build_request({ provider = "gemini", token = "a+b/c", model = "models/gemini-x" },
			MESSAGES, {}))
		unload()
		helpers.assert_true(request.url:find("/models/gemini%-x:generateContent%?key=a%%2Bb%%2Fc$") ~= nil, request.url)
		helpers.assert_eq(remote.redact_url(request.url):find("a%2Bb", 1, true), nil, "the key is redacted from logs")
	end)

	helpers.it("an OpenAI-compatible entry uses its own URL and model", function()
		local remote = load_remote()
		local request = assert(remote.build_request({
			provider = "openai_compat", token = "k", base_url = "http://127.0.0.1:8080/v1/", model = "local",
		}, MESSAGES, {}))
		unload()
		helpers.assert_eq(request.url, "http://127.0.0.1:8080/v1/chat/completions")
		helpers.assert_eq(Json.decode(request.body).model, "local")
	end)

	helpers.it("refuses a URL that could smuggle a credential, and an empty key", function()
		local remote = load_remote()
		local bad_userinfo = remote.build_request({ provider = "openai_compat", token = "k", model = "m",
			base_url = "https://user:pass@host/v1" }, MESSAGES, {})
		local bad_query = remote.build_request({ provider = "openai_compat", token = "k", model = "m",
			base_url = "https://host/v1?x=1" }, MESSAGES, {})
		local no_key = remote.build_request({ provider = "cerebras", token = "" }, MESSAGES, {})
		unload()
		helpers.assert_nil(bad_userinfo)
		helpers.assert_nil(bad_query)
		helpers.assert_nil(no_key)
	end)

end)




-- =========================================
-- =========================================
-- ======= 3/ Replies and transport ========
-- =========================================
-- =========================================

helpers.describe("api_remote: replies, refusals and cancellation", function()

	helpers.it("reads the completion of each format", function()
		local remote = load_remote()
		local openai = remote.extract_text("openai", '{"choices":[{"message":{"content":" que tout va bien"}}]}')
		local anthropic = remote.extract_text("anthropic", '{"content":[{"type":"text","text":"ok"}]}')
		local gemini = remote.extract_text("gemini",
			'{"candidates":[{"content":{"parts":[{"thought":true,"text":"hmm"},{"text":"oui"}]}}]}')
		unload()
		helpers.assert_eq(openai, " que tout va bien")
		helpers.assert_eq(anthropic, "ok")
		helpers.assert_eq(gemini, "oui", "a thought part is not the answer")
	end)

	helpers.it("delivers the text once, through the HTTP owner reserved for remote requests", function()
		local remote, calls = load_remote()
		local got, got_err, count = nil, nil, 0
		remote.chat({ provider = "cerebras", token = "k" }, nil, MESSAGES, {}, nil, function(text, err)
			count = count + 1
			got, got_err = text, err
		end)
		calls[1].callback({ ok = true, status = 200, body = '{"choices":[{"message":{"content":"é bien"}}]}' })
		unload()
		helpers.assert_eq(calls[1].options.owner, "llm_remote")
		helpers.assert_eq(count, 1)
		helpers.assert_eq(got, "é bien")
		helpers.assert_nil(got_err)
	end)

	helpers.it("reports the provider's own explanation of a refusal", function()
		local remote, calls = load_remote()
		local got_err
		remote.chat({ provider = "cerebras", token = "bad" }, nil, MESSAGES, {}, nil, function(_, err) got_err = err end)
		calls[1].callback({ ok = false, status = 401, body = "",
			error_body = '{"message":"Wrong API Key","type":"invalid_request_error"}' })
		unload()
		helpers.assert_eq(got_err, "HTTP 401: Wrong API Key")
	end)

	helpers.it("a cancelled request never calls back", function()
		local remote, calls = load_remote()
		local called = false
		remote.chat({ provider = "cerebras", token = "k" }, nil, MESSAGES, {}, nil, function() called = true end)
		remote.cancel()
		calls[1].callback({ ok = true, status = 200, body = '{"choices":[{"message":{"content":"late"}}]}' })
		unload()
		helpers.assert_eq(calls.cancelled, "llm_remote")
		helpers.assert_true(not called)
	end)

end)


helpers.describe("Local API optional authentication: actual requests (local-api-optional-auth) (local-api-optional-auth)", function()
	helpers.it("dispatches a keyless local chat to its configured address without Authorization (local-api-optional-auth)", function()
		local remote, calls = load_remote()
		local observed = {}
		local accepted = remote.chat({ provider = "lmstudio", token = "", model = "fixture-model",
			base_url = "http://127.0.0.1:19273/v1" }, "fixture-model", MESSAGES, {}, nil,
			function(text, reason) observed.text, observed.reason = text, reason end)
		unload()
		helpers.assert_eq(accepted, true)
		helpers.assert_eq(#calls, 1)
		helpers.assert_eq(calls[1].url, "http://127.0.0.1:19273/v1/chat/completions")
		helpers.assert_eq(calls[1].headers.Authorization, nil)
		helpers.assert_eq(Json.decode(calls[1].body).model, "fixture-model")
	end)

	helpers.it("keeps a provided local key exactly and refuses cloud, generic and unknown empty keys (local-api-optional-auth)", function()
		local remote = load_remote()
		local request = remote.build_request({ provider = "lmstudio", token = " leading-and-trailing ",
			model = "fixture-model", base_url = "http://127.0.0.1:19273/v1" }, MESSAGES, {})
		local refused = {}
		for _, provider in ipairs({ "openai", "openai_compat", "unknown-provider" }) do
			refused[#refused + 1] = remote.build_request({ provider = provider, token = "", model = "fixture-model",
				base_url = "http://127.0.0.1:19273/v1" }, MESSAGES, {}) == nil
		end
		unload()
		helpers.assert_true(request ~= nil)
		helpers.assert_eq(request.headers.Authorization, "Bearer  leading-and-trailing ")
		for _, value in ipairs(refused) do helpers.assert_eq(value, true) end
	end)
end)


helpers.describe("Local API models transport (local-api-optional-auth)", function()
	helpers.it("reads an actual models callback and fences changed identity (local-api-optional-auth)", function()
		local remote, calls = load_remote()
		local entry = { id = "local", provider = "lmstudio", token = "", model = "fixture-model",
			base_url = "http://127.0.0.1:19273/v1" }
		local seen = {}
		local first = remote.models(entry, function(ids, reason) seen.ids, seen.reason = ids, reason end)
		local request = calls.probes and calls.probes[1]
		if request then request.callback({ ok = true, status = 200, body = '{"data":[{"id":"fixture-model"}]}' }) end
		local second = remote.models(entry, function(ids, reason) seen.stale_ids, seen.stale_reason = ids, reason end)
		entry.base_url = "http://127.0.0.1:19274/v1"
		if calls.probes and calls.probes[2] then calls.probes[2].callback({ ok = true, status = 200, body = '{"data":[]}' }) end
		unload()
		helpers.assert_eq(first, true)
		helpers.assert_eq(second, true)
		helpers.assert_eq(request.url, "http://127.0.0.1:19273/v1/models")
		helpers.assert_eq(request.headers.Authorization, nil)
		helpers.assert_eq(request.options.follow_redirects, false)
		helpers.assert_eq(seen.ids[1], "fixture-model")
		helpers.assert_eq(seen.stale_ids, nil)
		helpers.assert_eq(seen.stale_reason, "identity_changed")
	end)

	helpers.it("refuses 401 and malformed models and suppresses a cancelled result (local-api-optional-auth)", function()
		local remote, calls = load_remote()
		local entry = { id = "local", provider = "lmstudio", token = "", model = "fixture-model" }
		local observations = {}
		for _, response in ipairs({ { ok = false, status = 401, body = '{}' },
			{ ok = true, status = 200, body = '{"data":{}}' } }) do
			remote.models(entry, function(ids, reason) observations[#observations + 1] = { ids = ids, reason = reason } end)
			calls.probes[#calls.probes].callback(response)
		end
		remote.models(entry, function(ids, reason) observations[#observations + 1] = { ids = ids, reason = reason } end)
		local stale = calls.probes[#calls.probes]
		local cancelled = remote.cancel()
		stale.callback({ ok = true, status = 200, body = '{"data":[]}' })
		unload()
		helpers.assert_eq(cancelled, true)
		helpers.assert_eq(#observations, 2)
		helpers.assert_eq(observations[1].ids, nil)
		helpers.assert_eq(observations[1].reason, "http_failure")
		helpers.assert_eq(observations[2].ids, nil)
		helpers.assert_eq(observations[2].reason, "invalid_models")
	end)
end)


helpers.describe("Remote provider error envelopes", function()
	local contract = require("test.response_error_contract")
	assert(#contract.vectors == 23, "every independent Lua response vector executes")
	for _, vector in ipairs(contract.vectors) do
		helpers.it("provider response: " .. vector.name, function()
			local remote = load_remote()
			local actual = remote.extract_text(vector.format, vector.body)
			unload()
			helpers.assert_eq(actual, vector.expected, vector.name)
		end)
	end
end)


helpers.describe("Shared provider response error ownership", function()
	helpers.it("checks only a decoded root's own field and preserves false and null", function()
		local formats = require("llm.remote_formats")
		for _, body in ipairs({ '{"error":null}', '{"error":false}', '{"error":""}', '{"error":{}}' }) do
			helpers.assert_true(formats.response_has_error(assert(Json.decode(body))), body)
		end
		for _, value in ipairs({ false, 0, "error", {}, { metadata = { error = true } },
			setmetatable({}, { __index = { error = true } }) }) do
			helpers.assert_eq(formats.response_has_error(value), false)
		end
		helpers.assert_eq(formats.response_has_error(nil), false)
	end)
end)
