// tools/test/test-studio-edit-history.cjs

/**
 * ==============================================================================
 * MODULE: Studio Edit History Gate
 * DESCRIPTION:
 * _shared/ui/edit_history.js is the undo and redo history of every Ergopti
 * Studio page (maintainer, 2026-11-21). This gate runs it in a VM, as the
 * pages load it.
 *
 * WHAT IS CHECKED:
 * 1. Sequence: undo and redo walk the steps in order and name them; a new
 *    edit after an undo clears the redo steps (branching).
 * 2. Bound: the history keeps HISTORY_LIMIT steps, the oldest dropped first,
 *    and HISTORY_LIMIT is the registry's [ui] studio_history_steps.
 * 3. Fail fast: nothing to undo or redo, a nameless step, an edit recorded
 *    while a step is taken back, and a page that does not take back the state
 *    it was given all throw.
 * 4. Tracker: a page's settings are recorded only when they change, named by
 *    the page or by the label set for a restore or an import, and put back on
 *    undo and redo.
 * 5. Shortcuts: Ctrl or Cmd with Z undoes, with Y or Shift+Z redoes, by the
 *    character typed; Alt chords and text fields are left alone.
 * 6. Names: the buttons say what they would take back, through the
 *    edit_history.* keys, which exist in all 21 locales with English's
 *    placeholders, every step name too.
 * 7. Pages: the editor, the Comparer, the Optimiser and the app's editor
 *    window load the history before the page scripts that use it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const toml = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const UI = shared('ui');
const LOCALES_DIR = shared('core', 'i18n', 'data', 'locales');
const REGISTRY = shared('core', 'timing', 'data', 'constants.toml');
// The Studio scripts that name history steps (the step keys they hold).
const STEP_SOURCES = [
	'layout_editor/editor_page.js',
	'layout_analysis/comparer_page.js',
	'layout_optimizer/optimizer_page.js',
	'edit_history.js'
];
// Each page and the script that uses the history after it is loaded.
const PAGES = {
	'layout_editor/index.html': 'editor_model.js',
	'layout_editor_window/index.html': '../layout_editor/editor_model.js',
	'layout_analysis/index.html': 'comparer_page.js',
	'layout_optimizer/index.html': 'optimizer_page.js'
};
// Floor: a scan that lost the step names must not read as complete.
const MIN_STEP_KEYS = 25;

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

/** Loads edit_history.js in a VM, with a document stub for the controls. */
function load() {
	const context = vm.createContext({});
	vm.runInContext(fs.readFileSync(path.join(UI, 'edit_history.js'), 'utf8'), context, {
		filename: 'edit_history.js'
	});
	return vm.runInContext('ERGOPTI_EDIT_HISTORY', context);
}

const H = load();
const step = (key, values) => (values ? { key, values } : { key });
const NAME = step('edit_history.step.change_key', { key: 'A' });

test('undo and redo walk the steps in order and name them', () => {
	const history = H.create('s0');
	assert.equal(history.canUndo(), false);
	history.push('s1', step('edit_history.step.change_key', { key: 'A' }));
	history.push('s2', step('edit_history.step.rename'));
	assert.equal(history.undoLabel().key, 'edit_history.step.rename');
	assert.equal(history.undo(), 's1');
	assert.equal(history.undoLabel().values.key, 'A');
	assert.equal(history.redoLabel().key, 'edit_history.step.rename');
	assert.equal(history.undo(), 's0');
	assert.equal(history.canUndo(), false);
	assert.equal(history.undoLabel(), null);
	assert.equal(history.redo(), 's1');
	assert.equal(history.redo(), 's2');
	assert.equal(history.canRedo(), false);
	assert.equal(history.redoLabel(), null);
});

test('a new edit after an undo clears the redo steps', () => {
	const history = H.create('s0');
	history.push('s1', NAME);
	history.push('s2', NAME);
	history.undo();
	history.undo();
	history.push('b1', NAME);
	assert.equal(history.canRedo(), false, 'the branch left behind cannot be redone');
	assert.equal(history.current(), 'b1');
	assert.equal(history.undo(), 's0');
	assert.equal(history.redo(), 'b1');
	assert.equal(history.size(), 1);
});

