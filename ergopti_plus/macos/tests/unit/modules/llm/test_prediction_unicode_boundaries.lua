--- tests/unit/modules/llm/test_prediction_unicode_boundaries.lua

--- ==============================================================================
--- MODULE: Prediction Unicode Boundary Regressions
--- DESCRIPTION:
--- Valid punctuation must survive parser padding removal and overlap spacing
--- cleanup as complete Unicode characters, never sliced UTF-8 bytes.
--- ==============================================================================

local helpers = require("tests.helpers")
local ApplyPrediction = require("tests.support.apply_prediction_fixture")


helpers.describe("prediction Unicode boundaries", function()
	for _, prefix in ipairs({ "...", "…", "• " }) do
		helpers.it("still removes model padding " .. prefix .. " (unicode-padding)", function()
			helpers.load_with_stubs("infra.logger")
			local result = require("llm.parser").process_prediction("hello", "hello",
				prefix .. "completion...", { min_words = 1, max_words = 0 })
			helpers.assert_not_nil(result)
			helpers.assert_eq(result.to_type, " completion")
		end)
	end

	helpers.it("accepts parsed Unicode through the real overlap and injection pipeline (unicode-padding)", function()
		helpers.load_with_stubs("infra.logger")
		local prediction = require("llm.parser").process_prediction("hello", "hello",
			"TAIL_CORRECTED: hello\nNEXT_WORDS: € completion", { min_words = 1, max_words = 0 })
		helpers.assert_not_nil(prediction)
		local result = ApplyPrediction.run({ buffer = "hello", text = prediction.to_type,
			deletes = prediction.deletes, real_overlap = true })
		helpers.assert_true(result.applied)
		helpers.assert_eq(result.state.buffer, "hello € completion")
		helpers.assert_eq(result.accepted_count, 1)
		helpers.assert_true(#(result.events or {}) > 0 or #result.posted_events > 0,
			"acceptance must construct or dispatch actual synthetic output")
	end)

	helpers.it("accepts a Unicode join without invalidating the cursor buffer (unicode-padding)", function()
		local result = ApplyPrediction.run({ buffer = "hello ", text = " € completion", real_overlap = true })
		helpers.assert_true(result.applied)
		helpers.assert_eq(result.state.buffer, "hello € completion")
		helpers.assert_eq(result.accepted_count, 1)
	end)

	for _, format in ipairs({ "plain", "advanced" }) do
		for _, text in ipairs({ "— completion", "€ completion", "completion æ", "completion …!" }) do
			helpers.it("preserves " .. format .. " boundary " .. text .. " (unicode-padding)", function()
				helpers.load_with_stubs("infra.logger")
				local parser = require("llm.parser")
				local block = format == "advanced" and "TAIL_CORRECTED: hello\nNEXT_WORDS: " .. text or text
				local result = parser.process_prediction("hello", "hello", block, { min_words = 1, max_words = 0 })
				helpers.assert_not_nil(result, "valid model punctuation must not become invalid UTF-8 internally")
				helpers.assert_not_nil(utf8.len(result.to_type))
				helpers.assert_true(result.to_type:find(text, 1, true) ~= nil,
					"padding cleanup must retain the complete punctuation and word suffix")
			end)
		end
	end

	for _, marker in ipairs({ "—", "…", "€", "«" }) do
		helpers.it("does not classify " .. marker .. " as leading whitespace (unicode-padding)", function()
			local utils = helpers.load_with_stubs("keymap.utils")
			local deletes, text = utils.resolve_prediction_overlap("hello " .. marker, 0, marker .. "completion")
			helpers.assert_eq(deletes, 1, "a complete nonspacing Unicode prefix must still participate in overlap")
			helpers.assert_eq(text, marker .. "completion")
		end)
		helpers.it("trims spacing without slicing " .. marker .. " (unicode-padding)", function()
			local utils = helpers.load_with_stubs("keymap.utils")
			for _, space in ipairs({ " ", "\u{00A0}", "\u{202F}" }) do
				local deletes, text = utils.resolve_prediction_overlap("hello ", 0, space .. marker .. " completion")
				helpers.assert_eq(deletes, 0)
				helpers.assert_eq(text, marker .. " completion")
				helpers.assert_not_nil(utf8.len(text))
			end
		end)
	end
end)
