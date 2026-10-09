// tools/test/test-hardening-c-ahk-scan-code-precedence.cjs

/**
 * ==============================================================================
 * MODULE: AHK Scan-Code Precedence Guard (hardening-c-ahk-scan-code-precedence)
 * DESCRIPTION:
 * Once any hotkey names a physical key by its scan code (`SC00F::`,
 * `*$SC00F::`, `SC01D & SC138::`), AutoHotkey's hook resolves that key through
 * its scan code only: ChangeHookState sets sc_takes_precedence and
 * LowLevelCommon looks up the scan-code record alone, letting the key through
 * when none of its variants is eligible. A hotkey that names the same key by
 * its name or virtual key (`Tab::`, `^Tab`, `vk09`, `Tab Up`) then never
 * fires, eligible scan-code variant or not.
 *
 * The rule holds for character keys too, whatever the layout puts on them:
 * the AltGr layer registers `SC138 & SCnnn` for every character key in every
 * emulation state, so each is resolved by scan code. A hotkey the hook owns
 * that names a character (`~^v`, `$^x`, `^y` under #HotIf or #InputLevel 2)
 * never fires from the physical key. A plain, global `^!+i::` at #InputLevel 0
 * is a RegisterHotKey hotkey instead (hotkey.cpp: HK_NORMAL unless `~ $ *`,
 * `< >`, `Up`, `&`, a criterion without a global variant, an input level or
 * #UseHook requires the hook): the OS matches its virtual key once the hook
 * lets the key through, so it fires on the key typing that character.
 *
 * ROOT CAUSE ENCODED (incidents of 2026-09-30):
 * The AI prediction's `Tab::` accept was dead from the day remap/tab.ahk
 * declared SC00F. Tab accepted only inside the Tab tap-hold; the switch to
 * neutral defaults (tap-holds off) exposed it, and Tab went to the application
 * instead of accepting the prediction (45704357d). The same class hid the
 * AltGr tap-hold behind `RAlt::` (altgr-single-identity-2026-09-25), and the
 * keylogger's `~^v` paste hotkey never fired, the layout's `^SC02F` and the
 * AltGr layer holding every V key: the paste is now observed on the
 * HookDispatcher InputHook, which no hotkey precedence reaches.
 *
 * FEATURES & RATIONALE:
 * 1. Mirrors windows/tests/meta/test_hardening_c_scan_code_shadows_key_name.ahk
 *    so the class fails on Linux and macOS before the Windows lane runs: the
 *    AutoHotkey suite cannot run outside Windows.
 * 2. Names are resolved from the physical-key registry
 *    (_shared/data/keycodes/physical_keys.json: `ahk_send` → `ahk`), plus the
 *    AutoHotkey aliases and the fixed Windows virtual-key codes of those
 *    layout-independent keys. A character key (a one-character name or its
 *    virtual key) is any registry key without a fixed name; the AltGr rows of
 *    the emulation golden fixture prove every one of them is declared by scan
 *    code, and a key that stops being so fails the guard instead of passing.
 * 3. Static labels, literal Hotkey() calls and literal-array prefix loops are scanned, with
 *    comments removed, and a floor on each count keeps the scan honest.
 *    #InputLevel, #HotIf and #UseHook are positional across #Include, so the
 *    context of each static label is read by walking the include graph of
 *    each script at the driver root (ErgoptiPlus.ahk) in parse order. A
 *    literal Hotkey() call runs under a HotIf context no source scan knows, so
 *    it counts as a hook hotkey.
 * 4. A self-check replays the pre-fix shapes (`Tab::` beside `SC00F::`, the
 *    `~^v` registration) and clean shapes through the same scanner.
 * 5. `--root <dir>` scans another checkout's copy of the Windows tree.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const rootArg = process.argv.indexOf('--root');
const ROOT =
	rootArg > 0 ? path.resolve(process.argv[rootArg + 1]) : path.resolve(__dirname, '..', '..');
const REGISTRY_ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const GOLDEN = path.join(WINDOWS, 'tests', 'fixtures', 'ergopti_emulation_golden.json');
const REGISTRY = path.join(
	REGISTRY_ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'data',
	'keycodes',
	'physical_keys.json'
);

// AutoHotkey spellings of the registry's `ahk_send` names (Keys.htm of the
// shipped help), lowercased: alias -> registry name.
const AHK_ALIASES = {
	esc: 'escape',
	bs: 'backspace',
	del: 'delete',
	ins: 'insert',
	return: 'enter',
	lcontrol: 'lctrl',
	rcontrol: 'rctrl'
};

// Fixed Windows virtual-key codes (WinUser.h) of the layout-independent keys
// the registry names, so a `vk09::` is resolved like `Tab::`.
const VK_NAMES = {
	'08': 'backspace',
	'09': 'tab',
	'0d': 'enter',
	14: 'capslock',
	'1b': 'escape',
	20: 'space',
	21: 'pgup',
	22: 'pgdn',
	23: 'end',
	24: 'home',
	25: 'left',
	26: 'up',
	27: 'right',
	28: 'down',
	'2d': 'insert',
	'2e': 'delete',
	'5b': 'lwin',
	'5c': 'rwin',
	'5d': 'appskey',
	a0: 'lshift',
	a1: 'rshift',
	a2: 'lctrl',
	a3: 'rctrl',
	a4: 'lalt',
	a5: 'ralt'
};

// Windows virtual-key ranges (WinUser.h) that name characters: digits,
// letters and the OEM punctuation keys the active layout assigns.
const CHARACTER_VK_RANGES = [
	[0x30, 0x39],
	[0x41, 0x5a],
	[0xba, 0xc0],
	[0xdb, 0xdf],
	[0xe2, 0xe2]
];

// The AltGr levels of the emulation, which RegisterAltGrLayer registers as
// `SC138 & SCnnn` whatever the emulation state (only their criteria vary).
const ALTGR_LEVELS = ['altgr_rows', 'altgr_number_row', 'altgr_plus'];

/** Lowercased key name -> SCnnn, from the physical-key registry. */
function nameTable() {
	const registry = JSON.parse(fs.readFileSync(REGISTRY, 'utf8'));
	const table = new Map();
	for (const record of Object.values(registry.keys)) {
		if (record.kind !== 'key' || !record.ahk_send || !/^SC[0-9A-F]{3}$/.test(record.ahk)) continue;
		table.set(record.ahk_send.toLowerCase(), record.ahk);
	}
	for (const [alias, name] of Object.entries(AHK_ALIASES)) {
		if (table.has(name)) table.set(alias, table.get(name));
	}
	for (const [vk, name] of Object.entries(VK_NAMES)) {
		if (!table.has(name)) throw new Error(`VK table names ${name}, which the registry lacks`);
		table.set(`vk${vk}`, table.get(name));
	}
	return table;
}

