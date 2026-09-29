// tools/test/test-nav-layer-recommended-golden.cjs

/**
 * ==============================================================================
 * MODULE: Recommended Navigation Layer ⇄ Windows Layer (Golden)
 * DESCRIPTION:
 * `_shared/keymap/layers.recommended.toml` is Ergopti's navigation layer as
 * data, and the Windows layer that used to be written by hand in
 * windows/platform/remap/nav_layer.ahk is its canonical behaviour. That layer
 * is frozen, hotkey by hotkey, in windows/tests/fixtures/nav_layer_golden.json;
 * this gate requires the recommended layer, resolved for Windows through the
 * physical-key registry and the layer vocabulary, to produce exactly the same
 * thing key for key — and nav_layer.ahk to hold no binding of its own again.
 *
 * WHY IT EXISTS:
 * The layer was hand-written three times (AHK hotkeys, Karabiner JSON, kanata
 * deflayer) and the copies drifted: on Linux F2 and F12 swapped, A and F lost
 * Shift, V and CapsLock went transparent, and the shared
 * [tap_hold.layers.nav.mappings] table matched no driver at all. Every driver
 * now generates its layer from layer files; this gate proves the preset still
 * equals the layer Windows users had, and the AHK suite
 * (tests/unit/test_nav_layer_table.ahk) proves the Windows table built from it
 * registers exactly the frozen hotkeys.
 *
 * WHAT IS COMPARED:
 * Each golden row becomes a canonical string — keystroke:ctrl+shift+ArrowUp@repeat,
 * repeat_count:3, call:maximize_window — computed from its Send string alone.
 * nav_layer.ahk may only hold the activation special cases (CapsWord through
 * LAlt, the LAlt key-up fix, the swallowed Space); they are listed by name here,
 * so a hand-written binding cannot come back under another condition, and it
 * must call NavLayer_Init with the configuration folder once at boot. The
 * recommended file must also resolve with zero errors on every OS, and its layer
 * ids must be exactly the layers the tap-hold hold picker offers — while the
 * tap-hold defaults bind no layer key of their own.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const {
	loadContext,
	loadLayers,
	formatResolution,
	RECOMMENDED_PATH
} = require('../lib/keymap-layers.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const NAV_LAYER_AHK = path.join(SP, 'windows', 'platform', 'remap', 'nav_layer.ahk');
const GOLDEN_PATH = path.join(SP, 'windows', 'tests', 'fixtures', 'nav_layer_golden.json');
const TAP_HOLD_DEFAULTS = path.join(SP, '_shared', 'tap_hold', 'defaults.toml');

// Floor: the hand-written layer bound 46 keys through 48 hotkeys. A fixture that
// stopped being read would otherwise compare nothing.
const MIN_GOLDEN_KEYS = 40;

const errors = [];
const fail = (msg) => errors.push(msg);

function report() {
	if (errors.length > 0) {
		console.error(
			'\x1b[31m[FAIL] the recommended navigation layer does not reproduce the Windows layer:\x1b[0m'
		);
		for (const e of errors) console.error('    - ' + e);
		process.exit(1);
	}
}

for (const [label, file] of [
	['the recommended layer', RECOMMENDED_PATH],
	['the frozen Windows layer', GOLDEN_PATH],
	['nav_layer.ahk', NAV_LAYER_AHK]
]) {
	if (!fs.existsSync(file)) fail(`${path.relative(ROOT, file)} (${label}) is missing`);
}
report();

const ctx = loadContext();
const keys = ctx.registry.keys;

// ==========================================
// ==========================================
// ======= 1/ Read the frozen layer =========
// ==========================================
// ==========================================

/** Maps an AHK hotkey label to the physical key it fires on. */
function labelToCode(label) {
	// `A & ~B` fires on B; `*`, `~` and `$` are prefix options, not key names.
	const name = label
		.split('&')
		.pop()
		.trim()
		.replace(/^[*~$]+/, '');
	const hits = Object.keys(keys).filter((code) => {
		const k = keys[code];
		return k.ahk === name || (k.ahk_send && k.ahk_send.toLowerCase() === name.toLowerCase());
	});
	return hits.length === 1 ? hits[0] : null;
}

/** Maps an AHK Send key name to a registry code. */
function sendNameToCode(name) {
	const hits = Object.keys(keys).filter(
		(code) => keys[code].ahk_send && keys[code].ahk_send.toLowerCase() === name.toLowerCase()
	);
	return hits.length === 1 ? hits[0] : null;
}

