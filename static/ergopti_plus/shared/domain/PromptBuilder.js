// static/ergopti_plus/shared/domain/PromptBuilder.js

/**
 * ==============================================================================
 * DOMAIN: PromptBuilder — Reference Implementation
 * DESCRIPTION:
 * Canonical pure-JS implementation of the LLM request parameter builder.
 * Given the user's buffer and a configuration object, returns all parameters
 * needed to fire an LLM prediction request: context, tail, token budget,
 * and temperature. No OS calls; fully deterministic and unit-testable.
 *
 * FEATURES & RATIONALE:
 * 1. Token budget: derived from max_words using a conservative words-to-tokens
 *    ratio plus a fixed overhead, with a hard floor so very short predictions
 *    still get a meaningful budget.
 * 2. Adaptive temperature: optionally raises temperature per additional
 *    prediction to encourage diversity, then snaps to 0 for single greedy
 *    decoding.
 * 3. Context truncation: limits the forwarded context proportionally to the
 *    predicted output length, cutting LLM prefill tokens and TTFT.
 * 4. Tail extraction: last N words used as a rolling freshness guard and as
 *    the backend's reference window (for advanced profiles).
 *
 * CONSTANTS (canonical — adapters MUST use these exact values):
 *   CONTEXT_TAIL_WORDS      = 5
 *   DEFAULT_MAX_TOKENS      = 150
 *   MIN_MAX_TOKENS          = 15
 *   WORDS_TO_TOKENS_RATIO   = 6
 *   TOKEN_BUDGET_OVERHEAD   = 10
 *   TEMP_DIVERSITY_CAP      = 1.0
 *   TEMP_INCREMENT_PER_PRED = 0.1
 *   GREEDY_TEMP_THRESHOLD   = 0.15
 *   CONTEXT_CHARS_PER_WORD  = 40
 *   CONTEXT_MIN_CHARS       = 100
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Module Constants =======
// ==================================================
// ==================================================

/** Number of words from the buffer tail kept as the rolling context window. */
const CONTEXT_TAIL_WORDS = 5;

/** Token budget when max_words is uncapped (= 0). */
const DEFAULT_MAX_TOKENS = 150;

/** Hard floor on the token budget regardless of word settings. */
const MIN_MAX_TOKENS = 15;

/** Conservative words-to-tokens multiplier for token budget estimation. */
const WORDS_TO_TOKENS_RATIO = 6;

/** Fixed overhead appended to the computed token budget. */
const TOKEN_BUDGET_OVERHEAD = 10;

/** Upper bound when auto_raise_temperature is active. */
const TEMP_DIVERSITY_CAP = 1.0;

/** Temperature step per extra prediction requested beyond 1. */
const TEMP_INCREMENT_PER_PRED = 0.1;

/**
 * Greedy threshold: if num_predictions == 1 and temperature is at or below
 * this value, snap temperature to 0 (pure greedy decoding).
 */
const GREEDY_TEMP_THRESHOLD = 0.15;

/** Chars of context allocated per predicted output word. */
const CONTEXT_CHARS_PER_WORD = 40;

/** Hard floor: always forward at least this many context characters. */
const CONTEXT_MIN_CHARS = 100;




// ==================================================
// ==================================================
// ======= 2/ Internal Helpers =======
// ==================================================
// ==================================================

/**
 * Extracts the last CONTEXT_TAIL_WORDS words from the buffer.
 * Returns both the word array and the concatenated tail string.
 * @param {string} buffer
 * @returns {{ words: string[], tail: string }}
 */
function extractTail(buffer) {
	if (!buffer || buffer.trim() === "") return { words: [], tail: "" };
	const words    = buffer.trim().split(/\s+/);
	const tailStart = Math.max(0, words.length - CONTEXT_TAIL_WORDS);
	const tailWords = words.slice(tailStart);
	return { words, tail: tailWords.join(" ") };
}

/**
 * Computes the token budget from the max_words setting.
 * @param {number} maxWords  0 = uncapped.
 * @returns {number}
 */
function computeMaxTokens(maxWords) {
	if (!maxWords || maxWords <= 0) return DEFAULT_MAX_TOKENS;
	return Math.max(MIN_MAX_TOKENS, maxWords * WORDS_TO_TOKENS_RATIO + TOKEN_BUDGET_OVERHEAD);
}

/**
 * Computes the effective temperature for a given request.
 * @param {number}  baseTemperature  User-configured base temperature.
 * @param {number}  numPredictions   Number of predictions requested (1+).
 * @param {boolean} autoRaise        True = raise temperature for diversity.
 * @returns {number}
 */
function computeTemperature(baseTemperature, numPredictions, autoRaise) {
	let t = baseTemperature;

	if (autoRaise && numPredictions > 1) {
		t = Math.min(
			TEMP_DIVERSITY_CAP,
			t + TEMP_INCREMENT_PER_PRED * (numPredictions - 1)
		);
	}

	// Snap to greedy if single prediction and temperature is effectively zero
	if (numPredictions === 1 && t <= GREEDY_TEMP_THRESHOLD) {
		t = 0;
	}

	return t;
}

/**
 * Truncates the context string to a character limit proportional to max_words.
 * Prevents oversized prefill tokens from driving up TTFT on short predictions.
 * @param {string} buffer
 * @param {number} maxWords  0 = unlimited (returns buffer unchanged).
 * @returns {string}
 */
function capContext(buffer, maxWords) {
	if (!maxWords || maxWords <= 0) return buffer;
	const charLimit = Math.max(CONTEXT_MIN_CHARS, maxWords * CONTEXT_CHARS_PER_WORD);
	if (buffer.length <= charLimit) return buffer;
	return buffer.slice(-charLimit);
}




