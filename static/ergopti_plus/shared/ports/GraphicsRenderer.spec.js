// static/ergopti_plus/shared/ports/GraphicsRenderer.spec.js

/**
 * ==============================================================================
 * PORT: GraphicsRenderer
 * DESCRIPTION:
 * Contract for the OS-level abstract rendering surface port. Every driver
 * adapter that creates and paints native layered windows MUST satisfy this
 * interface. The port abstracts GDI+ on Windows (AHK) and Core Graphics on
 * macOS (Hammerspoon) behind a unified window lifecycle + bitmap paint API.
 *
 * FEATURES & RATIONALE:
 * 1. Window lifecycle isolation: createWindow / destroyWindow give callers full
 *    control over allocation and teardown without coupling them to any particular
 *    OS windowing model (HWND, NSWindow, hs.canvas).
 * 2. Draw-callback model: drawBitmap receives an opaque draw function that the
 *    adapter invokes inside the correct GDI+/Core Graphics context. The caller
 *    never touches raw DC handles, keeping rendering logic portable.
 * 3. Show/hide symmetry: show() and hide() map to ShowWindow / setVisible on
 *    their respective platforms, always without stealing keyboard focus.
 * 4. Handle opacity: all methods that accept a handle MUST be no-ops when the
 *    handle is 0 / null — callers need not guard every call site.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The GraphicsRenderer port contract.
 * @type {object}
 */
const portContract = {
	name: "GraphicsRenderer",
	version: "1.0.0",

	/**
	 * createWindow(opts) — Allocate a native layered window.
	 *   @param {object} opts
	 *   @param {number} opts.x        Initial screen X in logical pixels.
	 *   @param {number} opts.y        Initial screen Y in logical pixels.
	 *   @param {number} opts.w        Window width in logical pixels.
	 *   @param {number} opts.h        Window height in logical pixels.
	 *   @param {boolean} [opts.clickThrough=true]  Window must not intercept
	 *          mouse events (WS_EX_TRANSPARENT / ignoresMouseEvents).
	 *   @param {boolean} [opts.alwaysOnTop=true]   Stays above all other windows.
	 *   @returns {number|object} Opaque handle (HWND on Windows, canvas on macOS).
	 *            Returns 0 on failure — callers must check before further use.
	 *   @error_behavior "log_and_return_zero"
	 *
	 * destroyWindow(handle) — Release the native window and all associated GDI
	 *   resources. Safe to call with handle=0 (no-op).
	 *   @param {number|object} handle  Handle returned by createWindow.
	 *   @returns {void}
	 *   @error_behavior "ignore"
	 *
	 * drawBitmap(handle, drawFn) — Paint the window surface via a caller-supplied
	 *   draw function. The adapter sets up the GDI+/CG context, calls drawFn with
	 *   the context handle, then commits the result via UpdateLayeredWindow /
	 *   canvas:renderImage. Safe to call with handle=0 (no-op).
	 *   @param {number|object} handle  Handle returned by createWindow.
	 *   @param {Function}      drawFn  Called as drawFn(ctx) where ctx is the
	 *          platform graphics context (pGfx on Windows, cgContext on macOS).
	 *   @returns {void}
	 *   @error_behavior "log_and_return"
	 *
	 * show(handle) — Make the window visible without stealing focus.
	 *   Equivalent to ShowWindow(SW_SHOWNOACTIVATE) on Windows.
	 *   Safe to call with handle=0 (no-op).
	 *   @param {number|object} handle
	 *   @returns {void}
	 *   @error_behavior "ignore"
	 *
	 * hide(handle) — Hide the window (SW_HIDE / setVisible false).
	 *   Safe to call with handle=0 (no-op).
	 *   @param {number|object} handle
	 *   @returns {void}
	 *   @error_behavior "ignore"
	 */
	methods: {
		createWindow:  { arity: 1, required: true },
		destroyWindow: { arity: 1, required: true },
		drawBitmap:    { arity: 2, required: true },
		show:          { arity: 1, required: true },
		hide:          { arity: 1, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a GraphicsRenderer adapter.
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
 * Returns test vectors for GraphicsRenderer compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "create_returns_nonzero_handle",
			description: "createWindow() with valid opts returns a non-zero handle.",
			input: { opts: { x: 100, y: 100, w: 200, h: 200 } },
			assert: { handle_nonzero: true },
		},
		{
			id: "destroy_zero_is_noop",
			description: "destroyWindow(0) is a safe no-op and does not throw.",
			input: { handle: 0 },
			assert: { no_exception: true },
		},
		{
			id: "show_zero_is_noop",
			description: "show(0) is a safe no-op and does not throw.",
			input: { handle: 0 },
			assert: { no_exception: true },
		},
		{
			id: "hide_zero_is_noop",
			description: "hide(0) is a safe no-op and does not throw.",
			input: { handle: 0 },
			assert: { no_exception: true },
		},
		{
			id: "draw_bitmap_zero_is_noop",
			description: "drawBitmap(0, fn) is a safe no-op and does not throw.",
			input: { handle: 0, drawFn: function(ctx) {} },
			assert: { no_exception: true },
		},
		{
			id: "draw_bitmap_calls_draw_fn",
			description: "drawBitmap() calls drawFn with the platform context.",
			input: {
				opts: { x: 0, y: 0, w: 64, h: 64 },
				drawFn: "spy",
			},
			assert: { draw_fn_called: true },
		},
		{
			id: "show_makes_window_visible",
			description: "show() makes the window visible without stealing focus.",
			input: { opts: { x: 0, y: 0, w: 64, h: 64 } },
			assert: { visible_after_show: true },
		},
		{
			id: "hide_makes_window_invisible",
			description: "hide() after show() makes the window invisible.",
			steps: [
				{ call: "createWindow", opts: { x: 0, y: 0, w: 64, h: 64 } },
				{ call: "show" },
				{ call: "hide" },
				{ assert: "is_hidden" },
			],
		},
		{
			id: "destroy_releases_resources",
			description: "destroyWindow() releases all GDI/CG resources without leaking.",
			input: { opts: { x: 0, y: 0, w: 64, h: 64 } },
			assert: { no_exception: true },
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
