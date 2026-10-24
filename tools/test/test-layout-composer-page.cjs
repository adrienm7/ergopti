// tools/test/test-layout-composer-page.cjs

/**
 * ==============================================================================
 * MODULE: Layout Composer Page Gate
 * DESCRIPTION:
 * Runs the composer view of the shared layout manager page
 * (_shared/ui/layout_composer/composer_page.js, loaded by
 * _shared/ui/layout_manager/index.html) against a minimal DOM and drives it
 * through the host protocol every driver speaks: composerData in, the
 * allowlisted composer_* messages out, composerResult back.
 *
 * WHAT IS CHECKED:
 * 1. Opening: the composer replaces the layout list, shows four layer rows,
 *    the four shortcut rows, the level tabs and the board of the chosen form,
 *    and starts from a dormant default (the page never saves by itself).
 * 2. Editing: a dropdown or a key override changes the composed board and the
 *    declaration, and the saved message carries the declaration and a
 *    .keylayout the model reads back.
 * 3. Refusals: an invalid composition shows its problems and disables saving;
 *    a layout the model cannot read is listed with the reason; a system that
 *    cannot type the Ctrl/Alt/Win layers says so and disables their selects.
 * 4. Words: every string the composer shows exists in the page's string list
 *    and in the 21 locales with the same placeholders, and every problem code
 *    the model can emit has its own sentence.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SHARED = path.resolve(__dirname, '../../static/ergopti_plus/_shared');
const REGISTRY = path.resolve(__dirname, '../../static/layouts/registry');
const MANAGER = path.join(SHARED, 'ui/layout_manager');
const COMPOSER = path.join(SHARED, 'ui/layout_composer');
const LOCALE_DIR = path.join(SHARED, 'data/locales');
const LOCALES = [
	'ar',
	'cs',
	'da',
	'de',
	'en',
	'es',
	'fr',
	'he',
	'hi',
	'it',
	'ja',
	'ko',
	'nl',
	'no',
	'pl',
	'pt',
	'ru',
	'sv',
	'tr',
	'uk',
	'zh'
];

const read = (...parts) => fs.readFileSync(path.join(...parts), 'utf8');
const html = read(MANAGER, 'index.html');
const locale = (code) => JSON.parse(read(LOCALE_DIR, code + '.json').replace(/^﻿/, ''));
const indexJson = JSON.parse(read(REGISTRY, 'index.json'));

// ==============================
// ======= 1/ Minimal DOM =======
// ==============================

/** Builds a page with every id of index.html and runs the page scripts in it. */
function loadPage(storage) {
	const byId = new Map();
	const i18nElements = [];
	const messages = [];

	function makeElement(tag) {
		const classes = new Set();
		const listeners = {};
		const el = {
			tagName: tag.toUpperCase(),
			textContent: '',
			hidden: false,
			disabled: false,
			title: '',
			type: '',
			value: '',
			id: '',
			dataset: {},
			style: {},
			children: [],
			attributes: {},
			get className() {
				return [...classes].join(' ');
			},
			set className(value) {
				classes.clear();
				for (const name of String(value).split(/\s+/).filter(Boolean)) classes.add(name);
			},
			classList: {
				toggle(name, on) {
					if (on) classes.add(name);
					else classes.delete(name);
				},
				contains: (name) => classes.has(name)
			},
			get firstChild() {
				return el.children[0] || null;
			},
			appendChild(child) {
				el.children.push(child);
				return child;
			},
			removeChild(child) {
				el.children.splice(el.children.indexOf(child), 1);
				return child;
			},
			getAttribute: (name) => el.attributes[name],
			addEventListener(type, fn) {
				(listeners[type] = listeners[type] || []).push(fn);
			},
			fire(type) {
				for (const fn of listeners[type] || []) fn({ type, target: el });
			},
			click() {
				el.fire('click');
			}
		};
		return el;
	}

	for (const match of html.matchAll(/<(\w+)[^>]*?\bid="([^"]+)"[^>]*>/g)) {
		const el = makeElement(match[1]);
		el.id = match[2];
		el.hidden = /\bhidden\b/.test(match[0]);
		byId.set(match[2], el);
	}
	for (const match of html.matchAll(/<(\w+)[^>]*?data-i18n="([^"]+)"[^>]*>/gs)) {
		const id = /\bid="([^"]+)"/.exec(match[0]);
		const el = id ? byId.get(id[1]) : makeElement(match[1]);
		el.attributes['data-i18n'] = match[2];
		i18nElements.push(el);
	}
	byId.get('composer-form').value = 'iso';

	const document = {
		title: '',
		getElementById: (id) => byId.get(id) || null,
		createElement: makeElement,
		querySelectorAll: () => i18nElements
	};
	const window = {
		webkit: {
			messageHandlers: {
				layout_manager_bridge: { postMessage: (payload) => messages.push(payload) }
			}
		},
		localStorage: storage
	};
	const context = vm.createContext({
		window,
		document,
		console,
		setTimeout: (fn) => fn(),
		TextDecoder,
		atob: (text) => Buffer.from(text, 'base64').toString('binary')
	});
	const scripts = [
		path.join(SHARED, 'ui/host_bridge.js'),
		path.join(COMPOSER, '_generated/composer_data.js'),
		path.join(COMPOSER, 'reference_layouts.js'),
		path.join(COMPOSER, 'composer_model.js'),
		path.join(MANAGER, 'script.js'),
		path.join(COMPOSER, 'composer_page.js')
	];
	for (const file of scripts)
		vm.runInContext(fs.readFileSync(file, 'utf8'), context, { filename: file });
	return { context, byId, messages, window };
}

