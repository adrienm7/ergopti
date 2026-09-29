// tools/test/test-layout-manager-page.cjs

/**
 * ==============================================================================
 * MODULE: Layout Manager Page Regression
 * DESCRIPTION:
 * Executes the shared layout manager page (_shared/ui/layout_manager) against
 * a minimal DOM and drives it through the host protocol every driver speaks.
 * Pins what the page decides for all three drivers: the status of each
 * registry layout (available, installed, update, built in, provided by a
 * bundle, removed from the registry), the buttons each status offers, the
 * catalogue line with its error, the result line, the busy state, and that
 * the page only ever posts the allowlisted actions. Every string it shows
 * must exist in every locale.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SHARED = path.resolve(__dirname, '../../static/ergopti_plus/_shared');
const PAGE = path.join(SHARED, 'ui/layout_manager');
const source = fs.readFileSync(path.join(PAGE, 'script.js'), 'utf8');
const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
const hostBridge = fs.readFileSync(path.join(SHARED, 'ui/host_bridge.js'), 'utf8');
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

/**
 * Reads one locale file as a flat key -> string map.
 * @param {string} code
 * @returns {Object<string, string>}
 */
function locale(code) {
	return JSON.parse(
		fs.readFileSync(path.join(LOCALE_DIR, code + '.json'), 'utf8').replace(/^\uFEFF/, '')
	);
}

// ==============================
// ==============================
// ======= 1/ Minimal DOM =======
// ==============================
// ==============================

/**
 * Builds a fresh page with every id declared in index.html.
 * @returns {{context: object, byId: Map, messages: Array}}
 */
function loadPage() {
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
			dataset: {},
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
			click() {
				for (const fn of listeners.click || []) fn({ type: 'click' });
			}
		};
		return el;
	}

	for (const match of html.matchAll(/<(\w+)[^>]*?\bid="([^"]+)"[^>]*>/g)) {
		byId.set(match[2], makeElement(match[1]));
	}
	for (const match of html.matchAll(/<(\w+)[^>]*?data-i18n="([^"]+)"[^>]*>/gs)) {
		const id = /\bid="([^"]+)"/.exec(match[0]);
		const el = id ? byId.get(id[1]) : makeElement(match[1]);
		el.attributes['data-i18n'] = match[2];
		i18nElements.push(el);
	}

	const document = {
		title: '',
		getElementById: (id) => byId.get(id) || null,
		createElement: makeElement,
		querySelectorAll: (selector) => {
			assert.equal(selector, '[data-i18n]');
			return i18nElements;
		}
	};
	const window = {
		webkit: {
			messageHandlers: {
				layout_manager_bridge: { postMessage: (payload) => messages.push(payload) }
			}
		}
	};
	const context = vm.createContext({
		window,
		document,
		console,
		setTimeout: (fn) => fn(),
		TextDecoder,
		atob: (text) => Buffer.from(text, 'base64').toString('binary')
	});
	vm.runInContext(hostBridge, context, { filename: 'host_bridge.js' });
	vm.runInContext(source, context, { filename: 'script.js' });
	return { context, byId, messages, window };
}

/** A copy of a value made in the page realm, comparable with plain objects. */
function plain(value) {
	return JSON.parse(JSON.stringify(value));
}

/** Collects the text of an element tree. */
function textOf(el) {
	return [el.textContent, ...el.children.map(textOf)].join(' ');
}

/** Finds every descendant matching a predicate. */
function findAll(el, predicate, out = []) {
	for (const child of el.children) {
		if (predicate(child)) out.push(child);
		findAll(child, predicate, out);
	}
	return out;
}

const index = {
	layouts: [
		{
			id: 'ergopti',
			name: 'Ergopti',
			family: 'ergopti',
			version: '2.2.2',
			sha256: 'a',
			author: 'Adrien Moyaux',
			licence: 'MIT',
			homepage: 'https://ergopti.fr',
			platforms: ['linux', 'macos', 'windows']
		},
		{
			id: 'ergol',
			name: 'Ergo-L',
			family: 'ergol',
			version: '1.0.2',
			sha256: 'b',
			author: 'NuclearSquid',
			licence: 'WTFPL',
			homepage: 'https://ergol.org',
			platforms: ['linux', 'macos', 'windows']
		},
		{
			id: 'fresh',
			name: 'Fresh',
			family: 'fresh',
			version: '3.0.0',
			sha256: 'c',
			author: 'Someone',
			licence: 'MIT',
			homepage: 'https://example.org',
			platforms: ['linux', 'macos', 'windows']
		},
		{
			id: 'maconly',
			name: 'Mac only',
			family: 'mac',
			version: '1.0.0',
			sha256: 'd',
			author: 'Someone',
			licence: 'MIT',
			homepage: 'http://insecure.example.org',
			platforms: ['macos']
		}
	]
};