/** SCnnn -> registry code of every character key: a key with no fixed name. */
function characterKeys() {
	const registry = JSON.parse(fs.readFileSync(REGISTRY, 'utf8'));
	const keys = new Map();
	for (const [code, record] of Object.entries(registry.keys)) {
		if (record.kind !== 'key' || record.ahk_send || !/^SC[0-9A-F]{3}$/.test(record.ahk)) continue;
		keys.set(record.ahk, code);
	}
	return keys;
}

/** Whether a declaration's key names a character: one character, or its VK. */
function isCharacterKey(key) {
	if (key.length === 1) return true;
	const vk = key.match(/^vk([0-9a-f]{2})$/);
	if (!vk) return false;
	const code = parseInt(vk[1], 16);
	return CHARACTER_VK_RANGES.some(([low, high]) => code >= low && code <= high);
}

/** Every .ahk file of the driver, tests, vendor and generated code excluded. */
function driverFiles(dir, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (['tests', 'vendor', '_generated'].includes(entry.name)) continue;
			driverFiles(full, out);
		} else if (entry.name.endsWith('.ahk')) {
			out.push(full);
		}
	}
	return out;
}

/**
 * Removes block comments (a line opening with slash-star up to its closing
 * star-slash) and `;` comments (a semicolon at a line start or after
 * whitespace, outside a string). Strings stay, since Hotkey() names are strings.
 */
