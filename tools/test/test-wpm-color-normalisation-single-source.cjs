// tools/test/test-wpm-color-normalisation-single-source.cjs

/**
 * ==============================================================================
 * MODULE: WPM Color Normalisation Cross-Driver Drift Gate (#6)
 * DESCRIPTION:
 * The WPM widget re-projects hotstring/AI accent colours onto a fixed HSL
 * target (L=0.40, S=1.00) and darkens the unit strip by unit_strip_darken_factor
 * (0.40). Both algorithms are implemented twice — once in Lua (macOS
 * ui/wpm/wpm_widget.lua) and once in AHK (Windows ui/wpm/wpm_widget.ahk +
 * wpm_display.ahk) — with the constants single-sourced in
 * _shared/modules/wpm_widget/constants.toml but the rounding hand-written per
 * driver.
 *
 * WHY THIS GATE EXISTS (and how it is NOT tautological):
 * The previous version only ran a JS reference against golden values computed
 * from that same JS reference — it never read the drivers, so a driver could
 * drift freely and stay green. It also merely WARNED that the AHK darken
 * (Round) and the Lua darken (math.floor, truncating) disagreed by ±1/255.
 *
 * This version does two things the old one did not:
 *   1. CANONICAL: round-half-up (floor(x + 0.5) in Lua == Round() in AHK) is the
 *      single agreed rounding for BOTH normalise and darken. The golden corpus
 *      below is recomputed for that canonical and pins the reference spec.
 *   2. REAL DRIFT CHECK: it reads the four actual driver call sites and asserts
 *      each implements the canonical round-half-up rounding AND sources the
 *      darken factor + HSL L/S from the shared constants — so a driver that
 *      truncates, rounds differently, or hardcodes a literal turns this red.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

// Shared TOML constants used by both drivers (canonical values).
const WIDGET_HSL_L = 0.40;
const WIDGET_HSL_S = 1.00;
const UNIT_DARKEN  = 0.40;

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

/** Round-half-up, matching Lua math.floor(x + 0.5) and AHK Round() for x ≥ 0. */
function roundHalfUp(x) {
	return Math.floor(x + 0.5);
}

/**
 * HSL→RGB: re-project a hue onto the fixed widget L/S target.
 * Returns "#rrggbb". Round-half-up rounding (canonical, both drivers).
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

	const nr = Math.max(0, Math.min(255, roundHalfUp((r + M) * 255)));
	const ng = Math.max(0, Math.min(255, roundHalfUp((g + M) * 255)));
	const nb = Math.max(0, Math.min(255, roundHalfUp((b + M) * 255)));

	return '#' + [nr, ng, nb].map(v => v.toString(16).padStart(2, '0')).join('');
}

/**
 * Darken a hex colour by the UNIT_DARKEN factor (0.40).
 * Each RGB channel × factor, round-half-up (canonical, both drivers).
 */
function darkenHex(hex) {
	const rgb = parseHex(hex);
	if (!rgb) return null;

	return '#' + [
		Math.max(0, Math.min(255, roundHalfUp(rgb.r * UNIT_DARKEN))),
		Math.max(0, Math.min(255, roundHalfUp(rgb.g * UNIT_DARKEN))),
		Math.max(0, Math.min(255, roundHalfUp(rgb.b * UNIT_DARKEN))),
	].map(v => v.toString(16).padStart(2, '0')).join('');
}

