// tools/test/test-onboarding-wizard-page.cjs

/**
 * ==============================================================================
 * MODULE: Onboarding Wizard Page Regression
 * DESCRIPTION:
 * Executes the shared first-run wizard page against a minimal DOM and drives it
 * through the host protocol every driver speaks, for each driver platform of
 * the generated catalogue.
 *
 * FEATURES & RATIONALE:
 * 1. One page per configuration scope, in the approved menu order, after the
 *    language and folder steps; every question starts at No.
 * 2. The finish payload carries manifest paths only: each one is checked
 *    against the driver's own generated manifest, not against the catalogue
 *    that produced it.
 * 3. A Yes imports the recommended items, a re-run starts from the values in
 *    force and writes only what the answers change.
 * 4. The earlier regressions stay pinned: the title follows the previewed
 *    locale and names the product once, a folder picked natively reaches the
 *    payload, and the metrics consent names the store of the chosen folder.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const TOML = require('smol-toml');

const ROOT = path.resolve(__dirname, '../..');
const SP = path.join(ROOT, 'static/ergopti_plus');
const SHARED = path.join(SP, '_shared');
const source = fs.readFileSync(path.join(SHARED, 'ui/onboarding/script.js'), 'utf8');
const hostBridge = fs.readFileSync(path.join(SHARED, 'ui/host_bridge.js'), 'utf8');
const catalogueScript = fs.readFileSync(
	path.join(SHARED, 'ui/_generated/onboarding_catalogue.js'),
	'utf8'
);
const html = fs.readFileSync(path.join(SHARED, 'ui/onboarding/index.html'), 'utf8');
const LOCALE_DIR = path.join(SHARED, 'data/locales');
const PRODUCT = 'ErgoptiPlus';

// The approved first-run order: the Tap-Holds, Shortcuts, Gestures, keyboard
// layout, Hotstrings, AI and Metrics submenus.
const APPROVED_ORDER = [
	'tap_holds',
	'shortcuts',
	'gestures',
	'keyboard_layout',
	'hotstrings',
	'llm',
	'metrics'
];

// Each driver's own generated manifest: the independent authority on which
// paths exist for it.
const DRIVER_MANIFESTS = {
	windows: {
		file: 'windows/_generated/features_manifest.ahk',
		row: /Map\("path", "([^"]+)"[^\n]*?"type", "([^"]+)"/g
	},
	macos: {
		file: 'macos/_generated/features_manifest.lua',
		row: /path = "([^"]+)"[^\n]*?type = "([^"]+)"/g
	},
	linux: {
		file: 'linux/_generated/features_manifest.lua',
		row: /path = "([^"]+)"[^\n]*?type = "([^"]+)"/g
	}
};

/**
 * Reads one locale file as a flat key -> string map.
 * @param {string} code
 * @returns {Object<string, string>}
 */
function locale(code) {
	return JSON.parse(
		fs.readFileSync(path.join(LOCALE_DIR, code + '.json'), 'utf8').replace(/^﻿/, '')
	);
}

/**
 * Counts non-overlapping occurrences of needle in haystack.
 * @param {string} haystack
 * @param {string} needle
 * @returns {number}
 */
function occurrences(haystack, needle) {
	return haystack.split(needle).length - 1;
}

// ======================================
// ======= 1/ Declared manifest paths ===
// ======================================

const manifestToml = TOML.parse(
	fs
		.readFileSync(path.join(SHARED, 'modules/features/manifest.toml'), 'utf8')
		.replace(
			/^\[\[features\.([^\]]+)\]\]\r?$/gm,
			(_m, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
		)
);

/**
 * Builds a predicate telling whether a path is a configuration key the driver
 * declares: one of its features, a feature table's `enabled`, or a leaf of a
 * scope's dynamic defaults.
 * @param {string} driver
 * @returns {function(string): boolean}
 */
function declaredPaths(driver) {
	const spec = DRIVER_MANIFESTS[driver];
	const text = fs.readFileSync(path.join(SP, spec.file), 'utf8');
	const features = new Map();
	for (const match of text.matchAll(spec.row)) features.set(match[1], match[2]);
	assert.ok(features.size > 100, `${driver}: the generated manifest yields its features`);
	const dynamics = [];
	for (const scope of Object.values(manifestToml.scopes))
		dynamics.push(...(scope.dynamic_defaults || []));
	return function declared(entryPath) {
		if (features.has(entryPath)) return true;
		if (entryPath.endsWith('.enabled') && features.get(entryPath.slice(0, -8)) === 'feature')
			return true;
		return dynamics.some((definition) => {
			if (!entryPath.startsWith(definition.prefix + '.')) return false;
			const parts = entryPath.slice(definition.prefix.length + 1).split('.');
			if (parts.length !== definition.depth || parts.includes('')) return false;
			return !definition.suffix || parts[parts.length - 1] === definition.suffix;
		});
	};
}

