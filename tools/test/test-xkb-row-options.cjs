// tools/test/test-xkb-row-options.cjs

/**
 * ==============================================================================
 * MODULE: XKB Number-Row Options Gate
 * DESCRIPTION:
 * The Linux converter (_shared/lua/layouts/xkb_converter.lua) applies the
 * number-row options to a layout it converts. The web composer applies the same
 * options when it compiles a layout (composer_model.js). The two must agree, and
 * both must agree with what Windows types.
 *
 * WHAT IS CHECKED, for every case of
 * _shared/tests/corpus/layouts/row_options_vectors.json:
 * 1. Differential: converting the plain layout with the options gives the same
 *    XKB and XCompose files as converting the layout the composer compiled with
 *    the options already applied.
 * 2. Idempotence: converting that compiled layout with the options again changes
 *    nothing (the options are then inert, already applied).
 * 3. Hand-written outcomes: the unshifted and Shift levels of the keys the case
 *    names are the keysyms of the characters the case says they type.
 * 4. The report (order in effect, reason, edge keys) equals the case's.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const { shared } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const PROBE = path.join(__dirname, 'fixtures', 'keylayout-xkb-convert.lua');
const DATA = path.join(ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data');
const TABLE_PATH = shared('modules', 'layouts', 'mac_keycodes.json');
const CASES = JSON.parse(
	fs.readFileSync(shared('tests', 'corpus', 'layouts', 'row_options_vectors.json'), 'utf8')
).cases;
const KEYSYMS = JSON.parse(fs.readFileSync(path.join(DATA, 'key_sym.json'), 'utf8')).keysyms;
const MIN_CASES = 10;

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};

const sandbox = vm.createContext({});
for (const file of [
	shared('ui', 'layout_composer', 'reference_layouts.js'),
	shared('ui', 'layout_composer', 'composer_model.js'),
	shared('ui', 'layout_composer', '_generated', 'composer_data.js')
])
	vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
const Composer = vm.runInContext('LayoutComposer', sandbox);
const REFERENCE = vm.runInContext('LAYOUT_COMPOSER_REFERENCE', sandbox);
const TABLE = vm.runInContext('LAYOUT_COMPOSER_DATA', sandbox);
const SOURCES = {};
for (const id of Object.keys(REFERENCE)) SOURCES[id] = Composer.referenceSource(id, REFERENCE[id]);

const xkbOfScan = new Map(
	JSON.parse(fs.readFileSync(TABLE_PATH, 'utf8')).keys.map((key) => [key.ahk, key.xkb])
);

function luaRuntime() {
	for (const name of ['luajit', 'lua5.4', 'lua'])
		if (spawnSync(name, ['-v'], { encoding: 'utf8' }).status === 0) return name;
	throw new Error('no Lua runtime on PATH');
}
const LUA = luaRuntime();

/** Converts one .keylayout text; returns the files it wrote and the options report. */
function convert(text, rows, scratch, label) {
	const input = path.join(scratch, label + '.keylayout');
	const out = path.join(scratch, label);
	fs.mkdirSync(out, { recursive: true });
	fs.writeFileSync(input, text);
	const result = spawnSync(
		LUA,
		[PROBE, shared(), DATA, input, TABLE_PATH, 'iso', 'rows_case', 'Rows case', out],
		{
			encoding: 'utf8',
			env: { ...process.env, ...(rows ? { ERGOPTI_ROWS: `${rows.order},${rows.edges}` } : {}) }
		}
	);
	if (result.status !== 0) {
		errors.push(`${label}: conversion refused: ${result.stderr}`);
		return null;
	}
	const read = (name) => fs.readFileSync(path.join(out, name), 'utf8');
	return {
		symbols: read('rows_case.xkb'),
		compose: read('rows_case.XCompose'),
		report: fs.existsSync(path.join(out, 'rows.json')) ? JSON.parse(read('rows.json')) : null
	};
}

/** The keysyms of one key's first four levels in an XKB symbols file. */
function levelsOf(symbols, xkbName) {
	const line = new RegExp(`key <${xkbName}> \\{ type\\[group1\\] = "[^"]*", \\[([^\\]]*)\\]`).exec(
		symbols
	);
	return line ? line[1].split(',').map((item) => item.trim()) : null;
}

const keysymOf = (character) =>
	KEYSYMS[character] || 'U' + character.codePointAt(0).toString(16).toUpperCase().padStart(4, '0');

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-xkb-rows-'));
try {
	let cases = 0;
	for (const entry of CASES) {
		cases += 1;
		const plain = Composer.emptyDeclaration(`Rows ${entry.id}`, 'iso', entry.source);
		if (entry.overrides) plain.overrides = JSON.parse(JSON.stringify(entry.overrides));
		const baked = JSON.parse(JSON.stringify(plain));
		Composer.setRowOptions(baked, entry.rows.order, entry.rows.edges);
		const compile = (declaration) => {
			const built = Composer.build(declaration, SOURCES, TABLE);
			if (!built.ok) {
				errors.push(`${entry.id}: ${JSON.stringify(built.problems)}`);
				return null;
			}
			return Composer.serialize(built.layout, TABLE);
		};
		const plainText = compile(plain);
		const bakedText = compile(baked);
		if (!plainText || !bakedText) continue;

		const viaConverter = convert(plainText, entry.rows, scratch, entry.id + '-converter');
		const viaComposer = convert(bakedText, null, scratch, entry.id + '-composer');
		const again = convert(bakedText, entry.rows, scratch, entry.id + '-again');
		if (!viaConverter || !viaComposer || !again) continue;

		check(
			viaConverter.symbols === viaComposer.symbols,
			`${entry.id}: the converter's options and the composer's differ in the XKB symbols`
		);
		check(
			viaConverter.compose === viaComposer.compose,
			`${entry.id}: the converter's options and the composer's differ in the XCompose`
		);
		check(
			again.symbols === viaComposer.symbols,
			`${entry.id}: the options applied twice change the layout`
		);
		const report = viaConverter.report;
		check(
			report &&
				report.order === entry.effective.order &&
				report.reason === entry.effective.reason &&
				report.edges.applies === entry.effective.edges.applies &&
				report.edges.reason === entry.effective.edges.reason,
			`${entry.id}: the report is ${JSON.stringify(report)}`
		);
		for (const [press, expected] of entry.types) {
			// Single unshifted or Shift presses of one key name a level of that key.
			const match = /^(shift )?(SC[0-9A-F]{3})$/.exec(press);
			if (!match || expected === '' || [...expected].length !== 1) continue;
			const levels = levelsOf(viaConverter.symbols, xkbOfScan.get(match[2]));
			const held = levels && levels[match[1] ? 2 : 0];
			check(
				held === keysymOf(expected),
				`${entry.id}: ${press} holds ${held}, the case says ${keysymOf(expected)}`
			);
		}
	}
	check(cases >= MIN_CASES, `only ${cases} cases`);
} finally {
	if (!process.env.KEEP_SCRATCH) fs.rmSync(scratch, { recursive: true, force: true });
}

if (errors.length > 0) {
	console.error(`test-xkb-row-options: ${errors.length} problem(s)`);
	for (const message of errors.slice(0, 40)) console.error(`  - ${message}`);
	process.exit(1);
}
console.log(`test-xkb-row-options: OK (${CASES.length} cases, converter and composer agree)`);
