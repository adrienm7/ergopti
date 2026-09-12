--- tests/unit/modules/llm/test_prediction_unicode_word_overlap.lua

--- ==============================================================================
--- MODULE: Prediction Unicode Whole-Word Overlap
--- DESCRIPTION:
--- Comparison and removal must count the same complete semantic word tokens.
--- An ASCII fragment of an accented word is never an overlapping whole word.
--- ==============================================================================

local helpers = require("tests.helpers")
local ApplyPrediction = require("tests.support.apply_prediction_fixture")


helpers.describe("prediction Unicode word overlap", function()
	for _, pair in ipairs({ { "café", "caféine" }, { "thé", "théâtre" }, { "tea", "theatre" } }) do
		helpers.it("retains distinct word " .. pair[2] .. " after " .. pair[1] .. " (unicode-word-overlap)", function()
			helpers.load_with_stubs("infra.logger")
			local buffer = "hello " .. pair[1]
			local prediction = require("llm.parser").process_prediction(buffer, buffer,
				"TAIL_CORRECTED: " .. buffer .. "\nNEXT_WORDS: " .. pair[2] .. " tomorrow",
				{ min_words = 1, max_words = 0 })
			helpers.assert_not_nil(prediction)
			helpers.assert_eq(prediction.deletes, 0)
			helpers.assert_eq(prediction.to_type, " " .. pair[2] .. " tomorrow")
			local result = ApplyPrediction.run({ buffer = buffer, text = prediction.to_type,
				deletes = prediction.deletes, real_overlap = true })
			helpers.assert_true(result.applied)
			helpers.assert_eq(result.state.buffer, buffer .. " " .. pair[2] .. " tomorrow")
		end)
	end

	for _, word in ipairs({ "tea", "café", "été", "é", "漢" }) do
		helpers.it("still removes the complete repeated word " .. word .. " (unicode-word-overlap)", function()
			helpers.load_with_stubs("infra.logger")
			local buffer = "hello " .. word
			local prediction = require("llm.parser").process_prediction(buffer, buffer,
				"TAIL_CORRECTED: " .. buffer .. "\nNEXT_WORDS: " .. word .. " tomorrow",
				{ min_words = 1, max_words = 0 })
			helpers.assert_not_nil(prediction)
			helpers.assert_eq(prediction.deletes, 0)
			helpers.assert_eq(prediction.to_type, " tomorrow")
		end)
	end
end)
