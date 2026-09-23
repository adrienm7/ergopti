// tools/test/test-nav-layer-recommended-golden.cjs

/**
 * ==============================================================================
 * MODULE: Recommended Navigation Layer ⇄ Windows Layer (Golden)
 * DESCRIPTION:
 * `_shared/keymap/layers.recommended.toml` is Ergopti's navigation layer as
 * data, and the Windows layer in windows/platform/remap/nav_layer.ahk is its
 * canonical behaviour. This gate reads the AutoHotkey hotkeys directly — every
 * scan code, every Send string, every repeat count — and requires the
 * recommended layer, resolved for Windows through the physical-key registry and
 * the layer vocabulary, to produce exactly the same thing key for key.
 *
 * WHY IT EXISTS:
 * The layer was hand-written three times (AHK hotkeys, Karabiner JSON, kanata
 * deflayer) and the copies drifted: on Linux F2 and F12 swapped, A and F lost
 * Shift, V and CapsLock went transparent, and the shared
 * [tap_hold.layers.nav.mappings] table matched no driver at all. A data preset
 * is only a single source if something proves it equals the layer users have
 * today; until the drivers are generated from it, this is that proof.
 *
 * WHAT IS COMPARED:
 * Each hotkey under `#HotIf LayerEnabled` (and its AltGr-kana twin) becomes a
 * canonical string — keystroke:ctrl+shift+ArrowUp@repeat, repeat_count:3,
 * call:maximize_window — computed from the AHK source alone. The hotkeys under
 * any other condition are the activation special cases (CapsWord through LAlt,
 * the LAlt key-up fix, the swallowed Space); they are listed by name here, so a
 * new condition cannot slip past as "not layer content". The recommended file
 * must also resolve with zero errors on every OS, and its layer ids must be
 * exactly the layers the tap-hold hold picker offers — while the tap-hold
 * defaults bind no layer key of their own.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { loadContext, loadLayers, formatResolution, RECOMMENDED_PATH } = require('../lib/keymap-layers.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const NAV_LAYER_AHK = path.join(SP, 'windows', 'platform', 'remap', 'nav_layer.ahk');
const TAP_HOLD_DEFAULTS = path.join(SP, '_shared', 'tap_hold', 'defaults.toml');

const errors = [];
const fail = (msg) => errors.push(msg);

function report() {
	if (errors.length > 0) {
		console.error('\x1b[31m[FAIL] the recommended navigation layer does not reproduce the Windows layer:\x1b[0m');
		for (const e of errors) console.error('    - ' + e);
		process.exit(1);
	}
}

if (!fs.existsSync(RECOMMENDED_PATH)) {
	fail(`${path.relative(ROOT, RECOMMENDED_PATH)} is missing — the navigation layer exists only as three hand-written copies.`);
	report();
}

const ctx = loadContext();
const keys = ctx.registry.keys;





// ==========================================
// ==========================================
// ======= 1/ Read the AutoHotkey layer =====
// ==========================================
// ==========================================

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

/** Maps an AHK hotkey label to the physical key it fires on. */
function labelToCode(label) {
	// `A & ~B` fires on B; `*`, `~` and `$` are prefix options, not key names.
	const name = label.split('&').pop().trim().replace(/^[*~$]+/, '');
	const hits = Object.keys(keys).filter((code) => {
		const k = keys[code];
		return k.ahk === name || (k.ahk_send && k.ahk_send.toLowerCase() === name.toLowerCase());
	});
	return hits.length === 1 ? hits[0] : null;
}

