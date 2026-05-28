// static/ergopti_plus/shared/tooltip/draw_calls.js

/**
 * ==============================================================================
 * MODULE: Tooltip Draw-Call Composer
 * DESCRIPTION:
 * Defines the draw_calls[] intermediate representation (IR) and the composer
 * functions that build it from high-level tooltip descriptors. The IR is a
 * flat, ordered array of platform-agnostic drawing primitives that a driver
 * adapter interprets to produce the final on-screen tooltip.
 *
 * FEATURES & RATIONALE:
 * 1. Platform-agnostic IR: every draw call carries only pure data — no OS
 *    handles, no canvas objects, no GDI pointers. A driver receives the array,
 *    maps each call to its native drawing API, and executes them in order.
 * 2. Composable: each compose_* function focuses on one tooltip variant. New
 *    variants (Linux, web overlay) add a new compose function without touching
 *    existing ones.
 * 3. Testable: the IR is a plain JSON-serializable array. Snapshot tests can
 *    assert the full draw_calls[] output without rendering anything.
 * 4. Streaming-friendly: partial updates are expressed as a separate
 *    patch_draw_call() that replaces a single element by its stable id.
 *    Drivers that support indexed element mutation (Hammerspoon canvas) use this path
 *    to avoid full redraws during token streaming.
 *
 * DRAW CALL TYPES:
 *
 *   "rect"
 *     A filled and/or stroked rounded rectangle.
 *     { type, id, frame, fill_color, stroke_color, stroke_width, corner_radius, action }
 *
 *   "text"
 *     A text block (plain or styled).
 *     { type, id, frame, text, font_name, font_size, color, alignment, styled }
 *     `styled` is a driver-opaque object (Hammerspoon StyledText on HS, ignored on AHK).
 *
 *   "separator"
 *     A 1 px horizontal rule between stacked rows.
 *     { type, id, frame, fill_color }
 *
 * FRAME FORMAT:
 *   All frame coordinates are relative to the tooltip canvas origin (0, 0).
 *   { x: number, y: number, w: number, h: number }
 *   Units are layout units (see layout.js for the coordinate system).
 *
 * COLOR FORMAT:
 *   { r: number, g: number, b: number, a: number } with components in [0.0, 1.0].
 *   Drivers convert to their native format (hex string for AHK, hs table for HS).
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Draw-call factory functions =======
// ==================================================
// ==================================================

/**
 * Creates a rectangle draw call.
 * @param {string} id             - Stable identifier for partial updates.
 * @param {object} frame          - { x, y, w, h } relative to canvas origin.
 * @param {object} [fillColor]    - { r, g, b, a } or null for no fill.
 * @param {object} [strokeColor]  - { r, g, b, a } or null for no stroke.
 * @param {number} [strokeWidth]  - Stroke width in layout units (default 1).
 * @param {number} [cornerRadius] - Rounded corner radius (default 0 = sharp).
 * @returns {object} Rect draw call.
 */
function makeRect(id, frame, fillColor = null, strokeColor = null, strokeWidth = 1, cornerRadius = 0) {
	return {
		type:          "rect",
		id,
		frame,
		fill_color:    fillColor,
		stroke_color:  strokeColor,
		stroke_width:  strokeWidth,
		corner_radius: cornerRadius,
	};
}

/**
 * Creates a text draw call for plain text.
 * @param {string} id          - Stable identifier for partial updates.
 * @param {object} frame       - { x, y, w, h }.
 * @param {string} text        - Plain text content.
 * @param {string} fontName    - Font family name (platform-specific).
 * @param {number} fontSize    - Font size in layout units.
 * @param {object} color       - { r, g, b, a } text color.
 * @param {string} [alignment] - "left" | "center" | "right" (default "left").
 * @returns {object} Text draw call.
 */
function makeText(id, frame, text, fontName, fontSize, color, alignment = "left") {
	return {
		type:      "text",
		id,
		frame,
		text,
		font_name: fontName,
		font_size: fontSize,
		color,
		alignment,
		styled:    null,   // no styled override
	};
}

/**
 * Creates a text draw call for driver-supplied styled text (opaque object).
 * The `styled` field is passed through to the driver as-is; plain `text`,
 * `color`, and font fields are still populated so non-styled drivers can fall
 * back to them.
 * @param {string} id       - Stable identifier.
 * @param {object} frame    - { x, y, w, h }.
 * @param {any}    styled   - Platform-opaque styled text object.
 * @param {string} fallback - Plain-text fallback for drivers without styled support.
 * @param {object} color    - { r, g, b, a } fallback color.
 * @returns {object} Text draw call with styled field populated.
 */
