// tools/test/test-layout-jis-abnt.cjs

/**
 * ==============================================================================
 * MODULE: JIS And ABNT Keyboards Test
 * DESCRIPTION:
 * Proves the JIS (Japanese 106/109-key) and ABNT (Brazilian) keyboards end to
 * end: their boards in the layout editor's key data and in the analysis
 * engine, and the two source fixtures (_shared/tests/corpus/layouts/source/
 * jis.toml and abnt.toml) through every format that can hold their keys.
 *
 * FEATURES & RATIONALE:
 * 1. Boards: the JIS board has Yen, Ro, Muhenkan, Henkan and Katakana/Hiragana
 *    and no ISO key left of Z; the ABNT board keeps that key and adds Ro (ABNT
 *    C1) and the keypad comma (ABNT C2); ISO and ANSI have none of them.
 * 2. Analysis: a JIS or ABNT keyboard fingers its own keys, so a character on
 *    Yen is typed there and is a character the ISO keyboard lacks.
 * 3. Round trips: .keylayout (codes 93, 94, 95), KLC (scan codes 7D, 73, 7E),
 *    XKB (<AE13>, <AB11>, <KPPT>) and the keyboard DLL (all four images, read
 *    back by the independent reader, the JIS keyboard type 7/2 and the
 *    input-method virtual keys, the wow64 image's 64-bit descriptor) each give
 *    the fixtures' characters back on the same keys. What a format cannot hold
 *    (Muhenkan has no macOS code, so no .keylayout, KLC or XKB through the
 *    canonical form) is reported with a stable reason.
 * 4. Microsoft's own layouts on this PC, read-only and structure only: KBDJPN
 *    reads as a foreign image (it carries code), KBD106's tables state the
 *    keyboard type and the input-method virtual keys the DLL writer uses, and
 *    KBDBR's the ABNT keys' virtual keys. Skipped where the files are absent.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shared } = require('../lib/paths.cjs');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { exportXkb } = require('../lib/layout-source-xkb.cjs');
const { exportKlc } = require('../lib/layout-source-klc.cjs');
const KbdSource = require('../lib/kbd-dll/source.cjs');
const PeWriter = require('../lib/kbd-dll/pe-writer.cjs');
const C = require('../lib/kbd-dll/constants.cjs');
const { fromKlc } = require('../lib/kbd-dll/klc.cjs');
const { readDll } = require('../lib/kbd-dll/reader.cjs');
const { compareLayout } = require('../lib/kbd-dll/compare.cjs');

const UI = shared('ui');
const FIXTURES = shared('tests', 'corpus', 'layouts', 'source');
const JIS_KEYS = ['IntlYen', 'IntlRo', 'NonConvert', 'Convert', 'KanaMode', 'NumpadComma'];

let checks = 0;
const clone = (value) => JSON.parse(JSON.stringify(value));
const Source = loadLayoutSource();
const fixture = (name) => Source.read(fs.readFileSync(path.join(FIXTURES, `${name}.toml`), 'utf8'));
/** The text a source layer types on a key, or undefined. */
const typed = (doc, layer, code) => {
	const found = doc.layers.find((l) => l.id === layer);
	return found && found.keys[code] && found.keys[code].text;
};

// The pages' scripts, run as the pages run them.
const sandbox = { TextDecoder };
vm.createContext(sandbox);
for (const file of [
	'layer_editor/_generated/layer_data.js',
	'layout_analysis/_generated/analysis_data.js',
	'layout_analysis/analysis_engine.js',
	'layout_analysis/layout_formats.js'
])
	vm.runInContext(fs.readFileSync(path.join(UI, file), 'utf8'), sandbox, { filename: file });
const EDITOR = vm.runInContext('LAYER_EDITOR_DATA', sandbox);
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const F = vm.runInContext('LAYOUT_FORMATS', sandbox);
const DATA = vm.runInContext('LAYOUT_ANALYSIS_DATA', sandbox);

// =========================
// ======= 1/ Boards =======
// =========================

