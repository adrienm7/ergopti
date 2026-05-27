// static/ergopti_plus/shared/tooltip/layout.js

/**
 * ==============================================================================
 * MODULE: Tooltip Layout Engine
 * DESCRIPTION:
 * Pure position-resolution and geometry engine for the Ergopti+ tooltip.
 * Accepts a platform-supplied anchor descriptor and a canvas size, then returns
 * the final (x, y) position clamped to the visible screen area.
 *
 * FEATURES & RATIONALE:
 * 1. Platform-agnostic: no OS calls. The driver is responsible for resolving
 *    the anchor (caret position, accessibility element bounds, window frame)
 *    and for providing the screen frame. This module only does math.
 * 2. Single source of truth: both AHK (_TooltipResolvePosition) and
 *    Hammerspoon (renderer.lua resolve_anchor + render position math) implement
 *    the cascade and clamping logic defined here. Any change here must be
 *    ported to both driver implementations.
 * 3. Testable: no side effects. scripts/test-tooltip-layout.js exercises
 *    every anchor type and screen-edge clamping case.
 *
 * COORDINATE SYSTEM:
 *   All values are in "layout units" (logical pixels on Windows, points on
 *   macOS). Drivers that work in physical pixels must convert before calling
 *   and after receiving results. The screen frame is expressed in the same
 *   coordinate space as the anchor.
 *
 * ANCHOR TYPES:
 *   "caret"       — insertion point from platform caret API or AX element.
 *                   Tooltip appears below-right of the anchor point.
 *   "input_box"   — larger AX element (e.g. a full text area).
 *                   Tooltip appears below the element, horizontally centred.
 *   "window"      — bottom-centre of the active window frame (fallback).
 *                   Tooltip appears just above that point.
 *   "screen"      — absolute screen coordinates (e.g. from VSCode bridge).
 *                   Treated identically to "caret".
 *   null / absent — no anchor found; tooltip appears at screen centre-bottom.
 * ==============================================================================
 */

"use strict";

const CONSTANTS = {
	caretOffsetX:        15,
	caretOffsetY:        18,
	windowOffsetY:        5,
	windowBottomInsetAhk: 60,
	windowBottomInsetHs:  40,
	screenMargin:          5,
};




// ================================================
// ================================================
// ======= 1/ Position resolution =======
// ================================================
// ================================================

/**
 * Resolves the tooltip (x, y) position from an anchor descriptor.
 *
 * @param {object|null} anchor - Anchor provided by the platform driver:
 *   {
 *     type: "caret"|"input_box"|"window"|"screen",
 *     x:    number,   // left edge of the anchor area (layout units)
 *     y:    number,   // top edge of the anchor area (layout units)
 *     w:    number,   // width of the anchor area (0 for point anchors)
 *     h:    number,   // height of the anchor area (0 for point anchors)
 *   }
 * @param {object} canvasSize - Computed canvas dimensions:
 *   { w: number, h: number }
 * @param {object} screenFrame - Active screen bounds in layout units:
 *   { x: number, y: number, w: number, h: number }
 * @param {object} [opts] - Optional overrides for offset constants.
 *   All keys are optional; defaults come from CONSTANTS above.
 * @returns {{ x: number, y: number }} Final clamped tooltip position.
 */
