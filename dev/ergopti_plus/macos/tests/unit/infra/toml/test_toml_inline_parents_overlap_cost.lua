--- tests/unit/infra/toml/test_toml_inline_parents_overlap_cost.lua

--- ==============================================================================
--- MODULE: Inline Parent Overlap Cost Tests
--- DESCRIPTION:
--- source_inline_scalar_parents runs on every preferences save. It found rows
--- whose case-folded paths nest by comparing every pair, lowercasing segments
--- on each comparison: about 45 000 pairs for a 300-operation save, roughly
--- 30 ms of a 43 ms call under Lua 5.4 (measured). A trie of folded segments
--- now finds the same pairs in one walk per row. These cases pin the linear
--- cost and that a case-folded nesting still withholds the inline parent.
--- ==============================================================================

local helpers = require("tests.helpers")

local SOURCE = "[a]\nchild={first=false,second=false}\n"

--- Counts string.lower calls while `body` runs.
--- @param body function Work to observe.
--- @return number calls
--- @return any result First result of body.
local function count_lower_calls(body)
	local original, calls = string.lower, 0
	string.lower = function(...) calls = calls + 1; return original(...) end
	local ok, result = pcall(body)
	string.lower = original
	if not ok then error(result, 0) end
	return calls, result
end

helpers.describe("inline scalar parents: overlap detection", function()
	helpers.it("lowercases a bounded number of segments per row", function()
		local Writer = require("toml_codec.writer")
		local rows = {}
		for index = 1, 300 do
			rows[index] = { section = "section_" .. index, key = "key", value = true }
		end
		local calls, parents = count_lower_calls(function()
			return Writer.source_inline_scalar_parents(SOURCE, rows)
		end)
		helpers.assert_eq(parents, {})
		-- The pairwise scan made 181 200 calls here; one walk per row makes 3 000.
		helpers.assert_true(calls <= 20 * #rows, "overlap scan is not linear: " .. calls .. " lower calls")
	end)

	helpers.it("still withholds a parent whose rows nest through a case-folded path", function()
		local Writer = require("toml_codec.writer")
		local leaf = { section = "a.child", key = "first", value = true }
		helpers.assert_eq(Writer.source_inline_scalar_parents(SOURCE, { leaf }), { ["a.child"] = true })
		local nested = { section = "A", key = "CHILD", value = { first = true, second = false } }
		helpers.assert_eq(Writer.source_inline_scalar_parents(SOURCE, { leaf, nested }), {})
		helpers.assert_eq(Writer.source_inline_scalar_parents(SOURCE, { nested, leaf }), {})
	end)
end)