{
	const on = (form) =>
		new Set(EDITOR.keys.filter((k) => k.geometry && k.geometry[form]).map((k) => k.code));
	const iso = on('iso');
	const ansi = on('ansi');
	const jis = on('jis');
	const abnt = on('abnt');
	for (const code of JIS_KEYS) {
		assert.ok(!iso.has(code) && !ansi.has(code), `${code} is on no ISO or ANSI board`);
		assert.equal(abnt.has(code), ['IntlRo', 'NumpadComma'].includes(code), `${code} on ABNT`);
		assert.equal(jis.has(code), code !== 'NumpadComma', `${code} on JIS`);
	}
	assert.ok(!jis.has('IntlBackslash') && abnt.has('IntlBackslash'), 'the ISO key left of Z');
	// Every other ISO key is on both boards (the number row, the arrows, the keypad).
	for (const code of iso) assert.ok(abnt.has(code), `${code} on ABNT`);
	for (const code of iso) if (code !== 'IntlBackslash') assert.ok(jis.has(code), `${code} on JIS`);
	const g = (code, form) => clone(EDITOR.keys.find((k) => k.code === code).geometry[form]);
	assert.equal(g('ShiftLeft', 'jis').width, 2.25, 'JIS left Shift spans the missing ISO key');
	assert.equal(g('ShiftRight', 'abnt').width, 1.75, 'ABNT right Shift leaves room for Ro');
	assert.equal(g('NumpadAdd', 'abnt').height, undefined, 'ABNT shortens the keypad plus');
	assert.deepEqual(g('KeyA', 'jis'), g('KeyA', 'iso'), 'a letter keeps its ISO place');
	checks++;
}

// ===========================
// ======= 2/ Analysis =======
// ===========================

{
	for (const id of ['jis', 'abnt']) assert.ok(DATA.model.keyboards[id], `${id} keyboard`);
	const jis = E.keyboard('jis');
	const abnt = E.keyboard('abnt');
	assert.ok(jis.index.has('IntlYen') && jis.index.has('IntlRo'), 'JIS fingers Yen and Ro');
	assert.ok(!jis.index.has('IntlBackslash'), 'JIS has no ISO key left of Z');
	assert.ok(abnt.index.has('IntlRo') && abnt.index.has('IntlBackslash'), 'ABNT keys');
	assert.ok(!E.keyboard('iso').index.has('IntlYen'), 'ISO has no Yen');
	const yen = jis.finger[jis.index.get('IntlYen')];
	assert.equal(DATA.model.fingers[yen], 'rp', 'the right pinky types Yen');
	// A layout with ¥ on Yen: typed on the JIS keyboard, lacking on ISO.
	const layout = {
		id: 'yen',
		name: 'Yen',
		rows: { KeyA: ['a', 'A', null, null], IntlYen: ['¥', '|', null, null] }
	};
	const ngrams = E.ngramsFromText('a¥a¥a');
	// The page realm's objects, as this realm's (deepEqual compares prototypes).
	const coverage = (keyboard) => clone(E.analyse(layout, ngrams, { keyboard }).coverage);
	assert.deepEqual(coverage('jis').missingKeys, [], 'the JIS keyboard has Yen');
	assert.deepEqual(Object.keys(coverage('jis').unsupportedChars), [], 'the JIS keyboard types ¥');
	assert.deepEqual(coverage('iso').missingKeys, ['IntlYen'], 'the ISO keyboard lacks Yen');
	assert.deepEqual(Object.keys(coverage('iso').unsupportedChars), ['¥'], 'and so lacks ¥');
	checks++;
}

// ====================================
// ======= 3/ Formats round trips =====
// ====================================

const jisDoc = fixture('jis');
const abntDoc = fixture('abnt');

// 3.1 macOS .keylayout: compiled at the JIS codes, imported back on the same keys.
for (const [doc, codes] of [
	[jisDoc, ['IntlYen', 'IntlRo']],
	[abntDoc, ['IntlRo', 'NumpadComma', 'IntlBackslash']]
]) {
	const compiled = Source.compileKeylayout(doc);
	for (const [code, mac] of [
		['IntlYen', 93],
		['IntlRo', 94],
		['NumpadComma', 95]
	])
		if (codes.includes(code))
			assert.match(compiled.text, new RegExp(`<key code="${mac}" output="`), `${code} at ${mac}`);
	const back = Source.read(
		Source.write(Source.importStructured(compiled.text, doc.layout.id, 'iso'))
	);
	for (const code of codes)
		for (const layer of ['base', 'shift'])
			assert.equal(
				typed(back, layer, code),
				typed(doc, layer, code),
				`.keylayout ${layer} ${code}`
			);
	if (doc === jisDoc)
		assert.ok(
			compiled.omitted.some(
				(o) =>
					o.path === 'layers.base.keys.NonConvert' && o.reason === 'physical_key_not_in_keylayout'
			),
			'Muhenkan has no macOS code'
		);
	checks++;
}

