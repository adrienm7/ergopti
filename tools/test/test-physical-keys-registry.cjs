// tools/test/test-physical-keys-registry.cjs

/**
 * ==============================================================================
 * MODULE: Physical-Key Registry Completeness and Parity
 * DESCRIPTION:
 * `_shared/data/keycodes/physical_keys.json` names every key, mouse button and
 * wheel direction a layer can bind by its W3C KeyboardEvent.code, and records
 * the identifier each driver uses for that physical position: the AutoHotkey
 * scan code, the Linux evdev code, the macOS virtual keycode, the
 * Karabiner-Elements event and the kanata name.
 *
 * WHY IT EXISTS:
 * Physical-key identity used to be spread over five hand-kept tables (heatmap
 * KEY_POSITIONS, AHK SCnnn literals, evdev.json, Karabiner key_code strings in
 * layer_keys.json, now frozen as legacy_layer_keys.json, kanata names in
 * kanata.kbd, plus SC_TO_KC in heatmap_win.js).
 * Nothing tied them together, so a navigation layer written three times drifted
 * three ways. The registry is the one table a generated layer can be resolved
 * through, and it is only worth that if every column is right.
 *
 * WHAT IS CHECKED:
 * 1. Completeness: every record carries every driver column with the type its
 *    kind requires, and keyboard keys carry ANSI and ISO geometry.
 * 2. Uniqueness: no two records share a driver code on the same form factor,
 *    so a code resolves back to exactly one position.
 * 3. Geometry: no two keys overlap and every alphanumeric row spans the same
 *    width on both form factors.
 * 4. Parity with every existing hand copy, each an independent oracle written
 *    before the registry: evdev.json, linux/infra/evdev_codes.lua,
 *    _shared/lua/keycodes/init.lua, azerty.json, heatmap_win.js SC_TO_KC, the
 *    Karabiner legacy_layer_keys.json and the native tap-hold input keys. Each scan is
 *    floored so a parser that stops matching cannot pass over nothing.
 * 5. HID usages (hid_usages.json, beside the registry and read only by the macOS
 *    codegen): every key carries exactly one USB HID usage, no two keys share
 *    one, each agrees with the USB HID Usage Tables, and a raw usage resolves to
 *    the macOS keycode of its form with the ISO swap of 0x35 and 0x64 only.
 *    Aliases (Non-US # on Backslash) and the unregistered keys (F13 to F20,
 *    keypad =, the JIS keys) agree with the same tables and with macOS keycodes.
 *    The registry itself carries no HID column: Windows parses it at boot.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const REGISTRY = path.join(SP, '_shared', 'data', 'keycodes', 'physical_keys.json');
const HID_USAGES = path.join(SP, '_shared', 'data', 'keycodes', 'hid_usages.json');

const errors = [];
const fail = (msg) => errors.push(msg);

// The US-QWERTY legend of each character key, from the W3C code definitions. It
// is the independent oracle the character tables below are compared through.
function usLegend(code) {
	let m = /^Key([A-Z])$/.exec(code);
	if (m) return m[1].toLowerCase();
	m = /^Digit([0-9])$/.exec(code);
	if (m) return m[1];
	return {
		Backquote: '`',
		Minus: '-',
		Equal: '=',
		BracketLeft: '[',
		BracketRight: ']',
		Backslash: '\\',
		Semicolon: ';',
		Quote: "'",
		Comma: ',',
		Period: '.',
		Slash: '/',
		Space: ' '
	}[code];
}

function report() {
	if (errors.length > 0) {
		console.error(
			'\x1b[31m[FAIL] the physical-key registry is incomplete or disagrees with a hand copy:\x1b[0m'
		);
		for (const e of errors) console.error('    - ' + e);
		process.exit(1);
	}
}

// =====================================
// =====================================
// ======= 1/ Load and shape ===========
// =====================================
// =====================================

if (!fs.existsSync(REGISTRY)) {
	fail(
		`${path.relative(ROOT, REGISTRY)} is missing — there is no canonical physical-key registry.`
	);
	report();
}

const registry = JSON.parse(fs.readFileSync(REGISTRY, 'utf8'));
const keys = registry.keys || {};
const codes = Object.keys(keys);

if (registry.schema_version !== 1)
	fail(`schema_version must be 1, found ${JSON.stringify(registry.schema_version)}`);
if (JSON.stringify(registry.forms) !== JSON.stringify(['ansi', 'iso']))
	fail('forms must be ["ansi", "iso"]');

const byKind = { key: [], mouse_button: [], wheel: [] };
for (const code of codes) {
	const k = keys[code];
	if (!byKind[k.kind]) {
		fail(`${code}: unknown kind ${JSON.stringify(k.kind)}`);
		continue;
	}
	byKind[k.kind].push(code);
}
// Floors: a main block, a navigation cluster and a keypad are ~100 keys; five
// mouse buttons and four wheel directions are the pseudo-keys the editor offers.
if (byKind.key.length < 100) fail(`only ${byKind.key.length} keyboard keys (floor 100)`);
if (byKind.mouse_button.length !== 5)
	fail(`expected 5 mouse buttons, found ${byKind.mouse_button.length}`);
if (byKind.wheel.length !== 4) fail(`expected 4 wheel directions, found ${byKind.wheel.length}`);

const GROUPS = {
	key: ['function', 'alphanumeric', 'navigation', 'numpad', 'media'],
	mouse_button: ['mouse'],
	wheel: ['wheel']
};
const KEYBOARD_GROUPS = new Set(['function', 'alphanumeric', 'navigation', 'numpad']);

const isInt = (v) => Number.isInteger(v);

// USB HID usage pages a registry key may sit on, and the largest usage of each.
const HID_PAGE_KEYBOARD = 7;
const HID_PAGE_CONSUMER = 12;
const HID_USAGE_MAX = { [HID_PAGE_KEYBOARD]: 0xff, [HID_PAGE_CONSUMER]: 0xffff };
const karabinerEvent = (v, allowed) =>
	v &&
	typeof v === 'object' &&
	Object.keys(v).length === 1 &&
	allowed.includes(Object.keys(v)[0]) &&
	typeof Object.values(v)[0] === 'string' &&
	Object.values(v)[0] !== '';

for (const code of codes) {
	const k = keys[code];
	if (!/^[A-Z][A-Za-z0-9]*$/.test(code))
		fail(`${code}: not a KeyboardEvent.code-shaped identifier`);
	// Every driver parses this file (Windows at boot, whenever a layers.toml
	// exists), so macOS-only HID data lives in hid_usages.json instead.
	if (k.hid !== undefined)
		fail(`${code}: the registry carries no hid column — HID usages belong in hid_usages.json`);
	if (!GROUPS[k.kind] || !GROUPS[k.kind].includes(k.group))
		fail(`${code}: group ${JSON.stringify(k.group)} is not valid for kind ${k.kind}`);
	if (typeof k.kanata !== 'string' || k.kanata === '' || /[\s()@]/.test(k.kanata))
		fail(`${code}: kanata name ${JSON.stringify(k.kanata)} is not a bare kanata key name`);
	if (k.kind === 'key') {
		if (!/^SC[0-9A-F]{3}$/.test(k.ahk))
			fail(`${code}: ahk must be an SCnnn scan code, found ${JSON.stringify(k.ahk)}`);
		if (
			!(
				k.ahk_send === null ||
				(typeof k.ahk_send === 'string' && /^[A-Za-z_0-9]+$/.test(k.ahk_send))
			)
		)
			fail(`${code}: ahk_send must be null or an AutoHotkey key name`);
		if (!isInt(k.evdev) || k.evdev < 1 || k.evdev > 255)
			fail(`${code}: evdev must be a KEY_* code, found ${k.evdev}`);
		if (!isInt(k.hs) || k.hs < 0 || k.hs > 127)
			fail(`${code}: hs must be a kVK_* keycode, found ${k.hs}`);
		if (!karabinerEvent(k.karabiner, ['key_code', 'consumer_key_code']))
			fail(`${code}: karabiner must be one {key_code} or {consumer_key_code} event`);
		// A character key sent by name would press whatever the active layout puts
		// under that character — the whole point of a physical registry.
		if (usLegend(code) !== undefined && code !== 'Space' && k.ahk_send !== null)
			fail(`${code}: a character key must not carry an ahk_send name (Send it by scan code)`);
	} else if (k.kind === 'mouse_button') {
		if (!/^(L|R|M|X)Button[12]?$/.test(k.ahk))
			fail(`${code}: ahk must be an AutoHotkey mouse button name`);
		if (!isInt(k.evdev) || k.evdev < 272 || k.evdev > 276)
			fail(`${code}: evdev must be a BTN_* code`);
		if (!isInt(k.hs) || k.hs < 0 || k.hs > 4) fail(`${code}: hs must be an NSEvent button number`);
		if (!karabinerEvent(k.karabiner, ['pointing_button']))
			fail(`${code}: karabiner must be one {pointing_button} event`);
	} else if (k.kind === 'wheel') {
		if (!/^Wheel(Up|Down|Left|Right)$/.test(k.ahk))
			fail(`${code}: ahk must be an AutoHotkey wheel name`);
		if (k.evdev !== null || k.hs !== null || k.karabiner !== null)
			fail(`${code}: a wheel direction has no evdev, hs or karabiner key code`);
		if (!['vertical', 'horizontal'].includes(k.axis) || ![1, -1].includes(k.direction))
			fail(`${code}: axis/direction malformed`);
	}
	const hasGeometry = k.geometry !== undefined;
	if (KEYBOARD_GROUPS.has(k.group) !== hasGeometry)
		fail(
			`${code}: ${hasGeometry ? 'has' : 'lacks'} geometry, but group ${k.group} ${hasGeometry ? 'draws none' : 'is drawn on the board'}`
		);
	if (hasGeometry) {
		for (const [form, g] of Object.entries(k.geometry)) {
			if (!registry.forms.includes(form)) fail(`${code}: geometry for unknown form ${form}`);
			if (!isInt(g.row) || typeof g.col !== 'number' || typeof g.width !== 'number' || g.width <= 0)
				fail(`${code}.${form}: row/col/width malformed`);
		}
		// Only IntlBackslash is absent from an ANSI board.
		const expected = code === 'IntlBackslash' ? ['iso'] : ['ansi', 'iso'];
		if (JSON.stringify(Object.keys(k.geometry).sort()) !== JSON.stringify(expected))
			fail(
				`${code}: geometry forms ${JSON.stringify(Object.keys(k.geometry))}, expected ${JSON.stringify(expected)}`
			);
	}
}

// =====================================
// =====================================
// ======= 2/ Per-driver uniqueness ====
// =====================================
// =====================================

// macOS reports the key left of 1 and the key left of Z swapped on an ISO board.
// The override must be exactly that swap, on exactly those two keys.
const isoOverrides = codes.filter((c) => keys[c].macos_iso !== undefined).sort();
if (JSON.stringify(isoOverrides) !== JSON.stringify(['Backquote', 'IntlBackslash'])) {
	fail(
		`macos_iso overrides must exist on Backquote and IntlBackslash only, found ${JSON.stringify(isoOverrides)}`
	);
} else {
	const bq = keys.Backquote;
	const ib = keys.IntlBackslash;
	if (bq.macos_iso.hs !== ib.hs || ib.macos_iso.hs !== bq.hs)
		fail('macos_iso.hs is not a swap of Backquote and IntlBackslash');
	if (
		JSON.stringify(bq.macos_iso.karabiner) !== JSON.stringify(ib.karabiner) ||
		JSON.stringify(ib.macos_iso.karabiner) !== JSON.stringify(bq.karabiner)
	)
		fail('macos_iso.karabiner is not a swap of Backquote and IntlBackslash');
}

/** The value a driver column resolves to on one form factor. */
function resolved(code, driver, form) {
	const k = keys[code];
	if (form === 'iso' && k.macos_iso && k.macos_iso[driver] !== undefined)
		return k.macos_iso[driver];
	return k[driver];
}
/** True when the key exists on that form (keys without geometry exist on every form). */
function onForm(code, form) {
	const g = keys[code].geometry;
	return g === undefined || g[form] !== undefined;
}

