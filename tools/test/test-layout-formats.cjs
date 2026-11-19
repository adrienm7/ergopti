// tools/test/test-layout-formats.cjs

/**
 * ==============================================================================
 * MODULE: Layout File Formats Gate
 * DESCRIPTION:
 * _shared/ui/layout_analysis/layout_formats.js reads the layout files people
 * have (KLA JSON, Kalamine TOML and JSON, XKB symbols, KLC, .keylayout, DOF,
 * cmini, genkey, plain rows) and writes Ergopti sources, KLA JSON, Kalamine
 * TOML, DOF, genkey and cmini.
 * This gate holds it to real files of the repository.
 *
 * WHAT IS CHECKED:
 * 1. One layout, four files: the Kalamine source of Ergopti 1DK v2.1.2 and the
 *    JSON, KLC and XKB Kalamine built from it give the same key sequence for
 *    every character, apart from the listed format limits; Kalamine's
 *    .keylayout of it is refused with its reason, and the registry's bépo
 *    .keylayout reads to the library's entry.
 * 2. KLA: Ergopti's published ISO and ErgoDox JSON files place the same
 *    characters on the same physical keys, and the ErgoDox key indexes are
 *    those of KLA's own ErgoDox QWERTY key set.
 * 3. Writers: every imported layout becomes an Ergopti source the source
 *    model validates; Kalamine TOML and KLA JSON read back to what was written.
 * 4. Plain rows, DOF and cmini blocks; unknown and malformed files refused.
 * 5. Third-party files (tools/test/fixtures/layout-formats/third-party, their
 *    sources and licences in its README): Ergo-L's own Kalamine TOML and the
 *    JSON its project publishes give the same keys, the TOML reporting only
 *    the dead keys whose rules Kalamine keeps built in; Kalamine's qwerty-prog
 *    example reads on its ANSI board; four of KLA's own built-in layouts (its
 *    european, standard and ergodox boards) read with their home row, the
 *    ErgoDox keys the ISO model lacks named as unread; each becomes a valid
 *    Ergopti source.
 * 6. KbdEdit .kbe: every committed KbdEdit export is recognised by its header
 *    (as bytes, renamed, or as text) and refused as encrypted, a truncated one
 *    as damaged; a ratchet keeps the evidence that the body is encrypted.
 * 7. KLA and KLAnext JSON: every committed ISO and ErgoDox file reads, names
 *    the keys the ISO board lacks with what they type, and import, export,
 *    import gives the same layout.
 * 8. .keylayout: bépo, KbdEdit's own .keylayout exports and the Ergopti
 *    bundle (ISO and ANSI) read, compile back through the source compiler to a
 *    file that follows Apple's schema, and read to the same layout; a KLAnext
 *    layout written as a .keylayout types the same keys.
 * 9. KLAnext's matrix board maps each index to the key its own QWERTY types
 *    there, and a matrix file's keys are placed by id; xkeyboard-config's
 *    bépo and Esperanto XKB symbols, Colemak Mod-DH's UTF-8 and UTF-16 KLC
 *    files and libdof's own DOF examples read with what they type and what
 *    they leave out; a genkey layout reads from a file without an extension;
 *    every real layout written as DOF, genkey and cmini reads back to the
 *    same keys, the losses named.
 * 10. Malformed files (hand-made, and real ones cut short or overwritten from
 *    a fixed seed) are refused with a stable code, never a crash.
 * 11. Every refusal and loss has words in all 21 locales; the app's native
 *    open panel offers the pages' file types; the editor's interoperability
 *    downloads have words and a file type the hosts write; a UTF-16 KLC
 *    decodes.
 * 12. Share links (share-link-fragment): the Comparer's own layouts written in
 *    a link's fragment read back to the same keys and dead keys; a fragment
 *    from another version, cut, damaged, too large or holding a layout the
 *    engine refuses (an unknown key, a bad cell, an unknown field) is refused
 *    whole with its stable code.
 * 13. KLA thumb keys: an ErgoDox file with a letter on a thumb key reads its
 *    thumbs to the model's thumb keys (a lone capital as its letter's Shift,
 *    the big keys first, a key beyond the codes named), a space-only file
 *    still reads the space bar, and the ErgoDox export reads back the same.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { parse: parseToml } = require('smol-toml');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');
const { loadLayoutSource } = require('../lib/layout-source.cjs');

const UI = shared('ui');
const KALAMINE_DIR = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'old', 'kalamine', '1dk');
const BUILT = path.join(KALAMINE_DIR, '2.1.2');
const KLA_ISO = path.join(REPO_ROOT, 'static', 'layouts', 'kla_iso', 'ergopti.v2.2.0.fr.iso.json');
const KLA_ERGODOX = path.join(
	REPO_ROOT,
	'static',
	'layouts',
	'kla_ergodox',
	'ergopti.v2.2.0.fr.ergodox.json'
);
// Characters a format cannot carry the same way, with the reason.
const FORMAT_LIMITS = {
	// The 1dk pressed twice chains to the diaeresis dead key; only the TOML says so.
	json: ['¨'],
	klc: ['¨'],
	// XKB puts the 1dk layer on Level5, which the four-level reader reports.
	xkb: 'one_dead_key_layer'
};
// Floor: the shared layout must type at least this many characters.
const MIN_CHARACTERS = 150;

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};

// The page's globals the readers use: TextDecoder decodes a picked file's bytes.
const sandbox = {
	TextDecoder,
	TextEncoder,
	Blob,
	CompressionStream,
	DecompressionStream,
	atob,
	btoa
};
vm.createContext(sandbox);
for (const file of [
	'layout_analysis/_generated/analysis_data.js',
	'layout_analysis/analysis_engine.js',
	'layout_analysis/layout_formats.js',
	'layout_composer/_generated/composer_data.js',
	'layout_composer/composer_model.js',
	'layout_composer/source_model.js'
])
	vm.runInContext(fs.readFileSync(path.join(UI, file), 'utf8'), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const F = vm.runInContext('LAYOUT_FORMATS', sandbox);
const DATA = vm.runInContext('LAYOUT_ANALYSIS_DATA', sandbox);
const Composer = vm.runInContext('LayoutComposer', sandbox);
const Source = vm.runInContext('LayoutSource', sandbox);
const TABLE = vm.runInContext('LAYOUT_COMPOSER_DATA', sandbox);
const board = E.keyboard('iso');

/** Whether two plain objects hold the same entries, in any order. */
const same = (a, b) =>
	JSON.stringify(Object.entries(a).sort()) === JSON.stringify(Object.entries(b).sort());

/** Character → key sequence of a layout, substitutes excluded. */
function sequences(layout) {
	const out = {};
	for (const [char, seq] of E.compileLayout(E.layoutFromRows(layout), board, null))
		if (!seq.substituted) out[char] = seq.keys.join(',');
	return out;
}

// ===============================================
// ======= 1/ One layout, five file formats ======
// ===============================================

const klcText = new TextDecoder('utf-16le')
	.decode(fs.readFileSync(path.join(BUILT, 'ergo_1dk.klc')))
	.replace(/^﻿/, '');
const read = {
	toml: F.fromKalamineToml(
		parseToml(fs.readFileSync(path.join(KALAMINE_DIR, 'ergo_1dk_v2.1.2.toml'), 'utf8'))
	),
	json: F.fromKalamineJson(JSON.parse(fs.readFileSync(path.join(BUILT, 'ergo_1dk.json'), 'utf8'))),
	klc: F.fromKlc(klcText, DATA.scancodes),
	xkb: F.fromXkb(fs.readFileSync(path.join(BUILT, 'ergo_1dk.xkb_symbols'), 'utf8'))
};
const reference = sequences(read.toml.layout);
check(
	Object.keys(reference).length >= MIN_CHARACTERS,
	`TOML types only ${Object.keys(reference).length} characters`
);
for (const [format, result] of Object.entries(read)) {
	if (format === 'toml') continue;
	const got = sequences(result.layout);
	const differing = Array.from(new Set(Object.keys(reference).concat(Object.keys(got)))).filter(
		(char) => reference[char] !== got[char]
	);
	if (FORMAT_LIMITS[format] === 'one_dead_key_layer') {
		// Every character XKB types the TOML types the same way; the rest are 1dk.
		// A character the TOML reaches through the 1dk at the same cost is not a difference.
		const wrong = Object.keys(got).filter(
			(char) => reference[char] !== got[char] && reference[char].split(',').length === 1
		);
		check(wrong.length === 0, `xkb types ${wrong.join(' ')} differently`);
		check(
			result.unmapped.some((u) => u.what === 'keysym' && /ISO_Level5_Latch/.test(u.detail)),
			'xkb: the 1dk level is not reported'
		);
		const odk = Object.keys(read.toml.layout.dead.odk).filter((typed) => typed !== ' ');
		check(odk.length > 10, 'toml: no 1dk table');
	} else {
		const allowed = new Set(FORMAT_LIMITS[format]);
		const unexpected = differing.filter((char) => !allowed.has(char));
		check(unexpected.length === 0, `${format} differs from the TOML on ${unexpected.join(' ')}`);
	}
}

