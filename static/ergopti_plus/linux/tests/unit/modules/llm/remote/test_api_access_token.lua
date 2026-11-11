--- tests/unit/modules/llm/remote/test_api_access_token.lua

--- ==============================================================================
--- MODULE: Access-Token Providers (Linux)
--- DESCRIPTION:
--- A provider whose auth block declares a token exchange (IBM watsonx, Google
--- Vertex AI) never receives the stored key: the driver exchanges it for an
--- access token, sends that token as Bearer, refreshes it before it ends,
--- waits for it in the key test, and does not ask the token service again for
--- a minute after a refusal. A Vertex AI service-account key is exchanged
--- for an RS256-signed assertion, signed one slice per timer tick. The real
--- api_remote runs over a scripted HTTP client and timer.
---
--- ROOT CAUSE ENCODED:
--- Sent as Bearer, the stored key itself was refused with HTTP 401. A
--- service-account key was refused ("the key holds no client_id field").
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
	local names = { "adapters.http_client", "modules.llm.api_remote", "infra.monotonic", "logger.shim",
		"adapters.timer_scheduler" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local calls, clock = {}, { now = 1000, ticks = {} }
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, fn)
			if clock.throw_schedule then clock.ticks[#clock.ticks + 1] = fn; error("scheduler unavailable") end
			clock.ticks[#clock.ticks + 1] = fn
			return { armed = true }
		end,
	}
	package.loaded["adapters.http_client"] = {
		post = function(url, headers, request_body, callback)
			calls[#calls + 1] = { url = url, headers = headers, body = request_body, callback = callback }
			if clock.sync_refusal then callback({ ok = false, status = 401 }); return false end
			if clock.sync_success_refused then
				callback({ ok = clock.sync_success_refused ~= "bad_envelope", status = 200,
					body = '{"access_token":"not-sent","expires_in":3600}' })
				return false
			end
			if clock.post_exception then
				if clock.post_exception == "after_callback" then
					callback({ ok = true, status = 200, body = '{"access_token":"early","expires_in":3600}' })
				end
				error("unknown native dispatch state")
			end
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

--- Runs the armed timer callbacks until none is left.
--- @param clock table
--- @return integer ticks How many ran.
local function drain_ticks(clock)
	local ran = 0
	while #clock.ticks > 0 do
		local fn = table.remove(clock.ticks, 1)
		fn()
		ran = ran + 1
	end
	return ran
end

--- A Google service-account key file holding the corpus's 2048-bit test key.
--- @return string key, string pem_body
local function service_account_key()
	local fh = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/crypto/rs256_vectors.json", "r"))
	local spec = Json.decode(fh:read("*a")).keys.rsa2048_pkcs8
	fh:close()
	local lines = {}
	for i = 1, #spec.body, 64 do lines[#lines + 1] = spec.body:sub(i, i + 63) end
	local pem = "-----BEGIN PRIVATE KEY-----\n" .. table.concat(lines, "\n") .. "\n-----END PRIVATE KEY-----\n"
	return Json.encode({ type = "service_account", project_id = "p1", private_key_id = "kid1",
		private_key = pem, client_email = "sa@p1.iam.gserviceaccount.com",
		token_uri = "https://attacker.example/token" }), spec.body
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
			-- The request carries the exchange's status first (access_failure).
			helpers.assert_eq(reason,
				"HTTP 400: the token exchange answered HTTP 400: Provided API key could not be found")
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
			helpers.assert_eq(verdict.detail, "the token exchange answered HTTP 401: no")
			remote.test(ENTRY, function(ok, detail) verdict = { ok = ok, detail = detail } end)
			helpers.assert_eq(#calls, 1, "a second test within the pause asks nothing")
			helpers.assert_eq(verdict.detail, "the token exchange answered HTTP 401: no")
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

	helpers.it("a Vertex AI service-account key is exchanged for a signed assertion, one slice per tick", function()
		with_remote(function(remote, calls, clock)
			local key, pem_body = service_account_key()
			local entry = { id = "sa", provider = "vertex", model = "google/gemini-3.5-flash", token = key,
				base_url = "https://aiplatform.googleapis.com/v1/projects/p1/locations/global/endpoints/openapi" }
			local ready
			remote.prepare_access(entry, function(ok, reason) ready = { ok, reason } end)
			helpers.assert_eq(#calls, 0, "nothing is sent before the assertion is signed")
			helpers.assert_nil(ready)
			local ticks = drain_ticks(clock)
			helpers.assert_true(ticks > 10, "the signature is spread over " .. ticks .. " tick(s)")
			helpers.assert_eq(#calls, 1, table.concat(clock.logs, " | "))
			-- The catalogue's address, never the key file's own token_uri
			helpers.assert_eq(calls[1].url, "https://oauth2.googleapis.com/token")
			helpers.assert_true(calls[1].body:match("^assertion=[%w_%-]+%.[%w_%-]+%.[%w_%-]+"
				.. "&grant_type=urn%%3Aietf%%3Aparams%%3Aoauth%%3Agrant%-type%%3Ajwt%-bearer$") ~= nil, calls[1].body)
			for _, line in ipairs(clock.logs) do
				helpers.assert_true(not line:find(pem_body:sub(1, 24), 1, true), "no log line holds the private key")
			end
			answer(calls, 1, 200, { access_token = "ya29.sa", expires_in = 3599 })
			helpers.assert_eq(ready[1], true)
			local endpoint = remote.endpoint(entry, entry.model)
			helpers.assert_eq(endpoint.headers.Authorization, "Bearer ya29.sa")
		end)
	end)

	helpers.it("a scheduler exception settles the token exchange and permits a later retry", function()
		with_remote(function(remote, calls, clock)
			local entry = { id = "sa", provider = "vertex", model = "google/gemini-3.5-flash",
				token = service_account_key(),
				base_url = "https://aiplatform.googleapis.com/v1/projects/p1/locations/global/endpoints/openapi" }
			clock.throw_schedule = true
			local answer
			remote.prepare_access(entry, function(ok, reason) answer = { ok, reason } end)
			helpers.assert_eq(answer[1], false)
			helpers.assert_true(type(answer[2]) == "string" and answer[2] ~= "")
			drain_ticks(clock)
			helpers.assert_eq(#calls, 0, "a callback retained by a failed scheduler must be inert")
			clock.throw_schedule = false
			clock.now = clock.now + 61
			remote.prepare_access(entry, function() end)
			helpers.assert_true(#clock.ticks > 0, "the refused exchange must not remain pending")
			drain_ticks(clock)
			helpers.assert_eq(#calls, 1)
		end)
	end)

	helpers.it("quarantines a throwing token transport even if a callback arrives", function()
		for _, variant in ipairs({ "before_callback", "after_callback" }) do
			with_remote(function(remote, calls, clock)
				clock.post_exception = variant
				local first, later
				remote.prepare_access(ENTRY, function(ok, reason) first = { ok, reason } end)
				helpers.assert_eq(first[1], false)
				helpers.assert_contains(first[2], "transport state is unknown")
				answer(calls, 1, 200, { access_token = "late", expires_in = 3600 })
				clock.now = clock.now + 120
				clock.post_exception = nil
				remote.prepare_access(ENTRY, function(ok, reason) later = { ok, reason } end)
				helpers.assert_eq(later, first)
				helpers.assert_eq(#calls, 1, "an unknown transport must not overlap a retry")
				helpers.assert_eq(remote.prewarm_access(ENTRY), false)
			end)
		end
	end)

	helpers.it("preserves a synchronous token refusal as the cached reason", function()
		with_remote(function(remote, _, clock)
			clock.sync_refusal = true
			local first, later
			remote.prepare_access(ENTRY, function(ok, reason) first = { ok, reason } end)
			remote.prepare_access(ENTRY, function(ok, reason) later = { ok, reason } end)
			helpers.assert_eq(first[1], false)
			helpers.assert_eq(first[2], "the token exchange answered HTTP 401")
			helpers.assert_eq(later, first)
		end)
	end)

	helpers.it("refuses synchronous success when the token dispatch returns false", function()
		for _, variant in ipairs({ "success", "bad_envelope" }) do
			with_remote(function(remote, calls, clock)
				clock.sync_success_refused = variant
				local first, later
				remote.prepare_access(ENTRY, function(ok, reason) first = { ok, reason } end)
				remote.prepare_access(ENTRY, function(ok, reason) later = { ok, reason } end)
				helpers.assert_eq(first[1], false)
				helpers.assert_eq(later, first)
				helpers.assert_eq(#calls, 1)
			end)
		end
	end)

	helpers.it("reports failed quarantined waiters without logging their error text", function()
		with_remote(function(remote, _, clock)
			local entry = { id = "sa", provider = "vertex", model = "google/gemini-3.5-flash",
				token = service_account_key(),
				base_url = "https://aiplatform.googleapis.com/v1/projects/p1/locations/global/endpoints/openapi" }
			clock.post_exception = "before_callback"
			local received
			remote.prepare_access(entry, function() error("private waiter payload") end)
			remote.prepare_access(entry, function(ok, reason) received = { ok, reason } end)
			drain_ticks(clock)
			helpers.assert_eq(received[1], false)
			local log = table.concat(clock.logs, "\n")
			helpers.assert_contains(log, "Access token waiter failed.")
			helpers.assert_true(not log:find("private waiter payload", 1, true))
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




-- =========================================
-- =========================================
-- ======= 3/ The wait =====================
-- =========================================
-- =========================================

-- The first prediction after start or a key change used to be refused while
-- the token was fetched ("the access token is being fetched"): the request
-- now waits for the exchange inside its own exchange epoch (access-token-lease).
helpers.describe("Access-token providers: the first request waits for the token (access-token-lease)", function()
	helpers.it("a chat waits for the exchange, then is sent with the token (access-token-lease)", function()
		with_remote(function(remote, calls, clock)
			local result
			local dispatched = remote.chat(ENTRY, nil, MESSAGES, nil, nil, function(text, err) result = { text, err } end)
			helpers.assert_eq(dispatched, true, "the request is owned while it waits")
			helpers.assert_nil(result, "not refused: " .. tostring(result and result[2]))
			helpers.assert_eq(#calls, 1, "the exchange first")
			answer(calls, 1, 200, { access_token = "iam-token", expires_in = 3600 })
			helpers.assert_eq(#calls, 2, "then the completion")
			helpers.assert_eq(calls[2].url, IBM.base_url .. "/chat/completions")
			helpers.assert_eq(calls[2].headers.Authorization, "Bearer iam-token")
			answer(calls, 2, 200, { choices = { { message = { content = "suite" } } } })
			helpers.assert_type(result, "table", table.concat(clock.logs, " | "))
			helpers.assert_eq(result[1], "suite")
		end)
	end)

	helpers.it("a cancelled chat is never sent nor answered once the token arrives (access-token-lease)", function()
		with_remote(function(remote, calls)
			local answered = false
			remote.chat(ENTRY, nil, MESSAGES, nil, nil, function() answered = true end)
			helpers.assert_eq(remote.cancel(), true)
			answer(calls, 1, 200, { access_token = "iam-token", expires_in = 3600 })
			helpers.assert_eq(#calls, 1, "no completion after the cancellation")
			helpers.assert_eq(answered, false)
		end)
	end)

	-- AID-2 (decided by the maintainer on 2026-11-11): an exchange answering 400
	-- (an unknown IAM key, OAuth invalid_grant) is a refused credential, never
	-- retried, and the request fails with the service's own message.
	helpers.it("a refused exchange answers the waiting chat with its reason (access-token-lease)", function()
		with_remote(function(remote, calls)
			local result
			remote.chat(ENTRY, nil, MESSAGES, nil, nil, function(text, err) result = { text, err } end)
			answer(calls, 1, 400, { errorMessage = "Provided API key could not be found" })
			helpers.assert_eq(#calls, 1, "no completion")
			helpers.assert_eq(result[1], "")
			helpers.assert_eq(result[2],
				"HTTP 400: the token exchange answered HTTP 400: Provided API key could not be found")
			helpers.assert_true(require("llm.failure_class").is_authentication_failure(result[2]),
				"a 400 exchange is a refused credential: never retried")
		end)
	end)

	-- Windows carries the exchange's status into the request failure
	-- (_LLMRemote_AccessFailInfo), so a refused key is never retried; the Lua
	-- failure was the bare reason, which the shared classifier cannot read, and
	-- the engine spent its whole retry budget (AIS-001, access-refusal-status).
	helpers.it("a refused exchange fails the chat as a refused credential (access-refusal-status)", function()
		local FailureClass = require("llm.failure_class")
		for _, status in ipairs({ 401, 403 }) do
			with_remote(function(remote, calls)
				local result
				remote.chat(ENTRY, nil, MESSAGES, nil, nil, function(text, err) result = { text, err } end)
				answer(calls, 1, status, { errorMessage = "no" })
				helpers.assert_eq(result[2], "HTTP " .. status .. ": the token exchange answered HTTP " .. status .. ": no")
				helpers.assert_true(FailureClass.is_authentication_failure(result[2]), "never retried")
				result = nil
				remote.chat(ENTRY, nil, MESSAGES, nil, nil, function(text, err) result = { text, err } end)
				helpers.assert_eq(#calls, 1, "the pause asks nothing")
				helpers.assert_true(FailureClass.is_authentication_failure(result[2]), "nor within the pause")
			end)
		end
	end)

	helpers.it("the model listing waits for the token too (access-token-lease)", function()
		with_remote(function(remote, calls)
			local listed
			local get_url, get_headers
			package.loaded["adapters.http_client"].get = function(url, headers, _, callback)
				get_url, get_headers = url, headers
				callback({ ok = true, status = 200, body = Json.encode({ data = { { id = "ibm/granite-4-h-small" } } }) })
				return true
			end
			remote.list_models(ENTRY, function(state) listed = state end)
			helpers.assert_nil(listed, "not failed while the token is fetched")
			answer(calls, 1, 200, { access_token = "iam-token", expires_in = 3600 })
			helpers.assert_eq(get_url, IBM.base_url .. "/models")
			helpers.assert_eq(get_headers.Authorization, "Bearer iam-token")
			helpers.assert_eq(listed.state, "listed")
		end)
	end)

	helpers.it("a key change starts the exchange before any request (access-token-lease)", function()
		with_remote(function(remote, calls)
			helpers.assert_eq(remote.prewarm_access(ENTRY), true)
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(calls[1].url, "https://iam.cloud.ibm.com/identity/token")
			helpers.assert_eq(remote.prewarm_access(ENTRY), true, "a pending exchange is not asked twice")
			helpers.assert_eq(#calls, 1)
			helpers.assert_eq(remote.prewarm_access({ id = "o", provider = "openai", token = "sk", model = "m" }), false)
		end)
	end)
end)