/** Maps an AHK Send key name to a registry code. */
function sendNameToCode(name) {
	const hits = Object.keys(keys).filter((code) => keys[code].ahk_send && keys[code].ahk_send.toLowerCase() === name.toLowerCase());
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

/** Turns one hotkey body into the canonical behaviour string. */
function bodyToCanonical(body, where) {
	const calls = body.match(/ActionLayer\(/g) || [];
	if (calls.length === 1) {
		const arg = /ActionLayer\(([\s\S]*)\)/.exec(body)[1];
		const collapsed = arg.replace(/"\s*\.\s*AppState_GetNumberOfRepetitions\(\)\s*\.\s*"/g, 'N');
		const literal = /^\s*"([^"]*)"\s*$/.exec(collapsed);
		if (!literal) {
			fail(`${where}: ActionLayer argument is not a string with an optional repeat count: ${arg.trim()}`);
			return null;
		}
		return sendToCanonical(literal[1], where);
	}
	if (calls.length > 1) {
		fail(`${where}: more than one ActionLayer call`);
		return null;
	}
	const rep = /^\s*SetNumberOfRepetitions\((\d+)\)\s*$/.exec(body);
	if (rep) return `repeat_count:${rep[1]}`;
	if (/WinMaximize\("A"\)/.test(body)) return 'call:maximize_window';
	fail(`${where}: unrecognised hotkey body: ${body.trim().slice(0, 80)}`);
	return null;
}

const LAYER_CONDITIONS = new Set(['LayerEnabled', 'LayerEnabled and _ALTGR_KANA_FIXUP']);
// The activation special cases: each is a fix for how a particular hold key
// enters the layer, not a binding of the layer itself.
const SPECIAL_CASES = [
	{ token: '_AnyShortcutEnabled("lalt_caps_lock")', labels: ['SC03A'] },
	{ token: '_LAltIsBackspaceLayer()', labels: ['SC038'] },
	{ token: 'TapHoldHoldLayer(TapHold, "space") == "nav"', labels: ['SC039'] }
];

// AutoHotkey sources carry a UTF-8 BOM; drop it before the first label is read.
const BOM = String.fromCharCode(0xfeff);
const ahkSource = fs.readFileSync(NAV_LAYER_AHK, 'utf8');
const lines = (ahkSource.startsWith(BOM) ? ahkSource.slice(1) : ahkSource).split(/\r?\n/).map(stripComment);
const windowsLayer = new Map();
const specialSeen = new Set();
let condition = null;
let pendingLabels = [];

function record(labels, body, lineNo) {
	const where = `nav_layer.ahk:${lineNo}`;
	if (condition === null) {
		fail(`${where}: hotkey ${labels.join(', ')} outside any #HotIf`);
		return;
	}
	if (!LAYER_CONDITIONS.has(condition)) {
		const special = SPECIAL_CASES.find((s) => condition.includes(s.token));
		if (!special) fail(`${where}: hotkey under an unknown condition "${condition}" — layer content or a new activation fix?`);
		else if (JSON.stringify(labels) !== JSON.stringify(special.labels)) fail(`${where}: the ${special.token} special case now covers ${labels.join(', ')}`);
		else specialSeen.add(special.token);
		return;
	}
	const behaviour = bodyToCanonical(body, where);
	if (behaviour === null) return;
	for (const label of labels) {
		const code = labelToCode(label);
		if (!code) {
			fail(`${where}: hotkey label "${label}" names no registry key`);
			continue;
		}
		if (windowsLayer.has(code) && windowsLayer.get(code) !== behaviour)
			fail(`${where}: ${code} is bound twice with different behaviours (${windowsLayer.get(code)} vs ${behaviour})`);
		windowsLayer.set(code, behaviour);
	}
}

/** Net brace depth change of one line, ignoring braces inside double quotes. */
function braceDelta(line) {
	let inString = false;
	let delta = 0;
	for (const c of line) {
		if (c === '"') inString = !inString;
		else if (!inString && c === '{') delta += 1;
		else if (!inString && c === '}') delta -= 1;
	}
	return delta;
}

/** Reads the block that opens on line `open`; returns [body, index of its last line]. */
function readBlock(open) {
	let depth = braceDelta(lines[open]);
	const body = [];
	let i = open;
	while (depth > 0 && i + 1 < lines.length) {
		const next = lines[++i];
		depth += braceDelta(next);
		if (depth > 0) body.push(next);
	}
	return [body.join('\n'), i];
}

/** Net parenthesis depth change of one line. */
function parenDelta(text) {
	return (text.match(/\(/g) || []).length - (text.match(/\)/g) || []).length;
}

