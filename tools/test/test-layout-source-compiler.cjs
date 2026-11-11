// tools/test/test-layout-source-compiler.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Compiler Contract
 * DESCRIPTION:
 * Pins the one generator of the layout source: structured import of the
 * registry Ergopti layouts compiles back to the same behaviour state by state,
 * the ANSI derivation reproduces the registry ANSI files, the Linux XKB files
 * of a structured source equal those of the original file byte for byte, the
 * Windows KLC likewise, the committed fixture compiles to its golden
 * .keylayout, the macOS bundle holds ISO and ANSI, and every record no
 * .keylayout carries is reported, never dropped.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { exportXkb } = require('../lib/layout-source-xkb.cjs');
const { exportKlc } = require('../lib/layout-source-klc.cjs');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const Source = loadLayoutSource();
const Composer = Source.composer;
const registry = path.join(REPO_ROOT, 'static', 'layouts', 'registry');
const corpus = shared('tests', 'corpus', 'layouts', 'source');
const read = (file) => fs.readFileSync(file, 'utf8');
const registryXml = (id) => read(path.join(registry, id, `${id}.keylayout`));
const clone = (value) => JSON.parse(JSON.stringify(value));
// The ISO -> ANSI rule of static/ergopti/macos/keylayout_generation/keylayout_ansi_creation.py.
const ERGOPTI_ANSI_SWAPS = [['Backslash', 'BracketRight']];
const PAIRS = [
	['ergopti', 'ergopti_ansi'],
	['ergopti_plus', 'ergopti_plus_ansi']
];
let checks = 0;

/**
 * Behavioural equality of two .keylayout files as macOS runs them: the same
 * modifier selectors in order, and from every reachable pair of dead-key states
 * every key of every keyMap types the same text. State names may differ.
 * @returns {string[]} The differences, empty when equivalent.
 */
function differences(left, right) {
	const a = typeof left === 'string' ? Composer.parseModel(left) : left;
	const b = typeof right === 'string' ? Composer.parseModel(right) : right;
	const tokens = (keys) => keys.map((k) => k.split(/\s+/).filter(Boolean).sort().join(' '));
	const found = [];
	if (a.selects.length !== b.selects.length) return ['keyMapSelect count'];
	a.selects.forEach((select, i) => {
		if (JSON.stringify(tokens(select.keys)) !== JSON.stringify(tokens(b.selects[i].keys)))
			found.push(`keyMapSelect ${i}`);
	});
	const seen = new Set();
	const queue = [['none', 'none']];
	while (queue.length) {
		const [sa, sb] = queue.shift();
		if (seen.has(`${sa}\0${sb}`)) continue;
		seen.add(`${sa}\0${sb}`);
		a.selects.forEach((select, i) => {
			for (let code = 0; code < 128; code++) {
				const x = Composer.step(a, sa, select.index, code);
				const y = Composer.step(b, sb, b.selects[i].index, code);
				if (x.output !== y.output)
					found.push(`${sa}/${sb} map ${i} code ${code}: ${x.output} != ${y.output}`);
				if (x.next !== 'none' || y.next !== 'none') queue.push([x.next, y.next]);
			}
		});
	}
	return found;
}

/** Type a sequence of [keyMap index, macOS code] presses from the neutral state. */
function typed(xml, presses) {
	const model = Composer.parseModel(xml);
	let state = 'none';
	let text = '';
	for (const [index, code] of presses) {
		const result = Composer.step(model, state, index, code);
		text += result.output;
		state = result.next;
	}
	return { text, state };
}

// The oracle can fail: one changed output in the original is a difference.
{
	const xml = registryXml('ergopti');
	const changed = xml.replace(
		'<when state="s1_circumflex" output="â"/>',
		'<when state="s1_circumflex" output="ä"/>'
	);
	assert.notEqual(changed, xml, 'mutation target present');
	assert(differences(xml, changed).length > 0, 'the equivalence oracle sees a changed composition');
	checks++;
}