const plain = (value) => JSON.parse(JSON.stringify(value));
const textOf = (el) => [el.textContent, ...el.children.map(textOf)].join(' ');
function findAll(el, predicate, out = []) {
	for (const child of el.children) {
		if (predicate(child)) out.push(child);
		findAll(child, predicate, out);
	}
	return out;
}
const selects = (el) => findAll(el, (child) => child.tagName === 'SELECT');
function choose(select, value) {
	select.value = value;
	select.fire('change');
}

/** The sources a host sends: every registry layout, with its keycode convention. */
function hostSources() {
	return indexJson.layouts.map((entry) => ({
		id: entry.id,
		name: entry.name,
		convention: entry.keycode_convention,
		text: read(REGISTRY, entry.file)
	}));
}

// The smallest state the Windows host sends: no catalogue yet.
const WINDOWS_STATE = { platform: 'windows', shortcut_menu_path: 'shortcuts/menu.ahk' };

/** A page opened on the real registry, with the English strings. */
function openPage(extra = {}) {
	const loaded = loadPage(extra.storage);
	loaded.window.initData({ strings: locale('en'), state: WINDOWS_STATE });
	loaded.window.composerData(
		Object.assign(
			{
				platform: 'windows',
				sources: hostSources(),
				declaration: null,
				active: false,
				shortcuts: 'full'
			},
			extra.data || {}
		)
	);
	return loaded;
}

const keyCap = (loaded, code) =>
	findAll(loaded.byId.get('composer-board'), (el) => el.dataset.code === code)[0];

let failures = 0;
let passes = 0;
function check(name, fn) {
	try {
		fn();
		passes += 1;
		console.log(`  ok   ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${String(err.message).split('\n').join('\n       ')}`);
	}
}

console.log('Layout composer page');

// ==========================
// ======= 2/ Opening =======
// ==========================

