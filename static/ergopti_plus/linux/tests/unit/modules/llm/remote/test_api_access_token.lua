--- tests/unit/modules/llm/remote/test_api_access_token.lua

--- ==============================================================================
--- MODULE: Access-Token Providers (Linux)
--- DESCRIPTION:
--- A provider whose auth block declares a token exchange (IBM watsonx, Google
--- Vertex AI) never receives the stored key: the driver exchanges it for an
--- access token, sends that token as Bearer, refreshes it before it ends,
--- waits for it in the key test, and does not ask the token service again for
--- a minute after a refusal. The real api_remote runs over a scripted HTTP
--- client.
---
--- ROOT CAUSE ENCODED:
--- Sent as Bearer, the stored key itself was refused with HTTP 401.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local IBM = {
	id = "ibm_fixture", label = "IBM fixture", base_url = "https://us-south.ml.cloud.ibm.com/ml/gateway/v1",
	default_model = "", format = "openai", thinking_dialect = {}, model_extras = {},
}
local ENTRY = { id = "w1", provider = "ibm_fixture", token = "ibm-api-key", model = "ibm/granite-4-h-small" }
local MESSAGES = { { role = "system", content = "S" }, { role = "user", content = "u" } }

--- Runs body against the real api_remote over a scripted HTTP client and clock.
--- @param body function body(remote, calls, clock)
local function with_remote(body)
	local names = { "adapters.http_client", "modules.llm.api_remote", "infra.monotonic", "logger.shim" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local calls, clock = {}, { now = 1000 }
	package.loaded["adapters.http_client"] = {
		post = function(url, headers, request_body, callback)
			calls[#calls + 1] = { url = url, headers = headers, body = request_body, callback = callback }
			return true
		end,
		get = function() return false end,
		cancel = function() return true end,
	}
	package.loaded["infra.monotonic"] = {
		now_ms = function() return clock.now * 1000 end,
		now_sec = function() return clock.now end,
	}
	local logs = {}
	local logger = { set_level = function() end, set_sink = function() end }
	for _, level in ipairs({ "debug", "trace", "done", "info", "start", "success", "warn", "error" }) do
		logger[level] = function(_, fmt, ...)
			local formatted, text = pcall(string.format, fmt, ...)
			logs[#logs + 1] = level .. ": " .. (formatted and text or tostring(fmt))
		end
	end
	package.loaded["logger.shim"] = logger
	clock.logs = logs
	package.loaded["modules.llm.api_remote"] = nil
	local ok, err = pcall(function()
		local remote = require("modules.llm.api_remote")
		remote._reset_for_test()
		local auth = assert(require("llm.api_token_exchange").parse({
			kind = "token_exchange", token_url = "https://iam.cloud.ibm.com/identity/token",
			body = { grant_type = "urn:ibm:params:oauth:grant-type:apikey", apikey = "{key}" },
			token_field = "access_token", expires_field = "expires_in",
			default_expires_seconds = 3600, refresh_margin_seconds = 300,
		}))
		IBM.auth = auth
		local original = remote.provider
		remote.provider = function(id) return id == IBM.id and IBM or original(id) end
		body(remote, calls, clock)
	end)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

--- Answers call `index` with a status and a JSON body.
local function answer(calls, index, status, root)
	calls[index].callback({ ok = status == 200, status = status, body = status == 200 and Json.encode(root) or "",
		error_body = status ~= 200 and Json.encode(root) or nil })
end




-- =========================================
-- =========================================
-- ======= 1/ The exchange =================
-- =========================================
-- =========================================

helpers.describe("Access-token providers: the key is exchanged, never sent", function()
	helpers.it("the first request waits for the token; the next carries it as Bearer", function()
		with_remote(function(remote, calls)
			local endpoint, reason = remote.endpoint(ENTRY, ENTRY.model)
			helpers.assert_nil(endpoint, "no token yet")
			helpers.assert_contains(reason, "being fetched")
			helpers.assert_eq(#calls, 1, "one exchange")
			helpers.assert_eq(calls[1].url, "https://iam.cloud.ibm.com/identity/token")
			helpers.assert_eq(calls[1].body, "apikey=ibm-api-key&grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey")
			helpers.assert_eq(calls[1].headers["Content-Type"], "application/x-www-form-urlencoded")
			helpers.assert_nil(remote.endpoint(ENTRY, ENTRY.model), "a pending exchange is not asked twice")
			helpers.assert_eq(#calls, 1)
			answer(calls, 1, 200, { access_token = "iam-token", expires_in = 3600 })
			endpoint = remote.endpoint(ENTRY, ENTRY.model)
			helpers.assert_eq(endpoint.url, IBM.base_url .. "/chat/completions")
			helpers.assert_eq(endpoint.headers.Authorization, "Bearer iam-token", "the token, never the key")
			helpers.assert_eq(#calls, 1, "a fresh token is reused")
		end)
	end)

	helpers.it("a token near its end is still sent while a new one is fetched", function()
		with_remote(function(remote, calls, clock)
			remote.endpoint(ENTRY, ENTRY.model)
			answer(calls, 1, 200, { access_token = "first", expires_in = 3600 })
			clock.now = clock.now + 3400
			helpers.assert_eq(remote.endpoint(ENTRY, ENTRY.model).headers.Authorization, "Bearer first")
			helpers.assert_eq(#calls, 2, "within the margin: a refresh in the background")
			answer(calls, 2, 200, { access_token = "second", expires_in = 3600 })
			helpers.assert_eq(remote.endpoint(ENTRY, ENTRY.model).headers.Authorization, "Bearer second")
		end)
	end)

	helpers.it("a refused key is not asked again for a minute, and the reason reaches the request", function()
		with_remote(function(remote, calls, clock)
			remote.endpoint(ENTRY, ENTRY.model)
			answer(calls, 1, 400, { errorMessage = "Provided API key could not be found" })
			local endpoint, reason = remote.endpoint(ENTRY, ENTRY.model)
			helpers.assert_nil(endpoint)
			helpers.assert_eq(reason, "the token exchange answered HTTP 400")
			helpers.assert_eq(#calls, 1, "no second exchange at once")
			clock.now = clock.now + 61
			remote.endpoint(ENTRY, ENTRY.model)
			helpers.assert_eq(#calls, 2, "asked again after the pause")
		end)
	end)

	helpers.it("the key test waits for the token, then sends the probe with it", function()
		with_remote(function(remote, calls, clock)
			local verdict
			remote.test(ENTRY, function(ok, detail) verdict = { ok = ok, detail = detail } end)
			helpers.assert_eq(#calls, 1, "the exchange first")
			answer(calls, 1, 200, { access_token = "iam-token", expires_in = 3600 })
			helpers.assert_eq(#calls, 2, "then the probe: " .. table.concat(clock.logs, " | "))
			helpers.assert_eq(calls[2].url, IBM.base_url .. "/chat/completions")
			helpers.assert_eq(calls[2].headers.Authorization, "Bearer iam-token")
			answer(calls, 2, 200, { choices = { { message = { content = "OK" } } } })
			helpers.assert_eq(verdict.ok, true)
		end)
	end)

	helpers.it("the key test reports a refused exchange without sending the probe", function()
		with_remote(function(remote, calls)
			local verdict
			remote.test(ENTRY, function(ok, detail) verdict = { ok = ok, detail = detail } end)
			answer(calls, 1, 401, { errorMessage = "no" })
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(verdict.ok, false)
			helpers.assert_eq(verdict.detail, "the token exchange answered HTTP 401")
			remote.test(ENTRY, function(ok, detail) verdict = { ok = ok, detail = detail } end)
			helpers.assert_eq(#calls, 1, "a second test within the pause asks nothing")
			helpers.assert_eq(verdict.detail, "the token exchange answered HTTP 401")
		end)
	end)
end)




-- =========================================
-- =========================================
-- ======= 2/ The catalogue ================
-- =========================================
-- =========================================

helpers.describe("Access-token providers: the shipped rows", function()
	helpers.it("a watsonx entry exchanges its IBM API key at IBM's token service", function()
		with_remote(function(remote, calls)
			local entry = { id = "x", provider = "watsonx", token = "ibm-key", model = "ibm/granite-4-h-small",
				base_url = "https://us-south.ml.cloud.ibm.com/ml/gateway/v1" }
			helpers.assert_nil(remote.endpoint(entry, entry.model))
			helpers.assert_eq(calls[1].url, "https://iam.cloud.ibm.com/identity/token")
			helpers.assert_contains(calls[1].body, "apikey=ibm-key")
			answer(calls, 1, 200, { access_token = "iam", expires_in = 3600 })
			local endpoint = remote.endpoint(entry, entry.model)
			helpers.assert_eq(endpoint.url, "https://us-south.ml.cloud.ibm.com/ml/gateway/v1/chat/completions")
			helpers.assert_eq(endpoint.headers.Authorization, "Bearer iam")
		end)
	end)

	helpers.it("a Vertex AI entry refreshes the token of its authorized_user credentials", function()
		with_remote(function(remote, calls)
			local entry = { id = "v", provider = "vertex", model = "google/gemini-3.5-flash",
				token = Json.encode({ type = "authorized_user", client_id = "cid", client_secret = "cs", refresh_token = "rt" }),
				base_url = "https://aiplatform.googleapis.com/v1/projects/p1/locations/global/endpoints/openapi" }
			helpers.assert_nil(remote.endpoint(entry, entry.model))
			helpers.assert_eq(calls[1].url, "https://oauth2.googleapis.com/token")
			helpers.assert_eq(calls[1].body, "client_id=cid&client_secret=cs&grant_type=refresh_token&refresh_token=rt")
		end)
	end)
end)




helpers.describe("Access-token providers: the catalogue block", function()
	helpers.it("a provider whose auth block is invalid is refused whole", function()
		local Remote = helpers.load_module("modules.llm.api_remote")
		local desc = { label = "X", base_url = "https://x.example/v1", default_model = "m", format = "openai",
			auth = { kind = "token_exchange", token_url = "http://insecure.example/token" } }
		local parsed = Remote.parse_catalogue(Json.encode({ provider_order = { "x" }, providers = { x = desc },
			model_prices = {} }))
		helpers.assert_eq(#parsed.order, 0)
	end)
end)
