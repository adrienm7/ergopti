// tools/test/test-layout-editor-model.cjs

/**
 * ==============================================================================
 * MODULE: Unified Layout Editor Model Tests
 * DESCRIPTION:
 * Runs the editor's pure scripts in a vm context, in the order the page loads
 * them (the vendored TOML codec included), and checks the source I/O module
 * and the editing model: round trips, refusals, .keylayout preservation and
 * projection, the navigation layer conversion, dead-key typing and history.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shared } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const UI = shared('ui');
const PAGE_SCRIPTS = [
	'layer_editor/_generated/layer_data.js',
	'layout_composer/_generated/composer_data.js',
	'layer_editor/layer_model.js',
	'layout_composer/composer_model.js',
	'layout_composer/reference_layouts.js',
	'layout_composer/source_model.js',
	'layout_composer/source_compiler.js',
	'layout_composer/source_emulation.js',
	'layout_editor/_generated/key_tables.js',
	'layout_editor/zip_writer.js',
	'layout_editor/toml_prelude.js',
	'vendor/smol-toml.js',
	'layout_editor/_generated/kbd_dll_writer.js',
	'layout_editor/source_io.js',
	'layout_editor/editor_model.js'
];

/** The scripts index.html loads, in its order, with the same global names. */
function loadEditor() {
	const html = fs.readFileSync(path.join(UI, 'layout_editor', 'index.html'), 'utf8');
	const loaded = [...html.matchAll(/<script src="([^"]+)"/g)]
		.map((m) => path.relative(UI, path.resolve(path.join(UI, 'layout_editor'), m[1])))
		.filter((file) => PAGE_SCRIPTS.includes(file));
	assert.deepEqual(loaded, PAGE_SCRIPTS, 'index.html loads the model scripts in this order');
	// The globals a page has that the scripts use.
	const context = vm.createContext({ TextEncoder });
	for (const file of PAGE_SCRIPTS) {
		// A top-level const is not a property of the context; the page reads these as globals.
		const source = fs
			.readFileSync(path.join(UI, file), 'utf8')
			.replace(
				/^const (LAYOUT_COMPOSER_DATA|LAYER_EDITOR_DATA|LAYOUT_SOURCE_TABLES) =/m,
				'var $1 ='
			);
		vm.runInContext(source, context, { filename: file });
	}
	return vm.runInContext(
		'({ IO: LayoutSourceIO, M: LayoutEditorModel, Zip: LayoutZipWriter, LayerModel, LayoutComposer, DATA: LAYER_EDITOR_DATA, COMPOSER: LAYOUT_COMPOSER_DATA })',
		context
	);
}

const { IO, M, Zip, LayerModel, LayoutComposer, DATA, COMPOSER } = loadEditor();
const plain = (value) => JSON.parse(JSON.stringify(value));
const registry = (id) =>
	fs.readFileSync(path.join(ROOT, 'static', 'layouts', 'registry', id, `${id}.keylayout`), 'utf8');
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const refuses = (fn, code) =>
	assert.throws(fn, (error) => error.code === code, `expected the refusal ${code}`);

test('the vendored codec is the locked smol-toml release, byte for byte', () => {
	const manifest = JSON.parse(
		fs.readFileSync(path.join(UI, 'vendor', 'vendor-manifest.json'), 'utf8')
	);
	const asset = manifest.assets.find((entry) => entry.file === 'smol-toml.js');
	const lock = JSON.parse(fs.readFileSync(path.join(ROOT, 'package-lock.json'), 'utf8'));
	assert.equal(lock.packages['node_modules/smol-toml'].version, asset.version);
	const installed = path.join(ROOT, 'node_modules', 'smol-toml', 'dist', 'index.cjs');
	if (fs.existsSync(installed))
		assert.ok(
			fs.readFileSync(installed).equals(fs.readFileSync(path.join(UI, 'vendor', 'smol-toml.js')))
		);
});

test('a new source saves and reads back unchanged', () => {
	let doc = IO.create('my_layout', 'Mine');
	doc = M.setMapping(doc, 'base', 'KeyA', { text: 'ffi🦆' }, null);
	doc = M.setLayout(doc, { description: 'Test', author: 'Someone' });
	const text = IO.serialize(doc);
	const read = IO.parse(text);
	assert.equal(read.ok, true);
	assert.deepEqual(plain(read.doc), plain(doc));
	assert.equal(IO.serialize(read.doc), text);
});

test('an unreadable or foreign document is refused with a stable code', () => {
	assert.deepEqual(plain(IO.parse('format = ')).error.code, 'toml_syntax');
	const foreign = IO.parse(
		'format = "other"\nversion = 1\n[layout]\nid = "a"\nname = "A"\n[physical]\nbase = "iso"\n'
	);
	assert.equal(foreign.error.code, 'source_format');
	const typo = IO.parse(
		IO.serialize(IO.create('a', 'A')).replace('[layout]', '[layout]\nnmae = "x"')
	);
	assert.equal(typo.error.code, 'source_unknown_field');
});

