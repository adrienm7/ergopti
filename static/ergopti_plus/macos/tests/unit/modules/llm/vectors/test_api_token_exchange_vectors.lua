--- tests/unit/modules/llm/vectors/test_api_token_exchange_vectors.lua

--- ==============================================================================
--- MODULE: API Token Exchange Corpus (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/api_token_exchange_vectors.json through
--- _shared/lua/llm/api_token_exchange.lua: the auth blocks a provider may
--- declare, the exchange form of a stored key (IBM API key, Google
--- authorized_user credentials), the answer read and the refresh decision.
---
--- ROOT CAUSE ENCODED:
--- IBM watsonx and Google Vertex AI take a short-lived access token, never the
--- stored key: sent as Bearer, the key itself was refused with HTTP 401.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local Exchange = require("llm.api_token_exchange")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

--- A copy of a corpus block with some fields replaced.
local function block(corpus, name, set)
	local copy = {}
	for key, value in pairs(corpus[name]) do copy[key] = value end
	for key, value in pairs(set or {}) do copy[key] = value end
	return copy
end

helpers.describe("api_token_exchange replays the shared corpus", function()
	local corpus = read_json("tests/corpus/llm/api_token_exchange_vectors.json")

	helpers.it("the corpus pins the lifetime bounds and holds every section", function()
		helpers.assert_eq(Exchange.MIN_EXPIRES_SECONDS, corpus.min_expires_seconds)
		helpers.assert_eq(Exchange.MAX_EXPIRES_SECONDS, corpus.max_expires_seconds)
		helpers.assert_true(#corpus.parse >= 8 and #corpus.requests >= 4 and #corpus.answers >= 5 and #corpus.states >= 4)
	end)

	for _, v in ipairs(corpus.parse) do
		helpers.it("parse: " .. v.name, function()
			local auth, reason = Exchange.parse(block(corpus, v.block, v.set))
			helpers.assert_eq(auth ~= nil, v.valid, v.name .. ": " .. tostring(reason))
		end)
	end

	for _, v in ipairs(corpus.requests) do
		helpers.it("request: " .. v.name, function()
			local auth = assert(Exchange.parse(block(corpus, v.block)))
			local request, reason = Exchange.request(auth, v.key)
			if v.reason then
				helpers.assert_nil(request)
				helpers.assert_eq(reason, v.reason)
				return
			end
			helpers.assert_eq(request.url, corpus[v.block].token_url)
			helpers.assert_eq(request.headers["Content-Type"], "application/x-www-form-urlencoded")
			helpers.assert_eq(request.body, v.body)
		end)
	end

	for _, v in ipairs(corpus.answers) do
		helpers.it("answer: " .. v.name, function()
			local auth = assert(Exchange.parse(block(corpus, v.block)))
			local token, reason = Exchange.read(auth, v.status, v.json, v.now)
			if v.reason then
				helpers.assert_nil(token)
				helpers.assert_eq(reason, v.reason)
				return
			end
			helpers.assert_eq(token.token, v.token)
			helpers.assert_eq(token.expires_at, v.expires_at)
		end)
	end

	for _, v in ipairs(corpus.states) do
		helpers.it("state: " .. v.name, function()
			local auth = assert(Exchange.parse(block(corpus, v.block)))
			local cached = v.expires_at and { token = "t", expires_at = v.expires_at } or nil
			local usable, refresh = Exchange.state(auth, cached, v.now)
			helpers.assert_eq(usable, v.usable)
			helpers.assert_eq(refresh, v.refresh)
		end)
	end
end)
