// tools/test/test-wpm-color-normalisation-single-source.cjs

/**
 * ==============================================================================
 * MODULE: WPM Strip Darkening Cross-Driver Drift Gate
 * DESCRIPTION:
 * The pill's unit strip is its background with each RGB channel multiplied by
 * the canon's unit_strip_darken_factor, rounded half up. The darkening exists
 * twice: once in the shared Lua model (_shared/lua/wpm_widget/model.lua,
 * which macOS and Linux draw with) and once in AHK (Windows
 * ui/wpm/wpm_widget.ahk). Linux used to keep (1 - factor) of each channel — a
 * lighter strip than the other two — and each driver used to carry its own
 * copy.
 *
 * WHAT THIS GATE CHECKS:
 *   1. A golden corpus pins the reference computation, with the factor read
 *      from the canon rather than restated.
 *   2. The two real implementations multiply by the factor itself (never by
 *      1 - factor), round half up (floor(x + 0.5) in Lua, Round() in AHK), and
 *      take the factor from the canon.
 *   3. No other Lua readout keeps a darkening of its own.
 * The HSL re-projection this gate once also pinned was dead code on both
 * drivers and is gone.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

function read(rel) {
	return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

const canon = read('static/ergopti_plus/_shared/modules/wpm_widget/constants.toml');
const factorMatch = canon.match(/^unit_strip_darken_factor\s*=\s*([\d.]+)/m);
const errors = [];
if (!factorMatch) {
	console.error('\x1b[31m[ERROR] the canon has no unit_strip_darken_factor.\x1b[0m');
	process.exit(1);
}
const FACTOR = Number(factorMatch[1]);

/** Round half up, as floor(x + 0.5) in Lua and Round() in AHK for x >= 0. */
function roundHalfUp(x) {
	return Math.floor(x + 0.5);
}

/** The reference darkening. */
function darkenHex(hex, factor) {
	const m = /^#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/.exec(hex);
	if (!m) return null;
	return '#' + m.slice(1).map((c) => roundHalfUp(parseInt(c, 16) * factor).toString(16).padStart(2, '0')).join('');
}

// ── Golden corpus, at the canon's factor (0.40 when this was written) ────────
const GOLDEN = [
	{ input: '#0055cc', darken: '#002252' },  // manual blue
	{ input: '#7a30b0', darken: '#311346' },  // AI purple
	{ input: '#ff8800', darken: '#663600' },  // orange
	{ input: '#ffffff', darken: '#666666' },  // white
	{ input: '#3498db', darken: '#153d58' },  // sky blue
	{ input: '#FF8800', darken: '#663600' },  // case does not matter
];
if (FACTOR !== 0.40) {
	console.log(`\x1b[33m[SKIP] golden corpus written for 0.40, canon says ${FACTOR}: recompute it.\x1b[0m`);
} else {
	for (const g of GOLDEN) {
		const got = darkenHex(g.input, FACTOR);
		if (got !== g.darken) errors.push(`darken("${g.input}") = ${got}, expected ${g.darken}`);
	}
}
if (darkenHex('#fff', FACTOR) !== null) errors.push('a shorthand colour must be refused, not darkened');

// ── The two real implementations ─────────────────────────────────────────────
const model = read('static/ergopti_plus/_shared/lua/wpm_widget/model.lua');
const luaStart = model.indexOf('function M.darken_hex(');
const luaBody = luaStart === -1 ? '' : model.slice(luaStart, model.indexOf('\nend\n', luaStart));
if (!luaBody) errors.push('model.lua has no darken_hex');
if (!/\* factor \+ 0\.5\)/.test(luaBody)) errors.push('model.lua darken_hex must compute floor(channel * factor + 0.5)');
if (/1 - /.test(luaBody)) errors.push('model.lua darken_hex must multiply by the factor, not by 1 - factor');
if (!model.includes('M.darken_hex(background, c.unit_strip_darken_factor)')) errors.push('model.lua must darken the strip by the canon\'s [compact] factor');

const ahk = read('static/ergopti_plus/windows/ui/wpm/wpm_widget.ahk');
const ahkStart = ahk.indexOf('_WPMWidget_DarkenHex(hex) {');
const ahkBody = ahkStart === -1 ? '' : ahk.slice(ahkStart, ahk.indexOf('\n}\n', ahkStart));
if (!ahkBody) errors.push('wpm_widget.ahk has no _WPMWidget_DarkenHex');
if (!ahkBody.includes('f := WPMWidgetConst.UNIT_DARKEN')) errors.push('_WPMWidget_DarkenHex must take the canon factor');
if ((ahkBody.match(/Round\(Integer\("0x" \. SubStr\(hex, \d, 2\)\) \* f\)/g) || []).length !== 3) {
	errors.push('_WPMWidget_DarkenHex must Round(channel * f) on each of the three channels');
}
if (!read('static/ergopti_plus/windows/ui/wpm/wpm_config.ahk')
	.includes('_WPMWidget_Need(wpm_c, "compact", "unit_strip_darken_factor"')) {
	errors.push('the AHK loader must read unit_strip_darken_factor from the canon');
}

// ── No private copies left in the Lua readouts ───────────────────────────────
for (const rel of ['static/ergopti_plus/macos/ui/wpm/wpm_widget.lua', 'static/ergopti_plus/linux/ui/wpm/widget.lua',
	'static/ergopti_plus/linux/adapters/wpm_surface.lua']) {
	if (/local function [_a-z]*darken/.test(read(rel))) errors.push(`${rel} keeps a darkening of its own`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] the WPM strip darkening drifted:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] WPM strip darkening: one Lua and one AHK implementation, both × the canon factor, round-half-up.\x1b[0m');