test('platform overrides win on their OS only and vanish when cleared', () => {
	let doc = IO.create('a', 'A');
	doc = M.setMapping(doc, 'base', 'KeyQ', { text: 'q' }, null);
	doc = M.setMapping(doc, 'base', 'KeyQ', { action: 'arrow_left' }, 'macos');
	assert.deepEqual(plain(M.mappingAt(doc, 'base', 'KeyQ', 'macos')), {
		mapping: { action: 'arrow_left' },
		scope: 'macos'
	});
	assert.equal(M.mappingAt(doc, 'base', 'KeyQ', 'linux').scope, 'all');
	doc = M.setMapping(doc, 'base', 'KeyQ', null, 'macos');
	assert.equal(Object.prototype.hasOwnProperty.call(doc.layers[0], 'platform_keys'), false);
	refuses(() => M.setMapping(doc, 'base', 'KeyQ', { text: 'x' }, 'beos'), 'platform_unknown');
});

test('an invalid edit is refused and leaves the document as it was', () => {
	const doc = IO.create('a', 'A');
	const before = JSON.stringify(doc);
	refuses(
		() => M.setMapping(doc, 'base', 'KeyA', { dead_key: 'missing' }, null),
		'source_reference'
	);
	refuses(
		() => M.setMapping(doc, 'base', 'KeyA', { text: 'a', action: 'x' }, null),
		'source_invalid'
	);
	assert.equal(JSON.stringify(doc), before);
});

test('modifiers, layers and dead keys still in use cannot be removed', () => {
	let doc = IO.create('a', 'A');
	doc = M.setModifier(doc, 'roya', 'locked', ['ScrollLock']);
	doc = M.addLayer(doc, 'roya', ['roya'], ['shift']);
	refuses(() => M.removeModifier(doc, 'roya'), 'modifier_in_use');
	refuses(() => M.removeLayer(doc, 'base'), 'layer_base_required');
	doc = M.setTapHold(doc, {
		key: 'CapsLock',
		tap: { key: 'Escape' },
		hold_layer: 'roya',
		threshold_ms: 180
	});
	refuses(() => M.removeLayer(doc, 'roya'), 'layer_in_use');
	doc = M.removeTapHold(doc, 'CapsLock');
	doc = M.removeLayer(doc, 'roya');
	doc = M.removeModifier(doc, 'roya');
	assert.equal(doc.modifiers, undefined);
	doc = M.setDeadKey(doc, 'circ', 'Circumflex', '^');
	doc = M.setMapping(doc, 'base', 'BracketLeft', { dead_key: 'circ' }, null);
	refuses(() => M.removeDeadKey(doc, 'circ'), 'dead_key_in_use');
	refuses(() => M.setModifier(doc, 'shift', 'held', ['Fn']), 'source_duplicate');
});

test('the most specific layer the held modifiers reach is chosen', () => {
	let doc = IO.create('a', 'A');
	doc = M.addLayer(doc, 'shift', ['shift'], []);
	doc = M.addLayer(doc, 'altgr', ['alt'], ['shift']);
	doc = M.addLayer(doc, 'shift_altgr', ['shift', 'alt'], []);
	assert.equal(M.layerFor(doc, []), 'base');
	assert.equal(M.layerFor(doc, ['shift']), 'shift');
	assert.equal(M.layerFor(doc, ['alt']), 'altgr');
	assert.equal(M.layerFor(doc, ['shift', 'alt']), 'shift_altgr');
	assert.equal(M.layerFor(doc, ['control']), null);
});

test('typing follows dead keys, chains, terminators and ligatures', () => {
	let doc = IO.create('a', 'A');
	doc = M.setDeadKey(doc, 'circ', '', '^');
	doc = M.setDeadKey(doc, 'tilde', '', '~');
	doc = M.setDeadRule(doc, 'circ', 'a', { text: 'â' });
	doc = M.setDeadRule(doc, 'circ', '~', { next: 'tilde' });
	doc = M.setDeadRule(doc, 'tilde', 'e', { text: 'ễ' });
	doc = M.setMapping(doc, 'base', 'BracketLeft', { dead_key: 'circ' }, null);
	doc = M.setMapping(doc, 'base', 'KeyA', { text: 'a' }, null);
	doc = M.setMapping(doc, 'base', 'KeyE', { text: 'e' }, null);
	doc = M.setMapping(doc, 'base', 'KeyX', { text: 'x' }, null);
	doc = M.setMapping(doc, 'base', 'KeyT', { text: '~' }, null);
	doc = M.setMapping(doc, 'base', 'KeyL', { text: 'ffl' }, null);
	const press = (...codes) => codes.map((code) => ({ code, held: [] }));
	assert.equal(M.simulate(doc, press('BracketLeft', 'KeyA'), null).text, 'â');
	assert.equal(M.simulate(doc, press('BracketLeft', 'KeyX'), null).text, '^x');
	assert.equal(M.simulate(doc, press('BracketLeft', 'KeyT', 'KeyE'), null).text, 'ễ');
	assert.equal(M.simulate(doc, press('BracketLeft', 'BracketLeft'), null).text, '^');
	assert.deepEqual(plain(M.simulate(doc, press('BracketLeft', 'KeyT'), null)), {
		text: '',
		pending: 'tilde'
	});
	assert.equal(M.simulate(doc, press('KeyL', 'KeyQ'), null).text, 'ffl');
});

