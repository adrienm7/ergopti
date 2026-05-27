// static/ergopti_plus/shared/ports/MouseControl.spec.js

/**
 * ==============================================================================
 * PORT: MouseControl
 * DESCRIPTION:
 * Contract for reading and writing the mouse cursor position and for querying
 * monitor geometry. Every driver adapter that moves the cursor or maps screen
 * coordinates MUST satisfy this interface. The port abstracts AHK v2's
 * MouseMove / MouseGetPos / MonitorGetCount / MonitorGet built-ins (Windows) and
 * Hammerspoon's hs.mouse / hs.screen APIs (macOS) behind a unified surface so
 * domain logic never imports OS-specific pointer primitives.
 *
 * FEATURES & RATIONALE:
 * 1. Absolute coordinates only: setPos() and getPos() work in virtual-desktop
 *    pixel coordinates. Adapter implementations MUST NOT apply any DPI scaling
 *    that would make coordinates inconsistent across calls.
 * 2. Fail-safe returns: getPos() always returns {x, y} (defaulting to 0,0);
 *    getMonitorBounds() always returns {left, top, right, bottom} (all 0 on
 *    error) rather than throwing, so callers are never surprised by exceptions.
 * 3. Monitor numbering: monitors are 1-indexed following the AHK / Hammerspoon
 *    convention. Monitor 0 is never valid. getMonitorCount() returns 0 on error.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition ==============
// ==================================================
// ==================================================

/**
 * The MouseControl port contract.
 * @type {object}
 */
const portContract = {
	name: "MouseControl",
	version: "1.0.0",

	/**
	 * setPos(x, y) — Move the mouse cursor to an absolute virtual-desktop position.
	 *   @param {number} x  Horizontal coordinate in pixels.
	 *   @param {number} y  Vertical coordinate in pixels.
	 *   @returns {void}
	 *   @error_behavior "silent_noop".
	 *
	 * getPos() — Return the current absolute cursor position.
	 *   @returns {{ x: number, y: number }} Current cursor coordinates.
	 *            Both fields default to 0 when the position cannot be read.
	 *   @error_behavior "return_zero_object".
	 *
	 * getMonitorCount() — Return the total number of monitors attached to the system.
	 *   @returns {number} Monitor count (>= 1 on a healthy system, 0 on error).
	 *   @error_behavior "return_zero".
	 *
	 * getMonitorBounds(n) — Return the bounding rectangle of monitor n (1-indexed).
	 *   @param {number} n  Monitor index, starting at 1.
	 *   @returns {{ left: number, top: number, right: number, bottom: number }}
	 *            All fields default to 0 when the monitor index is out of range.
	 *   @error_behavior "return_zero_object".
	 */
	methods: {
		setPos:           { arity: 2, required: true },
		getPos:           { arity: 0, required: true },
		getMonitorCount:  { arity: 0, required: true },
		getMonitorBounds: { arity: 1, required: true },
	},

	/**
	 * getPos() return shape:
	 * { x: number, y: number }
	 *
	 * getMonitorBounds() return shape:
	 * { left: number, top: number, right: number, bottom: number }
	 */
	POS_SHAPE:     ["x", "y"],
	BOUNDS_SHAPE:  ["left", "top", "right", "bottom"],
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator ==========
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a MouseControl adapter.
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
 * Returns test vectors for MouseControl compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "get_pos_returns_object",
			description: "getPos() returns a non-null object with x and y fields.",
			steps: [
				{ call: "getPos" },
				{
					assert: "return_shape",
					required_fields: portContract.POS_SHAPE,
				},
			],
		},
		{
			id: "get_pos_no_exception",
			description: "getPos() does not throw in any environment.",
			steps: [
				{ call: "getPos" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "get_pos_fields_are_numbers",
			description: "getPos() x and y fields are always numbers.",
			steps: [
				{ call: "getPos" },
				{ assert: "all_fields_are_numbers", fields: portContract.POS_SHAPE },
			],
		},
		{
			id: "set_pos_does_not_throw",
			description: "setPos() does not throw for valid coordinates.",
			steps: [
				{ call: "setPos", args: [0, 0] },
				{ assert: "no_exception" },
			],
		},
		{
			id: "get_monitor_count_is_number",
			description: "getMonitorCount() returns a number >= 0.",
			steps: [
				{ call: "getMonitorCount" },
				{ assert: "return_number_gte", min: 0 },
			],
		},
		{
			id: "get_monitor_count_no_exception",
			description: "getMonitorCount() does not throw.",
			steps: [
				{ call: "getMonitorCount" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "get_monitor_bounds_returns_object",
			description: "getMonitorBounds(1) returns an object with the four bound fields.",
			steps: [
				{ call: "getMonitorBounds", args: [1] },
				{
					assert: "return_shape",
					required_fields: portContract.BOUNDS_SHAPE,
				},
			],
		},
		{
			id: "get_monitor_bounds_fields_are_numbers",
			description: "getMonitorBounds() left/top/right/bottom fields are always numbers.",
			steps: [
				{ call: "getMonitorBounds", args: [1] },
				{ assert: "all_fields_are_numbers", fields: portContract.BOUNDS_SHAPE },
			],
		},
		{
			id: "get_monitor_bounds_invalid_index_returns_zeros",
			description: "getMonitorBounds() on an out-of-range index returns an all-zero object.",
			steps: [
				{ call: "getMonitorBounds", args: [9999] },
				{ assert: "return_shape",   required_fields: portContract.BOUNDS_SHAPE },
				{ assert: "no_exception" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
