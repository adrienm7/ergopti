// static/ergopti_plus/shared/tooltip/tint.js

/**
 * ==============================================================================
 * MODULE: Tooltip Tint Mixing
 * DESCRIPTION:
 * Pure HSL-based tint mixing algorithm shared across all Ergopti+ drivers.
 * Takes an accent color (RGB) and produces the characteristic "dark background
 * with a colored wash" tooltip background color used on every platform.
 *
 * FEATURES & RATIONALE:
 * 1. Platform-agnostic: no OS calls, no side effects — pure math only.
 * 2. Single source of truth: both AHK (_TooltipMixTintHex) and Hammerspoon
 *    (renderer.apply_tint) implement this exact algorithm. Any change here
 *    must be ported to both driver implementations.
 * 3. Testable: every function is a pure transformation. This file is consumed
 *    by scripts/test-tooltip-tint.js and by the CI validation step.
 *
 * ALGORITHM SUMMARY:
 *   Given an accent color (any RGB), extract its hue only (discard saturation
 *   and lightness). Reconstruct a new color at fixed lightness = 0.10 and
 *   fixed saturation = 0.40. This always yields a near-black tone with a
 *   subtle hue wash, regardless of how bright or saturated the accent is.
 *
 * COLOR FORMAT CONVENTION:
 *   Input / output colors are plain JS objects: { r, g, b } with components
 *   in [0.0, 1.0]. The module also exports hex-string converters for drivers
 *   that require "#RRGGBB" notation.
 * ==============================================================================
 */

"use strict";

/**
 * Default tint parameters, mirroring constants.toml [tint].
 * Drivers that deviate from these must document the divergence explicitly.
 */
const DEFAULT_LIGHTNESS = 0.13;
const DEFAULT_SATURATION = 0.85;

/**
 * Default background color used when no accent is provided or when the
 * accent color cannot be parsed. Mirrors constants.toml colors.bg_hex.
 */
const DEFAULT_BG = { r: 0x24 / 255, g: 0x24 / 255, b: 0x24 / 255 };




// ===========================================
// ===========================================
// ======= 1/ Core tint-mixing algorithm =======
// ===========================================
// ===========================================

/**
 * Extracts the hue from an RGB color.
 * Returns a value in [0.0, 1.0) where 0 = red, 1/6 = yellow, 2/6 = green, etc.
 * Returns 0 for achromatic colors (r = g = b).
 * @param {number} r - Red component [0.0, 1.0].
 * @param {number} g - Green component [0.0, 1.0].
 * @param {number} b - Blue component [0.0, 1.0].
 * @returns {number} Hue in [0.0, 1.0).
 */
function extractHue(r, g, b) {
	const maxC  = Math.max(r, g, b);
	const minC  = Math.min(r, g, b);
	const delta = maxC - minC;

	if (delta < 0.0001) {
		// Achromatic — no meaningful hue.
		return 0;
	}

	let hue;
	if (maxC === r) {
		hue = ((g - b) / delta % 6 + 6) % 6;
	} else if (maxC === g) {
		hue = (b - r) / delta + 2;
	} else {
		hue = (r - g) / delta + 4;
	}
	return hue / 6;
}

/**
 * Converts HSL values to an RGB color.
 * @param {number} hue        - Hue in [0.0, 1.0).
 * @param {number} saturation - Saturation in [0.0, 1.0].
 * @param {number} lightness  - Lightness in [0.0, 1.0].
 * @returns {{ r: number, g: number, b: number }} RGB color with components in [0.0, 1.0].
 */