// Kalamine's own .keylayout of that layout names an action it never defines:
// the reader refuses it with the reason instead of guessing.
const keylayoutTools = { composer: Composer, table: TABLE, analysis: E };
const kalamineKeylayout = fs.readFileSync(path.join(BUILT, 'ergo_1dk.keylayout'), 'utf8');
let refusal = null;
try {
	F.fromKeylayout(kalamineKeylayout, 'ergo_1dk', 'iso', keylayoutTools);
} catch (error) {
	refusal = error;
}
check(
	refusal && refusal.code === 'format_invalid' && /undefined_action/.test(refusal.detail),
	'Kalamine .keylayout: no reasoned refusal'
);
// A registry .keylayout reads to the library's own entry.
const bepoFile = path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'bepo', 'bepo.keylayout');
const bepo = F.fromKeylayout(fs.readFileSync(bepoFile, 'utf8'), 'bepo', 'iso', keylayoutTools);
const library = E.libraryLayouts().find((layout) => layout.id === 'bepo');
check(
	same(sequences(bepo.layout), sequences(library)),
	'.keylayout: bépo does not read to the library entry'
);

// ==========================
// ======= 2/ KLA files =====
// ==========================

const klaIso = F.fromKla(JSON.parse(fs.readFileSync(KLA_ISO, 'utf8')));
const klaErgodox = F.fromKla(JSON.parse(fs.readFileSync(KLA_ERGODOX, 'utf8')));
check(klaIso.layout.rows.KeyD[0] === 'e', `KLA ISO: KeyD types ${klaIso.layout.rows.KeyD[0]}`);
let compared = 0;
for (const code of [
	'KeyA',
	'KeyS',
	'KeyD',
	'KeyF',
	'KeyJ',
	'KeyK',
	'KeyL',
	'KeyE',
	'KeyR',
	'KeyU',
	'KeyI',
	'KeyM'
]) {
	check(
		// The ErgoDox file leaves some Shift+AltGr cells empty: base and Shift are compared.
		JSON.stringify(klaIso.layout.rows[code].slice(0, 2)) ===
			JSON.stringify(klaErgodox.layout.rows[code].slice(0, 2)),
		`KLA: ${code} differs between the ISO and ErgoDox files`
	);
	compared++;
}
// KLA's own ErgoDox key set: the primary character of every index of
// KB.keySet.ergodox.qwerty in common/pat/keyboard/js/kb.js (MIT, commit
// c4f2f9bb43ca8de98c8cb0cd28a78043602c7dcb). Each character index must map to
// the physical key that types it in QWERTY, and no other index may carry a key:
// 27 is Backslash and 60-62 the brackets and quote there, whatever a third-party
// ErgoDox file chooses to put on them.
const KLA_ERGODOX_QWERTY =
	"1 1 2 2 3 3 4 4 5 5 6 - 7 = 8 6 9 7 10 8 11 9 12 0 15 q 16 w 17 e 18 r 19 t 22 y 23 u 24 i 25 o 26 p 27 \\ 29 a 30 s 31 d 32 f 33 g 34 h 35 j 36 k 37 l 38 ; 41 z 42 x 43 c 44 v 45 b 48 n 49 m 50 , 51 . 52 / 58 ` 60 [ 61 ] 62 ' 66 space 74 space";
const QWERTY_CODE = {
	space: 'Space',
	'-': 'Minus',
	'=': 'Equal',
	'\\': 'Backslash',
	';': 'Semicolon',
	',': 'Comma',
	'.': 'Period',
	'/': 'Slash',
	'`': 'Backquote',
	'[': 'BracketLeft',
	']': 'BracketRight',
	"'": 'Quote'
};
const klaErgodoxExpected = {};
const klaErgodoxTokens = KLA_ERGODOX_QWERTY.split(' ');
for (let i = 0; i < klaErgodoxTokens.length; i += 2) {
	const char = klaErgodoxTokens[i + 1];
	klaErgodoxExpected[klaErgodoxTokens[i]] =
		QWERTY_CODE[char] ?? (/[0-9]/.test(char) ? `Digit${char}` : `Key${char.toUpperCase()}`);
}
check(
	JSON.stringify(F.KLA_KEYS.ergodox) === JSON.stringify(klaErgodoxExpected),
	`KLA ErgoDox key indexes differ from KLA's own key set: ${JSON.stringify(F.KLA_KEYS.ergodox)}`
);

// ========================
// ======= 3/ Writers =====
// ========================

for (const [format, result] of Object.entries(Object.assign({}, read, { kla: klaIso }))) {
	const source = F.toSource(result.layout);
	try {
		Source.validate(source);
	} catch (error) {
		check(false, `${format}: toSource is invalid (${error.code} ${error.path})`);
	}
}
const singleCharacterLayers = (layout, codes) =>
	JSON.stringify(
		codes.map((code) =>
			(layout.rows[code] || [null, null, null, null]).map((cell) =>
				typeof cell === 'string' && Array.from(cell).length === 1 ? cell : null
			)
		)
	);
const isoCodes = Object.values(F.XKB_KEYS).filter((code) => code !== 'Space');
const kalamine = F.toKalamineToml(read.toml.layout);
const back = F.fromKalamineToml(parseToml(kalamine.text));
check(
	singleCharacterLayers(back.layout, isoCodes) ===
		singleCharacterLayers(read.toml.layout, isoCodes),
	'Kalamine TOML does not read back to the same keys'
);
const kla = F.toKla(read.toml.layout, DATA.model.fingerings.standard);
const klaBack = F.fromKla(JSON.parse(JSON.stringify(kla)));
const klaCodes = Object.values(F.KLA_KEYS.european).filter((code) => code !== 'Space');
const plain = (layout) => {
	const copy = JSON.parse(JSON.stringify(layout));
	for (const row of Object.values(copy.rows))
		row.forEach((cell, i) => {
			if (typeof cell !== 'string') row[i] = null;
		});
	return copy;
};
check(
	singleCharacterLayers(klaBack.layout, klaCodes) ===
		singleCharacterLayers(plain(read.toml.layout), klaCodes),
	'KLA JSON does not read back to the same keys'
);

// ==================================
// ======= 4/ Rows and refusals =====
// ==================================

const text = F.fromRows(
	'q w f p b j l u y ;\na r s t g m n e i o\nz x c d v k h , . /',
	'colemak_dh'
);
check(
	text.layout.rows.KeyS[0] === 'r' && text.layout.rows.KeyS[1] === 'R',
	'rows: KeyS is not r / R'
);
const dof = F.fromRows({
	name: 'dof test',
	board: 'ortho',
	layers: { main: ['a b', 'c d', 'e f'] }
});
check(dof.format === 'dof' && dof.layout.rows.KeyZ[0] === 'e', 'dof: KeyZ is not e');
const cmini = F.fromRows({
	name: 'cmini test',
	board: 'angle',
	keys: { x: { row: 1, col: 3, finger: 'LI' } }
});
check(cmini.format === 'cmini' && cmini.layout.rows.KeyF[0] === 'x', 'cmini: KeyF is not x');
check(cmini.layout.fingering === 'angle', 'cmini: an angle board keeps the angle fingering');
const refuses = (fn, code) => {
	try {
		fn();
		return false;
	} catch (error) {
		return error.code === code;
	}
};
check(
	refuses(() => F.read('layout.bin', 'nothing', {}), 'format_unknown'),
	'an unknown file is not refused'
);
check(
	refuses(() => F.fromKlc('KBD x "y"\n', DATA.scancodes), 'format_invalid'),
	'a KLC without SHIFTSTATE is accepted'
);
check(
	refuses(() => F.fromKla({ keyboardType: 'moon', keys: [] }), 'format_unsupported_board'),
	'an unknown KLA board is accepted'
);

// 5/ Third-party files, as their projects publish them.
const THIRD_PARTY = path.join(
	REPO_ROOT,
	'tools',
	'test',
	'fixtures',
	'layout-formats',
	'third-party'
);
const thirdParty = (file) =>
	F.read(file, fs.readFileSync(path.join(THIRD_PARTY, file), 'utf8'), {
		parseToml,
		scancodes: DATA.scancodes
	});
