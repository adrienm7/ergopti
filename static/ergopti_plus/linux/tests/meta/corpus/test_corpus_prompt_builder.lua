--- tests/meta/corpus/test_corpus_prompt_builder.lua

--- ==============================================================================
--- MODULE: PromptBuilder Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/prompt_builder/vectors.json through the shared
--- PromptBuilder (_shared/lua/llm/prompt_builder.lua), which the Linux
--- prediction engine and api_remote load to size every request: token budget,
--- temperature, context tail and truncation, and the passthrough fields.
---
--- ROOT CAUSE ENCODED:
--- This corpus used to be skipped on Linux because ergopti_hotstrings.lua does
--- not name llm.prompt_builder. The engine modules load it, so the skip stayed
--- green while the request parameters had no shared vector behind them.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/prompt_builder/vectors.json"

--- Reads and decodes the shared corpus.
--- @return table corpus
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(Json.decode(raw), "the prompt builder corpus is not valid JSON")
end

--- Compares one build_params() result with a vector's expectations.
--- @param result table
--- @param vector table
local function assert_vector(result, vector)
	local expected, id = vector.expected, vector.id
	if expected.max_tokens ~= nil then helpers.assert_eq(result.max_tokens, expected.max_tokens, id .. ": max_tokens") end
	if expected.temperature ~= nil then
		helpers.assert_true(math.abs(result.temperature - expected.temperature) <= 1e-9,
			string.format("%s: temperature %s, expected %s", id, tostring(result.temperature), tostring(expected.temperature)))
	end
	if expected.context_tail ~= nil then helpers.assert_eq(result.context_tail, expected.context_tail, id .. ": context_tail") end
	if expected.context_length_max ~= nil then
		helpers.assert_true(#result.context <= expected.context_length_max,
			string.format("%s: context of %d bytes exceeds %d", id, #result.context, expected.context_length_max))
	end
	if expected.context ~= nil then helpers.assert_eq(result.context, expected.context, id .. ": context") end
	if expected.language ~= nil then helpers.assert_eq(result.language, expected.language, id .. ": language") end
	if expected.min_words ~= nil then helpers.assert_eq(result.min_words, expected.min_words, id .. ": min_words") end
	if expected.num_predictions ~= nil then
		helpers.assert_eq(result.num_predictions, expected.num_predictions, id .. ": num_predictions")
	end
end

helpers.describe("prompt builder corpus: the shared PromptBuilder on Linux", function()
	local corpus = read_corpus()
	local PromptBuilder = helpers.load_module("llm.prompt_builder")

	helpers.it("corpus constants match the module constants", function()
		local constants = corpus.constants
		for _, name in ipairs({ "DEFAULT_MAX_TOKENS", "MIN_MAX_TOKENS", "CONTEXT_TAIL_WORDS",
			"TEMP_DIVERSITY_CAP", "GREEDY_TEMP_THRESHOLD" }) do
			helpers.assert_eq(PromptBuilder[name], constants[name], name)
		end
	end)

	helpers.it("the corpus carries vectors", function()
		helpers.assert_true(#corpus.vectors >= 10, "the prompt builder corpus lost its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("corpus vector '" .. vector.id .. "'", function()
			assert_vector(PromptBuilder.build_params(vector.buffer, vector.config), vector)
		end)
	end

	helpers.it("the module's own inline vectors pass", function()
		local vectors = PromptBuilder.test_vectors()
		helpers.assert_true(#vectors >= 1, "prompt_builder.test_vectors() returned nothing")
		for _, vector in ipairs(vectors) do
			assert_vector(PromptBuilder.build_params(vector.buffer, vector.config), vector)
		end
	end)
end)
