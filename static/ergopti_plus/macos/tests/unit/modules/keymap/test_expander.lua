--- tests/unit/modules/keymap/test_expander.lua

--- ==============================================================================
--- MODULE: keymap.expander Unit Tests
--- DESCRIPTION:
--- Validates the expander's guard pattern (require_state) and early-return
--- logic for the public expansion entry points. We do NOT exercise the full
--- keystroke pipeline — that requires a richer keystroke simulator and live
--- registry / LLM bridge. The focus here is on the deterministic state-machine
--- branches that are exercised on every keystroke.
---
--- COVERAGE:
--- 1. Public surface and require_state guard behavior before init().
--- 2. try_repeat_feature early-returns: feature disabled, wrong char, buffer
---    too short, whitespace-only previous char.
--- 3. perform_text_replacement updates expected_synthetic_chars / deletes and
---    refreshes the buffer via the supplied buffer_action.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Expander = helpers.load_with_stubs("modules.keymap.expander")


--- Builds a minimal CoreState object that satisfies the expander's contract.
--- @return table
local function make_state(buffer)
	local s = {
		buffer                     = buffer or "",
		expected_synthetic_chars   = "",
		expected_synthetic_deletes = 0,
		magic_key                  = "★",
		repeat_enabled             = true,
	}
	function s.is_repeat_feature_enabled() return s.repeat_enabled end
	function s.suppress_rescan(_) end
	return s
end

--- Builds a minimal registry stub: terminators are read from a simple set.
local function make_registry(terminator_set, consumed_set)
	local R = {}
	function R.is_terminator(c) return terminator_set[c] == true end
	function R.terminator_is_consumed(c) return consumed_set[c] == true end
	return R
end

--- Builds a minimal LLM bridge stub that records the calls it receives.
local function make_llm()
	local L = { previews = {}, timer_starts = 0, llm_on = false }
	function L.update_preview(buf) table.insert(L.previews, buf) end
	function L.get_llm_enabled() return L.llm_on end
	function L.start_timer() L.timer_starts = L.timer_starts + 1 end
	return L
end




-- =====================================
--- =====================================
-- ======= 1/ Public API Surface =======
--- =====================================
-- =====================================

helpers.describe("keymap.expander: public surface", function()
	helpers.it("exposes the documented entry points", function()
		helpers.assert_eq(type(Expander.init),                     "function")
		helpers.assert_eq(type(Expander.perform_text_replacement), "function")
		helpers.assert_eq(type(Expander.try_auto_expand),          "function")
		helpers.assert_eq(type(Expander.try_terminator_expand),    "function")
		helpers.assert_eq(type(Expander.try_repeat_feature),       "function")
	end)
end)




-- ===========================================
-- ===========================================
-- ======= 2/ require_state guard ============
-- ===========================================
-- ===========================================

helpers.describe("keymap.expander: require_state guard", function()
	-- Each test reloads the module so _state is freshly nil.
	helpers.it("try_auto_expand returns false when init() not called", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		helpers.assert_eq(E.try_auto_expand({}, 1, false), false)
	end)

	helpers.it("try_terminator_expand returns false when init() not called", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		helpers.assert_eq(E.try_terminator_expand({}, " ", 1, false), false)
	end)

	helpers.it("try_repeat_feature returns false when init() not called", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)
end)




-- ============================================
-- ============================================
-- ======= 3/ init argument validation ========
-- ============================================
-- ============================================

