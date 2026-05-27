// static/ergopti_plus/shared/ports/WindowInfo.spec.js

/**
 * ==============================================================================
 * PORT: WindowInfo
 * DESCRIPTION:
 * Contract for reading the identity of the currently focused window. Every
 * driver adapter that queries the foreground application MUST satisfy this
 * interface. The port abstracts AHK's WinGetTitle / WinGetProcessName built-ins
 * (Windows) and Hammerspoon's hs.window / hs.application APIs (macOS) behind a
 * unified surface so domain logic never imports OS-specific windowing primitives.
 *
 * FEATURES & RATIONALE:
 * 1. Snapshot semantics: getFocused() returns the state at the moment of the
 *    call. It is the caller's responsibility to call it again when the focus
 *    changes. No subscription mechanism is part of this port (use KeyboardHook
 *    events or a TimerScheduler poll for reactive updates).
 * 2. Best-effort platform mapping: the WindowInfo shape carries four fields
 *    (appId, windowTitle, bundleId, executablePath). Not all fields are
 *    available on every platform — absent fields are empty strings. Callers
 *    MUST NOT assume a non-empty bundleId on Windows, nor a non-empty
 *    executablePath on macOS.
 * 3. Fail-safe return: getFocused() always returns a WindowInfo object, never
 *    null. All fields default to "" when the focused window cannot be identified
 *    (e.g., screen locked, desktop focused, permission denied).
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition ==============
// ==================================================
// ==================================================

/**
 * The WindowInfo port contract.
 * @type {object}
 */
const portContract = {
	name: "WindowInfo",
	version: "1.0.0",

	/**
	 * getFocused() — Return the identity of the currently focused window.
	 *   @returns {WindowInfo} A WindowInfo object (never null). All fields
	 *            default to "" when the focused window cannot be determined.
	 *   @error_behavior "return_empty_object".
	 *
	 * getAll() — Return an array of WindowInfo objects for all visible windows.
	 *   Useful for building a window picker or for debugging context detection.
	 *   @returns {WindowInfo[]} Array of WindowInfo objects (may be empty).
	 *   @error_behavior "return_empty_array".
	 */
	methods: {
		getFocused: { arity: 0, required: true },
		getAll:     { arity: 0, required: true },
	},

	/**
	 * WindowInfo shape (all fields are strings; absent values are ""):
	 * {
	 *   appId:          string,  // Process name e.g. "Code.exe" / "Code"
	 *   windowTitle:    string,  // Window caption e.g. "main.lua — VSCode"
	 *   bundleId:       string,  // macOS bundle ID e.g. "com.microsoft.VSCode" (empty on Windows)
	 *   executablePath: string,  // Full path to the executable (empty on macOS)
	 * }
	 */
	WINDOW_INFO_SHAPE: ["appId", "windowTitle", "bundleId", "executablePath"],
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator ==========
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a WindowInfo adapter.
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
 * Returns test vectors for WindowInfo compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "get_focused_returns_object",
			description: "getFocused() always returns a non-null object with the four required fields.",
			steps: [
				{ call: "getFocused" },
				{
					assert: "return_shape",
					required_fields: portContract.WINDOW_INFO_SHAPE,
					fields_are_strings: true,
				},
			],
		},
		{
			id: "get_focused_no_exception",
			description: "getFocused() does not throw even when no window is focused.",
			steps: [
				{ call: "getFocused" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "get_all_returns_array",
			description: "getAll() returns an array (possibly empty) of WindowInfo objects.",
			steps: [
				{ call: "getAll" },
				{ assert: "return_array" },
			],
		},
		{
			id: "get_all_no_exception",
			description: "getAll() does not throw even in a restricted environment.",
			steps: [
				{ call: "getAll" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "focused_fields_are_strings",
			description: "All fields of the getFocused() result are strings (empty string when unavailable).",
			steps: [
				{ call: "getFocused" },
				{
					assert: "all_fields_are_strings",
					fields: portContract.WINDOW_INFO_SHAPE,
				},
			],
		},
		{
			id: "get_all_items_have_correct_shape",
			description: "Every item in getAll() has the four required string fields.",
			steps: [
				{ call: "getAll" },
				{
					assert: "all_items_match_shape",
					required_fields: portContract.WINDOW_INFO_SHAPE,
					fields_are_strings: true,
				},
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