test('history undoes and redoes whole snapshots', () => {
	const first = IO.create('a', 'A');
	const history = M.createHistory(first);
	const second = history.push(M.setMapping(first, 'base', 'KeyA', { text: 'a' }, null));
	assert.equal(history.canUndo(), true);
	assert.equal(history.undo(), first);
	assert.equal(history.redo(), second);
	history.undo();
	history.push(M.setMapping(first, 'base', 'KeyB', { text: 'b' }, null));
	assert.equal(history.canRedo(), false);
});

test('an imported .keylayout exports byte for byte until it is edited', () => {
	for (const id of ['ergopti', 'ergopti_plus', 'ergopti_ansi']) {
		const xml = registry(id);
		const convention = id.endsWith('_ansi') ? 'ansi' : 'iso';
		const doc = IO.importKeylayout(xml, id, convention);
		assert.equal(IO.exportKeylayout(IO.parse(IO.serialize(doc)).doc), xml);
		assert.equal(IO.capabilities(doc).find((row) => row.target === 'macos').status, 'native');
		refuses(() => M.setMapping(doc, 'base', 'KeyA', { text: 'z' }, null), 'source_preserved');
	}
});

/** The four character levels the composer reader sees, as held modifiers. */
const LEVELS = {
	base: [],
	shift: ['shift_left'],
	altgr: ['alt_left'],
	shift_altgr: ['shift_left', 'alt_left']
};

/** Every printable cell of the four levels types the same text in the converted source. */
function assertTypesLike(xml, doc, label) {
	const source = LayoutComposer.parseSource('x', xml, 'iso', COMPOSER);
	let checked = 0;
	for (const [layer, held] of Object.entries(LEVELS))
		for (const [code, cells] of Object.entries(source.cells)) {
			const cell = cells[layer];
			if (!cell || cell.text === undefined) continue;
			assert.equal(
				M.simulate(doc, [{ code, held }], null).text,
				cell.text,
				`${label} ${layer} ${code}`
			);
			checked++;
		}
	assert.ok(checked > 150, `${label}: only ${checked} cells compared`);
}

test('the exact conversion keeps the behaviour and compiles back to the same characters', () => {
	for (const id of ['ergopti', 'ergopti_plus']) {
		const xml = registry(id);
		const converted = IO.convertImport(IO.importKeylayout(xml, id, 'iso'));
		assert.deepEqual(plain(converted.lost), ['keylayout_original_xml']);
		assertTypesLike(xml, converted.doc, id);
		const compiled = IO.keylayoutFile(converted.doc, 'iso');
		assert.match(compiled.filename, /\.keylayout$/);
		const before = LayoutComposer.parseSource('a', xml, 'iso', COMPOSER).cells;
		const after = LayoutComposer.parseSource('b', compiled.text, 'iso', COMPOSER).cells;
		for (const layer of Object.keys(LEVELS))
			for (const code of Object.keys(before))
				assert.equal(
					(after[code][layer] || {}).text,
					(before[code][layer] || {}).text,
					`${id} compiled ${layer} ${code}`
				);
		assert.ok(IO.keylayoutFile(converted.doc, 'ansi').text.length > 0, 'the ANSI variant compiles');
		const report = IO.capabilities(converted.doc);
		assert.ok(['native', 'partial'].includes(report.find((row) => row.target === 'macos').status));
		for (const target of ['driver_macos', 'driver_linux'])
			assert.ok(
				['emulated', 'partial'].includes(report.find((row) => row.target === target).status),
				target
			);
		const payload = IO.installPayload(converted.doc, 'linux');
		assert.equal(IO.parse(payload.source).ok, true);
		assert.match(payload.keylayout, /<keyboard /);
		const emulation = JSON.parse(payload.emulation);
		assert.equal(emulation.platform, 'linux');
		assert.equal(emulation.layout, converted.doc.layout.id);
	}
	refuses(() => IO.convertImport(IO.create('a', 'A')), 'source_not_imported');
});

