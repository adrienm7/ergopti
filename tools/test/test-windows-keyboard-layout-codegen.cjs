// tools/test/test-windows-keyboard-layout-codegen.cjs

/**
 * ==============================================================================
 * MODULE: Windows Keyboard Layout Codegen Guard
 * DESCRIPTION:
 * Pins tools/codegen/codegen-windows-keyboard-layout.cjs, which writes the
 * Ergopti Windows keyboard DLL sources and .klc from the registry .keylayout.
 *
 * ROOT CAUSES ENCODED:
 * 1. The Windows layout installer was a hand-built KbdEdit binary
 *    (static/ergopti/windows/Ergopti_v*.exe) that nothing compared with the
 *    .keylayout macOS and Linux install, so the three systems could type
 *    different characters. The tracked sources must be what the generator
 *    writes from the registry layout today.
 * 2. Windows keys its character tables by virtual key: two layout keys with one
 *    virtual key would type the same characters. Every key has its own, a key
 *    typing a letter takes that letter's, and a punctuation key keeps its
 *    QWERTY one before the pool hands one out.
 * 3. A keyboard DLL silently drops what it cannot express. A Caps Lock that is
 *    neither "none" nor "like Shift" is refused, and a dead-key sequence whose
 *    key or result is longer than one UTF-16 unit is named in the sources'
 *    header, never dropped without a trace.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const {
	buildSources,
	outputs,
	SPEC_PATH
} = require('../codegen/codegen-windows-keyboard-layout.cjs');
const { buildModel, generate, encodeKlc } = require('../codegen/lib/windows-keyboard-layout.cjs');
const { GENERATORS } = require('../build/generators.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const KEYCODES = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/layouts/data/mac_keycodes.json'),
		'utf8'
	)
);
const SPEC = JSON.parse(fs.readFileSync(SPEC_PATH, 'utf8'));
const PHYSICAL_KEYS = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/layouts/data/keycodes/physical_keys.json'),
		'utf8'
	)
);

let failures = 0;
function check(name, fn) {
	try {
		fn();
		console.log(`  ok  ${name}`);
	} catch (error) {
		failures++;
		console.error(`  FAIL ${name}\n       ${error.message}`);
	}
}

const built = buildSources();
const model = built.model;
const byCode = new Map(model.keys.map((key) => [key.code, key]));

check('the tracked sources are what the generator writes from the registry layout', () => {
	const files = outputs();
	assert.strictEqual(files.length, built.files.size);
	for (const rel of files) {
		const name = path.basename(rel);
		assert.ok(built.files.has(name), `${name} is not generated`);
		const tracked = fs.readFileSync(path.join(ROOT, rel), 'utf8');
		assert.strictEqual(
			tracked,
			built.files.get(name),
			`${rel} drifted: run npm run codegen:windows-keyboard-layout`
		);
	}
});

check('the generator registry declares exactly these outputs', () => {
	const entry = GENERATORS.find(
		(item) => item.script === 'codegen/codegen-windows-keyboard-layout.cjs'
	);
	assert.ok(entry, 'codegen-windows-keyboard-layout.cjs is not in tools/build/generators.cjs');
	assert.deepStrictEqual([...entry.outputs].sort(), [...outputs()].sort());
});

check('the sources are ASCII with LF line ends', () => {
	for (const [name, text] of built.files) {
		assert.ok(!/[^\x09\x0a\x20-\x7e]/.test(text), `${name} holds a non-ASCII or control character`);
	}
});

check(
	'the sources owe nothing to kalamine: written from kbd.h, key names from the shared registry',
	() => {
		// Maintainer rule (2026-11-06): kalamine may be read for ideas, never copied.
		for (const [name, text] of built.files)
			assert.ok(!/kalamine/i.test(text), `${name} names kalamine`);
		assert.ok(!/kalamine/i.test(built.klc), 'the .klc names kalamine');
		const source = built.files.get(`${SPEC.dll_name}.c`);
		assert.match(source, /\{ 0x01, L"Escape" \},/, 'Escape is named after its W3C code');
		assert.match(source, /KeyNamesExtended\[\] = \{\n    \{ 0x1C, L"Numpad Enter" \},/);
		assert.match(built.klc, /\nKEYNAME_EXT\n\n1c\t"Numpad Enter"\n/);
	}
);

check('the generated DLL is named by the shared spec and exports KbdLayerDescriptor', () => {
	assert.ok(built.files.has(`${SPEC.dll_name}.c`));
	assert.match(
		built.files.get(`${SPEC.dll_name}.def`),
		new RegExp(`LIBRARY ${SPEC.dll_name.toUpperCase()}\\n`)
	);
	assert.match(built.files.get(`${SPEC.dll_name}.def`), /KbdLayerDescriptor @1/);
	assert.match(built.files.get(`${SPEC.dll_name}.rc`), new RegExp(`1000 +"${SPEC.layout_text}"`));
});

check('every layout key has its own virtual key; letters follow the letter they type', () => {
	const seen = new Map();
	for (const key of model.keys) {
		assert.ok(!seen.has(key.vk), `${key.code} and ${seen.get(key.vk)} share VK ${key.vk}`);
		seen.set(key.vk, key.code);
	}
	assert.strictEqual(byCode.get('KeyA').vk, 'A');
	assert.strictEqual(byCode.get('KeyE').vk, 'O', 'the key typing o takes VK_O');
	assert.strictEqual(byCode.get('BracketLeft').vk, 'Z', 'the key typing z takes VK_Z');
	assert.strictEqual(byCode.get('IntlBackslash').vk, 'OEM_102');
	assert.strictEqual(byCode.get('Digit1').vk, '1');
	assert.strictEqual(byCode.get('Space').vk, 'SPACE');
	assert.strictEqual(
		byCode.get('Slash').vk,
		'OEM_2',
		'a punctuation key keeps its QWERTY virtual key'
	);
	assert.strictEqual(byCode.get('Backquote').vk, 'OEM_3');
});

check('letters follow Caps Lock like Shift; the digit row does not', () => {
	assert.strictEqual(byCode.get('KeyA').attribute, 'CAPLOK');
	assert.strictEqual(byCode.get('KeyQ').attribute, 'CAPLOK', 'è becomes È');
	assert.strictEqual(byCode.get('Digit1').attribute, 0);
});

check('the base, Shift and AltGr columns come from the layout keyMaps', () => {
	const a = byCode.get('KeyA').cells;
	assert.strictEqual(a.base.char, 0x61);
	assert.strictEqual(a.shift.char, 0x41);
	assert.strictEqual(a.altgr.char, 0x3c);
	assert.strictEqual(a.shift_altgr.char, 0x2264);
	assert.strictEqual(a.ctrl.kind, 'none');
	assert.match(
		built.files.get(`${SPEC.dll_name}.c`),
		/\{ 'A', CAPLOK, 0x0061, 0x0041, WCH_NONE, WCH_NONE, 0x003c, 0x2264 \},/
	);
});

check('multi-character outputs are ligatures (the guillemet with its no-break space)', () => {
	const t = byCode.get('KeyT').cells.altgr;
	assert.strictEqual(t.kind, 'ligature');
	assert.deepStrictEqual(t.units, [0x00ab, 0x00a0]);
	assert.ok(model.ligatures.some((item) => item.vk === 'B' && item.column === 4));
});

check(
	'dead keys: the circumflex is a dead key whose space-free terminator is its dead character',
	() => {
		const circumflex = byCode.get('Backslash').cells.base;
		assert.strictEqual(circumflex.kind, 'dead');
		assert.strictEqual(circumflex.deadChar, 0x5e);
		const dead = model.deadKeys.find((item) => item.state === 's1_circumflex');
		assert.ok(
			dead.entries.some((entry) => entry.base === 0x61 && entry.result === 0xe2 && !entry.chained),
			'a -> â'
		);
		assert.match(
			built.files.get(`${SPEC.dll_name}.c`),
			/DEADTRANS\(0x0061, 0x005e, 0x00e2, 0x0000\),/
		);
		const chars = model.deadKeys.map((item) => item.deadChar);
		assert.strictEqual(new Set(chars).size, chars.length, 'two dead keys share a dead character');
	}
);

check('the .klc is UTF-16LE with a byte order mark and CRLF line ends, as MSKLC reads it', () => {
	const bytes = encodeKlc(built.klc);
	assert.deepStrictEqual([...bytes.subarray(0, 2)], [0xff, 0xfe]);
	const text = bytes.subarray(2).toString('utf16le');
	assert.ok(text.includes('\r\n') && !/[^\r]\n/.test(text));
	assert.match(text, new RegExp(`KBD\\t${SPEC.dll_name}\\t"${SPEC.layout_text}"`));
	assert.match(text, /\r\n1e\tA\t1\t0061\t0041\t-1\t-1\t003c\t2264\r\n/);
	assert.match(text, /\r\n2b\tOEM_5\t0\t005e@\t%%\t-1\t-1\t0021\t00a1\r\n/);
	assert.match(text, /DEADKEY\t005e\r\n\r\n/);
});

// ----- Synthetic layouts: what the registry layout does not exercise -----

// Caps Lock changes nothing unless a layout gives it keyMaps of its own.
const SIMPLE_SELECTS = [
	{ index: 0, modifiers: [{ required: [], optional: ['caps'] }] },
	{ index: 2, modifiers: [{ required: ['shift'], optional: ['caps'] }] },
	{ index: 5, modifiers: [{ required: ['option'], optional: ['caps'] }] },
	{ index: 6, modifiers: [{ required: ['option', 'shift'], optional: ['caps'] }] }
];

const CAPS_SELECTS = [
	{ index: 0, modifiers: [{ required: [], optional: [] }] },
	{ index: 1, modifiers: [{ required: ['caps'], optional: [] }] },
	{ index: 2, modifiers: [{ required: ['shift'], optional: [] }] },
	{ index: 3, modifiers: [{ required: ['caps', 'shift'], optional: [] }] },
	{ index: 5, modifiers: [{ required: ['option'], optional: ['caps'] }] },
	{ index: 6, modifiers: [{ required: ['option', 'shift'], optional: ['caps'] }] }
];

/** A one-keyMapSet canonical layout from per-index key lists. */
function canonical(maps, actions = [], terminators = [], selects = SIMPLE_SELECTS) {
	return {
		schema: 1,
		name: 'synthetic',
		map_set: 'set',
		default_index: 0,
		selects,
		key_map_sets: [
			{
				id: 'set',
				key_maps: Object.entries(maps).map(([index, keys]) => ({ index: Number(index), keys }))
			}
		],
		actions,
		terminators
	};
}