check('the composer opens over the layout list from the host sources', () => {
	const loaded = openPage();
	assert.equal(loaded.byId.get('composer').hidden, false);
	assert.equal(loaded.byId.get('layout-view').hidden, true);
	const layerRows = loaded.byId.get('composer-layers').children;
	assert.equal(layerRows.length, 4, 'one row per layer');
	for (const row of layerRows)
		assert.equal(selects(row).length, 2, 'a layout and a layer dropdown');
	const sourceSelect = selects(layerRows[0])[0];
	const ids = sourceSelect.children.map((option) => option.value);
	assert.ok(
		['qwerty', 'azerty', 'ergopti', 'ergol'].every((id) => ids.includes(id)),
		ids.join()
	);
	assert.equal(loaded.byId.get('composer-shortcuts').children.length, 4, 'default, Win, Ctrl, Alt');
	assert.equal(loaded.byId.get('composer-tabs').children.length, 8);
	assert.ok(loaded.byId.get('composer-board').children.length >= 48, 'the board draws the keys');
	assert.equal(
		loaded.messages.filter((m) => m.action !== 'ready').length,
		0,
		'opening saves nothing'
	);
	assert.equal(loaded.byId.get('composer-save').disabled, false);
});

check('the open button asks the host for the sources', () => {
	const loaded = loadPage();
	loaded.window.initData({ strings: locale('en'), state: WINDOWS_STATE });
	loaded.byId.get('btn-compose').click();
	assert.deepEqual(plain(loaded.messages.at(-1)), { action: 'composer_open' });
});

// =========================
// ======= 3/ Editing ======
// =========================

check('a layer dropdown changes the composed board and the saved declaration', () => {
	const loaded = openPage();
	const layerRows = loaded.byId.get('composer-layers').children;
	choose(selects(layerRows[0])[0], 'qwerty');
	assert.equal(keyCap(loaded, 'KeyQ').textContent, 'q');
	choose(selects(loaded.byId.get('composer-layers').children[1])[0], 'azerty');
	loaded.byId.get('composer-tabs').children[1].click();
	assert.equal(keyCap(loaded, 'KeyQ').textContent, 'A', 'Shift level of the AZERTY layer');

	loaded.byId.get('composer-save-use').click();
	const sent = plain(loaded.messages.at(-1));
	assert.equal(sent.action, 'composer_save');
	assert.equal(sent.use, true);
	const declaration = JSON.parse(sent.declaration);
	assert.equal(declaration.layers.base.source, 'qwerty');
	assert.equal(declaration.layers.shift.source, 'azerty');
	assert.match(sent.keylayout, /^<\?xml version="1\.1"/);
	const model = loaded.context.LayoutComposer.parseModel(sent.keylayout);
	assert.equal(model.mapSet, 'composed');
});

check('a key override is drawn, marked and saved', () => {
	const loaded = openPage();
	keyCap(loaded, 'KeyQ').click();
	const editor = loaded.byId.get('composer-key-editor');
	assert.equal(editor.hidden, false);
	choose(selects(editor)[0], 'text');
	const input = findAll(editor, (el) => el.id === 'composer-key-text')[0];
	input.value = 'x';
	input.fire('input');
	findAll(editor, (el) => el.id === 'composer-key-apply')[0].click();
	assert.equal(keyCap(loaded, 'KeyQ').textContent, 'x');
	assert.ok(keyCap(loaded, 'KeyQ').classList.contains('is-overridden'));
	loaded.byId.get('composer-save').click();
	const sent = plain(loaded.messages.at(-1));
	assert.equal(JSON.parse(sent.declaration).overrides.base.KeyQ, 'x');
	assert.equal(sent.use, false);

	keyCap(loaded, 'KeyQ').click();
	choose(selects(loaded.byId.get('composer-key-editor'))[0], 'layer');
	findAll(
		loaded.byId.get('composer-key-editor'),
		(el) => el.id === 'composer-key-apply'
	)[0].click();
	assert.ok(!keyCap(loaded, 'KeyQ').classList.contains('is-overridden'), 'back to the layer');
});