for (const form of registry.forms) {
	for (const driver of ['ahk', 'ahk_send', 'evdev', 'hs', 'karabiner', 'kanata']) {
		const seen = new Map();
		for (const code of codes) {
			if (!onForm(code, form)) continue;
			const value = resolved(code, driver, form);
			if (value === null || value === undefined) continue;
			// Mouse-button numbers share a small integer range with keycodes; they are
			// a different event type, so uniqueness is per kind.
			const id = keys[code].kind + ':' + JSON.stringify(value);
			if (seen.has(id))
				fail(`${form}/${driver}: ${code} and ${seen.get(id)} share ${JSON.stringify(value)}`);
			else seen.set(id, code);
		}
	}
}

// =====================================
// =====================================
// ======= 3/ Geometry =================
// =====================================
// =====================================

for (const form of registry.forms) {
	// row -> list of [start, end, code]; tall keys also occupy the next row.
	const rows = new Map();
	for (const code of codes) {
		const g = keys[code].geometry && keys[code].geometry[form];
		if (!g) continue;
		for (let r = g.row; r < g.row + (g.height || 1); r++) {
			if (!rows.has(r)) rows.set(r, []);
			// The ISO Enter is an L: its lower row is narrower than its top row.
			const lower = r > g.row && g.bottom_col !== undefined;
			const col = lower ? g.bottom_col : g.col;
			const width = lower ? g.bottom_width : g.width;
			rows.get(r).push([col, col + width, code, keys[code].group]);
		}
	}
	for (const [row, spans] of rows) {
		spans.sort((a, b) => a[0] - b[0]);
		for (let i = 1; i < spans.length; i++) {
			if (spans[i][0] < spans[i - 1][1] - 1e-9)
				fail(`${form} row ${row}: ${spans[i - 1][2]} overlaps ${spans[i][2]}`);
		}
		// The main block is 15 units wide on both boards and has no gap in it.
		if (row >= 1 && row <= 5) {
			const main = spans.filter((s) => s[3] === 'alphanumeric');
			let edge = 0;
			for (const s of main) {
				if (Math.abs(s[0] - edge) > 1e-9)
					fail(`${form} row ${row}: gap or overlap before ${s[2]} (at ${s[0]}, expected ${edge})`);
				edge = s[1];
			}
			if (Math.abs(edge - 15) > 1e-9)
				fail(`${form} row ${row}: the main block ends at ${edge}, expected 15`);
		}
	}
}

