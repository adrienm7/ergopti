--- tests/meta/corpus/test_corpus_tone.lua

--- ==============================================================================
--- MODULE: Tone Ladder Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/tone_vectors.json through the shared tone
--- ladder (_shared/lua/llm/tone.lua) that the Linux prediction engine loads for
--- the more formal and more familiar actions: the next register, which text a
--- step rewrites, and how the model's answer is read.
---
--- ROOT CAUSE ENCODED:
--- The corpus header promised a Linux replay that did not exist. A step that
--- rewrote the previous rewrite instead of the original drifted from what the
--- user wrote at each swipe, and an answer read with its tag, bold or quotes
--- typed those into the document; macOS and Windows pinned both, Linux did not.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local CORPUS = helpers.driver_root() .. "/../_shared/tests/corpus/llm/tone_vectors.json"

--- Reads and decodes the shared corpus.
--- @return table corpus
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(Json.decode(raw), "the tone corpus is not valid JSON")
end

helpers.describe("tone corpus: the shared tone ladder on Linux", function()
	local corpus = read_corpus()
	local Tone = helpers.load_module("llm.tone")

	helpers.it("the corpus holds every family of vectors", function()
		helpers.assert_true(#corpus.step_vectors >= 6, "step vectors")
		helpers.assert_true(#corpus.plan_vectors >= 6, "plan vectors")
		helpers.assert_true(#corpus.extract_vectors >= 8, "extract vectors")
	end)

	for _, vector in ipairs(corpus.step_vectors) do
		helpers.it("step vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Tone.step(vector.level, vector.direction, vector.cycle), vector.expected, vector.id)
		end)
	end

	for _, vector in ipairs(corpus.plan_vectors) do
		helpers.it("plan vector '" .. vector.id .. "'", function()
			local plan, reason = Tone.plan(vector.selection, vector.memory, vector.direction, vector.cycle)
			if vector.expected then
				helpers.assert_eq(reason, nil, vector.id .. ": no refusal")
				helpers.assert_eq(plan.source, vector.expected.source, vector.id .. ": source")
				helpers.assert_eq(plan.level, vector.expected.level, vector.id .. ": level")
				helpers.assert_eq(plan.profile_id, vector.expected.profile_id, vector.id .. ": profile")
			else
				helpers.assert_eq(plan, nil, vector.id .. ": nothing to rewrite")
				helpers.assert_eq(reason, vector.reason, vector.id .. ": reason")
			end
		end)
	end

	for _, vector in ipairs(corpus.extract_vectors) do
		helpers.it("extract vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Tone.extract(vector.block), vector.expected, vector.id)
		end)
	end
end)
