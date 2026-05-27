// static/ergopti_plus/shared/ports/KeyboardHook.spec.js

/**
 * ==============================================================================
 * PORT: KeyboardHook
 * DESCRIPTION:
 * Contract for the OS-level keyboard event subscription port. Every driver
 * adapter that intercepts keyboard input MUST satisfy this interface. The hook
 * operates in a passive "observe" mode — it receives events without consuming
 * them, so the user's keystrokes still reach the foreground application.
 *
 * FEATURES & RATIONALE:
 * 1. Passive observation: the hook never swallows keystrokes by default. A
 *    driver that needs to intercept (e.g., tap-hold) must explicitly request
 *    interception via the `intercept` option at start time.
 * 2. Two event channels: printable characters arrive via `onChar`; special keys
 *    (Backspace, Enter, arrows, Escape, …) arrive via `onKey`. This mirrors
 *    AHK's InputHook OnChar/OnKeyDown split and HS's eventtap key vs. char
 *    distinction.
 * 3. Lifecycle safety: calling `start()` when already running MUST be a no-op
 *    (idempotent). Calling `stop()` before `start()` MUST be a no-op.
 * 4. Context refresh: `refreshContext()` re-reads the foreground application
 *    window handle / bundle ID. Called on window-focus changes.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The KeyboardHook port contract.
 *
 * An adapter object MUST expose every method listed here with the exact
 * parameter count shown. Return types and error behaviors are normative.
 *
 * @type {object}
 */
const portContract = {
	name: "KeyboardHook",
	version: "1.0.0",

	/**
	 * Lifecycle methods.
	 *
	 * start(opts) — Begin intercepting keyboard events.
	 *   @param {object} [opts]
	 *   @param {boolean} [opts.intercept=false]  When true, the hook may consume
	 *          events before they reach the OS (required for tap-hold). When false
	 *          (default), events pass through transparently.
	 *   @param {Function} [opts.onChar]   Called for each printable character.
	 *   @param {Function} [opts.onKey]    Called for each special key event.
	 *   @returns {void}
	 *   @error_behavior "log_and_return" if the OS hook cannot be registered.
	 *
	 * stop() — Remove the keyboard hook.
	 *   @returns {void}
	 *   @error_behavior "ignore" — always safe to call even if not running.
	 *
	 * isRunning() — Query hook state.
	 *   @returns {boolean}
	 *
	 * refreshContext() — Re-read the foreground application identity.
	 *   Called when the active window changes. Adapter stores the result
	 *   internally; domain modules read it via getContext().
	 *   @returns {void}
	 *
	 * getContext() — Return the last-known foreground application identity.
	 *   @returns {{ appId: string, windowTitle: string }}
	 *     appId: bundle ID (macOS) or executable name (Windows)
	 *     windowTitle: window caption string
	 */
	methods: {
		start:          { arity: 1, required: true },
		stop:           { arity: 0, required: true },
		isRunning:      { arity: 0, required: true },
		refreshContext: { arity: 0, required: true },
		getContext:     { arity: 0, required: true },
	},

	/**
	 * Event callback signatures.
	 *
	 * onChar(event) — Fired for each printable character the user types.
	 *   @param {object} event
	 *   @param {string} event.char       The Unicode character (single code-point).
	 *   @param {number} event.timestamp  Unix epoch ms when the key was pressed.
	 *   @param {string} event.appId      Active application identity at event time.
	 *
	 * onKey(event) — Fired for each non-printable key.
	 *   @param {object} event
	 *   @param {string} event.key        Normalized key name (see KEY_NAMES below).
	 *   @param {number} event.timestamp  Unix epoch ms.
	 *   @param {string} event.appId      Active application identity at event time.
	 *   @param {boolean} event.isDown    true = key pressed, false = released.
	 */
	events: {
		onChar: { params: ["event"] },
		onKey:  { params: ["event"] },
	},

	/**
	 * Normalized key names for onKey events.
	 * Adapters MUST map their platform-specific key codes to these names.
	 */
	KEY_NAMES: [
		"Backspace", "Delete", "Enter", "Tab", "Escape",
		"ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
		"Home", "End", "PageUp", "PageDown",
		"F1", "F2", "F3", "F4", "F5", "F6",
		"F7", "F8", "F9", "F10", "F11", "F12",
	],
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks that an adapter object exposes every required method with the correct
 * arity. Returns a list of violation strings (empty = compliant).
 * @param {object} adapter - The adapter instance to validate.
 * @returns {string[]} List of violations. Empty array means compliant.
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
 * Returns test vectors for the KeyboardHook port compliance test suite.
 * Each vector describes a scenario that the adapter's test harness
 * MUST reproduce and assert.
 *
 * These vectors are intentionally platform-agnostic: the test harness
 * injects synthetic events rather than relying on real OS input.
 *
 * @returns {Array<object>} Test vectors.
 */
function contractTestVectors() {
	return [
		{
			id: "lifecycle_start_stop",
			description: "start() makes isRunning() true; stop() makes it false.",
			steps: [
				{ call: "start", args: [{}] },
				{ assert: "isRunning", expected: true },
				{ call: "stop", args: [] },
				{ assert: "isRunning", expected: false },
			],
		},
		{
			id: "start_idempotent",
			description: "Calling start() twice does not throw or duplicate callbacks.",
			steps: [
				{ call: "start", args: [{}] },
				{ call: "start", args: [{}] },   // second call must be no-op
				{ assert: "isRunning", expected: true },
				{ call: "stop", args: [] },
			],
		},
		{
			id: "stop_before_start",
			description: "Calling stop() before start() is a safe no-op.",
			steps: [
				{ call: "stop", args: [] },
				{ assert: "isRunning", expected: false },
			],
		},
		{
			id: "onChar_fires_for_printable",
			description: "Injecting a printable key fires onChar with correct fields.",
			setup: { inject: { type: "char", char: "a" } },
			assert_event: {
				channel: "onChar",
				fields: { char: "a" },
				required_fields: ["char", "timestamp", "appId"],
			},
		},
		{
			id: "onKey_fires_for_backspace",
			description: "Injecting Backspace fires onKey with key='Backspace'.",
			setup: { inject: { type: "key", key: "Backspace" } },
			assert_event: {
				channel: "onKey",
				fields: { key: "Backspace", isDown: true },
				required_fields: ["key", "timestamp", "appId", "isDown"],
			},
		},
		{
			id: "getContext_returns_app_id",
			description: "getContext() returns an object with appId and windowTitle strings.",
			steps: [
				{ call: "refreshContext", args: [] },
				{
					assert_shape: "getContext",
					shape: { appId: "string", windowTitle: "string" },
				},
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
