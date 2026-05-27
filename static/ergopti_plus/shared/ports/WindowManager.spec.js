// static/ergopti_plus/shared/ports/WindowManager.spec.js

/**
 * ==============================================================================
 * PORT: WindowManager
 * DESCRIPTION:
 * Contract for imperative window management operations. Every driver adapter
 * that activates, inspects, or terminates application windows MUST satisfy this
 * interface. The port abstracts AHK v2's WinActivate / WinExist / WinKill /
 * WinGetList / WinGetTitle built-ins (Windows) and Hammerspoon's hs.window APIs
 * (macOS) behind a unified surface so domain logic never couples to OS-specific
 * windowing primitives.
 *
 * FEATURES & RATIONALE:
 * 1. HWND-or-spec duality: activate(), exists(), kill(), and getTitle() accept
 *    either a raw HWND integer or an AHK WinTitle spec string. Adapters normalise
 *    the input before forwarding to the underlying OS API.
 * 2. Fail-safe returns: every method returns a typed default on any OS error
 *    rather than throwing, so callers do not need try/catch for routine failures
 *    (window already closed, elevation mismatch, etc.).
 * 3. getFocused() shape contract: the returned object always carries the three
 *    fields {hwnd, title, process} as primitive types. Absent values are 0 (hwnd)
 *    or "" (title, process) when the focused window cannot be determined.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition ==============
// ==================================================
// ==================================================

/**
 * The WindowManager port contract.
 * @type {object}
 */
const portContract = {
	name: "WindowManager",
	version: "1.0.0",

	/**
	 * activate(hwndOrSpec) — Bring a window to the foreground and give it focus.
	 *   @param {number|string} hwndOrSpec  HWND integer or AHK WinTitle spec.
	 *   @returns {boolean} true on success, false if the window was not found or
	 *            could not be activated (elevation mismatch, window minimised, etc.).
	 *   @error_behavior "return_false".
	 *
	 * exists(spec) — Check whether at least one window matching spec exists.
	 *   @param {string} spec  AHK WinTitle spec (e.g. "ahk_exe notepad.exe").
	 *   @returns {boolean} true if a matching window exists, false otherwise.
	 *   @error_behavior "return_false".
	 *
	 * kill(spec) — Forcefully terminate all windows matching spec.
	 *   @param {string} spec  AHK WinTitle spec.
	 *   @returns {boolean} true if the kill was issued, false on any error.
	 *   @error_behavior "return_false".
	 *
	 * getList() — Return an array of HWNDs for all currently visible windows.
	 *   @returns {number[]} Array of HWND integers (may be empty).
	 *   @error_behavior "return_empty_array".
	 *
	 * getTitle(hwndOrSpec) — Return the title bar text of a window.
	 *   @param {number|string} hwndOrSpec  HWND integer or AHK WinTitle spec.
	 *   @returns {string} Window title, or "" if the window is not found.
	 *   @error_behavior "return_empty_string".
	 *
	 * getFocused() — Return the identity of the currently focused window.
	 *   @returns {{ hwnd: number, title: string, process: string }}
	 *            Always returns an object; hwnd is 0 and strings are "" when
	 *            the focused window cannot be identified.
	 *   @error_behavior "return_empty_object".
	 */
	methods: {
		activate:   { arity: 1, required: true },
		exists:     { arity: 1, required: true },
		kill:       { arity: 1, required: true },
		getList:    { arity: 0, required: true },
		getTitle:   { arity: 1, required: true },
		getFocused: { arity: 0, required: true },
	},

	/**
	 * getFocused() return shape:
	 * {
	 *   hwnd:    number,  // Window handle integer (0 when unavailable)
	 *   title:   string,  // Window title bar text ("" when unavailable)
	 *   process: string,  // Process name e.g. "notepad.exe" ("" when unavailable)
	 * }
	 */
	FOCUSED_SHAPE: ["hwnd", "title", "process"],
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator ==========
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a WindowManager adapter.
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
 * Returns test vectors for WindowManager compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	const NONEXISTENT_SPEC = "ahk_exe __nonexistent_process_9z3k__.exe";
	return [
		{
			id: "activate_missing_returns_false",
			description: "activate() on a non-existent window returns false, not an exception.",
			steps: [
				{ call: "activate", args: [NONEXISTENT_SPEC] },
				{ assert: "return_false" },
			],
		},
		{
			id: "exists_missing_returns_false",
			description: "exists() returns false for a spec that matches no window.",
			steps: [
				{ call: "exists", args: [NONEXISTENT_SPEC] },
				{ assert: "return_false" },
			],
		},
		{
			id: "kill_missing_returns_false",
			description: "kill() on a non-existent spec returns false without throwing.",
			steps: [
				{ call: "kill", args: [NONEXISTENT_SPEC] },
				{ assert: "return_false" },
			],
		},
		{
			id: "get_list_returns_array",
			description: "getList() always returns an array (possibly empty).",
			steps: [
				{ call: "getList" },
				{ assert: "return_array" },
			],
		},
		{
			id: "get_list_no_exception",
			description: "getList() does not throw in any environment.",
			steps: [
				{ call: "getList" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "get_title_missing_returns_empty_string",
			description: "getTitle() on a non-existent window returns empty string.",
			steps: [
				{ call: "getTitle", args: [NONEXISTENT_SPEC] },
				{ assert: "return_equals", expected: "" },
			],
		},
		{
			id: "get_focused_returns_object",
			description: "getFocused() returns a non-null object with the three required fields.",
			steps: [
				{ call: "getFocused" },
				{
					assert: "return_shape",
					required_fields: portContract.FOCUSED_SHAPE,
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
			id: "get_focused_hwnd_is_number",
			description: "getFocused().hwnd is always a number (0 when unavailable).",
			steps: [
				{ call: "getFocused" },
				{ assert: "field_is_number", field: "hwnd" },
			],
		},
		{
			id: "get_focused_strings_are_strings",
			description: "getFocused() title and process fields are always strings.",
			steps: [
				{ call: "getFocused" },
				{ assert: "all_fields_are_strings", fields: ["title", "process"] },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