check('a dead key is marked and shows its own character', () => {
	const loaded = openPage();
	choose(selects(loaded.byId.get('composer-layers').children[0])[0], 'azerty');
	assert.ok(keyCap(loaded, 'BracketLeft').classList.contains('is-dead'));
	assert.equal(keyCap(loaded, 'BracketLeft').textContent, '^');
});

check('the keyboard form follows the declaration and is remembered', () => {
	const store = {};
	const loaded = openPage({
		storage: { getItem: (k) => store[k] ?? null, setItem: (k, v) => (store[k] = v) }
	});
	const form = loaded.byId.get('composer-form');
	form.value = 'ansi';
	form.fire('change');
	assert.equal(store['layout_composer.form'], 'ansi');
	assert.equal(keyCap(loaded, 'IntlBackslash'), undefined, 'the ISO-only key is not drawn on ANSI');
	loaded.byId.get('composer-save').click();
	assert.equal(JSON.parse(loaded.messages.at(-1).declaration).keycode_convention, 'ansi');
});

// ===========================
// ======= 4/ Refusals =======
// ===========================

check('a stored composition naming a missing layout shows its problem and cannot be saved', () => {
	const stored = {
		schema_version: 1,
		name: 'Old',
		keycode_convention: 'iso',
		layers: { base: { source: 'gone' } }
	};
	const loaded = openPage({ data: { declaration: JSON.stringify(stored) } });
	const problems = loaded.byId.get('composer-problems');
	assert.equal(problems.hidden, false);
	assert.match(textOf(problems), /not available here/);
	assert.equal(loaded.byId.get('composer-save').disabled, true);
	assert.equal(loaded.byId.get('composer-save-use').disabled, true);
});

check('a layout the model cannot read is listed with the reason', () => {
	const sources = hostSources();
	sources.push({ id: 'broken', name: 'Broken', convention: 'iso', text: '<keyboard></keyboard>' });
	const loaded = openPage({ data: { sources } });
	assert.match(textOf(loaded.byId.get('composer-problems')), /broken cannot be used as a source/);
	const ids = selects(loaded.byId.get('composer-layers').children[0])[0].children.map(
		(o) => o.value
	);
	assert.ok(!ids.includes('broken'));
});

check('a system with one shortcuts layer says so and locks the per-modifier rows', () => {
	const loaded = openPage({ data: { platform: 'linux', shortcuts: 'single' } });
	assert.equal(loaded.byId.get('composer-shortcuts-note').hidden, false);
	const rows = loaded.byId.get('composer-shortcuts').children;
	assert.equal(selects(rows[0])[0].disabled, false, 'the default entry stays editable');
	for (const row of rows.slice(1))
		for (const select of selects(row)) assert.equal(select.disabled, true);
	const supported = openPage();
	assert.equal(supported.byId.get('composer-shortcuts-note').hidden, true);
});

check('host results are worded, and a failure code gets its own sentence', () => {
	const loaded = openPage();
	loaded.window.composerResult({ action: 'composer_save', ok: true, used: true });
	assert.equal(
		loaded.byId.get('composer-result').textContent,
		locale('en')['layout_composer.result_saved_used']
	);
	assert.equal(loaded.byId.get('composer-active').hidden, false);
	loaded.window.composerResult({ action: 'composer_remove', ok: true });
	assert.equal(
		loaded.byId.get('composer-result').textContent,
		locale('en')['layout_composer.result_removed']
	);
	assert.equal(loaded.byId.get('composer-active').hidden, true);
	loaded.window.composerResult({
		action: 'composer_save',
		ok: false,
		code: 'invalid',
		detail: 'x'
	});
	assert.match(loaded.byId.get('composer-result').textContent, /refused the generated layout/);
	assert.ok(loaded.byId.get('composer-result').classList.contains('is-error'));
	loaded.window.composerResult({ action: 'composer_save', ok: false, code: 'never_heard_of_it' });
	assert.match(loaded.byId.get('composer-result').textContent, /Unexpected error/);
});