// ── Golden corpus ────────────────────────────────────────────────────────────
// Each entry: input accent hex, expected normalized hex, expected darkened hex.
// Computed by the reference above under the round-half-up canonical. They pin
// the reference spec against accidental change — the real cross-driver check is
// the source drift gate below.
const GOLDEN = [
	// Primary/secondary wheel — each a distinct hue.
	{ input: '#ff0000', norm: '#cc0000', darken: '#660000' },  // red
	{ input: '#ff8800', norm: '#cc6d00', darken: '#663600' },  // orange
	{ input: '#ffcc00', norm: '#cca300', darken: '#665200' },  // yellow
	{ input: '#00cc00', norm: '#00cc00', darken: '#005200' },  // green
	{ input: '#00cccc', norm: '#00cccc', darken: '#005252' },  // cyan
	{ input: '#0066ff', norm: '#0052cc', darken: '#002966' },  // blue
	{ input: '#6600cc', norm: '#6600cc', darken: '#290052' },  // purple
	{ input: '#cc00cc', norm: '#cc00cc', darken: '#520052' },  // magenta

	// Real Ergonis hotstring group colours (from TOML _meta.color).
	{ input: '#0055cc', norm: '#0055cc', darken: '#002252' },  // magickey blue
	{ input: '#7a30b0', norm: '#7600cc', darken: '#311346' },  // AI purple
	{ input: '#ff4444', norm: '#cc0000', darken: '#661b1b' },  // light red

	// Achromatic / grey — normalise returns null (no hue), darken still works.
	{ input: '#888888', norm: null, darken: '#363636' },       // grey
	{ input: '#cccccc', norm: null, darken: '#525252' },       // light grey
	{ input: '#ffffff', norm: null, darken: '#666666' },       // white

	// Edge: case-normalisation (upper/lower/mixed).
	{ input: '#FF8800', norm: '#cc6d00', darken: '#663600' },  // uppercase same as lowercase
	{ input: '#00Cc00', norm: '#00cc00', darken: '#005200' },  // mixed case

	// Real-world accents from tooltip/hotstring colour palettes.
	{ input: '#e74c3c', norm: '#cc1300', darken: '#5c1e18' },  // warm red
	{ input: '#2ecc71', norm: '#00cc57', darken: '#12522d' },  // emerald
	{ input: '#3498db', norm: '#007acc', darken: '#153d58' },  // sky blue
];

// ── Verify golden corpus (reference spec pin) ────────────────────────────────

const errors = [];

for (let i = 0; i < GOLDEN.length; i++) {
	const g = GOLDEN[i];
	const actualNorm = normaliseHex(g.input);
	const actualDark = darkenHex(g.input);

	if (actualNorm !== g.norm) {
		errors.push(
			`Vector[${i}] "${g.input}": expected norm=${g.norm === null ? 'null' : `"${g.norm}"`}, got ` +
			`${actualNorm === null ? 'null' : `"${actualNorm}"`}. Recalculate the golden expected value.`
		);
	}
	if (actualDark !== g.darken) {
		errors.push(
			`Vector[${i}] "${g.input}": expected darken="${g.darken}", got "${actualDark}". ` +
			`Darken formula changed or factor drifted.`
		);
	}
}

// ── Cross-driver SOURCE drift gate (the non-tautological core) ───────────────
// Read the four real driver call sites and assert each implements the canonical
// round-half-up rounding, and sources the darken factor + HSL L/S from the
// shared constants.toml rather than a re-typed literal.

const LUA_WIDGET  = 'static/ergopti_plus/macos/ui/wpm/wpm_widget.lua';
const AHK_WIDGET  = 'static/ergopti_plus/windows/ui/wpm/wpm_widget.ahk';
const AHK_DISPLAY = 'static/ergopti_plus/windows/ui/wpm/wpm_display.ahk';
const AHK_CONFIG  = 'static/ergopti_plus/windows/ui/wpm/wpm_config.ahk';
const SHARED_TOML = 'static/ergopti_plus/_shared/modules/wpm_widget/constants.toml';

function readFile(rel) {
	const p = path.join(ROOT, rel);
	return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null;
}

/**
 * Slice the body of a function: from `startMarker` to the earliest boundary in
 * `endMarkers` that follows it (or a generous cap if none is found). Bounds each
 * function precisely so a long body's rounding is inside the slice and a
 * neighbouring function's rounding never leaks in.
 */
function funcBody(src, startMarker, endMarkers) {
	const i = src.indexOf(startMarker);
	if (i < 0) return null;
	let end = src.length;
	for (const m of endMarkers) {
		const j = src.indexOf(m, i + startMarker.length);
		if (j >= 0 && j < end) end = j;
	}
	return src.slice(i, end);
}

