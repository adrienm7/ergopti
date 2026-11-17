// tools/test/test-layout-formats.cjs

/**
 * ==============================================================================
 * MODULE: Layout File Formats Gate
 * DESCRIPTION:
 * _shared/ui/layout_analysis/layout_formats.js reads the layout files people
 * have (KLA JSON, Kalamine TOML and JSON, XKB symbols, KLC, .keylayout, DOF,
 * cmini, plain rows) and writes Ergopti sources, KLA JSON and Kalamine TOML.
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
 * 9. Malformed files (hand-made, and real ones cut short or overwritten from a
 *    fixed seed) are refused with a stable code, never a crash.
 * 10. Every refusal and loss has words in all 21 locales; the app's native
 *    open panel offers the pages' file types; a UTF-16 KLC decodes.
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
const sandbox = { TextDecoder };
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

// ====================================================
// ======= 9/ Malformed files: refused, never a crash ===
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
	['a.xkb', 'xkb_symbols "x" {\n key <AC01> { [ ] };\n};']
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
	kbeFiles[0]
]) {
	const bytes = new Uint8Array(fs.readFileSync(file));
	const name = path.basename(file);
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
// ======= 10/ Messages, pickers and decoding ======
// =================================================

// Every refusal and every loss the readers and writers report has words in
// every locale (the pages show t(key, values), never a bare code).
const LOCALES = shared('core', 'i18n', 'data', 'locales');
const catalogues = fs
	.readdirSync(LOCALES)
	.filter((file) => /^[a-z]{2}\.json$/.test(file))
	.map((file) => [file, JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'))]);
check(catalogues.length === 21, `${catalogues.length} locales`);
['dead_key', 'multi_character'].forEach((what) => lossKinds.add(what));
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
// The editor reads a picked UTF-16 KLC as the Comparer does.
check(
	F.decode(new Uint8Array(fs.readFileSync(path.join(BUILT, 'ergo_1dk.klc')))) === klcText,
	'a UTF-16 KLC does not decode to its text'
);

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-formats: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-formats: OK (4 formats of one layout, ${3 + klaResults.length} third-party files, ${Object.keys(reference).length} characters, ${compared} KLA keys, ${klaRoundTrips} KLAnext and ${keylayoutRoundTrips} .keylayout round trips, ${kbeFiles.length} .kbe refused, malformed files refused)`
);
