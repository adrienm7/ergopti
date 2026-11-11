--- tests/unit/modules/llm/vectors/test_api_token_exchange_vectors.lua

--- ==============================================================================
--- MODULE: API Token Exchange Corpus (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/api_token_exchange_vectors.json through
--- _shared/lua/llm/api_token_exchange.lua: the auth blocks a provider may
--- declare, the exchange form of a stored key (IBM API key, Google
--- authorized_user credentials, a Google service-account key's signed
--- assertion), the answer read and the refresh decision.
---
--- ROOT CAUSE ENCODED:
--- IBM watsonx and Google Vertex AI take a short-lived access token, never the
--- stored key: sent as Bearer, the key itself was refused with HTTP 401. A
--- service-account key was refused with "the key holds no client_id field":
--- only authorized_user credentials were exchanged.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"

local Exchange = require("llm.api_token_exchange")

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(SHARED .. path, "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

--- A PEM block from a label and its armorless Base64 body.
--- @param label string
--- @param body string
--- @return string
local function pem(label, body)
	local lines = {}
	for i = 1, #body, 64 do lines[#lines + 1] = body:sub(i, i + 63) end
	return "-----BEGIN " .. label .. "-----\n" .. table.concat(lines, "\n") .. "\n-----END " .. label .. "-----\n"
end

--- The stored key of a request vector: its key string, or the service-account
--- key file it describes, its private_key taken from the RS256 test keys.
--- @param v table A request vector.
--- @param keys table rs256_vectors.json keys.
--- @return string
local function stored_key(v, keys)
	if not v.service_account then return v.key end
	local file = {}
	for name, value in pairs(v.service_account) do
		if name ~= "private_key_of" then file[name] = value end
	end
	local of = v.service_account.private_key_of
	if of then file.private_key = pem(keys[of].label, keys[of].body) end
	return json.encode(file)
end

--- A copy of a corpus block with some fields replaced.
local function block(corpus, name, set)
	local copy = {}
	for key, value in pairs(corpus[name]) do copy[key] = value end
	for key, value in pairs(set or {}) do copy[key] = value end
	return copy
end

helpers.describe("api_token_exchange replays the shared corpus", function()
	helpers.it("settles once when a reentrant scheduler runs a tick then refuses", function()
		for _, throws in ipairs({ false, true }) do
			local steps, outcomes = 0, {}
			local job = { step = function()
				steps = steps + 1
				if steps == 1 then return false end
				return true, { body = "signed" }
			end }
			Exchange.drive(job, function(callback)
				callback()
				if throws then error("scheduler failed after callback") end
				return false
			end, function(request, reason) outcomes[#outcomes + 1] = { request, reason } end)
			helpers.assert_eq(#outcomes, 1)
			helpers.assert_eq(outcomes[1][1].body, "signed")
		end
	end)
	local corpus = read_json("tests/corpus/llm/api_token_exchange_vectors.json")
	local keys = read_json("tests/corpus/crypto/rs256_vectors.json").keys

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
			local request, reason = Exchange.request(auth, stored_key(v, keys), corpus.unix_now)
			if v.reason then
				helpers.assert_nil(request)
				helpers.assert_eq(reason, v.reason)
				return
			end
			helpers.assert_eq(request.url, corpus[v.block].token_url)
			helpers.assert_eq(request.headers["Content-Type"], "application/x-www-form-urlencoded")
			if v.body_prefix then
				helpers.assert_eq(request.body:sub(1, #v.body_prefix), v.body_prefix)
			else
				helpers.assert_eq(request.body, v.body)
			end
		end)
	end

	helpers.it("the catalogue's Vertex AI block is the corpus's Google block", function()
		local providers = read_json("modules/llm/api_providers.json").providers
		local catalogue = assert(Exchange.parse(providers.vertex.auth))
		helpers.assert_true(helpers.deep_equal(catalogue, assert(Exchange.parse(block(corpus, "google")))))
	end)

	helpers.it("a signed assertion settles over several steps, each one slice", function()
		local auth = assert(Exchange.parse(block(corpus, "google")))
		local v = corpus.requests[#corpus.requests - 5]
		helpers.assert_true(v.service_account ~= nil and v.body ~= nil, "the first service-account vector")
		local job = Exchange.begin(auth, stored_key(v, keys), corpus.unix_now)
		local steps, settled, request = 0, false, nil
		while not settled do
			steps = steps + 1
			settled, request = job.step()
		end
		helpers.assert_true(steps > 10, "the signature is sliced, " .. steps .. " step(s)")
		helpers.assert_eq(request.body, v.body)
		local again, same = job.step()
		helpers.assert_true(again)
		helpers.assert_eq(same, request)
	end)

	helpers.it("an authorized_user key settles on its first step", function()
		local auth = assert(Exchange.parse(block(corpus, "google")))
		local settled, request = Exchange.begin(auth, corpus.requests[2].key, corpus.unix_now).step()
		helpers.assert_true(settled)
		helpers.assert_eq(request.body, corpus.requests[2].body)
	end)

	helpers.it("the exchange needs the wall-clock time in whole seconds", function()
		local auth = assert(Exchange.parse(block(corpus, "google")))
		helpers.assert_true(not pcall(Exchange.begin, auth, "k", nil))
		helpers.assert_true(not pcall(Exchange.begin, auth, "k", 1.5))
	end)

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

	-- AID-2: a refusal carries the service's message, bounded so an error page
	-- never fills a log line, and cut between characters.
	helpers.it("answer: a long service message is cut on a character boundary", function()
		local auth = assert(Exchange.parse(block(corpus, "ibm")))
		local message = string.rep("\u{E9}", Exchange.MAX_SERVICE_MESSAGE_BYTES)
		local _, reason = Exchange.read(auth, 400, { errorMessage = message }, 1000)
		local prefix = "the token exchange answered HTTP 400: "
		helpers.assert_eq(reason:sub(1, #prefix), prefix)
		local kept = reason:sub(#prefix + 1)
		helpers.assert_eq(#kept, Exchange.MAX_SERVICE_MESSAGE_BYTES, "two-byte characters fill the bound exactly")
		local _, odd = Exchange.read(auth, 400, { errorMessage = "a" .. message }, 1000)
		helpers.assert_eq(#odd - #prefix, Exchange.MAX_SERVICE_MESSAGE_BYTES - 1, "a split character is left out")
	end)
end)
