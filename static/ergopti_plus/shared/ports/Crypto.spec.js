// static/ergopti_plus/shared/ports/Crypto.spec.js

/**
 * ==============================================================================
 * PORT: Crypto
 * DESCRIPTION:
 * Contract for cryptographic digest operations used by driver modules. Adapters
 * implementing this port expose a minimal hashing surface so domain logic can
 * produce deterministic, collision-resistant fingerprints (e.g., SSID privacy
 * hashing) without coupling to platform-specific cryptographic APIs.
 *
 * FEATURES & RATIONALE:
 * 1. Hex output: sha256() always returns a lowercase hexadecimal string of
 *    exactly 64 characters. Callers may safely compare, store, or slice without
 *    further encoding.
 * 2. Deterministic: identical inputs MUST always produce identical outputs
 *    within and across adapter implementations. Non-deterministic adapters are
 *    non-compliant.
 * 3. Error transparency: sha256() MUST NOT throw on valid string input. If the
 *    underlying crypto primitive fails (e.g., COM unavailable), the adapter
 *    returns "" so callers can detect the failure without try/catch boilerplate.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition ==============
// ==================================================
// ==================================================

/**
 * The Crypto port contract.
 * @type {object}
 */
const portContract = {
	name: "Crypto",
	version: "1.0.0",

	/**
	 * sha256(data) — Compute the SHA-256 digest of a UTF-8 string.
	 *   @param {string} data - The input string to hash.
	 *   @returns {string} Lowercase hex digest (64 chars), or "" on failure.
	 *   @error_behavior "return_empty_string".
	 */
	methods: {
		sha256: { arity: 1, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator ==========
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a Crypto adapter.
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
 * Returns test vectors for Crypto compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "sha256_returns_string",
			description: "sha256() always returns a string — never throws.",
			steps: [
				{ call: "sha256", args: ["hello"] },
				{ assert: "return_string" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "sha256_returns_64_hex_chars",
			description: "sha256() returns exactly 64 lowercase hex characters for non-empty input.",
			steps: [
				{ call: "sha256", args: ["hello"] },
				{ assert: "string_length", expected: 64 },
				{ assert: "matches_pattern", pattern: /^[0-9a-f]{64}$/ },
			],
		},
		{
			id: "sha256_is_deterministic",
			description: "sha256() returns the same value for the same input on two calls.",
			steps: [
				{ call: "sha256", args: ["ergopti"] },
				{ store: "first" },
				{ call: "sha256", args: ["ergopti"] },
				{ assert: "equals_stored", key: "first" },
			],
		},
		{
			id: "sha256_empty_string",
			description: "sha256() handles the empty string without throwing.",
			steps: [
				{ call: "sha256", args: [""] },
				{ assert: "return_string" },
				{ assert: "no_exception" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