test('the repository tool writes the payload « Install and use » sends', () => {
	const os = require('node:os');
	const { spawnSync } = require('node:child_process');
	const file = path.join(ROOT, 'static', 'layouts', 'sources', 'ergopti.toml');
	const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'install-payload-')), 'payload.json');
	// The Linux E2E rows run the tool with no node_modules: any npm package it
	// loads is refused here, as it is missing there.
	const guard = path.join(path.dirname(out), 'no-packages.cjs');
	fs.writeFileSync(
		guard,
		[
			"const Module = require('node:module');",
			'const resolve = Module._resolveFilename;',
			'Module._resolveFilename = function (request, ...rest) {',
			'\tif (!/^[./]/.test(request) && !Module.isBuiltin(request))',
			'\t\tthrow new Error(`npm package ${request} is not installed in the E2E rows`);',
			'\treturn resolve.call(this, request, ...rest);',
			'};',
			''
		].join('\n')
	);
	try {
		const run = spawnSync(
			process.execPath,
			[
				'--require',
				guard,
				path.join(ROOT, 'tools', 'layout-source.cjs'),
				'install-payload',
				file,
				'linux',
				out
			],
			{ encoding: 'utf8' }
		);
		assert.equal(run.status, 0, run.stderr);
		const page = plain(IO.installPayload(IO.parse(fs.readFileSync(file, 'utf8')).doc, 'linux'));
		assert.deepEqual(
			JSON.parse(fs.readFileSync(out, 'utf8')),
			page,
			'the tool and the page send the same'
		);
	} finally {
		fs.rmSync(path.dirname(out), { recursive: true, force: true });
	}
});

test('a preserved import installs and exports its own XML, only in its own variant', () => {
	const xml = registry('ergopti');
	const doc = IO.importKeylayout(xml, 'ergopti', 'iso');
	assert.equal(IO.installPayload(doc, 'macos').keylayout, xml);
	assert.equal(IO.installPayload(doc, 'macos').emulation, undefined, 'an import has no table');
	assert.equal(IO.keylayoutFile(doc, 'iso').text, xml);
	refuses(() => IO.keylayoutFile(doc, 'ansi'), 'source_export_unavailable');
});

test('the approximate conversion keeps the composer levels and says what it drops', () => {
	const xml = registry('ergopti');
	const projected = IO.approximateImport(IO.importKeylayout(xml, 'ergopti', 'iso'));
	assert.deepEqual(plain(projected.lost), ['keylayout_original_xml', 'keylayout_sided_modifiers']);
	assertTypesLike(xml, projected.doc, 'approximate');
	assert.ok(projected.doc.dead_keys.length > 0, 'dead keys are kept');
	for (const dead of projected.doc.dead_keys) assert.ok(dead.rules.length > 0, dead.id);
	assert.ok(
		IO.approximateImport(IO.importKeylayout(registry('ergopti_ansi'), 'x', 'ansi')).lost.includes(
			'keylayout_ansi_projected_iso'
		)
	);
	refuses(() => IO.approximateImport(IO.create('a', 'A')), 'source_not_imported');
});

test('sided modifiers and alternative selectors reach their layer', () => {
	let doc = IO.create('a', 'A');
	doc = M.addLayer(doc, 'shift', ['shift'], []);
	doc = M.addLayer(doc, 'left_alt', ['alt_left'], []);
	assert.equal(M.layerFor(doc, ['shift_right']), 'shift');
	assert.equal(M.layerFor(doc, ['alt_left']), 'left_alt');
	assert.equal(M.layerFor(doc, ['alt_right']), null);
	const next = plain(doc);
	next.layers.find((layer) => layer.id === 'left_alt').alternatives = [
		{ required: ['meta'], optional: [] }
	];
	assert.equal(IO.check(next).ok, true);
	assert.equal(M.layerFor(next, ['meta_left']), 'left_alt');
});

/** What layers.toml gives each key on one OS, `primary` resolved. */
function navEffective(text, os) {
	const doc = LayerModel.readLayerFile(text, DATA).doc;
	const out = {};
	for (const [code, { value }] of Object.entries(LayerModel.effective(doc, DATA.layer, os)))
		out[code] = value.replace(/primary\+/g, `${DATA.primary_modifier[os]}+`);
	return out;
}

test('the navigation layer converts both ways without changing a binding on any OS', () => {
	const recommended = fs.readFileSync(shared('layouts', 'data', 'layers.recommended.toml'), 'utf8');
	const doc = IO.withNavLayer(IO.create('a', 'A'), recommended, ['CapsLock'], DATA);
	const nav = doc.layers.find((layer) => layer.id === 'nav');
	assert.deepEqual(plain(nav.required), ['nav']);
	assert.deepEqual(plain(doc.modifiers.find((m) => m.id === 'nav').keys), ['CapsLock']);
	const written = IO.navLayerFile(doc, DATA);
	assert.equal(LayerModel.readLayerFile(written, DATA).problem, null);
	for (const os of DATA.platforms)
		assert.deepEqual(navEffective(written, os), navEffective(recommended, os), os);
	const again = IO.withNavLayer(IO.create('a', 'A'), written, ['CapsLock'], DATA);
	assert.equal(IO.navLayerFile(again, DATA), written, 'the conversion is a fixpoint');
	assert.equal(IO.parse(IO.serialize(doc)).ok, true);
});

