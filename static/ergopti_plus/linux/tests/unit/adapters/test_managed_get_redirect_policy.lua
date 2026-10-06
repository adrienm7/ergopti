--- tests/unit/adapters/test_managed_get_redirect_policy.lua

--- ==============================================================================
--- MODULE: Buffered GET Shared Transition Controls
--- DESCRIPTION:
--- Runs independent fixed expectations through the normal driver test helpers.
--- These modeled ports do not establish native transport or enterprise coverage.
--- ==============================================================================

local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Json = require("json")
local Shared = require("network.http_redirect")

local function read(relative)
	local file = assert(io.open(assert(Paths.shared(relative)), "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return Json.decode(bytes)
end
local law = assert(Shared.new(read("data/http/redirect_policy.json"), read("data/http/transport_policy.json")))
local corpus = read("tests/corpus/http/get_redirect_vectors.json")

helpers.describe("independent canonical buffered GET redirect vectors", function()
	for _, vector in ipairs(corpus.cases) do
		local fixed = vector
		helpers.it(fixed.name, function()
			local input = {}
			for key, value in pairs(corpus.defaults) do input[key] = value end
			for key, value in pairs(fixed) do input[key] = value end
			local status = input.status
			input.result = { ok = status >= 200 and status < 300, status = status, body = "", redirect_receipt = {
				format = "curl-single-hop-v1", http_status = status, curl_exit = input.curl_exit,
				num_redirects = input.num_redirects, effective_url = input.current_url, redirect_url = input.target,
			} }
			local original_headers = {}
			for name, value in pairs(input.headers) do original_headers[name] = value end
			local decision = law.transition({
				current_url = input.current_url, headers = input.headers,
				hops = input.hops, https_floor = input.https_floor,
				visited = input.visited, result = input.result,
			})
			for key, expected in pairs(fixed.expected) do
				if key == "headers" then
					for name, value in pairs(expected) do helpers.assert_eq(decision.headers[name], value) end
					for name in pairs(decision.headers) do helpers.assert_true(expected[name] ~= nil, "No extra forwarded header") end
				else helpers.assert_eq(decision[key], expected) end
			end
			if decision.action == "follow" then helpers.assert_eq(decision.url, input.target) end
			-- Caller mappings are never edited by the policy.
			for name, value in pairs(original_headers) do helpers.assert_eq(input.headers[name], value) end
			for name in pairs(input.headers) do helpers.assert_true(original_headers[name] ~= nil, "Caller header mapping was not extended") end
		end)
	end
end)

-- These additional outcomes were fixed from the native single-hop contract,
-- independently of the producer. The original33 corpus bytes remain intact.
helpers.describe("successful terminal native observation admission", function()
	local function input(receipt)
		return { current_url = "https://updates.example/start", https_floor = true, headers = {}, visited = {}, hops = 0,
			result = { ok = true, status = 200, body = "literal terminal bytes", redirect_receipt = receipt } }
	end
	helpers.it("successful missing observation refuses", function()
		local decision = law.transition(input(nil))
		helpers.assert_eq(decision.action, "refuse"); helpers.assert_eq(decision.error, "HTTP redirect receipt refused")
	end)
	helpers.it("successful previously followed observation refuses", function()
		local decision = law.transition(input({ format = "curl-single-hop-v1", http_status = 200, curl_exit = 0,
			num_redirects = 1, effective_url = "https://updates.example/start", redirect_url = "" }))
		helpers.assert_eq(decision.action, "refuse"); helpers.assert_eq(decision.error, "HTTP redirect receipt refused")
	end)
	helpers.it("successful observation of a different effective origin refuses", function()
		local decision = law.transition(input({ format = "curl-single-hop-v1", http_status = 200, curl_exit = 0,
			num_redirects = 0, effective_url = "https://foreign.example/start", redirect_url = "" }))
		helpers.assert_eq(decision.action, "refuse"); helpers.assert_eq(decision.error, "HTTP redirect URL refused")
	end)
	helpers.it("successful result contradicting native nonzero observation refuses", function()
		local decision = law.transition(input({ format = "curl-single-hop-v1", http_status = 200, curl_exit = 7,
			num_redirects = 0, effective_url = "https://updates.example/start", redirect_url = "" }))
		helpers.assert_eq(decision.action, "refuse"); helpers.assert_eq(decision.error, "HTTP redirect receipt refused")
	end)
	helpers.it("ordinary failed HTTP response retains primary failure without observation", function()
		local value = input(nil); value.result = { ok = false, status = 403, body = "denied bytes", error = "HTTP 403" }
		local decision = law.transition(value)
		helpers.assert_eq(decision.action, "terminal"); helpers.assert_eq(value.result.body, "denied bytes")
		helpers.assert_eq(value.result.error, "HTTP 403")
	end)
end)