check('booleans sent as 1 by the AutoHotkey host read as true', () => {
	const loaded = openPage({ data: { active: 1 } });
	assert.equal(loaded.byId.get('composer-active').hidden, false);
	loaded.window.composerResult({ action: 'composer_save', ok: 1, used: 0 });
	assert.equal(
		loaded.byId.get('composer-result').textContent,
		locale('en')['layout_composer.result_saved']
	);
	assert.equal(loaded.byId.get('composer-active').hidden, true, 'saved without using it');
});

check('a stored composition that is not JSON is reported, never replaced silently', () => {
	const loaded = openPage({ data: { declaration: '{ not json' } });
	assert.equal(loaded.byId.get('composer-problems').hidden, false);
	assert.match(textOf(loaded.byId.get('composer-problems')), /not readable/);
});

check('only allowlisted composer messages are ever posted', () => {
	const loaded = openPage();
	for (const action of ['composer_open', 'composer_save', 'composer_remove'])
		assert.ok(vm.runInContext('LAYOUT_MANAGER_ACTIONS', loaded.context).includes(action), action);
	assert.throws(() => loaded.context.send('composer_wipe'), /unknown action/);
});

// ==========================
// ======= 5/ Words =========
// ==========================

check('every composer string exists in the page list and in the 21 locales', () => {
	const used = new Set();
	for (const file of [path.join(COMPOSER, 'composer_page.js'), path.join(MANAGER, 'index.html')])
		for (const match of read(file).matchAll(/layout_composer\.[a-z_]+/g)) used.add(match[0]);
	// Keys the page builds from a code.
	const built = [];
	for (const level of [
		'base',
		'shift',
		'altgr',
		'shift_altgr',
		'caps',
		'meta',
		'ctrl',
		'alt',
		'command'
	])
		built.push('layout_composer.level_' + level);
	for (const code of ['invalid', 'write_failed', 'use_failed', 'busy', 'unsupported', 'other'])
		built.push('layout_composer.failure_' + code);
	const emitted = new Set([
		'declaration_invalid',
		'schema_version',
		'name_invalid',
		'convention_invalid',
		'layers_invalid',
		'base_missing',
		'base_empty',
		'unknown_layer',
		'unknown_source',
		'spec_invalid',
		'shortcuts_invalid',
		'unknown_shortcut',
		'overrides_invalid',
		'unknown_target',
		'unknown_key',
		'output_invalid',
		'override_invalid',
		'ambiguous_composition'
	]);
	// The model must not emit a code this list lacks.
	const model = read(COMPOSER, 'composer_model.js');
	for (const match of model.matchAll(/problem\('([a-z_]+)'/g))
		assert.ok(emitted.has(match[1]), `the model emits ${match[1]}, which has no sentence`);
	for (const code of emitted) built.push('layout_composer.problem_' + code);
	const STORAGE_KEYS = new Set(['layout_composer.form']);
	const keys = new Set(
		[...used, ...built].filter((key) => !key.endsWith('_') && !STORAGE_KEYS.has(key))
	);
	const listed = new Set(JSON.parse(read(MANAGER, 'strings.json')).keys);
	const english = locale('en');
	for (const key of keys) {
		assert.ok(listed.has(key), `${key} is missing from strings.json`);
		const placeholders = (english[key].match(/%s/g) || []).length;
		for (const code of LOCALES) {
			const value = locale(code)[key];
			assert.equal(typeof value, 'string', `${code} lacks ${key}`);
			assert.equal((value.match(/%s/g) || []).length, placeholders, `${code} ${key} placeholders`);
		}
	}
	for (const key of listed)
		if (key.startsWith('layout_composer.'))
			assert.ok(keys.has(key), `${key} is listed but the page does not use it`);
	assert.ok(keys.size > 50, 'the string floor');
});

if (failures > 0) {
	console.error(`\n${failures} failed, ${passes} passed`);
	process.exit(1);
}
console.log(`\n${passes} passed`);
