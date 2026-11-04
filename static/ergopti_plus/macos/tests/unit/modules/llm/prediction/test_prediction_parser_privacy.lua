--- tests/unit/modules/llm/prediction/test_prediction_parser_privacy.lua
local helpers = require("tests.helpers")
local Parser = helpers.load_with_stubs("llm.parser")
local logger = require("logger.shim")

helpers.describe("prediction parser diagnostic privacy", function()
	helpers.it("rejects stale predictions without logging the user's text", function()
		local original, messages = logger.warn, {}
		logger.warn = function(_, format, ...)
			messages[#messages + 1] = string.format(format, ...)
		end
		local ok, result = pcall(Parser.process_prediction, "privatealpha", "privatealpha",
			"TAIL_CORRECTED: zzzzzzzzzzzz\nNEXT_WORDS: tomorrow")
		logger.warn = original
		helpers.assert_true(ok)
		helpers.assert_nil(result)
		helpers.assert_eq(#messages, 1, "a useful diagnostic remains")
		helpers.assert_true(not messages[1]:find("privatealpha", 1, true))
		helpers.assert_true(not messages[1]:find("zzzzzzzzzzzz", 1, true))
	end)
end)
