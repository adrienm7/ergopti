// tools/test/test-keylayout-row-options.cjs

/**
 * ==============================================================================
 * MODULE: Keylayout Number-Row Options Gate
 * DESCRIPTION:
 * macOS installs a .keylayout that already types the number-row options: the
 * shared Lua editor (_shared/lua/layouts/keylayout_rows.lua) rewrites the cells
 * of the layout's file. Linux applies the same options while converting
 * (xkb_converter.lua) and the web composer while compiling. All three must
 * type the same layout.
 *
 * WHAT IS CHECKED:
 * 1. Every case of _shared/tests/corpus/layouts/row_options_vectors.json:
 *    converting the layout the editor rewrote gives the same XKB and XCompose
 *    files as converting the plain layout with the options, its report equals
 *    the case's, and the editor changes nothing on the layout the composer
 *    already compiled with the options.
 * 2. Every shipped registry layout, with each ordering and edge-key choice: the
 *    same differential. These layouts reach Cmd and Ctrl through the plain
 *    keyMap (defaultIndex), so the editor's copy of the original keyMap is what
 *    keeps Ctrl+1 a digit; the converter reads that level before its swap.
 * 3. A renamed build carries the new name and the keyboard id the composer
 *    derives from it (composer_model.js keyboardId, the single rule).
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
const CONVERT = path.join(__dirname, 'fixtures', 'keylayout-xkb-convert.lua');
const APPLY = path.join(__dirname, 'fixtures', 'keylayout-rows-apply.lua');
const DATA = path.join(ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data');
const REGISTRY = path.join(ROOT, 'static', 'layouts', 'registry');
const TABLE_PATH = shared('modules', 'layouts', 'mac_keycodes.json');
const CASES = JSON.parse(
	fs.readFileSync(shared('tests', 'corpus', 'layouts', 'row_options_vectors.json'), 'utf8')
).cases;
const MIN_CASES = 10;
const MIN_REGISTRY_LAYOUTS = 5;
// Ergopti types its digits on both levels (digits_on_both), so of the shipped
// layouts only Ergo-L moves cells, with symbols first, edges or not.
const MIN_REGISTRY_VARIANTS_MOVED = 2;

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

function luaRuntime() {
	for (const name of ['luajit', 'lua5.4', 'lua'])
		if (spawnSync(name, ['-v'], { encoding: 'utf8' }).status === 0) return name;
	throw new Error('no Lua runtime on PATH');
}
const LUA = luaRuntime();

/** Converts one .keylayout text to XKB; null when refused. */
function convert(text, rows, convention, scratch, label) {
	const input = path.join(scratch, label + '.keylayout');
	const out = path.join(scratch, label);
	fs.mkdirSync(out, { recursive: true });
	fs.writeFileSync(input, text);
	const result = spawnSync(
		LUA,
		[CONVERT, shared(), DATA, input, TABLE_PATH, convention, 'rows_case', 'Rows case', out],
		{
			encoding: 'utf8',
			env: { ...process.env, ...(rows ? { ERGOPTI_ROWS: `${rows.order},${rows.edges}` } : {}) }
		}
	);
	if (result.status !== 0) return { refused: result.stderr.trim() };
	const read = (name) => fs.readFileSync(path.join(out, name), 'utf8');
	return {
		symbols: read('rows_case.xkb'),
		compose: read('rows_case.XCompose'),
		report: fs.existsSync(path.join(out, 'rows.json')) ? JSON.parse(read('rows.json')) : null
	};
}

/** Applies the options with the shared editor; { text, changed, report } or { refused }. */
function apply(text, rows, convention, scratch, label, name) {
	const input = path.join(scratch, label + '-in.keylayout');
	const output = path.join(scratch, label + '-out.keylayout');
	const report = path.join(scratch, label + '-report.json');
	fs.writeFileSync(input, text);
	const result = spawnSync(
		LUA,
		[
			APPLY,
			shared(),
			input,
			TABLE_PATH,
			convention,
			rows.order,
			String(rows.edges),
			output,
			report
		].concat(name ? [name] : []),
		{ encoding: 'utf8' }
	);
	if (result.status !== 0) return { refused: result.stderr.trim() };
	return { text: fs.readFileSync(output, 'utf8'), ...JSON.parse(fs.readFileSync(report, 'utf8')) };
}

const sameReport = (a, b) =>
	a &&
	b &&
	a.order === b.order &&
	a.reason === b.reason &&
	a.edges.applies === b.edges.applies &&
	a.edges.reason === b.edges.reason;