test('navigation layer refusals name their cause', () => {
	const file = (binding) =>
		`[_meta]\nschema_version = 1\n\n[layers.nav.all]\n"KeyA" = "${binding}"\n`;
	refuses(
		() =>
			IO.withNavLayer(IO.create('a', 'A'), file('keystroke:ctrl+KeyA,KeyB'), ['CapsLock'], DATA),
		'nav_binding_sequence'
	);
	refuses(
		() => IO.withNavLayer(IO.create('a', 'A'), file('arrow_left'), [], DATA),
		'nav_hold_key_missing'
	);
	refuses(
		() => IO.withNavLayer(IO.create('a', 'A'), '[_meta]\nschema_version = 9\n', ['CapsLock'], DATA),
		'nav_file_invalid'
	);
	const fn = IO.withNavLayer(IO.create('a', 'A'), file('keystroke:fn+KeyA'), ['CapsLock'], DATA);
	assert.ok(
		fn.modifiers.some((m) => m.id === 'fn'),
		'fn is declared when a binding uses it'
	);
	let doc = M.setMapping(IO.create('a', 'A'), 'base', 'KeyA', { text: 'a' }, null);
	doc = M.setModifier(doc, 'nav', 'held', ['CapsLock']);
	doc = M.addLayer(doc, 'nav', ['nav'], []);
	doc = M.setMapping(doc, 'nav', 'KeyA', { text: 'a' }, null);
	refuses(() => IO.navLayerFile(doc, DATA), 'nav_mapping_unsupported');
	refuses(
		() =>
			IO.withNavLayer(
				IO.importKeylayout(registry('ergopti'), 'e', 'iso'),
				file('arrow_left'),
				['CapsLock'],
				DATA
			),
		'source_preserved'
	);
});

test('identifiers derived from file names are valid format identifiers', () => {
	assert.equal(IO.identifierFrom('Ergopti v2.2 (ISO)', 'layout'), 'ergopti_v2_2_iso');
	assert.equal(IO.identifierFrom('2024 Été', 'layout'), 'layout_2024_ete');
});

test('drag and drop swaps two keys, and a copy leaves the source', () => {
	let doc = IO.create('a', 'A');
	doc = M.setMapping(doc, 'base', 'KeyA', { text: 'a' }, null);
	doc = M.setMapping(doc, 'base', 'KeyB', { text: 'b' }, null);
	const swapped = M.transferMapping(doc, 'base', 'KeyA', 'KeyB', null, false);
	assert.equal(swapped.layers[0].keys.KeyA.text, 'b');
	assert.equal(swapped.layers[0].keys.KeyB.text, 'a');
	const copied = M.transferMapping(doc, 'base', 'KeyA', 'KeyC', null, true);
	assert.equal(copied.layers[0].keys.KeyC.text, 'a');
	assert.equal(copied.layers[0].keys.KeyA.text, 'a');
	const moved = M.transferMapping(doc, 'base', 'KeyA', 'KeyD', null, false);
	assert.equal(moved.layers[0].keys.KeyA, undefined, 'a swap with an empty key empties the source');
	assert.equal(M.transferMapping(doc, 'base', 'KeyA', 'KeyA', null, false), doc);
});

test('a letter fills its other case on the case layer, never over a mapping', () => {
	let doc = IO.create('a', 'A');
	assert.equal(M.caseLayer(doc, 'base'), null, 'no Shift layer yet');
	doc = M.addLayer(doc, 'shift', ['shift'], []);
	assert.equal(M.caseLayer(doc, 'base').id, 'shift');
	assert.equal(M.caseLayer(doc, 'shift').id, 'base');
	doc = M.setMappingWithCase(doc, 'base', 'KeyQ', { text: 'é' }, null, false);
	assert.equal(M.mappingAt(doc, 'shift', 'KeyQ', null).mapping.text, 'É');
	doc = M.setMappingWithCase(doc, 'shift', 'KeyW', { text: 'Ω' }, null, false);
	assert.equal(M.mappingAt(doc, 'base', 'KeyW', null).mapping.text, 'ω');
	doc = M.setMapping(doc, 'shift', 'KeyE', { text: '!' }, null);
	doc = M.setMappingWithCase(doc, 'base', 'KeyE', { text: 'e' }, null, false);
	assert.equal(M.mappingAt(doc, 'shift', 'KeyE', null).mapping.text, '!', 'a mapped partner stays');
	doc = M.setMappingWithCase(doc, 'base', 'KeyE', { text: 'e' }, null, true);
	assert.equal(M.mappingAt(doc, 'shift', 'KeyE', null).mapping.text, 'E', 'overwrite replaces it');
	// No one-letter other case: ß (SS), a digit, a ligature.
	for (const text of ['ß', '1', 'ff'])
		assert.equal(
			M.mappingAt(
				M.setMappingWithCase(doc, 'base', 'KeyR', { text }, null, false),
				'shift',
				'KeyR',
				null
			),
			null,
			text
		);
	// A platform override fills the partner's override, not the shared cell.
	doc = M.setMappingWithCase(doc, 'base', 'KeyT', { text: 'þ' }, 'linux', false);
	assert.equal(M.mappingAt(doc, 'shift', 'KeyT', 'linux').scope, 'linux');
	assert.equal(M.mappingAt(doc, 'shift', 'KeyT', null), null);
});

