--- tests/unit/ai/engine/prediction/test_unicode_insertion.lua

--- The actual macOS replacement path must receive valid decoded Unicode.
local helpers = require("tests.helpers")
local Parser = require("ai.engine.api.parser_core")
local Fixture = require("tests.support.apply_prediction_fixture")

helpers.describe("Unicode prediction insertion", function()
	helpers.it("inserts a decoded supplementary character through the real bridge", function()
		local prediction = assert(Parser.process_prediction("bonjour", "bonjour",
			"TAIL_CORRECTED: bonjour\nNEXT_WORDS: \\uD83D\\uDE00"))
		local result = Fixture.run({ prediction = prediction, buffer = "bonjour", real_overlap = true })
		helpers.assert_true(result.call_ok)
		helpers.assert_eq(result.applied, true)
		helpers.assert_eq(result.clipboard_writes, { " 😀" }, "paste must contain the exact decoded scalar")
		helpers.assert_eq(#(result.events or {}), 2)
		helpers.assert_eq(result.events[1].key, "v")
		helpers.assert_eq(result.state.buffer, "bonjour 😀")
		helpers.assert_eq(result.state.llm_buffer, "bonjour 😀")
	end)
	helpers.it("preserves an unpaired surrogate escape as literal safe text", function()
		local prediction = assert(Parser.process_prediction("bonjour", "bonjour",
			"TAIL_CORRECTED: bonjour\nNEXT_WORDS: \\uD800"))
		local result = Fixture.run({ prediction = prediction, buffer = "bonjour", real_overlap = true })
		helpers.assert_true(result.call_ok)
		helpers.assert_eq(result.applied, true)
		helpers.assert_true(#(result.events or {}) > 0, "literal text must be emitted")
		helpers.assert_eq(result.state.buffer, "bonjour \\uD800")
	end)

end)