/** The editor's layout converts to what the converter makes of the options itself. */
function differential(text, rows, convention, scratch, label) {
	const viaConverter = convert(text, rows, convention, scratch, label + '-converter');
	const edited = apply(text, rows, convention, scratch, label);
	if (viaConverter.refused || edited.refused) {
		check(
			Boolean(viaConverter.refused) === Boolean(edited.refused),
			`${label}: converter ${viaConverter.refused || 'accepts'}, editor ${edited.refused || 'accepts'}`
		);
		return null;
	}
	const viaEditor = convert(edited.text, null, convention, scratch, label + '-editor');
	if (viaEditor.refused) {
		errors.push(`${label}: the edited layout no longer converts: ${viaEditor.refused}`);
		return null;
	}
	check(viaEditor.symbols === viaConverter.symbols, `${label}: the XKB symbols differ`);
	check(viaEditor.compose === viaConverter.compose, `${label}: the XCompose differs`);
	check(
		sameReport(edited.report, viaConverter.report),
		`${label}: editor ${JSON.stringify(edited.report)}, converter ${JSON.stringify(viaConverter.report)}`
	);
	check(
		edited.changed === (edited.report.order !== 'native'),
		`${label}: changed=${edited.changed} for the order ${edited.report.order}`
	);
	return edited;
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-keylayout-rows-'));
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
		const edited = differential(plainText, entry.rows, 'iso', scratch, entry.id);
		if (edited)
			check(
				sameReport(edited.report, {
					order: entry.effective.order,
					reason: entry.effective.reason,
					edges: entry.effective.edges
				}),
				`${entry.id}: the report is ${JSON.stringify(edited.report)}`
			);
		const again = apply(bakedText, entry.rows, 'iso', scratch, entry.id + '-again');
		check(
			!again.refused && again.changed === false,
			`${entry.id}: the options applied to the compiled layout change it (${again.refused || ''})`
		);
	}
	check(cases >= MIN_CASES, `only ${cases} cases`);

	const index = JSON.parse(fs.readFileSync(path.join(REGISTRY, 'index.json'), 'utf8'));
	let layouts = 0;
	let moved = 0;
	let split = 0;
	const keyMaps = (text) => (text.match(/<keyMap\s/g) || []).length;
	for (const layout of index.layouts) {
		layouts += 1;
		const text = fs.readFileSync(path.join(REGISTRY, layout.file), 'utf8');
		for (const order of ['digits', 'symbols'])
			for (const edges of [false, true]) {
				const edited = differential(
					text,
					{ order, edges },
					layout.keycode_convention,
					scratch,
					`${layout.id}-${order}-${edges}`
				);
				if (edited && edited.changed) moved += 1;
				if (edited && edited.changed && keyMaps(edited.text) > keyMaps(text)) split += 1;
			}
	}
	check(layouts >= MIN_REGISTRY_LAYOUTS, `only ${layouts} registry layouts`);
	check(moved >= MIN_REGISTRY_VARIANTS_MOVED, `only ${moved} registry variants moved a cell`);
	// Ergo-L reaches Cmd and Ctrl through its plain keyMap: a moved variant must
	// have copied that keyMap for them, which is what the differential then proves.
	check(
		split >= MIN_REGISTRY_VARIANTS_MOVED,
		`only ${split} registry variants kept a shortcut keyMap copy`
	);

	const names = ['Ergopti+', 'Ergopti+ 2', 'Rows azerty_digits', 'Bépo 7', 'Ergo‑L 12', 'Rows 3'];
	const ids = spawnSync(LUA, [APPLY, shared()], {
		encoding: 'utf8',
		env: { ...process.env, ERGOPTI_KEYBOARD_IDS: names.join('|') }
	});
	const luaIds = ids.stdout.trim().split('\n').map(Number);
	const composerId = (name) => {
		const built = Composer.build(Composer.emptyDeclaration(name, 'iso', 'qwerty'), SOURCES, TABLE);
		return Number(/<keyboard [^>]*id="(-?\d+)"/.exec(Composer.serialize(built.layout, TABLE))[1]);
	};
	const jsIds = names.map(composerId);
	check(
		JSON.stringify(luaIds) === JSON.stringify(jsIds),
		`keyboard ids: Lua ${JSON.stringify(luaIds)}, composer ${JSON.stringify(jsIds)}`
	);
	const plainText = Composer.serialize(
		Composer.build(Composer.emptyDeclaration('Rows rename', 'iso', 'qwerty'), SOURCES, TABLE)
			.layout,
		TABLE
	);
	const renamed = apply(
		plainText,
		{ order: 'symbols', edges: false },
		'iso',
		scratch,
		'rename',
		'Rows 3'
	);
	check(
		!renamed.refused &&
			new RegExp(`<keyboard [^>]*id="${composerId('Rows 3')}"[^>]*name="Rows 3"`).test(
				renamed.text
			),
		`rename: the build does not carry its new name and id (${renamed.refused || ''})`
	);
} finally {
	if (!process.env.KEEP_SCRATCH) fs.rmSync(scratch, { recursive: true, force: true });
}

if (errors.length > 0) {
	console.error(`test-keylayout-row-options: ${errors.length} problem(s)`);
	for (const message of errors.slice(0, 40)) console.error(`  - ${message}`);
	process.exit(1);
}
console.log(
	`test-keylayout-row-options: OK (${CASES.length} cases and the registry layouts, editor and converter agree)`
);