test('every mapping of a layer moves or copies to another layer at once', () => {
	let doc = M.addLayer(IO.create('a', 'A'), 'shift', ['shift'], []);
	doc = M.setMapping(doc, 'base', 'KeyA', { text: 'a' }, null);
	doc = M.setMapping(doc, 'shift', 'KeyB', { text: 'B' }, null);
	const moved = M.transferLayer(doc, 'base', 'shift', false);
	assert.equal(M.mappingAt(moved, 'shift', 'KeyA', null).mapping.text, 'a');
	assert.equal(M.mappingAt(moved, 'shift', 'KeyB', null).mapping.text, 'B', 'other cells stay');
	assert.equal(M.mappingAt(moved, 'base', 'KeyA', null), null);
	const copied = M.transferLayer(doc, 'base', 'shift', true);
	assert.equal(M.mappingAt(copied, 'base', 'KeyA', null).mapping.text, 'a');
	refuses(() => M.transferLayer(doc, 'base', 'nowhere', true), 'layer_unknown');
});

test('the preview types through the web emulation on top of the native layout', () => {
	const fixture = fs.readFileSync(
		shared('tests', 'corpus', 'layouts', 'source', 'source.toml'),
		'utf8'
	);
	const doc = IO.parse(fixture).doc;
	// macOS sees no Scroll Lock press; the emulated Kana key is Insert here.
	doc.modifiers[0].keys = ['Insert'];
	const typist = M.previewTypist(doc, 'macos');
	const presses = [];
	const add = (entries) => presses.push(...plain(entries));
	const type = () => M.simulate(doc, presses, null).text;
	// A native key passes through to the .keylayout typing.
	add(typist.down('KeyA', [], 0));
	assert.equal(type(), 'a');
	// The locked Kana modifier selects its emulated layer, and a second press unlocks it.
	assert.ok(typist.owns('Insert'));
	add(typist.down('Insert', [], 10));
	add(typist.up('Insert', 20));
	add(typist.down('KeyA', [], 30));
	add(typist.down('Insert', [], 40));
	add(typist.up('Insert', 50));
	assert.equal(type(), 'aあ');
	// A tap-hold: a quick tap types its tap, a hold reaches its layer.
	assert.equal(typist.pendingThreshold(), null);
	add(typist.down('Space', [], 100));
	assert.equal(typist.pendingThreshold(), 180);
	add(typist.up('Space', 150));
	assert.equal(type(), 'aあ ');
	add(typist.down('Space', [], 200));
	add(typist.tick(400));
	add(typist.down('KeyJ', [], 410));
	add(typist.up('KeyJ', 420));
	add(typist.up('Space', 430));
	// The hold reaches the native command layer: the key goes out with Command.
	assert.equal(type(), 'aあ ⟨meta+KeyJ⟩');
	// A shortcut sending another chord shows as that chord.
	add(typist.down('KeyA', ['control_left'], 500));
	assert.equal(type(), 'aあ ⟨meta+KeyJ⟩⟨control+KeyB⟩');
	// Emulated output ends a pending dead key with its terminator.
	add(typist.down('BracketLeft', [], 600));
	presses.push({ text: '!' });
	assert.equal(type(), 'aあ ⟨meta+KeyJ⟩⟨control+KeyB⟩^!');
	refuses(
		() => M.previewTypist(IO.importKeylayout(registry('ergopti'), 'e', 'iso'), 'macos'),
		'source_imported_preserved'
	);
});

test('Windows flags and NLS functions are edited and refused like any record', () => {
	let doc = IO.create('a', 'A');
	doc = M.setWindowsFlags(doc, ['kllf_altgr']);
	doc = M.setNls(doc, {
		key: 'KeyQ',
		modifiers: ['shift'],
		function: 'kana_toggle',
		parameter_key: 'KeyW'
	});
	doc = M.setNls(doc, { key: 'KeyQ', modifiers: ['shift'], function: 'kana_lock' });
	assert.deepEqual(plain(doc.windows), {
		flags: ['kllf_altgr'],
		nls: [{ key: 'KeyQ', modifiers: ['shift'], function: 'kana_lock' }]
	});
	refuses(() => M.setWindowsFlags(doc, ['Bad Flag']), 'source_invalid');
	doc = M.removeNls(M.setWindowsFlags(doc, []), 'KeyQ', ['shift']);
	assert.equal(doc.windows, undefined);
});