test('the history is bounded by the registry limit, the oldest step dropped first', () => {
	const registry = toml.parse(fs.readFileSync(REGISTRY, 'utf8'));
	assert.equal(
		H.HISTORY_LIMIT,
		registry.ui.studio_history_steps,
		'HISTORY_LIMIT follows the registry'
	);
	const history = H.create(0);
	for (let i = 1; i <= H.HISTORY_LIMIT + 5; i += 1) history.push(i, NAME);
	assert.equal(history.size(), H.HISTORY_LIMIT);
	let undone = 0;
	while (history.canUndo()) {
		history.undo();
		undone += 1;
	}
	assert.equal(undone, H.HISTORY_LIMIT);
	assert.equal(history.current(), 5, 'the five oldest steps were dropped');
	const small = H.create('a', { limit: 2 });
	small.push('b', NAME);
	small.push('c', NAME);
	small.push('d', NAME);
	assert.equal(small.size(), 2);
	assert.throws(() => H.create('a', { limit: 0 }), /positive integer/);
});

test('an inconsistent use fails fast', () => {
	const history = H.create('s0');
	assert.throws(() => history.undo(), /nothing to undo/);
	assert.throws(() => history.redo(), /nothing to redo/);
	assert.throws(() => history.push('s1'), /locale key/);
	assert.throws(() => history.push('s1', { key: 'not a key' }), /locale key/);
	assert.throws(() => history.push('s1', NAME, { undo() {} }), /undo and redo/);
	// A side effect that records an edit while its step is taken back.
	history.push('s1', NAME, {
		undo: () => history.push('nested', NAME),
		redo() {}
	});
	assert.throws(() => history.undo(), /being taken back/);
});

test('a side effect runs with its step on undo and redo', () => {
	const log = [];
	const history = H.create('doc');
	history.push('doc', step('edit_history.step.fingering'), {
		undo: () => log.push('undo'),
		redo: () => log.push('redo')
	});
	history.undo();
	history.redo();
	assert.deepEqual(log, ['undo', 'redo']);
});

test('a tracked page records changes only, named by itself or by the label set', () => {
	const page = { weights: 1, corpus: 'fr' };
	let changes = 0;
	const tracker = H.track({
		capture: () => ({ weights: page.weights, corpus: page.corpus }),
		apply: (state) => Object.assign(page, state),
		describe: (before, after) =>
			before.corpus !== after.corpus
				? step('edit_history.step.corpus')
				: step('edit_history.step.weights'),
		onChange: () => (changes += 1)
	});
	assert.throws(() => tracker.record(), /not started/);
	tracker.start();
	assert.throws(() => tracker.start(), /already started/);
	assert.equal(tracker.record(), false, 'an unchanged page is no step');
	page.weights = 2;
	assert.equal(tracker.record(), true);
	assert.equal(tracker.undoLabel().key, 'edit_history.step.weights');
	page.corpus = 'en';
	tracker.record();
	assert.equal(tracker.undoLabel().key, 'edit_history.step.corpus');
	tracker.label(step('edit_history.step.restore', { name: 'weights' }));
	page.weights = 1;
	tracker.record();
	assert.equal(tracker.undoLabel().key, 'edit_history.step.restore', 'a restore names its step');
	tracker.undo();
	assert.deepEqual(page, { weights: 2, corpus: 'en' });
	tracker.undo();
	tracker.undo();
	assert.deepEqual(page, { weights: 1, corpus: 'fr' });
	tracker.redo();
	assert.deepEqual(page, { weights: 2, corpus: 'fr' });
	page.corpus = 'code';
	tracker.record();
	assert.equal(tracker.canRedo(), false, 'branching clears the redo steps');
	assert.ok(changes >= 8, 'the page hears every step, undo and redo');
});

test('a tracked page that does not take back its state fails fast', () => {
	const page = { value: 1 };
	const tracker = H.track({
		capture: () => ({ value: page.value }),
		apply: () => {},
		describe: () => step('edit_history.step.settings')
	});
	tracker.start();
	page.value = 2;
	tracker.record();
	assert.throws(() => tracker.undo(), /did not take back/);
});

test('saves made while a state is put back are not steps', () => {
	const page = { value: 1 };
	let tracker = null;
	tracker = H.track({
		capture: () => ({ value: page.value }),
		apply: (state) => {
			page.value = state.value;
			assert.equal(tracker.record(), false);
		},
		describe: () => step('edit_history.step.settings')
	});
	tracker.start();
	page.value = 2;
	tracker.record();
	tracker.undo();
	assert.equal(tracker.size(), 1);
	assert.equal(tracker.canRedo(), true);
});

