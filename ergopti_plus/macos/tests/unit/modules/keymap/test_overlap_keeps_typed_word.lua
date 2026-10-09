--- tests/unit/modules/keymap/test_overlap_keeps_typed_word.lua

--- ==============================================================================
--- MODULE: Regression — accepting a prediction must not swallow the typed word
---         (overlap-keeps-typed-word)
--- DESCRIPTION:
--- Type "j'aime la". The LLM returns NEXT_WORDS "lavande est magnifique"; the
--- parser yields deletes=0 with a LEADING SPACE, and the tooltip renders it as
--- appended ghost text. Press Tab and the screen becomes
--- "j'aime lavande est magnifique" — the "la" the user typed is gone.
---
--- ROOT CAUSE ENCODED: resolve_prediction_overlap strips the prediction's
--- leading whitespace for matching, discarding the parser's explicit "a new
--- word starts here" signal, and then runs a word-boundary-blind sliding
--- window. That window matches the buffer suffix "la" against the prediction
--- prefix "la", sets deletes=2, and turns an APPEND into a REPLACE. Any
--- prediction whose first word merely extends the last typed one is affected:
--- la→lavande, de→demain, the→theatre.
---
--- WHY IT IS SILENT: nothing fails. The solver logs a trace, apply_prediction
--- logs SUCCESS, and the corrupted sentence reads like a model mistake — so the
--- user blames the LLM rather than reporting a bug. And because
--- tooltip_llm.build_line renders the parser's chunks WITHOUT the solver, what
--- is shown and what is inserted are produced by two different code paths that
--- were never required to agree.
---
--- The space-less dedupe path is deliberately preserved: there the parser made
--- no such declaration, and the overlap genuinely is a mid-word continuation.
--- ==============================================================================

local helpers = require("tests.helpers")

local NBSP = "\194\160"
local NNBSP = "\226\128\175"

local function utils()
	return helpers.load_with_stubs("keymap.utils", {})
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ A leading space means append, never replace ==================
-- =========================================================================
-- =========================================================================

