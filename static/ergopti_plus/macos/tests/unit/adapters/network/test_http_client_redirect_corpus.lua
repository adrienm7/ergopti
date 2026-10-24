--- tests/unit/adapters/network/test_http_client_redirect_corpus.lua

--- ==============================================================================
--- MODULE: HttpClient Shared Redirect Corpus Replay
--- DESCRIPTION:
--- Replays the shared buffered GET redirect vectors through the real macOS
--- adapter hop policy, driven by a native double that answers each hop. Linux
--- answers the same file through its curl receipt law; this file proves the
--- macOS adapter reaches the same follow or stop outcome and forwards the same
--- headers. Vectors whose input only exists in a curl receipt are named with
--- their reason, and every disagreement awaiting a decision is pinned so that
--- fixing it forces this inventory to shrink.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local function read_corpus()
	local path = assert(helpers.shared("tests/corpus/http/get_redirect_vectors.json"))
	local handle = assert(io.open(path, "rb"))
	local bytes = assert(handle:read("*a"))
	assert(handle:close())
	return assert(Json.decode(bytes))
end

-- Inputs that only a curl single-hop receipt carries. hs.http hands the adapter
-- the raw Location header and treats only the five redirect statuses as hops.
local CURL_RECEIPT_ONLY = {
	["relative value cannot impersonate native resolved URL"] =
		"curl reports an already resolved URL; macOS resolves the raw Location itself",
	["transport failure never follows Location"] = "curl_exit has no hs.http counterpart",
	["native prior following is invalid evidence"] = "num_redirects has no hs.http counterpart",
	["native 300 Location preserves curl behavior"] = "curl follows every 3xx Location; hs.http does not",
	["native 304 Location preserves curl behavior without ETag port"] =
		"curl follows every 3xx Location; hs.http does not",
	["native 399 Location preserves curl behavior"] = "curl follows every 3xx Location; hs.http does not",
}

-- Disagreements with the shared law. Each entry must still disagree: a fix
-- turns its case red until the entry is removed.
local PENDING = {
	["last allowed hop admitted"] = "the adapter stops after 5 hops, the shared law after 50",
	["exact prior URL loop refused"] = "the adapter has no visited-URL guard",
	["fragment does not bypass loop guard"] = "the adapter has no visited-URL guard",
	["explicit https floor rejects http from http initial"] =
		"the adapter has no HTTPS floor for an HTTP initial request",
	["original HTTP floor stays HTTP after an intermediate HTTPS upgrade"] =
		"the adapter refuses every HTTPS to HTTP hop, whatever the initial scheme",
}

local function copy(map)
	local result = {}
	for key, value in pairs(map or {}) do result[key] = value end
	return result
end

--- Builds the real adapter over a native double recording every hop.
--- @return table client
--- @return table state
local function load_fixture()
	local state = { requests = {}, callbacks = {}, native_follow = 0 }
	local http = {}
	function http.doAsyncRequest(url, method, _, headers, callback)
		state.requests[#state.requests + 1] = { url = url, method = method, headers = copy(headers) }
		state.callbacks[#state.callbacks + 1] = callback
		return nil
	end
	local function native(url, headers, callback)
		state.native_follow = state.native_follow + 1
		state.requests[#state.requests + 1] = { url = url, method = "GET", headers = copy(headers) }
		state.callbacks[#state.callbacks + 1] = callback
		return nil
	end
	function http.asyncGet(url, headers, callback) return native(url, headers, callback) end
	function http.asyncPost(url, _, headers, callback) return native(url, headers, callback) end
	local timer = { secondsSinceEpoch = function() return 0 end }
	function timer.new(_, callback)
		local running = false
		return {
			start = function(self) running = true; return self end,
			stop = function(self) running = false; return self end,
			running = function() return running end,
			callback = callback,
		}
	end
	package.loaded["adapters.http_client"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	local HttpClient = helpers.load_with_stubs("adapters.http_client", { http = http, timer = timer })
	return HttpClient.new(), state
end

--- Drives one vector and reports what the adapter did with its redirect.
--- Prior hops and visited URLs become real earlier hops of the same request.
--- @param input table Vector merged over the corpus defaults.
--- @return table observation
local function observe(input)
	local client, state = load_fixture()
	local result
	local chain = {}
	for visited in pairs(input.visited) do chain[#chain + 1] = visited end
	table.sort(chain)
	for index = 1, input.hops do chain[#chain + 1] = input.current_url .. "?prior=" .. index end
	chain[#chain + 1] = input.current_url
	helpers.assert_eq(client.get(chain[1], copy(input.headers), function(value) result = value end), true)
	if state.native_follow > 0 then return { kind = "native_follow" } end
	for index = 2, #chain do
		state.callbacks[#state.callbacks](302, "", { Location = chain[index] })
		-- An adapter limit reached before the vector's own hop is a stop.
		if #state.requests ~= index then return { kind = "stop", result = result } end
	end
	local before = #state.requests
	local location = input.target ~= "" and { Location = input.target } or {}
	state.callbacks[#state.callbacks](input.status, "", location)
	if #state.requests > before then
		local hop = state.requests[#state.requests]
		return { kind = "follow", url = hop.url, method = hop.method, headers = hop.headers }
	end
	return { kind = "stop", result = result }
end

--- Returns nil when the observation answers the vector, or why it does not.
--- @param vector table Corpus case.
--- @param input table Vector merged over the defaults.
--- @param seen table Observation.
--- @return string|nil mismatch
local function mismatch(vector, input, seen)
	local expected = vector.expected
	if expected.action == "follow" then
		if seen.kind == "native_follow" then return nil end
		if seen.kind ~= "follow" then return "expected a followed hop, got " .. seen.kind end
		if seen.url ~= input.target then return "followed " .. tostring(seen.url) end
		if expected.method and seen.method ~= expected.method then return "method " .. seen.method end
		if expected.headers and not helpers.deep_equal(seen.headers, expected.headers) then
			return "forwarded " .. helpers.inspect(seen.headers)
		end
		return nil
	end
	if seen.kind ~= "stop" then return "expected a stop, got " .. seen.kind end
	if type(seen.result) ~= "table" or seen.result.status ~= input.status then
		return "the caller did not receive the redirect response unchanged"
	end
	return nil
end

local corpus = read_corpus()

helpers.describe("shared redirect corpus through the macOS adapter (redirect-corpus)", function()
	for _, vector in ipairs(corpus.cases) do
		local fixed = vector
		if CURL_RECEIPT_ONLY[fixed.name] == nil then
			helpers.it(fixed.name, function()
				local input = copy(corpus.defaults)
				for key, value in pairs(fixed) do input[key] = value end
				local reason = mismatch(fixed, input, observe(input))
				if PENDING[fixed.name] then
					helpers.assert_true(reason ~= nil, "now agrees, remove it from PENDING: " .. fixed.name)
				else
					helpers.assert_nil(reason, fixed.name .. ": " .. tostring(reason))
				end
			end)
		end
	end

	helpers.it("names only vectors the corpus still holds", function()
		local names = {}
		for _, vector in ipairs(corpus.cases) do names[vector.name] = true end
		for name in pairs(CURL_RECEIPT_ONLY) do helpers.assert_true(names[name], "stale exclusion: " .. name) end
		for name in pairs(PENDING) do
			helpers.assert_true(names[name], "stale pending entry: " .. name)
			helpers.assert_nil(CURL_RECEIPT_ONLY[name], "a vector is either excluded or pending: " .. name)
		end
	end)
end)
