--- tests/unit/ai/engine/test_context_edits.lua
--- Regression coverage for bounded, private AI context edit operations.
local helpers = require("tests.helpers")
local Context = require("ai.engine.api.context")

helpers.describe("independent AI context edits", function()
	helpers.it("keeps 800 characters and deletes an entire composed grapheme", function()
		local state = {}
		Context.append(state, string.rep("a", 800) .. "e" .. utf8.char(0x301))
		Context.backspace(state)
		helpers.assert_eq(state.llm_buffer, string.rep("a", 800))
		Context.replace_tail(state, 3, "ok")
		helpers.assert_eq(state.llm_buffer, string.rep("a", 797) .. "ok")
	end)
	helpers.it("does not expose a private replacement after trim and backspace", function()
		local state = {}
		Context.append(state, "prefix secret")
		Context.mark_private(state)
		Context.append(state, string.rep("a", 2050))
		helpers.assert_eq(state.llm_buffer, string.rep("a", 2048))
		Context.backspace(state)
		helpers.assert_eq(state.llm_buffer, string.rep("a", 2047))
		Context.reset(state)
		helpers.assert_eq(state.llm_buffer, "")
	end)
	helpers.it("honors the configured window and never reconstructs evicted text", function()
		local state = {}
		helpers.assert_eq(Context.configure(state, 4000), true)
		Context.append(state, string.rep("x", 3500))
		Context.mark_private(state)
		Context.append(state, "visible")
		local protected_text, protected_mark = state.llm_context_text, state.llm_context_mark
		local generation = state.llm_context_generation
		helpers.assert_eq(Context.configure(state, 4001), false)
		helpers.assert_eq(state.llm_context_generation, generation)
		helpers.assert_eq(state.llm_buffer, "visible")
		Context.configure(state, 800)
		helpers.assert_eq(state.llm_context_text, protected_text, "a tentative setting cannot discard context")
		helpers.assert_eq(state.llm_context_mark, protected_mark, "private boundary is retained")
		Context.configure(state, 4000)
		helpers.assert_eq(state.llm_context_text, protected_text, "rollback retains the preexisting context")
		helpers.assert_eq(state.llm_buffer, "visible")
		Context.configure(state, 0)
		Context.reset(state)
		Context.append(state, string.rep("y", 3000))
		helpers.assert_eq(#state.llm_buffer, 2048, "a reset adopts the smaller rolling limit")
	end)

	helpers.it("advances authority even when a full repeated window stays byte-identical", function()
		local state = {}
		Context.append(state, string.rep("a", 2048))
		local generation = state.llm_context_generation
		Context.append(state, "a")
		helpers.assert_eq(state.llm_buffer, string.rep("a", 2048))
		helpers.assert_true(state.llm_context_generation > generation)
	end)

end)