// ======================================
// ======= 2/ Minimal DOM ===============
// ======================================

/**
 * Builds a fresh page with every id declared in index.html.
 * @returns {object} Page handle.
 */
function loadPage() {
	const elements = new Map();
	const messages = [];

	function makeElement(tag, id) {
		const classes = new Set();
		const listeners = {};
		const el = {
			tagName: tag.toUpperCase(),
			id,
			textContent: '',
			value: '',
			placeholder: '',
			hidden: false,
			disabled: false,
			checked: false,
			indeterminate: false,
			type: '',
			name: '',
			src: '',
			alt: '',
			maxLength: -1,
			scrollTop: 0,
			style: {},
			dataset: {},
			children: [],
			get className() {
				return [...classes].join(' ');
			},
			set className(value) {
				classes.clear();
				String(value)
					.split(/\s+/)
					.filter(Boolean)
					.forEach((name) => classes.add(name));
			},
			classList: {
				add: (...names) => names.forEach((n) => classes.add(n)),
				remove: (...names) => names.forEach((n) => classes.delete(n)),
				toggle: (n, force) => {
					const on = force === undefined ? !classes.has(n) : !!force;
					if (on) classes.add(n);
					else classes.delete(n);
					return on;
				},
				contains: (n) => classes.has(n)
			},
			addEventListener(type, fn) {
				(listeners[type] = listeners[type] || []).push(fn);
			},
			dispatch(type) {
				(listeners[type] || []).slice().forEach((fn) => fn({ target: el }));
			},
			click() {
				el.dispatch('click');
			},
			appendChild(child) {
				el.children.push(child);
				return child;
			},
			set innerHTML(_) {
				el.children = [];
			},
			get innerHTML() {
				return '';
			},
			querySelectorAll(selector) {
				const wanted = selector.split('.').filter(Boolean);
				const out = [];
				(function walk(node) {
					node.children.forEach((child) => {
						if (wanted.every((n) => child.classList.contains(n))) out.push(child);
						walk(child);
					});
				})(el);
				return out;
			},
			querySelector(selector) {
				return el.querySelectorAll(selector)[0] || null;
			},
			scrollIntoView() {},
			focus() {}
		};
		return el;
	}

	for (const match of html.matchAll(/<(\w+)([^>]*)\sid="([^"]+)"([^>]*)>/g)) {
		const el = makeElement(match[1], match[3]);
		const attributes = match[2] + ' ' + match[4];
		const classMatch = attributes.match(/class="([^"]*)"/);
		if (classMatch) el.className = classMatch[1];
		el.checked = /\schecked(\s|$|\/)/.test(attributes);
		elements.set(match[3], el);
	}

	const document = {
		readyState: 'complete',
		title: '',
		getElementById: (id) => elements.get(id) || null,
		createElement: (tag) => makeElement(tag, ''),
		addEventListener() {}
	};
	const window = {
		webkit: {
			messageHandlers: {
				hsOnboarding: { postMessage: (m) => messages.push(JSON.parse(JSON.stringify(m))) }
			}
		}
	};
	const context = vm.createContext({ console, window, document, JSON });
	vm.runInContext(hostBridge, context);
	vm.runInContext(catalogueScript, context);
	vm.runInContext(source, context);
	return {
		window,
		document,
		elements,
		messages,
		el: (id) => elements.get(id),
		click: (id) => elements.get(id).click()
	};
}

/**
 * The catalogue the page renders.
 * @returns {object}
 */
function catalogue() {
	const sandbox = { window: {} };
	vm.runInNewContext(catalogueScript, sandbox);
	return JSON.parse(JSON.stringify(sandbox.window.ONBOARDING_CATALOGUE));
}

const CATALOGUE = catalogue();

/**
 * Loads the page and performs the host's initData handshake.
 * @param {object} [extra] Extra initData fields.
 * @returns {object} Page handle.
 */
function openWizard(extra) {
	const page = loadPage();
	assert.deepEqual(page.messages.splice(0), [{ action: 'ready' }]);
	page.window.initData(
		Object.assign(
			{
				locale: 'en',
				strings: locale('en'),
				default_config_dir: '/Volumes/Fixture/me/.config/ergopti_plus/',
				locales: [
					{ code: 'en', flag: '', name: 'English' },
					{ code: 'fr', flag: '', name: 'Français' }
				],
				config_dir: '',
				current: {},
				metrics_path: '/Volumes/Fixture/me/.config/ergopti_plus/metrics',
				platform: 'macos'
			},
			extra || {}
		)
	);
	return page;
}

