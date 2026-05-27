// static/ergopti_plus/shared/domain/TokenParser.js

/**
 * ==============================================================================
 * DOMAIN: TokenParser — Reference Implementation
 * DESCRIPTION:
 * Canonical pure-JS implementation of the LLM output diff-coloring algorithm.
 * Given the user's typing buffer tail and the LLM's raw prediction, produces
 * an ordered array of colored text chunks for display in the tooltip:
 *
 *   green  = text corrected by the LLM (tail words that changed)
 *   orange = new words invented by the LLM (continuation)
 *   null   = unchanged tail text (passed through as-is)
 *
 * Every driver adapter MUST produce the same output as this reference for any
 * given (tail, rawOutput) pair. Use tokenParserTestVectors() to verify.
 *
 * FEATURES & RATIONALE:
 * 1. Two-tier diffing: first determine which tail words were corrected (green),
 *    then tag all continuation words as new (orange). Unchanged tail words
 *    get no color (gray in the tooltip).
 * 2. Word-level granularity: the diff operates on whitespace-delimited words,
 *    not characters. This matches user expectation ("the whole word changed")
 *    and is fast enough for the tooltip latency budget.
 * 3. French typography: an optional post-processing step applies typographic
 *    apostrophes and non-breaking spaces before punctuation. Disabled by
 *    default; callers opt in via opts.apply_typography = true.
 * 4. Word cap: the output can be capped to max_words words. Callers pass 0
 *    for unlimited.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Color Constants =======
// ==================================================
// ==================================================

/** Hex color for corrected tail words (green). */
const COLOR_CORRECTED = "#22c55e";

/** Hex color for new continuation words (orange). */
const COLOR_NEW_WORDS = "#f97316";

/** Null means "no color" — render in the default gray. */
const COLOR_NONE = null;




// ==================================================
// ==================================================
// ======= 2/ Text Normalization Helpers =======
// ==================================================
// ==================================================

/**
 * Splits a string into an array of whitespace-delimited words.
 * Multiple consecutive spaces collapse to a single split boundary.
 * @param {string} text
 * @returns {string[]}
 */
function splitWords(text) {
	if (!text || text.trim() === "") return [];
	return text.trim().split(/\s+/);
}

/**
 * Applies French typographic conventions to a text string.
 * - Converts straight apostrophes to typographic apostrophes (').
 * - Inserts narrow no-break space (U+202F) before ?, !, ;.
 * - Inserts non-breaking space (U+00A0) before :.
 * @param {string} text
 * @returns {string}
 */