function resolvePosition(anchor, canvasSize, screenFrame, opts = {}) {
	const cfg = {
		caretOffsetX:       opts.caretOffsetX       ?? CONSTANTS.caretOffsetX,
		caretOffsetY:       opts.caretOffsetY        ?? CONSTANTS.caretOffsetY,
		windowOffsetY:      opts.windowOffsetY       ?? CONSTANTS.windowOffsetY,
		windowBottomInset:  opts.windowBottomInset   ?? CONSTANTS.windowBottomInsetHs,
		screenMargin:       opts.screenMargin        ?? CONSTANTS.screenMargin,
	};

	let posX, posY;

	if (!anchor) {
		// No anchor found — centre the tooltip horizontally at the screen bottom.
		posX = screenFrame.x + (screenFrame.w - canvasSize.w) / 2;
		posY = screenFrame.y + screenFrame.h - canvasSize.h - cfg.windowOffsetY;
	} else if (anchor.type === "caret" || anchor.type === "screen") {
		// Point anchor — position below-right of the caret.
		posX = anchor.x + cfg.caretOffsetX;
		posY = anchor.y + (anchor.h ?? 0) + cfg.caretOffsetY;
	} else if (anchor.type === "input_box") {
		// Wide anchor — centre tooltip under the element; flip above if it
		// would overflow the bottom screen edge.
		posX = anchor.x - canvasSize.w / 2;
		posY = anchor.y + cfg.windowOffsetY;
		if (posY + canvasSize.h > screenFrame.y + screenFrame.h) {
			posY = anchor.y - canvasSize.h - cfg.windowOffsetY;
		}
	} else if (anchor.type === "window") {
		// Window-bottom fallback — same centering / flip logic as input_box.
		posX = anchor.x - canvasSize.w / 2;
		posY = anchor.y + cfg.windowOffsetY;
		if (posY + canvasSize.h > screenFrame.y + screenFrame.h) {
			posY = anchor.y - canvasSize.h - cfg.windowOffsetY;
		}
	} else {
		// Unknown anchor type — treat as no-anchor (screen centre-bottom).
		posX = screenFrame.x + (screenFrame.w - canvasSize.w) / 2;
		posY = screenFrame.y + screenFrame.h - canvasSize.h - cfg.windowOffsetY;
	}

	return clampToScreen({ x: posX, y: posY }, canvasSize, screenFrame, cfg.screenMargin);
}

/**
 * Clamps a candidate tooltip position so the entire canvas remains within the
 * screen bounds with at least `margin` layout units of clearance on all sides.
 *
 * @param {{ x: number, y: number }} pos - Candidate top-left position.
 * @param {{ w: number, h: number }} canvasSize - Canvas dimensions.
 * @param {{ x: number, y: number, w: number, h: number }} screenFrame - Screen bounds.
 * @param {number} [margin] - Minimum clearance from screen edges (layout units).
 * @returns {{ x: number, y: number }} Clamped position.
 */
function clampToScreen(pos, canvasSize, screenFrame, margin = CONSTANTS.screenMargin) {
	const minX = screenFrame.x + margin;
	const maxX = screenFrame.x + screenFrame.w - canvasSize.w - margin;
	const minY = screenFrame.y + margin;
	const maxY = screenFrame.y + screenFrame.h - canvasSize.h - margin;

	return {
		x: Math.max(minX, Math.min(pos.x, maxX)),
		y: Math.max(minY, Math.min(pos.y, maxY)),
	};
}




// ===============================================
// ===============================================
// ======= 2/ Canvas geometry helpers =======
// ===============================================
// ===============================================

/**
 * Computes the canvas width and total height for a stacked hotstring tooltip.
 *
 * Input rows must already carry their measured text size. The engine does not
 * call any platform text-measurement API — that is the driver's responsibility.
 *
 * @param {Array<object>} rows - Array of row descriptors:
 *   {
 *     textSize:  { w: number, h: number },  // measured main text
 *     labelSize: { w: number, h: number },  // measured trigger label (or {w:0, h:0})
 *   }
 * @param {object} [opts] - Layout override options.
 *   padX        {number} - Horizontal padding (default 14).
 *   padY        {number} - Vertical padding per row (default 7).
 *   labelGap    {number} - Gap between text and label columns (default 16).
 *   separatorH  {number} - Height of inter-row separator line (default 1).
 * @returns {{
 *   canvasW:    number,          // total canvas width
 *   canvasH:    number,          // total canvas height
 *   rowMeta:    Array<{ topY: number, rowH: number }>,  // per-row layout
 *   maxTextW:   number,          // widest text column
 *   maxLabelW:  number,          // widest label column (0 if no labels)
 *   labelZone:  number,          // label column width including gap (0 if no labels)
 * }}
 */
