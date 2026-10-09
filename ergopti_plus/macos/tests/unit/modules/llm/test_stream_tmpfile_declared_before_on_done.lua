--- tests/unit/modules/llm/test_stream_tmpfile_declared_before_on_done.lua

--- ==============================================================================
--- MODULE: Regression — tmp_path declared before on_done closure
--- DESCRIPTION:
--- Guards against the Lua lexical-scoping foot-gun where a local variable
--- declared AFTER a closure that references it makes the closure capture the
--- nil global instead of the intended upvalue.
---
--- Root cause (2026-06-19): In post_and_parse_streaming, `local tmp_path` was
--- declared at line ~615, but `local function on_done` at line ~555 called
--- `os.remove(tmp_path)`. Lua scoping means on_done captured the nil global.
--- ShellRunner wraps callbacks in pcall, so the throw was silently swallowed
--- and ALL streaming completions aborted — Ollama predictions never appeared.
---
--- This test reads the source file and asserts that the lexical position of
--- `local tmp_path` comes strictly before `local function on_done`.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================================
-- =========================================================
-- ======= 1/ Lexical Order: tmp_path before on_done =======
-- =========================================================
-- =========================================================

helpers.describe("api_ollama streaming: tmp_path declaration order", function()
	helpers.it("declares tmp_path before the on_done closure", function()
		-- Resolve source relative to this test file's location
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		-- Navigate up from tests/unit/modules/llm/ to modules/llm/
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local ollama_src = base .. "/modules/llm/api_ollama.lua"

		local fh = io.open(ollama_src, "r")
		helpers.assert_true(fh ~= nil, "Cannot open api_ollama.lua at: " .. ollama_src)

		local tmp_path_line   = nil
		local on_done_line    = nil
		local line_num        = 0

		for line in fh:lines() do
			line_num = line_num + 1
			-- Match declaration of tmp_path local (the hoisted one)
			if not tmp_path_line and line:match("^%s*local tmp_path%s*=") then
				tmp_path_line = line_num
			end
			-- Match definition of the on_done closure
			if not on_done_line and line:match("^%s*local function on_done") then
				on_done_line = line_num
			end
			if tmp_path_line and on_done_line then break end
		end
		fh:close()

		helpers.assert_true(tmp_path_line ~= nil, "local tmp_path declaration not found in api_ollama.lua")
		helpers.assert_true(on_done_line  ~= nil, "local function on_done not found in api_ollama.lua")
		helpers.assert_true(
			tmp_path_line < on_done_line,
			string.format(
				"tmp_path (line %d) must be declared BEFORE on_done (line %d) — " ..
				"Lua lexical scoping: closure captures nil global otherwise",
				tmp_path_line, on_done_line
			)
		)
	end)
end)