const ergolToml = thirdParty('ergol.toml');
const ergolJson = thirdParty('ergol.json');
const prog = thirdParty('kalamine-qwerty-prog.toml');
check(
	ergolToml.format === 'kalamine_toml' && ergolJson.format === 'kalamine_json',
	'Ergo-L formats'
);
check(
	same(ergolToml.layout.rows, ergolJson.layout.rows),
	"Ergo-L: the TOML and the project's JSON give other keys"
);
check(
	JSON.stringify(ergolToml.layout.rows.KeyQ) ===
		JSON.stringify(['q', 'Q', '^', { dead: 'circumflex' }]) &&
		JSON.stringify(ergolToml.layout.rows.KeyO[0]) === JSON.stringify({ dead: 'odk' }),
	`Ergo-L: KeyQ ${JSON.stringify(ergolToml.layout.rows.KeyQ)}, its one dead key on KeyO`
);
check(ergolJson.unmapped.length === 0, `Ergo-L JSON: ${JSON.stringify(ergolJson.unmapped)}`);
check(
	JSON.stringify(ergolToml.unmapped.map((u) => u.what + ':' + u.detail).sort()) ===
		JSON.stringify(['dead_key_rules:currency', 'dead_key_rules:greek', 'dead_key_rules:stroke']),
	`Ergo-L TOML: only Kalamine's built-in dead keys go unread, got ${JSON.stringify(ergolToml.unmapped)}`
);
check(
	prog.layout.name === 'qwerty-prog' &&
		JSON.stringify(prog.layout.rows.KeyQ) === JSON.stringify(['q', 'Q', '=', null]) &&
		prog.unmapped.length === 0,
	`Kalamine qwerty-prog: ${JSON.stringify(prog.layout.rows.KeyQ)} ${JSON.stringify(prog.unmapped)}`
);
// KLA's own built-in layouts, one per board: the home row each one types, and
// the keys only KLA's ErgoDox board has (index 39, its QWERTY Enter, among
// them) named as unread instead of dropped.
const klaThirdParty = {
	'kla-european.azerty.json': { name: 'AZERTY', home: 'qsdfghjklm', unmapped: [] },
	'kla-european.bepo.json': { name: 'BÉPO', home: 'auie,ctsrn', unmapped: [] },
	'kla-standard.dvorakmod.json': {
		name: 'Dvorak IU Swap W/ caps as backspace',
		home: 'aoeiudhtns',
		unmapped: []
	},
	'kla-ergodox.workman.json': {
		name: 'Ergodox/Workman/Cub',
		home: 'ashtgyneoi',
		unmapped: ['key:0 (~ `)', 'key:13 (= +)', 'key:39 (- _)', 'key:75 ( )']
	}
};
const HOME_ROW = [
	'KeyA',
	'KeyS',
	'KeyD',
	'KeyF',
	'KeyG',
	'KeyH',
	'KeyJ',
	'KeyK',
	'KeyL',
	'Semicolon'
];
const klaResults = [];
for (const [file, expected] of Object.entries(klaThirdParty)) {
	const result = thirdParty(file);
	const home = HOME_ROW.map((code) => result.layout.rows[code]?.[0] ?? '?').join('');
	const unmapped = result.unmapped.map((u) => `${u.what}:${u.detail}`);
	check(
		result.format === 'kla' &&
			result.layout.name === expected.name &&
			home === expected.home &&
			JSON.stringify(unmapped) === JSON.stringify(expected.unmapped),
		`${file}: ${result.format} « ${result.layout.name} », home row ${home}, unread ${JSON.stringify(unmapped)}`
	);
	klaResults.push([file, result]);
}
// The library's KLA layouts are the reader's reading of KLA's published files
// (tools/build/import-kla-layouts.cjs): the codegen keeps every key and level
// and completes nothing; a file left out names its reason, a duplicate the
// layout it repeats; all 107 files are accounted for.
{
	const library = JSON.parse(
		fs.readFileSync(shared('layouts', 'data', 'analysis', 'layout_library.json'), 'utf8')
	);
	const imported = new Map(
		library.layouts.filter((e) => e.source === 'kla').map((e) => [e.source_path, e.id])
	);
	const left = new Map(
		library.not_imported.filter((e) => e.source === 'kla').map((e) => [e.source_path, e])
	);
	const KLA_BUILT_IN = 107;
	check(
		imported.size + left.size === KLA_BUILT_IN,
		`KLA library: ${imported.size} imported and ${left.size} left out, not ${KLA_BUILT_IN} files`
	);
	const dvorakmod = DATA.layouts.find((l) => l.id === imported.get('layouts/standard.dvorakmod'));
	const read = klaResults.find(([file]) => file === 'kla-standard.dvorakmod.json')[1];
	check(
		dvorakmod !== undefined && dvorakmod.source === 'kla' && same(dvorakmod.rows, read.layout.rows),
		'KLA library: Dvorak IU Swap is not the reader’s reading of KLA’s file'
	);
	for (const [file, sameAs] of [
		['layouts/european.bepo', 'bepo'],
		['layouts/european.azerty', 'azerty']
	])
		check(left.get(file)?.same_as === sameAs, `KLA library: ${file} is not left out as ${sameAs}`);
	check(
		/no code for: ~ ` = \+ - _$/.test(left.get('layouts/ergodox.workman')?.reason || ''),
		'KLA library: the ErgoDox Workman does not name the characters it would lose'
	);
}
for (const [name, result] of [
	['ergol.toml', ergolToml],
	['ergol.json', ergolJson],
	['kalamine-qwerty-prog.toml', prog],
	...klaResults
])
	try {
		Source.validate(F.toSource(result.layout));
	} catch (error) {
		check(false, `${name}: toSource is invalid (${error.code} ${error.path})`);
	}

// ===================================================
// ======= 6/ KbdEdit .kbe: recognised, refused ======
// ===================================================

const kbeFiles = [
	path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'bepo', 'kbdedit'),
	path.join(REPO_ROOT, 'static', 'ergopti', 'windows'),
	path.join(REPO_ROOT, 'static', 'ergopti', 'windows', '0_old')
].flatMap((dir) =>
	fs
		.readdirSync(dir)
		.filter((file) => file.endsWith('.kbe'))
		.map((file) => path.join(dir, file))
);
check(kbeFiles.length >= 10, `only ${kbeFiles.length} KbdEdit samples found`);
const thrown = (fn) => {
	try {
		fn();
		return null;
	} catch (error) {
		return error;
	}
};
for (const file of kbeFiles) {
	const bytes = new Uint8Array(fs.readFileSync(file));
	const name = path.basename(file);
	const fromBytes = thrown(() => F.readBytes(name, bytes, {}));
	check(
		fromBytes && fromBytes.code === 'format_kbe_encrypted' && fromBytes.detail === 'kbe version 5',
		`${name}: not refused as an encrypted .kbe (${fromBytes && fromBytes.message})`
	);
	// Renamed, it is still recognised by its header; as text (a host that sends
	// text), by its signature.
	const renamed = thrown(() => F.readBytes('layout.json', bytes, {}));
	check(renamed && renamed.code === 'format_kbe_encrypted', `${name}: renamed, not recognised`);
	const asText = thrown(() => F.read(name, F.decode(bytes), {}));
	check(asText && asText.code === 'format_kbe_encrypted', `${name}: as text, not recognised`);
	const cut = thrown(() => F.readBytes(name, bytes.subarray(0, bytes.length - 1), {}));
	check(
		cut && cut.code === 'format_invalid',
		`${name}: a truncated .kbe is not refused as damaged`
	);
}
const notKbe = thrown(() => F.readBytes('x.kbe', new TextEncoder().encode('{"keys": []}'), {}));
check(notKbe && notKbe.code === 'format_invalid', 'a .kbe without the signature is not refused');
// Why .kbe is refused, kept as a ratchet: two KbdEdit exports of Ergopti that
// differ by a few keys share no 8-byte run after the header, so the body is
// encrypted, not merely compressed. If a KbdEdit release writes it plainly,
// this fails and the reader can be written.
const kbeBody = (version) =>
	fs
		.readFileSync(path.join(REPO_ROOT, 'static', 'ergopti', 'windows', `Ergopti_v${version}.kbe`))
		.subarray(31);
const runs = new Set();
const older = kbeBody('2.2.0');
for (let i = 0; i + 8 <= older.length; i++) runs.add(older.subarray(i, i + 8).toString('hex'));
const newer = kbeBody('2.2.1');
let sharedRuns = 0;
for (let i = 0; i + 8 <= newer.length; i++)
	if (runs.has(newer.subarray(i, i + 8).toString('hex'))) sharedRuns++;
check(
	sharedRuns === 0,
	`two .kbe bodies share ${sharedRuns} 8-byte runs: the format may be readable now`
);

// ==========================================================
// ======= 7/ KLA and KLAnext JSON: every real file, back ===
// ==========================================================

/** Dead-key states renamed in the order they are reached, so two readings compare. */
function canonical(layout) {
	const names = new Map();
	const queue = [];
	const nameOf = (state) => {
		if (!names.has(state)) {
			names.set(state, `d${names.size}`);
			queue.push(state);
		}
		return names.get(state);
	};
	const cell = (value) =>
		value && typeof value === 'object' ? { dead: nameOf(value.dead) } : value;
	const rows = {};
	for (const code of Object.keys(layout.rows).sort()) rows[code] = layout.rows[code].map(cell);
	const dead = {};
	for (let i = 0; i < queue.length; i++) {
		const rules = layout.dead[queue[i]] || {};
		const out = {};
		for (const typed of Object.keys(rules).sort())
			out[typed.startsWith('dead:') ? `dead:${nameOf(typed.slice(5))}` : typed] = cell(
				rules[typed]
			);
		dead[names.get(queue[i])] = out;
	}
	return JSON.stringify({ rows, dead });
}

const klaDirs = ['kla_iso', 'kla_ergodox'].flatMap((board) => [
	path.join(REPO_ROOT, 'static', 'layouts', board),
	path.join(REPO_ROOT, 'static', 'layouts', board, 'others')
]);
const klaFiles = klaDirs.flatMap((dir) =>
	fs
		.readdirSync(dir)
		.filter((file) => file.endsWith('.json'))
		.map((file) => path.join(dir, file))
);
check(klaFiles.length >= 40, `only ${klaFiles.length} KLAnext files found`);
const lossKinds = new Set();
let klaRoundTrips = 0;
for (const file of klaFiles) {
	const name = path.relative(REPO_ROOT, file);
	const first = F.read(path.basename(file), fs.readFileSync(file, 'utf8'), {});
	first.unmapped.forEach((entry) => lossKinds.add(entry.what));
	// A key the ISO board lacks is named with what it types, never dropped silently.
	for (const entry of first.unmapped)
		check(
			entry.what === 'key' && /^\d+ \(.+\)$/.test(entry.detail),
			`${name}: unclear loss ${JSON.stringify(entry)}`
		);
	const written = F.toKla(first.layout, DATA.model.fingerings.standard);
	const back = F.fromKla(JSON.parse(JSON.stringify(written)));
	check(
		back.unmapped.length === 0,
		`${name}: the written KLA JSON loses ${back.unmapped.length} key(s)`
	);
	check(back.layout.name === first.layout.name, `${name}: the name does not come back`);
	check(
		canonical(back.layout) === canonical(first.layout),
		`${name}: import, export, import gives another layout`
	);
	klaRoundTrips++;
}

// ===============================================================
// ======= 8/ .keylayout: import, export, import on real files ===
// ===============================================================

// The writer of a .keylayout is the layout source compiler, which the editor
// runs on the source toSource builds; the round trip goes through both.
const Compiler = loadLayoutSource();
const exportKeylayout = (layout) =>
	Compiler.exportMacos(JSON.parse(JSON.stringify(F.toSource(layout))), 'iso').files[0].text;
const MACOS = path.join(REPO_ROOT, 'static', 'ergopti', 'macos');
const keylayoutFiles = [
	[bepoFile, 'iso'],
	...fs
		.readdirSync(path.join(MACOS, 'raw_kbdedit_keylayouts'))
		.filter((file) => file.endsWith('.keylayout'))
		.map((file) => [path.join(MACOS, 'raw_kbdedit_keylayouts', file), 'iso']),
	...['', '_ansi', '_plus', '_plus_ansi'].map((variant) => [
		path.join(
			MACOS,
			'bundles',
			'Ergopti_v2.2.2.bundle',
			'Contents',
			'Resources',
			`Ergopti_v2_2_2${variant}.keylayout`
		),
		variant.endsWith('ansi') ? 'ansi' : 'iso'
	])
];
let keylayoutRoundTrips = 0;
for (const [file, convention] of keylayoutFiles) {
	const name = path.relative(REPO_ROOT, file);
	const first = F.fromKeylayout(
		fs.readFileSync(file, 'utf8'),
		path.basename(file, '.keylayout'),
		convention,
		keylayoutTools
	);
	check(
		Object.keys(first.layout.rows).length >= 48,
		`${name}: only ${Object.keys(first.layout.rows).length} keys`
	);
	const text = exportKeylayout(first.layout);
	// Apple's schema (KeyboardLayout.dtd, which the file declares): a keyboard
	// with its group, a custom (negative) id and a name, then layouts, a
	// modifierMap and keyMapSets, in that order.
	const schema = [
		/^<\?xml version="1\.1" encoding="UTF-8"\?>\n/,
		/<!DOCTYPE keyboard SYSTEM "file:\/\/localhost\/System\/Library\/DTDs\/KeyboardLayout\.dtd">/,
		/<keyboard group="\d+" id="-\d+"( maxout="\d+")? name="[^"]+">\s*<layouts>[\s\S]*<\/layouts>\s*<modifierMap [\s\S]*<keyMapSet [\s\S]*<\/keyboard>\s*$/
	];
	check(
		schema.every((pattern) => pattern.test(text)),
		`${name}: the written .keylayout does not follow Apple's schema`
	);
	const back = F.fromKeylayout(text, first.layout.id, 'iso', keylayoutTools);
	check(
		canonical(back.layout) === canonical(first.layout),
		`${name}: import, export, import gives another layout`
	);
	keylayoutRoundTrips++;
}
// Across formats: a KLAnext file written as a .keylayout types the same keys.
const klaAsKeylayout = F.fromKeylayout(
	exportKeylayout(klaIso.layout),
	'kla',
	'iso',
	keylayoutTools
);
check(
	singleCharacterLayers(klaAsKeylayout.layout, klaCodes) ===
		singleCharacterLayers(klaIso.layout, klaCodes),
	'a KLAnext layout written as a .keylayout types other keys'
);
// A Ctrl/Cmd shortcut kept on another key than its letter (the optimizer's
// kept QWERTY shortcuts) survives the source and the .keylayout: toSource
// dropped the command map until 2026-11-18, so « Open in the editor » lost it.
{
	const azerty = E.libraryLayouts().find((layout) => layout.id === 'azerty');
	const moved = JSON.parse(JSON.stringify(azerty));
	moved.id = 'kept_shortcuts';
	[moved.rows.KeyW, moved.rows.KeyZ] = [moved.rows.KeyZ, moved.rows.KeyW];
	moved.command = { KeyZ: 'w', KeyW: 'z' };
	const source = F.toSource(moved);
	try {
		Source.validate(source);
	} catch (error) {
		check(false, `kept shortcuts: toSource is invalid (${error.code} ${error.path})`);
	}
	const back = F.fromKeylayout(exportKeylayout(moved), moved.id, 'iso', keylayoutTools);
	check(
		back.layout.command.KeyZ === 'w' && back.layout.command.KeyW === 'z',
		`kept shortcuts: the command map comes back as ${JSON.stringify(back.layout.command)}`
	);
}

