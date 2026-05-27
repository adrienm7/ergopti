// static/ergopti_plus/shared/ports/SecureFieldDetector.spec.js

/**
 * ==============================================================================
 * PORT: SecureFieldDetector
 * DESCRIPTION:
 * Contract for detecting whether the currently focused window or input field is
 * a "secure" context where keylogging and LLM autocomplete must be suppressed.
 * Every driver adapter that performs keystroke capture MUST consult this port
 * before processing any input, and MUST suppress all output (expansion, LLM
 * suggestion, clipboard injection) when either method returns true.
 *
 * FEATURES & RATIONALE:
 * 1. Privacy by default: when detection fails or is uncertain, both methods
 *    return false (not secure) rather than throwing — callers must treat a
 *    return value of false as "detection unavailable, proceed with caution",
 *    not as a guarantee that the field is safe.
 * 2. Two-axis detection: isSecureField() checks the OS-level input type
 *    (password field, PIN pad, system auth prompt), while isSecureApp() checks
 *    the parent process against a configurable allowlist of known sensitive apps
 *    (e.g. 1Password, Keychain Access, banking apps). Both axes are required
 *    because some apps render custom secure fields that the OS does not flag.
 * 3. Explicit refresh(): foreground-app changes do not automatically invalidate
 *    the cached window context on all platforms. Callers MUST invoke refresh()
 *    on every foreground-change event to keep the detector in sync.
 * 4. Minimal surface: three methods only — no event subscription, no callbacks.
 *    The adapter is stateless between refresh() calls.
 * ==============================================================================
 */

"use strict";




// ===========================================
// ===========================================
// ======= 1/ Port Contract Definition =======
// ===========================================
// ===========================================

/**
 * The SecureFieldDetector port contract.
 * @type {object}
 */
const portContract = {
	name: "SecureFieldDetector",
	version: "1.0.0",

	/**
	 * isSecureField() — Return true if the active input field is a secure or
	 *   password-type field as reported by the OS accessibility layer.
	 *   @returns {boolean} true if the focused field is a password/secure type.
	 *   @error_behavior "return_false" — if detection fails, assume not secure.
	 *
	 * isSecureApp(appId) — Return true if the given process name is in the
	 *   configured list of sensitive applications where all input capture must
	 *   be suppressed unconditionally (e.g. "1Password", "Keychain Access").
	 *   @param {string} appId  Process name or bundle identifier of the app.
	 *   @returns {boolean} true if appId is a known secure application.
	 *   @error_behavior "return_false" — unknown or empty appId returns false.
	 *
	 * refresh() — Re-read the current foreground window context so that
	 *   subsequent calls to isSecureField() and isSecureApp() reflect the
	 *   newly focused application. MUST be called by the adapter host on every
	 *   foreground-change event.
	 *   @returns {void}
	 *   @error_behavior "ignore" — failures are silently swallowed; the cached
	 *     context may be stale but must never cause a throw to the caller.
	 */
	methods: {
		isSecureField: { arity: 0, required: true },
		isSecureApp:   { arity: 1, required: true },
		refresh:       { arity: 0, required: true },
	},
};




// ===============================================
// ===============================================
// ======= 2/ Adapter Structural Validator =======
// ===============================================
// ===============================================

/**
 * Checks structural compliance of a SecureFieldDetector adapter.
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




// ==========================================
// ==========================================
// ======= 3/ Compliance Test Vectors =======
// ==========================================
// ==========================================

/**
 * Returns test vectors for SecureFieldDetector compliance.
 * Each vector exercises one method and asserts the return-value contract.
 * Vectors are structural: they verify type contracts and error-path behavior,
 * not platform-specific detection outcomes.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "isSecureField_returns_boolean",
			description: "isSecureField() returns a boolean (true or false), never throws.",
			steps: [
				{ call: "isSecureField", args: [] },
				{ assert: "return_type", expected: "boolean" },
			],
		},
		{
			id: "isSecureApp_unknown_returns_false",
			description: "isSecureApp() returns false for an unrecognised process name.",
			steps: [
				{ call: "isSecureApp", args: ["notanapp.exe"] },
				{ assert: "return_false" },
			],
		},
		{
			id: "isSecureApp_empty_returns_false",
			description: "isSecureApp() returns false for an empty string, never throws.",
			steps: [
				{ call: "isSecureApp", args: [""] },
				{ assert: "return_false" },
			],
		},
		{
			id: "refresh_does_not_throw",
			description: "refresh() completes without throwing regardless of window state.",
			steps: [
				{ call: "refresh", args: [] },
				{ assert: "no_throw" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
