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
 * must exist in every locale. The layout editor's own window
 * (_shared/ui/layout_editor_window) is driven the same way: its host actions,
 * its strings and the install payload it forwards.
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
const EDITOR_PAGE = path.join(SHARED, 'ui/layout_editor_window');
const editorSource = fs.readFileSync(path.join(EDITOR_PAGE, 'script.js'), 'utf8');
const editorHtml = fs.readFileSync(path.join(EDITOR_PAGE, 'index.html'), 'utf8');
const infoPopoverSource = fs.readFileSync(
	path.join(SHARED, 'ui/layout_analysis/info_popover.js'),
	'utf8'
);
// The scripts the Studio window reads « Ma frappe » with (index.html loads them
// before script.js): the analysis engine and the keystats key reader.
const studioReaderPreludes = [
	'ui/layout_analysis/analysis_engine.js',
	'ui/metrics_typing/_generated/keystats_tokens.js',
	'ui/metrics_typing/key_tokens.js'
].map((file) => ({ source: fs.readFileSync(path.join(SHARED, file), 'utf8'), filename: file }));
const LOCALE_DIR = path.join(SHARED, 'core/i18n/data/locales');
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
 * Builds a fresh page with every id declared in its index.html.
 * @param {{html: string, source: string, bridge: string}} [page] - The layout
 *   manager page by default.
 * @returns {{context: object, byId: Map, messages: Array}}
 */
function loadPage(page = { html, source, bridge: 'layout_manager_bridge' }) {
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
			setAttribute: (name, value) => {
				el.attributes[name] = String(value);
			},
			addEventListener(type, fn) {
				(listeners[type] = listeners[type] || []).push(fn);
			},
			click() {
				for (const fn of listeners.click || []) fn({ type: 'click' });
			}
		};
		return el;
	}

	for (const match of page.html.matchAll(/<(\w+)[^>]*?\bid="([^"]+)"[^>]*>/g)) {
		byId.set(match[2], makeElement(match[1]));
	}
	for (const match of page.html.matchAll(/<(\w+)[^>]*?data-i18n="([^"]+)"[^>]*>/gs)) {
		const id = /\bid="([^"]+)"/.exec(match[0]);
		const el = id ? byId.get(id[1]) : makeElement(match[1]);
		el.attributes['data-i18n'] = match[2];
		i18nElements.push(el);
	}

	const events = [];
	const document = {
		title: '',
		// The page's declared language, the formatter's last resort.
		documentElement: { lang: (/<html lang="([^"]+)"/.exec(page.html) || [])[1] },
		events,
		dispatchEvent: (event) => events.push(event),
		getElementById: (id) => byId.get(id) || null,
		createElement: makeElement,
		// The Comparer's markup adds placeholders and option prefixes; this
		// fake markup carries none of them.
		querySelectorAll: (selector) => {
			if (selector === '[data-i18n-placeholder]' || selector === 'select[data-i18n-option-prefix]')
				return [];
			assert.equal(selector, '[data-i18n]');
			return i18nElements;
		},
		// Scripts run while the page is still loading, as in a WebView.
		readyState: 'loading',
		listeners: [],
		addEventListener: (type, listener) => events.listeners.push({ type, listener })
	};
	events.listeners = [];
	const window = {
		events: [],
		dispatchEvent: (event) => window.events.push(event),
		webkit: {
			messageHandlers: {
				[page.bridge]: { postMessage: (payload) => messages.push(payload) }
			}
		}
	};
	const context = vm.createContext({
		window,
		document,
		console,
		setTimeout: (fn) => fn(),
		TextDecoder,
		Event: class Event {
			constructor(type) {
				this.type = type;
			}
		},
		CustomEvent: class CustomEvent {
			constructor(type, init) {
				this.type = type;
				this.detail = init && init.detail;
			}
		},
		atob: (text) => Buffer.from(text, 'base64').toString('binary'),
		btoa: (text) => Buffer.from(text, 'binary').toString('base64')
	});
	vm.runInContext(hostBridge, context, { filename: 'host_bridge.js' });
	for (const prelude of page.preludes || [])
		vm.runInContext(prelude.source, context, { filename: prelude.filename });
	vm.runInContext(page.source, context, { filename: 'script.js' });
	return { context, byId, messages, window, document };
}