// ====================================================================
// ======= 9/ KLAnext matrix, XKB, KLC, DOF, genkey, cmini: real files ===
// ====================================================================

// KLAnext's matrix board: the primary character of every index of KLAnext's
// own QWERTY on it (klanext.keyboard-design.com, layouts/qwerty.en.matrix.json,
// read on 2026-11-17; no licence is stated, so only these facts are kept, not
// the file). Each character index maps to the key that types it in QWERTY;
// Tab, the modifiers, Backspace, Enter, the page and arrow keys and the centre
// block (66-94) carry none.
const KLANEXT_MATRIX_QWERTY =
	"0 ` 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 0 11 \\ 13 q 14 w 15 e 16 r 17 t 18 y 19 u 20 i 21 o 22 p 23 = 25 a 26 s 27 d 28 f 29 g 30 h 31 j 32 k 33 l 34 ; 35 ' 37 z 38 x 39 c 40 v 41 b 44 n 45 m 46 , 47 . 48 / 52 [ 53 - 54 ] 56 space";
const matrixTokens = KLANEXT_MATRIX_QWERTY.split(' ');
const matrixExpected = {};
const matrixKeys = Array.from({ length: 95 }, (_, id) => ({ id, primary: -1, shift: -1 }));
for (let i = 0; i < matrixTokens.length; i += 2) {
	const char = matrixTokens[i + 1];
	matrixExpected[matrixTokens[i]] =
		QWERTY_CODE[char] ?? (/[0-9]/.test(char) ? `Digit${char}` : `Key${char.toUpperCase()}`);
	matrixKeys[Number(matrixTokens[i])].primary = (char === 'space' ? ' ' : char).codePointAt(0);
}
check(
	JSON.stringify(F.KLA_KEYS.matrix) === JSON.stringify(matrixExpected),
	`KLAnext matrix key indexes differ from KLAnext's QWERTY: ${JSON.stringify(F.KLA_KEYS.matrix)}`
);
// A KLAnext matrix file: its keys placed by id (KLAnext's fixKeys), a later key
// replacing an earlier one with the same id, as its own Dvorak preset does; a
// character on the centre block or a thumb named as unread.
const matrixFile = {
	label: 'matrix test',
	keyboardType: 'matrix',
	keys: [
		{ id: 13, primary: -1 },
		...matrixKeys,
		{ id: 13, primary: 'é'.codePointAt(0), shift: 'É'.codePointAt(0) },
		{ id: 70, primary: 'ŝ'.codePointAt(0) },
		{ id: 57, primary: 'e'.codePointAt(0) }
	]
};
const matrix = F.read('matrix.json', JSON.stringify(matrixFile), {});
const qwerty = E.libraryLayouts().find((layout) => layout.id === 'qwerty');
const matrixWrong = Object.values(F.KLA_KEYS.matrix).filter(
	(code) =>
		code !== 'KeyQ' && code !== 'Space' && matrix.layout.rows[code][0] !== qwerty.rows[code][0]
);
check(
	matrix.format === 'kla' &&
		matrixWrong.length === 0 &&
		JSON.stringify(matrix.layout.rows.KeyQ.slice(0, 2)) === JSON.stringify(['é', 'É']) &&
		JSON.stringify(matrix.unmapped.map((u) => u.detail)) === JSON.stringify(['57 (e)', '70 (ŝ)']),
	`KLAnext matrix: ${matrixWrong.join(' ')} differ from QWERTY, KeyQ ${JSON.stringify(matrix.layout.rows.KeyQ)}, unread ${JSON.stringify(matrix.unmapped)}`
);

