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
