// static/ergopti_plus/shared/domain/HotstringMatcher.spec.js

/**
 * ==============================================================================
 * DOMAIN: HotstringMatcher
 * DESCRIPTION:
 * Contract and reference algorithm for hotstring buffer matching. The matcher
 * receives the current typing buffer and the last typed character, queries the
 * Registry for candidates in the tail-char bucket, and applies word-boundary
 * and case-sensitivity rules to select the longest matching trigger.
 *
 * This spec is the single canonical description of the matching algorithm
 * shared by both the AHK (hotstring_engine.ahk) and Hammerspoon (registry.lua /
 * expander.lua) drivers. Any behavioural divergence between drivers is a bug
 * traceable to this document.
 *
 * FEATURES & RATIONALE:
 * 1. Tail-char bucketing: only mappings whose last codepoint equals the last
 *    typed character are examined. This keeps the hot-path O(bucket_size)
 *    rather than O(total_mappings).
 * 2. Longest-match-first: candidates are sorted by trigger length descending
 *    (Registry contract). The first candidate whose trigger is a suffix of the
 *    buffer is the match. This prevents a short trigger from shadowing a longer
 *    one that subsumes it.
 * 3. Word-boundary enforcement: a mapping with is_word=true may only fire when
 *    the character immediately preceding the trigger in the buffer is a non-word
 *    character (space, tab, punctuation, start-of-buffer). The matcher checks
 *    the buffer character at position (buffer.length - trigger.length - 1).
 * 4. Case sensitivity: by default matching is case-insensitive (buffer and
 *    trigger are lowercased before comparison). When is_case_sensitive=true the
 *    comparison is exact.
 * 5. Magic-key cycling: triggers that end with the magic key character (★) are
 *    stored in a separate star-bucket. The matcher exposes a separate
 *    matchMagic() entry point for this bucket; the cycling state lives in the
 *    Expander, not here.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Match Result Data Model =======
// ==================================================
// ==================================================

/**
 * Returned by match() when a trigger is found in the buffer.
 *
 * @typedef {object} MatchResult
 * @property {string}  trigger            The matched trigger string.
 * @property {string}  replacement        The raw replacement text.
 * @property {number}  backspace_count    Backspace keystrokes before inserting
 *           (= trigger codepoint length + 1 if terminator_consumed).
 * @property {boolean} consume_terminator True = the terminator belongs to the
 *           trigger and must not be re-echoed.
 * @property {boolean} is_final           True = skip further substitution passes.
 * @property {string}  group              Owning group name.
 * @property {string|null} color          Hex accent color, or null.
 */




// ==================================================
// ==================================================
// ======= 2/ Matching Algorithm Pseudocode =======
// ==================================================
// ==================================================

/**
 * Canonical matching algorithm (language-agnostic pseudocode):
 *
 *   function match(buffer, tailChar, registry, opts):
 *     opts.terminator_consumed  = opts.terminator_consumed  ?? false
 *     opts.case_sensitive_check = opts.case_sensitive_check ?? false
 *
 *     candidates = registry.mappingsForTail(tailChar)   // sorted longest-first
 *     if candidates is empty: return null
 *
 *     buf_lower = buffer.toLowerCase()
 *
 *     for each mapping in candidates:
 *       trig = mapping.trigger
 *       tlen = mapping.tlen   // codepoint length
 *
 *       -- 1. Buffer must be at least as long as the trigger
 *       if buffer.codepointLength < tlen: continue
 *
 *       -- 2. Suffix check (case-aware)
 *       buf_tail = buffer.lastCodepoints(tlen)
 *       if mapping.is_case_sensitive:
 *         if buf_tail != trig: continue
 *       else:
 *         if buf_tail.toLowerCase() != trig.toLowerCase(): continue
 *
 *       -- 3. Word-boundary check
 *       if mapping.is_word:
 *         if buffer.codepointLength > tlen:
 *           preceding_char = buffer.codepointAt(buffer.codepointLength - tlen - 1)
 *           if isWordChar(preceding_char): continue
 *         -- start-of-buffer counts as a word boundary: allow match
 *
 *       -- 4. Match found — build result
 *       bc = tlen + (opts.terminator_consumed ? 1 : 0)
 *       return MatchResult {
 *         trigger:            trig,
 *         replacement:        mapping.repl,
 *         backspace_count:    bc,
 *         consume_terminator: opts.terminator_consumed,
 *         is_final:           mapping.final_result,
 *         group:              mapping.group,
 *         color:              mapping.color,
 *       }
 *
 *     return null   -- no candidate matched
 *
 *   function isWordChar(char):
 *     -- A word character is any Unicode letter, digit, or underscore.
 *     -- Spaces, tabs, and punctuation are non-word characters.
 *     return char matches /\w/ (Unicode-aware)
 */




// ==================================================
// ==================================================
// ======= 3/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The HotstringMatcher domain contract.
 * @type {object}
 */
