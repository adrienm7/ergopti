// tools/test/test-layout-shortcut-keys.cjs

/**
 * ==============================================================================
 * MODULE: Native Shortcut-Key Exports Golden Test
 * DESCRIPTION:
 * Pins how the native exports carry a layout source's
 * `keys.<physical>.shortcut_key` (_shared/tests/corpus/layouts/source/shortcut_keys.toml):
 * the macOS .keylayout writes the named key's row on every Command and
 * Control keyMap, the Linux XKB symbols on the Control/Alt/Super level, and
 * the Windows KLC and DLL tables give the key the named key's virtual key.
 * Each generator output equals its committed golden file; the rows and
 * virtual keys the goldens hold are asserted too, so a regenerated golden
 * cannot hide a lost shortcut key. `--update` rewrites the goldens.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { exportXkb } = require('../lib/layout-source-xkb.cjs');
const { exportKlc } = require('../lib/layout-source-klc.cjs');
const KbdSource = require('../lib/kbd-dll/source.cjs');
const PeWriter = require('../lib/kbd-dll/pe-writer.cjs');
const { readDll } = require('../lib/kbd-dll/reader.cjs');
const { exchangeVirtualKeys } = require('../lib/kbd-dll/shortcut-keys.cjs');
const { shared } = require('../lib/paths.cjs');

const UPDATE = process.argv.includes('--update');
const corpus = shared('tests', 'corpus', 'layouts', 'source');
const goldenDir = path.join(corpus, 'shortcut_keys');
const Source = loadLayoutSource();
const fixture = Source.read(fs.readFileSync(path.join(corpus, 'shortcut_keys.toml'), 'utf8'));
let checks = 0;

/** Compares a generator output with its golden file, or rewrites it with --update. */
function golden(name, text) {
	const file = path.join(goldenDir, name);
	if (UPDATE) {
		fs.mkdirSync(goldenDir, { recursive: true });
		fs.writeFileSync(file, text);
		return;
	}
	assert.equal(text, fs.readFileSync(file, 'utf8'), `${name}: regenerate with --update`);
}

// The compiler runs in a vm context: its arrays are compared as plain values.
const reasonsOf = (omitted) =>
	JSON.parse(JSON.stringify(omitted))
		.filter((entry) => /^keys\.[^.]+\.shortcut_key$/.test(entry.path))
		.map((entry) => `${entry.path}: ${entry.reason}`);

// The shared rule: an exchange, never a share; a second claim and a key with no
// row are refused; the named key of a one-way claim takes the freed virtual key.
{
	const result = exchangeVirtualKeys(
		[
			{ code: 'KeyQ', vk: 'A' },
			{ code: 'KeyA', vk: 'Q' },
			{ code: 'KeyZ', vk: 'W' },
			{ code: 'KeyX', vk: 'X' },
			{ code: 'KeyC', vk: 'C' }
		],
		[
			{ key: 'KeyQ', shortcut_key: 'KeyA' },
			{ key: 'KeyA', shortcut_key: 'KeyQ' },
			{ key: 'KeyZ', shortcut_key: 'KeyC' },
			{ key: 'KeyX', shortcut_key: 'KeyC' },
			{ key: 'KeyB', shortcut_key: 'Space' }
		]
	);
	assert.deepEqual(Object.fromEntries(result.vks), {
		KeyQ: 'Q',
		KeyA: 'A',
		KeyZ: 'C',
		KeyX: 'X',
		KeyC: 'W'
	});
	assert.deepEqual(result.displaced, [{ key: 'KeyC', vk: 'W', by: 'KeyZ' }]);
	assert.deepEqual(
		result.refused.map((entry) => [entry.key, entry.reason]),
		[
			['KeyX', 'shortcut_key_virtual_key_taken'],
			['KeyB', 'shortcut_key_not_a_character_key']
		]
	);
	assert.equal(
		new Set(result.vks.values()).size,
		result.vks.size,
		'every virtual key stays distinct'
	);
	checks++;
}

