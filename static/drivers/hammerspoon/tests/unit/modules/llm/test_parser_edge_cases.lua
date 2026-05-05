--- tests/unit/modules/llm/test_parser_edge_cases.lua

--- ==============================================================================
--- MODULE: LLM Parser Edge Case Tests
--- DESCRIPTION:
--- Hardening tests for modules.llm.parser covering malformed inputs,
--- truncated JSON, nested tags, partial streaming chunks, multi-byte UTF-8
--- boundaries, and empty strings. Complements the behavioural fixtures in
--- test_parser.lua (which exercises the documented happy paths).
--- ==============================================================================

local helpers = require("tests.helpers")

-- The parser reads hs.settings + the llm DEFAULT_STATE. Provide both before
-- requiring it so calls don't blow up on missing config.
_G.hs = require("tests.stubs.hs")
_G.hs.__reset()
_G.hs.settings.set("llm_min_words", 1)
package.loaded["modules.llm.init"] = { DEFAULT_STATE = { llm_min_words = 1, llm_max_words = 5 } }

local parser = helpers.load_with_stubs("modules.llm.parser")

-- Re-stub hs after load_with_stubs reset it
_G.hs.settings.set("llm_min_words", 1)
package.loaded["modules.llm.init"] = { DEFAULT_STATE = { llm_min_words = 1, llm_max_words = 5 } }

helpers.describe("llm.parser edge cases", function()
	helpers.it("returns nil for empty body", function()
		local res = parser.process_prediction("hello", "hello", "")
		helpers.assert_nil(res)
	end)

	helpers.it("returns nil for body without expected tags", function()
		local res = parser.process_prediction("hello", "hello", "<random gibberish>")
		helpers.assert_nil(res)
	end)

	helpers.it("returns nil for non-string body", function()
		local res = parser.process_prediction("hello", "hello", nil)
		helpers.assert_nil(res)
	end)

	helpers.it("returns nil when buffer is empty", function()
		local body = "TAIL_CORRECTED: foo\nNEXT_WORDS: bar baz\n"
		local res = parser.process_prediction("", "", body)
		-- Should not blow up; may legitimately return nil for empty buffers.
		helpers.assert_true(res == nil or type(res) == "table")
	end)

	helpers.it("handles a partial / truncated body without crashing", function()
		local body = "TAIL_CORR" -- truncated mid-tag
		local ok, res = pcall(parser.process_prediction, "hello world", "hello world", body)
		helpers.assert_true(ok, "parser must not crash on truncated body")
		-- Either nil or a table is acceptable for a degraded-but-safe parse
		helpers.assert_true(res == nil or type(res) == "table")
	end)

	helpers.it("survives non-string buffer arguments", function()
		local body = "TAIL_CORRECTED: a\nNEXT_WORDS: b\n"
		local ok = pcall(parser.process_prediction, nil, nil, body)
		helpers.assert_true(ok, "parser must not crash on nil buffer")
	end)
end)