const portContract = {
	name: "HotstringMatcher",
	version: "1.0.0",

	/**
	 * match(buffer, tailChar, registry, opts) — Find the best matching trigger.
	 *   @param {string}  buffer    The full typing buffer.
	 *   @param {string}  tailChar  The last typed character (= tail of buffer).
	 *   @param {object}  registry  A Registry-compliant object (provides mappingsForTail).
	 *   @param {object}  [opts]
	 *   @param {boolean} [opts.terminator_consumed=false]  True when the terminator
	 *          itself is part of the trigger (magic key, auto-fire).
	 *   @returns {MatchResult|null} The best match, or null.
	 *
	 * matchMagic(buffer, magicChar, registry) — Find a match in the star-bucket.
	 *   Used when the user presses the magic key to start or continue a cycle.
	 *   @param {string} buffer     The typing buffer at magic-key press time.
	 *   @param {string} magicChar  The magic key character (e.g. "★").
	 *   @param {object} registry   Registry adapter.
	 *   @returns {MatchResult|null}
	 */
	methods: {
		match:      { arity: 4, required: true },
		matchMagic: { arity: 3, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 4/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a HotstringMatcher adapter.
 * @param {object} adapter
 * @returns {string[]} Violations. Empty = compliant.
 */
function validateAdapter(adapter) {
	const violations = [];
	if (!adapter || typeof adapter !== "object") {
		return ["adapter must be a non-null object"];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== "function") {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(
				`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`
			);
		}
	}
	return violations;
}




// ==================================================
// ==================================================
// ======= 5/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns test vectors for HotstringMatcher compliance.
 * Each vector describes the registry seed, the match() call, and the expected
 * outcome. Driver test suites MUST execute all vectors and assert the result.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "simple_suffix_match",
			description: "Buffer ending with trigger is matched.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input: {
				buffer:  "btw",
				tailChar: "w",
				opts:    {},
			},
			assert: {
				not_null:    true,
				trigger:     "btw",
				replacement: "by the way",
				backspace_count: 3,
				consume_terminator: false,
			},
		},
		{
			id: "no_match_wrong_tail",
			description: "Buffer tail char not in any bucket returns null.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input: {
				buffer:  "xyz",
				tailChar: "z",
				opts:    {},
			},
			assert: { is_null: true },
		},
		{
			id: "no_match_suffix_mismatch",
			description: "Tail char matches bucket but buffer does not end with trigger.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input: {
				buffer:  "xtw",
				tailChar: "w",
				opts:    {},
			},
			assert: { is_null: true },
		},
		{
			id: "longest_trigger_wins",
			description: "When two triggers share the same tail, the longer one is returned.",
			registry: [
				{ trigger: "btw",  repl: "by the way",    group: "g" },
				{ trigger: "btww", repl: "by the way wow", group: "g" },
			],
			input: {
				buffer:  "btww",
				tailChar: "w",
				opts:    {},
			},
			assert: {
				not_null: true,
				trigger:  "btww",
			},
		},
		{
			id: "word_boundary_mid_word_blocked",
			description: "is_word trigger does not fire when preceded by a word character.",
			registry: [{ trigger: "the", repl: "THE", group: "g", is_word: true }],
			input: {
				buffer:  "othe",
				tailChar: "e",
				opts:    {},
			},
			assert: { is_null: true },
		},
		{
			id: "word_boundary_start_of_buffer",
			description: "is_word trigger fires when trigger occupies the entire buffer.",
			registry: [{ trigger: "the", repl: "THE", group: "g", is_word: true }],
			input: {
				buffer:  "the",
				tailChar: "e",
				opts:    {},
			},
			assert: {
				not_null: true,
				trigger:  "the",
			},
		},
		{
			id: "word_boundary_after_space",
			description: "is_word trigger fires when preceded by a space.",
			registry: [{ trigger: "the", repl: "THE", group: "g", is_word: true }],
			input: {
				buffer:  "hello the",
				tailChar: "e",
				opts:    {},
			},
			assert: {
				not_null: true,
				trigger:  "the",
			},
		},
		{
			id: "word_boundary_after_punctuation",
			description: "is_word trigger fires when preceded by punctuation.",
			registry: [{ trigger: "the", repl: "THE", group: "g", is_word: true }],
			input: {
				buffer:  ".the",
				tailChar: "e",
				opts:    {},
			},
			assert: {
				not_null: true,
				trigger:  "the",
			},
		},
		{
			id: "backspace_count_consumed_terminator",
			description: "consume_terminator adds 1 to backspace_count.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input: {
				buffer:  "btw",
				tailChar: "w",
				opts:    { terminator_consumed: true },
			},
			assert: {
				not_null:           true,
				backspace_count:    4,
				consume_terminator: true,
			},
		},
		{
			id: "case_insensitive_default",
			description: "Without is_case_sensitive, uppercase buffer matches lowercase trigger.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input: {
				buffer:  "BTW",
				tailChar: "W",
				opts:    {},
			},
			assert: {
				not_null: true,
				trigger:  "btw",
			},
		},
		{
			id: "case_sensitive_no_match",
			description: "is_case_sensitive trigger does not match different case.",
			registry: [{ trigger: "BTW", repl: "by the way", group: "g", is_case_sensitive: true }],
			input: {
				buffer:  "btw",
				tailChar: "w",
				opts:    {},
			},
			assert: { is_null: true },
		},
		{
			id: "case_sensitive_exact_match",
			description: "is_case_sensitive trigger matches its exact case.",
			registry: [{ trigger: "BTW", repl: "by the way", group: "g", is_case_sensitive: true }],
			input: {
				buffer:  "BTW",
				tailChar: "W",
				opts:    {},
			},
			assert: {
				not_null: true,
				trigger:  "BTW",
			},
		},
		{
			id: "empty_buffer_no_match",
			description: "Empty buffer never produces a match.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input: {
				buffer:  "",
				tailChar: "",
				opts:    {},
			},
			assert: { is_null: true },
		},
		{
			id: "buffer_shorter_than_trigger",
			description: "Buffer shorter than trigger cannot match.",
			registry: [{ trigger: "afaik", repl: "as far as I know", group: "g" }],
			input: {
				buffer:  "fai",
				tailChar: "i",
				opts:    {},
			},
			assert: { is_null: true },
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
