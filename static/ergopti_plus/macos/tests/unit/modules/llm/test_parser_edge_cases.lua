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

	-- The parser has no pause state of its own: the engine gates before calling
	-- it. That claim used to be written as assert_true(true) with a sentence.
	-- What is checkable is that the coupling is genuinely absent — a pause check
	-- here would mean two modules decide whether a prediction reaches the
	-- tooltip, and a parser that returned early on its own reading of the flag
	-- would drop predictions the engine believed it had accepted.
	helpers.it("parses without consulting pause state (project_suspend_pause_invariant)", function()
		local src = helpers.read_driver_source("function M.process_prediction")
		helpers.assert_true(src ~= nil, "modules/llm/parser.lua source must be locatable")
		helpers.assert_true(src:find("paus") == nil,
			"the parser must stay pure — the pause gate belongs to the engine that calls it")
		helpers.assert_true(src:find("suspend") == nil, "same for suspend")
	end)

	helpers.it("malformed UTF-8 in volume returns a well-formed answer, never a raised error", function()
		-- The loop is worth keeping — it is the only place invalid continuation
		-- bytes are fed in bulk — but the old version threw every answer away and
		-- asserted true, so a parser that had started raising, or returning a
		-- malformed table the tooltip then indexed, would have passed.
		--
		-- Deliberately NOT asserted here: that the result is nil. It is not. A
		-- lone 0x80 byte comes back as a prediction whose to_type is that byte,
		-- while "<random gibberish>" two cases below comes back nil — the untagged
		-- body is rejected in one shape and accepted in the other. That asymmetry
		-- is real and lives in _shared/lua/llm, so pinning either answer here
		-- would freeze a decision this file is not the place to make.
		for i = 1, 80 do
			local ok, res = pcall(parser.process_prediction, "x", "x", string.char(0x80 + (i % 0x40)))
			helpers.assert_true(ok, "the parser must not raise on an invalid UTF-8 continuation byte")
			if res ~= nil then
				helpers.assert_eq(type(res), "table", "a non-nil result must be the documented table")
				helpers.assert_eq(type(res.to_type), "string",
					"to_type is typed straight into the buffer — a non-string there is a crash at the "
						.. "keystroke path, one frame later and far from here")
			end
		end
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
		local ok, res = pcall(parser.process_prediction, nil, nil, body)
		helpers.assert_true(ok, "parser must not crash on nil buffer")
		helpers.assert_true(res == nil or type(res) == "table",
			"and must answer nil or the documented table, never a half-value")
	end)
end)