// (1) macOS Lua darken + normalise must round-half-up: floor(x + 0.5).
const luaSrc = readFile(LUA_WIDGET);
if (!luaSrc) {
	errors.push(`missing driver source ${LUA_WIDGET}`);
} else {
	// normalise is defined before darken; bound each to the next 'local function'.
	const normBody = funcBody(luaSrc, 'local function _wpm_normalise_hex', ['local function _wpm_darken_hex']);
	if (!normBody) errors.push('could not locate _wpm_normalise_hex in wpm_widget.lua');
	else if (!normBody.includes('+ 0.5)')) {
		errors.push('Lua _wpm_normalise_hex must round-half-up (math.floor(x + 0.5)).');
	}
	const darkenBody = funcBody(luaSrc, 'local function _wpm_darken_hex', ['\nlocal function ', '\n\n\n']);
	if (!darkenBody) errors.push('could not locate _wpm_darken_hex in wpm_widget.lua');
	else if (!darkenBody.includes('+ 0.5)')) {
		errors.push(
			'Lua _wpm_darken_hex must round-half-up (math.floor(x + 0.5)). A bare ' +
			'math.floor(x) truncates and drifts ±1/255 from the AHK Round() darken.'
		);
	}
	if (!luaSrc.includes('unit_strip_darken_factor')) {
		errors.push('Lua widget must read unit_strip_darken_factor from the shared constants, not a hardcoded 0.40.');
	}
	if (!luaSrc.includes('widget_hsl_l') || !luaSrc.includes('widget_hsl_s')) {
		errors.push('Lua widget must read widget_hsl_l / widget_hsl_s from the shared constants.');
	}
}

// (2) Windows AHK darken must use Round() (round-half-up), matching Lua.
const ahkWidgetSrc = readFile(AHK_WIDGET);
if (!ahkWidgetSrc) {
	errors.push(`missing driver source ${AHK_WIDGET}`);
} else {
	const darkenBody = funcBody(ahkWidgetSrc, '_WPMWidget_DarkenHex(hex)', ['\n}']);
	if (!darkenBody) errors.push('could not locate _WPMWidget_DarkenHex in wpm_widget.ahk');
	else if (!/Round\(/.test(darkenBody)) {
		errors.push(
			'AHK _WPMWidget_DarkenHex must round-half-up (Round(...)). A Floor()/truncation ' +
			'would drift ±1/255 from the Lua darken.'
		);
	}
}

// (3) Windows AHK normalise must use Round() (round-half-up), matching Lua.
const ahkDisplaySrc = readFile(AHK_DISPLAY);
if (!ahkDisplaySrc) {
	errors.push(`missing driver source ${AHK_DISPLAY}`);
} else {
	const normBody = funcBody(ahkDisplaySrc, '_WPMWidget_NormaliseHex(', ['\n}']);
	if (!normBody) errors.push('could not locate _WPMWidget_NormaliseHex in wpm_display.ahk');
	else if (!/Round\(/.test(normBody)) {
		errors.push('AHK _WPMWidget_NormaliseHex must round-half-up (Round(...)).');
	}
}

// (4) Windows AHK config must read the darken factor + HSL target from constants.toml.
const ahkConfigSrc = readFile(AHK_CONFIG);
if (!ahkConfigSrc) {
	errors.push(`missing driver source ${AHK_CONFIG}`);
} else {
	for (const key of ['unit_strip_darken_factor', 'widget_hsl_l', 'widget_hsl_s']) {
		if (!ahkConfigSrc.includes(key)) {
			errors.push(`AHK wpm_config must read ${key} from the shared constants.toml, not a re-typed literal.`);
		}
	}
}

// (5) The shared constants.toml holds the canonical values both drivers consume.
const tomlSrc = readFile(SHARED_TOML);
if (!tomlSrc) {
	errors.push(`missing shared constants ${SHARED_TOML}`);
} else {
	const canon = [
		['unit_strip_darken_factor', UNIT_DARKEN],
		['widget_hsl_l', WIDGET_HSL_L],
		['widget_hsl_s', WIDGET_HSL_S],
	];
	for (const [key, val] of canon) {
		const m = tomlSrc.match(new RegExp('^\\s*' + key + '\\s*=\\s*([0-9.]+)', 'm'));
		if (!m) errors.push(`shared constants.toml is missing ${key}`);
		else if (Math.abs(parseFloat(m[1]) - val) > 1e-9) {
			errors.push(`shared constants.toml ${key}=${m[1]} but the gate canonical is ${val}.`);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] WPM colour normalisation cross-driver drift:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] WPM colour normalisation — ' + GOLDEN.length +
	' golden vectors + both drivers round-half-up on shared constants.\x1b[0m'
);