function computeStackedGeometry(rows, opts = {}) {
	const padX       = opts.padX       ?? 14;
	const padY       = opts.padY       ?? 7;
	const labelGap   = opts.labelGap   ?? 16;
	const separatorH = opts.separatorH ?? 1;

	let maxTextW  = 0;
	let maxLabelW = 0;

	for (const row of rows) {
		if (row.textSize.w  > maxTextW)  maxTextW  = row.textSize.w;
		if (row.labelSize.w > maxLabelW) maxLabelW = row.labelSize.w;
	}

	const labelZone = maxLabelW > 0 ? labelGap + maxLabelW : 0;
	const canvasW   = padX + maxTextW + labelZone + padX;

	let totalH  = 0;
	const rowMeta = [];
	for (let i = 0; i < rows.length; i++) {
		const rowH = padY + rows[i].textSize.h + padY;
		rowMeta.push({ topY: totalH, rowH });
		totalH += rowH;
		if (i < rows.length - 1) {
			totalH += separatorH;
		}
	}

	return { canvasW, canvasH: totalH, rowMeta, maxTextW, maxLabelW, labelZone };
}

/**
 * Computes the canvas geometry for the LLM prediction tooltip.
 *
 * The LLM canvas contains up to three vertical blocks stacked with a separator:
 *   [predictions] [---separator---] [hint] [info]
 *
 * Hint and info may be combined onto a single line if they fit within the
 * predictions width. The engine returns whether the combined layout applies.
 *
 * All block sizes must be pre-measured by the driver.
 *
 * @param {object} blocks - Pre-measured block sizes:
 *   {
 *     predsSize:    { w: number, h: number },
 *     hintSize:     { w: number, h: number } | null,
 *     infoSize:     { w: number, h: number } | null,
 *     combinedSize: { w: number, h: number } | null,  // hint + separator + info
 *     fixedWidth:   number | null,  // forced minimum width (e.g. from model info header)
 *   }
 * @param {object} [opts] - Layout overrides.
 *   padX        {number} - Horizontal padding (default 14).
 *   padY        {number} - Vertical padding (default 7).
 *   lineSpacing {number} - Gap between blocks (default 8).
 *   hintSpacing {number} - Reduced gap between hint and info rows (default 4).
 * @returns {{
 *   canvasW:        number,
 *   canvasH:        number,
 *   isCombined:     boolean,
 *   predsFrame:     { x, y, w, h },
 *   separatorY:     number | null,
 *   hintFrame:      { x, y, w, h } | null,
 *   infoFrame:      { x, y, w, h } | null,
 *   combinedFrame:  { x, y, w, h } | null,
 * }}
 */
function computeLlmGeometry(blocks, opts = {}) {
	const padX        = opts.padX        ?? 14;
	const padY        = opts.padY        ?? 7;
	const lineSpacing = opts.lineSpacing  ?? 8;
	const hintSpacing = opts.hintSpacing  ?? 4;

	const maxW     = Math.max(blocks.predsSize.w, blocks.fixedWidth ?? 0);
	const canvasW  = maxW + padX * 2;

	// Decide whether hint+info fit on a single combined row.
	const isCombined = !!(
		blocks.hintSize &&
		blocks.infoSize &&
		blocks.combinedSize &&
		blocks.combinedSize.w <= maxW
	);

	let currentY  = padY;

	// Predictions block.
	const predsFrame = { x: padX, y: currentY, w: maxW, h: blocks.predsSize.h };
	currentY += blocks.predsSize.h + lineSpacing;

	// Separator (only when there is a hint or info block).
	const hasHintOrInfo = blocks.hintSize || blocks.infoSize;
	let separatorY = null;
	if (hasHintOrInfo) {
		separatorY = currentY;
		currentY += lineSpacing;
	}

	// Hint / info blocks.
	let hintFrame    = null;
	let infoFrame    = null;
	let combinedFrame = null;

	if (isCombined && blocks.combinedSize) {
		combinedFrame = { x: 0, y: currentY, w: canvasW, h: blocks.combinedSize.h };
		currentY += blocks.combinedSize.h + lineSpacing;
	} else {
		if (blocks.hintSize) {
			hintFrame = { x: 0, y: currentY, w: canvasW, h: blocks.hintSize.h };
			currentY += blocks.hintSize.h + (blocks.infoSize ? hintSpacing : lineSpacing);
		}
		if (blocks.infoSize) {
			infoFrame = { x: 0, y: currentY, w: canvasW, h: blocks.infoSize.h };
			currentY += blocks.infoSize.h + lineSpacing;
		}
	}

	const canvasH = currentY - lineSpacing + padY;

	return {
		canvasW,
		canvasH,
		isCombined,
		predsFrame,
		separatorY,
		hintFrame,
		infoFrame,
		combinedFrame,
	};
}