/** The layout editor's own window, as the hosts open it. */
function loadEditorPage() {
	return loadPage({
		html: editorHtml,
		source: editorSource,
		bridge: 'layout_editor_window_bridge',
		// The page's own Studio formatter (index.html loads it before script.js);
		// a browser makes its top-level var a window property, as the second line does.
		preludes: [
			{ source: infoPopoverSource, filename: 'info_popover.js' },
			{
				source: 'window.LAYOUT_ANALYSIS_INFO = LAYOUT_ANALYSIS_INFO;',
				filename: 'window-binding.js'
			},
			...studioReaderPreludes
		]
	});
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

// The checks that settle a page promise; the summary waits for them.
const pending = [];

function check(name, fn) {
	const fail = (err) => {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${String(err.message).split('\n').join('\n       ')}`);
	};
	const pass = () => {
		passes += 1;
		console.log(`  ok   ${name}`);
	};
	try {
		const result = fn();
		if (result && typeof result.then === 'function') pending.push(result.then(pass, fail));
		else pass();
	} catch (err) {
		fail(err);
	}
}

// The shortcut menu file each host names in its state, as
// the host test below checks in the host sources.
const SHORTCUT_MENU = {
	windows: 'shortcuts/menu.ahk',
	macos: 'shortcuts/menu.lua',
	linux: 'shortcuts/menu.lua'
};

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
		shortcut_menu_path: SHORTCUT_MENU.windows,
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
		shortcut_menu_path: SHORTCUT_MENU.macos,
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

check('a built-in layout is recognised when the Windows host sends its flag as 1', () => {
	const { context } = loadPage();
	const rows = context.layoutRows({
		platform: 'windows',
		shortcut_menu_path: SHORTCUT_MENU.windows,
		index,
		installed: {},
		builtin: { ergopti: 1 }
	});
	assert.equal(rows.find((row) => row.id === 'ergopti').status, 'builtin');
});

check('extension updates remain visible when the layout bytes did not change', () => {
	const { context } = loadPage();
	const entry = { ...index.layouts[1], extension: { sha256: 'new-content', files: [] } };
	const rows = context.layoutRows({
		platform: 'windows',
		shortcut_menu_path: SHORTCUT_MENU.windows,
		index: { layouts: [entry] },
		installed: { ergol: { ...entry, extension: { sha256: 'old-content', files: [] } } }
	});
	assert.equal(rows[0].status, 'update');
	assert.ok(rows[0].actions.includes('update'));
});

check('the shortcut menu counted is the file the host names, never a platform guess', () => {
	const { context } = loadPage();
	const entry = {
		...index.layouts[1],
		extension: { sha256: 'payload', files: [{ path: 'shortcuts/menu.lua' }] }
	};
	const count = (shortcutMenuPath) =>
		context.layoutRows({
			platform: 'windows',
			shortcut_menu_path: shortcutMenuPath,
			index: { layouts: [entry] },
			installed: {}
		})[0].shortcuts;
	assert.equal(count('shortcuts/menu.lua'), 1, 'the named file is counted');
	assert.equal(count('shortcuts/menu.ahk'), 0, 'another host file is not');
	assert.throws(
		() => context.layoutRows({ platform: 'windows', index: { layouts: [entry] }, installed: {} }),
		/shortcut_menu_path/,
		'a host that names no shortcut menu file is refused'
	);
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
			window.initData({
				strings,
				state: {
					platform,
					shortcut_menu_path: SHORTCUT_MENU[platform],
					index: { layouts: [entry] },
					installed: {}
				}
			});
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
		state: {
			platform: 'linux',
			shortcut_menu_path: SHORTCUT_MENU.linux,
			index,
			source: 'network',
			error: null,
			installed: {},
			active: ''
		}
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
			shortcut_menu_path: SHORTCUT_MENU.linux,
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

for (const action of ['select', 'uninstall']) {
	check(`(layout-selection-owner) ${action} disables mutations with an honest busy label`, () => {
		const { byId, window } = loadPage();
		window.initData({
			strings,
			state: {
				platform: 'linux',
				shortcut_menu_path: SHORTCUT_MENU.linux,
				index,
				source: 'cache',
				installed: { ergol: index.layouts.find((entry) => entry.id === 'ergol') },
				active: 'ergopti',
				busy: { id: 'ergol', action }
			}
		});
		const list = byId.get('layout-list');
		const buttons = findAll(
			list,
			(el) => el.tagName === 'BUTTON' && el.dataset.action !== 'open_homepage'
		);
		assert.ok(buttons.length >= 3);
		assert.ok(buttons.every((button) => button.disabled));
		assert.equal(byId.get('btn-refresh').disabled, true);
		assert.ok(
			!textOf(list).includes(strings['layout_manager.busy_install']),
			'selection is not an installation'
		);
		assert.equal(
			textOf(list).includes(strings['layout_manager.busy_uninstall']),
			action === 'uninstall'
		);
	});
}

check(
	'the catalogue line says where the list comes from and why the network one is missing',
	() => {
		const { byId, window } = loadPage();
		window.initData({
			strings,
			state: {
				platform: 'linux',
				shortcut_menu_path: SHORTCUT_MENU.linux,
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
			shortcut_menu_path: SHORTCUT_MENU.linux,
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
		window.updateState({
			platform: 'linux',
			shortcut_menu_path: SHORTCUT_MENU.linux,
			index,
			source: 'network',
			record_error: 'damaged'
		});
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
			shortcut_menu_path: SHORTCUT_MENU.macos,
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
		shortcut_menu_path: SHORTCUT_MENU.macos,
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: true, warning: 'not_enabled' }
	});
	assert.equal(
		byId.get('result').textContent,
		strings['layout_manager.result_installed_not_enabled'].replace('%s', 'Ergo-L')
	);
	// macOS 26 turns a listed layout on only at the next login: no step is left to the user
	window.updateState({
		platform: 'macos',
		shortcut_menu_path: SHORTCUT_MENU.macos,
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: true, warning: 'pending_logout' }
	});
	assert.equal(
		byId.get('result').textContent,
		strings['layout_manager.result_installed_pending_logout'].replace('%s', 'Ergo-L')
	);
	assert.equal(byId.get('result').classList.contains('is-error'), false);
	window.updateState({
		platform: 'macos',
		shortcut_menu_path: SHORTCUT_MENU.macos,
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: true, warning: 'macos_consent' }
	});
	assert.equal(
		byId.get('result').textContent,
		strings['layout_manager.result_installed_consent'].replace('%s', 'Ergo-L')
	);
	window.updateState({
		platform: 'macos',
		shortcut_menu_path: SHORTCUT_MENU.macos,
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
		shortcut_menu_path: SHORTCUT_MENU.linux,
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: false, code: 'python_missing' }
	});
	assert.ok(byId.get('result').textContent.includes(strings['layouts.linux_needs_python']));
	window.updateState({
		platform: 'linux',
		shortcut_menu_path: SHORTCUT_MENU.linux,
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
		shortcut_menu_path: SHORTCUT_MENU.linux,
		index,
		installed: {},
		result: { id: 'ergol', action: 'install', ok: false, code: 'record_failed' }
	});
	assert.ok(byId.get('result').textContent.includes(strings['layout_manager.failure_other']));
	window.updateState({
		platform: 'linux',
		shortcut_menu_path: SHORTCUT_MENU.linux,
		index,
		installed: {}
	});
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
		assert.ok(literal.length >= 40, `only ${literal.length} keys found`);
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

check('the three hosts accept exactly the actions each page sends', () => {
	const manager = [...vm.runInContext('LAYOUT_MANAGER_ACTIONS', loadPage().context)].sort();
	// A top-level const is not a property of the context: evaluate it there.
	const editor = [
		...vm.runInContext('LAYOUT_EDITOR_WINDOW_ACTIONS', loadEditorPage().context)
	].sort();
	assert.ok(manager.length >= 8, `the manager page declares only ${manager.length} actions`);
	assert.ok(editor.length >= 8, `the editor window declares only ${editor.length} actions`);
	// macOS and Linux serve both windows with the one shared controller.
	const lua = fs.readFileSync(path.join(SHARED, 'layouts/engine/manager_bridge.lua'), 'utf8');
	const luaBlock = /M\.ACTIONS = \{([\s\S]*?)\n\}/.exec(lua);
	assert.ok(luaBlock, 'manager_bridge.lua declares no M.ACTIONS');
	const luaActions = [...luaBlock[1].matchAll(/^\t([a-z_]+) = true,$/gm)].map((m) => m[1]).sort();
	assert.deepEqual(
		luaActions,
		[...new Set([...manager, ...editor])].sort(),
		'the macOS and Linux hosts accept another list'
	);
	const windows = (file, name) => {
		const ahk = fs.readFileSync(path.resolve(SHARED, '../windows/ui/layout_manager', file), 'utf8');
		const block = new RegExp(`global ${name} := Map\\(([\\s\\S]*?)\\)\\n`).exec(ahk);
		assert.ok(block, `the Windows host declares no ${name}`);
		return [...block[1].matchAll(/"([a-z_]+)", true/g)].map((m) => m[1]).sort();
	};
	assert.deepEqual(
		windows('init.ahk', 'LAYMGR_ACTIONS'),
		manager,
		'the Windows layout manager accepts another list'
	);
	assert.deepEqual(
		windows('editor_window.ahk', 'LAYOUT_EDITOR_WINDOW_ACTIONS'),
		editor,
		'the Windows layout editor window accepts another list'
	);
});

check('the manager opens the layout editor in its own window', () => {
	const { window, byId, messages } = loadPage();
	window.initData({
		strings,
		state: { platform: 'linux', shortcut_menu_path: SHORTCUT_MENU.linux, index, installed: {} },
		source_editor: true
	});
	assert.equal(byId.get('btn-editor').hidden, false);
	assert.ok(!byId.has('layout-editor'), 'the manager page no longer carries the editor');
	byId.get('btn-editor').click();
	assert.equal(plain(messages[messages.length - 1]).action, 'open_editor');
	assert.ok(!/layout_editor\/editor_page\.js/.test(html), 'the manager loads no editor script');
});

check('the editor window declares its strings for the hosts, present in every locale', () => {
	// The page's own script names the Ergopti Studio status lines it writes.
	const script = fs.readFileSync(path.join(EDITOR_PAGE, 'script.js'), 'utf8');
	const keys = [
		...new Set([
			...[...editorHtml.matchAll(/data-i18n="([^"]+)"/g)].map((m) => m[1]),
			...[...script.matchAll(/'(layout_editor\.studio\.[a-z_.]+)'/g)].map((m) => m[1])
		])
	].sort();
	const declared = JSON.parse(fs.readFileSync(path.join(EDITOR_PAGE, 'strings.json'), 'utf8')).keys;
	assert.deepEqual(
		[...declared].sort(),
		keys,
		'strings.json must list exactly the keys the page shows'
	);
	for (const code of LOCALES) {
		const table = locale(code);
		assert.deepEqual(
			keys.filter((key) => typeof table[key] !== 'string' || table[key] === ''),
			[],
			`${code}.json lacks layout editor window strings`
		);
	}
});

check('a copied layout is named as the user’s own layout, not « My Ergopti »', () => {
	// « Mon Ergopti » read as the Ergopti layout itself (maintainer, 2026-11-18):
	// the copy is « My layout (based on Ergopti) », its name only a label (the
	// stored ids and workspace keys are unchanged).
	for (const code of LOCALES) {
		const table = locale(code);
		const name = table['layout_editor.start.copy_name'];
		const own = table['layout_editor.default_name'];
		assert.ok(
			typeof name === 'string' && name.includes('{name}'),
			`${code}.json: the copy's name lacks {name}`
		);
		assert.ok(
			typeof own === 'string' && own !== '' && name.includes(own),
			`${code}.json: « ${name.replace('{name}', 'Ergopti')} » does not say « ${own} »`
		);
		assert.ok(
			!/^(Mon|My) Ergopti$/.test(name.replace('{name}', 'Ergopti')),
			`${code}.json still says « ${name.replace('{name}', 'Ergopti')} »`
		);
		// The editor's own names: its blank tab and the Comparer's copy of a tab.
		assert.ok(!own.includes('Ergopti'), `${code}.json: the editor's default tab is « ${own} »`);
		const duplicate = table['layout_analysis.mine.copy_name'];
		assert.ok(
			typeof duplicate === 'string' && duplicate.includes('{name}'),
			`${code}.json: the duplicate's name lacks {name}`
		);
		const named = Object.entries(table).filter(([, text]) => /\b(Mon|My) Ergopti\b/.test(text));
		assert.deepEqual(named, [], `${code}.json says « Mon Ergopti »`);
	}
	// No page of the Studio names a tab, a workspace or a layout « Mon Ergopti »
	// in code, the editor included (its restored tabs are renamed, editor_page.js).
	for (const folder of ['layout_editor', 'layout_editor_window', 'layout_analysis']) {
		const dir = path.join(SHARED, 'ui', folder);
		for (const file of fs.readdirSync(dir).filter((name) => /\.(js|html)$/.test(name)))
			assert.ok(
				!/\b(Mon|My) Ergopti\b/.test(fs.readFileSync(path.join(dir, file), 'utf8')),
				`ui/${folder}/${file} names « Mon Ergopti »`
			);
	}
});