// ==================================================
// ==================================================
// ======= 3/ Public API =======
// ==================================================
// ==================================================

/**
 * @typedef {object} BuildConfig
 * @property {number}  [max_words=0]           Max prediction words (0 = uncapped).
 * @property {number}  [min_words=1]           Min prediction words.
 * @property {number}  [num_predictions=1]     Number of variants to request.
 * @property {number}  [temperature=0.1]       Base LLM temperature.
 * @property {boolean} [auto_raise_temp=false] Raise temperature for diversity.
 * @property {string}  [language="fr"]         Fallback language hint for the prompt.
 */

/**
 * @typedef {object} BuildResult
 * @property {string} context         Truncated buffer forwarded to the LLM.
 * @property {string} context_tail    Last CONTEXT_TAIL_WORDS words (freshness guard).
 * @property {number} max_tokens      Computed token budget.
 * @property {number} temperature     Effective temperature after diversity adjustment.
 * @property {number} min_words       Min words (passed through from config).
 * @property {number} max_words       Max words (passed through from config).
 * @property {string} language        Language hint (passed through from config).
 * @property {number} num_predictions Number of predictions (passed through).
 */

/**
 * Derives all LLM request parameters from the buffer and configuration.
 * @param {string}      buffer  The current typing buffer.
 * @param {BuildConfig} config
 * @returns {BuildResult}
 */
function buildParams(buffer, config = {}) {
	const maxWords       = config.max_words       || 0;
	const minWords       = config.min_words       || 1;
	const numPredictions = config.num_predictions || 1;
	const temperature    = config.temperature     ?? 0.1;
	const autoRaise      = config.auto_raise_temp || false;
	const language       = config.language        || "fr";

	const { tail } = extractTail(buffer);
	const context  = capContext(buffer, maxWords);

	return {
		context,
		context_tail:    tail,
		max_tokens:      computeMaxTokens(maxWords),
		temperature:     computeTemperature(temperature, numPredictions, autoRaise),
		min_words:       minWords,
		max_words:       maxWords,
		language,
		num_predictions: numPredictions,
	};
}




// ==================================================
// ==================================================
// ======= 4/ Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns cross-driver test vectors for the PromptBuilder.
 * Every driver implementation MUST produce matching output for these inputs.
 * @returns {Array<object>}
 */
function promptBuilderTestVectors() {
	return [
		{
			id:     "default_config",
			description: "Default config: token budget = DEFAULT_MAX_TOKENS, temperature = 0.",
			buffer: "hello world",
			config: { max_words: 0, num_predictions: 1, temperature: 0.1 },
			expected: {
				max_tokens:      DEFAULT_MAX_TOKENS,
				temperature:     0,    // single pred, temp ≤ threshold → greedy
				context_tail:    "hello world",
				min_words:       1,
				num_predictions: 1,
			},
		},
		{
			id:     "token_budget_from_max_words",
			description: "max_words=5: budget = max(15, 5*6+10) = 40.",
			buffer: "some context",
			config: { max_words: 5, num_predictions: 1, temperature: 0.5 },
			expected: {
				max_tokens:  40,
				temperature: 0.5,   // single pred, temp > threshold → no snap
			},
		},
		{
			id:     "min_token_floor",
			description: "max_words=1: budget = max(15, 1*6+10) = max(15,16) = 16.",
			buffer: "context",
			config: { max_words: 1, num_predictions: 1, temperature: 0.1 },
			expected: { max_tokens: 16 },
		},
		{
			id:     "auto_raise_temperature",
			description: "auto_raise_temp with 3 predictions: t = min(1.0, 0.2 + 0.1*2) = 0.4.",
			buffer: "le chat",
			config: { max_words: 3, num_predictions: 3, temperature: 0.2, auto_raise_temp: true },
			expected: { temperature: 0.4 },
		},
		{
			id:     "temperature_diversity_cap",
			description: "auto_raise_temp with high base: capped at TEMP_DIVERSITY_CAP = 1.0.",
			buffer: "le chat",
			config: { max_words: 5, num_predictions: 10, temperature: 0.9, auto_raise_temp: true },
			expected: { temperature: TEMP_DIVERSITY_CAP },
		},
		{
			id:     "context_truncation",
			description: "Long buffer is truncated to max(100, max_words * 40) chars.",
			buffer: "a ".repeat(200),   // 400 chars
			config: { max_words: 2, num_predictions: 1, temperature: 0.1 },
			// char limit = max(100, 2*40) = max(100, 80) = 100
			expected: {
				context_length_max: 100,
			},
		},
		{
			id:     "tail_extraction",
			description: "context_tail contains the last 5 words of the buffer.",
			buffer: "word1 word2 word3 word4 word5 word6 word7",
			config: { max_words: 0, num_predictions: 1, temperature: 0.1 },
			expected: {
				context_tail: "word3 word4 word5 word6 word7",
			},
		},
		{
			id:     "language_passthrough",
			description: "Language from config is passed through unchanged.",
			buffer: "some text",
			config: { language: "en" },
			expected: { language: "en" },
		},
	];
}


module.exports = {
	CONTEXT_TAIL_WORDS,
	DEFAULT_MAX_TOKENS,
	MIN_MAX_TOKENS,
	WORDS_TO_TOKENS_RATIO,
	TOKEN_BUDGET_OVERHEAD,
	TEMP_DIVERSITY_CAP,
	TEMP_INCREMENT_PER_PRED,
	GREEDY_TEMP_THRESHOLD,
	CONTEXT_CHARS_PER_WORD,
	CONTEXT_MIN_CHARS,
	extractTail,
	computeMaxTokens,
	computeTemperature,
	capContext,
	buildParams,
	promptBuilderTestVectors,
};
