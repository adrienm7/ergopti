// static/ergopti_plus/shared/domain/GestureRecognizer.spec.js

/**
 * ==============================================================================
 * DOMAIN: GestureRecognizer
 * DESCRIPTION:
 * Contract and constants for the multi-touch gesture recognition engine.
 * The GestureRecognizer processes raw touch frame data from the OS touchpad
 * driver, computes the gesture centroid and movement vector, applies
 * thresholds to classify the gesture (tap, swipe direction, finger count),
 * and emits a normalized gesture event.
 *
 * FEATURES & RATIONALE:
 * 1. Platform asymmetry: Hammerspoon has access to raw finger data from the
 *    MultitouchSupport framework and performs all centroid/vector math here.
 *    AHK on Windows receives pre-classified shortcuts from the Precision
 *    Touchpad registry (Microsoft fires F1..F10 shortcuts). The shared contract
 *    covers the OUTPUT (gesture events and the gesture slot catalogue) that
 *    both drivers produce; the INPUT processing is necessarily platform-specific.
 * 2. Canonical threshold constants: every threshold used by the HS engine is
 *    exported here so the AHK driver and future Linux drivers can reference
 *    the same numbers.
 * 3. Gesture slot catalogue: the set of gesture identifiers (tap_3,
 *    swipe_3_left, …) is shared. Both drivers map actions to these ids.
 * 4. Axis locking: once a gesture commits to horizontal or vertical axis,
 *    cross-axis noise is ignored. The spec documents this behavior.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Threshold Constants =======
// ==================================================
// ==================================================

/**
 * Canonical gesture detection thresholds.
 * HS adapter MUST use these exact values. AHK adapter receives pre-classified
 * events from Windows so thresholds are not applicable, but MUST export this
 * object for documentary parity.
 */
const THRESHOLDS = {
	/** Maximum duration (seconds) for a contact to be classified as a tap. */
	TAP_MAX_SEC: 0.70,

	/** Maximum Manhattan-distance movement (layout units) for a tap. */
	TAP_MAX_DELTA: 8.0,

	/** Minimum displacement (LU) to classify a 3-, 4-, or 5-finger swipe. */
	SWIPE_MIN: 1.5,

	/** Minimum displacement (LU) for a 2-finger horizontal or vertical swipe. */
	SWIPE_MIN_2: 3.0,

	/** Minimum diagonal displacement (LU) for a 2-finger diagonal swipe. */
	DIAG_MIN_2: 5.0,

	/**
	 * Minimum per-frame displacement (LU) to start axis locking on 2-finger
	 * gestures. Below this value the frame is treated as noise.
	 */
	LIVE_AXIS_MIN: 1.0,
};




// ==================================================
// ==================================================
// ======= 2/ Gesture Slot Catalogue =======
// ==================================================
// ==================================================

/**
 * Complete catalogue of gesture identifiers.
 * An adapter assigns an action to each slot. Slots without an assigned action
 * are no-ops. Both AHK and HS use these ids as the stable key for user config.
 *
 * @typedef {object} GestureSlot
 * @property {string}   id       Stable snake_case identifier.
 * @property {number}   fingers  Finger count (2–5).
 * @property {string}   type     "tap" | "swipe".
 * @property {string|null} direction  "up"|"down"|"left"|"right"|"diag_ul"|
 *           "diag_ur"|"diag_dl"|"diag_dr" for swipes; null for taps.
 */
const GESTURE_SLOTS = [
	// 2-finger gestures
	{ id: "tap_2",            fingers: 2, type: "tap",   direction: null },
	{ id: "swipe_2_up",       fingers: 2, type: "swipe", direction: "up" },
	{ id: "swipe_2_down",     fingers: 2, type: "swipe", direction: "down" },
	{ id: "swipe_2_left",     fingers: 2, type: "swipe", direction: "left" },
	{ id: "swipe_2_right",    fingers: 2, type: "swipe", direction: "right" },
	{ id: "swipe_2_diag_ul",  fingers: 2, type: "swipe", direction: "diag_ul" },
	{ id: "swipe_2_diag_ur",  fingers: 2, type: "swipe", direction: "diag_ur" },
	{ id: "swipe_2_diag_dl",  fingers: 2, type: "swipe", direction: "diag_dl" },
	{ id: "swipe_2_diag_dr",  fingers: 2, type: "swipe", direction: "diag_dr" },
	// 3-finger gestures
	{ id: "tap_3",            fingers: 3, type: "tap",   direction: null },
	{ id: "swipe_3_up",       fingers: 3, type: "swipe", direction: "up" },
	{ id: "swipe_3_down",     fingers: 3, type: "swipe", direction: "down" },
	{ id: "swipe_3_left",     fingers: 3, type: "swipe", direction: "left" },
	{ id: "swipe_3_right",    fingers: 3, type: "swipe", direction: "right" },
	// 4-finger gestures
	{ id: "tap_4",            fingers: 4, type: "tap",   direction: null },
	{ id: "swipe_4_up",       fingers: 4, type: "swipe", direction: "up" },
	{ id: "swipe_4_down",     fingers: 4, type: "swipe", direction: "down" },
	{ id: "swipe_4_left",     fingers: 4, type: "swipe", direction: "left" },
	{ id: "swipe_4_right",    fingers: 4, type: "swipe", direction: "right" },
	// 5-finger gestures
	{ id: "tap_5",            fingers: 5, type: "tap",   direction: null },
	{ id: "swipe_5_up",       fingers: 5, type: "swipe", direction: "up" },
	{ id: "swipe_5_down",     fingers: 5, type: "swipe", direction: "down" },
	{ id: "swipe_5_left",     fingers: 5, type: "swipe", direction: "left" },
	{ id: "swipe_5_right",    fingers: 5, type: "swipe", direction: "right" },
];