function stripComments(src) {
	const out = [];
	let inBlock = false;
	for (const raw of src.replace(/^﻿/, '').split('\n')) {
		const line = raw.replace(/\r$/, '');
		if (inBlock) {
			if (/^\s*\*\//.test(line) || line.includes('*/')) inBlock = false;
			out.push('');
			continue;
		}
		if (/^\s*\/\*/.test(line)) {
			inBlock = !line.includes('*/');
			out.push('');
			continue;
		}
		let quote = null;
		let cut = line.length;
		for (let i = 0; i < line.length; i++) {
			const c = line[i];
			if (quote) {
				if (c === '`') i++;
				else if (c === quote) quote = null;
			} else if (c === '"' || c === "'") {
				quote = c;
			} else if (c === ';' && (i === 0 || /\s/.test(line[i - 1]))) {
				cut = i;
				break;
			}
		}
		out.push(line.slice(0, cut));
	}
	return out.join('\n');
}

const LABEL =
	/^[ \t]*([~*$#!^+<>]*[A-Za-z][A-Za-z0-9_]*(?:[ \t]*&[ \t]*~?[A-Za-z][A-Za-z0-9_]*)?(?:[ \t]+up)?)[ \t]*::/gim;
const CALL = /Hotkey\(\s*(?:[A-Za-z_]\w*\(\s*)?(["'])([^"']*)\1(?=\s*[,)])/g;

/**
 * Resolve the bounded form used by passthrough registrations: a literal key
 * array and a loop concatenating a literal modifier prefix with each key.
 * Do not claim to evaluate arbitrary AutoHotkey expressions.
 */
function arrayLoopDeclarations(code, file) {
	const arrays = new Map();
	for (const m of code.matchAll(/^global\s+(\w+)\s*:=\s*\[([^\]]*)\]/gm)) {
		const tokens = m[2]
			.split(',')
			.map((token) => token.trim())
			.filter(Boolean);
		const keys = tokens.map((token) => token.match(/^(["'])([A-Za-z][A-Za-z0-9_]*)\1$/));
		if (keys.length && keys.every(Boolean))
			arrays.set(
				m[1],
				keys.map((key) => key[2])
			);
	}
	const loops =
		/for\s+(\w+)\s+in\s+(\w+)\s*\{\s*Hotkey(?:\w*\.Call)?\(\s*(["'])([~*$#!^+<>]*)\3\s*\.\s*\1\s*,/g;
	const found = [];
	for (const m of code.matchAll(loops)) {
		for (const key of arrays.get(m[2]) || []) {
			found.push({
				text: m[4] + key,
				file,
				line: code.slice(0, m.index).split('\n').length,
				kind: 'computed'
			});
		}
	}
	return found;
}

/** Every hotkey declaration of one comment-free source: static and Hotkey(). */
function declarations(code, file) {
	const found = [];
	for (const m of code.matchAll(LABEL)) {
		found.push({
			text: m[1],
			file,
			line: code.slice(0, m.index).split('\n').length,
			kind: 'label'
		});
	}
	for (const m of code.matchAll(CALL)) {
		found.push({ text: m[2], file, line: code.slice(0, m.index).split('\n').length, kind: 'call' });
	}
	return found.concat(arrayLoopDeclarations(code, file));
}

/** The key names one declaration hooks: both keys of a combination. */
function keysOf(text) {
	return text.split('&').map((part) =>
		part
			.trim()
			.replace(/\s+up$/i, '')
			.replace(/^[~*$#!^+<>]+/, '')
			.trim()
			.toLowerCase()
	);
}

/**
 * Splits declarations into the scan codes that take precedence and the
 * name/VK uses of a key, resolved to its scan code.
 */
function analyse(decls, names) {
	const scanCodes = new Map();
	const named = [];
	for (const d of decls) {
		for (const key of keysOf(d.text)) {
			const sc = key.match(/^sc([0-9a-f]{3})$/);
			if (sc) {
				const id = `SC${sc[1].toUpperCase()}`;
				if (!scanCodes.has(id)) scanCodes.set(id, d);
			} else if (names.has(key)) {
				named.push({ ...d, key, sc: names.get(key) });
			}
		}
	}
	const offenders = named.filter((n) => scanCodes.has(n.sc));
	return { scanCodes, named, offenders };
}

/**
 * Resolves one #Include argument (after its `*i`) as AutoHotkey v2 does: a
 * relative path from the including file's directory (or the last directory an
 * #Include named), %A_ScriptDir% as the entry's directory. Library and other
 * variable paths resolve to null.
 */
function resolveInclude(arg, dir, file) {
	if (arg.startsWith('<')) return null;
	const expanded = arg
		.replace(/%A_ScriptDir%/gi, WINDOWS)
		.replace(/%A_LineFile%/gi, file)
		.replace(/\\/g, '/');
	if (expanded.includes('%')) return null;
	return path.resolve(dir, expanded);
}

/**
 * Applies one comment-free line to the positional directive state, visiting
 * an #Include target in place, as AutoHotkey parses it.
 */
function applyDirective(line, state, cursor, visit) {
	let m;
	if ((m = line.match(/^\s*#InputLevel\b\s*(\d*)/i))) state.level = m[1] ? Number(m[1]) : 0;
	else if ((m = line.match(/^\s*#UseHook\b\s*(\S*)/i)))
		state.useHook = !/^(false|off|0)$/i.test(m[1]);
	else if ((m = line.match(/^\s*#HotIf\b(.*)$/i))) state.hotIf = m[1].trim() !== '';
	else if ((m = line.match(/^\s*#Include(?:Again)?\s+(?:\*i\s+)?(.+?)\s*$/i))) {
		const target = resolveInclude(m[1], cursor.dir, cursor.file);
		if (target && fs.existsSync(target)) {
			if (fs.statSync(target).isDirectory()) cursor.dir = target;
			else visit(target);
		}
	}
}

/**
 * The directive context of every line of every file a script at the driver
 * root includes: file -> [{ level, hotIf, useHook }] indexed by line - 1.
 */
function includeContexts() {
	const contexts = new Map();
	for (const root of fs.readdirSync(WINDOWS).filter((name) => name.endsWith('.ahk'))) {
		const state = { level: 0, hotIf: false, useHook: false };
		const visit = (file) => {
			if (contexts.has(file)) return;
			const perLine = [];
			contexts.set(file, perLine);
			const cursor = { dir: path.dirname(file), file };
			for (const line of stripComments(fs.readFileSync(file, 'utf8')).split('\n')) {
				applyDirective(line, state, cursor, visit);
				perLine.push({ ...state });
			}
		};
		visit(path.join(WINDOWS, root));
	}
	return contexts;
}

/**
 * Why AutoHotkey's hook, not RegisterHotKey, owns a declaration (an empty list
 * for a registered hotkey), from its syntax and its directive context.
 */
function hookReasons(d, context) {
	const reasons = [];
	if (d.kind === 'call') reasons.push('a Hotkey() registration, whose HotIf context no scan knows');
	const prefix = d.text.match(/^[~*$#!^+<>]*/)[0];
	for (const symbol of ['~', '$', '*', '<', '>']) {
		if (prefix.includes(symbol)) reasons.push(`the ${symbol} prefix`);
	}
	if (/\s+up\s*$/i.test(d.text)) reasons.push('a key-up hotkey');
	if (d.text.includes('&')) reasons.push('a custom combination');
	if (d.kind === 'label') {
		if (!context) reasons.push('no #Include path from a driver root script, so no known context');
		else {
			if (context.hotIf) reasons.push('a #HotIf criterion');
			if (context.level !== 0) reasons.push(`#InputLevel ${context.level}`);
			if (context.useHook) reasons.push('#UseHook');
		}
	}
	return reasons;
}

/** Character-key declarations that the hook owns, with the reasons. */
function characterOffenders(decls, contextOf) {
	const uses = [];
	const offenders = [];
	for (const d of decls) {
		const key = keysOf(d.text).find(isCharacterKey);
		if (key === undefined) continue;
		uses.push(d);
		const reasons = hookReasons(d, contextOf(d));
		if (reasons.length > 0) offenders.push({ ...d, key, reasons });
	}
	return { uses, offenders };
}

function describe(d) {
	return `${path.relative(ROOT, d.file).replace(/\\/g, '/')}:${d.line} ${d.kind} "${d.text}"`;
}

const names = nameTable();
const errors = [];

// ── Self-check: the scanner flags the pre-fix shape and nothing else ────────
{
	const fixture = stripComments(
		[
			'#HotIf LLM_Tooltip_GetText() != ""',
			'Tab:: {',
			'}',
			'#HotIf',
			'; Tab:: in a comment is not a hotkey',
			'SC00F:: {',
			'}',
			'*$SC01C:: return',
			'Hotkey("~*vk0D", Fn)',
			'Hotkey("~*Space", Fn)',
			'Hotkey("SC138 & Esc", Fn)',
			'Hotkey("SC001", Fn)'
		].join('\n')
	);
	const { offenders } = analyse(declarations(fixture, 'fixture.ahk'), names);
	const got = offenders.map((o) => o.text).join(', ');
	const want = 'Tab, ~*vk0D, SC138 & Esc';
	if (got !== want) {
		errors.push(`self-check: the scanner flagged [${got}], expected [${want}]`);
	}
}

// Computed names must cover the pre-fix dead-key reset loop, without admitting
// unrelated arrays or interpolated values the bounded resolver cannot judge.
{
	const fixture = stripComments(
		[
			'SC00E:: return',
			'SC001:: return',
			'global ResetKeys := ["BackSpace", "Escape"]',
			'for Key in ResetKeys {',
			'    HotkeyFn.Call("~" . Key, Reset)',
			'}',
			'global Unknown := [SomeFunction()]',
			'for Key in Unknown {',
			'    Hotkey("~" . Key, Reset)',
			'}'
		].join('\n')
	);
	const computed = arrayLoopDeclarations(fixture, 'fixture.ahk');
	const got = computed.map((row) => row.text).join(', ');
	if (got !== '~BackSpace, ~Escape') errors.push(`computed self-check: got [${got}]`);
	const { offenders } = analyse(declarations(fixture, 'fixture.ahk'), names);
	if (offenders.map((row) => row.text).join(', ') !== '~BackSpace, ~Escape')
		errors.push('computed self-check: concatenated key names must retain scan-code precedence');
}

// ── Self-check: character keys the hook owns, registered ones spared ────────
{
	const lines = stripComments(
		[
			'^!+i:: {',
			'}',
			'#InputLevel 2',
			'^!+j:: return',
			'#InputLevel 0',
			'#HotIf Foo()',
			'^k:: return',
			'#HotIf',
			'$^m:: return',
			'Tab:: return',
			'SC02F:: return',
			'Hotkey("~^v", Fn)',
			'Hotkey("~^vk56", Fn)',
			'Hotkey("^vk0D", Fn)'
		].join('\n')
	).split('\n');
	const state = { level: 0, hotIf: false, useHook: false };
	const cursor = { dir: WINDOWS, file: 'fixture.ahk' };
	const perLine = lines.map((line) => {
		applyDirective(line, state, cursor, () => {});
		return { ...state };
	});
	const found = declarations(lines.join('\n'), 'fixture.ahk');
	const { offenders } = characterOffenders(found, (d) => perLine[d.line - 1]);
	const got = offenders.map((o) => o.text).join(', ');
	const want = '^!+j, ^k, $^m, ~^v, ~^vk56';
	if (got !== want) {
		errors.push(`self-check: the character scan flagged [${got}], expected [${want}]`);
	}
}

// ── The driver ──────────────────────────────────────────────────────────────
const files = driverFiles(WINDOWS);
const decls = [];
for (const file of files)
	decls.push(...declarations(stripComments(fs.readFileSync(file, 'utf8')), file));
const labels = decls.filter((d) => d.kind === 'label').length;
const calls = decls.filter((d) => d.kind === 'call').length;
const { scanCodes, named, offenders } = analyse(decls, names);

if (files.length < 100)
	errors.push(`only ${files.length} driver .ahk file(s) found under ${WINDOWS}`);
if (labels < 100)
	errors.push(`the scan saw only ${labels} static hotkey label(s): it no longer reads them`);
if (calls < 20) errors.push(`the scan saw only ${calls} literal Hotkey() registration(s)`);
if (!scanCodes.has('SC00F'))
	errors.push('the Tab key (SC00F) must still be declared by its scan code');
if (named.length < 5)
	errors.push(`the scan resolved only ${named.length} name/VK hotkey(s) to a key`);

for (const o of offenders) {
	errors.push(
		`${describe(o)} names ${o.key} (${o.sc}), which ${describe(scanCodes.get(o.sc))} declares by ` +
			'scan code: AutoHotkey resolves that key through its scan code only, so this hotkey never fires. ' +
			'Declare it by the scan code and let variant order decide precedence.'
	);
}

// ── Character keys ──────────────────────────────────────────────────────────
const golden = JSON.parse(fs.readFileSync(GOLDEN, 'utf8'));
const altGr = new Set();
for (const level of ALTGR_LEVELS) {
	if (!golden.levels[level]) errors.push(`the emulation golden fixture lost its ${level} level`);
	else for (const sc of Object.keys(golden.levels[level])) altGr.add(sc.toUpperCase());
}
const layoutCode = files
	.filter((f) => f.replace(/\\/g, '/').endsWith('modules/keymap/layout.ahk'))
	.map((f) => stripComments(fs.readFileSync(f, 'utf8')))
	.join('\n');
if (!/^RegisterAltGrLayer\(\)\s*$/m.test(layoutCode))
	errors.push('modules/keymap/layout.ahk must still register the AltGr layer unconditionally');
const nativeAltGrProducer = files
	.filter((f) => f.replace(/\\/g, '/').endsWith('modules/keymap/layout/layout_altgr.ahk'))
	.map((f) => stripComments(fs.readFileSync(f, 'utf8')))
	.join('\n')
	.match(
		/^RegisterAltGrLayer\(HotkeyFn := Hotkey, HotIfFn := HotIf, DispatchFn := AltGrShiftDispatch, RealAltGrFn := IsRealAltGrPress\) \{([\s\S]*?)^\}/m
	);
const nativePortRegistrations =
	nativeAltGrProducer && !/^\s*HotkeyFn\s*:=/m.test(nativeAltGrProducer[1])
		? (nativeAltGrProducer[1].match(/^\s*HotkeyFn\.Call\("SC138 & " \. SC,/gm) || []).length
		: 0;
const altGrRegistrations =
	nativePortRegistrations +
	files
		.map(
			(f) =>
				(stripComments(fs.readFileSync(f, 'utf8')).match(/Hotkey\("SC138 & " \. SC,/g) || []).length
		)
		.reduce((a, b) => a + b, 0);
if (altGrRegistrations < 3)
	errors.push('the AltGr layer must still register its keys as "SC138 & SCnnn" hotkeys');
const characters = characterKeys();
if (characters.size < 40)
	errors.push(`the registry names only ${characters.size} character key(s)`);
for (const [sc, code] of characters) {
	if (!altGr.has(sc) && !scanCodes.has(sc))
		errors.push(
			`the character key ${code} (${sc}) is no longer declared by scan code: the character rule ` +
				'below assumes every character key is; revisit it before relaxing this'
		);
}

const contexts = includeContexts();
const contextOf = (d) => (contexts.get(d.file) || [])[d.line - 1];
const labelContexts = decls
	.filter((d) => d.kind === 'label')
	.map(contextOf)
	.filter(Boolean);
if (labelContexts.length !== labels)
	errors.push(
		`the #Include walk reached ${labelContexts.length} of the ${labels} static label(s): ` +
			'every driver hotkey must be reachable from a driver root script'
	);
if (contexts.size < 100)
	errors.push(
		`the #Include walk from the driver root scripts reached only ${contexts.size} file(s)`
	);
if (labelContexts.filter((c) => c.level !== 0).length < 20)
	errors.push('the #Include walk no longer places the layout hotkeys under #InputLevel 2');
if (labelContexts.filter((c) => c.hotIf).length < 20)
	errors.push('the #Include walk no longer sees the #HotIf criteria of static hotkeys');
const { uses: characterUses, offenders: characterHooks } = characterOffenders(decls, contextOf);

for (const o of characterHooks) {
	errors.push(
		`${describe(o)} names the character ${o.key} and the hook owns it (${o.reasons.join(', ')}): ` +
			'every character key is declared by scan code (the AltGr layer), so the hook looks that key ' +
			'up by scan code only and this hotkey never fires. Observe the key on the HookDispatcher, ' +
			'declare it by scan code, or keep it a plain global hotkey at #InputLevel 0.'
	);
}

if (errors.length > 0) {
	for (const e of errors) console.error(`  FAIL  ${e}`);
	console.error(`\n[hardening-c-ahk-scan-code-precedence] ${errors.length} problem(s).`);
	process.exit(1);
}
console.log(
	`[hardening-c-ahk-scan-code-precedence] ${files.length} files, ${labels} labels, ${calls} ` +
		`Hotkey() calls: ${scanCodes.size} scan-code keys, ${named.length} name/VK uses and ` +
		`${characterUses.length} character hotkey(s), none shadowed.`
);
