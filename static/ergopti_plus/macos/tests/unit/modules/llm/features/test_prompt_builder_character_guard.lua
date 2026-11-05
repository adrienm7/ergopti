--- tests/unit/modules/llm/features/test_prompt_builder_character_guard.lua

--- ==============================================================================
--- MODULE: Prompt Builder Character Guard
--- DESCRIPTION:
--- A Unicode codepoint obeys the same minimum context as an ASCII letter.
--- ==============================================================================
local helpers = require("tests.helpers")
local Prompt = require("modules.llm.prompt_builder")
local config = { max_words = 5, min_words = 1, num_predictions = 1, temperature = 0.2 }

helpers.describe("prompt builder minimum context", function()
	for _, value in ipairs({ "a", "é", "中", "😀" }) do
		helpers.it("refuses one Unicode codepoint " .. value, function()
			local params, reason = Prompt.build(value, config, nil, false)
			helpers.assert_nil(params)
			helpers.assert_eq(reason, "context too short (1 chars)")
		end)
	end
	helpers.it("accepts two codepoints and keeps force-trigger behavior", function()
		for _, value in ipairs({ "éa", "中é", "😀a", "é" }) do
			helpers.assert_not_nil(Prompt.build(value, config, nil, false))
		end
		helpers.assert_not_nil(Prompt.build("é", config, nil, true))
	end)
	helpers.it("keeps the freshness guard for an unchanged context", function()
		local params, _, signature = Prompt.build("éa", config, nil, false)
		helpers.assert_not_nil(params)
		local duplicate, reason = Prompt.build("éa", config, signature, false)
		helpers.assert_nil(duplicate)
		helpers.assert_eq(reason, "buffer unchanged (freshness)")
		helpers.assert_not_nil(Prompt.build("éa", config, signature, true))
	end)
end)