// macOS: the Command layer is patched in place; Control falls to the default
// keyMap, so one more keyMap based on it takes the free combinations.
{
	const compiled = Source.compileKeylayout(fixture);
	golden('shortcut_keys.keylayout', compiled.text);
	const model = Source.composer.parseModel(compiled.text);
	assert.equal(model.selects.length, 4, 'base, shift, command and the added shortcut keyMap');
	const added = compiled.text.match(
		/<keyMap index="3" baseMapSet="layout" baseIndex="0">\n([\s\S]*?)\t\t<\/keyMap>/
	);
	assert(added, 'the added keyMap inherits the default one');
	// macOS codes: KeyA 0, KeyZ 6, KeyX 7, KeyC 8, KeyQ 12.
	assert.equal(
		added[1],
		[
			'\t\t\t<key code="0" output="a"/>',
			'\t\t\t<key code="6" output="c"/>',
			'\t\t\t<key code="7" output="c"/>',
			'\t\t\t<key code="12" output="q"/>',
			''
		].join('\n')
	);
	const command = compiled.text.match(/<keyMap index="2">\n([\s\S]*?)\t\t<\/keyMap>/)[1];
	for (const [code, text] of [
		[0, 'a'],
		[6, 'c'],
		[7, 'c'],
		[12, 'q']
	])
		assert.match(command, new RegExp(`<key code="${code}" output="${text}"/>`));
	assert.doesNotMatch(command, /<key code="11" /, 'KeyB acts as Space, which types nothing there');
	assert.deepEqual(reasonsOf(compiled.omitted), [
		'keys.KeyB.shortcut_key: shortcut_key_types_nothing_in_keylayout'
	]);
	checks++;
}

// Linux: the XKB Control/Alt/Super level (the fifth of ERGOPTI_SEVEN_LEVEL,
// whose type preserves those modifiers for the application's shortcut match).
{
	const xkb = exportXkb(fixture);
	const symbols = xkb.files.get('shortcut_keys.xkb');
	golden('shortcut_keys.xkb', symbols);
	const level5 = (name) =>
		new RegExp(`key <${name}> \\{ type\\[group1\\] = "ERGOPTI_SEVEN_LEVEL", \\[([^\\]]*)\\]`)
			.exec(symbols)[1]
			.split(', ')[4];
	assert.deepEqual(
		['AD01', 'AC01', 'AB01', 'AB02', 'AB03'].map(level5),
		['q', 'a', 'c', 'c', 'c'],
		'KeyQ, KeyA, KeyZ, KeyX and KeyC on the shortcut level'
	);
	assert.deepEqual(reasonsOf(xkb.report.omitted), [
		'keys.KeyB.shortcut_key: shortcut_key_types_nothing_in_xkb'
	]);
	assert(
		xkb.report.limitations.some((line) => /shortcut_key/.test(line)),
		'the XKB export says what its shortcut level cannot carry'
	);
	checks++;
}

// Windows KLC: the virtual keys follow the typed character, then the exchange.
{
	const klc = exportKlc(fixture);
	const bytes = klc.files.get('kbdshort.klc');
	const text = Buffer.from(bytes).subarray(2).toString('utf16le').replace(/\r\n/g, '\n');
	golden('kbdshort.klc', text);
	const vkOf = (sc) => new RegExp(`^${sc}\\t(\\S+)\\t`, 'm').exec(text)[1];
	// Scan codes: KeyQ 10, KeyA 1e, KeyZ 2c, KeyX 2d, KeyC 2e.
	assert.deepEqual(['10', '1e', '2c', '2d', '2e'].map(vkOf), ['Q', 'A', 'C', 'X', 'W']);
	assert.deepEqual(JSON.parse(JSON.stringify(klc.report.shortcut_keys.displaced)), [
		{ key: 'KeyC', virtual_key: 'W', by: 'KeyZ' }
	]);
	assert.deepEqual(reasonsOf(klc.report.omitted), [
		'keys.KeyX.shortcut_key: shortcut_key_virtual_key_taken_in_klc',
		'keys.KeyB.shortcut_key: shortcut_key_not_a_character_key_in_klc',
		'keys.KeyZ.shortcut_key: shortcut_key_displaces_virtual_key_in_klc'
	]);
	checks++;
}

// Windows DLL: the tables the four images hold, read back from a built image.
{
	const converted = KbdSource.fromSource(fixture);
	golden('kbdshort.scancodes.json', `${JSON.stringify(converted.model.scancodes, null, '\t')}\n`);
	const image = readDll(PeWriter.writeDlls(converted.model).x64);
	const vk = (sc) => String.fromCharCode(image.layout.scancodes[sc] & 0xff);
	// Positional virtual keys exchanged: KeyQ takes A, KeyA Q, KeyZ C, KeyC Z.
	assert.deepEqual([0x10, 0x1e, 0x2c, 0x2d, 0x2e].map(vk), ['A', 'Q', 'C', 'X', 'Z']);
	assert.deepEqual(reasonsOf(converted.omitted), [
		'keys.KeyX.shortcut_key: shortcut_key_virtual_key_taken',
		'keys.KeyB.shortcut_key: shortcut_key_not_a_character_key',
		'keys.KeyZ.shortcut_key: shortcut_key_displaces_virtual_key'
	]);
	checks++;
}

console.log(
	UPDATE
		? `[OK] shortcut-key goldens rewritten in ${goldenDir}`
		: `[OK] native shortcut keys: ${checks} checks (.keylayout, XKB, KLC and DLL goldens)`
);
