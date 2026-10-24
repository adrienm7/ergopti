--- tests/unit/modules/llm/vectors/test_remote_usage_vectors.lua

--- ==============================================================================
--- MODULE: Remote Usage and Cost Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/remote_usage_vectors.json through the
--- shared remote response classifier (_shared/lua/llm/remote_response_classifier.lua)
--- that macOS and Linux both use for the events_llm token and cost columns.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local Classifier = require("llm.remote_response_classifier")

-- Tolerance for comparing a computed dollar cost with its vector
local COST_TOLERANCE = 1e-12

local function read_vectors()
	local path = SHARED .. "tests/corpus/llm/remote_usage_vectors.json"
	local fh = assert(io.open(path, "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

local VECTORS = read_vectors()

helpers.describe("Remote usage corpus — token counts", function()
	for _, vec in ipairs(VECTORS.usage_vectors) do
		helpers.it(vec.id, function()
			local usage = Classifier.classify(vec.format, vec.body).usage
			helpers.assert_eq(usage.prompt_tokens, vec.expected.prompt_tokens, vec.id .. " prompt")
			helpers.assert_eq(usage.completion_tokens, vec.expected.completion_tokens, vec.id .. " completion")
			helpers.assert_eq(usage.total_tokens, vec.expected.total_tokens, vec.id .. " total")
		end)
	end
end)

helpers.describe("Remote usage corpus — model prices", function()
	local prices, skipped = Classifier.parse_prices(VECTORS.model_prices)

	helpers.it("admits exactly the valid price rows", function()
		local admitted = {}
		for model in pairs(prices) do admitted[#admitted + 1] = model end
		table.sort(admitted)
		helpers.assert_eq(table.concat(admitted, ","), table.concat(VECTORS.admitted_prices, ","))
		helpers.assert_eq(table.concat(skipped, ","), table.concat(VECTORS.skipped_prices, ","))
	end)

	for _, vec in ipairs(VECTORS.cost_vectors) do
		helpers.it(vec.id, function()
			local cost = Classifier.estimate_cost(prices, vec.model, vec.prompt_tokens, vec.completion_tokens)
			helpers.assert_true(math.abs(cost - vec.expected) < COST_TOLERANCE,
				vec.id .. ": got " .. tostring(cost) .. ", want " .. tostring(vec.expected))
		end)
	end
end)