check(
	'Ergopti Studio reads « My typing » when the window opens, from a host that offers it',
	() => {
		const keys = JSON.parse(fs.readFileSync(path.join(EDITOR_PAGE, 'strings.json'), 'utf8')).keys;
		const strings = Object.fromEntries(keys.map((key) => [key, 'T:' + key + ' {1}']));
		const contract = JSON.parse(
			fs.readFileSync(path.join(SHARED, 'metrics/data/studio_ngrams.json'), 'utf8')
		);
		assert.deepEqual(
			Object.keys(plain(vm.runInContext('KEYSTATS_REFUSALS', loadEditorPage().context))).sort(),
			Object.values(contract.codes).sort(),
			'the page translates exactly the refusal codes the hosts send'
		);
		// « My typing » is a corpus, not a bar with its own button (maintainer,
		// 2026-11-17): the page announces each state of its read to the Comparer.
		const states = (document) =>
			document.events
				.filter((event) => event.type === 'studio-ngrams-state')
				.map((event) => plain(event.detail));
		const quiet = loadEditorPage();
		quiet.window.initData({ strings, state: { platform: 'linux' } });
		assert.equal(quiet.byId.get('studio-keystats'), undefined, 'the page has no keystats bar');
		assert.deepEqual(states(quiet.document), [], 'a host without keystats offers no « My typing »');
		const { window, messages, document } = loadEditorPage();
		window.initData({ strings, state: { platform: 'linux' }, keystats: true });
		const reads = () => messages.filter((m) => m.action === 'keystats_ngrams').length;
		// « My typing » is the app's default corpus: the window reads it once when it opens.
		assert.equal(reads(), 1, 'the window reads the store when it opens');
		window.initData({ strings, state: { platform: 'linux' }, keystats: true });
		assert.equal(reads(), 1, 'none again for a second initData');
		assert.deepEqual(states(document), [{ state: 'loading', reason: '' }]);
		// No store yet, at the read the window makes by itself: no corpus to offer.
		window.keystatsNgrams({ ok: false, code: 'keystats_absent' });
		assert.deepEqual(states(document)[1], {
			state: 'absent',
			reason: 'T:layout_editor.studio.keystats.keystats_absent {1}'
		});
		const published = () => document.events.filter((event) => event.type === 'studio-ngrams');
		assert.equal(published().length, 0, 'a refusal publishes no data');
		window.keystatsNgrams({ ok: false, code: 'something_else' });
		assert.deepEqual(
			states(document)[2],
			{
				state: 'failed',
				reason: 'T:layout_editor.studio.keystats.keystats_unreadable {1}'
			},
			'an unknown code reads as unreadable'
		);
		// Schema 2 (maintainer, 2026-11-17): the keys typed at the top level, and
		// the final text (every source counted) under the contract's final_field,
		// which the Comparer's text modes read.
		assert.equal(contract.schema, 2, 'the payload carries the final text since schema 2');
		assert.equal(contract.final_field, 'final');
		const ngrams = {
			schema: contract.schema,
			source: 'keystats',
			chars: { e: 7 },
			bigrams: {},
			trigrams: {},
			total: 7,
			[contract.final_field]: { chars: { e: 9 }, bigrams: {}, trigrams: {}, total: 9 }
		};
		window.keystatsNgrams({ ok: true, ngrams });
		assert.equal(published().length, 1);
		const empty = { chars: {}, bigrams: {}, trigrams: {} };
		assert.deepEqual(plain(published()[0].detail), {
			chars: { e: 7 },
			bigrams: {},
			trigrams: {},
			breaks: empty,
			total: 7,
			skipped: 0,
			final: { chars: { e: 9 }, bigrams: {}, trigrams: {}, breaks: empty, total: 9, skipped: 0 }
		});
		// The analysis panels open their « i » links through the host.
		window.LAYOUT_ANALYSIS_HOST.openLink('https://ergopti.fr/studio');
		assert.deepEqual(plain(messages[messages.length - 1]), {
			action: 'open_link',
			url: 'https://ergopti.fr/studio'
		});
	}
);

