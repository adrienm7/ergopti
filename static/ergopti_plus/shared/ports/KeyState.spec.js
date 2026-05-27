// static/ergopti_plus/shared/ports/KeyState.spec.js

/**
 * ==============================================================================
 * PORT: KeyState
 * DESCRIPTION:
 * Contract for querying the physical state of keyboard keys so tap-hold logic
 * and modifier-detection routines can check whether a key is currently held
 * without coupling to any OS-specific API (AHK GetKeyState, HS eventtap, etc.).
 *
 * FEATURES & RATIONALE:
 * 1. Physical-only semantics: the port exclusively models physical key state
 *    ("P" mode in AHK parlance). Logical/toggle state (CapsLock LED, NumLock)
 *    is out of scope — use a dedicated ToggleState port for that.
 * 2. Dual helpers: KS_IsDown and KS_IsUp are both required so call sites read
 *    naturally ("if key is up") without forcing callers to negate IsDown.
 * 3. Boolean return: no exceptions, no error objects — callers treat an unknown
 *    key the same as a key that is up (false).
 * ==============================================================================
 */

"use strict";




// ================================================
// ================================================
// ======= 1/ Port Contract Definition ===========
// ================================================
// ================================================

/**
 * The KeyState port contract.
 * @type {object}
 */
const portContract = {
	name: "KeyState",
	version: "1.0.0",

	/**
	 * KS_IsDown(keyName) — Returns true when the key is physically held down.
	 *   @param {string} keyName  Platform key identifier (e.g. "SC038", "LShift").
	 *   @returns {boolean} true if the key is currently down, false otherwise.
	 *   @error_behavior "return_false".
	 *
	 * KS_IsUp(keyName) — Returns true when the key is not physically held down.
	 *   Equivalent to !KS_IsDown(keyName).
	 *   @param {string} keyName  Platform key identifier.
	 *   @returns {boolean} true if the key is currently up, false otherwise.
	 *   @error_behavior "return_true" (absent key = not pressed = up).
	 */
	methods: {
		KS_IsDown: { arity: 1, required: true },
		KS_IsUp:   { arity: 1, required: true },
	},
};




// ================================================
// ================================================
// ======= 2/ Adapter Structural Validator =======
// ================================================
// ================================================

/**
 * Checks structural compliance of a KeyState adapter.
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
 * Returns test vectors for KeyState compliance.
 * Each vector exercises one method and asserts the return-value contract.
 * Vectors assume the adapter under test runs in a context where no keys are
 * physically held (a normal automated test environment).
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "is_down_unknown_key_returns_false",
			description: "KS_IsDown() with an unknown key name returns false.",
			steps: [
				{ call: "KS_IsDown", args: ["ERGOPTI_NONEXISTENT_KEY_XYZ"] },
				{ assert: "return_false" },
			],
		},
		{
			id: "is_up_unknown_key_returns_true",
			description: "KS_IsUp() with an unknown key name returns true (not pressed = up).",
			steps: [
				{ call: "KS_IsUp", args: ["ERGOPTI_NONEXISTENT_KEY_XYZ"] },
				{ assert: "return_true" },
			],
		},
		{
			id: "is_down_is_up_are_inverse",
			description: "KS_IsDown and KS_IsUp return opposite values for the same key.",
			steps: [
				{ call: "KS_IsDown", args: ["LShift"] },
				{ call: "KS_IsUp",   args: ["LShift"] },
				{ assert: "return_inverse_pair" },
			],
		},
		{
			id: "is_down_returns_boolean",
			description: "KS_IsDown() returns a boolean, never throws.",
			steps: [
				{ call: "KS_IsDown", args: ["SC038"] },
				{ assert: "return_type_one_of", expected: ["boolean"] },
			],
		},
		{
			id: "is_up_returns_boolean",
			description: "KS_IsUp() returns a boolean, never throws.",
			steps: [
				{ call: "KS_IsUp", args: ["SC038"] },
				{ assert: "return_type_one_of", expected: ["boolean"] },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
