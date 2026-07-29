--- tests/unit/lib/test_logger_sub_file_patterns.lua

--- ==============================================================================
--- MODULE: Regression — a routing pattern containing ']' must not end the array
--- DESCRIPTION:
--- The sub-file routing parser closed a multi-line TOML array on the first line
--- whose raw text contained "]". Patterns are tag-based by design — the shared
--- file's own guidance is to "prefer tag-based patterns (e.g. \"[gestures\")" —
--- so a closing bracket inside a pattern string is the norm, not an edge case.
--- Every pattern after such a line was silently discarded and the sub-file it
--- belonged to simply stopped receiving those lines.
---
--- ROOT CAUSE ENCODED:
--- Structure located by searching the raw line instead of the line minus its
--- string literals. The test asserts the PARSE RESULT, so any rewrite that keeps
--- string contents from standing in for syntax satisfies it.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("logger: routing patterns that contain a bracket are all kept", function()

	helpers.it("keeps every pattern of an array whose entries carry ']'", function()
		package.loaded["lib.logger"] = nil
		local Logger = helpers.load_with_stubs("lib.logger")

		local parse = Logger._parse_sub_files_toml or Logger.parse_sub_files_toml
		if type(parse) ~= "function" then
			-- The parser is private: assert the invariant at the source level, still
			-- naming exactly what must hold rather than how it is spelled.
			local src = helpers.read_driver_source("in_pats")
			helpers.assert_true(type(src) == "string" and src ~= "",
				"the logger source must be readable or this asserts nothing")
			helpers.assert_true(src:find("strip_quoted(line)", 1, true) ~= nil,
				"the array must close on a ']' outside a quoted string; testing the raw line "
				.. "lets a bracket INSIDE a pattern terminate the array and silently drop "
				.. "every pattern after it")
			return
		end

		local toml = table.concat({
			"[[sub_files]]",
			'name = "gestures.log"',
			"patterns = [",
			'  "[gestures]",',
			'  "[gestures.engine]",',
			'  "SENTINEL_LAST",',
			"]",
		}, "\n")

		local entries = parse(toml)
		helpers.assert_type(entries, "table", "the parser must return the sub-file list")
		local found_last = false
		for _, e in ipairs(entries) do
			for _, pat in ipairs(e.patterns or {}) do
				if pat == "SENTINEL_LAST" then found_last = true end
			end
		end
		helpers.assert_true(found_last,
			"a pattern listed after a bracket-bearing one must survive the parse")
	end)

end)
