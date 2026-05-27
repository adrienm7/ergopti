// static/ergopti_plus/shared/ports/TextSender.spec.js

/**
 * ==============================================================================
 * PORT: TextSender
 * DESCRIPTION:
 * Contract for the OS-level text/keystroke injection port. Every driver
 * adapter that sends text to the foreground application MUST satisfy this
 * interface. The port abstracts three distinct send strategies and selects
 * the appropriate one based on payload characteristics.
 *
 * FEATURES & RATIONALE:
 * 1. Three send modes — direct key simulation (fast, synchronous), clipboard
 *    paste (handles large payloads and non-ASCII on every OS), and keystroke
 *    simulation (modifier combos). Callers declare intent; the adapter picks
 *    the strategy.
 * 2. Backspace erasure — before inserting the replacement, the driver typically
 *    erases the trigger characters. The eraseChars() method encapsulates this
 *    so domain code never issues raw Backspace sequences.
 * 3. Async completion callback — clipboard-based sends require OS settle time
 *    (AHK: ~0 ms via direct clipboard write, HS: 80–200 ms for pasteboard
 *    round-trips). Callers always receive a callback-style completion
 *    notification for correctness, even when the adapter is synchronous.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The TextSender port contract.
 * @type {object}
 */
const portContract = {
	name: "TextSender",
	version: "1.0.0",

	/**
	 * send(text, opts, callback) — Insert text at the current insertion point.
	 *   @param {string}   text           The Unicode text to insert.
	 *   @param {object}   [opts]
	 *   @param {string}   [opts.mode]    Strategy hint: "direct"|"clipboard"|"auto".
	 *          "auto" (default): adapter chooses based on payload length.
	 *          Threshold: payloads > CLIPBOARD_THRESHOLD chars use clipboard.
	 *   @param {boolean}  [opts.nested]  True when called from within an active
	 *          expansion (avoids SendMode conflicts on AHK).
	 *   @param {Function} [callback]     Called with no arguments on completion.
	 *          On sync adapters, called inline. On async adapters, deferred.
	 *   @returns {void}
	 *   @error_behavior "log_and_return" on OS injection failure.
	 *
	 * eraseChars(count) — Emit `count` Backspace keystrokes synchronously.
	 *   Used to delete the trigger characters before inserting the replacement.
	 *   @param {number} count  Number of Backspace keystrokes to emit.
	 *   @returns {void}
	 *   @error_behavior "log_and_return" on failure.
	 *
	 * pressKey(key, modifiers) — Emit a single keystroke with optional modifiers.
	 *   @param {string}   key          Key name from KeyboardHook.KEY_NAMES.
	 *   @param {string[]} [modifiers]  Modifier names: "Ctrl"|"Shift"|"Alt"|"Cmd".
	 *   @returns {void}
	 *   @error_behavior "log_and_return" on failure.
	 */
	methods: {
		send:       { arity: 3, required: true },
		eraseChars: { arity: 1, required: true },
		pressKey:   { arity: 2, required: true },
	},

	/**
	 * Payload threshold above which "auto" mode switches to clipboard.
	 * Adapters MUST respect this threshold when mode="auto".
	 */
	CLIPBOARD_THRESHOLD: 1000,
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks that an adapter exposes every required method with the correct arity.
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
// ======= 3/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns test vectors for the TextSender port compliance suite.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "send_short_text_direct",
			description: "Short text (<= threshold) completes synchronously via callback.",
			input: { text: "hello", opts: { mode: "direct" } },
			assert: { callback_called: true, captured_text: "hello" },
		},
		{
			id: "send_long_text_clipboard",
			description: "Text above CLIPBOARD_THRESHOLD uses clipboard mode.",
			input: {
				// 1001 'a' characters — above the 1000-char threshold
				text: "a".repeat(1001),
				opts: { mode: "auto" },
			},
			assert: {
				callback_called: true,
				// Harness asserts clipboard was written with this text
				clipboard_written: true,
			},
		},
		{
			id: "erase_chars",
			description: "eraseChars(3) emits exactly 3 Backspace events.",
			input: { count: 3 },
			assert: { backspace_count: 3 },
		},
		{
			id: "erase_chars_zero",
			description: "eraseChars(0) is a no-op — zero Backspace events.",
			input: { count: 0 },
			assert: { backspace_count: 0 },
		},
		{
			id: "press_key_no_modifiers",
			description: "pressKey('Enter', []) emits a bare Enter keystroke.",
			input: { key: "Enter", modifiers: [] },
			assert: { key_emitted: "Enter", modifiers_emitted: [] },
		},
		{
			id: "press_key_with_modifier",
			description: "pressKey('v', ['Ctrl']) emits Ctrl+V.",
			input: { key: "v", modifiers: ["Ctrl"] },
			assert: { key_emitted: "v", modifiers_emitted: ["Ctrl"] },
		},
		{
			id: "send_nested_mode",
			description: "Nested mode does not crash when called re-entrantly.",
			input: { text: "nested", opts: { nested: true } },
			assert: { callback_called: true },
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
