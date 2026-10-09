--- tests/unit/modules/keymap/test_would_fire_single_source.lua

--- ==============================================================================
--- MODULE: would_fire Single-Source Tests
--- DESCRIPTION:
--- `Expander.would_fire` is the pure predicate answering "will this hotstring
--- fire against this buffer". The emitters call it directly, while the keyboard
--- magic path and tooltip both enter through `resolve_magic_action`, which calls
--- the same predicate for every candidate. Its own
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
		local consumers = {
			{ symbol = "function M.would_fire", name = "expander (the definition)" },
			{
				symbol = "local resolution = Expander.resolve_magic_action",
				name = "the keyboard engine",
			},
			{
				symbol = "expander.resolve_magic_action(buf, literal_preview_allowed)",
				name = "the tooltip bridge",
			},
		}
		for _, consumer in ipairs(consumers) do
			local src = helpers.read_driver_source(consumer.symbol)
			helpers.assert_true(src ~= nil,
				consumer.name .. " must still reach the shared predicate — its own docstring says the " ..
				"rule lives in one place, and the preview once showed an expansion that did not fire " ..
				"because it did not")
		end

		local src = helpers.read_driver_source("function M.resolve_magic_action")
		helpers.assert_true(src ~= nil, "the shared prospective resolver must be readable")
		helpers.assert_true(src:find("M.would_fire(mapping, auto_buffer)", 1, true) ~= nil,
			"star candidates must reach the shared match predicate")
		helpers.assert_true(src:find(
			"resolve_terminator_match(mapping, end_buffer, physical_magic, true)", 1, true) ~= nil,
			"end-character candidates must reach the emitter's shared terminator predicate")
	end)

	helpers.it("and the predicate itself defers to the CROSS-DRIVER rule", function()
		-- The layer above this one. would_fire being macOS's single source stopped
		-- the preview disagreeing with the engine; it did nothing about macOS
		-- disagreeing with Windows and Linux, which it did — on the word boundary,
		-- in two separate ways, for as long as each driver owned its own copy.
		-- would_fire now slices (its byte-string buffer's business) and hands the two
		-- resulting strings to HotstringCore.decide, which the Linux engine calls too.
		local src = helpers.read_driver_source("function M.would_fire")
		helpers.assert_true(src ~= nil, "the expander source must be readable")
		helpers.assert_true(src:find("HotstringCore.decide(", 1, true) ~= nil,
			"would_fire must call HotstringCore.decide. Re-deriving the case resolution, the "
			.. "word boundary or the no-op guard here rebuilds the divergence: three engines "
			.. "answering 'does this fire?' three ways is what shipped a hotstring that "
			.. "expanded on one driver and was refused on the other two")
	end)

	helpers.it("and it does not keep a private copy of the rules it delegated", function()
		local src = helpers.read_driver_source("function M.would_fire")
		if not src then return end
		-- The window is would_fire's own body. A rule reappearing anywhere else in
		-- the expander is a different question; a rule reappearing HERE means the
		-- delegation was undone in place, which is the regression this names.
		local at = src:find("function M.would_fire", 1, true)
		local body = src:sub(at, at + 1400)
		for _, forbidden in ipairs({ "conform_replacement", "trigger_folded", "is_hotstring_word_char" }) do
			helpers.assert_true(body:find(forbidden, 1, true) == nil,
				"would_fire must not reach for '" .. forbidden .. "' itself — that is a rule it "
				.. "hands to the shared predicate, and holding both is how the two drift apart")
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
			match_mode    = "exact",
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