/**
 * Advances with Next the given number of times.
 * @param {object} page
 * @param {number} count
 */
function next(page, count) {
	for (let i = 0; i < count; i++) page.click('btn-next');
}

/**
 * Walks from the language step to the configuration page with the given id.
 * @param {object} page
 * @param {string} id
 */
function goToPage(page, id) {
	next(page, 2 + APPROVED_ORDER.indexOf(id));
	assert.equal(page.el('page-title').textContent, locale('en')[pageOf(page, id).title_key]);
}

/**
 * The catalogue page of the open wizard's platform.
 * @param {object} page
 * @param {string} id
 * @returns {object}
 */
function pageOf(page, id) {
	const platform = page.platform || 'macos';
	return CATALOGUE.platforms[platform].pages.find((candidate) => candidate.id === id);
}

/**
 * Answers the visible question.
 * @param {object} page
 * @param {boolean} yes
 */
function answer(page, yes) {
	page.el('page-yes').checked = yes;
	page.el('page-no').checked = !yes;
	page.el(yes ? 'page-yes' : 'page-no').dispatch('change');
}

/**
 * Clicks Next until the wizard posts its finish message, and returns it.
 * @param {object} page
 * @returns {object}
 */
function finish(page) {
	page.messages.splice(0);
	for (let guard = 0; guard < 20; guard++) {
		page.click('btn-next');
		const done = page.messages.find((m) => m.action === 'finish');
		if (done) return done;
	}
	throw new Error('the wizard never finished');
}

/**
 * Every checkbox row under the checklist body, with its label.
 * @param {object} page
 * @returns {Array<{text: string, box: object}>}
 */
function checkRows(page) {
	return page
		.el('page-checklist-body')
		.querySelectorAll('check-row')
		.map((row) => ({ text: row.children[1].textContent, box: row.children[0] }));
}

/**
 * Toggles one checkbox row.
 * @param {{box: object}} row
 */
function toggle(row) {
	row.box.checked = !row.box.checked;
	row.box.dispatch('change');
}

/**
 * Every path a platform's catalogue lets the wizard write.
 * @param {string} driver
 * @returns {Set<string>}
 */
function cataloguePaths(driver) {
	const paths = new Set();
	for (const page of CATALOGUE.platforms[driver].pages) {
		if (page.master) paths.add(page.master.path);
		if (page.magic_key) paths.add(page.magic_key.path);
		(function walk(groups) {
			for (const group of groups) {
				if (group.path) paths.add(group.path);
				(group.items || []).forEach((item) => paths.add(item.path));
				walk(group.groups || []);
			}
		})(page.groups);
	}
	return paths;
}

// ======================================
// ======= 3/ Pages and defaults ========
// ======================================

(function everyScopeHasAPageInTheApprovedOrder() {
	const scopes = Object.keys(manifestToml.scopes).filter((scope) => scope !== 'global');
	assert.deepEqual([...scopes].sort(), [...APPROVED_ORDER].sort(), 'the wizard covers every scope');
	assert.deepEqual(manifestToml.onboarding.order, APPROVED_ORDER);
	assert.deepEqual(CATALOGUE.order, APPROVED_ORDER);
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		const pages = CATALOGUE.platforms[driver].pages.map((page) => page.id);
		assert.deepEqual(pages, APPROVED_ORDER, `${driver}: one page per scope, in order`);
		const page = openWizard({ platform: driver });
		assert.equal(
			page.el('step-bar').children.length,
			2 + APPROVED_ORDER.length,
			`${driver}: language, folder, then one dot per page`
		);
	}
})();

(function everyQuestionStartsAtNo() {
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		const page = openWizard({ platform: driver });
		page.platform = driver;
		next(page, 2);
		let asked = 0;
		for (const id of APPROVED_ORDER) {
			const described = pageOf(page, id);
			const asks = !!described.master || described.groups.length > 0;
			assert.equal(page.el('page-question').classList.contains('hidden'), !asks, `${driver}/${id}`);
			if (asks) {
				asked += 1;
				assert.equal(page.el('page-no').checked, true, `${driver}/${id} starts at No`);
				assert.equal(page.el('page-yes').checked, false, `${driver}/${id} is not pre-answered`);
				for (const row of checkRows(page)) {
					assert.equal(row.box.checked, false, `${driver}/${id}: ${row.text} unchecked while No`);
					assert.equal(row.box.disabled, true, `${driver}/${id}: ${row.text} inactive while No`);
				}
			}
			page.click('btn-next');
		}
		assert.ok(asked >= 5, `${driver}: most pages ask their question`);
		const done = page.messages.find((m) => m.action === 'finish');
		assert.ok(done, `${driver}: the last page finishes`);
		const masters = CATALOGUE.platforms[driver].pages
			.filter((p) => p.master)
			.map((p) => p.master.path);
		assert.deepEqual(
			done.answers.operations,
			masters.map((master) => ({ path: master, value: false })),
			`${driver}: declining everything writes each category switch off and nothing else`
		);
	}
})();