// Registry round trip: structured import -> TOML -> compile behaves as the original.
const structured = new Map();
for (const id of ['ergopti', 'ergopti_ansi', 'ergopti_plus', 'ergopti_plus_ansi']) {
	const xml = registryXml(id);
	const imported = Source.importStructured(xml, id, 'iso');
	assert.equal(imported.imported_keylayout, undefined, `${id}: structured, not preserved`);
	const text = Source.write(imported);
	const reloaded = Source.read(`# A comment is ordinary TOML.\n${text}`);
	assert.equal(Source.write(reloaded), text, `${id}: deterministic TOML`);
	const compiled = Source.compileKeylayout(reloaded);
	assert.deepEqual(differences(xml, compiled.text), [], `${id}: compiled behaviour`);
	assert.deepEqual(clone(compiled.omitted), [], `${id}: a registry layout loses nothing`);
	assert.equal(
		Composer.parseModel(compiled.text).name,
		Composer.parseModel(xml).name,
		`${id}: name`
	);
	assert.equal(compiled.names.keyboardId, Number(Composer.parseModel(xml).keyboardId), `${id}: id`);
	structured.set(id, reloaded);
	checks++;
}

// Several hardware layouts (Bépo): the ISO map becomes the layers, the ANSI map the
// ANSI variant, its differences from the derivation rule kept in each layer's ansi_keys.
{
	const xml = registryXml('bepo');
	const original = Composer.parseModel(xml);
	const reloaded = Source.read(Source.write(Source.importStructured(xml, 'bepo', 'iso')));
	assert(
		reloaded.layers.some((layer) => layer.ansi_keys),
		'bepo: the ANSI map differs from the rule'
	);
	assert.deepEqual(differences(xml, Source.compileKeylayout(reloaded).text), [], 'bepo: ISO');
	const ansiMap = Object.assign({}, original, { mapSet: 'ANSI' });
	const ansi = Source.compileKeylayout(reloaded, { variant: 'ansi' });
	assert.deepEqual(differences(ansiMap, ansi.text), [], 'bepo: ANSI map');
	// Without its ansi_keys the ANSI variant follows the rule, which Bépo does not.
	const ruleOnly = clone(reloaded);
	for (const layer of ruleOnly.layers) delete layer.ansi_keys;
	assert(
		differences(ansiMap, Source.compileKeylayout(ruleOnly, { variant: 'ansi' }).text).length > 0,
		'bepo: ansi_keys carry the difference'
	);
	// A layout set the records cannot hold is still refused with a stable code.
	assert.throws(
		() => Source.importStructured(xml, 'bepo', 'ansi'),
		/source_import_hardware_layouts/
	);
	assert.throws(
		() =>
			Source.importStructured(
				xml.replace(
					'mapSet="ANSI" modifiers="commonModifiers"/>',
					'mapSet="ISO" modifiers="commonModifiers"/>'
				),
				'bepo',
				'iso'
			),
		/source_import_hardware_layouts/
	);
	checks++;
}

// A printable key at a code no key table names (Ergo-L's 66) is MacCode<n>: kept on
// macOS, listed as omitted by the converter targets, which have no such key.
{
	const xml = registryXml('ergol');
	const reloaded = Source.read(Source.write(Source.importStructured(xml, 'ergol', 'ansi')));
	assert.deepEqual(clone(reloaded.layers[1].keys.MacCode66), { text: '*' }, 'ergol: code 66 named');
	// An ANSI-numbered file is the ANSI variant of the physical source it imports to.
	assert.deepEqual(
		differences(xml, Source.compileKeylayout(reloaded, { variant: 'ansi' }).text),
		[],
		'ergol: behaviour'
	);
	const linux = Source.compileKeylayout(reloaded, { platform: 'linux' });
	assert(
		linux.omitted.some(
			(entry) =>
				entry.path.endsWith('.keys.MacCode66') && entry.reason === 'mac_only_key_code_not_in_linux'
		),
		'ergol: Linux lists code 66'
	);
	// A MacCode name for a code a table names, or out of range, is no key.
	for (const name of ['MacCode0', 'MacCode128', 'MacCode066']) {
		const source = clone(reloaded);
		source.layers[0].keys = { [name]: { text: 'x' } };
		assert(
			Source.compileKeylayout(source).omitted.some((entry) => entry.path.endsWith(`.keys.${name}`)),
			`${name} is not a key`
		);
	}
	checks++;
}

