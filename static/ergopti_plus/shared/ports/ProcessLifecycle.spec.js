// static/ergopti_plus/shared/ports/ProcessLifecycle.spec.js

/**
 * ==============================================================================
 * PORT: ProcessLifecycle
 * DESCRIPTION:
 * Contract for OS process monitoring so domain modules can react to application
 * launches, quits, and focus changes. Every driver adapter that observes running
 * processes MUST satisfy this interface. The port abstracts Hammerspoon's
 * hs.application.watcher and hs.window.filter APIs (macOS) and AHK's
 * WinActive/WinExist polling or COM-based process watchers (Windows) behind a
 * unified surface so domain logic never imports OS-specific window management
 * APIs.
 *
 * FEATURES & RATIONALE:
 * 1. Event-driven: listeners are registered via callbacks, not polling. Adapters
 *    translate OS-level events into the normalized (appId, windowTitle) shape.
 * 2. Idempotent lifecycle: start() and stop() are safe to call multiple times.
 *    Calling stop() before start() must not throw.
 * 3. Fail-safe returns: getForegroundApp() returns an empty-string shape on any
 *    error rather than throwing, so callers can always destructure safely.
 * 4. appId contract: adapters MUST use the application bundle ID (macOS) or the
 *    process executable name without path (Windows) as the appId string.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition ==============
// ==================================================
// ==================================================

/**
 * The ProcessLifecycle port contract.
 * @type {object}
 */
const portContract = {
	name: "ProcessLifecycle",
	version: "1.0.0",

	/**
	 * onFocusChange(callback) — Register a callback for frontmost-app changes.
	 *   The callback receives the new foreground app and its window title.
	 *   @param {function(appId: string, windowTitle: string): void} callback
	 *   @returns {void}
	 *   @error_behavior "ignore" on registration failure.
	 *
	 * onAppLaunch(callback) — Register a callback fired when any app launches.
	 *   @param {function(appId: string): void} callback
	 *   @returns {void}
	 *   @error_behavior "ignore".
	 *
	 * onAppQuit(callback) — Register a callback fired when any app quits.
	 *   @param {function(appId: string): void} callback
	 *   @returns {void}
	 *   @error_behavior "ignore".
	 *
	 * getForegroundApp() — Return the current foreground application.
	 *   @returns {{ appId: string, windowTitle: string }}
	 *            The frontmost app descriptor. Returns {appId: "", windowTitle: ""}
	 *            on any error or when no foreground app is detected.
	 *   @error_behavior "return_empty".
	 *
	 * start() — Begin listening for process events. Idempotent.
	 *   @returns {void}
	 *   @error_behavior "ignore".
	 *
	 * stop() — Stop listening for process events. Idempotent.
	 *   Safe to call before start() has been invoked.
	 *   @returns {void}
	 *   @error_behavior "ignore".
	 */
	methods: {
		onFocusChange:   { arity: 1, required: true },
		onAppLaunch:     { arity: 1, required: true },
		onAppQuit:       { arity: 1, required: true },
		getForegroundApp: { arity: 0, required: true },
		start:           { arity: 0, required: true },
		stop:            { arity: 0, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator ==========
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a ProcessLifecycle adapter.
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
 * Returns test vectors for ProcessLifecycle compliance.
 * Each vector exercises one method and asserts the return-value contract.
 * Vectors that register callbacks only verify that registration does not throw —
 * event delivery depends on OS-level triggers that cannot be synthesized in a
 * structural compliance harness.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "getForegroundApp_returns_shape",
			description: "getForegroundApp() returns an object with appId and windowTitle string fields.",
			steps: [
				{ call: "getForegroundApp", args: [] },
				{ assert: "return_shape", shape: { appId: "string", windowTitle: "string" } },
			],
		},
		{
			id: "start_is_idempotent",
			description: "Calling start() twice does not throw.",
			steps: [
				{ call: "start", args: [] },
				{ call: "start", args: [] },
				{ assert: "no_throw" },
			],
		},
		{
			id: "stop_is_idempotent",
			description: "Calling stop() twice does not throw.",
			steps: [
				{ call: "start", args: [] },
				{ call: "stop",  args: [] },
				{ call: "stop",  args: [] },
				{ assert: "no_throw" },
			],
		},
		{
			id: "stop_before_start_is_safe",
			description: "Calling stop() before start() does not throw.",
			steps: [
				{ call: "stop", args: [] },
				{ assert: "no_throw" },
			],
		},
		{
			id: "onFocusChange_accepts_function",
			description: "Passing a function to onFocusChange() does not throw.",
			steps: [
				{ call: "onFocusChange", args: ["__NOOP_CALLBACK__"] },
				{ assert: "no_throw" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