const strings = locale('en');
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

console.log('Layout manager page');

// =======================
// =======================
// ======= 2/ Rows =======
// =======================
// =======================

check('every status is decided from the host state, per platform', () => {
	const { context } = loadPage();
	const rows = context.layoutRows({
		platform: 'windows',
		index,
		installed: {
			ergol: { id: 'ergol', name: 'Ergo-L', version: '1.0.1', sha256: 'old' },
			fresh: { id: 'fresh', name: 'Fresh', version: '3.0.0', sha256: 'c' },
			gone: { id: 'gone', name: 'Gone', version: '0.1.0', sha256: 'e' }
		},
		builtin: { ergopti: true },
		active: 'fresh'
	});
	const byId = Object.fromEntries(rows.map((row) => [row.id, row]));
	assert.deepEqual(
		[...rows].map((row) => row.id),
		['ergopti', 'ergol', 'fresh', 'gone'],
		'maconly is not published for windows'
	);
	assert.equal(byId.ergopti.status, 'builtin');
	assert.deepEqual([...byId.ergopti.actions], ['select']);
	assert.equal(byId.ergol.status, 'update');
	assert.deepEqual([...byId.ergol.actions], ['update', 'select', 'uninstall']);
	assert.equal(byId.ergol.installedVersion, '1.0.1');
	assert.equal(byId.fresh.status, 'installed');
	assert.equal(byId.fresh.active, true);
	assert.deepEqual(
		[...byId.fresh.actions],
		['uninstall'],
		'the active layout is not offered again'
	);
	assert.equal(byId.gone.removed, true, 'an installed layout the registry dropped stays listed');
	assert.deepEqual([...byId.gone.actions], ['select', 'uninstall']);

	const mac = context.layoutRows({
		platform: 'macos',
		index,
		installed: {},
		provided: { ergopti: 'bundle' }
	});
	const macById = Object.fromEntries(mac.map((row) => [row.id, row]));
	assert.equal(macById.ergopti.status, 'provided');
	assert.deepEqual([...macById.ergopti.actions], [], 'a bundle-provided layout offers no action');
	assert.equal(macById.ergol.status, 'available');
	assert.deepEqual([...macById.ergol.actions], ['install']);
	assert.equal(macById.maconly.homepage, '', 'only an https homepage is offered');
	assert.deepEqual([...context.layoutRows(null)], []);
});

// ========================================
// ========================================
// ======= 3/ Rendering and actions =======
// ========================================
// ========================================

check('extension updates remain visible when the layout bytes did not change', () => {
	const { context } = loadPage();
	const entry = { ...index.layouts[1], extension: { sha256: 'new-content', files: [] } };
	const rows = context.layoutRows({
		platform: 'windows',
		index: { layouts: [entry] },
		installed: { ergol: { ...entry, extension: { sha256: 'old-content', files: [] } } }
	});
	assert.equal(rows[0].status, 'update');
	assert.ok(rows[0].actions.includes('update'));
});

check(
	'optional content is counted for the host and never presented as automatically enabled',
	() => {
		for (const platform of ['windows', 'macos', 'linux']) {
			const { byId, messages, window } = loadPage();
			const entry = {
				...index.layouts[1],
				extension: {
					sha256: 'payload',
					files: [
						{ path: 'ergol.keylayout' },
						{ path: 'manifest.toml' },
						{ path: 'hotstrings/rolls.toml' },
						{ path: 'hotstrings/sfbs.toml' },
						{ path: 'shortcuts/menu.ahk' },
						{ path: 'shortcuts/menu.lua' }
					]
				}
			};
			window.initData({ strings, state: { platform, index: { layouts: [entry] }, installed: {} } });
			const text = textOf(byId.get('layout-list'));
			assert.ok(
				text.includes(
					strings['layout_manager.extension_content'].replace('%s', '2').replace('%s', '1')
				)
			);
			assert.ok(text.includes(strings['layout_manager.extension_opt_in']));
			assert.deepEqual(plain(messages), [{ action: 'ready' }]);
		}
	}
);

