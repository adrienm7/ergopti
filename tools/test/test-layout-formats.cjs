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
 *    characters on the same physical keys.
 * 3. Writers: every imported layout becomes an Ergopti source the source
 *    model validates; Kalamine TOML and KLA JSON read back to what was written.
 * 4. Plain rows, DOF and cmini blocks; unknown and malformed files refused.
 * 5. Third-party files (tools/test/fixtures/layout-formats/third-party, their
 *    sources and licences in its README): Ergo-L's own Kalamine TOML and the
 *    JSON its project publishes give the same keys, the TOML reporting only
 *    the dead keys whose rules Kalamine keeps built in; Kalamine's qwerty-prog
 *    example reads on its ANSI board; each becomes a valid Ergopti source.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { parse: parseToml } = require('smol-toml');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

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

const sandbox = {};
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
for (const [name, result] of [
	['ergol.toml', ergolToml],
	['ergol.json', ergolJson],
	['kalamine-qwerty-prog.toml', prog]
])
	try {
		Source.validate(F.toSource(result.layout));
	} catch (error) {
		check(false, `${name}: toSource is invalid (${error.code} ${error.path})`);
	}

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-formats: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-formats: OK (4 formats of one layout, 3 third-party files, 2 .keylayout, ${Object.keys(reference).length} characters, ${compared} KLA keys, writers round-trip)`
);
