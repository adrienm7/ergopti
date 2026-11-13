--- tests/unit/modules/llm/prediction/test_prediction_unicode_escapes.lua
local helpers = require("tests.helpers")
local Parser = helpers.load_with_stubs("ai.engine.api.parser_core")

helpers.describe("prediction Unicode escapes", function()
	helpers.it("inserts a supplementary character represented by a UTF-16 surrogate pair", function()
		local result = Parser.process_prediction("bonjour", "bonjour",
			"TAIL_CORRECTED: bonjour\nNEXT_WORDS: \\uD83D\\uDE00")
		helpers.assert_true(result ~= nil)
		helpers.assert_eq(result.to_type, " 😀")
	end)
end)