check(
	'Ergopti Studio hands the analyses the saved read, then the fresh one, from one request',
	() => {
		// (studio-my-typing-refresh) A host may answer the window's one
		// keystats_ngrams twice: a saved projection at once, then a fresh read.
		// Both reach the Comparer and the analysis panel, in order; a refused
		// refresh publishes nothing over the saved tables.
		const { window, messages, document } = loadEditorPage();
		window.initData({ strings: {}, state: { platform: 'windows' }, keystats: true });
		assert.equal(messages.filter((m) => m.action === 'keystats_ngrams').length, 1);
		const saved = {
			schema: 1,
			source: 'keystats',
			chars: { e: 7 },
			bigrams: {},
			trigrams: {},
			total: 7
		};
		const fresh = {
			schema: 1,
			source: 'keystats',
			chars: { e: 9 },
			bigrams: {},
			trigrams: {},
			total: 9
		};
		window.keystatsNgrams({ ok: true, ngrams: saved });
		window.keystatsNgrams({ ok: true, ngrams: fresh });
		const published = () =>
			document.events
				.filter((event) => event.type === 'studio-ngrams')
				.map((event) => plain(event.detail));
		assert.deepEqual(
			published().map((tables) => tables.chars),
			[{ e: 7 }, { e: 9 }],
			'each answer is published, the fresh one last'
		);
		window.keystatsNgrams({ ok: false, code: 'keystats_unreadable' });
		assert.equal(published().length, 2, 'a refused refresh publishes no data');
		assert.equal(
			messages.filter((m) => m.action === 'keystats_ngrams').length,
			1,
			'the second answer is not a second request'
		);
	}
);

