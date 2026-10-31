--- tests/unit/modules/llm/remote/test_api_access_token.lua

--- ==============================================================================
--- MODULE: Access-Token Providers (macOS)
--- DESCRIPTION:
--- A provider whose auth block declares a token exchange (IBM watsonx, Google
--- Vertex AI) never receives the stored key: the real remote backend exchanges
--- it for an access token, reuses that token while it is fresh, makes the key
--- test wait for it, and does not ask the token service again for a minute
--- after a refusal. The HTTP clients are faked.
---
--- ROOT CAUSE ENCODED:
--- Sent as Bearer, the stored key itself was refused with HTTP 401.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local Exchange = require("llm.api_token_exchange")

--- Finds one upvalue, searching nested closures.
local function find_upvalue(fn, target, seen)
	seen = seen or {}
	if seen[fn] then return nil end
	seen[fn] = true
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
		if type(value) == "function" then
			local found = find_upvalue(value, target, seen)
			if found ~= nil then return found end
		end
	end
	return nil
end

--- Loads the real remote backend with an access-token provider and faked clients.
--- @return table api, table posts
local function load_api()
	package.loaded["modules.llm.api_remote"] = nil
	local api = helpers.load_with_stubs("modules.llm.api_remote", {})
	api.PROVIDERS.ibm_fixture = {
		label = "IBM fixture", base_url = "https://us-south.ml.cloud.ibm.com/ml/gateway/v1", default_model = "",
		format = "openai", model_extras = {}, thinking_dialect = {},
		auth = assert(Exchange.parse({
			kind = "token_exchange", token_url = "https://iam.cloud.ibm.com/identity/token",
			body = { grant_type = "urn:ibm:params:oauth:grant-type:apikey", apikey = "{key}" },
			token_field = "access_token", expires_field = "expires_in",
			default_expires_seconds = 3600, refresh_margin_seconds = 300,
		})),
	}
	local posts = {}
	local access = find_upvalue(api.prepare_access, "_access_client")
	assert(type(access) == "table", "_access_client must be reachable")
	access.post = function(url, headers, body, callback)
		posts[#posts + 1] = { client = "access", url = url, headers = headers, body = body, callback = callback }
		return true
	end
	local infer = find_upvalue(api.test_request, "_infer_client")
	assert(type(infer) == "table", "_infer_client must be reachable")
	infer.post = function(url, headers, body, callback)
		posts[#posts + 1] = { client = "infer", url = url, headers = headers, body = json.decode(body), callback = callback }
		return true
	end
	return api, posts
end

local function reply(post, status, body)
	post.callback({ ok = status >= 200 and status < 300, status = status, body = json.encode(body), headers = {} })
end

local SPEC = { system_prompt = "Reply with exactly: OK", user_text = "ping", temperature = 0, max_tokens = 16 }




-- =========================================
-- =========================================
-- ======= 1/ The exchange =================
-- =========================================
-- =========================================

helpers.describe("Access-token providers (macOS)", function()
	helpers.it("the key is exchanged once, and the fresh token is reused", function()
		local api, posts = load_api()
		local got = {}
		api.prepare_access("ibm_fixture", "ibm-api-key", function(ok, reason, token) got[#got + 1] = { ok, reason, token } end)
		helpers.assert_eq(#posts, 1)
		helpers.assert_eq(posts[1].url, "https://iam.cloud.ibm.com/identity/token")
		helpers.assert_eq(posts[1].body, "apikey=ibm-api-key&grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey")
		reply(posts[1], 200, { access_token = "iam-token", expires_in = 3600 })
		helpers.assert_eq(got[1][1], true)
		helpers.assert_eq(got[1][3], "iam-token")
		api.prepare_access("ibm_fixture", "ibm-api-key", function(ok, _, token) got[#got + 1] = { ok, nil, token } end)
		helpers.assert_eq(#posts, 1, "no second exchange while the token is fresh")
		helpers.assert_eq(got[2][3], "iam-token")
	end)

	helpers.it("the key test waits for the token, then probes with it as Bearer", function()
		local api, posts = load_api()
		local failed
		api.test_request({ id = "w1", provider = "ibm_fixture", token = "ibm-api-key", model = "ibm/granite-4-h-small",
			base_url = "https://us-south.ml.cloud.ibm.com/ml/gateway/v1" }, SPEC, nil, function(...) failed = { ... } end)
		helpers.assert_eq(#posts, 1, "the exchange first")
		reply(posts[1], 200, { access_token = "iam-token", expires_in = 3600 })
		helpers.assert_nil(failed, "no failure: " .. tostring(failed and failed[2]))
		helpers.assert_eq(#posts, 2, "then the probe")
		helpers.assert_eq(posts[2].client, "infer")
		helpers.assert_eq(posts[2].url, "https://us-south.ml.cloud.ibm.com/ml/gateway/v1/chat/completions")
		helpers.assert_eq(posts[2].headers.Authorization, "Bearer iam-token", "the token, never the key")
	end)

	helpers.it("a refused exchange fails the key test, and is not asked again for a minute", function()
		local api, posts = load_api()
		local failed
		api.test_request({ id = "w1", provider = "ibm_fixture", token = "bad-key", model = "m",
			base_url = "https://us-south.ml.cloud.ibm.com/ml/gateway/v1" }, SPEC, nil, function(...) failed = { ... } end)
		reply(posts[1], 400, { errorMessage = "Provided API key could not be found" })
		helpers.assert_eq(#posts, 1, "no probe")
		helpers.assert_type(failed, "table")
		local again
		api.prepare_access("ibm_fixture", "bad-key", function(ok, reason) again = { ok, reason } end)
		helpers.assert_eq(#posts, 1, "no second exchange at once")
		helpers.assert_eq(again[1], false)
		helpers.assert_eq(again[2], "the token exchange answered HTTP 400")
	end)
end)