// ISO edits, ANSI derived: the fixed rule reproduces the registry ANSI files.
for (const [iso, ansi] of PAIRS) {
	const source = clone(structured.get(iso));
	source.physical.ansi_swaps = ERGOPTI_ANSI_SWAPS;
	const ansiModel = Composer.parseModel(registryXml(ansi));
	source.exports.macos.ansi_internal_name = ansiModel.name;
	source.exports.macos.ansi_keyboard_id = Number(ansiModel.keyboardId);
	const compiled = Source.compileKeylayout(Source.validate(source), { variant: 'ansi' });
	assert.deepEqual(differences(registryXml(ansi), compiled.text), [], `${iso}: derived ANSI`);
	assert.equal(Composer.parseModel(compiled.text).name, ansiModel.name);
	// Without the declared swaps the derivation moves only the ISO key: it differs.
	delete source.physical.ansi_swaps;
	const extraOnly = Source.compileKeylayout(source, { variant: 'ansi' });
	assert(differences(registryXml(ansi), extraOnly.text).length > 0, `${iso}: the swaps matter`);
	checks++;
}

// Linux: the structured source's XKB files equal the original file's byte for byte.
for (const id of structured.keys()) {
	const original = exportXkb(Source.importKeylayout(registryXml(id), id, 'iso'));
	const compiled = exportXkb(structured.get(id));
	for (const name of [`${id}.xkb`, `${id}.XCompose`, 'xkb_types.txt'])
		assert.equal(compiled.files.get(name), original.files.get(name), `${id}: ${name}`);
	assert.deepEqual(clone(compiled.report.omitted), []);
	checks++;
}

// Windows: the KLC of the structured Ergopti source equals the original's.
{
	const windows = { locale: 'fr-FR', layout_id: '0000040c', dll_name: 'kbdergo' };
	const imported = Source.importKeylayout(registryXml('ergopti'), 'ergopti', 'iso');
	imported.exports = { windows };
	const source = clone(structured.get('ergopti'));
	source.exports.windows = windows;
	const original = exportKlc(imported);
	const compiled = exportKlc(source);
	assert(
		Buffer.from(compiled.files.get('kbdergo.klc')).equals(
			Buffer.from(original.files.get('kbdergo.klc'))
		)
	);
	checks++;
}

// The committed fixture compiles to its golden .keylayout and reports its omissions.
const fixture = Source.read(read(path.join(corpus, 'source.toml')));
const golden = read(path.join(corpus, 'source.keylayout'));
{
	const compiled = Source.compileKeylayout(fixture);
	assert.equal(
		compiled.text,
		golden,
		'regenerate with: npm run layout-source -- export-macos <corpus>/source.toml <new-dir> iso'
	);
	assert.deepEqual(clone(compiled.omitted), [
		{ path: 'modifiers.kana', reason: 'custom_modifier_not_in_keylayout' },
		{ path: 'layers.kana', reason: 'modifier_not_in_keylayout' },
		{ path: 'remap.CapsLock', reason: 'system_or_modifier_key_remap' },
		{ path: 'shortcuts.KeyA', reason: 'shortcut_output_not_in_keylayout' },
		{ path: 'tap_holds.Space', reason: 'tap_hold_not_in_keylayout' },
		{ path: 'layers.command.keys.KeyJ', reason: 'action_not_in_keylayout' }
	]);
	// macOS codes (ISO): KeyA 0, KeyE 14, KeyO 31, KeyW 13, KeyC 8, KeyJ 38,
	// BracketLeft 33, Quote 39, IntlBackslash 50, Backquote 10.
	const vectors = [
		[
			[
				[0, 33],
				[0, 0]
			],
			'â'
		],
		[
			[
				[0, 33],
				[0, 8]
			],
			'ĵ'
		],
		[
			[
				[0, 33],
				[0, 38]
			],
			'^j'
		],
		[
			[
				[0, 33],
				[0, 33]
			],
			'^'
		],
		[
			[
				[0, 33],
				[0, 39],
				[0, 31]
			],
			'ö̂'
		],
		[
			[
				[0, 39],
				[0, 14]
			],
			'ë'
		],
		[[[0, 8]], '★'],
		[[[0, 13]], 'z'],
		[[[0, 12]], 'ffi'],
		[[[1, 12]], 'FFI'],
		[[[2, 0]], 'æ'],
		[
			[
				[2, 14],
				[0, 0]
			],
			'α'
		],
		[[[0, 50]], '<'],
		[[[0, 10]], '$']
	];
	for (const [presses, text] of vectors)
		assert.equal(typed(golden, presses).text, text, JSON.stringify(presses));
	const model = Composer.parseModel(golden);
	assert.equal(Composer.keyMapIndex(model, ['caps']), 1, 'Caps Lock selects the Shift layer');
	assert.equal(
		Composer.keyMapIndex(model, ['option']),
		2,
		'the folded reader sees the right Option layer'
	);
	checks++;
}