const thirdPartyBytes = (file) =>
	F.readBytes(file, new Uint8Array(fs.readFileSync(path.join(THIRD_PARTY, file))), {
		parseToml,
		scancodes: DATA.scancodes
	});
const row = (layout, codes, level = 0) =>
	codes.map((code) => (layout.rows[code] || [])[level] ?? '?').join('');
const LETTER_ROWS = [
	['KeyQ', 'KeyW', 'KeyE', 'KeyR', 'KeyT', 'KeyY', 'KeyU', 'KeyI', 'KeyO', 'KeyP'],
	HOME_ROW,
	['KeyZ', 'KeyX', 'KeyC', 'KeyV', 'KeyB', 'KeyN', 'KeyM', 'Comma', 'Period', 'Slash']
];
const moreResults = [];

// XKB symbols as xkeyboard-config publishes them: bépo states its number row
// after a `type[group1] = …` assignment, Esperanto names its letters by keysym
// (scircumflex, Ubreve…).
const xkbFr = fs.readFileSync(path.join(THIRD_PARTY, 'xkeyboard-config.fr.xkb_symbols'), 'utf8');
const xkbBepo = F.fromXkb(xkbFr, 'bepo');
const bepoLibrary = E.libraryLayouts().find((layout) => layout.id === 'bepo');
// Dead keys compare by being dead keys: the two files name their states differently.
const baseShift = (layout, code) =>
	JSON.stringify(
		layout.rows[code].slice(0, 2).map((cell) => (typeof cell === 'string' ? cell : 'dead'))
	);
// xkeyboard-config's « bepo » keeps bépo 1.0's straight apostrophe on KeyN,
// where the registry's bépo 1.1 types ’.
const bepoDiffers = [...LETTER_ROWS.flat(), 'Digit1', 'Digit5', 'Minus', 'Equal'].filter(
	(code) => code !== 'KeyN' && baseShift(xkbBepo.layout, code) !== baseShift(bepoLibrary, code)
);
check(
	xkbBepo.layout.name === 'French (BEPO)' &&
		bepoDiffers.length === 0 &&
		xkbBepo.layout.rows.KeyN[0] === "'" &&
		JSON.stringify(xkbBepo.layout.rows.Digit1) === JSON.stringify(['"', '1', '—', '„']) &&
		!xkbBepo.unmapped.some((u) => /group1/i.test(u.detail)),
	`xkeyboard-config bépo: ${bepoDiffers.join(' ')} differ from the registry's bépo, Digit1 ${JSON.stringify(xkbBepo.layout.rows.Digit1)}, unread ${JSON.stringify(xkbBepo.unmapped)}`
);
const epo = thirdParty('xkeyboard-config.epo.xkb_symbols');
check(
	epo.layout.name === 'Esperanto' &&
		JSON.stringify(epo.layout.rows.KeyQ) === JSON.stringify(['ŝ', 'Ŝ', 'q', 'Q']) &&
		JSON.stringify(epo.layout.rows.KeyY.slice(0, 2)) === JSON.stringify(['ŭ', 'Ŭ']) &&
		JSON.stringify(epo.unmapped.map((u) => `${u.what}:${u.detail}`)) ===
			JSON.stringify(['include:us(basic)', 'include:level3(ralt_switch)']),
	`xkeyboard-config Esperanto: KeyQ ${JSON.stringify(epo.layout.rows.KeyQ)}, unread ${JSON.stringify(epo.unmapped)}`
);
moreResults.push(['xkeyboard-config bépo', xkbBepo], ['xkeyboard-config.epo', epo]);

// Windows KLC as the Colemak Mod-DH project publishes them (CC0): one UTF-8,
// one UTF-16, each with its dead keys and their tables.
for (const [file, bottom] of [
	['mod-dh.colemak_dh_iso_uk.klc', 'zxcdv\\kh,./'],
	['mod-dh.colemak_dh_ansi_us.klc', 'zxcdvzkh,./']
]) {
	const result = thirdPartyBytes(file);
	const codes = ['IntlBackslash', ...LETTER_ROWS[2]];
	const acute = Object.entries(result.layout.dead).find(([, rules]) => rules.e === 'é');
	check(
		result.format === 'klc' &&
			row(result.layout, LETTER_ROWS[0]) === 'qwfpbjluy;' &&
			row(result.layout, LETTER_ROWS[1]) === 'arstgmneio' &&
			row(result.layout, codes) === bottom &&
			Object.keys(result.layout.dead).length >= 10 &&
			acute !== undefined &&
			result.unmapped.length === 0,
		`${file}: rows ${row(result.layout, LETTER_ROWS[1])} ${row(result.layout, codes)}, ${Object.keys(result.layout.dead).length} dead keys, unread ${JSON.stringify(result.unmapped)}`
	);
	moreResults.push([file, result]);
}

// DOF as libdof's own examples write it (Apache-2.0): a full ANSI-shaped
// board anchored at its top left key with Shift and AltGr layers, magic keys
// and combos; libdof's minimal valid file on its ANSI preset; a colstag block
// with a letter on a thumb; a board shape the Studio has no keys for.
const maximal = thirdParty('libdof.maximal.dof');
check(
	maximal.format === 'dof' &&
		JSON.stringify(maximal.layout.rows.Backquote) === JSON.stringify(['`', '~', null, null]) &&
		JSON.stringify(maximal.layout.rows.Digit8.slice(0, 2)) === JSON.stringify(['8', '*']) &&
		JSON.stringify(maximal.layout.rows.KeyU) === JSON.stringify(['u', 'U', 'ü', null]) &&
		JSON.stringify(maximal.layout.rows.KeyT) === JSON.stringify(['t', 'T', 'tb', null]) &&
		JSON.stringify(maximal.layout.rows.Space.slice(0, 2)) === JSON.stringify([' ', ' ']) &&
		JSON.stringify(maximal.unmapped.map((u) => `${u.what}:${u.detail}`)) ===
			JSON.stringify([
				'rule:&mgc',
				'key:4:7 (ß)',
				'key:4:4 (altgr)',
				'key:4:7 (SS)',
				'rule:&mgc2',
				'rule:d f',
				'rule:j k',
				'rule:sft-2 ?'
			]),
	`libdof maximal: Backquote ${JSON.stringify(maximal.layout.rows.Backquote)}, KeyU ${JSON.stringify(maximal.layout.rows.KeyU)}, unread ${JSON.stringify(maximal.unmapped)}`
);
const minimal = thirdParty('libdof.minimal_valid.dof');
check(
	LETTER_ROWS.every((codes) => row(minimal.layout, codes) === row(qwerty, codes)) &&
		minimal.layout.rows.Semicolon[1] === ':' &&
		minimal.layout.rows.Quote[1] === '"' &&
		minimal.layout.fingering === 'angle' &&
		minimal.unmapped.length === 0,
	`libdof minimal: ${LETTER_ROWS.map((codes) => row(minimal.layout, codes)).join(' ')}`
);
const aptmak = thirdParty('libdof.aptmak.dof');
check(
	row(aptmak.layout, LETTER_ROWS[1]) === 'rsthkxnaio' &&
		JSON.stringify(aptmak.unmapped) === JSON.stringify([{ what: 'key', detail: '3:4 (e)' }]),
	`libdof aptmak: home ${row(aptmak.layout, LETTER_ROWS[1])}, unread ${JSON.stringify(aptmak.unmapped)}`
);
const buggy = thrown(() => thirdParty('libdof.buggy.dof'));
check(
	buggy && buggy.code === 'format_unsupported_board' && buggy.detail === 'custom',
	`libdof buggy: a custom board is not refused (${buggy && buggy.message})`
);
moreResults.push(['libdof.maximal.dof', maximal], ['libdof.aptmak.dof', aptmak]);

