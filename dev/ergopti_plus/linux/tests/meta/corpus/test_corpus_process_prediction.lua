--- tests/meta/corpus/test_corpus_process_prediction.lua

--- ==============================================================================
--- MODULE: process_prediction Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/process_prediction_vectors.json through the
--- shared reply parser (_shared/lua/llm/parser.lua), which the Linux prediction
--- engine requires to turn a model reply into the physical injection: deletes,
--- text to type, word count, corrections and bold.
---
--- ROOT CAUSE ENCODED:
--- The corpus skip on Linux probed a module named modules.llm.parser that
--- never existed, so it stayed green while the engine ran the shared parser
--- with no row of this corpus replayed against it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/llm/process_prediction_vectors.json"

--- Reads and decodes the shared corpus.
--- @return table corpus
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(Json.decode(raw), "the process_prediction corpus is not valid JSON")
end

--- Coerces a truthy or falsy value to a strict boolean.
local function as_bool(value) return value and true or false end

helpers.describe("process_prediction corpus: the shared parser on Linux", function()
	local corpus = read_corpus()
	local Parser = helpers.load_module("llm.parser")

	helpers.it("the corpus carries vectors", function()
		helpers.assert_true(#corpus.vectors >= 10, "the process_prediction corpus lost its vectors")
	end)

	for _, vector in ipairs(corpus.vectors) do
		helpers.it("vector '" .. tostring(vector.id) .. "'", function()
			local prediction = Parser.process_prediction(vector.full_text, vector.tail_text, vector.block,
				{ min_words = vector.min_words, max_words = vector.max_words })
			local expected = vector.expected
			if expected.is_nil then
				helpers.assert_eq(prediction, nil, vector.id .. ": no prediction")
				return
			end
			helpers.assert_true(prediction ~= nil, vector.id .. ": a prediction")
			helpers.assert_eq(prediction.deletes, expected.deletes, vector.id .. ": deletes")
			helpers.assert_eq(prediction.to_type, expected.to_type, vector.id .. ": to_type")
			helpers.assert_eq(prediction.nw, expected.nw, vector.id .. ": nw")
			helpers.assert_eq(as_bool(prediction.has_corrections), as_bool(expected.has_corrections),
				vector.id .. ": has_corrections")
			helpers.assert_eq(as_bool(prediction.disable_bold), as_bool(expected.disable_bold),
				vector.id .. ": disable_bold")
		end)
	end
end)