// The ANSI variant moves the ISO key and the declared pair.
{
	const ansi = Source.compileKeylayout(fixture, { variant: 'ansi' });
	assert.equal(typed(ansi.text, [[0, 10]]).text, '<', 'the ISO key moved onto Backquote');
	assert.equal(typed(ansi.text, [[0, 50]]).text, '$');
	assert.equal(typed(ansi.text, [[0, 42]]).text, '^', 'Backslash takes BracketRight');
	assert.equal(typed(ansi.text, [[0, 30]]).text, '*');
	assert.equal(ansi.names.internal, 'source_fixture_ansi');
	assert.equal(ansi.names.inputSource, 'com.apple.keyboardlayout.source_fixture.ansi');
	checks++;
}

// The bundle: ISO and ANSI .keylayout, plists keyed by the internal names, UTF-16 strings.
{
	const { files, report } = Source.exportMacos(fixture);
	const root = 'source_fixture.bundle/Contents';
	assert.deepEqual(clone(files.map((file) => file.path)), [
		`${root}/Info.plist`,
		`${root}/version.plist`,
		`${root}/Resources/source_fixture.keylayout`,
		`${root}/Resources/source_fixture_ansi.keylayout`,
		`${root}/Resources/en.lproj/InfoPlist.strings`,
		`${root}/Resources/fr.lproj/InfoPlist.strings`
	]);
	const byPath = new Map(files.map((file) => [file.path, file]));
	assert.equal(byPath.get(`${root}/Resources/source_fixture.keylayout`).text, golden);
	const info = byPath.get(`${root}/Info.plist`).text;
	for (const needle of [
		'<key>KLInfo_source_fixture</key>',
		'<key>KLInfo_source_fixture_ansi</key>',
		'<string>com.apple.keyboardlayout.source_fixture.ansi</string>',
		'<string>fr</string>'
	])
		assert(info.includes(needle), needle);
	const strings = byPath.get(`${root}/Resources/en.lproj/InfoPlist.strings`);
	assert.equal(strings.encoding, 'utf16le');
	assert.equal(
		strings.text,
		'﻿"source_fixture" = "Source Fixture";\n"source_fixture_ansi" = "Source Fixture ANSI";\n'
	);
	assert.equal(report.status, 'partial');
	assert.equal(report.omitted.length, 6);
	for (const format of ['iso', 'ansi']) {
		const single = Source.exportMacos(fixture, format);
		assert.equal(single.files.length, 1);
		assert.equal(single.report.artifact, 'keylayout');
	}
	const collide = clone(fixture);
	collide.exports.macos.ansi_internal_name = 'source_fixture';
	assert.throws(() => Source.exportMacos(collide), /source_duplicate/);
	checks++;
}

