// static/ergopti_plus/shared/ports/Clipboard.spec.js

/**
 * ==============================================================================
 * PORT: Clipboard
 * DESCRIPTION:
 * Contract for OS clipboard read/write so domain modules (text expansion, LLM
 * paste) can use the clipboard as a delivery mechanism without importing any
 * OS-specific API. Every driver adapter that injects expanded text via the
 * clipboard MUST satisfy this interface.
 *
 * FEATURES & RATIONALE:
 * 1. Save/restore cycle: text expansion typically overwrites the clipboard to
 *    deliver the expanded string. save() and restore() allow the adapter host
 *    to snapshot the user's clipboard before injection and return it afterwards,
 *    making the operation transparent to the user.
 * 2. Null-safe semantics: read() and save() return null on an empty or non-text
 *    clipboard rather than an empty string, so callers can distinguish "nothing
 *    was there" from "an empty string was there". restore(null) means "clear".
 * 3. Boolean return on write/restore: callers can check for failure without
 *    catching exceptions. A false return MUST be logged by the caller.
 * 4. UTF-8 everywhere: the adapter MUST read and write clipboard content as
 *    UTF-8. Platform default encodings (Windows-1252, etc.) are forbidden.
 * ==============================================================================
 */

"use strict";




// ================================================
// ================================================
// ======= 1/ Port Contract Definition ===========
// ================================================
// ================================================

/**
 * The Clipboard port contract.
 * @type {object}
 */
const portContract = {
	name: "Clipboard",
	version: "1.0.0",

	/**
	 * read() — Read the current clipboard content as a UTF-8 string.
	 *   @returns {string|null} Clipboard text, or null if the clipboard is empty,
	 *     contains non-text data, or an error occurred.
	 *   @error_behavior "return_null".
	 *
	 * write(text) — Write a UTF-8 string to the clipboard, replacing any
	 *   existing content.
	 *   @param {string} text  UTF-8 string to place on the clipboard.
	 *   @returns {boolean} true on success, false on any error.
	 *   @error_behavior "return_false".
	 *
	 * save() — Snapshot the current clipboard content and return it so the
	 *   caller can restore it later. Equivalent to read() but signals intent.
	 *   @returns {string|null} Current clipboard text, or null if the clipboard
	 *     is empty, contains non-text data, or an error occurred.
	 *   @error_behavior "return_null".
	 *
	 * restore(saved) — Restore the clipboard to a previously saved value.
	 *   If saved is null, the clipboard is cleared.
	 *   @param {string|null} saved  Value previously returned by save(), or null.
	 *   @returns {boolean} true on success, false on any error.
	 *   @error_behavior "return_false".
	 */
	methods: {
		read:    { arity: 0, required: true },
		write:   { arity: 1, required: true },
		save:    { arity: 0, required: true },
		restore: { arity: 1, required: true },
	},
};




// ================================================
// ================================================
// ======= 2/ Adapter Structural Validator =======
// ================================================
// ================================================

/**
 * Checks structural compliance of a Clipboard adapter.
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




// ================================================
// ================================================
// ======= 3/ Compliance Test Vectors ============
// ================================================
// ================================================

/**
 * Returns test vectors for Clipboard compliance.
 * Each vector exercises one method and asserts the return-value contract.
 * Vectors assume the adapter under test operates on a writable clipboard
 * in a sandboxed test environment.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "write_returns_true",
			description: "write() with a valid UTF-8 string returns true.",
			steps: [
				{ call: "write", args: ["test"] },
				{ assert: "return_true" },
			],
		},
		{
			id: "read_after_write",
			description: "read() returns the exact content written by write().",
			steps: [
				{ call: "write", args: ["ergopti_clipboard_test_42"] },
				{ call: "read",  args: [] },
				{ assert: "return_equals", expected: "ergopti_clipboard_test_42" },
			],
		},
		{
			id: "save_returns_string_or_null",
			description: "save() returns a string or null, never throws.",
			steps: [
				{ call: "save", args: [] },
				{ assert: "return_type_one_of", expected: ["string", "null"] },
			],
		},
		{
			id: "restore_null_clears",
			description: "restore(null) returns true and does not throw.",
			steps: [
				{ call: "restore", args: [null] },
				{ assert: "return_true" },
			],
		},
		{
			id: "read_empty_returns_null",
			description: "read() returns null when the clipboard is empty.",
			steps: [
				{ call: "restore", args: [null] },
				{ call: "read",    args: [] },
				{ assert: "return_null" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