check(
	'(studio-my-typing-markers) « Ma frappe » reaches the tabs as text, not as stored keys',
	() => {
		// The keystats store keeps keys: [BS], [ENTER], the arrows, [[ for a typed
		// bracket, and Escape as U+001B. The saved read with them reached the
		// editor's analysis panel before the editor mounted (the AHK host answers
		// keystats_ngrams while it still builds sourceData); its first table refused
		// "[BS]" as a 1-gram and « Éditer » stayed empty, and the Comparer never
		// listed « Ma frappe ».
		const { window, document, context } = loadEditorPage();
		window.initData({ strings: {}, state: { platform: 'windows' }, keystats: true });
		const stored = {
			chars: { e: 5, '[BS]': 4, '[ENTER]': 2, '\n': 2, '[[': 1, '\u001b': 3, ' ?': 1 },
			bigrams: { 'e[BS]': 3, '[BS][BS]': 2, ee: 1, 'e\n': 2, '[[e': 1 },
			trigrams: { 'e[BS]e': 1, eee: 1, '[ENTER]\ne': 1 },
			total: 18
		};
		window.keystatsNgrams({ ok: true, ngrams: { ...stored, final: stored } });
		const published = document.events.filter((event) => event.type === 'studio-ngrams');
		assert.equal(published.length, 1, 'the read is published');
		const tables = plain(published[0].detail);
		assert.deepEqual(tables.chars, { e: 5, '[': 1 }, 'markers and control keys are not text');
		assert.deepEqual(tables.bigrams, { ee: 1, '[e': 1 });
		assert.deepEqual(tables.trigrams, { eee: 1 });
		assert.deepEqual(tables.breaks, { chars: { '\n': 2 }, bigrams: { 'e\n': 2 }, trigrams: {} });
		assert.equal(tables.skipped, 4 + 2 + 3 + 1, 'every key left out is counted');
		// Every tab prepares the tables it receives: none may refuse them.
		const engine = vm.runInContext('LAYOUT_ANALYSIS', context);
		engine.prepareNgrams(published[0].detail);
		engine.prepareNgrams(published[0].detail.final);
		assert.equal(
			document.events.filter((event) => event.type === 'studio-ngrams-state').length,
			1,
			'only the loading state was announced'
		);
		// Tables the engine still refuses are announced as unreadable, never published.
		window.keystatsNgrams({ ok: true, ngrams: { chars: { e: 'many' }, bigrams: {} } });
		assert.equal(document.events.filter((event) => event.type === 'studio-ngrams').length, 1);
		const states = document.events.filter((event) => event.type === 'studio-ngrams-state');
		assert.equal(states[states.length - 1].detail.state, 'failed');
	}
);

