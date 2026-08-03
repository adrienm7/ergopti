--- tests/unit/modules/keymap/test_noop_expansion_passthrough.lua

--- ==============================================================================
--- MODULE: No-Op Expansion Pass-Through Guard
--- DESCRIPTION:
--- Guards that identity mappings (trigger == plain replacement) signal pass-through
--- so the triggering/terminator character is NOT consumed. Before the fix, the
--- no-op branch returned true, which caused onKeyDownRaw to consume the eventtap
--- event — the character vanished from screen even though nothing was injected.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

local Expander = helpers.load_with_stubs("modules.keymap.expander")


-- Minimal CoreState that satisfies the expander contract.
local function make_state(buffer)
	local s = {
		buffer                     = buffer or "",
		expected_synthetic_chars   = "",
		expected_synthetic_deletes = 0,
		magic_key                  = "\226\152\133",  -- U+2605 (black star)
		start_is_word_boundary     = true,
	}
	function s.is_repeat_feature_enabled() return false end
	function s.suppress_rescan(_) end
	return s
end

-- Minimal Registry stub with tail-bucket lookup.
local function make_registry(entries)
	local R = { _entries = entries or {} }
	function R.is_terminator(c) return c == " " or c == "," end
	function R.terminator_is_consumed(c) return false end
	function R.mappings_for_tail(tail)
		return R._entries[tail] or {}
	end
	return R
end

-- Minimal LLM bridge stub.
local function make_llm()
	local L = { llm_on = false }
	function L.update_preview(_) end
	function L.get_llm_enabled() return L.llm_on end
	function L.start_timer() end
	return L
end


helpers.describe("keymap.expander: no-op identity mapping pass-through", function()

	-- ==================================================================
	-- 1. Auto-expand identity mapping → pass-through (return false)
	-- ==================================================================

	helpers.describe("try_auto_expand identity", function()
		helpers.it("returns false for an auto identity mapping (ok→ok)", function()
			local E = helpers.load_with_stubs("modules.keymap.expander")
			local s = make_state("ok")
			local m = {
				trigger       = "ok",
				trigger_bytes = 2,
				tlen          = 2,
				repl          = "ok",
				plain_repl    = "ok",
				is_word       = false,
				-- auto: the field try_auto_expand gates on. Absent from these hand-built
				-- fixtures for as long as nothing read it — which is what let a non-auto
				-- entry expand mid-word (test_auto_expand_flag_gate.lua).
				auto          = true,
				case_conform  = false,
				final_result  = false,
			}
			local reg = make_registry({ ["k"] = { m } })
			E.init(s, reg, make_llm())

			-- The buffer ends with "ok" which is the trigger. The plain
			-- replacement is also "ok" — an identity mapping. The no-op
			-- branch must return FALSE so the triggering keystroke is
			-- NOT consumed in onKeyDownRaw.
			local result = E.try_auto_expand(m, 1, false)
			helpers.assert_eq(result, false,
				"identity auto mapping must return false (pass-through)")
		end)

		helpers.it("does not emit deletes or chars for an identity mapping", function()
			local E = helpers.load_with_stubs("modules.keymap.expander")
			local s = make_state("ok")
			local m = {
				trigger       = "ok",
				trigger_bytes = 2,
				tlen          = 2,
				repl          = "ok",
				plain_repl    = "ok",
				is_word       = false,
				-- auto: the field try_auto_expand gates on. Absent from these hand-built
				-- fixtures for as long as nothing read it — which is what let a non-auto
				-- entry expand mid-word (test_auto_expand_flag_gate.lua).
				auto          = true,
				case_conform  = false,
				final_result  = false,
			}
			local reg = make_registry({ ["k"] = { m } })
			E.init(s, reg, make_llm())

			local before_chars   = s.expected_synthetic_chars
			local before_deletes = s.expected_synthetic_deletes
			E.try_auto_expand(m, 1, false)
			helpers.assert_eq(s.expected_synthetic_chars, before_chars,
				"no synthetic chars emitted for identity mapping")
			helpers.assert_eq(s.expected_synthetic_deletes, before_deletes,
				"no synthetic deletes emitted for identity mapping")
		end)
	end)

	-- ==================================================================
	-- 2. Terminator identity mapping → pass-through (return false)
	-- ==================================================================

	helpers.describe("try_terminator_expand identity", function()
		helpers.it("returns false for a terminator identity mapping (btw→btw)", function()
			local E = helpers.load_with_stubs("modules.keymap.expander")
			local s = make_state("btw")
			local m = {
				trigger       = "btw",
				trigger_bytes = 3,
				tlen          = 3,
				repl          = "btw",
				plain_repl    = "btw",
				is_word       = false,
				final_result  = false,
			}
			local reg = make_registry({ ["w"] = { m } })
			function reg.is_terminator(c) return c == " " end
			function reg.terminator_is_consumed(c) return true end
			E.init(s, reg, make_llm())

			-- Append the terminator so the buffer is "btw ".
			s.buffer = s.buffer .. " "

			local result = E.try_terminator_expand(m, " ", 1, false)
			helpers.assert_eq(result, false,
				"identity terminator mapping must return false (pass-through)")
		end)
	end)

	-- ==================================================================
	-- 3. Non-identity mappings still return true (expansion fired)
	-- ==================================================================

	helpers.describe("non-identity still fires", function()
		helpers.it("returns true for a real auto expansion (btw→by the way)", function()
			local E = helpers.load_with_stubs("modules.keymap.expander")
			local s = make_state("btw")
			local m = {
				trigger       = "btw",
				trigger_bytes = 3,
				tlen          = 3,
				repl          = "by the way",
				plain_repl    = "by the way",
				is_word       = false,
				-- auto: the field try_auto_expand gates on. Absent from these hand-built
				-- fixtures for as long as nothing read it — which is what let a non-auto
				-- entry expand mid-word (test_auto_expand_flag_gate.lua).
				auto          = true,
				case_conform  = false,
				final_result  = false,
			}
			local reg = make_registry({ ["w"] = { m } })
			E.init(s, reg, make_llm())

			local result = E.try_auto_expand(m, 1, false)
			helpers.assert_eq(result, true,
				"real expansion must still return true (event consumed)")
		end)
	end)

end)