helpers.describe("resolve_prediction_overlap: a declared new word is not converted", function()
	helpers.it("keeps the typed word when the prediction starts with a space", function()
		local u = utils()
		local deletes, to_type =
			u.resolve_prediction_overlap("j'aime la", 0, " lavande est magnifique")

		helpers.assert_eq(deletes, 0,
			"a prediction that starts with a space is the parser declaring a NEW word. Converting "
				.. "it into a mid-word continuation deletes what the user typed: with deletes=2 the "
				.. "screen becomes \"j'aime lavande est magnifique\" and the \"la\" is gone")
		helpers.assert_true(to_type:find("lavande", 1, true) ~= nil,
			"the completion itself must still be typed")
	end)

	helpers.it("the shown text and the inserted text agree", function()
		local u = utils()
		-- What the tooltip renders is the parser's chunk, verbatim. What gets
		-- inserted is whatever the solver returns. They must describe the same
		-- screen, which is the whole guarantee this finding broke.
		local shown = " lavande est magnifique"
		local deletes, to_type = u.resolve_prediction_overlap("j'aime la", 0, shown)

		helpers.assert_eq(deletes, 0, "no deletion may be introduced behind the tooltip's back")
		helpers.assert_eq(to_type, shown,
			"the inserted text must be exactly what was shown. Any divergence here is a sentence "
				.. "the user did not ask for, produced by a path the preview never consulted")
	end)

	helpers.it("the English shape behaves identically", function()
		local u = utils()
		local deletes = u.resolve_prediction_overlap("I like the", 0, " theatre tonight")
		helpers.assert_eq(deletes, 0,
			"the→theatre is the same shape as la→lavande: a first word that merely EXTENDS the "
				.. "last typed one, which is exactly what the blind sliding window mistakes for a "
				.. "continuation")
	end)

	helpers.it("a non-breaking leading space counts as a declaration too", function()
		local u = utils()
		for _, space in ipairs({ NBSP, NNBSP }) do
			local deletes = u.resolve_prediction_overlap("j'aime la", 0, space .. "lavande")
			helpers.assert_eq(deletes, 0,
				"NBSP and NNBSP are the French typographic spaces this driver emits everywhere; "
					.. "treating only U+0020 as a word declaration would leave the bug open for "
					.. "exactly the punctuation this layout is built around")
		end
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ The genuine mid-word dedupe still works ======================
-- =========================================================================
-- =========================================================================

helpers.describe("resolve_prediction_overlap: the space-less dedupe is preserved", function()
	helpers.it("still converts a real mid-word continuation", function()
		local u = utils()
		local deletes, to_type = u.resolve_prediction_overlap("Je tex", 0, "texte")

		helpers.assert_eq(deletes, 3,
			"with NO leading space the parser made no declaration, and the overlap really is a "
				.. "continuation: \"tex\" must be deleted so \"texte\" replaces it rather than "
				.. "producing \"Je textexte\". Disabling this path would trade one corruption for "
				.. "another")
		helpers.assert_eq(to_type, "texte", "and the full word must be typed")
	end)

	helpers.it("an empty prediction is still a no-op", function()
		local u = utils()
		local deletes, to_type = u.resolve_prediction_overlap("anything", 0, "")
		helpers.assert_eq(deletes, 0, "nothing to resolve")
		helpers.assert_eq(to_type, "", "nothing to type")
	end)

	helpers.it("an empty buffer keeps the LLM's own instruction", function()
		local u = utils()
		local deletes, to_type = u.resolve_prediction_overlap("", 2, "bonjour")
		helpers.assert_eq(deletes, 2,
			"with no buffer there is nothing to overlap against, so the parser's own delete count "
				.. "must survive untouched")
		helpers.assert_eq(to_type, "bonjour", "and its text with it")
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 3/ Normalized overlap keeps physical character units ===========
-- =========================================================================
-- =========================================================================

helpers.describe("resolve_prediction_overlap: normalized matches count physical deletions", function()
	local zwsp = "\u{200B}"
	local cases = {
		{
			name = "oe ligature",
			buffer = "je cœ",
			prediction = "coeur ensuite",
			expected_deletes = 2,
			expected_screen = "je coeur ensuite",
		},
		{
			name = "ae ligature",
			buffer = "l'æ",
			prediction = "aether suite",
			expected_deletes = 1,
			expected_screen = "l'aether suite",
		},
		{
			name = "buffer-side zero-width marker",
			buffer = "je c" .. zwsp .. "œ",
			prediction = "coeur ensuite",
			expected_deletes = 3,
			expected_screen = "je coeur ensuite",
		},
		{
			name = "prediction-side zero-width marker",
			buffer = "je cœ",
			prediction = "co" .. zwsp .. "eur ensuite",
			expected_deletes = 2,
			expected_screen = "je coeur ensuite",
		},
		{
			name = "forty normalized character boundary",
			buffer = string.rep("x", 38) .. "œ",
			prediction = string.rep("x", 38) .. "oe suite",
			expected_deletes = 39,
			expected_screen = string.rep("x", 38) .. "oe suite",
		},
	}

	for _, case in ipairs(cases) do
		helpers.it(case.name .. " matches without corrupting the physical delete count", function()
			local u = utils()
			local deletes, to_type =
				u.resolve_prediction_overlap(case.buffer, 0, case.prediction)
			local prefix = require("infra.text_utils").utf8_sub(
				case.buffer, 1, require("infra.text_utils").utf8_len(case.buffer) - deletes)

			helpers.assert_eq(deletes, case.expected_deletes,
				"comparison-only normalization must preserve one Backspace per physical buffer codepoint")
			helpers.assert_eq(prefix .. to_type, case.expected_screen,
				"applying the computed deletion count must preserve the character before the overlap")
		end)
	end
end)
