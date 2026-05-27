--- tests/unit/modules/llm/test_parser_helpers.lua

--- ==============================================================================
--- MODULE: llm.parser helpers Unit Tests
--- DESCRIPTION:
--- Focused tests for the small, side-effect-free helpers exposed by the parser
--- module: strip_thinking and split_blocks. The full process_prediction path is
--- exercised by tests/unit/modules/llm/test_parser.lua.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Parser = helpers.load_with_stubs("modules.llm.parser")




-- =====================================
-- =====================================
-- ======= 1/ strip_thinking ===========
-- =====================================
-- =====================================

helpers.describe("Parser.strip_thinking", function()
	helpers.it("removes <think>…</think> blocks", function()
		local out = Parser.strip_thinking("hello <think>internal</think> world")
		helpers.assert_true(out:find("internal") == nil)
		helpers.assert_true(out:find("hello") ~= nil)
		helpers.assert_true(out:find("world") ~= nil)
	end)

	helpers.it("removes lone trailing </think>", function()
		local out = Parser.strip_thinking("done </think>final")
		helpers.assert_true(out:find("final") ~= nil)
	end)

	helpers.it("returns empty string for non-string input", function()
		helpers.assert_eq(Parser.strip_thinking(nil), "")
		helpers.assert_eq(Parser.strip_thinking(42), "")
	end)

	helpers.it("returns input unchanged when no thinking tags", function()
		helpers.assert_eq(Parser.strip_thinking("plain output"), "plain output")
	end)

	helpers.it("removes multiple successive thinking blocks", function()
		local out = Parser.strip_thinking("<think>a</think>x<think>b</think>y")
		-- Note the implementation uses non-greedy .-, so multi-block is supported by repeated gsub
		helpers.assert_true(out:find("x") ~= nil)
		helpers.assert_true(out:find("y") ~= nil)
		helpers.assert_true(out:find("a") == nil)
		helpers.assert_true(out:find("b") == nil)
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ split_blocks =============
-- =====================================
-- =====================================

helpers.describe("Parser.split_blocks", function()
	helpers.it("returns single block when no separator is present", function()
		local b = Parser.split_blocks("just one prediction")
		helpers.assert_eq(#b, 1)
		helpers.assert_eq(b[1], "just one prediction")
	end)

	helpers.it("splits on '===' separators", function()
		local b = Parser.split_blocks("alpha\n===\nbeta\n===\ngamma")
		helpers.assert_eq(#b, 3)
		helpers.assert_eq(b[1], "alpha")
		helpers.assert_eq(b[2], "beta")
		helpers.assert_eq(b[3], "gamma")
	end)

	helpers.it("trims leading/trailing whitespace per block", function()
		local b = Parser.split_blocks("  alpha  ===  beta  ")
		helpers.assert_eq(b[1], "alpha")
		helpers.assert_eq(b[2], "beta")
	end)

	helpers.it("drops empty blocks between separators", function()
		local b = Parser.split_blocks("a===   ===b")
		helpers.assert_eq(#b, 2)
		helpers.assert_eq(b[1], "a")
		helpers.assert_eq(b[2], "b")
	end)
end)
