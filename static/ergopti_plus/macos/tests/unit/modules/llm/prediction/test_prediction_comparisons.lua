--- tests/unit/modules/llm/prediction/test_prediction_comparisons.lua
local helpers = require("tests.helpers")
local Parser = helpers.load_with_stubs("ai.engine.api.parser_core")

helpers.describe("prediction comparisons", function()
	helpers.it("preserves comparison operators while removing generated HTML tags", function()
		local result = Parser.process_prediction("valeur", "valeur",
			"TAIL_CORRECTED: valeur\nNEXT_WORDS: <b>1 < 2 > 0</b>")
		helpers.assert_true(result ~= nil)
		helpers.assert_eq(result.to_type, " 1 < 2 > 0")
	end)
	helpers.it("still removes a tag with attributes", function()
		local result = Parser.process_prediction("valeur", "valeur",
			"TAIL_CORRECTED: valeur\nNEXT_WORDS: <span class=em>bonjour</span>")
		helpers.assert_true(result ~= nil)
		helpers.assert_eq(result.to_type, " bonjour")
	end)
end)