// =====================================
// =====================================
// ======= 4/ Parity with hand copies ==
// =====================================
// =====================================

const read = (rel) => fs.readFileSync(path.join(SP, rel), 'utf8');
const find = (pred) => codes.filter((c) => pred(keys[c]));

// --- 4.1 evdev.json: evdev code -> US character.
{
	const evdev = JSON.parse(read('_shared/data/keycodes/evdev.json'));
	let n = 0;
	for (const [num, ch] of Object.entries(evdev.layouts.qwerty.unshifted)) {
		const hit = find((k) => k.kind === 'key' && k.evdev === Number(num));
		if (hit.length !== 1 || usLegend(hit[0]) !== ch)
			fail(`evdev.json: code ${num} is "${ch}" but the registry says ${JSON.stringify(hit)}`);
		n++;
	}
	if (n < 45) fail(`evdev.json: only ${n} codes compared (floor 45)`);
}

// --- 4.2 linux/infra/evdev_codes.lua: named kernel codes.
{
	const src = read('linux/infra/evdev_codes.lua');
	const NAMED = {
		LEFTSHIFT: 'ShiftLeft',
		RIGHTSHIFT: 'ShiftRight',
		LEFTCTRL: 'ControlLeft',
		RIGHTCTRL: 'ControlRight',
		LEFTALT: 'AltLeft',
		RIGHTALT: 'AltRight',
		LEFTMETA: 'MetaLeft',
		RIGHTMETA: 'MetaRight',
		CAPSLOCK: 'CapsLock',
		BACKSPACE: 'Backspace',
		TAB: 'Tab',
		ENTER: 'Enter',
		ESC: 'Escape',
		UP: 'ArrowUp',
		DOWN: 'ArrowDown',
		LEFT: 'ArrowLeft',
		RIGHT: 'ArrowRight'
	};
	const consts = {};
	for (const m of src.matchAll(/^M\.KEY_([A-Z]+)\s*=\s*(\d+)/gm)) consts[m[1]] = Number(m[2]);
	let n = 0;
	for (const [name, num] of Object.entries(consts)) {
		const code = NAMED[name];
		if (!code)
			fail(`evdev_codes.lua: KEY_${name} has no expected registry key — extend this test's table`);
		else if (keys[code].evdev !== num)
			fail(
				`evdev_codes.lua: KEY_${name} = ${num} but registry ${code}.evdev = ${keys[code].evdev}`
			);
		n++;
	}
	const CONTROL = {
		enter: ['Enter', 'NumpadEnter'],
		escape: ['Escape'],
		backspace: ['Backspace'],
		tab: ['Tab'],
		up: ['ArrowUp'],
		down: ['ArrowDown'],
		left: ['ArrowLeft'],
		right: ['ArrowRight'],
		home: ['Home'],
		end: ['End'],
		pageup: ['PageUp'],
		pagedown: ['PageDown'],
		insert: ['Insert'],
		delete: ['Delete']
	};
	for (let i = 1; i <= 12; i++) CONTROL['f' + i] = ['F' + i];
	const block = (src.match(/M\.CONTROL_NAME_OF = \{([\s\S]*?)\n\}/) || [])[1] || '';
	for (const m of block.matchAll(/\[(?:(\d+)|M\.KEY_([A-Z]+))\]\s*=\s*"(\w+)"/g)) {
		const num = m[1] !== undefined ? Number(m[1]) : consts[m[2]];
		const hit = find((k) => k.kind === 'key' && k.evdev === num);
		const allowed = CONTROL[m[3]] || [];
		if (hit.length !== 1 || !allowed.includes(hit[0]))
			fail(`evdev_codes.lua: [${num}] = "${m[3]}" but the registry says ${JSON.stringify(hit)}`);
		n++;
	}
	if (n < 35) fail(`evdev_codes.lua: only ${n} codes compared (floor 35)`);
}