function makeStyledText(id, frame, styled, fallback, color) {
	return {
		type:      "text",
		id,
		frame,
		text:      fallback,
		font_name: null,     // caller controls via styled object
		font_size: null,
		color,
		alignment: "left",
		styled,
	};
}

/**
 * Creates a separator draw call (thin horizontal rule).
 * @param {string} id        - Stable identifier.
 * @param {number} y         - Y position relative to canvas origin.
 * @param {number} canvasW   - Full canvas width (separator spans edge to edge).
 * @param {object} fillColor - { r, g, b, a }.
 * @returns {object} Separator draw call.
 */
function makeSeparator(id, y, canvasW, fillColor) {
	return {
		type:       "separator",
		id,
		frame:      { x: 0, y, w: canvasW, h: 1 },
		fill_color: fillColor,
	};
}




// =========================================================
// =========================================================
// ======= 2/ Stacked hotstring tooltip composer =======
// =========================================================
// =========================================================

/**
 * Composes the draw_calls[] for a stacked hotstring tooltip.
 *
 * DRIVER RESPONSIBILITY (before calling this function):
 *   Measure every row's text and label size. Pass the geometry computed by
 *   layout.computeStackedGeometry(). Tint each row's bg_color using
 *   tint.mixTint() if colorization is enabled.
 *
 * @param {Array<object>} rows - Row descriptors (one per expansion candidate):
 *   {
 *     text:         string,          // main expansion text
 *     trigger_label:string|null,     // right-column symbol (e.g. "★", "↵") or null
 *     is_dimmed:    boolean,         // non-firing alternate; shown grayed + strikethrough
 *     bg_color:     { r, g, b, a }, // tinted background color for this row
 *   }
 * @param {object} geometry  - Output of layout.computeStackedGeometry().
 * @param {object} style     - Resolved style constants:
 *   {
 *     fontName:      string,
 *     fontSizeMain:  number,
 *     fontSizeHint:  number,
 *     colorText:     { r, g, b, a },   // #FFFFFF
 *     colorDim:      { r, g, b, a },   // #8C8C8C
 *     colorLabel:    { r, g, b, a },   // #AAAAAA
 *     colorLabelDim: { r, g, b, a },   // darker label for dimmed rows
 *     colorSep:      { r, g, b, a },
 *     colorBorder:   { r, g, b, a },
 *     cornerRadius:  number,
 *   }
 * @returns {Array<object>} Ordered draw_calls[].
 */
function composeStacked(rows, geometry, style) {
	const calls = [];
	const { canvasW, canvasH, rowMeta, maxTextW, maxLabelW, labelZone } = geometry;
	const padX     = 14;   // must match what computeStackedGeometry used
	const padY     = 7;
	const labelGap = 16;

	for (let i = 0; i < rows.length; i++) {
		const row   = rows[i];
		const meta  = rowMeta[i];
		const topY  = meta.topY;
		const rowH  = meta.rowH;
		const isDim = row.is_dimmed;

		// Background fill — tinted per row.
		calls.push(makeRect(
			`row_bg_${i}`,
			{ x: 0, y: topY, w: canvasW, h: rowH },
			row.bg_color,
			null, 1, 0
		));

		// Main text.
		calls.push(makeText(
			`row_text_${i}`,
			{ x: padX, y: topY + padY, w: maxTextW, h: rowH - padY * 2 },
			row.text,
			style.fontName,
			style.fontSizeMain,
			isDim ? style.colorDim : style.colorText,
			"left"
		));
		// Mark dimmed rows so drivers can apply strikethrough.
		if (isDim) calls[calls.length - 1].is_dimmed = true;

		// Trigger label (right column).
		if (row.trigger_label && labelZone > 0) {
			const labelX = padX + maxTextW + labelGap;
			calls.push(makeText(
				`row_label_${i}`,
				{ x: labelX, y: topY + padY, w: maxLabelW, h: rowH - padY * 2 },
				row.trigger_label,
				style.fontName,
				style.fontSizeHint,
				isDim ? style.colorLabelDim : style.colorLabel,
				"right"
			));
		}

		// Separator — after every row except the last.
		if (i < rows.length - 1) {
			const sepY = topY + rowH;
			calls.push(makeSeparator(`sep_${i}`, sepY, canvasW, style.colorSep));
		}
	}

	// Outer border (last, so it renders on top of everything).
	calls.push(makeRect(
		"border",
		{ x: 0, y: 0, w: canvasW, h: canvasH },
		null,   // no fill — transparent interior
		style.colorBorder,
		1,
		style.cornerRadius
	));

	// Background — prepend so it is drawn first (underneath all rows).
	// Use the first row's bg_color as the canvas-level background fallback.
	calls.unshift(makeRect(
		"bg",
		{ x: 0, y: 0, w: canvasW, h: canvasH },
		rows[0]?.bg_color ?? { r: 0.10, g: 0.10, b: 0.10, a: 1.0 },
		null, 1, style.cornerRadius
	));

	return calls;
}




