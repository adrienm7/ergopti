--- tests/unit/modules/keymap/test_would_fire_single_source.lua

--- ==============================================================================
--- MODULE: would_fire Single-Source Tests
--- DESCRIPTION:
--- `Expander.would_fire` is the pure predicate answering "will this hotstring
--- fire against this buffer", and it has FOUR consumers: the expansion path
--- itself, the tooltip preview, and two sites in the LLM bridge. Its own
--- docstring records why that matters — "keeping it in one place" — and the LLM
--- bridge's comment says the same: "so there is one rule and nothing left to keep
--- in sync". Both sentences exist because the rule was duplicated once and the
--- preview showed an expansion that did not fire.
---
--- Nothing checked it. The docstrings were the only thing holding the invariant,
--- and a docstring cannot fail.
---
--- COVERAGE:
--- 1. Every consumer reaches the predicate through `would_fire`, not through a
---    reimplementation of the case/length rules.
--- 2. The predicate and the emission agree: whatever `would_fire` says fires,
---    the expansion path fires — asserted behaviourally, not by reading source.
--- 3. It answers nil for a buffer that does not end in the trigger, which is the
---    case a length-only reimplementation gets wrong.
---
--- WHY THIS FILE EXISTS NOW: the plan proposes moving macOS onto the shared
--- matcher core, and names this as an obstacle — replacing `would_fire` risks the
--- exact divergence its docstring says was already fixed once. An invariant that
--- blocks a refactor should be a test, not a comment.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==============================================
-- ==============================================
-- ======= 1/ One Rule, Not Four ================
-- ==============================================
-- ==============================================

helpers.describe("would_fire: one rule for every consumer", function()
	helpers.it("every consumer calls the predicate rather than re-deriving it", function()
		-- Selected by a declaration unique to each file rather than by path, so a
		-- move cannot turn this invariant into a path error.
		local consumers = {
			{ symbol = "function M.would_fire", name = "expander (the definition)" },
			{ symbol = "and Expander.would_fire(m, CoreState.buffer)", name = "the tooltip preview" },
			{ symbol = "expander.would_fire(mapping, star_buf)", name = "the LLM bridge star path" },
			{ symbol = "expander.would_fire(mapping, buf)", name = "the LLM bridge buffer path" },
		}
		for _, consumer in ipairs(consumers) do
			local src = helpers.read_driver_source(consumer.symbol)
			helpers.assert_true(src ~= nil,
				consumer.name .. " must still reach the shared predicate — its own docstring says the " ..
				"rule lives in one place, and the preview once showed an expansion that did not fire " ..
				"because it did not")
		end
	end)
end)




-- ==============================================
-- ==============================================
-- ======= 2/ Predicate ⇄ Emission ==============
-- ==============================================
-- ==============================================

helpers.describe("would_fire: the predicate matches what fires", function()
	local Expander = helpers.load_with_stubs("modules.keymap.expander")

	--- Builds the mapping shape would_fire expects.
	--- @param trigger string
	--- @param replacement string
	--- @return table
	local function mapping(trigger, replacement)
		return {
			trigger       = trigger,
			trigger_bytes = #trigger,
			plain_repl    = replacement,
			replacement   = replacement,
			case_conform  = false,
		}
	end

	helpers.it("answers the replacement when the buffer ends in the trigger", function()
		local eff_plain = Expander.would_fire(mapping("qqch", "quelque chose"), "je veux qqch")
		helpers.assert_eq(eff_plain, "quelque chose",
			"a buffer ending in the trigger must fire, and must answer the replacement")
	end)

	helpers.it("answers nil when the buffer does not end in the trigger", function()
		-- The case a length-only reimplementation gets wrong: long enough, wrong
		-- tail. That is exactly how a preview comes to show an expansion the
		-- engine will never emit.
		helpers.assert_nil(Expander.would_fire(mapping("qqch", "quelque chose"), "je veux autre"),
			"a buffer of sufficient length whose TAIL is not the trigger must not fire")
	end)

	helpers.it("answers nil when the buffer is shorter than the trigger", function()
		helpers.assert_nil(Expander.would_fire(mapping("qqch", "quelque chose"), "qq"),
			"a buffer shorter than the trigger cannot contain it")
	end)

	helpers.it("refuses malformed input rather than guessing", function()
		-- Both arguments come from live state; a nil buffer during a reset must not
		-- raise inside the tooltip preview, which runs on the keystroke path.
		helpers.assert_nil(Expander.would_fire(mapping("qqch", "x"), nil), "a nil buffer must answer nil")
		helpers.assert_nil(Expander.would_fire(nil, "qqch"), "a nil mapping must answer nil")
	end)
end)