check('the page renders the rows and posts the action of each button', () => {
	const { context, byId, messages, window } = loadPage();
	assert.deepEqual(plain(messages), [{ action: 'ready' }], 'the page announces itself');
	window.initData({
		strings,
		state: { platform: 'linux', index, source: 'network', error: null, installed: {}, active: '' }
	});
	const list = byId.get('layout-list');
	assert.equal(list.children.length, 3);
	assert.ok(textOf(list).includes(strings['layout_manager.status_available']));
	assert.ok(
		textOf(list).includes(strings['layout_manager.meta_author'].replace('%s', 'Adrien Moyaux'))
	);
	assert.equal(byId.get('catalogue-status').textContent, strings['layout_manager.source_network']);
	assert.equal(byId.get('empty').hidden, true);

	const install = findAll(list, (el) => el.dataset.action === 'install')[1];
	install.click();
	assert.deepEqual(plain(messages[messages.length - 1]), { action: 'install', id: 'ergol' });
	const homepage = findAll(list, (el) => el.dataset.action === 'open_homepage')[0];
	homepage.click();
	assert.deepEqual(plain(messages[messages.length - 1]), {
		action: 'open_homepage',
		id: 'ergopti'
	});
	byId.get('btn-refresh').click();
	assert.deepEqual(plain(messages[messages.length - 1]), { action: 'refresh' });
	byId.get('btn-close').click();
	assert.deepEqual(plain(messages[messages.length - 1]), { action: 'close' });
	assert.throws(() => context.send('delete_everything'), /unknown action/);
});

check('an operation in flight disables every button and says what runs', () => {
	const { byId, window } = loadPage();
	window.initData({
		strings,
		state: {
			platform: 'linux',
			index,
			source: 'cache',
			installed: {},
			busy: { id: 'ergol', action: 'install' }
		}
	});
	const list = byId.get('layout-list');
	const buttons = findAll(
		list,
		(el) => el.tagName === 'BUTTON' && el.dataset.action !== 'open_homepage'
	);
	assert.ok(buttons.length >= 3);
	assert.ok(
		buttons.every((button) => button.disabled),
		'no second operation can start'
	);
	assert.equal(byId.get('btn-refresh').disabled, true);
	assert.ok(textOf(list).includes(strings['layout_manager.busy_install']));
});

check(
	'the catalogue line says where the list comes from and why the network one is missing',
	() => {
		const { byId, window } = loadPage();
		window.initData({
			strings,
			state: {
				platform: 'linux',
				index,
				source: 'bundled',
				error: { code: 'offline', detail: 'could not resolve host' }
			}
		});
		const status = byId.get('catalogue-status');
		assert.ok(status.textContent.startsWith(strings['layout_manager.source_bundled']));
		assert.ok(status.textContent.includes(strings['layout_manager.error_offline']));
		assert.ok(status.classList.contains('is-error'));
		window.updateState({
			platform: 'linux',
			index: null,
			source: 'none',
			error: { code: 'too_large', detail: 'x' }
		});
		assert.ok(
			byId
				.get('catalogue-status')
				.textContent.includes(strings['layout_manager.error_generic'].replace('%s', 'too_large'))
		);
		assert.equal(byId.get('empty').hidden, false, 'an empty list says so');
		window.updateState({ platform: 'linux', index, source: 'network', record_error: 'damaged' });
		assert.ok(
			byId.get('catalogue-status').textContent.includes(strings['layout_manager.error_record'])
		);
	}
);

