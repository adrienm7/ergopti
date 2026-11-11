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
	'layout_composer/source_model.js',
	'layout_composer/source_compiler.js',
	'layout_editor/_generated/key_tables.js',
	'layout_editor/toml_prelude.js',
	'vendor/smol-toml.js',
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
	const context = vm.createContext({});
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
		'({ IO: LayoutSourceIO, M: LayoutEditorModel, LayerModel, LayoutComposer, DATA: LAYER_EDITOR_DATA, COMPOSER: LAYOUT_COMPOSER_DATA })',
		context
	);
}

const { IO, M, LayerModel, LayoutComposer, DATA, COMPOSER } = loadEditor();
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
	doc = M.setModifier(doc, 'kana', 'locked', ['ScrollLock']);
	doc = M.addLayer(doc, 'kana', ['kana'], ['shift']);
	refuses(() => M.removeModifier(doc, 'kana'), 'modifier_in_use');
	refuses(() => M.removeLayer(doc, 'base'), 'layer_base_required');
	doc = M.setTapHold(doc, {
		key: 'CapsLock',
		tap: { key: 'Escape' },
		hold_layer: 'kana',
		threshold_ms: 180
	});
	refuses(() => M.removeLayer(doc, 'kana'), 'layer_in_use');
	doc = M.removeTapHold(doc, 'CapsLock');
	doc = M.removeLayer(doc, 'kana');
	doc = M.removeModifier(doc, 'kana');
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
	}
	refuses(() => IO.convertImport(IO.create('a', 'A')), 'source_not_imported');
});

test('a preserved import installs and exports its own XML, only in its own variant', () => {
	const xml = registry('ergopti');
	const doc = IO.importKeylayout(xml, 'ergopti', 'iso');
	assert.equal(IO.installPayload(doc, 'macos').keylayout, xml);
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
	const recommended = fs.readFileSync(shared('keymap', 'layers.recommended.toml'), 'utf8');
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