// macOS code 0 is KeyA, 1 KeyS, 12 KeyQ (shared keycode table).
check('a Caps Lock that is neither none nor Shift is refused (no SGCAP)', () => {
	const layout = canonical(
		{
			0: [{ code: 0, output: 'a' }],
			1: [{ code: 0, output: 'b' }],
			2: [{ code: 0, output: 'A' }],
			3: [{ code: 0, output: 'a' }]
		},
		[],
		[],
		CAPS_SELECTS
	);
	assert.throws(() => buildModel(layout, KEYCODES, 'iso'), /SGCAP/);
});

check('a key typing a letter outside its QWERTY place does not steal another key its VK', () => {
	const layout = canonical({
		0: [
			{ code: 0, output: 'q' },
			{ code: 12, output: 'a' }
		],
		2: [
			{ code: 0, output: 'Q' },
			{ code: 12, output: 'A' }
		]
	});
	const keys = new Map(buildModel(layout, KEYCODES, 'iso').keys.map((key) => [key.code, key]));
	assert.strictEqual(keys.get('KeyA').vk, 'Q');
	assert.strictEqual(keys.get('KeyQ').vk, 'A');
});

check('a dead-key result beyond one UTF-16 unit is named, never silently dropped', () => {
	const layout = canonical(
		{
			0: [
				{ code: 0, action: 'a' },
				{ code: 1, action: 'dead' }
			],
			2: [{ code: 0, output: 'A' }]
		},
		[
			{
				id: 'a',
				whens: [
					{ state: 'none', output: 'a' },
					{ state: 's1_double', output: '\u{1D552}' }
				]
			},
			{ id: 'dead', whens: [{ state: 'none', next: 's1_double' }] }
		],
		[{ state: 's1_double', output: 'ℤ' }]
	);
	const result = generate(layout, {
		meta: {
			name: 'Synthetic',
			version: '1.0.0',
			author: 'Test',
			licence: 'MIT',
			keycode_convention: 'iso'
		},
		spec: SPEC,
		keycodes: KEYCODES,
		physicalKeys: PHYSICAL_KEYS,
		sourceRel: 'synthetic.keylayout'
	});
	assert.deepStrictEqual(result.model.omitted, [
		{ state: 's1_double', typed: 'a', output: '\u{1D552}' }
	]);
	assert.match(result.files.get(`${SPEC.dll_name}.c`), /s1_double: U\+0061 -> U\+1D552/);
	assert.ok(!/DEADTRANS\(0x0061/.test(result.files.get(`${SPEC.dll_name}.c`)));
});

check('a chained dead key moves to the next dead character (DEADTRANS flag 1)', () => {
	const layout = canonical(
		{
			0: [
				{ code: 0, action: 'first' },
				{ code: 1, action: 'second' }
			]
		},
		[
			{ id: 'first', whens: [{ state: 'none', next: 's1_one' }] },
			{
				id: 'second',
				whens: [
					{ state: 'none', next: 's2_two' },
					{ state: 's1_one', next: 's2_two' }
				]
			}
		],
		[
			{ state: 's1_one', output: '^' },
			{ state: 's2_two', output: '¨' }
		]
	);
	const dead = buildModel(layout, KEYCODES, 'iso').deadKeys.find((item) => item.state === 's1_one');
	assert.deepStrictEqual(dead.entries, [{ base: 0xa8, result: 0xa8, chained: true }]);
});

check('two dead keys with one dead character are refused', () => {
	const layout = canonical(
		{
			0: [
				{ code: 0, action: 'first' },
				{ code: 1, action: 'second' }
			]
		},
		[
			{ id: 'first', whens: [{ state: 'none', next: 's1_one' }] },
			{ id: 'second', whens: [{ state: 'none', next: 's2_two' }] }
		],
		[
			{ state: 's1_one', output: '^' },
			{ state: 's2_two', output: '^' }
		]
	);
	assert.throws(() => buildModel(layout, KEYCODES, 'iso'), /share the dead character/);
});

if (failures > 0) {
	console.error(`\n${failures} Windows keyboard layout codegen check(s) failed.`);
	process.exit(1);
}
console.log('\nWindows keyboard layout codegen: all checks passed.');
