--- tests/unit/modules/llm/test_prediction_apostrophe_boundaries.lua

--- ==============================================================================
--- MODULE: Prediction Apostrophe Boundary Regressions
--- DESCRIPTION:
--- Complete Unicode punctuation must not inherit apostrophe spacing merely
--- because its UTF-8 representation shares a byte with a typographic apostrophe.
--- ==============================================================================

local helpers = require("tests.helpers")
local ApplyPrediction = require("tests.support.apply_prediction_fixture")


helpers.describe("prediction apostrophe classification", function()
	for _, format in ipairs({ "plain", "advanced" }) do
		for _, suffix in ipairs({ "”", "😀", "€", "»" }) do
			helpers.it("separates " .. format .. " words after " .. suffix .. " (unicode-apostrophe)", function()
				helpers.load_with_stubs("infra.logger")
				local buffer = "hello" .. suffix
				local raw = format == "advanced"
					and "TAIL_CORRECTED: " .. buffer .. "\nNEXT_WORDS: then left" or "then left"
				local prediction = require("llm.parser").process_prediction(buffer, buffer, raw,
					{ min_words = 1, max_words = 0 })
				helpers.assert_not_nil(prediction)
				helpers.assert_eq(prediction.deletes, 0)
				helpers.assert_eq(prediction.to_type, " then left")
				local result = ApplyPrediction.run({ buffer = buffer, text = prediction.to_type,
					deletes = prediction.deletes, real_overlap = true })
				helpers.assert_true(result.applied)
				helpers.assert_eq(result.state.buffer, buffer .. " then left")
			end)
		end

		for _, apostrophe in ipairs({ "'", "’" }) do
			helpers.it("keeps the " .. format .. " contraction with " .. apostrophe .. " (unicode-apostrophe)", function()
				helpers.load_with_stubs("infra.logger")
				local buffer = "l" .. apostrophe
				local raw = format == "advanced"
					and "TAIL_CORRECTED: " .. buffer .. "\nNEXT_WORDS: idée claire" or "idée claire"
				local prediction = require("llm.parser").process_prediction(buffer, buffer, raw,
					{ min_words = 1, max_words = 0 })
				helpers.assert_not_nil(prediction)
				helpers.assert_eq(prediction.to_type, "idée claire")
			end)
		end
	end

	helpers.it("keeps the advanced hyphen continuation (unicode-apostrophe)", function()
		helpers.load_with_stubs("infra.logger")
		local prediction = require("llm.parser").process_prediction("anti-", "anti-",
			"TAIL_CORRECTED: anti-\nNEXT_WORDS: spam utile", { min_words = 1, max_words = 0 })
		helpers.assert_not_nil(prediction)
		helpers.assert_eq(prediction.to_type, "spam utile")
	end)
end)
