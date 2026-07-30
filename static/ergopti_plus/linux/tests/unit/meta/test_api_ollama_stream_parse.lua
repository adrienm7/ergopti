--- tests/unit/meta/test_api_ollama_stream_parse.lua

--- ==============================================================================
--- MODULE: Ollama Streaming Parse Regression Guard
--- DESCRIPTION:
--- Regression test for a broken streaming parser in modules/llm/api_ollama.lua.
---
--- ROOT CAUSE ENCODED:
--- chat() extracted each ndjson chunk's text with the Lua pattern
---   "content"%s*:%s*"(([^"\\]|\\")*)"
--- which uses PCRE alternation ('|'). Lua patterns have no alternation — '|' is a
--- literal — so the group matched nothing and every streamed prediction produced
--- empty output. Fixed by delegating to the shared bridge's parse_stream_line,
--- which JSON-decodes the line.
---
--- This test mocks io.popen to feed a realistic ndjson stream and asserts the
--- on_chunk callback receives the decoded text.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ================================================================
-- =================================================================
-- ======= 1/ Behavioural: streamed content reaches on_chunk =======
-- =================================================================
-- ================================================================

helpers.describe("api_ollama.chat: streaming ndjson content reaches on_chunk", function()
	helpers.it("extracts message.content from each streamed line", function()
		local orig_popen = io.popen
		local stream_lines = {
			'{"message":{"role":"assistant","content":"Hello"},"done":false}',
			'{"message":{"content":" world"},"done":false}',
			'{"message":{"content":""},"done":true}',
		}
		-- Fake pipe: pipe:lines() iterates stream_lines; pipe:close() is a no-op.
		io.popen = function()
			local i = 0
			return {
				lines = function()
					return function()
						i = i + 1
						return stream_lines[i]
					end
				end,
				close = function() end,
			}
		end

		local ao = helpers.load_module("modules.llm.api_ollama")
		local chunks = {}
		local ok, err = pcall(function()
			ao.chat("http://127.0.0.1:11434/api/chat", "test-model",
				{ { role = "user", content = "hi" } },
				{ stream = true },
				function(delta) chunks[#chunks + 1] = delta end,
				function() end)
		end)

		io.popen = orig_popen

		helpers.assert_true(ok, "chat() must not crash parsing the stream; got: " .. tostring(err))
		local joined = table.concat(chunks)
		helpers.assert_true(joined:find("Hello", 1, true) ~= nil, "on_chunk should receive 'Hello' from the first line")
		helpers.assert_true(joined:find("world", 1, true) ~= nil, "on_chunk should receive ' world' from the second line")
	end)
end)
