--- tests/unit/llm/test_rewrite_vectors.lua

--- ==============================================================================
--- MODULE: Rewrite Request Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/rewrite_vectors.json through the shared
--- rewrite helpers (_shared/lua/llm/rewrite.lua), which macOS and Linux both use
--- and the AutoHotkey port replays too: the sentence a rewrite prompt rewrites,
--- its token budget, and which prompts are rewrite prompts.
---
--- ROOT CAUSE ENCODED:
--- A prediction request only ever sent the last five words as its tail and a
--- budget sized for a few new words, so no prompt could rewrite the sentence
--- being typed: the model saw a fragment and its answer was cut off.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local Rewrite = require("llm.rewrite")
local Tone = require("llm.tone")

local CORPUS = helpers.shared("tests/corpus/llm/rewrite_vectors.json")

--- @return table The decoded corpus.
local function read_corpus()
	local fh = assert(io.open(CORPUS, "r"), "cannot open " .. CORPUS)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), "the rewrite corpus is not valid JSON")
end




-- ============================================
-- ======= 1/ Corpus replay ===================
-- ============================================

helpers.describe("rewrite helpers replay the shared rewrite corpus", function()
	local corpus = read_corpus()

	helpers.it("the corpus holds every family of vectors", function()
		helpers.assert_true(#corpus.sentence_vectors >= 10, "sentence vectors")
		helpers.assert_true(#corpus.max_tokens_vectors >= 3, "max_tokens vectors")
		helpers.assert_true(#corpus.prompt_vectors >= 3, "prompt vectors")
	end)

	for _, vector in ipairs(corpus.sentence_vectors) do
		helpers.it("sentence vector '" .. vector.id .. "'", function()
			local span = Rewrite.sentence_span(vector.buffer)
			helpers.assert_eq(span, vector.span, vector.id)
			local suffix = vector.buffer:sub(#vector.buffer - #span + 1)
			helpers.assert_eq(span == "" or suffix == span, true,
				vector.id .. ": the span must be an exact suffix of the buffer")
		end)
	end

	for _, vector in ipairs(corpus.max_tokens_vectors) do
		helpers.it("max_tokens vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Rewrite.max_tokens(vector.span), vector.max_tokens, vector.id)
		end)
	end

	for _, vector in ipairs(corpus.prompt_vectors) do
		helpers.it("prompt vector '" .. vector.id .. "'", function()
			helpers.assert_eq(Rewrite.is_rewrite_prompt(vector.prompt), vector.is_rewrite, vector.id)
		end)
	end
end)




-- ============================================
-- ======= 2/ Shipped profile =================
-- ============================================

helpers.describe("the shipped rewrite profile is a rewrite prompt", function()
	helpers.it("profiles.json holds a rewrite profile the helpers recognise", function()
		local fh = assert(io.open(helpers.shared("modules/llm/profiles.json"), "r"))
		local profiles = json.decode(fh:read("*a"))
		fh:close()
		local found
		for _, profile in ipairs(profiles) do
			if profile.id == "rewrite" then found = profile end
		end
		helpers.assert_true(found ~= nil, "the rewrite profile must ship")
		helpers.assert_true(Rewrite.is_rewrite_profile(found), "its prompt must ask for REWRITE:")
		-- The PREFIX/TAIL user turn is chosen by sniffing both words in the prompt
		helpers.assert_true(found.system_single:find("PREFIX", 1, true) ~= nil
			and found.system_single:find("TAIL", 1, true) ~= nil, "the prompt must name PREFIX and TAIL")
		helpers.assert_true(found.system_single:find("TAIL_CORRECTED", 1, true) == nil,
			"the prompt must not ask for the continuation format")
		helpers.assert_eq(found.batch, false, "a rewrite is one request per prediction")
	end)

	-- The tone ladder (llm/tone.lua) rewrites a selection into a register, and
	-- the live translations (translate_<language>) rewrite the current sentence
	-- into another language: they are rewrite prompts too, and nothing else may be one
	helpers.it("no other built-in profile than the tone ladder and the translations is a rewrite profile", function()
		local fh = assert(io.open(helpers.shared("modules/llm/profiles.json"), "r"))
		local profiles = json.decode(fh:read("*a"))
		fh:close()
		local ladder = {}
		for _, id in ipairs(Tone.LADDER) do ladder[id] = true end
		local rungs = 0
		for _, profile in ipairs(profiles) do
			if ladder[profile.id] then
				helpers.assert_eq(Rewrite.is_rewrite_profile(profile), true, profile.id)
				rungs = rungs + 1
			elseif profile.id:match("^translate_%l%l$") then
				helpers.assert_eq(Rewrite.is_rewrite_profile(profile), true, profile.id)
			elseif profile.id ~= "rewrite" then
				helpers.assert_eq(Rewrite.is_rewrite_profile(profile), false, profile.id)
			end
		end
		helpers.assert_eq(rungs, #Tone.LADDER, "every rung of the tone ladder must ship")
	end)
end)