const MOD_OF = { '^': 'ctrl', '!': 'alt', '+': 'shift', '#': 'meta' };
const MOD_ORDER = ctx.vocabulary._meta.modifier_order;

/** Turns an ActionLayer Send string into the canonical keystroke form. */
function sendToCanonical(send, where) {
	const chords = [];
	let repeat = false;
	let i = 0;
	while (i < send.length) {
		const mods = new Set();
		while (MOD_OF[send[i]]) mods.add(MOD_OF[send[i++]]);
		const m = /^\{([A-Za-z0-9_]+)( N)?\}/.exec(send.slice(i));
		if (!m) {
			fail(`${where}: cannot read Send string "${send}" at "${send.slice(i)}"`);
			return null;
		}
		const code = sendNameToCode(m[1]);
		if (!code) {
			fail(`${where}: Send key "${m[1]}" has no registry entry with that ahk_send name`);
			return null;
		}
		chords.push([...MOD_ORDER.filter((x) => mods.has(x)), code].join('+'));
		i += m[0].length;
		if (m[2]) {
			// The repeat count can only multiply the last chord of a sequence.
			if (i < send.length) {
				fail(`${where}: the repeat count applies to a chord that is not the last one in "${send}"`);
				return null;
			}
			repeat = true;
		}
	}
	return 'keystroke:' + chords.join(',') + (repeat ? '@repeat' : '');
}

/** Turns one golden action into the canonical behaviour string. */
function actionToCanonical(action, where) {
	if (action.startsWith('send:')) return sendToCanonical(action.slice(5), where);
	if (/^repeat_count:\d+$/.test(action) || /^call:[a-z_]+$/.test(action) || action === 'none')
		return action;
	fail(`${where}: unrecognised golden action "${action}"`);
	return null;
}

const CRITERIA = new Set(['layer', 'layer_kana']);
const golden = JSON.parse(fs.readFileSync(GOLDEN_PATH, 'utf8'));
const windowsLayer = new Map();
for (const [index, row] of (Array.isArray(golden.rows) ? golden.rows : []).entries()) {
	const where = `nav_layer_golden.json row ${index + 1} (${row.hotkey})`;
	if (!CRITERIA.has(row.criterion))
		fail(`${where}: criterion "${row.criterion}" is not ${[...CRITERIA].join(' or ')}`);
	const behaviour = actionToCanonical(String(row.action), where);
	if (behaviour === null) continue;
	const code = labelToCode(String(row.hotkey));
	if (!code) {
		fail(`${where}: hotkey label names no registry key`);
		continue;
	}
	if (windowsLayer.has(code) && windowsLayer.get(code) !== behaviour)
		fail(
			`${where}: ${code} is bound twice with different behaviours (${windowsLayer.get(code)} vs ${behaviour})`
		);
	windowsLayer.set(code, behaviour);
}
if (windowsLayer.size < MIN_GOLDEN_KEYS)
	fail(
		`only ${windowsLayer.size} keys read from the frozen Windows layer (floor ${MIN_GOLDEN_KEYS})`
	);

// ===============================================
// ===============================================
// ======= 2/ nav_layer.ahk binds nothing ========
// ===============================================
// ===============================================

/** Drops `;` comments outside double-quoted strings (AHK needs a blank before an inline one). */
function stripComment(line) {
	let inString = false;
	for (let i = 0; i < line.length; i++) {
		const c = line[i];
		if (c === '"') inString = !inString;
		if (!inString && c === ';' && (i === 0 || /\s/.test(line[i - 1]))) return line.slice(0, i);
	}
	return line;
}

/** Net parenthesis depth change of one line. */
function parenDelta(text) {
	return (text.match(/\(/g) || []).length - (text.match(/\)/g) || []).length;
}

// The activation special cases: each fixes how a particular hold key enters the
// layer; none is a binding of the layer itself.
const SPECIAL_CASES = [
	{ token: '_AnyShortcutEnabled("lalt_caps_lock")', label: '*SC03A' },
	{ token: '_LAltIsBackspaceLayer()', label: '*SC038' }
];

// AutoHotkey sources carry a UTF-8 BOM; drop it before the first label is read.
const BOM = String.fromCharCode(0xfeff);
const ahkSource = fs.readFileSync(NAV_LAYER_AHK, 'utf8');
const lines = (ahkSource.startsWith(BOM) ? ahkSource.slice(1) : ahkSource)
	.split(/\r?\n/)
	.map(stripComment);