function applyFrenchTypography(text) {
	if (!text) return text;
	// Straight apostrophe → typographic apostrophe
	text = text.replace(/'/g, "’");
	// Space before ?, !, ; → narrow no-break space
	text = text.replace(/ ([?!;])/g, " $1");
	// Space before : → non-breaking space
	text = text.replace(/ :/g, " :");
	// Space after « → non-breaking space
	text = text.replace(/« /g, "« ");
	// Space before » → non-breaking space
	text = text.replace(/ »/g, " »");
	return text;
}

/**
 * Enforces a maximum word count by truncating excess words.
 * @param {string} text
 * @param {number} maxWords  0 = unlimited.
 * @returns {string}
 */
function enforceWordLimit(text, maxWords) {
	if (!maxWords || maxWords <= 0) return text.trimEnd();
	const words = splitWords(text);
	return words.slice(0, maxWords).join(" ");
}




// ==================================================
// ==================================================
// ======= 3/ Diff Coloring Algorithm =======
// ==================================================
// ==================================================

/**
 * Computes the word-level diff between the tail and the LLM's correction,
 * returning the index at which the correction diverges from the tail.
 * Words before the divergence index are identical (no change); words from
 * the divergence index onward in corrected are highlighted green.
 *
 * Uses a greedy prefix-match: finds the longest common prefix of the two
 * word arrays (case-insensitive comparison so "Hello" and "hello" match).
 *
 * @param {string[]} tailWords       The last N words of the user's buffer.
 * @param {string[]} correctedWords  The LLM's corrected tail words.
 * @returns {number} The first index at which the arrays diverge (0 = all changed).
 */
function findDivergenceIndex(tailWords, correctedWords) {
	let i = 0;
	const limit = Math.min(tailWords.length, correctedWords.length);
	while (i < limit && tailWords[i].toLowerCase() === correctedWords[i].toLowerCase()) {
		i++;
	}
	return i;
}

/**
 * Parses the raw LLM output for the "advanced" profile format:
 *   TAIL_CORRECTED: <corrected tail>
 *   NEXT_WORDS: <continuation>
 *
 * Returns { corrected: string|null, next_words: string|null }.
 * Returns { corrected: null, next_words: rawOutput } for any other format
 * (treated as a plain "basic" completion without a corrected tail).
 *
 * @param {string} rawOutput  The full LLM response string.
 * @returns {{ corrected: string|null, next_words: string|null }}
 */
function parseAdvancedFormat(rawOutput) {
	if (!rawOutput) return { corrected: null, next_words: null };
	const correctedMatch = rawOutput.match(/TAIL_CORRECTED:\s*(.+)/);
	const nextMatch      = rawOutput.match(/NEXT_WORDS:\s*(.*)/);
	if (correctedMatch) {
		return {
			corrected:  correctedMatch[1].trim(),
			next_words: nextMatch ? nextMatch[1].trim() : "",
		};
	}
	// Not advanced format — treat entire output as continuation
	return { corrected: null, next_words: rawOutput.trim() };
}


/**
 * Produces an ordered array of { text, color } chunks from the LLM output.
 *
 * The chunk array is suitable for direct rendering by the tooltip:
 *   - Concatenate all chunk.text values to obtain the full display string.
 *   - Apply chunk.color to each chunk (null = default gray).
 *
 * @param {string}   tail        The last N words of the user's buffer (space-separated).
 * @param {string}   rawOutput   The raw LLM response string.
 * @param {object}   [opts]
 * @param {number}   [opts.max_words=0]          Word cap (0 = unlimited).
 * @param {boolean}  [opts.apply_typography=false] Apply French typography.
 * @returns {Array<{ text: string, color: string|null }>}
 */
function parse(tail, rawOutput, opts = {}) {
	const maxWords        = opts.max_words        || 0;
	const applyTypography = opts.apply_typography || false;

	const { corrected, next_words } = parseAdvancedFormat(rawOutput);
	const chunks = [];

	if (corrected !== null) {
		// Advanced format: diff the corrected tail against the original tail
		const tailWords      = splitWords(tail);
		const correctedWords = splitWords(corrected);
		const divIdx         = findDivergenceIndex(tailWords, correctedWords);

		// Unchanged prefix (gray — not added to the chunk array; the UI already
		// shows the unchanged tail in the buffer so we only show the delta)
		const changedWords = correctedWords.slice(divIdx);
		if (changedWords.length > 0) {
			let changedText = changedWords.join(" ");
			if (applyTypography) changedText = applyFrenchTypography(changedText);
			chunks.push({ text: changedText, color: COLOR_CORRECTED });
		}

		// New continuation words (orange)
		if (next_words) {
			let capped = enforceWordLimit(next_words, maxWords);
			if (applyTypography) capped = applyFrenchTypography(capped);
			if (capped) {
				const separator = changedWords.length > 0 ? " " : "";
				chunks.push({ text: separator + capped, color: COLOR_NEW_WORDS });
			}
		}
	} else {
		// Basic / raw format: the entire output is a continuation (orange)
		let output = enforceWordLimit(rawOutput.trim(), maxWords);
		if (applyTypography) output = applyFrenchTypography(output);
		if (output) {
			chunks.push({ text: output, color: COLOR_NEW_WORDS });
		}
	}

	return chunks;
}




// ==================================================
// ==================================================
// ======= 4/ Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns cross-driver test vectors for the TokenParser.
 * Every driver implementation MUST produce matching output for these inputs.
 *
 * Format: { id, tail, rawOutput, opts, expected_chunks }
 * where expected_chunks = Array<{ text: string, color: string|null }>.
 *
 * @returns {Array<object>}
 */
function tokenParserTestVectors() {
	return [
		{
			id:        "basic_format_all_orange",
			description: "Basic completion — entire output is orange new words.",
			tail:      "je suis",
			rawOutput: "content de vous voir",
			opts:      {},
			expected_chunks: [
				{ text: "content de vous voir", color: COLOR_NEW_WORDS },
			],
		},
		{
			id:        "advanced_format_fully_corrected",
			description: "Advanced format where the full tail is corrected (all green).",
			tail:      "je envoit",
			rawOutput: "TAIL_CORRECTED: j'envoie\nNEXT_WORDS: ce mail.",
			opts:      {},
			expected_chunks: [
				{ text: "j'envoie",   color: COLOR_CORRECTED },
				{ text: " ce mail.", color: COLOR_NEW_WORDS },
			],
		},
		{
			id:        "advanced_format_tail_unchanged",
			description: "Advanced format where tail matches exactly — only new words.",
			tail:      "bonjour comment",
			rawOutput: "TAIL_CORRECTED: bonjour comment\nNEXT_WORDS: allez-vous ?",
			opts:      {},
			expected_chunks: [
				{ text: "allez-vous ?", color: COLOR_NEW_WORDS },
			],
		},
		{
			id:        "advanced_format_partial_correction",
			description: "Advanced format: first word unchanged, second corrected.",
			tail:      "bonjour messieu",
			rawOutput: "TAIL_CORRECTED: bonjour messieurs\nNEXT_WORDS: !",
			opts:      {},
			// "bonjour" matches, "messieu" → "messieurs" is green
			expected_chunks: [
				{ text: "messieurs", color: COLOR_CORRECTED },
				{ text: " !",        color: COLOR_NEW_WORDS },
			],
		},
		{
			id:        "word_cap_applied",
			description: "max_words=2 truncates the output to 2 words.",
			tail:      "je",
			rawOutput: "suis très content de vous voir",
			opts:      { max_words: 2 },
			expected_chunks: [
				{ text: "suis très", color: COLOR_NEW_WORDS },
			],
		},
		{
			id:        "empty_output",
			description: "Empty raw output returns an empty chunk array.",
			tail:      "hello",
			rawOutput: "",
			opts:      {},
			expected_chunks: [],
		},
		{
			id:        "advanced_empty_next_words",
			description: "Advanced format with empty NEXT_WORDS — only correction chunk.",
			tail:      "je envoit",
			rawOutput: "TAIL_CORRECTED: j'envoie\nNEXT_WORDS: ",
			opts:      {},
			expected_chunks: [
				{ text: "j'envoie", color: COLOR_CORRECTED },
			],
		},
	];
}


module.exports = {
	COLOR_CORRECTED,
	COLOR_NEW_WORDS,
	COLOR_NONE,
	splitWords,
	applyFrenchTypography,
	enforceWordLimit,
	findDivergenceIndex,
	parseAdvancedFormat,
	parse,
	tokenParserTestVectors,
};