function hslToRgb(hue, saturation, lightness) {
	const c  = (1 - Math.abs(2 * lightness - 1)) * saturation;
	const h6 = hue * 6;
	const x  = c * (1 - Math.abs(h6 % 2 - 1));
	const m  = lightness - c / 2;

	let nr, ng, nb;
	if      (h6 < 1) { nr = c; ng = x; nb = 0; }
	else if (h6 < 2) { nr = x; ng = c; nb = 0; }
	else if (h6 < 3) { nr = 0; ng = c; nb = x; }
	else if (h6 < 4) { nr = 0; ng = x; nb = c; }
	else if (h6 < 5) { nr = x; ng = 0; nb = c; }
	else             { nr = c; ng = 0; nb = x; }

	return {
		r: Math.max(0, Math.min(1, nr + m)),
		g: Math.max(0, Math.min(1, ng + m)),
		b: Math.max(0, Math.min(1, nb + m)),
	};
}

/**
 * Mixes an accent color into a near-black background using hue-only blending.
 * This is the canonical algorithm implemented by every Ergopti+ driver.
 *
 * Only the hue of `accent` is used. Lightness and saturation are fixed at
 * the values in DEFAULT_LIGHTNESS / DEFAULT_SATURATION (from constants.toml).
 * An absent or achromatic accent returns the plain dark background.
 *
 * @param {object|null} accent            - Accent color { r, g, b } in [0.0, 1.0],
 *                                          or null/undefined for no tint.
 * @param {number} [lightness]            - Override for the fixed lightness (default 0.10).
 * @param {number} [saturation]           - Override for the fixed saturation (default 0.40).
 * @returns {{ r: number, g: number, b: number }} Mixed background color in [0.0, 1.0].
 */
function mixTint(accent, lightness = DEFAULT_LIGHTNESS, saturation = DEFAULT_SATURATION) {
	if (!accent || typeof accent !== "object") {
		return { ...DEFAULT_BG };
	}

	const r = Math.max(0, Math.min(1, accent.r ?? 0));
	const g = Math.max(0, Math.min(1, accent.g ?? 0));
	const b = Math.max(0, Math.min(1, accent.b ?? 0));

	const hue = extractHue(r, g, b);

	// Achromatic accent — no hue to carry, fall back to neutral background.
	if (Math.max(r, g, b) - Math.min(r, g, b) < 0.0001) {
		return { ...DEFAULT_BG };
	}

	return hslToRgb(hue, saturation, lightness);
}




// ===================================================
// ===================================================
// ======= 2/ Color format converters =======
// ===================================================
// ===================================================

/**
 * Parses a hex color string ("#RRGGBB" or "RRGGBB") into a normalized RGB object.
 * Returns null for malformed input so callers can fall back to the default.
 * @param {string|null} hex - Hex color string.
 * @returns {{ r: number, g: number, b: number }|null} Normalized color or null.
 */
function parseHex(hex) {
	if (typeof hex !== "string" || hex === "") return null;
	const h = hex.startsWith("#") ? hex.slice(1) : hex;
	if (h.length !== 6) return null;
	const ri = parseInt(h.slice(0, 2), 16);
	const gi = parseInt(h.slice(2, 4), 16);
	const bi = parseInt(h.slice(4, 6), 16);
	if (isNaN(ri) || isNaN(gi) || isNaN(bi)) return null;
	return { r: ri / 255, g: gi / 255, b: bi / 255 };
}

/**
 * Serializes a normalized RGB color to an uppercase hex string without "#".
 * Format: "RRGGBB" — the form AHK Gui.BackColor and SetFont "c" option accept.
 * @param {{ r: number, g: number, b: number }} color - Normalized RGB.
 * @returns {string} Uppercase hex string (6 characters, no "#" prefix).
 */
function toHexNoHash(color) {
	const r8 = Math.round(Math.max(0, Math.min(1, color.r)) * 255);
	const g8 = Math.round(Math.max(0, Math.min(1, color.g)) * 255);
	const b8 = Math.round(Math.max(0, Math.min(1, color.b)) * 255);
	return (
		r8.toString(16).toUpperCase().padStart(2, "0") +
		g8.toString(16).toUpperCase().padStart(2, "0") +
		b8.toString(16).toUpperCase().padStart(2, "0")
	);
}

