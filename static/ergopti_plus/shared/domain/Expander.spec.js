// static/ergopti_plus/shared/domain/Expander.spec.js

/**
 * ==============================================================================
 * DOMAIN: Expander
 * DESCRIPTION:
 * Contract for the hotstring expansion decision engine. The Expander receives
 * the current typing buffer and a terminator character, queries the Registry
 * for candidate mappings, selects the best match, and emits an expansion
 * descriptor that the TextSender port executes.
 *
 * FEATURES & RATIONALE:
 * 1. Stateless expansion decision: given (buffer, tailChar, terminatorConsumed),
 *    the Expander returns a plain ExpansionResult object. It does not call any
 *    OS API — that is the TextSender's job.
 * 2. Word-boundary enforcement: mappings with is_word=true only fire when the
 *    character immediately before the trigger is a non-word character (space,
 *    punctuation, start of buffer). The Expander checks this; the Registry
 *    does not.
 * 3. Magic-key cycling: when the user presses the magic key after an expansion,
 *    the Expander selects the next mapping in the star bucket for the same
 *    trigger base. The cycling state is owned by the Expander.
 * 4. Backspace count: the Expander computes how many Backspace keystrokes the
 *    TextSender must emit before inserting the replacement (= trigger length +
 *    1 if the terminator was consumed by the expansion).
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Expansion Result Data Model =======
// ==================================================
// ==================================================

/**
 * Returned by decide() when a match is found.
 *
 * @typedef {object} ExpansionResult
 * @property {string}  replacement      The resolved replacement text to insert.
 * @property {number}  backspace_count  Backspace keystrokes to emit before inserting.
 * @property {boolean} consume_terminator True = the terminator should not be re-typed.
 * @property {boolean} is_final         True = skip further substitution passes.
 * @property {string}  group            Owning group of the matched mapping.
 * @property {string}  trigger          The matched trigger string.
 * @property {string|null} color        Hex accent color for tooltip, or null.
 */




// ==================================================
// ==================================================
// ======= 2/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The Expander domain contract.
 * @type {object}
 */
const portContract = {
	name: "Expander",
	version: "1.0.0",

	/**
	 * decide(buffer, tailChar, opts) — Decide whether to expand.
	 *   @param {string} buffer    The full typing buffer (everything the user typed
	 *          since the last expansion or reset).
	 *   @param {string} tailChar  The character just typed (the terminator or the
	 *          last char of an auto trigger).
	 *   @param {object} [opts]
	 *   @param {boolean} [opts.terminator_consumed=false] True when the terminator
	 *          itself should not be echoed (it belongs to the trigger).
	 *   @returns {ExpansionResult|null} The expansion descriptor, or null if no
	 *          mapping matches.
	 *
	 * cycleNext(buffer) — Advance to the next magic-key mapping for the current base.
	 *   Called when the user presses the magic key after a successful expansion.
	 *   @param {string} buffer  Buffer state at cycle time (used to re-resolve base).
	 *   @returns {ExpansionResult|null} The next cycling expansion, or null if no
	 *          further candidates exist.
	 *
	 * reset() — Clear internal cycling state and any per-keystroke buffers.
	 *   Called on Escape, on window focus change, or when the buffer is cleared.
	 *   @returns {void}
	 */
	methods: {
		decide:    { arity: 3, required: true },
		cycleNext: { arity: 1, required: true },
		reset:     { arity: 0, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 3/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of an Expander adapter.
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
			violations.push(`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`);
		}
	}
	return violations;
}




// ==================================================
// ==================================================
// ======= 4/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns test vectors for Expander compliance.
 * Each vector assumes the registry has been pre-seeded with the given mappings.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id:       "simple_match",
			description: "Buffer ending with trigger + terminator returns correct expansion.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input:    { buffer: "btw", tailChar: " ", opts: {} },
			assert:   {
				not_null:         true,
				replacement:      "by the way",
				backspace_count:  3,   // trigger length = 3; terminator not part of trigger
				consume_terminator: false,
			},
		},
		{
			id: "no_match_returns_null",
			description: "Buffer that does not end with any trigger returns null.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input: { buffer: "xyz", tailChar: " ", opts: {} },
			assert: { is_null: true },
		},
		{
			id: "word_boundary_respected",
			description: "is_word=true trigger does not fire mid-word.",
			registry: [{ trigger: "the", repl: "THE", group: "g", opts: { is_word: true } }],
			// Buffer ends with "othe" — the trigger "the" is present but preceded by "o" (word char)
			input: { buffer: "othe", tailChar: " ", opts: {} },
			assert: { is_null: true },
		},
		{
			id: "word_boundary_fires_after_space",
			description: "is_word=true trigger fires when preceded by a space.",
			registry: [{ trigger: "the", repl: "THE", group: "g", opts: { is_word: true } }],
			input: { buffer: "hello the", tailChar: " ", opts: {} },
			assert: { not_null: true, replacement: "THE" },
		},
		{
			id: "longest_match_wins",
			description: "When two triggers share a tail, the longer one wins.",
			registry: [
				{ trigger: "btw",  repl: "by the way",    group: "g" },
				{ trigger: "btww", repl: "by the way wow", group: "g" },
			],
			input: { buffer: "btww", tailChar: " ", opts: {} },
			assert: { not_null: true, trigger: "btww" },
		},
		{
			id: "backspace_count_with_consumed_terminator",
			description: "consume_terminator=true adds 1 to backspace_count.",
			registry: [{ trigger: "btw", repl: "by the way", group: "g" }],
			input: { buffer: "btw", tailChar: "★", opts: { terminator_consumed: true } },
			assert: {
				not_null:        true,
				backspace_count: 4,   // trigger(3) + terminator(1)
				consume_terminator: true,
			},
		},
		{
			id: "reset_clears_cycle_state",
			description: "reset() after a cycleNext() means decide() starts fresh.",
			registry: [
				{ trigger: "btw★", repl: "by the way",      group: "g", opts: { has_magic: true } },
				{ trigger: "btw★", repl: "between",         group: "g", opts: { has_magic: true } },
			],
			steps: [
				{ call: "decide",    args: ["btw", "★", { terminator_consumed: true }] },
				{ call: "cycleNext", args: ["btw"] },
				{ call: "reset",     args: [] },
				{ call: "decide",    args: ["btw", "★", { terminator_consumed: true }], capture: "r" },
				// After reset, cycling restarts from the first candidate
				{ assert_field: { variable: "r", field: "replacement", value: "by the way" } },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