check(
	'Ergopti Studio keeps the Comparer layouts in the host and runs corpus tables on request',
	async () => {
		const { window, byId, messages } = loadEditorPage();
		const store = window.LAYOUT_ANALYSIS_HOST.store;
		assert.ok(store, 'the Comparer finds the store at its mount, before initData');
		// The Comparer lists the stored layouts when it starts, before initData.
		const early = store.list();
		assert.equal(
			messages.filter((m) => m.action === 'studio_layouts').length,
			0,
			'nothing is asked before the host offers its store'
		);
		window.initData({ strings: {}, state: { platform: 'linux' }, studio_store: true });
		await new Promise((resolve) => setImmediate(resolve));
		const first = messages[messages.length - 1];
		assert.equal(first.action, 'studio_layouts');
		window.studioLayouts({ request: first.request, ok: true, layouts: [] });
		assert.deepEqual(plain(await early), []);
		const layout = { id: 'user_mine', rows: { KeyQ: ['q', null, null, 'Q'] } };
		const saving = store.save(layout);
		await new Promise((resolve) => setImmediate(resolve));
		const save = messages[messages.length - 1];
		assert.equal(save.action, 'studio_layout_save');
		assert.equal(save.id, 'user_mine');
		assert.equal(save.text, JSON.stringify(layout), 'the layout travels as its JSON text');
		window.studioLayoutResult({ request: save.request, ok: true, detail: 'user_mine' });
		await saving;
		const listing = store.list();
		await new Promise((resolve) => setImmediate(resolve));
		const list = messages[messages.length - 1];
		assert.equal(list.action, 'studio_layouts');
		window.studioLayouts({ request: list.request, ok: true, layouts: [save.text] });
		assert.deepEqual(plain(await listing), [layout]);
		const failing = store.list();
		await new Promise((resolve) => setImmediate(resolve));
		window.studioLayouts({
			request: messages[messages.length - 1].request,
			ok: false,
			code: 'studio_unreadable'
		});
		await assert.rejects(failing, (error) => error.code === 'studio_unreadable');
		const removing = store.remove('user_mine');
		await new Promise((resolve) => setImmediate(resolve));
		const remove = messages[messages.length - 1];
		assert.deepEqual(plain(remove), {
			action: 'studio_layout_remove',
			request: remove.request,
			id: 'user_mine'
		});
		window.studioLayoutResult({ request: remove.request, ok: true });
		await removing;

		// The fingering profile: one per user, null for the defaults.
		const profiling = store.loadProfile();
		await new Promise((resolve) => setImmediate(resolve));
		const load = messages[messages.length - 1];
		assert.equal(load.action, 'studio_profile_load');
		window.studioProfile({ request: load.request, ok: true });
		assert.equal(await profiling, null, 'no saved profile is the defaults');
		const profile = { id: 'mine', fingers: { Digit6: 'right_index' }, home: {} };
		const savingProfile = store.saveProfile(profile);
		await new Promise((resolve) => setImmediate(resolve));
		const saveProfile = messages[messages.length - 1];
		assert.deepEqual(plain(saveProfile), {
			action: 'studio_profile_save',
			request: saveProfile.request,
			text: JSON.stringify(profile)
		});
		window.studioProfileResult({ request: saveProfile.request, ok: true });
		await savingProfile;
		const reloading = store.loadProfile();
		await new Promise((resolve) => setImmediate(resolve));
		window.studioProfile({
			request: messages[messages.length - 1].request,
			ok: true,
			profile: JSON.stringify(profile)
		});
		assert.deepEqual(plain(await reloading), profile);
		const resetting = store.saveProfile(null);
		await new Promise((resolve) => setImmediate(resolve));
		const reset = messages[messages.length - 1];
		assert.deepEqual(plain(reset), {
			action: 'studio_profile_save',
			request: reset.request,
			reset: true
		});
		window.studioProfileResult({ request: reset.request, ok: false, code: 'studio_write_failed' });
		await assert.rejects(resetting, (error) => error.code === 'studio_write_failed');

		// A host without a store refuses every call instead of waiting forever.
		const quiet = loadEditorPage();
		const refused = quiet.window.LAYOUT_ANALYSIS_HOST.store.list();
		quiet.window.initData({ strings: {}, state: { platform: 'linux' } });
		await assert.rejects(refused, (error) => error.code === 'studio_store_unavailable');

		// A built-in corpus's tables run in the page through the host.
		const loading = window.LAYOUT_ANALYSIS_HOST.loadCorpus('fr_swann');
		const corpus = messages[messages.length - 1];
		assert.deepEqual(plain(corpus), {
			action: 'studio_corpus',
			request: corpus.request,
			id: 'fr_swann'
		});
		window.LAYOUT_ANALYSIS_CORPORA = { fr_swann: { chars: {} } };
		window.studioCorpus({ request: corpus.request, ok: true });
		await loading;
		const missing = window.LAYOUT_ANALYSIS_HOST.loadCorpus('en_other');
		window.studioCorpus({ request: messages[messages.length - 1].request, ok: true });
		await assert.rejects(missing, /no tables for the corpus en_other/);
		const unavailable = window.LAYOUT_ANALYSIS_HOST.loadCorpus('en_other');
		window.studioCorpus({
			request: messages[messages.length - 1].request,
			ok: false,
			code: 'studio_corpus_unavailable'
		});
		await assert.rejects(unavailable, (error) => error.code === 'studio_corpus_unavailable');

		// The tabs show one panel at a time; the Comparer mounts the first time.
		const mounts = [];
		window.LAYOUT_ANALYSIS_COMPARER = {
			mount: (root, options) => mounts.push({ root, options })
		};
		byId.get('studio-tab-compare').click();
		assert.equal(byId.get('layout-editor').hidden, true);
		assert.equal(byId.get('studio-comparer').hidden, false);
		assert.equal(mounts.length, 1);
		assert.ok(mounts[0].root === byId.get('studio-comparer'));
		assert.ok(mounts[0].options.host === window.LAYOUT_ANALYSIS_HOST, 'the Comparer gets the host');
		byId.get('studio-tab-edit').click();
		assert.equal(byId.get('layout-editor').hidden, false);
		assert.equal(byId.get('studio-comparer').hidden, true);
		byId.get('studio-tab-compare').click();
		assert.equal(mounts.length, 1, 'the Comparer mounts once');
		assert.equal(
			window.events[window.events.length - 1].type,
			'resize',
			'the Comparer lays out again'
		);
	}
);