/**
 * Serializes a normalized RGB color to a CSS hex string with "#" prefix.
 * @param {{ r: number, g: number, b: number }} color - Normalized RGB.
 * @returns {string} Hex string with "#" prefix (e.g. "#1A1A1A").
 */
function toHex(color) {
	return "#" + toHexNoHash(color);
}

/**
 * Converts a normalized RGB object to a Hammerspoon-style RGBA table literal.
 * @param {{ r: number, g: number, b: number }} color - Normalized RGB.
 * @param {number} [alpha=1.0] - Alpha component.
 * @returns {{ red: number, green: number, blue: number, alpha: number }}
 */
function toHsColor(color, alpha = 1.0) {
	return {
		red:   Math.max(0, Math.min(1, color.r)),
		green: Math.max(0, Math.min(1, color.g)),
		blue:  Math.max(0, Math.min(1, color.b)),
		alpha: Math.max(0, Math.min(1, alpha)),
	};
}

/**
 * Convenience: mix an accent hex string and return the result as a hex string.
 * Used by scripts/test-tooltip-tint.js to cross-validate AHK and HS outputs.
 * @param {string} accentHex - Accent color as "#RRGGBB" or "RRGGBB".
 * @returns {string} Tinted background as "#RRGGBB".
 */
function mixTintHex(accentHex) {
	const accent = parseHex(accentHex);
	if (!accent) return toHex(DEFAULT_BG);
	return toHex(mixTint(accent));
}




// ==============================================
// ==============================================
// ======= 3/ Test vector generation =======
// ==============================================
// ==============================================

/**
 * Returns the canonical test vectors for cross-driver tint validation.
 * Each vector exercises a distinct region of the hue wheel (red, green, blue,
 * yellow, magenta, cyan) plus the achromatic edge case.
 *
 * A driver is considered compliant if its tint output matches the `expected_hex`
 * field within ±1 per channel (rounding differences of 1 LSB are acceptable).
 *
 * @returns {Array<{ id: string, accent_hex: string, expected_hex: string, description: string }>}
 */
function tintTestVectors() {
	return [
		{
			id:           "red_accent",
			description:  "Pure red accent → hue=0, produces warm near-black.",
			accent_hex:   "#FF0000",
			expected_hex: toHex(mixTint({ r: 1, g: 0, b: 0 })),
		},
		{
			id:           "green_accent",
			description:  "Pure green accent → hue=1/3.",
			accent_hex:   "#00CC00",
			expected_hex: toHex(mixTint({ r: 0, g: 0.8, b: 0 })),
		},
		{
			id:           "blue_accent",
			description:  "Medium blue accent → hue=2/3.",
			accent_hex:   "#3388FF",
			expected_hex: toHex(mixTint({ r: 0.2, g: 0.53, b: 1 })),
		},
		{
			id:           "purple_accent",
			description:  "Purple accent (LLM loading color from config).",
			accent_hex:   "#AE61FF",
			expected_hex: toHex(mixTint({ r: 0.68, g: 0.38, b: 1 })),
		},
		{
			id:           "yellow_accent",
			description:  "Yellow accent → hue=1/6.",
			accent_hex:   "#FFCC00",
			expected_hex: toHex(mixTint({ r: 1, g: 0.8, b: 0 })),
		},
		{
			id:           "achromatic",
			description:  "Achromatic (gray) accent → falls back to default dark background.",
			accent_hex:   "#808080",
			expected_hex: toHex(DEFAULT_BG),
		},
		{
			id:           "no_accent",
			description:  "Null accent → falls back to default dark background.",
			accent_hex:   null,
			expected_hex: toHex(DEFAULT_BG),
		},
	];
}


module.exports = {
	DEFAULT_LIGHTNESS,
	DEFAULT_SATURATION,
	DEFAULT_BG,
	extractHue,
	hslToRgb,
	mixTint,
	parseHex,
	toHexNoHash,
	toHex,
	toHsColor,
	mixTintHex,
	tintTestVectors,
};