// 3.2 KLC: rows 7D, 73 and 7E, read back by the DLL tool's KLC reader and the Comparer's.
{
	const klcText = (doc) => {
		const out = exportKlc(doc);
		const name = [...out.files.keys()].find((f) => f.endsWith('.klc'));
		return { bytes: Buffer.from(out.files.get(name)), report: out.report };
	};
	const jis = klcText(jisDoc);
	const text = jis.bytes.subarray(2).toString('utf16le').replace(/\r\n/g, '\n');
	assert.match(text, /\n7d\tOEM_AX\t0\t00a5\t007c\t/, 'Yen on 7D with VK_OEM_AX');
	assert.match(text, /\n73\tABNT_C1\t0\t005c\t005f\t/, 'Ro on 73 with VK_ABNT_C1');
	const abnt = klcText(abntDoc);
	const abntText = abnt.bytes.subarray(2).toString('utf16le').replace(/\r\n/g, '\n');
	assert.match(abntText, /\n73\tABNT_C1\t0\t002f\t003f\t/, 'ABNT C1 types / and ?');
	assert.match(abntText, /\n7e\t[A-Z_0-9]+\t0\t002e\t/, 'ABNT C2 types .');
	for (const [doc, bytes] of [
		[jisDoc, jis.bytes],
		[abntDoc, abnt.bytes]
	]) {
		const source = KbdSource.toSource(fromKlc(bytes), { id: doc.layout.id });
		for (const code of ['IntlYen', 'IntlRo', 'NumpadComma'])
			for (const layer of ['base', 'shift'])
				assert.equal(typed(source, layer, code), typed(doc, layer, code), `KLC ${layer} ${code}`);
		// The Comparer's reader places the JIS and ABNT keys it can analyse.
		const read = F.fromKlc(bytes.subarray(2).toString('utf16le'), DATA.scancodes);
		for (const code of ['IntlYen', 'IntlRo'])
			if (typed(doc, 'base', code))
				assert.equal(read.layout.rows[code][0], typed(doc, 'base', code));
	}
	checks++;
}