const specialSeen = new Set();
let condition = null;
let hotkeys = 0;
for (let i = 0; i < lines.length; i++) {
	const line = lines[i].trim();
	if (line.startsWith('#HotIf')) {
		let text = line.slice('#HotIf'.length);
		let depth = parenDelta(text);
		while (depth > 0 && i + 1 < lines.length) {
			const next = lines[++i];
			text += ' ' + next;
			depth += parenDelta(next);
		}
		condition = text.replace(/\s+/g, ' ').trim();
		continue;
	}
	const hot = /^([^\s"(][^"]*?)::/.exec(line);
	if (!hot) continue;
	hotkeys += 1;
	const label = hot[1].trim();
	const special = SPECIAL_CASES.find((s) => condition && condition.includes(s.token));
	if (!special)
		fail(
			`nav_layer.ahk:${i + 1}: hotkey ${label} under "${condition || 'no condition'}" — the layer's bindings live in layers.toml now`
		);
	else if (label !== special.label)
		fail(`nav_layer.ahk:${i + 1}: the ${special.token} special case now covers ${label}`);
	else specialSeen.add(special.token);
}
for (const s of SPECIAL_CASES)
	if (!specialSeen.has(s.token))
		fail(
			`the ${s.token} special case was not found in nav_layer.ahk — the parser or the file changed`
		);
if (hotkeys !== SPECIAL_CASES.length)
	fail(
		`nav_layer.ahk declares ${hotkeys} hotkey(s); only the ${SPECIAL_CASES.length} activation fixes belong there`
	);

// The table is registered at boot from the root of the configuration folder,
// where layers.toml lives on every OS. Without this one top-level call the
// Windows layer binds nothing while every table test stays green.
const INIT_CALL = 'NavLayer_Init(_SharedDir, _ConfigDir)';
const initCalls = lines.filter((line) => line.trimEnd() === INIT_CALL).length;
if (initCalls !== 1)
	fail(`nav_layer.ahk must call ${INIT_CALL} once at the top level, found ${initCalls}`);

// ==========================================
// ==========================================
// ======= 3/ Compare with the preset =======
// ==========================================
// ==========================================

const recommendedText = fs.readFileSync(RECOMMENDED_PATH, 'utf8');
const perOs = {};
for (const os of ctx.platforms) {
	const r = loadLayers(recommendedText, os, ctx);
	perOs[os] = r;
	for (const e of r.errors)
		fail(
			`layers.recommended.toml on ${os}: ${e.code} ${e.layer || ''}.${e.section || ''}.${e.key || ''} — ${e.detail}`
		);
}

const nav = (perOs.windows.layers || {}).nav || {};
const recommended = new Map(Object.entries(nav).map(([code, r]) => [code, formatResolution(r)]));
for (const [code, behaviour] of windowsLayer) {
	if (!recommended.has(code))
		fail(`${code}: Windows did ${behaviour}, the recommended layer leaves it unbound`);
	else if (recommended.get(code) !== behaviour)
		fail(`${code}: Windows did ${behaviour}, the recommended layer does ${recommended.get(code)}`);
}
for (const [code, behaviour] of recommended) {
	if (!windowsLayer.has(code))
		fail(
			`${code}: the recommended layer does ${behaviour} on Windows, the hand-written layer did not bind it`
		);
}

// The hold picker offers exactly the layers the preset defines, and the
// tap-hold defaults bind no layer key themselves: a second table of layer
// bindings is how [tap_hold.layers.nav.mappings] came to match no driver.
const tapHold = TOML.parse(fs.readFileSync(TAP_HOLD_DEFAULTS, 'utf8')).tap_hold || {};
const pickerLayers = [...((tapHold.hold_picker || {}).layers || [])].sort();
if (tapHold.layers !== undefined)
	fail(
		'_shared/tap_hold/defaults.toml declares [tap_hold.layers.*]: layer bindings live in _shared/keymap/layers.recommended.toml, and a second copy matches no driver'
	);
const presetLayers = Object.keys(perOs.windows.layers || {}).sort();
if (pickerLayers.length === 0)
	fail('[tap_hold.hold_picker].layers could not be read from _shared/tap_hold/defaults.toml');
if (JSON.stringify(pickerLayers) !== JSON.stringify(presetLayers))
	fail(
		`the hold picker offers layers ${JSON.stringify(pickerLayers)} but the recommended file defines ${JSON.stringify(presetLayers)}`
	);

report();
console.log(
	`\x1b[32m[OK] the recommended navigation layer reproduces all ${windowsLayer.size} frozen Windows bindings, nav_layer.ahk holds only ` +
		`the ${SPECIAL_CASES.length} activation fixes, and the preset resolves cleanly on ${ctx.platforms.join(', ')}.\x1b[0m`
);
