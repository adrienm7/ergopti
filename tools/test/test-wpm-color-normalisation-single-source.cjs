// tools/test/test-wpm-color-normalisation-single-source.cjs

/**
 * ==============================================================================
 * MODULE: WPM Color Normalisation Golden-Vector Gate (#6)
 * DESCRIPTION:
 * The WPM widget re-projects hotstring/AI accent colours onto a fixed HSL
 * target (L=0.40, S=1.00) and darkens the unit strip. Both algorithms are
 * implemented twice — once in Lua (macOS wpm_widget.lua) and once in AHK
 * (Windows wpm_display.ahk / wpm_widget.ahk) — with NO shared canonical and
 * NO cross-driver vectors to catch drift.
 *
 * This test implements the reference algorithm ONCE in JS (matching the
 * shared Lua engine's semantics: floor for darken, floor(x+0.5) for HSL→RGB),
 * feeds a golden corpus of real-world accent colours through it, and hardcodes
 * the expected outputs. Either driver's implementation that disagrees with
 * these golden values has drifted and must be aligned.
 *
 * The corpus covers the colour gamut: red, orange, yellow, green, cyan, blue,
 * purple, magenta, plus real Ergonis accent colours gleaned from hotstring
 * TOML files, plus edge cases (achromatic, 3-char shorthand invariance).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

// Shared TOML constants used by both drivers.
const WIDGET_HSL_L = 0.40;
const WIDGET_HSL_S = 1.00;
const UNIT_DARKEN   = 0.40;

/**
 * Parse a 6-char hex colour ("#rrggbb" or "rrggbb") into {r,g,b} 0-255 ints.
 * Returns null for junk input (achromatic guard).
 */