check(
	'the macOS and Linux windows build the downloads with the host Lua (lua_export)',
	async () => {
		const { context, window, messages } = loadEditorPage();
		context.LayoutExportAssetData = { keysyms: { a: 1 }, template: 'symbols', types: 'types' };
		context.LayoutKlcGenerator = { id: 'klc' };
		window.initData({
			strings: {},
			state: { platform: 'linux' },
			source_export: true,
			lua_export: true
		});
		const assets = vm.runInContext('hostExportAssets()', context);
		assert.equal(assets.template, 'symbols');
		assert.ok(assets.generator === context.LayoutKlcGenerator);
		const running = assets.lua.call('xkb', { name: 'mine' });
		const step = messages[messages.length - 1];
		assert.deepEqual(plain(step), {
			action: 'lua_export',
			request: step.request,
			step: 'xkb',
			input: '{"name":"mine"}'
		});
		window.luaExportResult({ request: step.request, ok: true, output: '{"ok":true,"files":[]}' });
		assert.deepEqual(plain(await running), { ok: true, files: [] }, 'the result is the host JSON');
		const refused = assets.lua.call('read', { xml: '<keyboard/>' });
		window.luaExportResult({
			request: messages[messages.length - 1].request,
			ok: false,
			code: 'target_export_refused',
			detail: 'the export step is not read or xkb'
		});
		await assert.rejects(refused, (error) => error.code === 'target_export_refused');

		// A host without lua_export (Windows) builds them with the page's fengari VM.
		const windows = loadEditorPage();
		windows.context.LayoutExportAssetData = { keysyms: {}, template: '', types: '' };
		windows.context.LayoutKlcGenerator = {};
		windows.context.LayoutLuaRunner = { assets: () => ({ via: 'fengari' }) };
		windows.window.initData({ strings: {}, state: { platform: 'windows' }, source_export: true });
		assert.equal(vm.runInContext('hostExportAssets()', windows.context).via, 'fengari');
	}
);

check(
	'the editor window mounts the editor on sourceData and closes its window on « Close »',
	() => {
		const { context, window, messages } = loadEditorPage();
		window.initData({ strings: {}, state: { platform: 'linux' }, nav_apply: true, emulate: true });
		let host = null;
		const order = [];
		context.LayoutEditorPage = {
			mount: (root, options) => {
				host = options;
				return {
					open: () => {},
					flushAutosave: () => order.push(`flush before ${messages.length} messages`)
				};
			}
		};
		window.sourceData({ text: 'a = 1', filename: 'mine.toml' });
		assert.ok(host, 'the editor is mounted on sourceData');
		assert.equal(host.platform, 'linux');
		assert.equal(host.initial, 'a = 1');
		assert.equal(typeof host.applyNav, 'function');
		assert.equal(typeof host.emulate, 'function');
		assert.equal(host.pickFile, null, 'no native picker without source_pick');
		assert.equal(host.workspace, null, 'no workspace store without studio_workspace');
		const before = messages.length;
		host.onClose();
		// The tabs' last edits are saved before the window closes (layout-editor-workspace).
		assert.deepEqual(order, [`flush before ${before} messages`]);
		assert.equal(plain(messages[messages.length - 1]).action, 'close');
		host.saveFile('mine.toml', 'b = 2');
		assert.deepEqual(plain(messages[messages.length - 1]), {
			action: 'source_save',
			filename: 'mine.toml',
			text: 'b = 2'
		});
		window.sourceResult({ ok: true });
	}
);

