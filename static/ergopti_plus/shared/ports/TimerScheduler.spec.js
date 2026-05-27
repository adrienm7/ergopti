// static/ergopti_plus/shared/ports/TimerScheduler.spec.js

/**
 * ==============================================================================
 * PORT: TimerScheduler
 * DESCRIPTION:
 * Contract for the OS-level timer / delayed-action port. Every driver adapter
 * that schedules deferred or repeating callbacks MUST satisfy this interface.
 * The port is a thin, deterministic layer over the platform timer API —
 * AHK's SetTimer and Hammerspoon's hs.timer — so domain modules can be tested
 * against a controllable fake-clock implementation.
 *
 * FEATURES & RATIONALE:
 * 1. Cancellable handles: every scheduled action returns an opaque handle that
 *    can be passed to cancel(). The handle abstraction avoids the AHK pattern
 *    of requiring a named-function reference for cancellation.
 * 2. One-shot vs. repeating: after(delay, fn) fires once; every(interval, fn)
 *    repeats. Both return the same handle shape.
 * 3. Idempotent cancel: cancel(handle) on an already-fired or already-cancelled
 *    handle is a no-op.
 * 4. Fake clock: the port makes no assumption about wall-clock time, enabling
 *    test harnesses to inject a controllable clock implementation.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The TimerScheduler port contract.
 * @type {object}
 */
const portContract = {
	name: "TimerScheduler",
	version: "1.0.0",

	/**
	 * after(delaySec, fn) — Schedule fn to fire once after delaySec seconds.
	 *   @param {number}   delaySec  Delay in seconds (may be fractional, e.g. 0.1).
	 *   @param {Function} fn        Zero-arity callback. Wrapped in a try/catch by
	 *          the adapter; exceptions are logged but never propagated.
	 *   @returns {object} handle    Opaque cancellation token.
	 *   @error_behavior "log_and_return" if the OS timer cannot be armed.
	 *
	 * every(intervalSec, fn) — Schedule fn to fire repeatedly every intervalSec.
	 *   The first firing happens after intervalSec (not immediately).
	 *   @param {number}   intervalSec  Repeat interval in seconds.
	 *   @param {Function} fn           Zero-arity callback.
	 *   @returns {object} handle       Opaque cancellation token.
	 *   @error_behavior "log_and_return" if the OS timer cannot be armed.
	 *
	 * cancel(handle) — Stop a previously scheduled timer.
	 *   @param {object} handle  Token returned by after() or every().
	 *   @returns {void}
	 *   @error_behavior "ignore" — safe to call on a fired or already-cancelled handle.
	 *
	 * cancelAll() — Cancel every timer owned by this scheduler instance.
	 *   Used during module teardown to prevent orphaned timers.
	 *   @returns {void}
	 *   @error_behavior "ignore".
	 */
	methods: {
		after:     { arity: 2, required: true },
		every:     { arity: 2, required: true },
		cancel:    { arity: 1, required: true },
		cancelAll: { arity: 0, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a TimerScheduler adapter.
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
 * Returns test vectors for TimerScheduler compliance.
 * These vectors assume the test harness provides a fake clock with an
 * advanceClock(sec) function that runs all timers due within that window.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "after_fires_once",
			description: "after(0.5, fn) fires fn exactly once after 0.5 s.",
			steps: [
				{ call: "after", args: [0.5, "recordFire"] },
				{ advance_clock_sec: 0.4 },
				{ assert: "fire_count", expected: 0 },
				{ advance_clock_sec: 0.15 },   // total 0.55 s > 0.5 s
				{ assert: "fire_count", expected: 1 },
				{ advance_clock_sec: 1.0 },    // no second firing
				{ assert: "fire_count", expected: 1 },
			],
		},
		{
			id: "after_cancel_before_fire",
			description: "cancel(handle) before the delay prevents fn from firing.",
			steps: [
				{ call: "after", args: [1.0, "recordFire"], capture_handle: true },
				{ advance_clock_sec: 0.5 },
				{ call: "cancel", handle: "captured" },
				{ advance_clock_sec: 1.0 },
				{ assert: "fire_count", expected: 0 },
			],
		},
		{
			id: "cancel_after_fire_is_safe",
			description: "cancel() on an already-fired handle is a no-op.",
			steps: [
				{ call: "after", args: [0.1, "recordFire"], capture_handle: true },
				{ advance_clock_sec: 0.2 },
				{ assert: "fire_count", expected: 1 },
				{ call: "cancel", handle: "captured" },   // must not throw
				{ assert: "fire_count", expected: 1 },
			],
		},
		{
			id: "every_repeats",
			description: "every(0.5, fn) fires fn multiple times at the interval.",
			steps: [
				{ call: "every", args: [0.5, "recordFire"] },
				{ advance_clock_sec: 0.5 },
				{ assert: "fire_count", expected: 1 },
				{ advance_clock_sec: 0.5 },
				{ assert: "fire_count", expected: 2 },
				{ advance_clock_sec: 0.5 },
				{ assert: "fire_count", expected: 3 },
			],
		},
		{
			id: "every_cancel_stops_repeat",
			description: "cancel() stops a repeating timer.",
			steps: [
				{ call: "every", args: [0.5, "recordFire"], capture_handle: true },
				{ advance_clock_sec: 1.0 },   // 2 firings
				{ assert: "fire_count", expected: 2 },
				{ call: "cancel", handle: "captured" },
				{ advance_clock_sec: 1.0 },   // no more firings
				{ assert: "fire_count", expected: 2 },
			],
		},
		{
			id: "cancel_all_stops_all",
			description: "cancelAll() stops all pending timers.",
			steps: [
				{ call: "after", args: [1.0, "recordFire"] },
				{ call: "after", args: [2.0, "recordFire"] },
				{ call: "every", args: [0.5, "recordFire"] },
				{ advance_clock_sec: 0.5 },   // every fires once
				{ assert: "fire_count", expected: 1 },
				{ call: "cancelAll" },
				{ advance_clock_sec: 5.0 },   // nothing else fires
				{ assert: "fire_count", expected: 1 },
			],
		},
		{
			id: "callback_exception_does_not_propagate",
			description: "An exception thrown inside the callback does not crash the scheduler.",
			steps: [
				{ call: "after", args: [0.1, "throwError"] },
				{ advance_clock_sec: 0.2 },
				// If the scheduler is still alive (no uncaught exception), this assertion passes
				{ call: "after", args: [0.1, "recordFire"] },
				{ advance_clock_sec: 0.2 },
				{ assert: "fire_count", expected: 1 },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