// genkey (semilin/genkey, GPL-3.0, so no file of it is shipped here): a layout
// written the way its layouts folder holds them, a file without an extension.
const GENKEY_TEXT = [
	'Colemak DH Angle',
	'q w f p b j l u y ;',
	'a r s t g m n e i o Quote',
	'x c d v z k h , . /',
	'0 1 2 3 3 4 4 5 6 7',
	'0 1 2 3 3 4 4 5 6 7 7',
	'1 2 3 3 3 4 4 5 6 7',
	''
].join('\n');
const genkey = F.read('colemak_dh_angle', GENKEY_TEXT, {});
check(
	genkey.format === 'genkey' &&
		genkey.layout.name === 'Colemak DH Angle' &&
		row(genkey.layout, [...HOME_ROW, 'Quote']) === 'arstgmneioq' &&
		row(genkey.layout, LETTER_ROWS[2]) === 'xcdvzkh,./' &&
		genkey.layout.fingering === 'angle' &&
		F.read('rows.txt', 'q w e\na s d\nz x c\n', {}).format === 'rows',
	`genkey: ${genkey.format} ${row(genkey.layout, HOME_ROW)} ${genkey.layout.fingering}`
);

// Writers: every real layout above, and the repository's own, written as DOF,
// genkey and cmini, reads back to the same keys; what a format cannot hold is
// reported, never dropped.
const ISO_GRID = Object.values(F.XKB_KEYS);
const cells = (layout, codes, levels) =>
	JSON.stringify(
		codes.map((code) =>
			levels.map((level) => {
				const cell = (layout.rows[code] || [])[level];
				return typeof cell === 'string' ? cell : null;
			})
		)
	);
let writerRoundTrips = 0;
for (const [name, result] of [
	['Ergo-L TOML', ergolToml],
	['bépo .keylayout', bepo],
	['Ergopti 1DK KLC', read.klc],
	...moreResults
]) {
	const dofOut = F.toDof(result.layout);
	const dofBack = F.fromDof(JSON.parse(dofOut.text));
	// A file that states no space bar (an XKB variant over another) gets the
	// space every DOF reading gives it.
	const expected = JSON.parse(JSON.stringify(result.layout));
	if (!expected.rows.Space) expected.rows.Space = [' ', null, null, null];
	const deadCount = Object.values(result.layout.rows)
		.flat()
		.filter((cell) => cell && typeof cell === 'object').length;
	check(
		cells(dofBack.layout, ISO_GRID, [0, 1, 2, 3]) ===
			cells(expected, ISO_GRID, [0, 1, 2, 3]).replace(/" "|" "/g, 'null') &&
			dofBack.unmapped.length === 0 &&
			dofOut.unmapped.filter((u) => u.what === 'dead_key').length <= deadCount,
		`${name}: DOF import, export, import gives other keys (${JSON.stringify(dofOut.unmapped.slice(0, 4))})`
	);
	check(
		dofOut.unmapped.every((u) => u.what === 'dead_key' || u.what === 'character'),
		`${name}: DOF reports ${JSON.stringify(dofOut.unmapped)}`
	);
	for (const [format, write, readBack] of [
		['genkey', F.toGenkey, (text) => F.read('layout', text, {})],
		['cmini', F.toCmini, (text) => F.read('layout.json', text, {})]
	]) {
		const out = write(result.layout);
		const back = readBack(out.text);
		const kept = (layout) =>
			LETTER_ROWS.map((codes) =>
				codes.map((code) => {
					const cell = (layout.rows[code] || [])[0];
					return typeof cell === 'string' &&
						Array.from(cell).length === 1 &&
						cell === cell.toLowerCase() &&
						!/[\s~*]/.test(cell)
						? cell
						: null;
				})
			);
		check(
			back.format === format &&
				JSON.stringify(kept(back.layout)) === JSON.stringify(kept(result.layout)) &&
				back.unmapped.length === 0 &&
				back.layout.fingering === result.layout.fingering,
			`${name}: ${format} import, export, import gives other keys`
		);
		writerRoundTrips++;
	}
	writerRoundTrips++;
}
// The library's genkey layouts (tools/build/import-genkey-layouts.cjs): all 30
// files of genkey's layouts folder at the pinned commit are accounted for, each
// imported one an alphabetic block of the three letter rows the codegen
// completes, each duplicate naming a library layout.
{
	const library = JSON.parse(
		fs.readFileSync(shared('layouts', 'data', 'analysis', 'layout_library.json'), 'utf8')
	);
	const imported = library.layouts.filter((e) => e.source === 'genkey');
	const left = library.not_imported.filter((e) => e.source === 'genkey');
	const GENKEY_FILES = 30;
	check(
		imported.length + left.length === GENKEY_FILES &&
			new Set([...imported, ...left].map((e) => e.source_path)).size === GENKEY_FILES,
		`genkey library: ${imported.length} imported and ${left.length} left out, not ${GENKEY_FILES} files`
	);
	const blockCodes = new Set(
		LETTER_ROWS.flat().concat(['BracketLeft', 'BracketRight', 'Quote', 'Backslash'])
	);
	for (const entry of imported) {
		const generated = DATA.layouts.find((l) => l.id === entry.id);
		check(
			Object.keys(entry.keys).every((code) => blockCodes.has(code)) &&
				generated !== undefined &&
				Object.entries(entry.keys).every(([code, char]) => generated.rows[code][0] === char),
			`genkey library: ${entry.id} is not a generated alphabetic block`
		);
	}
	for (const entry of left.filter((e) => e.same_as))
		check(
			DATA.layouts.some((l) => l.id === entry.same_as),
			`genkey library: ${entry.source_path} repeats ${entry.same_as}, which the library lacks`
		);
}
// A letter-block format names what it leaves out: Ergo-L's dead keys and its
// AltGr layer, bépo's dead key on KeyY.
const ergolGenkey = F.toGenkey(ergolToml.layout);
check(
	ergolGenkey.unmapped.some((u) => u.what === 'layer' && u.detail === 'AltGr') &&
		ergolGenkey.unmapped.some((u) => u.what === 'dead_key'),
	`Ergo-L genkey: losses ${JSON.stringify(ergolGenkey.unmapped)}`
);
// A cmini thumb key and a DOF space other than the space bar's are named.
const cminiThumb = F.read(
	'thumb.json',
	JSON.stringify({
		name: 't',
		board: 'stagger',
		keys: { a: { row: 1, col: 0 }, e: { row: 3, col: 0 } }
	}),
	{}
);
check(
	JSON.stringify(cminiThumb.unmapped) === JSON.stringify([{ what: 'key', detail: '3:0 (e)' }]),
	`cmini: a thumb key is not named (${JSON.stringify(cminiThumb.unmapped)})`
);
// A JIS key the ISO board lacks is named too.
const nbsp = F.toDof({
	id: 'n',
	name: 'n',
	rows: { Space: [' ', '\u00a0', null, null], IntlRo: ['\\', '_', null, null] },
	dead: {}
});
check(
	JSON.stringify(nbsp.unmapped) ===
		JSON.stringify([
			{ what: 'key', detail: 'IntlRo (\\ _)' },
			{ what: 'character', detail: 'Space: U+00A0' }
		]),
	`DOF: a JIS key or a non-breaking space is not reported (${JSON.stringify(nbsp.unmapped)})`
);
for (const [name, result] of [...moreResults, ['genkey', genkey], ['libdof minimal', minimal]])
	try {
		Source.validate(F.toSource(result.layout));
	} catch (error) {
		check(false, `${name}: toSource is invalid (${error.code} ${error.path})`);
	}

// ====================================================
// ======= 10/ Malformed files: refused, never a crash ===
// ====================================================