check('the result line reports success, a translated failure and its detail', () => {
	const { byId, window } = loadPage();
	window.initData({
		strings,
		state: {
			platform: 'macos',
			index,
			installed: {},
			result: { id: 'ergol', action: 'install', ok: true }
		}
	});
	const result = byId.get('result');
	assert.equal(result.hidden, false);
	assert.equal(
		result.textContent,
		strings['layout_manager.result_installed'].replace('%s', 'Ergo-L')
	);
	window.updateState({
		platform: 'macos',
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: true, warning: 'not_enabled' }
	});
	assert.equal(
		byId.get('result').textContent,
		strings['layout_manager.result_installed_not_enabled'].replace('%s', 'Ergo-L')
	);
	window.updateState({
		platform: 'macos',
		index,
		installed: {},
		result: {
			id: 'ergol',
			action: 'install',
			ok: false,
			code: 'download_failed',
			detail: 'HTTP 404 for x'
		}
	});
	const failed = byId.get('result');
	assert.ok(failed.textContent.includes(strings['layout_manager.failure_download']));
	assert.equal(failed.title, 'HTTP 404 for x', 'the technical detail stays available');
	assert.ok(failed.classList.contains('is-error'));
	window.updateState({
		platform: 'linux',
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: false, code: 'python_missing' }
	});
	assert.ok(byId.get('result').textContent.includes(strings['layouts.linux_needs_python']));
	window.updateState({
		platform: 'linux',
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: false, code: 'foreign_file' }
	});
	assert.ok(
		byId.get('result').textContent.includes(strings['layout_manager.failure_foreign_file']),
		'a file the driver did not install is named as such'
	);
	window.updateState({
		platform: 'linux',
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: false, code: 'record_failed' }
	});
	assert.ok(byId.get('result').textContent.includes(strings['layout_manager.failure_other']));
	window.updateState({ platform: 'linux', index, installed: {} });
	assert.equal(byId.get('result').hidden, true);
});

// ==========================
// ==========================
// ======= 4/ Strings =======
// ==========================
// ==========================

check(
	'every string the page shows is declared once for the hosts and exists in every locale',
	() => {
		const keys = new Set();
		for (const match of html.matchAll(/data-i18n="([^"]+)"/g)) keys.add(match[1]);
		for (const match of source.matchAll(/'((?:layout_manager|layouts)\.[a-z_]+)'/g))
			keys.add(match[1]);
		// The status and source keys are composed from the codes the hosts send.
		for (const status of ['installed', 'update', 'available', 'builtin', 'provided', 'active']) {
			keys.add('layout_manager.status_' + status);
		}
		for (const origin of ['network', 'cache', 'bundled', 'none'])
			keys.add('layout_manager.source_' + origin);
		// A literal ending in _ is the prefix of a composed key (status_, source_).
		const literal = [...keys].filter((key) => !key.endsWith('_')).sort();
		assert.ok(literal.length >= 35, `only ${literal.length} keys found`);
		const declared = JSON.parse(fs.readFileSync(path.join(PAGE, 'strings.json'), 'utf8')).keys;
		assert.deepEqual(
			[...declared].sort(),
			literal,
			'strings.json must list exactly the keys the page shows (the hosts send it)'
		);
		for (const code of LOCALES) {
			const table = locale(code);
			const missing = literal.filter((key) => typeof table[key] !== 'string' || table[key] === '');
			assert.deepEqual(missing, [], `${code}.json lacks layout manager strings`);
		}
	}
);

check('the three hosts accept exactly the actions the page sends', () => {
	const { context } = loadPage();
	// A top-level const is not a property of the context: evaluate it there.
	const page = [...vm.runInContext('LAYOUT_MANAGER_ACTIONS', context)].sort();
	assert.ok(page.length >= 8, `the page declares only ${page.length} actions`);
	const lua = fs.readFileSync(path.join(SHARED, 'lua/layouts/manager_bridge.lua'), 'utf8');
	const luaBlock = /M\.ACTIONS = \{([\s\S]*?)\n\}/.exec(lua);
	assert.ok(luaBlock, 'manager_bridge.lua declares no M.ACTIONS');
	const luaActions = [...luaBlock[1].matchAll(/^\t([a-z_]+) = true,$/gm)].map((m) => m[1]).sort();
	assert.deepEqual(luaActions, page, 'the macOS and Linux hosts accept another list');
	const ahk = fs.readFileSync(
		path.resolve(SHARED, '../windows/ui/layout_manager/init.ahk'),
		'utf8'
	);
	const ahkBlock = /global LAYMGR_ACTIONS := Map\(([\s\S]*?)\)\n/.exec(ahk);
	assert.ok(ahkBlock, 'the Windows host declares no LAYMGR_ACTIONS');
	const ahkActions = [...ahkBlock[1].matchAll(/"([a-z_]+)", true/g)].map((m) => m[1]).sort();
	assert.deepEqual(ahkActions, page, 'the Windows host accepts another list');
});

console.log(`\n${passes} passed, ${failures} failed`);
if (failures > 0) process.exit(1);