// --- 4.3 _shared/lua/keycodes/init.lua: macOS keycodes named in code.
{
	const src = read('_shared/lua/keycodes/init.lua');
	const NAMED = {
		BACKSPACE: 'Backspace',
		RETURN: 'Enter',
		ESCAPE: 'Escape',
		TAB: 'Tab',
		ENTER: 'NumpadEnter',
		LEFT_ARROW: 'ArrowLeft',
		RIGHT_ARROW: 'ArrowRight',
		DOWN_ARROW: 'ArrowDown',
		UP_ARROW: 'ArrowUp'
	};
	let n = 0;
	for (const m of src.matchAll(/^M\.([A-Z_]+)\s*=\s*(\d+)/gm)) {
		if (!NAMED[m[1]]) continue;
		if (keys[NAMED[m[1]]].hs !== Number(m[2]))
			fail(
				`keycodes/init.lua: ${m[1]} = ${m[2]} but registry ${NAMED[m[1]]}.hs = ${keys[NAMED[m[1]]].hs}`
			);
		n++;
	}
	if (n !== Object.keys(NAMED).length)
		fail(`keycodes/init.lua: compared ${n} of ${Object.keys(NAMED).length} named keycodes`);
}

// --- 4.4 azerty.json: the heatmap's Apple ISO keycodes.
{
	const azerty = JSON.parse(read('_shared/data/keycodes/azerty.json'));
	const NAMED = {
		return: 'Enter',
		space: 'Space',
		iso_extra: 'IntlBackslash',
		backspace: 'Backspace',
		escape: 'Escape',
		cmd_r: 'MetaRight',
		cmd_l: 'MetaLeft',
		shift_l: 'ShiftLeft',
		shift_r: 'ShiftRight',
		capslock: 'CapsLock',
		alt_l: 'AltLeft',
		alt_r: 'AltRight',
		ctrl_l: 'ControlLeft',
		left: 'ArrowLeft',
		right: 'ArrowRight',
		up: 'ArrowUp',
		down: 'ArrowDown'
	};
	for (let i = 1; i <= 12; i++) NAMED['f' + i] = 'F' + i;
	// fn is a macOS-only modifier the OS sees; it has no KeyboardEvent.code a
	// layer could bind, so the registry does not carry it.
	const NOT_IN_REGISTRY = new Set(['fn']);
	let n = 0;
	for (const entry of azerty.keys) {
		if (NOT_IN_REGISTRY.has(entry.qwerty)) continue;
		const code = NAMED[entry.qwerty] || codes.find((c) => usLegend(c) === entry.qwerty);
		if (!code) {
			fail(`azerty.json: kc ${entry.kc} (${entry.qwerty}) matches no registry key`);
			continue;
		}
		if (resolved(code, 'hs', 'iso') !== entry.kc)
			fail(
				`azerty.json: kc ${entry.kc} is ${entry.qwerty} but registry ${code} resolves to ${resolved(code, 'hs', 'iso')} on ISO`
			);
		n++;
	}
	if (n < 70) fail(`azerty.json: only ${n} keycodes compared (floor 70)`);
}