function parseHex(hex) {
	const h = (hex || '').replace(/^#/, '');
	if (!/^[0-9A-Fa-f]{6}$/.test(h)) return null;
	return {
		r: parseInt(h.slice(0, 2), 16),
		g: parseInt(h.slice(2, 4), 16),
		b: parseInt(h.slice(4, 6), 16),
	};
}

/**
 * RGB→HSL: extract the hue (0-1) from an {r,g,b} 0-255 triplet.
 * Returns null for achromatic input (all channels equal or delta ≤ 1).
 */
function extractHue(rgb) {
	const r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255;
	const max = Math.max(r, g, b), min = Math.min(r, g, b);
	const delta = max - min;
	if (delta <= 0.001) return null; // achromatic — no hue

	let hue;
	if (max === r)       hue = ((g - b) / delta + 6) % 6;
	else if (max === g)  hue = (b - r) / delta + 2;
	else                 hue = (r - g) / delta + 4;
	return hue / 6;
}

/**
 * HSL→RGB: re-project a hue onto the fixed widget L/S target.
 * Returns "#rrggbb". Matches the Lua _wpm_normalise_hex floor(x+0.5) rounding.
 */
function normaliseHex(hex) {
	const rgb = parseHex(hex);
	if (!rgb) return null;
	const hue = extractHue(rgb);
	if (hue === null) return null; // achromatic — caller applies fallback

	const L = WIDGET_HSL_L;
	const S = WIDGET_HSL_S;
	const C = (1 - Math.abs(2 * L - 1)) * S;
	const h6 = hue * 6;
	const X  = C * (1 - Math.abs(h6 % 2 - 1));
	const M  = L - C / 2;

	let r, g, b;
	if      (h6 < 1) { r = C; g = X; b = 0; }
	else if (h6 < 2) { r = X; g = C; b = 0; }
	else if (h6 < 3) { r = 0; g = C; b = X; }
	else if (h6 < 4) { r = 0; g = X; b = C; }
	else if (h6 < 5) { r = X; g = 0; b = C; }
	else             { r = C; g = 0; b = X; }

	// floor(x+0.5) == Math.round for non-negative — matches Lua.
	const nr = Math.max(0, Math.min(255, Math.floor((r + M) * 255 + 0.5)));
	const ng = Math.max(0, Math.min(255, Math.floor((g + M) * 255 + 0.5)));
	const nb = Math.max(0, Math.min(255, Math.floor((b + M) * 255 + 0.5)));

	return '#' + [nr, ng, nb].map(v => v.toString(16).padStart(2, '0')).join('');
}

/**
 * Darken a hex colour by the UNIT_DARKEN factor (0.40).
 * Each RGB channel × factor, floored (matches Lua _wpm_darken_hex semantics).
 */
function darkenHex(hex) {
	const rgb = parseHex(hex);
	if (!rgb) return null;

	return '#' + [
		Math.floor(rgb.r * UNIT_DARKEN),
		Math.floor(rgb.g * UNIT_DARKEN),
		Math.floor(rgb.b * UNIT_DARKEN),
	].map(v => v.toString(16).padStart(2, '0')).join('');
}

// ── Golden corpus ────────────────────────────────────────────────────────────
// Each entry: input accent hex, expected normalized hex, expected darkened hex.
// These are the authoritative expected outputs. Either driver must match these
// exactly, or there is a cross-driver drift to fix.

// WARNING: These golden values were computed by the JS reference implementation
// and verified byte-for-byte. Do NOT hand-edit them — if a value changes, it
// means the reference algorithm changed, and both drivers must be updated.
const GOLDEN = [
	// Primary/secondary wheel — each a distinct hue.
	{ input: '#ff0000', norm: '#cc0000', darken: '#660000' },  // red
	{ input: '#ff8800', norm: '#cc6d00', darken: '#663600' },  // orange
	{ input: '#ffcc00', norm: '#cca300', darken: '#665100' },  // yellow
	{ input: '#00cc00', norm: '#00cc00', darken: '#005100' },  // green
	{ input: '#00cccc', norm: '#00cccc', darken: '#005151' },  // cyan
	{ input: '#0066ff', norm: '#0052cc', darken: '#002866' },  // blue
	{ input: '#6600cc', norm: '#6600cc', darken: '#280051' },  // purple
	{ input: '#cc00cc', norm: '#cc00cc', darken: '#510051' },  // magenta

	// Real Ergonis hotstring group colours (from TOML _meta.color).
	{ input: '#0055cc', norm: '#0055cc', darken: '#002251' },  // magickey blue
	{ input: '#7a30b0', norm: '#7600cc', darken: '#301346' },  // AI purple
	{ input: '#ff4444', norm: '#cc0000', darken: '#661b1b' },  // light red

	// Achromatic / grey — normalise returns null (no hue), darken still works.
	// These exercise the fallback path: the caller should pass a fallback hex.
	{ input: '#888888', norm: null, darken: '#363636' },       // grey
	{ input: '#cccccc', norm: null, darken: '#515151' },       // light grey
	{ input: '#ffffff', norm: null, darken: '#666666' },       // white

	// Edge: case-normalisation (upper/lower/mixed).
	{ input: '#FF8800', norm: '#cc6d00', darken: '#663600' },  // uppercase same as lowercase
	{ input: '#00Cc00', norm: '#00cc00', darken: '#005100' },  // mixed case

	// Real-world accents from tooltip/hotstring colour palettes.
	{ input: '#e74c3c', norm: '#cc1300', darken: '#5c1e18' },  // warm red
	{ input: '#2ecc71', norm: '#00cc57', darken: '#12512d' },  // emerald
	{ input: '#3498db', norm: '#007acc', darken: '#143c57' },  // sky blue
];

// ── Verify golden corpus ─────────────────────────────────────────────────────

const errors = [];

for (let i = 0; i < GOLDEN.length; i++) {
	const g = GOLDEN[i];
	const actualNorm = normaliseHex(g.input);
	const actualDark = darkenHex(g.input);

	if (actualNorm !== g.norm) {
		if (g.norm === null) {
			// We expected null (achromatic) — verify the algorithm correctly
			// returns null so the caller applies fallback.
			if (actualNorm !== null) {
				errors.push(
					`Vector[${i}] "${g.input}": expected norm=null (achromatic), got "${actualNorm}". ` +
					`Achromatic guard (delta≤0.001) missed an achromatic input.`
				);
			}
		} else {
			errors.push(
				`Vector[${i}] "${g.input}": expected norm="${g.norm}", got "${actualNorm}". ` +
				`Recalculate the golden expected value.`
			);
		}
	}

	if (actualDark !== g.darken) {
		errors.push(
			`Vector[${i}] "${g.input}": expected darken="${g.darken}", got "${actualDark}". ` +
			`Darken formula changed or factor drifted.`
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] WPM colour normalisation golden vectors do not match:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

// ── Cross-driver gate: verify AHK darken (Round) consistency ─────────────────
// The AHK _WPMWidget_DarkenHex uses Round() while Lua uses math.floor().
// For factor 0.40, the two can differ by ±1 on boundary values (e.g. 122×0.40).
// This check alerts when they diverge so the maintainer can decide which to fix.

function darkenRound(hex) {
	const rgb = parseHex(hex);
	if (!rgb) return null;
	return '#' + [
		Math.round(rgb.r * UNIT_DARKEN),
		Math.round(rgb.g * UNIT_DARKEN),
		Math.round(rgb.b * UNIT_DARKEN),
	].map(v => Math.max(0, Math.min(255, v)).toString(16).padStart(2, '0')).join('');
}

const roundWarnings = [];
for (const g of GOLDEN) {
	const floorV = darkenHex(g.input);
	const roundV = darkenRound(g.input);
	if (floorV !== roundV) {
		roundWarnings.push(
			`"${g.input}" darken: floor="${floorV}" ≠ round="${roundV}". ` +
			`AHK (Round) and Lua (floor) disagree — choose one canonical.`
		);
	}
}

console.log('\x1b[32m[OK] WPM colour normalisation — ' + GOLDEN.length + ' golden vectors verified.\x1b[0m');

if (roundWarnings.length > 0) {
	console.warn('\x1b[33m[WARN] AHK Round() vs Lua floor() darken divergence detected:\x1b[0m');
	for (const w of roundWarnings) console.warn('    ' + w);
	console.warn('\x1b[33m    → Not a hard failure yet, but investigate before the next driver release.\x1b[0m');
} else {
	console.log('\x1b[32m[OK] AHK Round() and Lua floor() darken are byte-identical for this corpus.\x1b[0m');
}

// ── Prevent golden corpus staleness — verify this file is referenced ─────────
// Scan for the test file path in known consumers (CI config, run-js-suite).
const ciPath = path.join(ROOT, '.github', 'workflows', 'ci.yml');
if (fs.existsSync(ciPath)) {
	const ciContent = fs.readFileSync(ciPath, 'utf8');
	if (!ciContent.includes('test-wpm-color-normalisation')) {
		console.warn('\x1b[33m[WARN] test-wpm-color-normalisation-single-source.cjs is not referenced in CI workflow.\x1b[0m');
	}
}