// ==================================================
// ==================================================
// ======= 3/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The GestureRecognizer domain contract.
 *
 * NOTE: the AHK adapter satisfies this contract differently from HS:
 *   - HS: processes raw frames via processFrame() → commitGesture() → emits event.
 *   - AHK: Windows fires the gesture event directly; processFrame() is a no-op
 *     stub; commitGesture() is called immediately with the pre-classified slot id.
 * Both adapters MUST expose all methods listed here.
 *
 * @type {object}
 */
const portContract = {
	name: "GestureRecognizer",
	version: "1.0.0",

	/**
	 * processFrame(frame) — Feed a raw touch frame to the recognizer.
	 *   HS: performs centroid and delta computation; may update internal state.
	 *   AHK: no-op stub (Windows handles the math).
	 *   @param {object} frame
	 *   @param {Array<{x:number,y:number}>} frame.fingers  Finger positions (LU).
	 *   @param {number} frame.timestamp  Unix epoch ms.
	 *   @returns {void}
	 *
	 * commitGesture() — Finalize the current gesture and emit an event.
	 *   @returns {GestureEvent|null}  The classified gesture, or null if ambiguous.
	 *
	 * reset() — Discard the in-progress gesture state without emitting.
	 *   @returns {void}
	 *
	 * setActionForSlot(slotId, actionFn) — Register a callback for a slot.
	 *   @param {string}   slotId    Must be an id from GESTURE_SLOTS.
	 *   @param {Function} actionFn  Called with no args when the gesture fires.
	 *   @returns {void}
	 *   @error_behavior "log_and_return" on unknown slotId.
	 *
	 * clearActionForSlot(slotId) — Remove the callback for a slot.
	 *   @param {string} slotId
	 *   @returns {void}
	 */
	methods: {
		processFrame:       { arity: 1, required: true },
		commitGesture:      { arity: 0, required: true },
		reset:              { arity: 0, required: true },
		setActionForSlot:   { arity: 2, required: true },
		clearActionForSlot: { arity: 1, required: true },
	},

	THRESHOLDS,
	GESTURE_SLOTS,
};

/**
 * @typedef {object} GestureEvent
 * @property {string}      slot_id    Matching id from GESTURE_SLOTS.
 * @property {number}      fingers    Finger count.
 * @property {string}      type       "tap" | "swipe".
 * @property {string|null} direction  Direction string or null for taps.
 * @property {number}      timestamp  Unix epoch ms of gesture commit.
 */




// ==================================================
// ==================================================
// ======= 4/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a GestureRecognizer adapter.
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
			violations.push(`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`);
		}
	}
	return violations;
}




// ==================================================
// ==================================================
// ======= 5/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns test vectors for GestureRecognizer compliance.
 * The HS adapter's test harness injects synthetic frame data.
 * The AHK adapter's test harness calls commitGesture() directly with a
 * pre-classified slot id.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id:          "set_and_fire_action",
			description: "setActionForSlot fires the callback when the gesture commits.",
			steps: [
				{ call: "setActionForSlot", args: ["tap_3", "recordFire"] },
				{
					// Inject a 3-finger tap via the platform-specific path
					inject_gesture: { slot_id: "tap_3" },
				},
				{ assert: "fire_count", expected: 1 },
			],
		},
		{
			id:          "clear_action_stops_firing",
			description: "clearActionForSlot prevents the callback from firing.",
			steps: [
				{ call: "setActionForSlot",   args: ["tap_3", "recordFire"] },
				{ call: "clearActionForSlot", args: ["tap_3"] },
				{ inject_gesture: { slot_id: "tap_3" } },
				{ assert: "fire_count", expected: 0 },
			],
		},
		{
			id:          "reset_discards_gesture",
			description: "reset() mid-gesture prevents the action from firing.",
			steps: [
				{ call: "setActionForSlot", args: ["swipe_3_left", "recordFire"] },
				{ inject_partial_gesture: { fingers: 3, direction: "left", partial: true } },
				{ call: "reset", args: [] },
				{ assert: "fire_count", expected: 0 },
			],
		},
		{
			id:          "unknown_slot_is_logged_not_crashed",
			description: "setActionForSlot with an unknown slotId does not throw.",
			steps: [
				{ call: "setActionForSlot", args: ["nonexistent_slot", "recordFire"] },
				{ assert: "no_exception" },
			],
		},
		{
			id:          "all_gesture_slots_are_settable",
			description: "setActionForSlot accepts every id in GESTURE_SLOTS without error.",
			steps: GESTURE_SLOTS.map(slot => ({
				call: "setActionForSlot", args: [slot.id, null],
				assert: "no_exception",
			})),
		},
	];
}


module.exports = {
	THRESHOLDS,
	GESTURE_SLOTS,
	portContract,
	validateAdapter,
	contractTestVectors,
};
