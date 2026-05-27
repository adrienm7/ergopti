// static/ergopti_plus/shared/ports/Notifier.spec.js

/**
 * ==============================================================================
 * PORT: Notifier
 * DESCRIPTION:
 * Contract for the OS-level system notification port. Every driver adapter
 * that displays system-level alerts to the user MUST satisfy this interface.
 * The port abstracts Windows tray balloon (AHK TrayTip) and macOS Notification
 * Center (HS hs.notify) behind a single send() method with a severity level.
 *
 * FEATURES & RATIONALE:
 * 1. Four severity levels: "info", "success", "warning", "error". The adapter
 *    maps each to the nearest native equivalent (icon type on Windows, emoji
 *    prefix + sound on macOS). Callers declare intent, not platform detail.
 * 2. Optional action callback: some platforms (macOS) support clicking the
 *    notification to trigger an action. The adapter calls the optional onClick
 *    callback when the user clicks the notification.
 * 3. Fail-safe: a notification failure MUST NEVER propagate to the caller.
 *    Notifications are optional UX enhancements. If the OS rejects the
 *    notification, log the error and continue.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The Notifier port contract.
 * @type {object}
 */
const portContract = {
	name: "Notifier",
	version: "1.0.0",

	/**
	 * send(message, opts) — Display a system notification.
	 *   @param {string} message           Body text of the notification.
	 *   @param {object} [opts]
	 *   @param {string} [opts.title]      Notification title. Defaults to "Ergopti+".
	 *   @param {string} [opts.level]      Severity: "info"|"success"|"warning"|"error".
	 *          Default: "info".
	 *   @param {Function} [opts.onClick]  Called with no args if the user clicks
	 *          the notification. Ignored on platforms that do not support it.
	 *   @returns {void}
	 *   @error_behavior "log_and_return" — notification failures are non-fatal.
	 */
	methods: {
		send: { arity: 2, required: true },
	},

	/** Valid severity levels. Adapters MUST accept all four. */
	LEVELS: ["info", "success", "warning", "error"],

	/** Default notification title used when opts.title is omitted. */
	DEFAULT_TITLE: "Ergopti+",
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a Notifier adapter.
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
 * Returns test vectors for Notifier compliance.
 * Test harnesses stub the OS notification API and assert what was sent.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "send_info",
			description: "send() with level='info' does not throw.",
			input: { message: "Configuration loaded.", opts: { level: "info" } },
			assert: { no_exception: true, notification_sent: true },
		},
		{
			id: "send_success",
			description: "send() with level='success' does not throw.",
			input: { message: "LLM bridge initialized.", opts: { level: "success" } },
			assert: { no_exception: true, notification_sent: true },
		},
		{
			id: "send_warning",
			description: "send() with level='warning' does not throw.",
			input: { message: "API key not set.", opts: { level: "warning" } },
			assert: { no_exception: true, notification_sent: true },
		},
		{
			id: "send_error",
			description: "send() with level='error' does not throw.",
			input: { message: "Configuration file missing.", opts: { level: "error" } },
			assert: { no_exception: true, notification_sent: true },
		},
		{
			id: "default_title_applied",
			description: "When opts.title is omitted, the adapter uses DEFAULT_TITLE.",
			input: { message: "Hello.", opts: {} },
			assert: { title_sent: "Ergopti+" },
		},
		{
			id: "custom_title_applied",
			description: "opts.title overrides the default title.",
			input: { message: "Ready.", opts: { title: "Mon Titre" } },
			assert: { title_sent: "Mon Titre" },
		},
		{
			id: "os_failure_does_not_propagate",
			description: "If the OS API throws, send() catches it and returns normally.",
			stub: { os_throws: true },
			input: { message: "Test.", opts: { level: "info" } },
			assert: { no_exception: true },
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