// 3.3 XKB: <AE13>, <AB11> and <KPPT> written after the template's keys only when typed on.
{
	const symbols = (doc) => {
		const out = exportXkb(doc);
		const name = [...out.files.keys()].find((f) => f.endsWith('.xkb'));
		return out.files.get(name).toString();
	};
	const jis = symbols(jisDoc);
	assert.match(jis, /\n\tkey <AE13> \{ type\[group1\] = "[A-Z_]+", \[yen, yen, bar, bar/);
	assert.match(
		jis,
		/\n\tkey <AB11> \{ type\[group1\] = "[A-Z_]+", \[backslash, backslash, underscore/
	);
	assert.doesNotMatch(jis, /<KPPT>/, 'a key the layout leaves empty is not written');
	const abnt = symbols(abntDoc);
	assert.match(abnt, /\n\tkey <AB11> \{[^\n]*\[slash, slash, question, question/);
	assert.match(abnt, /\n\tkey <KPPT> \{[^\n]*\[period, period, NoSymbol/);
	assert.doesNotMatch(abnt, /<AE13>/);
	// The Comparer's XKB reader gives the base characters back on the same keys (it reads
	// levels in the four-level order, not the seven-level type's).
	for (const [doc, text] of [
		[jisDoc, jis],
		[abntDoc, abnt]
	]) {
		const read = F.fromXkb(text);
		for (const code of ['IntlYen', 'IntlRo', 'NumpadComma'])
			if (typed(doc, 'base', code))
				assert.equal(read.layout.rows[code][0], typed(doc, 'base', code), `XKB base ${code}`);
	}
	checks++;
}

// 3.4 The keyboard DLL: every image read back, the JIS type and keys, a lossless round trip.
{
	for (const doc of [jisDoc, abntDoc]) {
		const { model, omitted } = KbdSource.fromSource(clone(doc));
		assert.deepEqual(omitted, [], `${doc.layout.id}: the DLL holds every key`);
		const jis = doc.physical.keyboard === 'jis';
		assert.equal(model.keyboard_type, jis ? 'jis' : undefined);
		const moves = new Map(model.scancodes.map((m) => [m.sc, m.vk]));
		if (jis) {
			// Muhenkan types a character, Henkan and Katakana/Hiragana keep their keys.
			for (const sc of [0x70, 0x79, 0x7b, 0x7d]) assert.equal(moves.get(sc), C.JIS_VKS[sc]);
		} else assert.equal(moves.size, 0, 'the ABNT keys are in the standard table');
		const dlls = PeWriter.writeDlls(model);
		assert.deepEqual(Object.keys(dlls).sort(), ['arm64', 'wow64', 'x64', 'x86']);
		for (const [arch, bytes] of Object.entries(dlls)) {
			const read = readDll(bytes);
			assert.deepEqual(compareLayout(model, read.layout), [], `${doc.layout.id} ${arch}`);
			assert.equal(read.keyboard_type, jis ? 7 : 4, `${arch} dwType`);
			assert.deepEqual(
				read.layout.keyboard_type,
				jis ? { type: 7, subtype: 2 } : { type: 4, subtype: 0 }
			);
			// The wow64 image keeps kbd.h's 64-bit KBD_LONG_POINTER descriptor (EDX:EAX).
			assert.equal(read.descriptor_bits, arch === 'x86' ? 32 : 64, `${arch} descriptor`);
		}
		const back = KbdSource.toSource(model, { id: doc.layout.id });
		assert.equal(back.physical.keyboard, jis ? 'jis' : undefined, 'the JIS keyboard type survives');
		const again = KbdSource.fromSource(Object.assign(back, { exports: doc.exports })).model;
		assert.deepEqual(again, model, `${doc.layout.id}: model -> source -> model`);
	}
	// This tool's own image never states a keyboard type it does not know.
	const { model } = KbdSource.fromSource(clone(jisDoc));
	const image = Buffer.from(PeWriter.writeDlls(model).x64);
	const at = image.indexOf(Buffer.from([7, 0, 0, 0, 2, 0, 0, 0]));
	assert.ok(at > 0, 'dwType 7 and dwSubType 2 are in the image');
	image.writeUInt32LE(0, at + 4);
	assert.throws(() => readDll(image), /keyboard type is neither 4 nor 7/);
	checks++;
}

// =================================================
// ======= 4/ Microsoft's layouts on this PC =======
// =================================================

{
	const system = process.env.SystemRoot || process.env.SYSTEMROOT || 'C:\\Windows';
	const file = (dir, name) => path.join(system, dir, name);
	const present = (f) => process.platform === 'win32' && fs.existsSync(f);
	let read = 0;
	for (const dir of ['System32', 'SysWOW64']) {
		const jpn = file(dir, 'KBDJPN.DLL');
		if (!present(jpn)) continue;
		const bytes = fs.readFileSync(jpn);
		// It carries code (its NLS functions), so only the foreign reading accepts it.
		assert.throws(() => readDll(bytes), /no entry point/);
		const image = readDll(bytes, { foreign: true });
		// Its rows are spread over tables of several widths (the Kana columns in the first).
		const rows =
			image.layout.keys.length + image.layout.extra_tables.reduce((n, t) => n + t.length, 0);
		assert.ok(rows > 40, `${dir} KBDJPN.DLL has its character keys`);
		assert.ok(image.layout.columns.includes(C.MOD_BITS.kana), `${dir} KBDJPN.DLL has Kana columns`);
		read++;
	}
	const kbd106 = file('System32', 'KBD106.DLL');
	if (present(kbd106)) {
		const image = readDll(fs.readFileSync(kbd106), { foreign: true });
		assert.deepEqual(image.layout.keyboard_type, C.KEYBOARD_TYPES.jis, 'KBD106 states 7/2');
		const scan = image.layout.scancodes;
		for (const sc of C.JIS_IME_SCANCODES)
			assert.equal(scan[sc] & 0xff, C.JIS_VKS[sc], `KBD106 0x${sc.toString(16)}`);
		// Its Yen is VK_OEM_5, the type-4 table's Backslash: why the writer takes VK_OEM_AX.
		assert.equal(scan[0x7d] & 0xff, C.VK.OEM_5);
		assert.equal(C.DEFAULT_SCANCODES[0x2b] & 0xff, C.VK.OEM_5);
		read++;
	}
	const br = file('System32', 'KBDBR.DLL');
	if (present(br)) {
		const scan = readDll(fs.readFileSync(br), { foreign: true }).layout.scancodes;
		assert.equal(scan[0x73] & 0xff, C.VK.ABNT_C1, 'KBDBR: Ro is ABNT C1');
		assert.equal(scan[0x7e] & 0xff, C.VK.ABNT_C2, 'KBDBR: the keypad key is ABNT C2');
		read++;
	}
	if (read) checks++;
	else console.log('test-layout-jis-abnt: no Microsoft JIS or ABNT layout here, section 4 skipped');
}

console.log(
	`[OK] JIS and ABNT keyboards: ${checks} checks (boards, analysis, .keylayout, KLC, XKB and DLL round trips, Microsoft layouts)`
);