// =====================================================
// =====================================================
// ======= 3/ Test vector generation =======
// =====================================================
// =====================================================

/**
 * Returns canonical test vectors for the position resolution and clamping logic.
 * Each vector provides inputs and the expected output so the JS unit test and
 * driver implementations can all be validated against the same ground truth.
 *
 * @returns {Array<object>} Array of test vector objects.
 */
function layoutTestVectors() {
	const screen = { x: 0, y: 0, w: 1920, h: 1080 };
	const canvas = { w: 300, h: 80 };

	return [
		{
			id:          "caret_normal",
			description: "Caret anchor — tooltip appears below-right of the insertion point.",
			anchor:      { type: "caret", x: 500, y: 400, w: 0, h: 20 },
			canvasSize:  canvas,
			screenFrame: screen,
			expected:    { x: 515, y: 438 },  // x + 15, y + 20 + 18
		},
		{
			id:          "caret_near_right_edge",
			description: "Caret near right edge — clamped so tooltip stays on screen.",
			anchor:      { type: "caret", x: 1800, y: 400, w: 0, h: 20 },
			canvasSize:  canvas,
			screenFrame: screen,
			// Unclamped x = 1815, but max = 1920 - 300 - 5 = 1615.
			expected:    { x: 1615, y: 438 },
		},
		{
			id:          "caret_near_bottom",
			description: "Caret near bottom — clamped upward so tooltip stays on screen.",
			anchor:      { type: "caret", x: 500, y: 1020, w: 0, h: 20 },
			canvasSize:  canvas,
			screenFrame: screen,
			// Unclamped y = 1058, but max = 1080 - 80 - 5 = 995.
			expected:    { x: 515, y: 995 },
		},
		{
			id:          "input_box_normal",
			description: "Input-box anchor — centred below the element.",
			anchor:      { type: "input_box", x: 960, y: 500, w: 0, h: 0 },
			canvasSize:  canvas,
			screenFrame: screen,
			// x = 960 - 300/2 = 810, y = 500 + 5 = 505.
			expected:    { x: 810, y: 505 },
		},
		{
			id:          "input_box_near_bottom_flips",
			description: "Input-box anchor near bottom — tooltip flips above the element.",
			anchor:      { type: "input_box", x: 960, y: 1010, w: 0, h: 0 },
			canvasSize:  canvas,
			screenFrame: screen,
			// Unclamped y = 1015 → overflow (1015 + 80 > 1080) → flip: y = 1010 - 80 - 5 = 925.
			expected:    { x: 810, y: 925 },
		},
		{
			id:          "no_anchor_screen_center_bottom",
			description: "No anchor — tooltip appears at screen centre-bottom.",
			anchor:      null,
			canvasSize:  canvas,
			screenFrame: screen,
			// x = (1920 - 300) / 2 = 810, y = 1080 - 80 - 5 = 995.
			expected:    { x: 810, y: 995 },
		},
	];
}


module.exports = {
	CONSTANTS,
	resolvePosition,
	clampToScreen,
	computeStackedGeometry,
	computeLlmGeometry,
	layoutTestVectors,
};