// --- 4.5 heatmap_win.js SC_TO_KC: PC scan code -> macOS ISO keycode.
{
	const src = read('_shared/ui/metrics_typing/heatmap_win.js');
	const block = (src.match(/const SC_TO_KC = \{([\s\S]*?)\n\};/) || [])[1] || '';
	// Entries the heatmap maps elsewhere on purpose: modifier slots reuse the
	// macOS geometry (Ctrl -> fn slot, Alt -> Cmd slot, AltGr -> right Cmd slot),
	// and 72/75/77/80 are the bare (non-extended) arrow scan codes, which are the
	// keypad codes. The rest are Windows aliases no registry key carries.
	const DELIBERATE = new Set([29, 56, 312, 72, 75, 77, 80]);
	const ALIASES = new Set([91, 92, 93, 200, 203, 205, 208]);
	let n = 0;
	const unmatched = [];
	for (const m of block.replace(/\/\/[^\n]*/g, '').matchAll(/(\d+):\s*(\d+)/g)) {
		const sc = Number(m[1]);
		const kc = Number(m[2]);
		const hit = find((k) => k.kind === 'key' && parseInt(k.ahk.slice(2), 16) === sc);
		if (hit.length === 0) {
			unmatched.push(sc);
			continue;
		}
		if (DELIBERATE.has(sc)) continue;
		if (resolved(hit[0], 'hs', 'iso') !== kc)
			fail(
				`heatmap_win.js: SC ${sc} -> kc ${kc} but registry ${hit[0]} resolves to ${resolved(hit[0], 'hs', 'iso')} on ISO`
			);
		n++;
	}
	if (
		JSON.stringify(unmatched.sort((a, b) => a - b)) !==
		JSON.stringify([...ALIASES].sort((a, b) => a - b))
	)
		fail(
			`heatmap_win.js: scan codes with no registry key ${JSON.stringify(unmatched)}, expected exactly the aliases ${JSON.stringify([...ALIASES])}`
		);
	if (n < 55) fail(`heatmap_win.js: only ${n} scan codes compared (floor 55)`);
}

// --- 4.6 macOS legacy_layer_keys.json: every Karabiner key_code the hand-written
// layer used. The file was written on an Apple ISO board, so it resolves through
// macos_iso.
{
	const layer = JSON.parse(read('macos/platform/remap/data/legacy_layer_keys.json'));
	const names = new Set();
	for (const m of layer.manipulators) {
		names.add(m.from.key_code);
		for (const field of ['to', 'to_if_alone', 'to_after_key_up'])
			for (const ev of m[field] || []) if (ev.key_code) names.add(ev.key_code);
	}
	for (const name of names) {
		const hit = codes.filter((c) => {
			const ev = resolved(c, 'karabiner', 'iso');
			return ev && ev.key_code === name;
		});
		if (hit.length !== 1)
			fail(`legacy_layer_keys.json: key_code "${name}" resolves to ${JSON.stringify(hit)} on ISO`);
	}
	if (names.size < 40)
		fail(`legacy_layer_keys.json: only ${names.size} key codes compared (floor 40)`);
}