test('the ZIP writer produces an archive any unzip reads back, byte for byte', () => {
	const { execFileSync } = require('node:child_process');
	const os = require('node:os');
	const files = [
		{ path: 'b.bundle/Contents/Info.plist', text: '<plist/>\n', encoding: 'utf8' },
		{
			path: 'b.bundle/Contents/Resources/fr.lproj/InfoPlist.strings',
			text: '\ufeff"x" = "Été";\n',
			encoding: 'utf16le'
		}
	];
	const bytes = Zip.pack(files);
	assert.equal(
		Zip.crc32(new TextEncoder().encode('123456789')),
		0xcbf43926,
		'the CRC-32 check value'
	);
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'layout-editor-zip-'));
	try {
		const archive = path.join(dir, 'a.zip');
		fs.writeFileSync(archive, bytes);
		const listing = execFileSync(
			'python3',
			[
				'-I',
				'-c',
				'import sys,zipfile,json; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; print(json.dumps({n: z.read(n).hex() for n in z.namelist()}))',
				archive
			],
			{ encoding: 'utf8' }
		);
		const read = JSON.parse(listing);
		assert.deepEqual(
			Object.keys(read),
			files.map((file) => file.path)
		);
		assert.equal(Buffer.from(read[files[0].path], 'hex').toString('utf8'), files[0].text);
		assert.equal(Buffer.from(read[files[1].path], 'hex').toString('utf16le'), files[1].text);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
	assert.throws(() => Zip.pack([{ path: '../x', text: '', encoding: 'utf8' }]), /unsafe path/);
	assert.deepEqual(Zip.pack(files), bytes, 'the same files give the same bytes');
});

test('a structured source downloads its macOS bundle as one archive', () => {
	const converted = IO.convertImport(IO.importKeylayout(registry('ergopti'), 'ergopti', 'iso')).doc;
	const archive = IO.macosBundleArchive(converted);
	assert.match(archive.filename, /\.bundle\.zip$/);
	assert.ok(archive.bytes.length > 1000);
	refuses(
		() => IO.macosBundleArchive(IO.importKeylayout(registry('ergopti'), 'e', 'iso')),
		'source_export_unavailable'
	);
});

test('the macOS download follows the export format drop-down', () => {
	const converted = IO.convertImport(IO.importKeylayout(registry('ergopti'), 'ergopti', 'iso')).doc;
	assert.match(IO.macosDownload(converted).filename, /\.bundle\.zip$/, 'bundle by default');
	const iso = IO.macosDownload(converted, 'iso');
	const ansi = IO.macosDownload(converted, 'ansi');
	assert.equal(iso.mime, 'application/xml');
	assert.equal(iso.text, IO.keylayoutFile(converted, 'iso').text);
	assert.equal(ansi.text, IO.keylayoutFile(converted, 'ansi').text);
	assert.notEqual(iso.text, ansi.text);
	const preserved = IO.importKeylayout(registry('ergopti'), 'e', 'iso');
	assert.equal(IO.macosDownload(preserved).text, registry('ergopti'), 'an import stays verbatim');
	refuses(() => IO.macosDownload(preserved, 'bundle'), 'source_export_unavailable');
	refuses(() => IO.macosDownload(preserved, 'ansi'), 'source_export_unavailable');
});

test('a layer fills from a reference or a registry layout, dead keys included', () => {
	const sources = IO.fillSources([
		{ id: 'ergopti', name: 'Ergopti', convention: 'iso', text: registry('ergopti') },
		{ id: 'broken', name: 'Broken', convention: 'iso', text: '<keyboard' }
	]);
	assert.deepEqual(
		plain(sources.map((entry) => entry.id)),
		['qwerty', 'azerty', 'ergopti'],
		'references first, an unreadable layout left out'
	);
	const azerty = sources.find((entry) => entry.id === 'azerty');
	let doc = M.setMapping(IO.create('a', 'A'), 'base', 'Digit9', { text: 'stale' }, null);
	doc = IO.fillLayer(doc, azerty, 'base', 'base');
	const press = (...codes) => codes.map((code) => ({ code, held: [] }));
	assert.equal(M.simulate(doc, press('KeyQ', 'KeyW'), null).text, 'az');
	assert.equal(
		M.simulate(doc, press('BracketLeft', 'KeyE'), null).text,
		'ê',
		'the circumflex dead key came along'
	);
	doc = M.addLayer(doc, 'shift', ['shift'], []);
	const again = IO.fillLayer(IO.fillLayer(doc, azerty, 'shift', 'shift'), azerty, 'shift', 'shift');
	assert.equal(
		again.dead_keys.length,
		IO.fillLayer(doc, azerty, 'shift', 'shift').dead_keys.length,
		'filling twice replaces, never duplicates, its dead keys'
	);
	const ergopti = IO.fillLayer(IO.create('b', 'B'), sources[2], 'base', 'base');
	const reference = LayoutComposer.parseSource('e', registry('ergopti'), 'iso', COMPOSER).cells;
	for (const [code, cells] of Object.entries(reference))
		if (cells.base && cells.base.text !== undefined)
			assert.equal(M.simulate(ergopti, press(code), null).text, cells.base.text, code);
	refuses(() => IO.fillLayer(doc, azerty, 'base', 'missing'), 'layer_unknown');
});