// Icons: each variant's PNG becomes its .icns, declared in Info.plist; a single
// .keylayout takes the .icns of its name beside it. Bad or missing PNGs refuse.
{
	const zlib = require('node:zlib');
	const png = (width, height) => {
		const chunk = (type, data) => {
			const head = Buffer.alloc(8);
			head.writeUInt32BE(data.length, 0);
			head.write(type, 4, 'latin1');
			return Buffer.concat([head, data, Buffer.alloc(4)]);
		};
		const ihdr = Buffer.alloc(13);
		ihdr.writeUInt32BE(width, 0);
		ihdr.writeUInt32BE(height, 4);
		ihdr.set([8, 6, 0, 0, 0], 8);
		const pixels = zlib.deflateSync(Buffer.alloc(height * (1 + width * 4)));
		return new Uint8Array(
			Buffer.concat([
				Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
				chunk('IHDR', ihdr),
				chunk('IDAT', pixels),
				chunk('IEND', Buffer.alloc(0))
			])
		);
	};
	const iconic = clone(fixture);
	iconic.exports.macos.icon = 'layout.png';
	iconic.exports.macos.ansi_icon = 'layout_ansi.png';
	const iso = png(32, 32);
	const ansiPng = png(16, 16);
	const { files, report } = Source.exportMacos(iconic, undefined, {
		'layout.png': iso,
		'layout_ansi.png': ansiPng
	});
	const root = 'source_fixture.bundle/Contents';
	const byPath = new Map(files.map((file) => [file.path, file]));
	for (const [name, image, type] of [
		['source_fixture', iso, 'icp5'],
		['source_fixture_ansi', ansiPng, 'icp4']
	]) {
		const icon = Buffer.from(byPath.get(`${root}/Resources/${name}.icns`).bytes);
		assert.equal(icon.toString('latin1', 0, 4), 'icns', `${name}: magic`);
		assert.equal(icon.readUInt32BE(4), icon.length, `${name}: length`);
		assert.equal(icon.toString('latin1', 8, 12), type, `${name}: element type`);
		assert.equal(icon.readUInt32BE(12), 8 + image.length, `${name}: element length`);
		assert(icon.subarray(16).equals(Buffer.from(image)), `${name}: PNG kept`);
		assert(
			byPath
				.get(`${root}/Info.plist`)
				.text.includes(
					`<key>KLInfo_${name}</key>\n\t<dict>\n\t\t<key>TICapsLockLanguageSwitchCapable</key>\n\t\t<true/>\n\t\t<key>TISIconIsTemplate</key>\n\t\t<false/>\n\t\t<key>ICNS</key>\n\t\t<string>${name}.icns</string>`
				),
			`${name}: Info.plist names the icon`
		);
	}
	assert(!report.limitations.some((line) => /generic layout icon/.test(line)), 'no generic icon');
	const single = Source.exportMacos(iconic, 'iso', {
		'layout.png': iso,
		'layout_ansi.png': ansiPng
	});
	assert.deepEqual(clone(single.files.map((file) => file.path)), [
		'source_fixture.keylayout',
		'source_fixture.icns'
	]);
	// The ANSI variant falls back to the ISO icon when it names none of its own.
	delete iconic.exports.macos.ansi_icon;
	const shared = Source.exportMacos(iconic, 'ansi', { 'layout.png': iso });
	assert.equal(Buffer.from(shared.files[1].bytes).toString('latin1', 8, 12), 'icp5');
	assert.throws(() => Source.exportMacos(iconic), /source_icon_missing: exports.macos.icon/);
	assert.throws(
		() => Source.exportMacos(iconic, undefined, { 'layout.png': png(32, 16) }),
		/source_icon_size/
	);
	assert.throws(
		() => Source.exportMacos(iconic, undefined, { 'layout.png': png(48, 48) }),
		/source_icon_size/
	);
	assert.throws(
		() => Source.exportMacos(iconic, undefined, { 'layout.png': new Uint8Array(40) }),
		/source_icon_png/
	);
	for (const bad of ['../x.png', 'x.jpg', '.x.png', 'a/b.png'])
		assert.throws(() => {
			const invalid = clone(fixture);
			invalid.exports.macos.icon = bad;
			Source.exportMacos(invalid);
		}, /source_invalid: exports.macos.icon/);
	// Without an icon the export says the generic icon is shown.
	assert(
		Source.exportMacos(fixture).report.limitations.some((line) => /generic layout icon/.test(line))
	);
	checks++;
}

// Linux and Windows read the same compilation, with their own folds and omissions.
{
	const linux = exportXkb(fixture);
	assert.equal(linux.report.status, 'partial');
	assert.deepEqual(clone(linux.report.omitted.map((entry) => entry.path)), [
		'modifiers.kana',
		'layers.kana',
		'remap.CapsLock',
		'shortcuts.KeyA',
		'tap_holds.Space',
		'layers.base.keys.KeyX',
		'layers.command.keys.KeyJ'
	]);
	const left = clone(fixture);
	left.layers.find((layer) => layer.id === 'option').required = ['alt_left'];
	const sided = Source.targetKeylayout(Source.validate(left), 'linux');
	assert.deepEqual(clone(sided.omitted.find((entry) => entry.path === 'layers.option')), {
		path: 'layers.option',
		reason: 'sided_modifier_not_in_linux'
	});
	assert.throws(
		() => exportKlc(fixture),
		/CAPLOKALTGR/,
		'KLC refuses the Caps+AltGr columns it cannot write'
	);
	checks++;
}

