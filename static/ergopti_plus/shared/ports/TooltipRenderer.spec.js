// static/ergopti_plus/shared/ports/TooltipRenderer.spec.js

/**
 * ==============================================================================
 * PORT: TooltipRenderer
 * DESCRIPTION:
 * Contract for the OS-level floating overlay port. Every driver adapter that
 * displays the Ergopti+ tooltip MUST satisfy this interface. The port accepts
 * the draw_calls[] IR produced by the shared tooltip layout engine
 * (shared/tooltip/draw_calls.js) and translates it to native drawing calls.
 *
 * FEATURES & RATIONALE:
 * 1. IR-driven rendering: the adapter receives a draw_calls[] array and maps
 *    each call to its native API (AHK Gui/GDI, HS canvas). No layout
 *    arithmetic is done inside the adapter — that lives in shared/tooltip/.
 * 2. Partial update path: adapters that support indexed element mutation
 *    (hs.canvas) implement updateElement() to replace a single draw call
 *    without a full redraw, enabling flicker-free LLM token streaming.
 * 3. Click-through: the tooltip window MUST never steal focus or intercept
 *    mouse clicks (WS_EX_TRANSPARENT on AHK, ignoresMouseEvents on HS).
 * 4. Auto-dismiss: the adapter arms a platform timer when show() is called
 *    with a positive duration. The timer is cancelled on hide() or re-show().
 *    A generation counter prevents stale timers from hiding a rebuilt tooltip.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The TooltipRenderer port contract.
 * @type {object}
 */
const portContract = {
	name: "TooltipRenderer",
	version: "1.0.0",

	/**
	 * show(payload) — Render or update the tooltip.
	 *   @param {object}   payload
	 *   @param {Array}    payload.draw_calls  Ordered draw_calls[] IR array
	 *                     (see shared/tooltip/draw_calls.js).
	 *   @param {object}   payload.position    { x: number, y: number }
	 *                     Screen coordinates in logical pixels (already clamped
	 *                     by the layout engine).
	 *   @param {number}   payload.duration_sec  Auto-dismiss delay in seconds.
	 *                     0 means "keep visible until hide() is called".
	 *   @returns {void}
	 *   @error_behavior "log_and_return" — any rendering exception must call
	 *          hide() immediately to prevent ghost tooltips.
	 *
	 * hide() — Remove the tooltip from the screen immediately.
	 *   Cancels any pending auto-dismiss timer.
	 *   @returns {void}
	 *   @error_behavior "ignore" — always safe to call.
	 *
	 * isVisible() — Query display state.
	 *   @returns {boolean}
	 *
	 * updateElement(drawCall) — Replace a single draw call by its stable id.
	 *   Used for streaming partial updates (e.g., updating "preds" text during
	 *   LLM token streaming). If not supported by the adapter, the adapter
	 *   MUST fall back to a full show() re-render.
	 *   @param {object} drawCall  The replacement draw call (same id as existing).
	 *   @returns {void}
	 *   @error_behavior "log_and_return".
	 */
	methods: {
		show:          { arity: 1, required: true },
		hide:          { arity: 0, required: true },
		isVisible:     { arity: 0, required: true },
		updateElement: { arity: 1, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a TooltipRenderer adapter.
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
 * Minimal draw_calls[] fixture for a single-row tooltip.
 * Adapters use this in their test harness — no real rendering needed,
 * just assert no exception is thrown and isVisible() flips.
 */
const FIXTURE_SINGLE_ROW = [
	{
		type: "rect", id: "bg",
		frame: { x: 0, y: 0, w: 200, h: 32 },
		fill_color: { r: 0.10, g: 0.10, b: 0.10, a: 1.0 },
		stroke_color: null, stroke_width: 1, corner_radius: 7,
	},
	{
		type: "text", id: "row_text_0",
		frame: { x: 14, y: 7, w: 172, h: 18 },
		text: "example expansion", font_name: null, font_size: 14,
		color: { r: 1, g: 1, b: 1, a: 1 }, alignment: "left", styled: null,
	},
	{
		type: "rect", id: "border",
		frame: { x: 0, y: 0, w: 200, h: 32 },
		fill_color: null,
		stroke_color: { r: 1, g: 1, b: 1, a: 0.13 },
		stroke_width: 1, corner_radius: 7,
	},
];

/**
 * Returns test vectors for TooltipRenderer compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "show_makes_visible",
			description: "show() with valid draw_calls makes isVisible() return true.",
			input: {
				payload: {
					draw_calls:   FIXTURE_SINGLE_ROW,
					position:     { x: 100, y: 200 },
					duration_sec: 2.5,
				},
			},
			assert: { is_visible_after: true },
		},
		{
			id: "hide_makes_invisible",
			description: "hide() after show() makes isVisible() return false.",
			steps: [
				{ call: "show", payload: { draw_calls: FIXTURE_SINGLE_ROW, position: { x: 0, y: 0 }, duration_sec: 0 } },
				{ call: "hide" },
				{ assert: "isVisible", expected: false },
			],
		},
		{
			id: "hide_before_show_is_safe",
			description: "Calling hide() before show() is a safe no-op.",
			steps: [
				{ call: "hide" },
				{ assert: "isVisible", expected: false },
			],
		},
		{
			id: "auto_dismiss_fires",
			description: "Tooltip auto-hides after duration_sec seconds.",
			input: {
				payload: {
					draw_calls:   FIXTURE_SINGLE_ROW,
					position:     { x: 0, y: 0 },
					duration_sec: 0.1,
				},
			},
			assert: {
				// Test harness must advance the clock by 0.1 s and then check
				is_visible_after_delay: { delay_sec: 0.1, expected: false },
			},
		},
		{
			id: "duration_zero_stays_visible",
			description: "duration_sec=0 means no auto-dismiss; tooltip stays visible.",
			input: {
				payload: {
					draw_calls:   FIXTURE_SINGLE_ROW,
					position:     { x: 0, y: 0 },
					duration_sec: 0,
				},
			},
			assert: {
				is_visible_after_delay: { delay_sec: 5.0, expected: true },
			},
		},
		{
			id: "update_element_replaces_by_id",
			description: "updateElement() replaces the draw call with matching id.",
			setup: {
				show_first: {
					draw_calls: FIXTURE_SINGLE_ROW,
					position: { x: 0, y: 0 },
					duration_sec: 0,
				},
			},
			input: {
				draw_call: {
					type: "text", id: "row_text_0",
					frame: { x: 14, y: 7, w: 172, h: 18 },
					text: "updated text", font_name: null, font_size: 14,
					color: { r: 1, g: 1, b: 1, a: 1 }, alignment: "left", styled: null,
				},
			},
			assert: { no_exception: true, still_visible: true },
		},
		{
			id: "rendering_exception_calls_hide",
			description: "Any rendering exception must result in isVisible()=false.",
			input: {
				payload: {
					draw_calls:   [{ type: "invalid_type", id: "bogus" }],
					position:     { x: 0, y: 0 },
					duration_sec: 0,
				},
			},
			assert: { is_visible_after: false },
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors, FIXTURE_SINGLE_ROW };
