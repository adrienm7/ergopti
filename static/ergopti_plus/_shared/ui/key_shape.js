// _shared/ui/key_shape.js

/**
 * ==============================================================================
 * MODULE: Key Shapes
 * DESCRIPTION:
 * The outline of a drawn key that is not a rectangle: the ISO Enter, an L of
 * two rows whose lower row is narrower (physical_keys.json gives it bottom_col
 * and bottom_width). The pages that draw a keyboard from that geometry share
 * this one outline, so every board draws the same L.
 *
 * FEATURES & RATIONALE:
 * 1. One SVG path for the whole key, in key units: a stroke that follows the
 *    L, not two rectangles whose seam shows.
 * 2. The gap between drawn keys is given in key units, so the notch lines up
 *    with the gap left beside the key that sits in it.
 * 3. A rectangle key has no outline here: a key without bottom_col throws, so
 *    a caller cannot draw a plain key through this path by mistake.
 * ==============================================================================
 */

const KEY_SHAPE = (function () {
	'use strict';

	/** Whether a key's geometry on one keyboard is the two-row L of the ISO Enter. */
	function isTwoRowL(geometry) {
		return (
			Boolean(geometry) &&
			(geometry.height || 1) > 1 &&
			typeof geometry.bottom_col === 'number' &&
			typeof geometry.bottom_width === 'number'
		);
	}

	/**
	 * The ISO Enter as one closed SVG path, its box from (0, 0) to the key's
	 * drawn width and height, both less the gap: the upper row spans the whole
	 * width, the lower rows start at the notch.
	 * @param {{col: number, width: number, height: number, bottom_col: number,
	 *   bottom_width: number}} geometry - physical_keys.json geometry, in key units.
	 * @param {{gap: number, radius: number}} drawing - The gap between drawn keys and
	 *   the corner radius, in key units.
	 * @returns {{d: string, width: number, height: number, notchX: number, notchY: number}}
	 *   The path and its box; notchX and notchY place the inner corner.
	 * @throws {Error} On a geometry that is not the two-row L.
	 */
	function lPath(geometry, drawing) {
		if (!isTwoRowL(geometry)) throw new Error('key shape: the geometry is not a two-row L');
		const { gap, radius } = drawing;
		if (!(gap >= 0) || !(radius >= 0)) throw new Error('key shape: gap and radius are key units');
		const width = geometry.width - gap;
		const height = geometry.height - gap;
		const notchX = geometry.bottom_col - geometry.col;
		const notchY = 1 - gap;
		if (!(notchX > 0) || notchX + geometry.bottom_width - gap > width + 1e-9)
			throw new Error('key shape: the lower row does not sit under the upper one');
		const r = Math.min(radius, notchX / 2, notchY / 2);
		const n = (value) => Number(value.toFixed(4));
		// Clockwise from the top-left corner, each corner rounded by an arc.
		const d = [
			`M ${n(r)} 0`,
			`H ${n(width - r)}`,
			`A ${n(r)} ${n(r)} 0 0 1 ${n(width)} ${n(r)}`,
			`V ${n(height - r)}`,
			`A ${n(r)} ${n(r)} 0 0 1 ${n(width - r)} ${n(height)}`,
			`H ${n(notchX + r)}`,
			`A ${n(r)} ${n(r)} 0 0 1 ${n(notchX)} ${n(height - r)}`,
			`V ${n(notchY + r)}`,
			`A ${n(r)} ${n(r)} 0 0 0 ${n(notchX - r)} ${n(notchY)}`,
			`H ${n(r)}`,
			`A ${n(r)} ${n(r)} 0 0 1 0 ${n(notchY - r)}`,
			`V ${n(r)}`,
			`A ${n(r)} ${n(r)} 0 0 1 ${n(r)} 0`,
			'Z'
		].join(' ');
		return { d, width, height, notchX, notchY };
	}

	return { isTwoRowL, lPath };
})();

// Node (tests) reads the module through require().
if (typeof module !== 'undefined' && module.exports) module.exports = KEY_SHAPE;