(function emittedKeysAreManifestPaths() {
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		const declared = declaredPaths(driver);
		const allowed = cataloguePaths(driver);
		assert.ok(allowed.size > 10, `${driver}: the catalogue lists paths`);
		for (const entryPath of allowed) {
			assert.ok(
				declared(entryPath),
				`${driver}: ${entryPath} is declared by the driver's manifest`
			);
		}
		const page = openWizard({ platform: driver });
		page.platform = driver;
		next(page, 2);
		for (const id of APPROVED_ORDER) {
			if (!page.el('page-question').classList.contains('hidden')) answer(page, true);
			page.click('btn-next');
		}
		const done = page.messages.find((m) => m.action === 'finish');
		assert.ok(
			done.answers.operations.length > APPROVED_ORDER.length,
			`${driver}: Yes everywhere imports items`
		);
		const seen = new Set();
		for (const operation of done.answers.operations) {
			assert.deepEqual(Object.keys(operation).sort(), ['path', 'value']);
			assert.ok(allowed.has(operation.path), `${driver}: ${operation.path} is a wizard path`);
			assert.ok(declared(operation.path), `${driver}: ${operation.path} is a manifest path`);
			assert.ok(!seen.has(operation.path), `${driver}: ${operation.path} is written once`);
			seen.add(operation.path);
		}
	}
})();

(function yesImportsExactlyTheRecommendedItems() {
	const page = openWizard({ platform: 'windows' });
	page.platform = 'windows';
	goToPage(page, 'shortcuts');
	const described = pageOf(page, 'shortcuts');
	answer(page, true);
	const rows = checkRows(page);
	const items = described.groups[0].items;
	assert.equal(rows.length, items.length, 'one row per recommended shortcut');
	assert.ok(
		rows.every((row) => row.box.checked && !row.box.disabled),
		'Yes pre-checks every recommendation'
	);
	// A slot row names the chord and the action it imports.
	const slot = items.find((item) => item.path === 'shortcuts.keyboard.win_a');
	assert.ok(slot, 'Win + A is a recommended keyboard slot');
	const slotRow = rows[items.indexOf(slot)];
	assert.equal(slotRow.text, 'Win + A → ' + locale('en')[slot.value_label.key]);
	toggle(slotRow);
	const done = finish(page);
	const imported = done.answers.operations.filter((operation) =>
		operation.path.startsWith('shortcuts.')
	);
	assert.equal(
		imported.length,
		items.length - 1,
		'every checked item is imported, the unchecked one is not'
	);
	for (const item of items) {
		const operation = imported.find((candidate) => candidate.path === item.path);
		if (item === slot) assert.equal(operation, undefined);
		else assert.deepEqual(operation, { path: item.path, value: item.value });
	}
	assert.deepEqual(
		done.answers.operations.find((operation) => operation.path === 'category_enabled.shortcuts'),
		{ path: 'category_enabled.shortcuts', value: true }
	);
})();

(function macosScriptControlLabelsFillTheirPlaceholder() {
	const page = openWizard({ platform: 'macos' });
	page.platform = 'macos';
	goToPage(page, 'shortcuts');
	answer(page, true);
	const texts = checkRows(page).map((row) => row.text);
	const expected = locale('en')
		['menu.shortcuts.right_opt_return'].split('%s')
		.join(locale('en')['sg_actions.script_pause_toggle']);
	assert.ok(texts.includes(expected), 'the action fills the %s of the slot label');
	assert.ok(
		texts.every((text) => !text.includes('%s')),
		'no row shows a raw placeholder'
	);
})();

