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
 * ROOT CAUSE ENCODED (incident of 2026-09-30):
 * The AI prediction's `Tab::` accept was dead from the day remap/tab.ahk
 * declared SC00F. Tab accepted only inside the Tab tap-hold; the switch to
 * neutral defaults (tap-holds off) exposed it, and Tab went to the application
 * instead of accepting the prediction (45704357d). The same class hid the
 * AltGr tap-hold behind `RAlt::` (altgr-single-identity-2026-09-25).
 *
 * FEATURES & RATIONALE:
 * 1. Mirrors windows/tests/meta/test_hardening_c_scan_code_shadows_key_name.ahk
 *    so the class fails on Linux and macOS before the Windows lane runs: the
 *    AutoHotkey suite cannot run outside Windows.
 * 2. Names are resolved from the physical-key registry
 *    (_shared/data/keycodes/physical_keys.json: `ahk_send` → `ahk`), plus the
 *    AutoHotkey aliases and the fixed Windows virtual-key codes of those
 *    layout-independent keys. Character keys are named through the active
 *    layout, which no source scan knows: they are out of this guard's scope.
 * 3. Static labels and literal Hotkey() registrations are both scanned, with
 *    comments removed, and a floor on each count keeps the scan honest.
 * 4. A self-check replays the pre-fix shape (`Tab::` beside `SC00F::`) and a
 *    clean shape through the same scanner.
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
	return found;
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

if (errors.length > 0) {
	for (const e of errors) console.error(`  FAIL  ${e}`);
	console.error(`\n[hardening-c-ahk-scan-code-precedence] ${errors.length} problem(s).`);
	process.exit(1);
}
console.log(
	`[hardening-c-ahk-scan-code-precedence] ${files.length} files, ${labels} labels, ${calls} ` +
		`Hotkey() calls: ${scanCodes.size} scan-code keys, ${named.length} name/VK uses, none shadowed.`
);
