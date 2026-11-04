--- tests/unit/modules/llm/remote/test_api_remote_capabilities.lua

--- ==============================================================================
--- MODULE: Capability Listings In Linux Cloud Requests
--- DESCRIPTION:
--- A provider whose model listing says which reasoning controls each model
--- takes (thinking_off.json capability_listing) has that listing fetched off
--- the prediction path: build_request only schedules the fetch, on the next
--- event-loop tick, with its own HTTP owner and the largest page; the parsed
--- listing then makes later requests skip a control the model lacks. A fresh
--- listing is not fetched again; a failed one keeps the old.
---
--- ROOT CAUSE ENCODED:
--- A control a model does not take went out anyway and came back as an HTTP
--- 400, then a retry: the listing that says so was never read.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"

-- The refusal store of these tests
local REFUSED_FILE = os.tmpname()
os.remove(REFUSED_FILE)

--- The recorded listing answers of the shared corpus.
--- @return table answers listing -> decoded body
local function answers()
	local fh = assert(io.open(SHARED .. "tests/corpus/llm/model_capabilities_vectors.json", "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(Json.decode(raw)).answers
end

--- Loads the module over a scripted HTTP client and event loop.
--- @return table remote, table http, table deferred
local function load_remote()
	local http, deferred = { gets = {}, posts = {} }, {}
	package.loaded["adapters.http_client"] = {
		get = function(url, headers, options, callback)
			http.gets[#http.gets + 1] = { url = url, headers = headers, options = options, callback = callback }
			return true
		end,
		post = function(url, headers, body, callback)
			http.posts[#http.posts + 1] = { url = url, body = body, callback = callback }
			return true
		end,
		cancel = function() return true end,
	}
	package.loaded["adapters.event_loop"] = {
		defer = function(fn, delay)
			deferred[#deferred + 1] = { fn = fn, delay = delay }
			return true
		end,
	}
	local remote = helpers.load_module("modules.llm.api_remote")
	remote._reset_for_test(REFUSED_FILE)
	return remote, http, deferred
end

local function unload()
	package.loaded["adapters.http_client"] = nil
	package.loaded["adapters.event_loop"] = nil
	package.loaded["modules.llm.api_remote"] = nil
	os.remove(REFUSED_FILE)
end

local MESSAGES = { { role = "user", content = "Bonjour" } }

--- Runs the deferred callbacks once.
--- @param deferred table
local function tick(deferred)
	local due = {}
	for index, entry in ipairs(deferred) do due[index] = entry end
	for index = #deferred, 1, -1 do deferred[index] = nil end
	for _, entry in ipairs(due) do entry.fn() end
end

helpers.describe("api_remote: capability listings skip what a model lacks (thinking-off-capabilities)", function()

	helpers.it("a prediction only schedules the fetch; the listing then skips a lacking control", function()
		local remote, http, deferred = load_remote()
		local entry = { provider = "openrouter", model = "mistralai/mistral-small-2603", token = "k" }
		local first = assert(remote.build_request(entry, MESSAGES, { max_tokens = 16 }))
		helpers.assert_eq(type(Json.decode(first.body).reasoning), "table", "no listing yet: the control is sent")
		helpers.assert_eq(#http.gets, 0, "nothing is fetched before the request goes out")
		helpers.assert_eq(#deferred, 1, "the fetch waits for the next tick")
		assert(remote.build_request(entry, MESSAGES, { max_tokens = 16 }))
		helpers.assert_eq(#deferred, 1, "a pending fetch is not scheduled twice")
		tick(deferred)
		helpers.assert_eq(#http.gets, 1, "one listing request")
		helpers.assert_eq(http.gets[1].url, "https://openrouter.ai/api/v1/models", "the provider's listing")
		helpers.assert_eq(http.gets[1].options.owner, "llm_remote_capabilities", "its own HTTP owner")
		http.gets[1].callback({ ok = true, status = 200, body = Json.encode(answers().openrouter) })
		local second = assert(remote.build_request(entry, MESSAGES, { max_tokens = 16 }))
		helpers.assert_eq(Json.decode(second.body).reasoning, nil, "the listing says the model takes no reasoning")
		helpers.assert_eq(#deferred, 0, "a fresh listing is not fetched again")
		local listed = assert(remote.build_request({ provider = "openrouter", model = "qwen/qwen3-235b-a22b", token = "k" },
			MESSAGES, { max_tokens = 16 }))
		helpers.assert_eq(Json.decode(listed.body).reasoning.enabled, false, "a listed control is still sent")
		unload()
	end)

	helpers.it("Anthropic and Gemini ask for their largest page", function()
		local remote, http, deferred = load_remote()
		assert(remote.build_request({ provider = "anthropic", model = "claude-opus-5", token = "k" }, MESSAGES, {}))
		assert(remote.build_request({ provider = "gemini", model = "gemini-2.5-flash", token = "k" }, MESSAGES, {}))
		tick(deferred)
		helpers.assert_eq(#http.gets, 2, "one listing per provider")
		helpers.assert_true(http.gets[1].url:find("/models?limit=1000", 1, true) ~= nil, http.gets[1].url)
		helpers.assert_true(http.gets[2].url:find("&pageSize=1000", 1, true) ~= nil, "gemini page size after its key")
		http.gets[1].callback({ ok = true, status = 200, body = Json.encode(answers().anthropic) })
		local body = Json.decode(assert(remote.build_request({ provider = "anthropic", model = "claude-opus-5", token = "k" },
			MESSAGES, {})).body)
		helpers.assert_eq(body.thinking, nil, "the listing says disabled is not supported")
		unload()
	end)

	helpers.it("a failed fetch keeps no listing and waits for the time to live", function()
		local remote, http, deferred = load_remote()
		local entry = { provider = "openrouter", model = "mistralai/mistral-small-2603", token = "k" }
		assert(remote.build_request(entry, MESSAGES, {}))
		tick(deferred)
		http.gets[1].callback({ ok = false, status = 500, body = "" })
		local body = Json.decode(assert(remote.build_request(entry, MESSAGES, {})).body)
		helpers.assert_eq(type(body.reasoning), "table", "no listing: the control is sent")
		helpers.assert_eq(#deferred, 0, "no retry before the time to live")
		unload()
	end)

	helpers.it("a provider without a listing never fetches one", function()
		local remote, _, deferred = load_remote()
		assert(remote.build_request({ provider = "openai", model = "gpt-5.1", token = "k" }, MESSAGES, {}))
		helpers.assert_eq(#deferred, 0, "openai has no capability listing")
		unload()
	end)
end)