// --- 4.7 The daemon's tap-hold input keys use the same physical identities.
{
	const src = read('linux/platform/remap/tap_hold_engine.lua');
	const block = (src.match(/M\.KEY_CODES\s*=\s*\{([\s\S]*?)\}/) || [])[1];
	if (!block) fail('native tap-hold engine: KEY_CODES table is missing');
	const physical = {
		escape: 'Escape',
		tab: 'Tab',
		caps_lock: 'CapsLock',
		left_shift: 'ShiftLeft',
		left_ctrl: 'ControlLeft',
		win: 'MetaLeft',
		left_alt: 'AltLeft',
		space: 'Space',
		alt_gr: 'AltRight',
		right_ctrl: 'ControlRight',
		right_shift: 'ShiftRight',
		enter: 'Enter',
		backspace: 'Backspace',
		delete: 'Delete'
	};
	const seen = new Set();
	for (const [, id, raw] of (block || '').matchAll(/(\w+)\s*=\s*(\d+)/g)) {
		const code = physical[id];
		if (!code || registry.keys[code]?.evdev !== Number(raw))
			fail('native tap-hold key disagrees with registry: ' + id);
		if (seen.has(id)) fail('duplicate native tap-hold key: ' + id);
		seen.add(id);
	}
	for (const id of Object.keys(physical))
		if (!seen.has(id)) fail('native tap-hold key was not compared: ' + id);
}

// =====================================
// =====================================
// ======= 5/ HID usages ===============
// =====================================
// =====================================

const hidUsages = fs.existsSync(HID_USAGES) ? JSON.parse(fs.readFileSync(HID_USAGES, 'utf8')) : {};
if (hidUsages.schema_version !== 1)
	fail(
		`hid_usages.json: schema_version must be 1, found ${JSON.stringify(hidUsages.schema_version)}`
	);
const hidKeys = hidUsages.keys || {};
const hidOf = (code) => hidKeys[code];

// --- 5.1 Shape: every entry names a registry key and one usage on the page its
// group implies; a media key is a Consumer-page usage, exactly as its Karabiner
// event says, and every other key sits on the Keyboard/Keypad page.
for (const [code, hid] of Object.entries(hidKeys)) {
	const k = keys[code];
	if (!k || k.kind !== 'key') {
		fail(`hid_usages.json: ${code} is not a keyboard key of the registry`);
		continue;
	}
	const page = k.group === 'media' ? HID_PAGE_CONSUMER : HID_PAGE_KEYBOARD;
	const fields = hid && typeof hid === 'object' ? Object.keys(hid).sort() : [];
	const shape = JSON.stringify(fields.filter((f) => f !== 'aliases'));
	if (shape !== '["page","usage"]')
		fail(`hid_usages.json: ${code} must be one {page, usage} object with optional aliases`);
	else if (hid.page !== page)
		fail(`hid_usages.json: ${code} page must be ${page} for group ${k.group}, found ${hid.page}`);
	else if (!isInt(hid.usage) || hid.usage < 1 || hid.usage > HID_USAGE_MAX[page])
		fail(`hid_usages.json: ${code} usage ${hid.usage} is outside page ${page}`);
	if (k.karabiner && 'consumer_key_code' in k.karabiner !== (page === HID_PAGE_CONSUMER))
		fail(`hid_usages.json: ${code}: the Karabiner event and the hid page disagree on the page`);
	const aliases = hid && hid.aliases;
	if (aliases !== undefined && (!Array.isArray(aliases) || aliases.length === 0))
		fail(`hid_usages.json: ${code}: aliases must be a non-empty array when present`);
	for (const alias of aliases || []) {
		const aliasPage = alias && alias.page;
		if (
			!alias ||
			JSON.stringify(Object.keys(alias).sort()) !== '["page","usage"]' ||
			HID_USAGE_MAX[aliasPage] === undefined ||
			!isInt(alias.usage) ||
			alias.usage < 1 ||
			alias.usage > HID_USAGE_MAX[aliasPage]
		)
			fail(`hid_usages.json: ${code}: alias ${JSON.stringify(alias)} is not a key-page usage`);
	}
}