test('the shortcuts follow the character typed, with Ctrl or Cmd', () => {
	const press = (key, mods) =>
		Object.assign({ key, ctrlKey: false, metaKey: false, shiftKey: false, altKey: false }, mods);
	assert.equal(H.action(press('z', { ctrlKey: true })), 'undo');
	assert.equal(H.action(press('z', { metaKey: true })), 'undo', 'Cmd+Z on macOS');
	assert.equal(H.action(press('y', { ctrlKey: true })), 'redo');
	assert.equal(H.action(press('Y', { metaKey: true })), 'redo');
	assert.equal(H.action(press('Z', { ctrlKey: true, shiftKey: true })), 'redo');
	assert.equal(
		H.action(press('Z', { metaKey: true, shiftKey: true })),
		'redo',
		'Cmd+Shift+Z on macOS'
	);
	assert.equal(H.action(press('y', { ctrlKey: true, shiftKey: true })), null);
	assert.equal(H.action(press('z', { ctrlKey: true, altKey: true })), null, 'AltGr chords type');
	assert.equal(H.action(press('z', {})), null);
	assert.equal(H.SHORTCUTS.undo, 'Control+Z Meta+Z');
	const field = (tagName, type) => ({ nodeType: 1, tagName, type, isContentEditable: false });
	assert.equal(H.inTextField(field('INPUT', 'text')), true);
	assert.equal(H.inTextField(field('TEXTAREA')), true);
	assert.equal(H.inTextField(field('INPUT', 'checkbox')), false);
	assert.equal(H.inTextField(field('BUTTON')), false);
});

test('the buttons say what they would take back, in all 21 locales', () => {
	const order = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locale_order.json'), 'utf8')
	).order;
	const catalogues = Object.fromEntries(
		order.map((lang) => [
			lang,
			JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, `${lang}.json`), 'utf8'))
		])
	);
	assert.equal(order.length, 21);
	const t = (key, values) =>
		String(catalogues.en[key]).replace(/\{(\w+)\}/g, (_, name) => String(values[name]));
	assert.equal(
		H.buttonName(t, 'undo', step('edit_history.step.change_key', { key: 'A' })),
		'Undo: change key A'
	);
	assert.equal(
		H.buttonName(t, 'redo', step('edit_history.step.rename')),
		'Redo: rename the layout'
	);
	assert.equal(H.buttonName(t, 'undo', null), 'Undo');
	assert.throws(() => H.buttonName(t, 'again', null), /no again button/);
	const keys = new Set(['edit_history.group', 'edit_history.undo', 'edit_history.redo']);
	for (const name of ['undo_step', 'redo_step', 'undone', 'redone'])
		keys.add(`edit_history.${name}`);
	for (const file of STEP_SOURCES)
		for (const m of fs
			.readFileSync(path.join(UI, file), 'utf8')
			.matchAll(/'(edit_history\.step\.[a-z_]+)'/g))
			keys.add(m[1]);
	assert.ok(keys.size >= MIN_STEP_KEYS, `only ${keys.size} history keys were found`);
	const placeholders = (text) => [...String(text).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
	for (const key of keys)
		for (const lang of order) {
			const text = catalogues[lang][key];
			assert.equal(typeof text, 'string', `${lang}.json lacks ${key}`);
			assert.ok(text.trim() !== '', `${lang}.json has an empty ${key}`);
			assert.deepEqual(
				placeholders(text),
				placeholders(catalogues.en[key]),
				`${lang}.json ${key} placeholders`
			);
		}
});

test('every Studio page loads the history before the script that uses it', () => {
	for (const [page, user] of Object.entries(PAGES)) {
		const html = fs.readFileSync(path.join(UI, page), 'utf8');
		const scripts = [...html.matchAll(/<script src="([^"]+)"/g)].map((m) => m[1]);
		const history = scripts.findIndex((src) => src.endsWith('/edit_history.js'));
		assert.ok(history >= 0, `${page} does not load edit_history.js`);
		assert.ok(history < scripts.indexOf(user), `${page} loads edit_history.js after ${user}`);
	}
});

let failed = 0;
for (const [name, fn] of tests) {
	try {
		fn();
		console.log(`ok - ${name}`);
	} catch (error) {
		failed += 1;
		console.error(`not ok - ${name}\n${error.stack}`);
	}
}
if (failed) {
	console.error(`FAIL test-studio-edit-history (${failed} of ${tests.length})`);
	process.exit(1);
}
console.log(`PASS test-studio-edit-history (${tests.length} tests)`);
