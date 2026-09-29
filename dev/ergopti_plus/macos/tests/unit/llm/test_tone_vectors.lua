--- tests/unit/llm/test_tone_vectors.lua

--- ==============================================================================
--- MODULE: Tone Ladder Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/tone_vectors.json through the shared tone
--- ladder (_shared/lua/llm/tone.lua), which the macOS tone actions run and the
--- AutoHotkey port replays too: the next register, which text a step rewrites,
--- and how the model's answer is read.
---
--- ROOT CAUSE ENCODED:
--- A step that rewrote the previous rewrite instead of the original drifted a
--- little further from what the user wrote at each swipe, and an answer read
--- with its tag, bold or quotes typed those into the document.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local Tone = require("llm.tone")

local CORPUS = helpers.shared("tests/corpus/llm/tone_vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the tone corpus is not valid JSON")
end

helpers.describe("tone ladder replays the shared tone corpus", function()
	local corpus = read_corpus()

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

	helpers.it("remember ties the output to the plan's source and level", function()
		local plan = Tone.plan("merci pour ton aide", nil, Tone.MORE_FORMAL, false)
		local memory = Tone.remember(plan, "Merci pour votre aide.")
		helpers.assert_eq(memory.source, "merci pour ton aide")
		helpers.assert_eq(memory.output, "Merci pour votre aide.")
		helpers.assert_eq(memory.level, 3)
		local next_plan = Tone.plan("Merci pour votre aide.", memory, Tone.MORE_FORMAL, false)
		helpers.assert_eq(next_plan.source, "merci pour ton aide", "the next step rewrites the original")
		helpers.assert_eq(next_plan.profile_id, "tone_very_formal")
	end)
end)