// Keys real keyboards send that no layer can bind: named like registry keys but
// absent from it, each with the macOS keycode macOS reports for its usage.
const unregistered = hidUsages.unregistered || {};
for (const [code, entry] of Object.entries(unregistered)) {
	if (!/^[A-Z][A-Za-z0-9]*$/.test(code))
		fail(`hid_usages.json: unregistered ${code} is not a KeyboardEvent.code-shaped identifier`);
	if (keys[code] !== undefined)
		fail(`hid_usages.json: ${code} is a registry key; list its usage under keys instead`);
	if (
		!entry ||
		JSON.stringify(Object.keys(entry).sort()) !== '["hs","page","usage"]' ||
		entry.page !== HID_PAGE_KEYBOARD ||
		!isInt(entry.usage) ||
		entry.usage < 1 ||
		entry.usage > HID_USAGE_MAX[HID_PAGE_KEYBOARD] ||
		!isInt(entry.hs) ||
		entry.hs < 0 ||
		entry.hs > 127
	)
		fail(`hid_usages.json: unregistered ${code} must be {page: 7, usage, hs: kVK}`);
}

// --- 5.2 Total and unique: one usage per key, one key per usage.
{
	const seen = new Map();
	const claim = (code, hid) => {
		const id = hid.page + ':' + hid.usage;
		if (seen.has(id)) fail(`hid: ${code} and ${seen.get(id)} share usage ${id}`);
		else seen.set(id, code);
	};
	let main = 0;
	for (const code of byKind.key) {
		const hid = hidOf(code);
		if (!hid) continue;
		claim(code, hid);
		main++;
		for (const alias of hid.aliases || []) claim(code, alias);
	}
	for (const [code, entry] of Object.entries(unregistered)) claim(code, entry);
	if (main !== byKind.key.length)
		fail(`hid: ${main} keys of ${byKind.key.length} have a usage — the mapping is not total`);
}

// --- 5.3 The USB HID Usage Tables 1.21 (section 10, Keyboard/Keypad page, and
// section 15, Consumer page) are the oracle: each W3C code names the position
// its usage is defined at.
{
	const HUT = {};
	'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('').forEach((l, i) => (HUT['Key' + l] = [7, 0x04 + i]));
	'123456789'.split('').forEach((d, i) => (HUT['Digit' + d] = [7, 0x1e + i]));
	for (let i = 1; i <= 12; i++) HUT['F' + i] = [7, 0x39 + i];
	'123456789'.split('').forEach((d, i) => (HUT['Numpad' + d] = [7, 0x59 + i]));
	Object.assign(HUT, {
		Digit0: [7, 0x27],
		Enter: [7, 0x28],
		Escape: [7, 0x29],
		Backspace: [7, 0x2a],
		Tab: [7, 0x2b],
		Space: [7, 0x2c],
		Minus: [7, 0x2d],
		Equal: [7, 0x2e],
		BracketLeft: [7, 0x2f],
		BracketRight: [7, 0x30],
		Backslash: [7, 0x31],
		Semicolon: [7, 0x33],
		Quote: [7, 0x34],
		Backquote: [7, 0x35],
		Comma: [7, 0x36],
		Period: [7, 0x37],
		Slash: [7, 0x38],
		CapsLock: [7, 0x39],
		Insert: [7, 0x49],
		Home: [7, 0x4a],
		PageUp: [7, 0x4b],
		Delete: [7, 0x4c],
		End: [7, 0x4d],
		PageDown: [7, 0x4e],
		ArrowRight: [7, 0x4f],
		ArrowLeft: [7, 0x50],
		ArrowDown: [7, 0x51],
		ArrowUp: [7, 0x52],
		NumLock: [7, 0x53],
		NumpadDivide: [7, 0x54],
		NumpadMultiply: [7, 0x55],
		NumpadSubtract: [7, 0x56],
		NumpadAdd: [7, 0x57],
		NumpadEnter: [7, 0x58],
		Numpad0: [7, 0x62],
		NumpadDecimal: [7, 0x63],
		IntlBackslash: [7, 0x64],
		ContextMenu: [7, 0x65],
		ControlLeft: [7, 0xe0],
		ShiftLeft: [7, 0xe1],
		AltLeft: [7, 0xe2],
		MetaLeft: [7, 0xe3],
		ControlRight: [7, 0xe4],
		ShiftRight: [7, 0xe5],
		AltRight: [7, 0xe6],
		MetaRight: [7, 0xe7],
		AudioVolumeMute: [12, 0xe2],
		AudioVolumeUp: [12, 0xe9],
		AudioVolumeDown: [12, 0xea]
	});
	let n = 0;
	for (const code of byKind.key) {
		const hid = hidOf(code);
		const expected = HUT[code];
		if (!expected) {
			fail(`hid: ${code} has no entry in this test's USB HID usage oracle — extend the table`);
			continue;
		}
		if (!hid || hid.page !== expected[0] || hid.usage !== expected[1])
			fail(
				`hid: ${code} is ${JSON.stringify(hid)} but the HID usage tables define ${expected[0]}:0x${expected[1].toString(16)}`
			);
		n++;
	}
	if (n < 100) fail(`hid: only ${n} usages compared (floor 100)`);
}