test('a new layout starts blank or as a copy of a reference or a registry layout', () => {
	const sources = IO.fillSources(
		['bepo', 'ergol', 'ergopti'].map((id) => ({
			id,
			name: id,
			convention: 'iso',
			text: registry(id)
		}))
	);
	const press = (...codes) => codes.map((code) => ({ code, held: [] }));
	const shift = (code) => [{ code, held: ['shift'] }];
	const azerty = IO.startFrom(
		sources.find((entry) => entry.id === 'azerty'),
		'azerty_custom',
		'My AZERTY'
	);
	assert.deepEqual(plain(azerty.lost), [], 'a reference projects without loss');
	assert.equal(azerty.doc.layout.id, 'azerty_custom');
	assert.equal(azerty.doc.layout.name, 'My AZERTY');
	assert.equal(M.simulate(azerty.doc, press('KeyQ', 'KeyW'), null).text, 'az');
	assert.equal(M.simulate(azerty.doc, shift('KeyQ'), null).text, 'A', 'the Shift level came along');
	for (const id of ['bepo', 'ergol', 'ergopti']) {
		const started = IO.startFrom(
			sources.find((entry) => entry.id === id),
			`${id}_custom`,
			`My ${id}`
		);
		assert.equal(LayoutSourceIO_preserved(started.doc), false, `${id}: an editable source`);
		assert.equal(started.doc.layout.id, `${id}_custom`);
		const reference = LayoutComposer.parseSource(id, registry(id), 'iso', COMPOSER).cells;
		for (const [code, cells] of Object.entries(reference))
			if (cells.base && cells.base.text !== undefined)
				assert.equal(
					M.simulate(started.doc, press(code), null).text,
					cells.base.text,
					`${id} ${code}`
				);
		// It compiles for the drivers like any source.
		assert.match(IO.installPayload(started.doc, 'linux').keylayout, /<keyboard /);
	}
});

test('the page writes the Windows DLLs the repository tool writes, and the Windows host gets them', () => {
	const PeWriter = require('../lib/kbd-dll/pe-writer.cjs');
	const KbdSource = require('../lib/kbd-dll/source.cjs');
	const { readDll } = require('../lib/kbd-dll/reader.cjs');
	const { compareLayout } = require('../lib/kbd-dll/compare.cjs');
	const text = fs.readFileSync(
		path.join(ROOT, 'static', 'layouts', 'sources', 'ergopti.toml'),
		'utf8'
	);
	const doc = IO.parse(text).doc;
	const page = IO.windowsDlls(doc);
	const tool = KbdSource.fromSource(plain(doc));
	assert.equal(page.dllName, tool.model.dll_name);
	assert.deepEqual(plain(page.omitted), tool.omitted, 'the same omissions as the tool');
	const written = PeWriter.writeDlls(tool.model);
	assert.deepEqual(Object.keys(page.dlls), ['x86', 'wow64', 'x64', 'arm64']);
	for (const [arch, bytes] of Object.entries(page.dlls)) {
		assert.ok(Buffer.from(bytes).equals(Buffer.from(written[arch])), `${arch}: the tool's bytes`);
		assert.deepEqual(
			compareLayout(tool.model, readDll(bytes).layout),
			[],
			`${arch} reads back as its model`
		);
	}
	// The download: the four images and what the tables leave out.
	const archive = IO.windowsDllArchive(doc);
	assert.equal(archive.filename, `${page.dllName}-dll.zip`);
	const zipText = Buffer.from(archive.bytes).toString('latin1');
	for (const arch of Object.keys(page.dlls))
		assert.ok(
			zipText.includes(`${page.dllName}/${arch}/${page.dllName}.dll`),
			`${arch} in the ZIP`
		);
	assert.ok(zipText.includes(`${page.dllName}/omitted.json`));
	const x64At = Buffer.from(archive.bytes).indexOf(Buffer.from(page.dlls.x64));
	assert.ok(x64At > 0, 'the image is stored byte for byte');
	// composer_save on Windows carries every image, base64.
	const payload = IO.installPayload(doc, 'windows');
	assert.equal(payload.dll_name, page.dllName);
	for (const [arch, bytes] of Object.entries(page.dlls))
		assert.ok(
			Buffer.from(payload.dlls[arch], 'base64').equals(Buffer.from(bytes)),
			`${arch} base64`
		);
	assert.equal(IO.installPayload(doc, 'linux').dlls, undefined, 'only the Windows host gets DLLs');
	refuses(
		() => IO.windowsDlls(IO.importKeylayout(registry('ergopti'), 'e', 'iso')),
		'source_preserved'
	);
});

function LayoutSourceIO_preserved(doc) {
	return IO.isPreserved(doc);
}

let failed = 0;
for (const [name, fn] of tests) {
	try {
		fn();
		console.log(`ok - ${name}`);
	} catch (error) {
		failed++;
		console.error(`not ok - ${name}\n${error.stack}`);
	}
}
if (failed) {
	console.error(`${failed} of ${tests.length} layout editor model tests failed`);
	process.exit(1);
}
console.log(`ok - ${tests.length} layout editor model tests`);