// ==================================================
// ==================================================
// ======= 3/ LLM prediction tooltip composer =======
// ==================================================
// ==================================================

/**
 * Composes the draw_calls[] for the LLM prediction tooltip.
 *
 * Stable element IDs allow partial updates during streaming: a driver that
 * supports indexed element mutation can replace only the "preds" or "info"
 * text call without re-executing the full compose pipeline.
 *
 * DRIVER RESPONSIBILITY (before calling this function):
 *   Assemble the styled text blocks (preds, hint, info). Measure their sizes.
 *   Compute geometry via layout.computeLlmGeometry(). Tint bg_color via
 *   tint.mixTint().
 *
 * @param {object} blocks   - Assembled and measured content:
 *   {
 *     preds:         any,    // styled text or plain string for predictions
 *     preds_plain:   string, // plain-text fallback
 *     hint:          any,    // styled hint block or null
 *     hint_plain:    string,
 *     info:          any,    // styled info block or null
 *     info_plain:    string,
 *     combined:      any,    // hint + sep + info combined styled text, or null
 *     combined_plain:string,
 *   }
 * @param {object} geometry - Output of layout.computeLlmGeometry().
 * @param {object} style    - Resolved style constants (same shape as composeStacked).
 *   Additionally requires: colorSep, colorHint, colorInfo.
 * @param {{ r, g, b, a }} bgColor - Tinted background color.
 * @returns {Array<object>} Ordered draw_calls[] with stable IDs.
 */
function composeLlm(blocks, geometry, style, bgColor) {
	const calls = [];
	const { canvasW, canvasH, predsFrame, separatorY, hintFrame, infoFrame, combinedFrame, isCombined } = geometry;

	// Background (rounded, tinted).
	calls.push(makeRect("bg", { x: 0, y: 0, w: canvasW, h: canvasH },
		bgColor, null, 1, style.cornerRadius));

	// Border.
	calls.push(makeRect("border", { x: 0, y: 0, w: canvasW, h: canvasH },
		null, style.colorBorder, 1, style.cornerRadius));

	// Predictions block — stable ID "preds" for streaming partial updates.
	calls.push(makeStyledText("preds", predsFrame,
		blocks.preds, blocks.preds_plain,
		{ r: 1, g: 1, b: 1, a: 1 }));

	// Separator (only when there is hint/info content).
	if (separatorY !== null) {
		calls.push(makeSeparator("sep", separatorY, canvasW, style.colorSep));
	}

	// Hint + info.
	if (isCombined && combinedFrame) {
		calls.push(makeStyledText("hint_info", combinedFrame,
			blocks.combined, blocks.combined_plain, style.colorHint));
	} else {
		if (hintFrame) {
			calls.push(makeStyledText("hint", hintFrame,
				blocks.hint, blocks.hint_plain, style.colorHint));
		}
		// Info line — stable ID "info" for streaming TTFT/TTLT updates.
		if (infoFrame) {
			calls.push(makeStyledText("info", infoFrame,
				blocks.info, blocks.info_plain, style.colorInfo));
		}
	}

	return calls;
}




// ==================================================
// ==================================================
// ======= 4/ Partial-update helpers =======
// ==================================================
// ==================================================

/**
 * Returns a copy of the draw_calls[] array with one call replaced by id.
 * Used for streaming updates where only one element changes (e.g. the info
 * bar TTFT/TTLT line or the predictions text block during token streaming).
 *
 * If no call with the given id exists, the original array is returned unchanged.
 *
 * @param {Array<object>} drawCalls   - Existing draw_calls[].
 * @param {string}        id          - ID of the call to replace.
 * @param {object}        replacement - New draw call object (must have same type and id).
 * @returns {Array<object>} New array with the replacement applied.
 */
function patchDrawCall(drawCalls, id, replacement) {
	const idx = drawCalls.findIndex(c => c.id === id);
	if (idx === -1) return drawCalls;
	const updated = [...drawCalls];
	updated[idx] = replacement;
	return updated;
}

/**
 * Finds a draw call by its stable id.
 * @param {Array<object>} drawCalls - The draw_calls[] array.
 * @param {string}        id        - The id to find.
 * @returns {object|null} The found draw call or null.
 */
function findDrawCall(drawCalls, id) {
	return drawCalls.find(c => c.id === id) ?? null;
}


module.exports = {
	makeRect,
	makeText,
	makeStyledText,
	makeSeparator,
	composeStacked,
	composeLlm,
	patchDrawCall,
	findDrawCall,
};