// --- 5.4 A raw usage resolves to the macOS keycode of its position on the
// device's form. macOS swaps the keycodes of 0x35 (left of 1) and 0x64 (left of
// Z) on an ISO keyboard, and no other usage depends on the form.
{
	const kcOf = (page, usage, form) => {
		const code = byKind.key.find(
			(c) => hidOf(c) && hidOf(c).page === page && hidOf(c).usage === usage
		);
		return code === undefined ? undefined : resolved(code, 'hs', form);
	};
	const expected = [
		['ansi', 0x35, 50],
		['ansi', 0x64, 10],
		['iso', 0x35, 10],
		['iso', 0x64, 50]
	];
	for (const [form, usage, kc] of expected) {
		const got = kcOf(HID_PAGE_KEYBOARD, usage, form);
		if (got !== kc)
			fail(`hid: usage 0x${usage.toString(16)} on ${form} resolves to ${got}, expected ${kc}`);
	}
	const formDependent = byKind.key
		.filter((c) => resolved(c, 'hs', 'ansi') !== resolved(c, 'hs', 'iso'))
		.map((c) => hidOf(c) && hidOf(c).usage)
		.sort((a, b) => a - b);
	if (JSON.stringify(formDependent) !== JSON.stringify([0x35, 0x64]))
		fail(`hid: the form-dependent usages are ${JSON.stringify(formDependent)}, expected [53, 100]`);
}

// --- 5.5 Aliases and unregistered keys against the HID usage tables and the
// macOS keycodes (HIToolbox kVK_*) macOS reports for them. A PC keyboard's
// PrintScreen, ScrollLock and Pause are F13, F14 and F15 on macOS, and the
// function keys past F12 agree with the sentinel keycodes keycodes/init.lua names.
{
	const ALIASES = {
		Backslash: [[7, 0x32]],
		AudioVolumeMute: [[7, 0x7f]],
		AudioVolumeUp: [[7, 0x80]],
		AudioVolumeDown: [[7, 0x81]]
	};
	for (const code of byKind.key) {
		const got = ((hidOf(code) || {}).aliases || []).map((a) => [a.page, a.usage]);
		if (JSON.stringify(got) !== JSON.stringify(ALIASES[code] || []))
			fail(
				`hid: ${code} aliases are ${JSON.stringify(got)}, expected ${JSON.stringify(ALIASES[code] || [])}`
			);
	}
	const fKeys = {};
	for (const m of read('_shared/lua/keycodes/init.lua').matchAll(/^M\.F(\d+)_\w+\s*=\s*(\d+)/gm))
		fKeys['F' + m[1]] = Number(m[2]);
	const UNREGISTERED = {
		PrintScreen: [0x46, fKeys.F13],
		ScrollLock: [0x47, fKeys.F14],
		Pause: [0x48, fKeys.F15],
		NumpadEqual: [0x67, 81],
		NumpadComma: [0x85, 95],
		IntlRo: [0x87, 94],
		IntlYen: [0x89, 93],
		Lang1: [0x90, 104],
		Lang2: [0x91, 102]
	};
	for (let i = 13; i <= 20; i++) UNREGISTERED['F' + i] = [0x68 + i - 13, fKeys['F' + i]];
	for (const [code, [usage, hs]] of Object.entries(UNREGISTERED)) {
		const entry = unregistered[code];
		if (!isInt(hs)) fail(`hid: no macOS keycode known for ${code} (keycodes/init.lua)`);
		else if (!entry || entry.usage !== usage || entry.hs !== hs)
			fail(
				`hid: unregistered ${code} is ${JSON.stringify(entry)}, expected usage 0x${usage.toString(16)} and kVK ${hs}`
			);
	}
	for (const code of Object.keys(unregistered))
		if (!UNREGISTERED[code])
			fail(`hid: unregistered ${code} is not in this test's oracle — extend it`);
}

// --- 5.6 fn/globe has no registry position, so the macOS keycode it resolves to
// is the shared keycodes constant, which must be the heatmap's fn keycode.
{
	const src = read('_shared/lua/keycodes/init.lua');
	const fnConst = /^M\.FUNCTION\s*=\s*(\d+)/m.exec(src);
	const azerty = JSON.parse(read('_shared/data/keycodes/azerty.json'));
	const fnHeatmap = azerty.keys.find((entry) => entry.qwerty === 'fn');
	if (!fnConst) fail('keycodes/init.lua: M.FUNCTION (the fn/globe keycode) is missing');
	else if (!fnHeatmap || fnHeatmap.kc !== Number(fnConst[1]))
		fail(
			`keycodes/init.lua: FUNCTION = ${fnConst[1]} but the heatmap's fn keycode is ${fnHeatmap && fnHeatmap.kc}`
		);
}

report();
console.log(
	`\x1b[32m[OK] ${codes.length} physical keys (${byKind.key.length} keys, ${byKind.mouse_button.length} mouse buttons, ` +
		`${byKind.wheel.length} wheel directions) are complete, unique per driver and agree with every hand copy.\x1b[0m`
);