(function consentIsNeverPreSelected() {
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		const metrics = CATALOGUE.platforms[driver].pages.find((page) => page.id === 'metrics');
		assert.equal(metrics.consent, true, `${driver}: metrics is a consent page`);
		assert.equal(metrics.groups.length, 0, `${driver}: metrics imports nothing but its consent`);
		const llm = CATALOGUE.platforms[driver].pages.find((page) => page.id === 'llm');
		assert.ok(llm.master && llm.groups.length === 0, `${driver}: the AI page only enables AI`);
	}
	const page = openWizard();
	goToPage(page, 'metrics');
	assert.equal(
		page.el('page-no').checked,
		true,
		'metrics starts at No although the manifest recommends it'
	);
	assert.equal(
		page.el('page-consent').classList.contains('hidden'),
		false,
		'the consent text is shown'
	);
})();

(function informationalPagesAskNothing() {
	const page = openWizard({ platform: 'macos' });
	page.platform = 'macos';
	goToPage(page, 'keyboard_layout');
	assert.equal(page.el('page-question').classList.contains('hidden'), true);
	assert.equal(
		page.el('page-note').textContent,
		locale('en')['onboarding.page.keyboard_layout.system_note']
	);
	assert.equal(page.el('page-checklist').classList.contains('hidden'), true);
})();

// ======================================
// ======= 4/ Hotstrings ================
// ======================================

(function hotstringsGroupLanguageFileSection() {
	const page = openWizard({ platform: 'linux' });
	page.platform = 'linux';
	goToPage(page, 'hotstrings');
	const described = pageOf(page, 'hotstrings');
	assert.equal(described.master, undefined, 'Linux has no hotstring category switch');
	assert.equal(
		page.el('page-question').classList.contains('hidden'),
		false,
		'the import question is still asked'
	);
	assert.ok(described.groups.length >= 2, 'the neutral categories, then each language pack');
	assert.equal(described.groups[0].label[0].key, 'onboarding.hotstrings.all_languages');
	assert.ok(
		described.groups[1].label[0].text.includes('Français'),
		'a language pack is named by its locale'
	);
	assert.ok(described.groups.every((group) => group.select_all === true && !group.path));
	for (const language of described.groups) {
		for (const file of language.groups) {
			assert.ok(
				file.path.startsWith('hotstrings.groups.'),
				'each file is gated by its group switch'
			);
			assert.ok(file.items.length > 0, file.path + ' lists its sections');
		}
	}
	answer(page, true);
	// The whole-language checkbox selects every section of the pack.
	const french = described.groups[1];
	const frenchRow = checkRows(page).find((row) => row.text === french.label[0].text);
	assert.ok(frenchRow, 'the language pack has its own checkbox');
	toggle(frenchRow);
	const done = finish(page);
	const operations = done.answers.operations;
	for (const file of french.groups) {
		assert.ok(
			operations.some((op) => op.path === file.path && op.value === true),
			file.path + ' switched on'
		);
		for (const item of file.items) {
			assert.ok(
				operations.some((op) => op.path === item.path && op.value === true),
				item.path + ' imported'
			);
		}
	}
	assert.ok(
		operations.some((op) => op.path === 'hotstrings.trigger_char'),
		'a Yes also sets the trigger character'
	);
})();

(function triggerLengthMatchesTheConfigurationSchema() {
	// config.schema.json is what the Windows boot validator enforces: a longer
	// wizard answer is saved, then stops the driver at every start.
	const schema = JSON.parse(
		fs.readFileSync(path.join(SHARED, 'core/config_schema/config.schema.json'), 'utf8')
	);
	const limit = schema.$defs.hotstrings.properties.trigger_char.maxLength;
	assert.ok(Number.isInteger(limit) && limit >= 1, 'the schema bounds the trigger character');
	let checked = 0;
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		for (const page of CATALOGUE.platforms[driver].pages) {
			if (!page.magic_key) continue;
			checked += 1;
			assert.equal(
				page.magic_key.max_characters,
				limit,
				`${driver}/${page.id}: the wizard accepts exactly what the configuration schema accepts`
			);
		}
	}
	assert.equal(checked, Object.keys(DRIVER_MANIFESTS).length, 'every driver asks for the trigger');
})();

(function magicKeyFollowsTheSystemLayoutAndRefusesAnEmptyCustomValue() {
	const page = openWizard({ platform: 'macos', system_layout: 'French - PC' });
	page.platform = 'macos';
	goToPage(page, 'hotstrings');
	answer(page, true);
	const options = page.el('page-magic-options');
	const checked = options.children.find((row) => row.children[0].checked);
	assert.equal(checked.children[0].value, 'ù', 'French layouts propose ù');
	const custom = options.children[options.children.length - 1];
	custom.children[0].checked = true;
	custom.children[0].dispatch('change');
	const input = page.el('page-magic-options').querySelector('magic-input');
	const hotstrings = CATALOGUE.platforms.macos.pages.find(
		(described) => described.id === 'hotstrings'
	);
	assert.equal(
		input.maxLength,
		hotstrings.magic_key.max_characters,
		'the custom trigger length comes from the manifest the hosts validate against'
	);
	input.value = '  ';
	input.dispatch('input');
	page.messages.splice(0);
	page.click('btn-next');
	assert.equal(
		page.el('page-title').textContent,
		locale('en')['menu.hotstrings.title'],
		'an empty custom key blocks Next'
	);
	assert.ok(input.classList.contains('invalid'));
	input.value = '§';
	input.dispatch('input');
	const done = finish(page);
	assert.deepEqual(
		done.answers.operations.find((op) => op.path === 'hotstrings.trigger_char'),
		{ path: 'hotstrings.trigger_char', value: '§' }
	);
})();