const REFUSAL_CODES = new Set([
	'format_unknown',
	'format_invalid',
	'format_unsupported_board',
	'format_kbe_encrypted'
]);
const readTools = Object.assign({ parseToml, scancodes: DATA.scancodes }, keylayoutTools);
const crashes = [];
const tryRead = (label, run) => {
	try {
		const result = run();
		result.unmapped.forEach((entry) => lossKinds.add(entry.what));
	} catch (error) {
		if (!REFUSAL_CODES.has(error.code)) crashes.push(`${label}: ${error.message}`);
	}
};
for (const [name, text] of [
	['a.klc', 'KBD x "y"\nSHIFTSTATE\n0\nDEADKEY\n0061 00e1\n'],
	['a.klc', 'KBD x "y"\nSHIFTSTATE\n0\nDEADKEY 0060\nzz 00e1\n'],
	['a.json', 'null'],
	['a.json', '{"keys": [null], "keyboardType": "european"}'],
	['a.json', '{"keymap": {"KeyA": ["*"]}, "deadkeys": {"*^": null}}'],
	['a.json', '{"layers": {"main": [1, 2]}}'],
	['a.json', '{"keys": {"a": null}}'],
	['a.json', '{"keys": [{"primary": 1e9}], "keyboardType": "european"}'],
	['a.toml', 'name = 3\nfull = 5\n'],
	['a.toml', 'name = "'],
	['a.txt', ''],
	['a.keylayout', '<keyboard group="0"'],
	['a.xkb', 'xkb_symbols "x" {\n key <AC01> { [ ] };\n};'],
	['a.xkb', 'xkb_symbols "x" {\n key <AC01> { [ UFFFFFF, U110000 ] };\n};'],
	['a.xkb', 'xkb_symbols "x" {\n key <AC01> { type[group1] = "A", actions[Group1] = [ x ] };\n};'],
	['a.dof', '{"name": "x", "board": "moon", "layers": {"main": ["a"]}}'],
	['a.dof', '{"board": "ansi", "anchor": [-1, 0], "layers": {"main": ["a"]}}'],
	['a.dof', '{"board": "ansi", "anchor": [99, 99], "layers": {"main": ["a"]}}'],
	['a.dof', '{"board": ["k k", 3], "layers": {"main": ["a"]}}'],
	['a.dof', '{"board": "ortho", "layers": {"main": "a b c"}}'],
	['a.dof', '{"board": "ortho", "layers": {"main": ["a"], "shift": [7]}}'],
	['a.dof', '{"board": "ortho", "layers": {"main": ["& @ * ~ \\\\~ #"]}, "magic": {"m": 3}}'],
	['a.dof', '{"layers": {"main": ["a"]}}'],
	['a.json', '{"keys": {"a": {"row": 0.5, "col": 1}}}'],
	['a.json', '{"keys": {"a": {"row": -1, "col": 1}}}'],
	['a.txt', 'name\na\nb\nc\n0\n1\nx'],
	['genkey', 'name\na\nb\nc\n0\n1\n2'],
	['genkey', '\n\n\n\n\n\n\n'],
	[
		'a.json',
		'{"keyboardType": "matrix", "keys": [{"id": -3, "primary": 97}, {"id": 1e9, "primary": 98}]}'
	]
])
	tryRead(`${name} ${JSON.stringify(text)}`, () => F.read(name, text, readTools));
// Real files cut short or with bytes overwritten, from a fixed seed.
let seed = 7;
const random = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
for (const file of [
	KLA_ISO,
	bepoFile,
	path.join(BUILT, 'ergo_1dk.klc'),
	path.join(BUILT, 'ergo_1dk.xkb_symbols'),
	path.join(BUILT, 'ergo_1dk.json'),
	path.join(THIRD_PARTY, 'ergol.toml'),
	kbeFiles[0],
	path.join(THIRD_PARTY, 'xkeyboard-config.epo.xkb_symbols'),
	path.join(THIRD_PARTY, 'mod-dh.colemak_dh_iso_uk.klc'),
	path.join(THIRD_PARTY, 'mod-dh.colemak_dh_ansi_us.klc'),
	path.join(THIRD_PARTY, 'libdof.maximal.dof'),
	path.join(THIRD_PARTY, 'libdof.aptmak.dof'),
	// Files the writers make: a genkey layout (no extension) and a DOF.
	['colemak_dh_angle', GENKEY_TEXT],
	['written.dof', F.toDof(ergolToml.layout).text],
	['written.cmini.json', F.toCmini(ergolToml.layout).text]
]) {
	const bytes = Array.isArray(file)
		? new TextEncoder().encode(file[1])
		: new Uint8Array(fs.readFileSync(file));
	const name = Array.isArray(file) ? file[0] : path.basename(file);
	for (const cut of [0, 1, 21, 100, Math.floor(bytes.length / 2)])
		tryRead(`${name} cut at ${cut}`, () => F.readBytes(name, bytes.subarray(0, cut), readTools));
	for (let i = 0; i < 20; i++) {
		const copy = Uint8Array.from(bytes);
		for (let k = 0; k < 1 + Math.floor(random() * 20); k++)
			copy[Math.floor(random() * copy.length)] = Math.floor(random() * 256);
		tryRead(`${name} corrupted #${i}`, () => F.readBytes(name, copy, readTools));
	}
}
check(crashes.length === 0, `readers crash instead of refusing:\n    ${crashes.join('\n    ')}`);
const empty = thrown(() => F.read('a.txt', '\n\n', readTools));
check(empty && empty.code === 'format_invalid', 'a file that places no character is imported');

// =================================================
// ======= 11/ Messages, pickers and decoding ======
// =================================================

