--- macos/tests/unit/modules/llm/vectors/test_local_model_presence_vectors.lua

--- ==============================================================================
--- MODULE: Local Model Presence Vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/local_model_presence.json through the shared
--- policy that api_ollama.lua loads, as Linux already does: model-name
--- normalization, the exact "model not found" errors and the strict listing
--- receipt.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local function read_corpus()
	local handle = assert(io.open(helpers.shared("tests/corpus/llm/local_model_presence.json"), "rb"))
	local corpus = assert(Json.decode_lossless(handle:read("*a")))
	handle:close()
	return corpus
end

--- The corpus spells an absent result as JSON null.
local function expected_of(vector)
	return not Json.is_null(vector.expected) and vector.expected or nil
end

helpers.describe("local model presence vectors (macOS)", function()
	local Policy = require("llm.local_model_policy")
	local corpus = read_corpus()

	for _, vector in ipairs(corpus.normalization) do
		helpers.it("normalizes " .. string.format("%q", vector.name), function()
			helpers.assert_eq(Policy.normalize(vector.name), expected_of(vector))
		end)
	end

	for _, vector in ipairs(corpus.missing_responses) do
		helpers.it("reads the missing model of HTTP " .. vector.status .. " " .. vector.error, function()
			helpers.assert_eq(Policy.missing_model(vector.status, vector.error), expected_of(vector))
		end)
	end

	for _, vector in ipairs(corpus.lists) do
		helpers.it("admits the listing " .. vector.body .. " (HTTP " .. vector.status .. ")", function()
			local names, reason = Policy.list_receipt(vector)
			helpers.assert_eq(reason, vector.reason)
			if vector.reason then
				helpers.assert_nil(names)
				return
			end
			local count = 0
			for _ in pairs(names) do count = count + 1 end
			helpers.assert_eq(count, #vector.names)
			for _, name in ipairs(vector.names) do helpers.assert_true(names[name], name) end
		end)
	end
end)