// ======================================
// ======= 5/ Re-run from the menu ======
// ======================================

(function aRerunShowsAndKeepsTheValuesInForce() {
	const described = CATALOGUE.platforms.macos.pages.find((page) => page.id === 'gestures');
	const items = described.groups[0].items;
	const custom = items[0];
	const kept = items[1];
	const current = { 'gestures.enabled': true, [kept.path]: kept.value, [custom.path]: 'tab_close' };
	const page = openWizard({ platform: 'macos', current });
	page.platform = 'macos';
	goToPage(page, 'gestures');
	assert.equal(page.el('page-yes').checked, true, 'the switch shows the value in force');
	const rows = checkRows(page);
	assert.equal(rows[items.indexOf(kept)].box.checked, true, 'an imported item shows checked');
	assert.equal(
		rows[items.indexOf(custom)].box.checked,
		false,
		'a customised slot is not the recommendation'
	);
	assert.ok(
		rows.filter((row) => row.box.checked).length === 1,
		'nothing else is pre-checked on a re-run'
	);
	const done = finish(page);
	const gestures = done.answers.operations.filter((op) => op.path.startsWith('gestures.'));
	assert.deepEqual(
		gestures,
		[{ path: 'gestures.enabled', value: true }],
		'an untouched page rewrites only its switch'
	);
})();

(function uncheckingAnImportedItemRestoresItsNeutralValue() {
	const described = CATALOGUE.platforms.macos.pages.find((page) => page.id === 'gestures');
	const item = described.groups[0].items[0];
	const page = openWizard({
		platform: 'macos',
		current: { 'gestures.enabled': true, [item.path]: item.value }
	});
	page.platform = 'macos';
	goToPage(page, 'gestures');
	toggle(checkRows(page)[0]);
	const done = finish(page);
	assert.deepEqual(
		done.answers.operations.find((op) => op.path === item.path),
		{ path: item.path, value: item.default }
	);
})();

(function aFolderWithItsOwnConfigurationRestartsThePages() {
	const page = openWizard({ platform: 'macos' });
	page.platform = 'macos';
	page.click('btn-next');
	page.window.setConfigDir('/Volumes/Other/');
	page.messages.splice(0);
	page.click('btn-next');
	const request = page.messages.find((m) => m.action === 'loadExistingConfig');
	assert.deepEqual(request, {
		action: 'loadExistingConfig',
		config_dir: '/Volumes/Other/',
		request: 1
	});
	page.window.applyCurrentValues({ request: 0, values: { 'tap_holds.enabled': true } });
	assert.equal(page.el('page-no').checked, true, 'a stale reply is dropped');
	page.window.applyCurrentValues({ request: 1, values: { 'tap_holds.enabled': true } });
	assert.equal(page.el('page-yes').checked, true, 'the chosen folder answers for its pages');
	// Returning to the same folder does not reload it over the user's answers.
	answer(page, false);
	page.click('btn-back');
	page.messages.splice(0);
	page.click('btn-next');
	assert.equal(page.messages.filter((m) => m.action === 'loadExistingConfig').length, 0);
	assert.equal(page.el('page-no').checked, true, 'the answer survives a back-and-forth');
})();

// ======================================
// ======= 6/ Window title ==============
// ======================================