helpers.describe("keymap.expander: init argument validation", function()
	helpers.it("init() is a no-op when core_state is not a table", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		E.init("oops", {}, {})
		-- Subsequent calls must still hit the guard (state never assigned).
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("init() is a no-op when registry_mod is not a table", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		E.init(make_state(), "oops", make_llm())
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("init() is a no-op when llm_mod is not a table", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		E.init(make_state(), make_registry({}, {}), "oops")
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)
end)





-- =================================================
--- ===================================================
--- ======= 4/ try_repeat_feature early-returns =======
--- ===================================================
-- =================================================

helpers.describe("keymap.expander: try_repeat_feature early-returns", function()
	helpers.it("returns false when the repeat feature is disabled", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("ab★"); s.repeat_enabled = false
		E.init(s, make_registry({}, {}), make_llm())
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("returns false when chars is not the magic key", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("ab★")
		E.init(s, make_registry({}, {}), make_llm())
		helpers.assert_eq(E.try_repeat_feature("x", false), false)
	end)

	helpers.it("returns false when buffer is shorter than the magic key", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("★")  -- only the magic key, no preceding char
		E.init(s, make_registry({}, {}), make_llm())
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("returns false when the previous char is whitespace", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state(" ★")  -- space before magic key — repeating space is useless
		E.init(s, make_registry({}, {}), make_llm())
		helpers.assert_eq(E.try_repeat_feature("★", false), false)
	end)

	helpers.it("fires for a normal letter before the magic key", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("ab★")
		E.init(s, make_registry({}, {}), make_llm())
		local result = E.try_repeat_feature("★", false)
		helpers.assert_eq(result, true)
		-- The magic key is stripped and the previous char ("b") is repeated, so
		-- the buffer goes from "ab★" → "ab" + "b" = "abb".
		helpers.assert_eq(s.buffer, "abb")
		helpers.assert_eq(s.expected_synthetic_chars, "b")
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 5/ perform_text_replacement ===========
-- ===============================================
-- ===============================================

helpers.describe("keymap.expander: perform_text_replacement", function()
	helpers.it("issues the requested deletes and runs the buffer_action", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("hello")
		local llm = make_llm()
		E.init(s, make_registry({}, {}), llm)

		local emit_called, buf_called = false, false
		E.perform_text_replacement(
			3,
			function() emit_called = true ; return 4, "wrld" end,
			function() buf_called = true ; s.buffer = "hewrld" end,
			false, false, "test"
		)

		helpers.assert_eq(emit_called, true)
		helpers.assert_eq(buf_called,  true)
		helpers.assert_eq(s.expected_synthetic_deletes, 3)
		helpers.assert_eq(s.expected_synthetic_chars,   "wrld")
		helpers.assert_eq(s.buffer, "hewrld")
		-- update_preview must be called on the rebuilt buffer.
		helpers.assert_eq(llm.previews[#llm.previews], "hewrld")
	end)

	helpers.it("does not arm the LLM timer when LLM is disabled", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("x")
		local llm = make_llm() ; llm.llm_on = false
		E.init(s, make_registry({}, {}), llm)
		E.perform_text_replacement(
			0,
			function() return 0, "" end,
			function() end,
			false, false, "test"
		)
		helpers.assert_eq(llm.timer_starts, 0)
	end)

	helpers.it("arms the LLM timer when LLM is enabled and not ignored", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("x")
		local llm = make_llm() ; llm.llm_on = true
		E.init(s, make_registry({}, {}), llm)
		E.perform_text_replacement(
			0,
			function() return 0, "" end,
			function() end,
			false, false, "test"
		)
		helpers.assert_eq(llm.timer_starts, 1)
	end)

	helpers.it("skips LLM side-effects when is_ignored=true", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("x")
		local llm = make_llm() ; llm.llm_on = true
		E.init(s, make_registry({}, {}), llm)
		E.perform_text_replacement(
			0,
			function() return 0, "" end,
			function() end,
			false, true, "test"
		)
		-- update_preview is gated on is_ignored, and so is start_timer.
		helpers.assert_eq(#llm.previews, 0)
		helpers.assert_eq(llm.timer_starts, 0)
	end)

	helpers.it("survives an emit_action that throws (logs + skips synth chars)", function()
		local E = helpers.load_with_stubs("modules.keymap.expander")
		local s = make_state("x")
		E.init(s, make_registry({}, {}), make_llm())
		E.perform_text_replacement(
			0,
			function() error("boom") end,
			function() end,
			false, false, "test"
		)
		-- emit failed → no synth chars accumulated.
		helpers.assert_eq(s.expected_synthetic_chars, "")
	end)
end)