// Every refusal and every loss the readers and writers report has words in
// every locale (the pages show t(key, values), never a bare code).
const LOCALES = shared('core', 'i18n', 'data', 'locales');
const catalogues = fs
	.readdirSync(LOCALES)
	.filter((file) => /^[a-z]{2}\.json$/.test(file))
	.map((file) => [file, JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'))]);
check(catalogues.length === 21, `${catalogues.length} locales`);
// The writers' losses, and every kind the module declares, whether or not a file above showed it.
['dead_key', 'multi_character', 'layer', 'rule', 'special', 'character'].forEach((what) =>
	lossKinds.add(what)
);
for (const what of lossKinds) {
	const { key } = F.lossMessage({ what, detail: 'x' });
	for (const [file, strings] of catalogues)
		check(typeof strings[key] === 'string' && strings[key].includes('{detail}'), `${file}: ${key}`);
}
for (const code of REFUSAL_CODES) {
	const { key } = F.refusalMessage({ code, detail: 'x' });
	for (const [file, strings] of catalogues)
		check(typeof strings[key] === 'string', `${file}: ${key}`);
}
const other = F.refusalMessage(new Error('disk full'));
check(
	other.key === 'layout_analysis.layouts.import_failed' && other.values.reason === 'disk full',
	'an error that is not a reader refusal loses its reason'
);
check(
	refuses(() => F.lossMessage({ what: 'mystery', detail: 'x' }), 'format_loss_unknown'),
	'a loss without words is accepted'
);
// The app's native open panel offers what the pages' pickers offer.
const layoutDefaults = JSON.parse(
	fs.readFileSync(shared('layouts', 'data', 'defaults.json'), 'utf8')
);
check(
	JSON.stringify(layoutDefaults.source.pick_extensions) ===
		JSON.stringify(Array.from(F.EXTENSIONS)),
	'source.pick_extensions differs from LAYOUT_FORMATS.EXTENSIONS'
);
// Each interoperability download of the editor's « Format » list has words in
// every locale and a file type the app's hosts write to Downloads.
const editorPage = fs.readFileSync(path.join(UI, 'layout_editor', 'editor_page.js'), 'utf8');
const interop = Array.from(
	editorPage.matchAll(/\['(\w+)', (?:klaExport|LAYOUT_FORMATS\.to\w+), '([\w.]+)', '[\w/+.-]+'\]/g)
);
check(
	JSON.stringify(interop.map((m) => m[1])) ===
		JSON.stringify(['kla', 'kalamine', 'dof', 'genkey', 'cmini']),
	`editor interoperability downloads: ${interop.map((m) => m[1]).join(' ')}`
);
for (const [, id, extension] of interop) {
	check(
		layoutDefaults.source.export_extensions.includes(extension.split('.').pop()),
		`the ${id} download (.${extension}) is not in source.export_extensions`
	);
	for (const [file, strings] of catalogues)
		check(
			typeof strings[`layout_editor.export.option.${id}`] === 'string',
			`${file}: layout_editor.export.option.${id}`
		);
}
// (board-image-downloads) The keyboard and heatmap images (board_image.js FORMATS)
// go through the same host download path: the hosts write their types.
for (const extension of ['png', 'svg'])
	check(
		layoutDefaults.source.export_extensions.includes(extension),
		`the board images (.${extension}) are not in source.export_extensions`
	);
// The editor reads a picked UTF-16 KLC as the Comparer does.
check(
	F.decode(new Uint8Array(fs.readFileSync(path.join(BUILT, 'ergo_1dk.klc')))) === klcText,
	'a UTF-16 KLC does not decode to its text'
);

// ===============================
// ======= 12/ Share links =======
// ===============================

/** The code a share link's fragment is refused with, or 'read' when it reads. */
async function linkRefusal(hash) {
	try {
		await F.fromLink(hash, E);
		return 'read';
	} catch (error) {
		return error.code || error.message;
	}
}

/** A fragment of the current version holding this JSON, deflated as toLink writes it. */
async function linkOf(value) {
	const packed = new Uint8Array(
		await new Response(
			new Blob([JSON.stringify(value)]).stream().pipeThrough(new CompressionStream('deflate-raw'))
		).arrayBuffer()
	);
	return `#l=1.${Buffer.from(packed).toString('base64url')}`;
}

async function checkLinks() {
	const library = E.libraryLayouts();
	const shared = ['ergopti', 'bepo'].map((id) => library.find((layout) => layout.id === id));
	const part = await F.toLink(shared);
	check(
		/^l=1\.[A-Za-z0-9_-]+$/.test(part),
		`share link: not a versioned part: ${part.slice(0, 20)}`
	);
	const back = await F.fromLink(`#${part}`, E);
	check(back.length === 2, `share link: ${back.length} layouts read back`);
	back.forEach((layout, index) => {
		const sent = shared[index];
		check(layout.name === sent.name, `share link: name ${layout.name}`);
		check(layout.origin === 'user', `share link: ${layout.name} is not a personal layout`);
		check(
			JSON.stringify([layout.rows, layout.dead, layout.command]) ===
				JSON.stringify([sent.rows, sent.dead, sent.command]),
			`share link: ${sent.id} does not read back to the same keys`
		);
	});
	check((await F.fromLink('', E)).length === 0, 'share link: an empty fragment carries layouts');
	check(
		(await F.fromLink('#section', E)).length === 0,
		'share link: a page anchor carries layouts'
	);
	const good = { n: 'Mine', r: { KeyQ: ['a', 'A', null, null] } };
	check(
		(await linkRefusal(await linkOf([good]))) === 'read',
		'share link: a minimal layout is refused'
	);
	for (const [hash, code, what] of [
		[`#l=2.${part.slice(4)}`, 'link_version', 'another version'],
		[`#${part.slice(0, 40)}`, 'link_damaged', 'a cut link'],
		['#l=1.$$$', 'link_damaged', 'a link outside base64url'],
		['#l=1.AAAA', 'link_damaged', 'bytes that do not inflate'],
		[`#${part}&${part}`, 'link_damaged', 'two layout parts'],
		[`#l=1.${'A'.repeat(300000)}`, 'link_too_large', 'an oversized fragment'],
		[await linkOf({ n: 'x' }), 'link_invalid', 'an object instead of a list'],
		[await linkOf([]), 'link_invalid', 'no layout'],
		[await linkOf(Array(17).fill(good)), 'link_too_large', 'too many layouts'],
		[await linkOf([{ ...good, x: 1 }]), 'link_invalid', 'an unknown field'],
		[await linkOf([{ ...good, n: '' }]), 'link_invalid', 'an empty name'],
		[
			await linkOf([{ ...good, r: { Nowhere: ['a', null, null, null] } }]),
			'link_invalid',
			'an unknown key'
		],
		[await linkOf([{ ...good, r: { KeyQ: ['a', 'A'] } }]), 'link_invalid', 'a short row'],
		[
			await linkOf([{ ...good, r: { KeyQ: [7, null, null, null] } }]),
			'link_invalid',
			'a number cell'
		],
		[
			await linkOf([{ ...good, r: { KeyQ: [{ dead: 'x', y: 1 }, null, null, null] } }]),
			'link_invalid',
			'a dead cell with a field too many'
		],
		[await linkOf([{ ...good, d: { x: { a: 5 } } }]), 'link_invalid', 'a bad dead-key result'],
		[await linkOf([{ ...good, c: { KeyQ: 3 } }]), 'link_invalid', 'a bad shortcut']
	])
		check((await linkRefusal(hash)) === code, `share link: ${what} is not refused as ${code}`);
	const message = F.refusalMessage({ code: 'link_invalid', detail: 'layout 1' });
	check(
		message.key === 'layout_analysis.formats.refused.link_invalid',
		`share link: the refusal is not worded: ${message.key}`
	);
}

// ===================================================
// ======= 13/ KLA thumb keys (thumb-letter files) ===
// ===================================================

{
	// A Hands Down « ts » ErgoDox file as moutis/HandsDown writes it: t on the
	// left thumb's inner 2-unit key (67), its capital alone on another left
	// thumb key (69), the space on the right inner one (74), KLA fingers 5/6.
	const key = (id, primary, finger, shift = -1) => ({
		id,
		primary,
		shift,
		altGr: -1,
		shiftAltGr: -1,
		finger
	});
	const thumbFile = (thumbs) => ({
		label: 'thumb test',
		keyboardType: 'ergodox',
		keys: [key(29, 'r'.codePointAt(0), 1, 'R'.codePointAt(0)), ...thumbs]
	});
	const gold = F.fromKla(
		thumbFile([key(67, 116, 5), key(69, 84, 5), key(74, 32, 6, 95), key(75, 13, 6)])
	);
	check(
		JSON.stringify(gold.layout.rows.NonConvert) === '["t","T",null,null]' &&
			JSON.stringify(gold.layout.rows.Convert) === '[" ","_",null,null]' &&
			!gold.layout.rows.Space &&
			gold.unmapped.length === 0,
		`thumb keys: the Gold file reads ${JSON.stringify(gold.layout.rows)} ${JSON.stringify(gold.unmapped)}`
	);
	// A third right thumb key has no code: it is named, not dropped; the big
	// keys (74, 75) take Convert before the small one (72) takes KanaMode.
	const many = F.fromKla(
		thumbFile([key(66, 32, 5), key(72, 45, 6), key(75, 101, 6), key(73, 120, 6)])
	);
	check(
		many.layout.rows.NonConvert[0] === ' ' &&
			many.layout.rows.Convert[0] === 'e' &&
			many.layout.rows.KanaMode[0] === '-' &&
			many.unmapped.length === 1 &&
			/^73 \(x\)$/.test(many.unmapped[0].detail),
		`thumb keys: the big keys first, the extra named: ${JSON.stringify(many.layout.rows)} ${JSON.stringify(many.unmapped)}`
	);
	// The space alone on the thumbs reads as before: the shared space bar.
	const plain = F.fromKla(thumbFile([key(66, 32, 5), key(74, 32, 6)]));
	check(
		plain.layout.rows.Space[0] === ' ' && !plain.layout.rows.NonConvert,
		`thumb keys: a space-only file does not read Space: ${JSON.stringify(plain.layout.rows)}`
	);
	// An action sign (⌦) on a thumb key types nothing: alone it keeps the
	// space bar reading; beside a thumb letter it is named, not read as Space.
	const sign = F.fromKla(thumbFile([key(66, 8, 5, 0x2326), key(74, 32, 6)]));
	check(
		sign.layout.rows.Space[0] === ' ' && !sign.layout.rows.NonConvert,
		`thumb keys: an action sign reads as a thumb letter: ${JSON.stringify(sign.layout.rows)}`
	);
	const signed = F.fromKla(thumbFile([key(66, 8, 5, 0x2326), key(67, 116, 5), key(74, 32, 6)]));
	check(
		!signed.layout.rows.Space &&
			signed.layout.rows.NonConvert[0] === 't' &&
			signed.unmapped.some((entry) => /^66 /.test(entry.detail)),
		`thumb keys: the action sign beside a thumb letter: ${JSON.stringify(signed.layout.rows)}`
	);
	// Written back on KLA's ErgoDox board, it reads to the same keys.
	const written = F.toKla(gold.layout, DATA.model.fingerings.standard);
	const back = F.fromKla(JSON.parse(JSON.stringify(written)));
	check(
		written.keyboardType === 'ergodox' &&
			written.keys[67].finger === 5 &&
			written.keys[74].finger === 6 &&
			canonical(back.layout) === canonical(gold.layout),
		`thumb keys: the ErgoDox export does not read back: ${JSON.stringify(back.layout.rows)}`
	);
	// The reader's thumb codes are the model's.
	const codes = ['NonConvert', 'Convert', 'KanaMode'];
	check(
		JSON.stringify(DATA.model.thumb_keys) === JSON.stringify(codes) &&
			JSON.stringify(DATA.model.thumb_rest_keys) === JSON.stringify(codes.slice(0, 2)),
		`thumb keys: the model's ${DATA.model.thumb_keys} are not the KLA reader's ${codes}`
	);
}

checkLinks().then(report, (error) => {
	console.error(error);
	process.exit(1);
});

function report() {
	if (errors.length > 0) {
		for (const error of errors) console.error(`  ✗ ${error}`);
		console.error(`test-layout-formats: ${errors.length} problem(s)`);
		process.exit(1);
	}
	console.log(
		`test-layout-formats: OK (4 formats of one layout, ${3 + klaResults.length + moreResults.length + 2} third-party files, ${Object.keys(reference).length} characters, ${compared} KLA keys, ${klaRoundTrips} KLAnext, ${keylayoutRoundTrips} .keylayout and ${writerRoundTrips} DOF, genkey and cmini round trips, ${kbeFiles.length} .kbe refused, malformed files refused)`
	);
}
