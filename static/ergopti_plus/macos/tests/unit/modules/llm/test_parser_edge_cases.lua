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
_G.hs.settings.set("ergopti.llm_min_words", 1)
package.loaded["modules.llm.init"] = { DEFAULT_STATE = { llm_min_words = 1, llm_max_words = 5 } }

local parser = helpers.load_with_stubs("modules.llm.parser")
local text_utils = require("text_utils")

-- Re-stub hs after load_with_stubs reset it
_G.hs.settings.set("ergopti.llm_min_words", 1)
package.loaded["modules.llm.init"] = { DEFAULT_STATE = { llm_min_words = 1, llm_max_words = 5 } }


--- Applies the parser's physical tail replacement through the strict shared helper.
--- @param buffer string Original logical buffer.
--- @param prediction table Parser result.
--- @return string Reconstructed buffer.
local function apply_prediction(buffer, prediction)
	local next_buffer, err = text_utils.replace_utf8_tail(
		buffer, prediction.deletes, prediction.to_type)
	helpers.assert_nil(err, "the parser must emit an injectable UTF-8 replacement")
	helpers.assert_not_nil(next_buffer)
	return next_buffer
end


--- Captures parser ERROR diagnostics while restoring every logger alias exactly.
--- @param callback function Test body receiving the captured messages.
--- @return table messages
local function capture_parser_errors(callback)
	local candidates = { require("infra.logger"), require("logger.shim") }
	local patched = {}
	local messages = {}
	for _, logger in ipairs(candidates) do
		if not patched[logger] then
			patched[logger] = logger.error
			logger.error = function(log, format_string, ...)
				if log == "llm.parser" then
					messages[#messages + 1] = string.format(format_string, ...)
				end
			end
		end
	end

	local outcome = table.pack(xpcall(function() callback(messages) end, debug.traceback))
	for logger, original_error in pairs(patched) do logger.error = original_error end
	if not outcome[1] then error(outcome[2], 0) end
	return messages
end

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

	helpers.it("rejects malformed UTF-8 instead of dropping bytes during tokenization", function()
		local errors = capture_parser_errors(function()
			local ok, result = pcall(parser.process_prediction,
				"x", "x", string.char(0x80))
			helpers.assert_true(ok,
				"the parser must contain an invalid UTF-8 continuation byte")
			helpers.assert_nil(result,
				"invalid bytes must never survive into an injectable prediction")
		end)
		helpers.assert_eq(#errors, 1,
			"a malformed model result must reach the parser's explicit refusal boundary")
		helpers.assert_contains(errors[1], "invalid UTF-8")
	end)

	helpers.it("reconstructs a long UTF-8 URL at every multibyte window offset", function()
		local e_acute = string.char(0xC3, 0xA9)
		local han = string.char(0xE6, 0xBC, 0xA2)
		local emoji = string.char(0xF0, 0x9F, 0x98, 0x80)
		local after = "aa" .. e_acute .. emoji .. "a/aa" .. emoji .. han:rep(3) .. "aaa"
		local tail = emoji .. after
		local corrected_tail = "d" .. after
		local path_pattern = ("segment/"):rep(8)
		local cases = {
			{ marker = e_acute, offsets = 2 },
			{ marker = han, offsets = 3 },
		}

		for _, case in ipairs(cases) do
			for offset = 1, case.offsets do
				local between_length = 59 + offset - #case.marker - #tail
				local rotation = #case.marker + 5 - offset
				local between = (path_pattern .. path_pattern):sub(
					rotation + 1, rotation + between_length)
				local prefix = "https://" .. case.marker .. between
				local full_text = prefix .. tail
				local raw_window_start = #full_text - 60 + 1
				local marker_start = #"https://" + 1

				helpers.assert_eq(raw_window_start, marker_start + offset - 1,
					"the fixture must exercise the requested byte offset inside the marker")
				helpers.assert_true(#full_text > 60)
				helpers.assert_true(text_utils.utf8_len(full_text) < 60,
					"the logical 60-character window must still contain the whole buffer")

				local result = parser.process_prediction(full_text, tail,
					"TAIL_CORRECTED: " .. corrected_tail .. "\nNEXT_WORDS: next")
				helpers.assert_not_nil(result)
				helpers.assert_eq(result.deletes, text_utils.utf8_len(tail))
				helpers.assert_eq(result.to_type, corrected_tail .. " next")
				helpers.assert_eq(apply_prediction(full_text, result),
					prefix .. corrected_tail .. " next",
					"delete and insert units must reconstruct the exact corrected UTF-8 context")
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