// Schema controls for the records the compiler added to version 1.
{
	const invalid = [
		[
			'rule with two inputs',
			(s) => Object.assign(s.dead_keys[0].rules[0], { input_dead_key: 'greek' })
		],
		[
			'compose_as outside composition',
			(s) => Object.assign(s.layers[0].keys.KeyC, { compose: false })
		],
		[
			'compose on a dead key',
			(s) => Object.assign(s.layers[0].keys.BracketLeft, { compose: true })
		],
		['a key in two ANSI pairs', (s) => s.physical.ansi_swaps.push(['Backslash', 'KeyA'])],
		['the ISO key in a pair', (s) => s.physical.ansi_swaps.push(['IntlBackslash', 'KeyA'])],
		['two dead keys, one state', (s) => Object.assign(s.dead_keys[3], { state: 's3_diaeresis' })],
		[
			'a path in the internal name',
			(s) => Object.assign(s.exports.macos, { internal_name: 'a/b' })
		],
		['a fractional keyboard id', (s) => Object.assign(s.exports.macos, { keyboard_id: 1.5 })],
		['an unknown alternative field', (s) => (s.layers[1].alternatives[0].extra = [])]
	];
	for (const [name, edit] of invalid) {
		const source = clone(fixture);
		edit(source);
		assert.throws(() => Source.validate(source), /SourceError|source_/, name);
	}
	const conflict = clone(fixture);
	conflict.layers[0].keys.KeyO = { text: 'x', compose_as: 'j' };
	assert.throws(() => Source.compileKeylayout(conflict), /source_compose_conflict/);
	const preserved = Source.importKeylayout(registryXml('ergopti'), 'ergopti', 'iso');
	assert.throws(() => Source.compileKeylayout(preserved), /source_imported_preserved/);
	checks++;
}

// CLI: structured import and export-all publish into new directories only.
{
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'layout-source-compiler-'));
	try {
		const cli = (...args) =>
			spawnSync(process.execPath, [path.join(REPO_ROOT, 'tools', 'layout-source.cjs'), ...args], {
				encoding: 'utf8'
			});
		const toml = path.join(temporary, 'ergopti.toml');
		const input = path.join(registry, 'ergopti', 'ergopti.keylayout');
		assert.equal(cli('import-structured', 'ergopti', 'iso', input, toml).status, 0);
		assert.equal(read(toml), Source.write(structured.get('ergopti')));
		assert.notEqual(
			cli('import-structured', 'ergopti', 'iso', input, toml).status,
			0,
			'no overwrite'
		);
		const out = path.join(temporary, 'out');
		const run = cli('export-all', path.join(corpus, 'source.toml'), out);
		assert.equal(run.status, 0, run.stderr);
		const reports = JSON.parse(read(path.join(out, 'report.json')));
		assert.deepEqual(
			reports.map((report) => [report.target, report.status]),
			[
				['macos', 'partial'],
				['linux', 'partial'],
				['windows', 'unavailable']
			]
		);
		assert(
			fs.existsSync(path.join(out, 'macos', 'source_fixture.bundle', 'Contents', 'Info.plist'))
		);
		assert(fs.existsSync(path.join(out, 'linux', 'source_fixture.xkb')));
		assert(!fs.existsSync(path.join(out, 'windows')), 'a refused target writes nothing');
		const bom = fs.readFileSync(
			path.join(
				out,
				'macos',
				'source_fixture.bundle',
				'Contents',
				'Resources',
				'en.lproj',
				'InfoPlist.strings'
			)
		);
		assert.deepEqual([...bom.subarray(0, 2)], [0xff, 0xfe], 'UTF-16LE byte-order mark');
		assert.notEqual(
			cli('export-all', path.join(corpus, 'source.toml'), out).status,
			0,
			'no overwrite'
		);
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
	checks++;
}

console.log(
	`[OK] layout source compiler: ${checks} contract groups (registry round trips, ANSI derivation, XKB/KLC byte equality, fixture golden, bundle, omissions, schema, CLI)`
);
