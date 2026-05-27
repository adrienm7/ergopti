// static/ergopti_plus/shared/ports/Storage.spec.js

/**
 * ==============================================================================
 * PORT: Storage
 * DESCRIPTION:
 * Contract for persistent key-value and structured storage used by domain
 * modules. Every driver adapter that needs durable storage MUST satisfy this
 * interface. The port abstracts SQLite on Hammerspoon/Linux and JSON-file
 * storage on AHK behind a unified surface so domain logic (keylogger SQLite,
 * app categories, config) never imports OS-specific storage APIs.
 *
 * FEATURES & RATIONALE:
 * 1. Minimal surface: only the six operations domain modules actually need —
 *    set, get, delete, has, keys, and clear. No transactions, no indexes.
 * 2. Synchronous contract: all operations block and return immediately. Async
 *    wrappers are the caller's responsibility if non-blocking I/O is required.
 * 3. Fail-safe returns: every method returns a safe default on error rather
 *    than throwing, so callers need only check the return value.
 * 4. Value types: values MUST round-trip as string, number, boolean, or plain
 *    object. Adapters are free to JSON-serialize internally.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition ==============
// ==================================================
// ==================================================

/**
 * The Storage port contract.
 * @type {object}
 */
const portContract = {
	name: "Storage",
	version: "1.0.0",

	/**
	 * set(key, value) — Store a value under the given key.
	 *   @param {string} key    Storage key.
	 *   @param {*}      value  Value to store (string/number/boolean/object).
	 *   @returns {boolean} true on success, false on any error.
	 *   @error_behavior "return_false".
	 *
	 * get(key, defaultValue) — Retrieve a stored value, or defaultValue if absent.
	 *   @param {string} key           Storage key to look up.
	 *   @param {*}      defaultValue  Value to return when key is not found.
	 *   @returns {*} The stored value, or defaultValue.
	 *   @error_behavior "return_default".
	 *
	 * delete(key) — Remove a key from the store.
	 *   Returns true even when the key was already absent.
	 *   @param {string} key  Storage key to remove.
	 *   @returns {boolean} true on success (including key-not-found), false on error.
	 *   @error_behavior "return_false".
	 *
	 * has(key) — Check whether a key exists in the store.
	 *   @param {string} key  Storage key to test.
	 *   @returns {boolean} true if the key exists, false otherwise.
	 *   @error_behavior "return_false".
	 *
	 * keys() — Return all currently stored keys.
	 *   @returns {string[]} Array of key strings. Empty array on error.
	 *   @error_behavior "return_empty_array".
	 *
	 * clear() — Remove all entries from the store.
	 *   @returns {boolean} true on success, false on any error.
	 *   @error_behavior "return_false".
	 */
	methods: {
		set:    { arity: 2, required: true },
		get:    { arity: 2, required: true },
		delete: { arity: 1, required: true },
		has:    { arity: 1, required: true },
		keys:   { arity: 0, required: true },
		clear:  { arity: 0, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator ==========
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a Storage adapter.
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
// ======= 3/ Compliance Test Vectors ===============
// ==================================================
// ==================================================

/**
 * Returns test vectors for Storage compliance.
 * Each vector exercises one method and asserts the return-value contract.
 * Vectors use the sentinel key "__ST_TEST_KEY__" — adapters under test
 * should use an isolated namespace to avoid colliding with real data.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	const TEST_KEY = "__ST_TEST_KEY__";
	const MISSING_KEY = "never_set_9z3k";
	return [
		{
			id: "set_returns_true",
			description: "set() returns true on a simple string value.",
			steps: [
				{ call: "set", args: [TEST_KEY, "v"] },
				{ assert: "return_true" },
			],
		},
		{
			id: "get_after_set",
			description: "get() returns the value previously stored by set().",
			steps: [
				{ call: "set", args: [TEST_KEY, "v"] },
				{ call: "get", args: [TEST_KEY, null] },
				{ assert: "return_equals", expected: "v" },
			],
		},
		{
			id: "get_missing_returns_default",
			description: "get() returns the supplied defaultValue when the key is absent.",
			steps: [
				{ call: "get", args: [MISSING_KEY, "fallback"] },
				{ assert: "return_equals", expected: "fallback" },
			],
		},
		{
			id: "has_true_after_set",
			description: "has() returns true for a key that was just set.",
			steps: [
				{ call: "set", args: [TEST_KEY, "x"] },
				{ call: "has", args: [TEST_KEY] },
				{ assert: "return_true" },
			],
		},
		{
			id: "has_false_for_missing",
			description: "has() returns false for a key that was never stored.",
			steps: [
				{ call: "has", args: [MISSING_KEY] },
				{ assert: "return_false" },
			],
		},
		{
			id: "delete_removes_key",
			description: "has() returns false for a key that was deleted.",
			steps: [
				{ call: "set",    args: [TEST_KEY, "to_delete"] },
				{ call: "delete", args: [TEST_KEY] },
				{ call: "has",    args: [TEST_KEY] },
				{ assert: "return_false" },
			],
		},
		{
			id: "keys_returns_array",
			description: "keys() returns an array (possibly empty).",
			steps: [
				{ call: "keys", args: [] },
				{ assert: "return_type", expected: "array" },
			],
		},
		{
			id: "clear_empties_store",
			description: "has() returns false for a key that existed before clear().",
			steps: [
				{ call: "set",   args: [TEST_KEY, "v"] },
				{ call: "clear", args: [] },
				{ call: "has",   args: [TEST_KEY] },
				{ assert: "return_false" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
