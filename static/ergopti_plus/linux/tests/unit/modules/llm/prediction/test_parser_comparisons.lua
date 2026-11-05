--- tests/unit/modules/llm/prediction/test_parser_comparisons.lua
local helpers = require("tests.helpers")
local Parser = require("llm.parser")

helpers.describe("prediction comparisons", function()
	helpers.it("preserves comparisons while removing HTML tags", function()
		local result = Parser.process_prediction("valeur", "valeur",
			"TAIL_CORRECTED: valeur\nNEXT_WORDS: <b>1 < 2 > 0</b>")
		helpers.assert_true(result ~= nil)
		helpers.assert_eq(result.to_type, " 1 < 2 > 0")
	end)
end)
