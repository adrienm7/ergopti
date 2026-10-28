--- tests/unit/modules/llm/remote/test_api_remote_usage.lua

--- ==============================================================================
--- MODULE: Remote Provider Token Usage and Cost
--- DESCRIPTION:
--- A remote completion hands its caller the tokens the provider reported and
--- their cost from the catalogue's model_prices, so the prediction engine's
--- generation row in events_llm carries remote tokens and cost as on macOS. A
--- failed request hands no usage. HTTP is scripted; no real provider is called.
--- ==============================================================================

local helpers = require("tests.helpers")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local Json = require("json")
local Classifier = require("llm.remote_response_classifier")

-- Tolerance for comparing a computed dollar cost with the catalogue's price
local COST_TOLERANCE = 1e-12

--- The model_prices row the shipped catalogue gives a model.
--- @param model string
--- @return table { in, out }
local function catalogue_price(model)
	local fh = assert(io.open(SHARED .. "modules/llm/api_providers.json", "r"))
	local raw = fh:read("*a")
	fh:close()
	local prices = Classifier.parse_prices(Json.decode(raw).model_prices)
	return assert(prices[model], model .. " has no price in api_providers.json")
end

--- Runs one case with the HTTP adapter scripted.
--- @param test function Receives the loaded module and the queued requests.
local function isolated(test)
	local saved = {}
	for _, name in ipairs({ "adapters.http_client", "modules.llm.api_remote" }) do saved[name] = package.loaded[name] end
	local calls = {}
	package.loaded["adapters.http_client"] = {
		post = function(url, headers, body, callback)
			calls[#calls + 1] = { url = url, body = body, callback = callback }
			return true
		end,
		cancel = function() return true end,
	}
	local ok, err = pcall(function()
		local remote = helpers.load_module("modules.llm.api_remote")
		remote._reset_for_test()
		test(remote, calls)
	end)
	for name, value in pairs(saved) do package.loaded[name] = value end
	if saved["modules.llm.api_remote"] == nil then package.loaded["modules.llm.api_remote"] = nil end
	if not ok then error(err, 0) end
end

--- Sends one completion and returns what the terminal callback received.
local function chat(remote, calls, entry, reply)
	local received
	assert(remote.chat(entry, nil, { { role = "user", content = "fixture prompt" } },
		{ temperature = 0.2, max_tokens = 16 }, nil, function(...) received = { n = select("#", ...), ... } end))
	calls[#calls].callback(reply)
	return assert(received, "the terminal callback did not run")
end

helpers.describe("api_remote: token usage and cost of a completion", function()
	helpers.it("prices the usage an OpenAI-format provider reports", function()
		isolated(function(remote, calls)
			local price = catalogue_price("gpt-4o-mini")
			local got = chat(remote, calls, { provider = "openai_compat", base_url = "https://example.invalid/v1",
				token = "fixture-token", model = "gpt-4o-mini" }, { ok = true, status = 200,
				body = '{"choices":[{"message":{"content":"done"}}],"usage":{"prompt_tokens":1200,"completion_tokens":30,"total_tokens":1230}}' })
			helpers.assert_eq(got[1], "done")
			helpers.assert_nil(got[2])
			local usage = got[3]
			helpers.assert_eq(usage.prompt_tokens, 1200)
			helpers.assert_eq(usage.completion_tokens, 30)
			helpers.assert_eq(usage.total_tokens, 1230)
			local want = (1200 * price["in"] + 30 * price["out"]) / 1000000
			helpers.assert_true(want > 0 and math.abs(usage.est_cost_usd - want) < COST_TOLERANCE,
				"cost " .. tostring(usage.est_cost_usd) .. " for want " .. tostring(want))
		end)
	end)

	helpers.it("fills a missing total and leaves an unpriced model at no cost", function()
		isolated(function(remote, calls)
			local got = chat(remote, calls, { provider = "openai_compat", base_url = "https://example.invalid/v1",
				token = "fixture-token", model = "fixture-unpriced-model" }, { ok = true, status = 200,
				body = '{"choices":[{"message":{"content":"done"}}],"usage":{"prompt_tokens":7,"completion_tokens":3}}' })
			helpers.assert_eq(got[3].total_tokens, 10)
			helpers.assert_eq(got[3].est_cost_usd, 0.0)
		end)
	end)

	helpers.it("hands no usage when the request fails", function()
		isolated(function(remote, calls)
			local got = chat(remote, calls, { provider = "openai_compat", base_url = "https://example.invalid/v1",
				token = "fixture-token", model = "gpt-4o-mini" }, { ok = false, status = 500, error_body = "{}" })
			helpers.assert_eq(got[1], "")
			helpers.assert_eq(got[2], "HTTP 500")
			helpers.assert_true(got[3] == nil or got[3].prompt_tokens == nil, "a failure must not look like usage")
		end)
	end)
end)