check(
	'the editor window offers the downloads only when its host writes them (source_export)',
	() => {
		const mounted = (exports) => {
			const page = loadEditorPage();
			page.window.initData({ strings: {}, state: { platform: 'linux' }, source_export: exports });
			let host = null;
			page.context.LayoutEditorPage = {
				mount: (root, options) => {
					host = options;
					return { open: () => {} };
				}
			};
			page.window.sourceData({ text: null });
			return { ...page, host };
		};
		const without = mounted(undefined);
		assert.equal(without.host.saveBinary, null, 'no download without source_export');
		assert.equal(without.host.exportAssets, null, 'no XKB or KLC build without source_export');
		const { context, window, messages, host } = mounted(true);
		const calls = [];
		context.LayoutExportAssetData = { sources: {} };
		context.LayoutKlcGenerator = { generator: true };
		context.LayoutLuaRunner = {
			assets: (scope, data, generator) => {
				calls.push([scope === window, data === context.LayoutExportAssetData, generator]);
				return { built: calls.length };
			}
		};
		assert.equal(host.exportAssets().built, 1, 'the shipped data builds the export assets');
		assert.equal(host.exportAssets().built, 1, 'once per window');
		assert.equal(calls.length, 1);
		assert.deepEqual(plain(calls[0]), [true, true, { generator: true }]);
		const bytes = new Uint8Array(0x8000 + 3).map((_, i) => i % 256);
		let saved = null;
		host.saveBinary('mine_xkb.zip', bytes, 'application/zip').then((path) => (saved = path));
		const sent = plain(messages[messages.length - 1]);
		assert.equal(sent.action, 'source_export');
		assert.equal(sent.filename, 'mine_xkb.zip');
		assert(
			Buffer.from(sent.data, 'base64').equals(Buffer.from(bytes)),
			'the bytes cross as base64, unchanged'
		);
		let busy = null;
		host.saveBinary('other.zip', bytes).catch((error) => (busy = error.code));
		window.exportResult({ ok: true, path: 'Downloads/mine_xkb.zip' });
		let refused = null;
		host.saveBinary('x.zip', bytes).catch((error) => (refused = error));
		window.exportResult({ ok: false, code: 'write_failed', detail: 'disk full' });
		return Promise.resolve().then(() => {
			assert.equal(saved, 'Downloads/mine_xkb.zip', 'settles with the written path');
			assert.equal(busy, 'save_busy', 'one download at a time');
			assert.deepEqual(plain(refused), { code: 'write_failed', path: 'disk full' });
		});
	}
);

check('« Install and use » forwards the Windows layout DLL images the page wrote', () => {
	const { context, window, messages } = loadEditorPage();
	window.initData({
		strings: {},
		state: { platform: 'windows' },
		source_editor: true
	});
	let host = null;
	context.LayoutEditorPage = {
		mount: (root, options) => {
			host = options;
			return { open: () => {} };
		}
	};
	window.sourceData({ text: null, strings: { 'layout_editor.btn.install': 'Install' } });
	assert.ok(host, 'the editor is mounted on sourceData');
	assert.equal(
		window._i18n_strings['layout_editor.btn.install'],
		'Install',
		'the strings sent with sourceData reach the editor'
	);
	host.install({
		source: 'format = "ergopti-layout"\n',
		keylayout: '<?xml?>',
		emulation: '{}',
		dll_name: 'kbdmine',
		dlls: { x86: 'TVo=', wow64: 'TVo=', x64: 'TVo=', arm64: 'TVo=' }
	});
	const sent = plain(messages[messages.length - 1]);
	assert.equal(sent.action, 'composer_save');
	assert.equal(sent.dll_name, 'kbdmine');
	assert.deepEqual(Object.keys(sent.dlls).sort(), ['arm64', 'wow64', 'x64', 'x86']);
	window.composerResult({ action: 'composer_save', ok: true });
	host.install({ source: 's', keylayout: 'k' });
	const plainSave = plain(messages[messages.length - 1]);
	assert.ok(!('dlls' in plainSave), 'a host without images sends none');
});

check('every host names the shortcut menu file the page counts', () => {
	const ahk = fs.readFileSync(
		path.resolve(SHARED, '../windows/ui/layout_manager/init.ahk'),
		'utf8'
	);
	assert.ok(
		ahk.includes(`"shortcut_menu_path", "${SHORTCUT_MENU.windows}"`),
		'the Windows host names another shortcut menu file'
	);
	const lua = fs.readFileSync(path.join(SHARED, 'layouts/engine/manager_bridge.lua'), 'utf8');
	assert.ok(
		lua.includes(`M.SHORTCUT_MENU_PATH = "${SHORTCUT_MENU.linux}"`) &&
			SHORTCUT_MENU.linux === SHORTCUT_MENU.macos &&
			lua.includes('shortcut_menu_path = M.SHORTCUT_MENU_PATH'),
		'the macOS and Linux hosts name another shortcut menu file'
	);
});

Promise.all(pending).then(() => {
	console.log(`\n${passes} passed, ${failures} failed`);
	if (failures > 0) process.exit(1);
});