(function titleFollowsTheSelectedLanguage() {
	const page = openWizard();
	assert.equal(
		page.document.title,
		locale('en')['onboarding.welcome.title'],
		'title at open uses the current locale'
	);

	const frRow = page.el('lang-list').children.find((row) => row.dataset.code === 'fr');
	assert.ok(frRow, 'the injected locale list renders a French row');
	frRow.click();
	assert.deepEqual(page.messages.splice(0), [{ action: 'previewLocale', locale: 'fr' }]);
	page.window.applyStrings({ locale: 'fr', strings: locale('fr') });
	assert.equal(
		page.document.title,
		locale('fr')['onboarding.welcome.title'],
		'title follows the previewed locale'
	);
	assert.equal(page.el('language-title').textContent, locale('fr')['onboarding.welcome.title']);

	// A stale reply for a locale the user already left must not retitle the page.
	page.window.applyStrings({ locale: 'en', strings: locale('en') });
	assert.equal(
		page.document.title,
		locale('fr')['onboarding.welcome.title'],
		'stale locale replies are ignored'
	);

	page.click('btn-next');
	assert.deepEqual(page.messages.splice(0), [{ action: 'localeSelected', locale: 'fr' }]);
	page.window.applyStrings({ locale: 'fr', strings: locale('de') });
	assert.equal(page.document.title, locale('de')['onboarding.welcome.title']);
})();

(function everyLocaleNamesTheProductOnce() {
	const codes = fs
		.readdirSync(LOCALE_DIR)
		.filter((n) => n.endsWith('.json'))
		.map((n) => n.slice(0, -5));
	assert.equal(codes.length, 21, 'all 21 locales are checked');
	for (const code of codes) {
		const strings = locale(code);
		const heading = strings['onboarding.welcome.title'];
		const windowTitle = strings['onboarding.window_title'];
		assert.equal(
			occurrences(heading, PRODUCT),
			1,
			code + ': the page title names the product once'
		);
		assert.equal(typeof windowTitle, 'string', code + ': onboarding.window_title exists');
		assert.equal(
			occurrences(windowTitle, 'Ergopti'),
			0,
			code + ': the native title key is brand-less'
		);
		assert.equal(occurrences(PRODUCT + ' — ' + windowTitle, PRODUCT), 1, code + ': composed title');
	}
	assert.equal(
		occurrences(html.match(/<title>([^<]*)<\/title>/)[1], PRODUCT),
		1,
		'static <title> names the product once'
	);
})();

(function everyStringThePageReadsIsTranslated() {
	const keys = new Set();
	for (const match of source.matchAll(/_t\('([^']+)'\)/g)) keys.add(match[1]);
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		for (const page of CATALOGUE.platforms[driver].pages) {
			for (const field of [
				'title_key',
				'question_key',
				'description_key',
				'hint_key',
				'note_key'
			]) {
				if (page[field]) keys.add(page[field]);
			}
		}
	}
	assert.ok(keys.size > 30, 'the scan finds the page strings');
	for (const code of fs.readdirSync(LOCALE_DIR).filter((n) => n.endsWith('.json'))) {
		const strings = locale(code.slice(0, -5));
		for (const key of keys) {
			assert.equal(typeof strings[key], 'string', `${code}: ${key}`);
			assert.notEqual(strings[key], '', `${code}: ${key} is empty`);
		}
	}
})();

// ======================================
// ======= 7/ Native folder picker ======
// ======================================

(function pickedFolderFillsTheFieldAndTheAnswers() {
	const page = openWizard();
	page.click('btn-next');
	const input = page.el('config-input');
	assert.equal(input.value, '', 'the field starts empty over the default');
	assert.equal(input.placeholder, '/Volumes/Fixture/me/.config/ergopti_plus/');
	page.messages.splice(0);

	page.click('config-browse');
	assert.deepEqual(page.messages.splice(0), [{ action: 'pickConfigDir', current: '' }]);

	page.window.setConfigDir('/Volumes/Fixture/me/Ergopti Data/');
	assert.equal(
		input.value,
		'/Volumes/Fixture/me/Ergopti Data/',
		'the chosen folder is written into the field'
	);

	// A locale switch re-renders the step from the answers, not from the DOM.
	page.window.applyStrings({ locale: 'en', strings: locale('en') });
	assert.equal(
		input.value,
		'/Volumes/Fixture/me/Ergopti Data/',
		'the chosen folder survives a re-render'
	);

	const done = finish(page);
	assert.equal(
		done.answers.config_dir,
		'/Volumes/Fixture/me/Ergopti Data/',
		'the finish payload uses the chosen folder'
	);
	assert.equal(done.answers.locale, 'en');
})();

(function cancelledPickerLeavesTheFieldAlone() {
	const page = openWizard();
	page.click('btn-next');
	const input = page.el('config-input');
	input.value = '/typed/by/hand';
	page.window.setConfigDir('');
	page.window.setConfigDir(null);
	assert.equal(input.value, '/typed/by/hand');
})();

(function backFromThePagesKeepsThePickedFolder() {
	const page = openWizard();
	page.click('btn-next');
	page.window.setConfigDir('/picked/');
	page.click('btn-next');
	page.click('btn-back');
	assert.equal(page.el('config-input').value, '/picked/');
})();