for (let i = 0; i < lines.length; i++) {
	const line = lines[i].trim();
	if (line === '') continue;
	if (line.startsWith('#HotIf')) {
		let text = line.slice('#HotIf'.length);
		let depth = parenDelta(text);
		while (depth > 0 && i + 1 < lines.length) {
			const next = lines[++i];
			text += ' ' + next;
			depth += parenDelta(next);
		}
		text = text.replace(/\s+/g, ' ').trim().replace(/^\((.*)\)$/, '$1').trim();
		condition = text === '' ? null : text;
		continue;
	}
	// A lone brace opens the body shared by the stacked labels above it.
	if (line === '{' && pendingLabels.length > 0) {
		const [body, last] = readBlock(i);
		record(pendingLabels, body, i + 1);
		pendingLabels = [];
		i = last;
		continue;
	}
	const hot = /^([^\s"(][^"]*?)::(.*)$/.exec(line);
	if (!hot) continue;
	pendingLabels.push(hot[1].trim());
	const rest = hot[2].trim();
	// `Label::` alone stacks onto the next hotkey or brace.
	if (rest === '') continue;
	if (rest === '{') {
		const [body, last] = readBlock(i);
		record(pendingLabels, body, i + 1);
		i = last;
	} else {
		record(pendingLabels, rest, i + 1);
	}
	pendingLabels = [];
}

for (const s of SPECIAL_CASES) if (!specialSeen.has(s.token)) fail(`the ${s.token} special case was not found — the parser or the file changed`);
// Floor: the layer binds the letters, the number row, CapsLock, AltRight and the
// wheel. A parser that stopped matching would otherwise compare nothing.
if (windowsLayer.size < 40) fail(`only ${windowsLayer.size} Windows layer bindings read from nav_layer.ahk (floor 40)`);





// ==========================================
// ==========================================
// ======= 2/ Compare with the preset =======
// ==========================================
// ==========================================

const recommendedText = fs.readFileSync(RECOMMENDED_PATH, 'utf8');
const perOs = {};
for (const os of ctx.platforms) {
	const r = loadLayers(recommendedText, os, ctx);
	perOs[os] = r;
	for (const e of r.errors) fail(`layers.recommended.toml on ${os}: ${e.code} ${e.layer || ''}.${e.section || ''}.${e.key || ''} — ${e.detail}`);
}

const nav = (perOs.windows.layers || {}).nav || {};
const recommended = new Map(Object.entries(nav).map(([code, r]) => [code, formatResolution(r)]));
for (const [code, behaviour] of windowsLayer) {
	if (!recommended.has(code)) fail(`${code}: Windows does ${behaviour}, the recommended layer leaves it unbound`);
	else if (recommended.get(code) !== behaviour) fail(`${code}: Windows does ${behaviour}, the recommended layer does ${recommended.get(code)}`);
}
for (const [code, behaviour] of recommended) {
	if (!windowsLayer.has(code)) fail(`${code}: the recommended layer does ${behaviour} on Windows, nav_layer.ahk does not bind it`);
}

// The hold picker offers exactly the layers the preset defines, and the
// tap-hold defaults bind no layer key themselves: a second table of layer
// bindings is how [tap_hold.layers.nav.mappings] came to match no driver.
const tapHold = TOML.parse(fs.readFileSync(TAP_HOLD_DEFAULTS, 'utf8')).tap_hold || {};
const pickerLayers = [...((tapHold.hold_picker || {}).layers || [])].sort();
if (tapHold.layers !== undefined)
	fail('_shared/tap_hold/defaults.toml declares [tap_hold.layers.*]: layer bindings live in _shared/keymap/layers.recommended.toml, and a second copy matches no driver');
const presetLayers = Object.keys(perOs.windows.layers || {}).sort();
if (pickerLayers.length === 0) fail('[tap_hold.hold_picker].layers could not be read from _shared/tap_hold/defaults.toml');
if (JSON.stringify(pickerLayers) !== JSON.stringify(presetLayers))
	fail(`the hold picker offers layers ${JSON.stringify(pickerLayers)} but the recommended file defines ${JSON.stringify(presetLayers)}`);

report();
console.log(
	`\x1b[32m[OK] the recommended navigation layer reproduces all ${windowsLayer.size} Windows bindings and resolves cleanly on ` +
		`${ctx.platforms.join(', ')}.\x1b[0m`
);
