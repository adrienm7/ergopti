--- tests/unit/modules/llm/test_parser_spacing.lua

--- ==============================================================================
--- MODULE: One Space Between The Text And The Prediction
--- DESCRIPTION:
--- The parser spaced a basic completion against the context's TAIL, which is
--- rebuilt from words and never ends with a space. Accepting " que tout va
--- bien" after "bonjour " therefore typed "bonjour  que tout va bien": the
--- live daemon check read the double space off the kernel. It now spaces
--- against the character actually before the caret.
--- ==============================================================================

local helpers = require("tests.helpers")
local Parser = require("llm.parser")
local PromptBuilder = require("llm.prompt_builder")

--- The text a completion adds after a context, as the engine computes it.
--- @param context string
--- @param reply string
--- @return string|nil
local function typed_after(context, reply)
	local params = PromptBuilder.build_params(context, { min_words = 3, max_words = 15 })
	local candidate = Parser.process_prediction(params.context, params.context_tail, reply,
		{ min_words = 3, max_words = 15 })
	return candidate and candidate.to_type or nil
end

helpers.describe("parser: spacing a basic completion", function()

	helpers.it("adds no space after a context that ends with one", function()
		helpers.assert_eq(typed_after("bonjour ", " que tout va bien"), "que tout va bien")
	end)

	helpers.it("adds one after a context that ends with a word", function()
		helpers.assert_eq(typed_after("bonjour", "que tout va bien"), " que tout va bien")
	end)

	helpers.it("adds none after an apostrophe", function()
		helpers.assert_eq(typed_after("je pense qu’", " il fait beau aujourd’hui"), "il fait beau aujourd’hui")
	end)

end)