// ======================================
// ======= 8/ Metrics consent path ======
// ======================================

/**
 * Advances from the config step to the metrics page.
 * @param {object} page
 */
function advanceToMetrics(page) {
	next(page, APPROVED_ORDER.length);
	assert.equal(page.el('page-title').textContent, locale('en')['menu.metrics.title']);
}

(function consentNamesTheInitialStore() {
	const page = openWizard();
	page.click('btn-next');
	advanceToMetrics(page);
	const warning = page.el('page-consent').textContent;
	assert.ok(warning.includes('/Volumes/Fixture/me/.config/ergopti_plus/metrics'), warning);
	assert.ok(!warning.includes('{1}'), 'the placeholder is filled');
})();

(function consentFollowsTheChosenFolder() {
	const page = openWizard();
	page.click('btn-next');
	page.window.setConfigDir('/Volumes/Data/Ergopti/');
	page.messages.splice(0);
	page.click('btn-next');
	const request = page.messages.find((m) => m.action === 'resolveMetricsPath');
	assert.deepEqual(request, {
		action: 'resolveMetricsPath',
		config_dir: '/Volumes/Data/Ergopti/',
		request: 1
	});
	page.window.setMetricsPath({ request: 1, path: '/Volumes/Data/Ergopti/metrics' });
	next(page, APPROVED_ORDER.length - 1);
	const warning = page.el('page-consent').textContent;
	assert.ok(warning.includes('/Volumes/Data/Ergopti/metrics'), warning);
	assert.ok(
		!warning.includes('/Volumes/Fixture/me/.config/ergopti_plus/metrics'),
		'the default store is no longer named'
	);
})();

(function consentUpdatesWhenTheReplyArrivesOnTheMetricsPage() {
	const page = openWizard();
	page.click('btn-next');
	page.el('config-input').value = '/late/';
	advanceToMetrics(page);
	page.window.setMetricsPath({ request: 1, path: '/late/metrics' });
	assert.ok(
		page.el('page-consent').textContent.includes('/late/metrics'),
		'the visible page re-renders'
	);
})();

(function goingBackAndChangingTheFolderIsLive() {
	const page = openWizard();
	page.click('btn-next');
	page.window.setConfigDir('/first/');
	page.click('btn-next');
	page.window.setMetricsPath({ request: 1, path: '/first/metrics' });
	page.click('btn-back');
	page.window.setConfigDir('/second/');
	page.messages.splice(0);
	page.click('btn-next');
	assert.equal(page.messages.find((m) => m.action === 'resolveMetricsPath').request, 2);
	// The late reply for the first folder must not overwrite the second one.
	page.window.setMetricsPath({ request: 2, path: '/second/metrics' });
	page.window.setMetricsPath({ request: 1, path: '/first/metrics' });
	next(page, APPROVED_ORDER.length - 1);
	const warning = page.el('page-consent').textContent;
	assert.ok(warning.includes('/second/metrics'), warning);
	assert.ok(!warning.includes('/first/metrics'), 'a stale reply is dropped');
})();

(function consentFollowsALanguageSwitch() {
	const page = openWizard({ metrics_path: '/m' });
	page.click('btn-next');
	advanceToMetrics(page);
	page.window.applyStrings({ locale: 'en', strings: locale('fr') });
	const expected = locale('fr')['dialog.metrics.enable_warning'].split('{1}').join('/m');
	assert.equal(page.el('page-consent').textContent, expected);
})();

(function pathIsInsertedLiterally() {
	const page = openWizard({ metrics_path: "/odd/$&$'/metrics" });
	page.click('btn-next');
	advanceToMetrics(page);
	assert.ok(
		page.el('page-consent').textContent.includes("/odd/$&$'/metrics"),
		'no replacement patterns'
	);
})();

(function malformedRepliesAreIgnored() {
	const page = openWizard({ metrics_path: '/kept' });
	page.click('btn-next');
	page.click('btn-next');
	page.window.setMetricsPath(null);
	page.window.setMetricsPath({ request: 1 });
	page.window.setMetricsPath({ request: '1', path: '/wrong' });
	next(page, APPROVED_ORDER.length - 1);
	assert.ok(page.el('page-consent').textContent.includes('/kept'));
})();

(function anUnknownPlatformIsRefused() {
	const page = loadPage();
	assert.throws(
		() => page.window.initData({ platform: 'amiga', strings: {}, current: {} }),
		/unknown platform/
	);
})();

console.log(
	'Onboarding wizard page: pages, defaults, manifest paths, re-run, title, folder and consent passed.'
);
