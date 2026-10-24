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
 *    force and writes only what the answers change. A page's sub-switch (the
 *    Windows key combinations) follows the answer its master no longer reaches.
 * 4. The Tap-Holds page lists each engine's recommended keys from the shared
 *    tap-hold catalogue; their answers name keys, never configuration paths,
 *    and only a checked key under a Yes is imported.
 * 5. The earlier regressions stay pinned: the title follows the previewed
 *    locale and names the product once, a folder picked natively reaches the
 *    payload, and the metrics consent names the store of the chosen folder.
 * 6. Every item that imports an action names its trigger, then the page's own
 *    separator element, then the action: a tap-hold key its recommended tap and
 *    hold, a shortcut its chord (wizard-checklist-labels).
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
const TAP_HOLD_DEFAULTS = TOML.parse(
	fs.readFileSync(path.join(SHARED, 'tap_hold/defaults.toml'), 'utf8')
);
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
			// As in a real DOM: an element's text is its children's, and setting it
			// replaces them.
			ownText: '',
			get textContent() {
				return this.children.length > 0
					? this.children.map((child) => child.textContent).join('')
					: this.ownText;
			},
			set textContent(value) {
				this.children = [];
				this.ownText = String(value);
			},
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

// Each host's capabilities, as the host test below checks in the host sources:
// only the Windows host registers gestures with the system.
const HOST_CAPABILITIES = {
	windows: { gesture_registration: true },
	macos: { gesture_registration: false },
	linux: { gesture_registration: false }
};

/**
 * Loads the page and performs the host's initData handshake.
 * @param {object} [extra] Extra initData fields.
 * @param {function} [prepare] Called with the page's window before initData.
 * @returns {object} Page handle.
 */
function openWizard(extra, prepare) {
	const page = loadPage();
	assert.deepEqual(page.messages.splice(0), [{ action: 'ready' }]);
	if (prepare) prepare(page.window);
	page.window.initData(
		Object.assign(
			{
				locale: 'en',
				strings: locale('en'),
				default_config_dir: '/Volumes/Fixture/me/.config/ergopti_plus/',
				empty_config_dir: '/Volumes/Fixture/me/.config/ergopti_plus/',
				locales: [
					{ code: 'en', flag: '', name: 'English' },
					{ code: 'fr', flag: '', name: 'Français' }
				],
				config_dir: '',
				current: {},
				metrics_path: '/Volumes/Fixture/me/.config/ergopti_plus/metrics',
				platform: 'macos',
				capabilities: HOST_CAPABILITIES[(extra && extra.platform) || 'macos']
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
 * Every checkbox row under the checklist body, with its label: its whole text,
 * and for a row that imports an action its trigger, separator and action spans.
 * `name` is the trigger of such a row and the whole text of any other.
 * @param {object} page
 * @returns {Array<{text: string, name: string, parts: Array<object>, box: object}>}
 */
function checkRows(page) {
	return page
		.el('page-checklist-body')
		.querySelectorAll('check-row')
		.map((row) => {
			const label = row.children[1];
			const parts = label.children;
			return {
				text: label.textContent,
				name: parts.length > 0 ? parts[0].textContent : label.textContent,
				parts,
				trigger: parts.length > 0 ? parts[0].textContent : null,
				action: parts.length > 0 ? parts[parts.length - 1].textContent : null,
				box: row.children[0]
			};
		});
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
 * Every tap-hold key item of a platform's catalogue, by answer path.
 * @param {string} driver
 * @returns {Map<string, object>}
 */
function tapHoldKeyItems(driver) {
	const items = new Map();
	for (const page of CATALOGUE.platforms[driver].pages) {
		(function walk(groups) {
			for (const group of groups) {
				(group.items || []).forEach((item) => {
					if (item.tap_hold_key !== undefined) items.set(item.path, item);
				});
				walk(group.groups || []);
			}
		})(page.groups);
	}
	return items;
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
		if (page.sub_switch) paths.add(page.sub_switch.path);
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
	const scopes = manifestToml.scopes.global.includes;
	assert.deepEqual(
		manifestToml.scopes.shortcuts.includes,
		['key_combinations'],
		'the combination scope belongs to the existing Shortcuts question'
	);
	assert.deepEqual(
		[...scopes].sort(),
		[...APPROVED_ORDER].sort(),
		'the wizard covers every root scope, including its nested scopes'
	);
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
		// Existing unsupported/Windows sub-switch behavior remains unchanged.
		// Linux's independent pair master follows its explicit No-first answer.
		const masters = CATALOGUE.platforms[driver].pages.flatMap((described) => {
			const paths = described.master ? [described.master.path] : [];
			if (driver === 'linux' && described.sub_switch) paths.push(described.sub_switch.path);
			return paths;
		});
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
		const tapHoldKeys = tapHoldKeyItems(driver);
		assert.ok(allowed.size > 10, `${driver}: the catalogue lists paths`);
		assert.ok(tapHoldKeys.size > 0, `${driver}: the catalogue lists tap-hold keys`);
		for (const entryPath of allowed) {
			// A tap-hold key goes to the driver's tap-hold writer: it must never
			// read as a configuration path a host would write to config.toml.
			assert.equal(
				declared(entryPath),
				!tapHoldKeys.has(entryPath),
				`${driver}: ${entryPath} is a manifest path exactly when it is no tap-hold key`
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
			assert.ok(
				declared(operation.path) || tapHoldKeys.has(operation.path),
				`${driver}: ${operation.path} is a manifest path or a tap-hold key`
			);
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
	assert.equal(slotRow.trigger, 'Win + A');
	assert.equal(slotRow.action, locale('en')['sg_actions.select_line']);
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

(function shortcutsAnswerWritesTheKeyCombinationsSwitch() {
	// The key combinations follow only their own switch, which the Shortcuts
	// master no longer reaches: a No must still leave them off, as it did.
	const described = CATALOGUE.platforms.windows.pages.find((p) => p.id === 'shortcuts');
	// The sections the sub-switch governs: the tap slots of the pairs that ship
	// a recommendation, the three chords the Windows driver always had.
	const families = manifestToml.onboarding.pages.shortcuts.sub_switch.ahk.sections;
	assert.deepEqual(families, ['shortcuts.key_combination_taps']);
	const items = described.groups[0].items.filter((item) =>
		families.some((family) => item.path.startsWith(family + '.'))
	);
	assert.equal(items.length, 3, 'AltGr then LAlt, AltGr then CapsLock, LAlt then CapsLock');
	assert.deepEqual(
		items.map((item) =>
			item.label.map((segment) => (segment.key ? locale('en')[segment.key] : segment.text)).join('')
		),
		['AltGr + LAlt', 'AltGr + CapsLock', 'LAlt + CapsLock'],
		'a pair is named by its two keys, the key held first then the key struck under it'
	);
	assert.deepEqual(described.sub_switch, {
		path: 'category_enabled.key_combinations',
		default: true,
		independent: false,
		items: families.flatMap((family) =>
			items.filter((item) => item.path.startsWith(family + '.')).map((item) => item.path)
		)
	});
	for (const driver of ['macos']) {
		assert.ok(
			CATALOGUE.platforms[driver].pages.every((page) => page.sub_switch === undefined),
			`${driver}: no page lists a key combination`
		);
	}
	const combinations = (operations) =>
		operations.filter((op) => op.path === 'category_enabled.key_combinations');
	const familiesOn = Object.fromEntries(items.map((item) => [item.path, item.value]));
	/**
	 * Opens the Shortcuts page over the given values in force.
	 * @param {object} current
	 * @returns {object} Page handle.
	 */
	const shortcutsOver = (current) => {
		const page = openWizard({ platform: 'windows', current });
		page.platform = 'windows';
		goToPage(page, 'shortcuts');
		return page;
	};

	const firstNo = shortcutsOver({});
	answer(firstNo, true);
	answer(firstNo, false);
	assert.deepEqual(
		combinations(finish(firstNo).answers.operations),
		[],
		'a first No over nothing in force leaves the switch absent, so a family enabled later works'
	);

	const rerunNo = shortcutsOver({ 'category_enabled.shortcuts': true, ...familiesOn });
	answer(rerunNo, false);
	assert.deepEqual(
		combinations(finish(rerunNo).answers.operations),
		[{ path: 'category_enabled.key_combinations', value: false }],
		'a No that turns Shortcuts in force off turns the key combinations off, as the master once did'
	);

	// A: the master is off, the families on and the switch absent: untouched.
	const keptOff = shortcutsOver(familiesOn);
	assert.equal(keptOff.el('page-no').checked, true);
	assert.deepEqual(
		combinations(finish(keptOff).answers.operations),
		[],
		'a page left at the No in force never switches the combinations off'
	);

	// B: the master and the families are on, the switch off in the tray.
	const keptChoice = shortcutsOver({
		'category_enabled.shortcuts': true,
		'category_enabled.key_combinations': false,
		...familiesOn
	});
	assert.equal(keptChoice.el('page-yes').checked, true);
	assert.deepEqual(
		combinations(finish(keptChoice).answers.operations),
		[],
		'a Yes that imports no new family keeps the tray choice'
	);

	const accepted = shortcutsOver({});
	answer(accepted, true);
	assert.deepEqual(
		combinations(finish(accepted).answers.operations),
		[{ path: 'category_enabled.key_combinations', value: true }],
		'a Yes that imports a family turns them on'
	);

	const without = shortcutsOver({ 'category_enabled.key_combinations': false });
	answer(without, true);
	const labels = new Set(
		items.map((item) =>
			item.label.map((segment) => (segment.key ? locale('en')[segment.key] : segment.text)).join('')
		)
	);
	// A pair's row reads « keys » then « action »: its name is the first part.
	const familyRows = checkRows(without).filter((row) => labels.has(row.name));
	assert.equal(familyRows.length, items.length, 'each family item has its row');
	familyRows.forEach(toggle);
	const operations = finish(without).answers.operations;
	assert.deepEqual(
		combinations(operations),
		[],
		'a Yes without any family leaves the switch alone'
	);
	assert.ok(
		items.every((item) => !operations.some((op) => op.path === item.path)),
		'and imports no family item'
	);
})();

(function anIndependentSubSwitchIsReadFromTheCatalogueNotThePlatform() {
	// The Windows page with its sub-switch marked independent behaves as the
	// Linux one: a first No writes the switch off. The page reads the flag.
	const page = openWizard({ platform: 'windows' }, (window) => {
		const shortcuts = window.ONBOARDING_CATALOGUE.platforms.windows.pages.find(
			(described) => described.id === 'shortcuts'
		);
		shortcuts.sub_switch.independent = true;
	});
	page.platform = 'windows';
	goToPage(page, 'shortcuts');
	answer(page, false);
	assert.deepEqual(
		finish(page).answers.operations.filter((op) => op.path === 'category_enabled.key_combinations'),
		[{ path: 'category_enabled.key_combinations', value: false }],
		'an independent sub-switch is turned off by every No'
	);
})();

(function gestureRegistrationFollowsTheHostCapability() {
	const shown = (platform, capabilities) => {
		const page = openWizard({ platform, capabilities });
		page.platform = platform;
		goToPage(page, 'gestures');
		answer(page, true);
		return !page.el('page-register').classList.contains('hidden');
	};
	for (const platform of ['windows', 'macos', 'linux'])
		assert.equal(
			shown(platform, HOST_CAPABILITIES[platform]),
			HOST_CAPABILITIES[platform].gesture_registration,
			platform + ': the registration panel follows the host capability'
		);
	assert.equal(
		shown('linux', { gesture_registration: true }),
		true,
		'the capability, not the platform name, shows the panel'
	);
	assert.equal(
		shown('windows', { gesture_registration: false }),
		false,
		'a host without the capability never shows the panel'
	);
	assert.throws(
		() => openWizard({ platform: 'windows', capabilities: undefined }),
		/gesture_registration/,
		'a host that states no capability is refused'
	);
})();

(function linuxOrderedPairsFollowTheirOwnNoFirstAnswer() {
	const described = CATALOGUE.platforms.linux.pages.find((page) => page.id === 'shortcuts');
	const families = manifestToml.onboarding.pages.shortcuts.sub_switch.linux.sections;
	assert.deepEqual(families, ['shortcuts.key_combination_taps']);
	const items = described.groups[0].items.filter((item) =>
		families.some((family) => item.path.startsWith(family + '.'))
	);
	assert.deepEqual(
		items.map((item) => [item.path, item.value]),
		[
			['shortcuts.key_combination_taps.alt_gr_then_left_alt', 'ctrl_backspace'],
			['shortcuts.key_combination_taps.alt_gr_then_caps_lock', 'ctrl_delete'],
			// Linux recommends the Windows LAlt then CapsLock CapsWord (2026-10-22).
			['shortcuts.key_combination_taps.left_alt_then_caps_lock', 'caps_word']
		]
	);
	assert.deepEqual(
		described.sub_switch.items,
		items.map((item) => item.path)
	);
	assert.equal(described.sub_switch.independent, true, 'the catalogue marks the own master');
	const open = (current = {}) => {
		const page = openWizard({ platform: 'linux', current });
		page.platform = 'linux';
		goToPage(page, 'shortcuts');
		return page;
	};
	const combinations = (page) =>
		finish(page).answers.operations.filter((op) => op.path === 'category_enabled.key_combinations');
	const firstNo = open();
	assert.equal(firstNo.el('page-no').checked, true);
	assert.deepEqual(
		combinations(firstNo),
		[{ path: 'category_enabled.key_combinations', value: false }],
		'No-first explicitly disables the independent ordered-pair owner'
	);
	const accepted = open();
	answer(accepted, true);
	assert.deepEqual(combinations(accepted), [
		{ path: 'category_enabled.key_combinations', value: true }
	]);
	const alreadyOn = Object.fromEntries(items.map((item) => [item.path, item.value]));
	const activeDespiteMasterOff = open({
		...alreadyOn,
		'shortcuts.enabled': false,
		'category_enabled.key_combinations': true
	});
	assert.deepEqual(
		combinations(activeDespiteMasterOff),
		[{ path: 'category_enabled.key_combinations', value: false }],
		'No disables current pairs even when the ordinary shortcuts master is off'
	);
	const keptTray = open({
		...alreadyOn,
		'shortcuts.enabled': true,
		'category_enabled.key_combinations': false
	});
	assert.deepEqual(
		combinations(keptTray),
		[],
		'unchanged Yes imports no pair and preserves the disabled tray switch'
	);
	const withoutPairs = open({ 'category_enabled.key_combinations': false });
	answer(withoutPairs, true);
	const names = new Set(
		items.map((item) =>
			item.label.map((segment) => (segment.key ? locale('en')[segment.key] : segment.text)).join('')
		)
	);
	const rows = checkRows(withoutPairs).filter((row) => names.has(row.name));
	assert.equal(rows.length, items.length);
	rows.forEach(toggle);
	assert.deepEqual(
		combinations(withoutPairs),
		[],
		'Yes without pair selections does not enable the pair owner'
	);
})();

(function scriptChordsAreNoWizardRows() {
	// script-chords-three-os-2026-09-30: the script chords start with their
	// preset on every driver, so the wizard has nothing of theirs to import.
	const page = openWizard({ platform: 'macos' });
	page.platform = 'macos';
	goToPage(page, 'shortcuts');
	answer(page, true);
	const rows = checkRows(page);
	const chordLabels = new Set(
		['return', 'backspace', 'delete', 'escape'].map(
			(key) => locale('en')[`sg_labels.script_ropt_${key}`]
		)
	);
	assert.ok(
		rows.every((candidate) => !chordLabels.has(candidate.trigger)),
		'no script chord is a row of the Shortcuts page'
	);
	assert.ok(
		rows.every((candidate) => !candidate.text.includes('%s')),
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
// ======= 4/ Hotstrings, Tap-Holds ===
// ======================================

(function hotstringsPageLeavesThePreviewBubblesOn() {
	// (wizard-preview-bubbles, revised by PAR-24) The four preview switches ship
	// on for every driver, Windows included, so a fresh configuration shows the
	// bubble without the wizard and the page offers no preview setting: the
	// generator refuses a setting that recommends its neutral default.
	for (const platform of ['windows', 'macos', 'linux']) {
		const described = CATALOGUE.platforms[platform].pages.find((p) => p.id === 'hotstrings');
		assert.ok(
			!JSON.stringify(described).includes('preview_'),
			platform + ': the hotstrings page offers no preview switch, they ship on'
		);
	}
})();

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
	// The last group holds the preview bubbles, settings rather than a language.
	for (const language of described.groups.filter((group) => group.groups)) {
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
	assert.deepEqual(
		described.magic_key.options.map((option) => option.value),
		['★'],
		'Linux offers only the preset its runtime accepts'
	);
	assert.equal(described.magic_key.validation, 'safe_magic_key');
	assert.ok(
		!operations.some((op) => op.path === 'hotstrings.trigger_char'),
		'the default trigger is sparse until the user changes it'
	);
})();

/**
 * The keys an engine ships a recommendation for, in the order of its column of
 * the shared key catalogue: Windows and Linux read [tap_hold.keys.*], macOS its
 * Karabiner slots, where a key whose tap and hold are both "none" has none.
 * @param {string} driver
 * @returns {Array<{id: string, hand: string, label_key: string}>}
 */
function recommendedTapHoldKeys(driver) {
	const platform = { windows: 'ahk', macos: 'hs', linux: 'linux' }[driver];
	const preset =
		platform === 'hs'
			? Object.keys(TAP_HOLD_DEFAULTS.hs_tap_hold).filter((key) => {
					const slots = TAP_HOLD_DEFAULTS.hs_tap_hold[key];
					return slots.tap !== 'none' || slots.hold !== 'none';
				})
			: Object.keys(TAP_HOLD_DEFAULTS.tap_hold.keys);
	return TAP_HOLD_DEFAULTS.tap_hold.catalog.keys
		.filter((entry) => entry[platform] !== undefined && preset.includes(entry[platform]))
		.map((entry) => ({ id: entry[platform], hand: entry.hand, label_key: entry.label_key }));
}

(function tapHoldPagesListEachEngineRecommendedKeys() {
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		const described = CATALOGUE.platforms[driver].pages.find((p) => p.id === 'tap_holds');
		const expected = recommendedTapHoldKeys(driver);
		assert.ok(expected.length >= 7, `${driver}: the engine recommends its tap-hold keys`);
		const items = described.groups
			.flatMap((group) => group.items)
			.map(({ value_label: _assignment, ...item }) => item);
		assert.deepEqual(
			items,
			expected.map((key) => ({
				path: 'tap_holds.keys.' + key.id,
				value: true,
				default: false,
				recommended: true,
				tap_hold_key: key.id,
				customised_value: 'customised',
				label: [{ key: key.label_key }]
			})),
			`${driver}: one item per recommended key, in tray order, named by the catalogue`
		);
		assert.deepEqual(
			described.groups.map((group) => group.label),
			[
				[{ key: 'menu.tapholds.left_hand_tap_hold' }],
				[{ key: 'menu.tapholds.right_hand_tap_hold' }]
			],
			`${driver}: the keys are grouped under the tray's hand headers`
		);
		for (const [index, group] of described.groups.entries()) {
			const hand = index === 0 ? 'left' : 'right';
			assert.ok(
				group.items.every(
					(item) => expected.find((key) => key.id === item.tap_hold_key).hand === hand
				),
				`${driver}: each key sits under its own hand`
			);
		}
		assert.equal(
			described.note_key,
			undefined,
			`${driver}: the page asks instead of pointing away`
		);
		const page = openWizard({ platform: driver });
		next(page, 2);
		assert.equal(page.el('page-question').classList.contains('hidden'), false, `${driver} asks`);
		assert.equal(page.el('page-checklist').classList.contains('hidden'), false, `${driver} lists`);
	}
	// macOS reads the switch from config_karabiner.toml and Linux from
	// tap_hold.toml: there the import switches the Tap-Holds on, never config.toml.
	for (const driver of ['macos', 'linux']) {
		const described = CATALOGUE.platforms[driver].pages.find((p) => p.id === 'tap_holds');
		assert.equal(described.master, undefined, `${driver}: no config.toml tap-hold switch`);
		assert.ok(!cataloguePaths(driver).has('tap_holds.enabled'), `${driver}: no config.toml row`);
		assert.deepEqual(
			described.state,
			{ path: 'tap_holds.enabled', default: false },
			`${driver}: the question starts from the switch its host reports`
		);
	}
	const windows = CATALOGUE.platforms.windows.pages.find((p) => p.id === 'tap_holds');
	assert.equal(windows.master.path, 'category_enabled.tap_holds', 'Windows reads its switch there');
})();

/**
 * The English label of a tap and of a hold an engine ships for one key, as its
 * tray names them: Windows and Linux through the action registry and the hold
 * picker, macOS through its Karabiner actions (registry label under the
 * Karabiner alias, else the catalogue's short label).
 * @param {string} driver
 * @param {string} key The key's id on the driver.
 * @returns {{tap: string, hold: string}}
 */
function expectedTapHold(driver, key) {
	const en = locale('en');
	if (driver === 'macos') {
		const aliases = TOML.parse(
			fs.readFileSync(path.join(SHARED, 'modules/actions/actions.toml'), 'utf8')
		).karabiner_aliases;
		const karabiner = JSON.parse(
			fs.readFileSync(path.join(SP, 'macos/platform/remap/data/actions.json'), 'utf8')
		);
		const name = (action) =>
			en['sg_actions.' + (aliases[action] || action)] ||
			karabiner.find((entry) => entry.id === action).short_label;
		const slots = TAP_HOLD_DEFAULTS.hs_tap_hold[key];
		return { tap: name(slots.tap), hold: name(slots.hold) };
	}
	const preset = TAP_HOLD_DEFAULTS.tap_hold.keys[key];
	const tap = preset.tap_action ? en['sg_actions.' + preset.tap_action] : en['tap_hold.tap.none'];
	let hold = en['tap_hold.hold.none'];
	if (preset.hold_layer) hold = en['tap_hold.hold.' + preset.hold_layer + '_layer'];
	else if (preset.hold_modifier) {
		hold = preset.hold_modifier
			.split('+')
			.map((modifier) => en['tap_hold.hold.' + modifier])
			.join(' + ');
	}
	return { tap, hold };
}

/**
 * Asserts a row draws its trigger, the separator element, then its action.
 * @param {object} row From checkRows.
 * @param {string} where Assertion context.
 */
function assertSeparated(row, where) {
	assert.deepEqual(
		row.parts.map((part) => part.className),
		['item-trigger', 'value-separator', 'item-action'],
		`${where}: trigger, separator element, action`
	);
	assert.equal(row.parts[1].textContent.trim(), CATALOGUE.value_separator, `${where}: separator`);
	for (const text of [row.trigger, row.action]) {
		assert.ok(!text.includes(CATALOGUE.value_separator), `${where}: no label shows the separator`);
		assert.ok(!text.includes('%s'), `${where}: no label shows a raw placeholder`);
	}
	assert.ok(!row.trigger.includes(' → '), `${where}: the trigger spells no separator of its own`);
}

(function tapHoldItemsShowTheirRecommendedTapAndHold() {
	// wizard-checklist-labels: the list named only the keys, never what each one
	// would do once imported.
	const en = locale('en');
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		const page = openWizard({ platform: driver });
		page.platform = driver;
		goToPage(page, 'tap_holds');
		answer(page, true);
		const rows = checkRows(page);
		const keys = [...tapHoldKeyItems(driver).values()];
		assert.ok(keys.length >= 7, `${driver}: recommended keys are listed`);
		for (const item of keys) {
			const row = rows.find((candidate) => candidate.name === en[item.label[0].key]);
			assert.ok(row, `${driver}: ${item.tap_hold_key} has its row`);
			assertSeparated(row, `${driver}/${item.tap_hold_key}`);
			const { tap, hold } = expectedTapHold(driver, item.tap_hold_key);
			assert.equal(
				row.action,
				en['onboarding.checklist.tap_hold'].split('{1}').join(tap).split('{2}').join(hold),
				`${driver}: ${item.tap_hold_key} shows the tap and the hold it imports`
			);
		}
	}
	const macTab = checkRows(
		(() => {
			const page = openWizard({ platform: 'macos' });
			goToPage(page, 'tap_holds');
			answer(page, true);
			return page;
		})()
	).find((row) => row.name === 'Tab');
	assert.equal(macTab.action, 'tap: ◱ Previous window — all screens · hold: Fn');
	const winCaps = checkRows(
		(() => {
			const page = openWizard({ platform: 'windows' });
			page.platform = 'windows';
			goToPage(page, 'tap_holds');
			answer(page, true);
			return page;
		})()
	).find((row) => row.name === 'CapsLock');
	assert.equal(winCaps.action, 'tap: ↵ Enter · hold: Ctrl');
})();

(function shortcutItemsShowTheirChordBeforeTheAction() {
	// wizard-checklist-labels: the macOS built-in shortcuts listed only what they
	// do, never the key combination they are bound to.
	const en = locale('en');
	const page = openWizard({ platform: 'macos' });
	page.platform = 'macos';
	goToPage(page, 'shortcuts');
	answer(page, true);
	const rows = checkRows(page);
	const row = (trigger) => rows.find((candidate) => candidate.trigger === trigger);
	const expected = {
		'Cmd + Shift + V': en['shortcuts.label_cmd_shift_v'],
		'Ctrl + A': en['shortcuts.label_ctrl_a'],
		'Ctrl + E': en['shortcuts.label_ctrl_e'],
		'Ctrl + .': en['shortcuts.label_ctrl_period'],
		'Ctrl + CapsLock': en['shortcuts.label_ctrl_capslock'],
		'Ctrl + Space': en['sg_actions.llm_generate_prediction']
	};
	// The layer's wheel is edited with the layer (Tap-Holds › Edit the layer),
	// no shortcut the wizard offers any more.
	assert.ok(!row('Layer + Scroll'), 'macOS no longer offers Layer + Scroll as a shortcut');
	for (const [trigger, action] of Object.entries(expected)) {
		assert.ok(row(trigger), `macOS lists ${trigger}`);
		assertSeparated(row(trigger), `macos/${trigger}`);
		assert.equal(row(trigger).action, action, `macOS: ${trigger} runs ${action}`);
	}
	const builtIns = pageOf(page, 'shortcuts').groups[0].items.filter((item) =>
		item.path.startsWith('shortcuts.keys.')
	);
	assert.ok(builtIns.length >= 20, 'macOS recommends its built-in shortcuts');
	for (const item of builtIns) {
		const shown = rows.find((candidate) => candidate.action === en[item.value_label[0].key]);
		assert.ok(shown && shown.trigger !== '', `macOS: ${item.path} names its chord`);
	}
	const linux = openWizard({ platform: 'linux' });
	linux.platform = 'linux';
	goToPage(linux, 'shortcuts');
	answer(linux, true);
	const superSpace = checkRows(linux).find((candidate) => candidate.trigger === 'Super + Space');
	assert.ok(superSpace, 'Linux names its Super + Space chord alone');
	assert.equal(superSpace.action, en['sg_actions.llm_generate_prediction']);
})();

(function everyActionItemDrawsTheSeparatorElement() {
	// wizard-checklist-labels: « Swipe 3 doigts ↓ → ⧉ → Onglet suivant » drew the
	// separator as the same arrow the labels contain.
	for (const code of ['en', 'fr']) {
		for (const driver of Object.keys(DRIVER_MANIFESTS)) {
			const page = openWizard({ platform: driver, locale: code, strings: locale(code) });
			page.platform = driver;
			next(page, 2);
			let separated = 0;
			for (const id of APPROVED_ORDER) {
				const described = pageOf(page, id);
				if (!page.el('page-question').classList.contains('hidden')) answer(page, true);
				const items = [];
				(function walk(groups) {
					for (const group of groups) {
						items.push(...(group.items || []));
						walk(group.groups || []);
					}
				})(described.groups);
				// A page without a checklist hides the previous page's rows.
				const listed = !page.el('page-checklist').classList.contains('hidden');
				const rows = listed ? checkRows(page).filter((row) => row.parts.length > 0) : [];
				assert.equal(
					rows.length,
					items.filter((item) => item.value_label).length,
					`${code}/${driver}/${id}: one separated row per item that imports an action`
				);
				rows.forEach((row) => assertSeparated(row, `${code}/${driver}/${id}/${row.trigger}`));
				separated += rows.length;
				page.click('btn-next');
			}
			assert.ok(separated >= 10, `${code}/${driver}: the action items are separated`);
		}
	}
	assert.ok(!/' → '/.test(source), 'the page spells no text separator of its own');
})();

(function aYesImportsOnlyTheCheckedKeysAndANoImportsNone() {
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		const keys = [...tapHoldKeyItems(driver).values()];
		const labels = new Map(keys.map((item) => [locale('en')[item.label[0].key], item]));
		const page = openWizard({ platform: driver });
		page.platform = driver;
		goToPage(page, 'tap_holds');
		answer(page, true);
		const rows = checkRows(page).filter((row) => labels.has(row.name));
		assert.equal(rows.length, keys.length, `${driver}: one row per recommended key`);
		assert.ok(
			rows.every((row) => row.box.checked && !row.box.disabled),
			`${driver}: Yes pre-checks every recommended key`
		);
		const left = rows[0];
		toggle(left);
		const imported = finish(page).answers.operations.filter((op) =>
			tapHoldKeyItems(driver).has(op.path)
		);
		const leftItem = labels.get(left.name);
		assert.deepEqual(
			imported,
			keys.filter((item) => item !== leftItem).map((item) => ({ path: item.path, value: true })),
			`${driver}: every checked key is imported and the unchecked one is not written at all`
		);

		const declined = openWizard({ platform: driver });
		declined.platform = driver;
		goToPage(declined, 'tap_holds');
		answer(declined, true);
		answer(declined, false);
		assert.deepEqual(
			finish(declined).answers.operations.filter((op) => op.path.startsWith('tap_holds.')),
			[],
			`${driver}: answering No imports no key, even after a Yes`
		);
	}
})();

(function aRerunKeepsTheConfiguredTapHoldKeys() {
	// A re-run answered Yes pre-checked every key and imported over the user's
	// own settings; on macOS and Linux it even opened at No with Tap-Holds on.
	for (const driver of Object.keys(DRIVER_MANIFESTS)) {
		const described = CATALOGUE.platforms[driver].pages.find((p) => p.id === 'tap_holds');
		const keys = described.groups.flatMap((group) => group.items);
		const [imported, customised, ...free] = keys;
		const current = {
			[imported.path]: imported.value,
			[customised.path]: customised.customised_value,
			[described.master ? described.master.path : described.state.path]: true
		};
		const page = openWizard({ platform: driver, current });
		page.platform = driver;
		goToPage(page, 'tap_holds');
		assert.equal(
			page.el('page-yes').checked,
			true,
			`${driver}: the page opens at the Yes in force`
		);
		const text = (item) => locale('en')[item.label[0].key];
		const rowOf = (item) =>
			checkRows(page).find(
				(row) =>
					row.name === text(item) ||
					row.name === locale('en')['onboarding.checklist.customised'].split('{1}').join(text(item))
			);
		assert.equal(rowOf(imported).box.checked, true, `${driver}: an imported key shows checked`);
		assert.equal(rowOf(imported).box.disabled, true, `${driver}: and is kept as it is`);
		assert.equal(
			rowOf(customised).box.checked,
			false,
			`${driver}: a customised key is not the recommendation`
		);
		assert.equal(rowOf(customised).box.disabled, true, `${driver}: and cannot be imported over`);
		assert.notEqual(rowOf(customised).name, text(customised), `${driver}: its row says it is kept`);
		assert.equal(
			rowOf(customised).trigger,
			null,
			`${driver}: a kept key shows no recommended tap and hold it would not receive`
		);
		assert.ok(
			free.every((item) => rowOf(item).box.checked === false && rowOf(item).box.disabled === false),
			`${driver}: a configured page pre-checks nothing, and the free keys stay choosable`
		);
		answer(page, false);
		answer(page, true);
		assert.ok(
			free.every((item) => rowOf(item).box.checked === false),
			`${driver}: turning the answer back to Yes still pre-checks nothing`
		);
		const header = checkRows(page).find(
			(row) => row.text === locale('en')[described.groups[0].label[0].key]
		);
		toggle(header);
		assert.equal(
			rowOf(customised).box.checked,
			false,
			`${driver}: a group checkbox skips a customised key`
		);
		const operations = finish(page).answers.operations;
		assert.ok(
			!operations.some((op) => op.path === imported.path || op.path === customised.path),
			`${driver}: neither configured key is written`
		);
		assert.ok(
			!operations.some((op) => described.state && op.path === described.state.path),
			`${driver}: the reported switch is never written`
		);
		const leftFree = described.groups[0].items.filter((item) => free.includes(item));
		assert.deepEqual(
			operations.filter((op) => op.path.startsWith('tap_holds.keys.')),
			leftFree.map((item) => ({ path: item.path, value: true })),
			`${driver}: only the free keys the user checked are imported`
		);
	}
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
	assert.equal(checked, 3, 'each driver asks for a trigger its owner can validate');
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

(function linuxTriggerChoiceKeepsRuntimePolicyAndCustomAnswer() {
	for (const system_layout of ['French - PC', 'US', 'Ergopti']) {
		const page = openWizard({ platform: 'linux', system_layout });
		page.platform = 'linux';
		goToPage(page, 'hotstrings');
		answer(page, true);
		const rows = page.el('page-magic-options').children;
		assert.deepEqual(
			rows.slice(0, -1).map((row) => row.children[0].value),
			['★']
		);
		assert.equal(
			rows.find((row) => row.children[0].checked).children[0].value,
			'★',
			`${system_layout}: Linux never proposes a common character`
		);
		const custom = rows[rows.length - 1].children[0];
		custom.checked = true;
		custom.dispatch('change');
		const input = page.el('page-magic-options').querySelector('magic-input');
		assert.equal(input.maxLength, 2, 'one supplementary Unicode scalar fits the browser input');
		input.value = '§';
		input.dispatch('input');
		const done = finish(page);
		assert.deepEqual(
			done.answers.operations.find((op) => op.path === 'hotstrings.trigger_char'),
			{ path: 'hotstrings.trigger_char', value: '§' }
		);
	}
	const page = openWizard({ platform: 'linux', current: { 'hotstrings.trigger_char': '§' } });
	page.platform = 'linux';
	goToPage(page, 'hotstrings');
	answer(page, true);
	const input = page.el('page-magic-options').querySelector('magic-input');
	assert.equal(input.value, '§', 'a re-run shows the stored custom trigger');
	assert.ok(
		!finish(page).answers.operations.some((op) => op.path === 'hotstrings.trigger_char'),
		'a kept custom trigger is not overwritten'
	);
})();

(function linuxRerunPreservesAnOutdatedTriggerUntilExplicitChoice() {
	for (const stale of [';', 'ù']) {
		for (const replace of [false, true]) {
			const page = openWizard({ platform: 'linux', current: { 'hotstrings.trigger_char': stale } });
			page.platform = 'linux';
			goToPage(page, 'hotstrings');
			answer(page, true);
			assert.equal(
				page.el('page-magic-options').querySelector('magic-input').value,
				stale,
				'an outdated stored scalar is shown without changing it'
			);
			if (replace) {
				const star = page.el('page-magic-options').children[0].children[0];
				star.checked = true;
				star.dispatch('change');
			}
			const operation = finish(page).answers.operations.find(
				(op) => op.path === 'hotstrings.trigger_char'
			);
			assert.deepEqual(
				operation,
				replace ? { path: 'hotstrings.trigger_char', value: '★' } : undefined,
				'only an explicit replacement answers the old trigger'
			);
		}
	}
})();

(function existingOutdatedRecordsRequireExplicitTriggerIntent() {
	const outdated = [7, false, '', { retained: 'independent' }];
	for (const platform of ['windows', 'macos', 'linux']) {
		for (const value of outdated) {
			const current = { 'hotstrings.trigger_char': value };
			const untouched = openWizard({ platform, current });
			untouched.platform = platform;
			goToPage(untouched, 'hotstrings');
			answer(untouched, true);
			assert.ok(
				!finish(untouched).answers.operations.some((op) => op.path === 'hotstrings.trigger_char'),
				`${platform}/${JSON.stringify(value)}: Hotstrings Yes never answers an untouched outdated trigger`
			);
			const changed = openWizard({ platform, current });
			changed.platform = platform;
			goToPage(changed, 'hotstrings');
			answer(changed, true);
			const options = changed.el('page-magic-options').children;
			const custom = options[options.length - 1].children[0];
			custom.checked = true;
			custom.dispatch('change');
			const input = changed.el('page-magic-options').querySelector('magic-input');
			input.value = '';
			input.dispatch('input');
			changed.click('btn-next');
			assert.equal(
				changed.el('page-title').textContent,
				locale('en')['menu.hotstrings.title'],
				'explicit empty custom input blocks Next even over an outdated record'
			);
			assert.ok(input.classList.contains('invalid'));
			input.value = '§';
			input.dispatch('input');
			assert.deepEqual(
				finish(changed).answers.operations.find((op) => op.path === 'hotstrings.trigger_char'),
				{ path: 'hotstrings.trigger_char', value: '§' },
				'only the explicit valid choice answers the owned leaf'
			);
		}
	}
})();

(function changedFoldersRetirePreviousTriggerIntentAndCallbacks() {
	for (const platform of ['windows', 'macos', 'linux']) {
		const page = openWizard({ platform, current: { 'hotstrings.trigger_char': '§' } });
		page.platform = platform;
		goToPage(page, 'hotstrings');
		answer(page, true);
		const rows = page.el('page-magic-options').children;
		const previousCustom = rows[rows.length - 1].children[0];
		previousCustom.checked = true;
		previousCustom.dispatch('change');
		const previousInput = page.el('page-magic-options').querySelector('magic-input');
		previousInput.value = '±';
		previousInput.dispatch('input');
		for (let i = 0; i < 1 + APPROVED_ORDER.indexOf('hotstrings'); i++) page.click('btn-back');
		page.window.setConfigDir('/tmp/second-trigger-folder');
		page.messages.splice(0);
		page.click('btn-next');
		const request = page.messages.find(
			(message) => message.action === 'loadExistingConfig'
		).request;
		page.window.applyCurrentValues({
			request: request - 1,
			values: { 'hotstrings.trigger_char': '→' }
		});
		page.window.applyCurrentValues({ request, values: { 'hotstrings.trigger_char': 7 } });
		next(page, APPROVED_ORDER.indexOf('hotstrings'));
		answer(page, true);
		previousInput.value = '😀';
		previousInput.dispatch('input');
		previousCustom.dispatch('change');
		const done = finish(page);
		assert.equal(done.answers.config_dir, '/tmp/second-trigger-folder');
		assert.ok(
			!done.answers.operations.some((op) => op.path === 'hotstrings.trigger_char'),
			'old-folder intent and retained callbacks cannot replace the untouched record of the new folder'
		);
	}
})();

(function triggerOptionProjectionRejectsInvalidDeclarations() {
	const generatorPath = path.join(ROOT, 'tools/codegen/codegen-onboarding-catalogue.cjs');
	const generatorSource = fs.readFileSync(generatorPath, 'utf8');
	const originalRequire = require('node:module').createRequire(generatorPath);
	const manifestPath = path.join(SHARED, 'modules/features/manifest.toml');
	const original = fs.readFileSync(manifestPath, 'utf8');
	function buildWith(choice) {
		const declaration = TOML.stringify({
			onboarding: { pages: { hotstrings: { magic_key: choice } } }
		});
		const manifest = original.replace(
			/\[onboarding\.pages\.hotstrings\.magic_key\][\s\S]*?(?=\[onboarding\.pages\.llm\])/,
			declaration + '\n'
		);
		const module = { exports: {} };
		const fakeFs = Object.assign({}, fs, {
			readFileSync(file, encoding) {
				return file === manifestPath ? manifest : fs.readFileSync(file, encoding);
			}
		});
		vm.runInNewContext(
			generatorSource,
			{
				module,
				require: (name) => (name === 'fs' ? fakeFs : originalRequire(name)),
				console
			},
			{ filename: generatorPath }
		);
		return JSON.parse(JSON.stringify(module.exports.buildCatalogue()));
	}
	const choice = TOML.parse(original).onboarding.pages.hotstrings.magic_key;
	const projected = buildWith(choice);
	for (const driver of ['windows', 'macos', 'linux']) {
		const described = projected.platforms[driver].pages.find((page) => page.id === 'hotstrings');
		assert.deepEqual(
			described.magic_key.options.map((option) => option.value),
			driver === 'linux' ? ['★'] : ['★', 'ù', ';']
		);
		assert.equal(described.magic_key.validation, driver === 'linux' ? 'safe_magic_key' : undefined);
	}
	for (const platforms of [[], ['unknown'], ['linux', 'linux'], 'linux']) {
		const malformed = JSON.parse(JSON.stringify(choice));
		malformed.options[0].platforms = platforms;
		assert.throws(() => buildWith(malformed), /option platforms must be a nonempty known subset/);
	}
	for (const validation of ['safe_magic_key', { linux: 'anything' }, { hs: 'safe_magic_key' }]) {
		const malformed = JSON.parse(JSON.stringify(choice));
		malformed.validation = validation;
		assert.throws(() => buildWith(malformed), /validation|unsupported/);
	}
})();

// ======================================
// ======= 5/ Re-run from the menu ======
// ======================================

(function twoFingerRecommendationsStayWithTheOperatingSystem() {
	for (const platform of ['windows', 'macos', 'linux']) {
		const page = openWizard({ platform });
		page.platform = platform;
		goToPage(page, 'gestures');
		answer(page, true);
		const assigned = finish(page).answers.operations.filter(
			(op) => /^gestures\.(tap_2|swipe_2_)/.test(op.path) && op.value !== 'none'
		);
		assert.deepEqual(
			assigned,
			[],
			platform + ': recommendations must not take over two-finger OS gestures'
		);
	}
	const page = openWizard({
		platform: 'macos',
		current: { 'gestures.enabled': true, 'gestures.swipe_2_left': 'tab_close' }
	});
	goToPage(page, 'gestures');
	answer(page, true);
	assert.deepEqual(
		finish(page).answers.operations.filter((op) => op.path === 'gestures.swipe_2_left'),
		[],
		'an explicitly configured two-finger action remains owned by the user'
	);
})();

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
	// Windows: its first page asks through a config.toml switch.
	const page = openWizard({ platform: 'windows' });
	page.platform = 'windows';
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
	page.window.applyCurrentValues({ request: 0, values: { 'category_enabled.tap_holds': true } });
	assert.equal(page.el('page-no').checked, true, 'a stale reply is dropped');
	page.window.applyCurrentValues({ request: 1, values: { 'category_enabled.tap_holds': true } });
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
	assert.equal(
		page.el('language-title').textContent,
		locale('fr')['onboarding.welcome.heading'],
		'the language step is headed by its name, as every later step is'
	);
	assert.equal(
		page.el('language-subtitle'),
		undefined,
		'the step does not repeat the window title'
	);

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

	page.click('btn-next');
	page.window.applyCurrentValues({ request: 1, values: {} });
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
	page.window.applyCurrentValues({ request: 1, values: {} });
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
	page.click('btn-next');
	page.window.applyCurrentValues({ request: 1, values: {} });
	next(page, APPROVED_ORDER.length - 1);
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
	page.window.applyCurrentValues({ request: 2, values: {} });
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

(function pendingFolderCannotFinishAndCanRetryTheSameTarget() {
	for (const platform of ['windows', 'macos', 'linux']) {
		const page = openWizard({ platform, current: { 'hotstrings.trigger_char': '§' } });
		page.platform = platform;
		goToPage(page, 'hotstrings');
		answer(page, true);
		const custom = page.el('page-magic-options').children.slice(-1)[0].children[0];
		custom.checked = true;
		custom.dispatch('change');
		const oldInput = page.el('page-magic-options').querySelector('magic-input');
		oldInput.value = '±';
		oldInput.dispatch('input');
		for (let i = 0; i < 1 + APPROVED_ORDER.indexOf('hotstrings'); i++) page.click('btn-back');
		page.window.setConfigDir('/tmp/second-trigger-folder');
		page.messages.splice(0);
		page.click('btn-next');
		assert.deepEqual(
			page.messages.find((m) => m.action === 'loadExistingConfig'),
			{
				action: 'loadExistingConfig',
				config_dir: '/tmp/second-trigger-folder',
				request: 1
			}
		);
		assert.equal(
			page.el('btn-next').disabled,
			true,
			platform + ': unknown target gates feature navigation'
		);
		assert.equal(page.el('btn-next').textContent, locale('en')['common.loading']);
		const initialTitle = page.el('page-title').textContent;
		for (const reply of [
			null,
			{ request: 0, values: {} },
			{ request: 1, values: null },
			{ request: 1, values: [] },
			{ request: '1', values: {} }
		]) {
			page.window.applyCurrentValues(reply);
			next(page, 20);
			assert.equal(
				page.el('page-title').textContent,
				initialTitle,
				platform + ': missing or malformed reply cannot admit the target'
			);
			assert.ok(
				!page.messages.some((m) => m.action === 'finish'),
				platform + ': pending target cannot finish'
			);
		}
		// Read failure has no success envelope. Back remains usable and Next
		// explicitly retries the same folder rather than marking it loaded.
		page.click('btn-back');
		assert.equal(page.el('config-input').value, '/tmp/second-trigger-folder');
		assert.equal(page.el('btn-next').disabled, false);
		page.messages.splice(0);
		page.click('btn-next');
		assert.equal(page.messages.find((m) => m.action === 'loadExistingConfig').request, 2);
		page.window.applyCurrentValues({ request: 1, values: { 'hotstrings.trigger_char': '±' } });
		assert.equal(
			page.el('btn-next').disabled,
			true,
			'the retired request cannot acknowledge the retry'
		);
		page.window.applyCurrentValues({ request: 2, values: { 'hotstrings.trigger_char': 7 } });
		assert.equal(page.el('btn-next').disabled, false);
		next(page, APPROVED_ORDER.indexOf('hotstrings'));
		answer(page, true);
		// Captured prior-folder controls and duplicate success envelopes must
		// not reintroduce old intent after the new target is admitted.
		oldInput.value = '→';
		oldInput.dispatch('input');
		custom.checked = true;
		custom.dispatch('change');
		page.window.applyCurrentValues({ request: 2, values: { 'hotstrings.trigger_char': '±' } });
		const done = finish(page);
		assert.equal(done.answers.config_dir, '/tmp/second-trigger-folder');
		assert.ok(
			!done.answers.operations.some((op) => op.path === 'hotstrings.trigger_char'),
			platform + ': untouched admitted outdated trigger is preserved'
		);
	}
})();

(function anEmptySuccessfulFolderReadAdmitsFirstRunChoices() {
	const page = openWizard({ platform: 'linux', current: { 'hotstrings.trigger_char': '§' } });
	page.platform = 'linux';
	page.click('btn-next');
	page.window.setConfigDir('/tmp/new-trigger-folder');
	page.click('btn-next');
	page.window.applyCurrentValues({ request: 1, values: {} });
	next(page, APPROVED_ORDER.indexOf('hotstrings'));
	answer(page, true);
	const rows = page.el('page-magic-options').children;
	assert.equal(
		rows.find((row) => row.children[0].checked).children[0].value,
		'★',
		'successful empty read establishes absence and shows the first-run recommendation'
	);
	const custom = rows[rows.length - 1].children[0];
	custom.checked = true;
	custom.dispatch('change');
	const input = page.el('page-magic-options').querySelector('magic-input');
	input.value = '±';
	input.dispatch('input');
	const done = finish(page);
	assert.deepEqual(
		done.answers.operations.filter((op) => op.path === 'hotstrings.trigger_char'),
		[{ path: 'hotstrings.trigger_char', value: '±' }],
		'a successfully admitted empty folder receives the new explicit choice'
	);
})();

(function aReplyCannotAdmitADifferentPickerTarget() {
	const page = openWizard({ platform: 'linux' });
	page.click('btn-next');
	page.window.setConfigDir('/tmp/first-pending-target');
	page.click('btn-next');
	page.click('btn-back');
	page.window.setConfigDir('/tmp/second-pending-target');
	page.window.applyCurrentValues({ request: 1, values: { 'hotstrings.trigger_char': '§' } });
	page.click('btn-next');
	assert.equal(page.messages.filter((m) => m.action === 'loadExistingConfig').length, 2);
	assert.equal(
		page.el('btn-next').disabled,
		true,
		'a picker change cannot be admitted by the prior target reply'
	);
	page.window.applyCurrentValues({ request: 2, values: {} });
	assert.equal(page.el('btn-next').disabled, false);
})();

// ======================================
// ======= 10/ Empty folder target ======
// ======================================

(function anEmptyFolderNamesItsNativeTarget() {
	const current = '/Volumes/Personal/B/';
	const osDefault = '/Volumes/Default/A/';
	for (const platform of ['macos', 'windows', 'linux']) {
		const target = platform === 'macos' ? current : osDefault;
		const page = openWizard({
			platform,
			config_dir: current,
			default_config_dir: osDefault,
			empty_config_dir: target
		});
		page.platform = platform;
		page.click('btn-next');
		const input = page.el('config-input');
		assert.equal(input.value, current, platform + ': the current folder stays explicit');
		assert.equal(input.placeholder, target, platform + ': empty means the native target');
		assert.equal(
			page.el('config-hint').textContent,
			'Personal files are loaded from this folder. Leave empty to use: ' + target,
			platform + ': the hint names the actual empty target even while the field is filled'
		);

		input.value = '';
		input.dispatch('input');
		page.messages.splice(0);
		page.click('btn-next');
		assert.deepEqual(
			page.messages.find((message) => message.action === 'loadExistingConfig'),
			{ action: 'loadExistingConfig', config_dir: '', request: 1 },
			platform + ': the import wire contract still sends the empty field'
		);
		page.window.applyCurrentValues({ request: 1, values: {} });
		page.click('btn-back');
		page
			.el('lang-list')
			.children.find((row) => row.dataset.code === 'fr')
			.click();
		page.window.applyStrings({ locale: 'fr', strings: locale('fr') });
		assert.equal(input.value, '', platform + ': locale changes preserve the empty answer');
		assert.equal(input.placeholder, target, platform + ': locale changes preserve its target');
		const done = finish(page);
		assert.equal(done.answers.config_dir, '', platform + ': Finish retains native empty semantics');
	}
})();

(function everyLocaleNamesTheSameEmptyFolderTarget() {
	const target = '/Volumes/Personal/<B> & {1}/';
	const codes = fs.readdirSync(LOCALE_DIR).filter((name) => name.endsWith('.json'));
	const page = openWizard({
		config_dir: '/Volumes/Explicit/C/',
		default_config_dir: '/Volumes/Default/A/',
		empty_config_dir: target,
		locales: codes.map((name) => ({ code: name.slice(0, -5), flag: '', name }))
	});
	page.click('btn-next');
	assert.equal(codes.length, 21, 'the empty-folder hint covers all 21 locales');
	for (const name of codes) {
		const code = name.slice(0, -5);
		const strings = locale(code);
		const template = strings['onboarding.config_folder.hint'];
		assert.equal(typeof template, 'string', code + ': the onboarding-only hint exists');
		assert.equal(occurrences(template, '{1}'), 1, code + ': exactly one folder placeholder');
		page
			.el('lang-list')
			.children.find((row) => row.dataset.code === code)
			.click();
		page.window.applyStrings({ locale: code, strings });
		assert.equal(
			page.el('config-hint').textContent,
			template.replace('{1}', () => target),
			code + ': path punctuation is rendered literally in text'
		);
		assert.equal(page.el('config-input').value, '/Volumes/Explicit/C/');
		assert.equal(page.el('config-input').placeholder, target);
	}
	page.window.setConfigDir('/Volumes/Picked/D/');
	page
		.el('lang-list')
		.children.find((row) => row.dataset.code === 'en')
		.click();
	page.window.applyStrings({ locale: 'en', strings: locale('en') });
	assert.equal(page.el('config-input').value, '/Volumes/Picked/D/');
	assert.equal(
		page.el('config-input').placeholder,
		target,
		'picking a folder does not redefine empty'
	);
})();

(function aMissingEmptyFolderTargetCannotResetThePage() {
	const page = openWizard({ empty_config_dir: '/Volumes/Captured/B/' });
	page.click('btn-next');
	page.window.setConfigDir('/Volumes/Picked/C/');
	for (const invalid of [undefined, null, '', '   ', 42]) {
		assert.throws(
			() => page.window.initData({ platform: 'macos', empty_config_dir: invalid }),
			/configuration folder used for an empty input/,
			'an invalid target refuses before resetting the wizard'
		);
		assert.equal(page.el('config-input').value, '/Volumes/Picked/C/');
		assert.equal(page.el('config-input').placeholder, '/Volumes/Captured/B/');
	}
})();

(function theFolderTargetScriptInvalidatesTheNativeResourceCache() {
	const match = html.match(/src="script\.js\?v=(\d+)"/);
	assert.ok(match, 'the native document versions its onboarding script URL');
	assert.ok(Number(match[1]) > 7, 'folder-target rendering retires the published v7 script cache');
})();

console.log(
	'Onboarding wizard page: pages, defaults, manifest paths, re-run, title, folder, consent and checklist labels passed.'
);

// ======================================
// ======= 11/ Retained folder edits ====
// ======================================

(function delayedLocaleRepliesPreserveFolderEdits() {
	for (const platform of ['windows', 'macos', 'linux']) {
		for (const intent of ['typed', 'empty', 'picked']) {
			for (const response of ['matching', 'stale']) {
				const context = platform + '/' + intent + '/' + response;
				const target = platform === 'macos' ? '/Volumes/Personal/B/' : '/Volumes/Default/A/';
				const page = openWizard({
					platform,
					config_dir: '/Volumes/Personal/B/',
					default_config_dir: '/Volumes/Default/A/',
					empty_config_dir: target
				});
				page.platform = platform;
				page
					.el('lang-list')
					.children.find((row) => row.dataset.code === 'fr')
					.click();
				assert.deepEqual(page.messages.splice(0), [{ action: 'previewLocale', locale: 'fr' }]);
				// The page can navigate while the native preview is still in flight.
				page.click('btn-next');
				assert.deepEqual(page.messages.splice(0), [{ action: 'localeSelected', locale: 'fr' }]);
				const input = page.el('config-input');
				const raw =
					intent === 'typed'
						? ' /Volumes/Typed/<D> & {1}/ '
						: intent === 'empty'
							? ''
							: '/Volumes/Picked/C/';
				const expected = intent === 'typed' ? '/Volumes/Typed/<D> & {1}/' : raw;
				if (intent === 'picked') {
					page.click('config-browse');
					assert.deepEqual(page.messages.splice(0), [
						{ action: 'pickConfigDir', current: '/Volumes/Personal/B/' }
					]);
					page.window.setConfigDir('/Volumes/Picked/C/');
				} else {
					input.value = raw;
					input.dispatch('input');
					page.window.setConfigDir('');
					page.window.setConfigDir(null);
				}
				assert.equal(input.value, raw, context + ': raw input survives a cancelled picker');
				assert.deepEqual(
					page.messages.splice(0),
					[],
					context + ': typing does not read or resolve metrics'
				);
				page.window.applyStrings({
					locale: response === 'matching' ? 'fr' : 'en',
					strings: locale(response === 'matching' ? 'fr' : 'en')
				});
				assert.equal(
					input.value,
					raw,
					context + ': delayed locale delivery retains exact raw intent'
				);
				assert.equal(
					input.placeholder,
					target,
					context + ': editing does not change the native empty target'
				);
				assert.equal(
					page.document.title,
					locale(response === 'matching' ? 'fr' : 'en')['onboarding.welcome.title'],
					context + ': stale locale envelopes remain refused'
				);
				page.click('btn-next');
				assert.deepEqual(
					page.messages.splice(0),
					[
						{ action: 'loadExistingConfig', config_dir: expected, request: 1 },
						{ action: 'resolveMetricsPath', config_dir: expected, request: 1 }
					],
					context + ': navigation alone trims and requests the chosen source'
				);
				assert.equal(page.el('btn-next').disabled, true, context + ': unread source blocks pages');
				page.click('btn-next');
				assert.deepEqual(
					page.messages.splice(0),
					[],
					context + ': pending source cannot reach Finish'
				);
				page.window.applyCurrentValues({ request: 0, values: {} });
				assert.equal(
					page.el('btn-next').disabled,
					true,
					context + ': stale response cannot admit pages'
				);
				page.window.applyCurrentValues({ request: 1, values: {} });
				assert.equal(
					page.el('btn-next').disabled,
					false,
					context + ': exact response admits pages'
				);
				page.click('btn-back');
				assert.equal(
					input.value,
					expected,
					context + ': Back retains the admitted, trimmed folder'
				);
				const done = finish(page);
				assert.equal(
					done.answers.config_dir,
					expected,
					context + ': Finish keeps exact native empty or explicit semantics'
				);
				assert.equal(
					done.answers.locale,
					'fr',
					context + ': the selected locale remains the Finish intent'
				);
			}
		}
	}
})();

(function editingThePendingFolderRetiresItsReadAuthority() {
	for (const platform of ['windows', 'macos', 'linux']) {
		const page = openWizard({ platform, config_dir: '/Volumes/Personal/B/' });
		page.platform = platform;
		page.click('btn-next');
		const input = page.el('config-input');
		input.value = '/Volumes/Pending/A/';
		input.dispatch('input');
		page.messages.splice(0);
		page.click('btn-next');
		assert.deepEqual(page.messages.splice(0), [
			{ action: 'loadExistingConfig', config_dir: '/Volumes/Pending/A/', request: 1 },
			{ action: 'resolveMetricsPath', config_dir: '/Volumes/Pending/A/', request: 1 }
		]);
		page.click('btn-back');
		input.value = '/Volumes/Successor/C/';
		input.dispatch('input');
		assert.deepEqual(
			page.messages.splice(0),
			[],
			platform + ': editing the pending folder does not publish'
		);
		// This reply names the pending request, but its folder is no longer selected.
		page.window.applyCurrentValues({ request: 1, values: {} });
		input.value = '/Volumes/Pending/A/';
		input.dispatch('input');
		page.click('btn-next');
		assert.deepEqual(
			page.messages.splice(0),
			[
				{ action: 'loadExistingConfig', config_dir: '/Volumes/Pending/A/', request: 2 },
				{ action: 'resolveMetricsPath', config_dir: '/Volumes/Pending/A/', request: 2 }
			],
			platform + ': a retired read is not reused when the folder is selected again'
		);
		assert.equal(page.el('btn-next').disabled, true);
		page.window.applyCurrentValues({ request: 1, values: {} });
		assert.equal(page.el('btn-next').disabled, true, platform + ': retired response remains stale');
		page.window.applyCurrentValues({ request: 2, values: {} });
		assert.equal(page.el('btn-next').disabled, false);
		assert.equal(finish(page).answers.config_dir, '/Volumes/Pending/A/');
	}
})();

(function theFolderIntentScriptInvalidatesItsPredecessorCache() {
	const match = html.match(/src="script\.js\?v=(\d+)"/);
	assert.ok(match, 'the native document versions its onboarding script URL');
	assert.ok(
		Number(match[1]) > 8,
		'retained typed intent retires the folder-target v8 script cache'
	);
})();

// ======================================
// ======= 11/ Keyboard layout controls =
// ======================================

/**
 * The persistent control groups of the shown page, by control id.
 * @param {object} page
 * @returns {Map<string, object>}
 */
function controlGroups(page) {
	const groups = new Map();
	for (const group of page.el('page-controls').children) groups.set(group.dataset.control, group);
	return groups;
}

/**
 * The radio inputs of a choice control, by value.
 * @param {object} group
 * @returns {Map<string, object>}
 */
function controlRadios(group) {
	const radios = new Map();
	for (const row of group.children.filter((child) => child.classList.contains('radio-card')))
		radios.set(row.children[0].value, row.children[0]);
	return radios;
}

/** Picks a radio of a choice control. */
function pick(page, id, value) {
	const radio = controlRadios(controlGroups(page).get(id)).get(value);
	radio.checked = true;
	radio.dispatch('change');
}

// The layout step offers the emulated layout, the number-row emulation (base
// and Shift levels) and the ordering as controls of their own, declared once
// for every driver. A new installation emulates nothing and reorders nothing;
// a control changes only what the user changes, posts nothing to the host and
// keeps its value across Yes/No and a language preview (neutral-layout-wizard).
(function theLayoutStepOffersPersistentNeutralControls() {
	const page = openWizard({ platform: 'windows' });
	page.platform = 'windows';
	goToPage(page, 'keyboard_layout');
	const layout = pageOf(page, 'keyboard_layout');
	assert.deepEqual(
		layout.controls.map((control) => control.id),
		['emulated_layout', 'alt_gr_emulation', 'number_row_emulation', 'number_row_order']
	);
	for (const path of [
		'layout.ergopti_base',
		'layout.ergopti_variant',
		'layout.ergopti_alt_gr',
		'layout.direct_access_digits'
	])
		assert.ok(
			!layout.groups.some((group) => (group.items || []).some((item) => item.path === path)),
			path + ' is a control, never a checklist item a Yes would prefill'
		);
	let groups = controlGroups(page);
	assert.equal(page.el('page-controls').classList.contains('hidden'), false);
	assert.equal(
		controlRadios(groups.get('emulated_layout')).get('none').checked,
		true,
		'no emulation'
	);
	assert.equal(
		controlRadios(groups.get('number_row_order')).get('native').checked,
		true,
		'native order'
	);
	const numberRow = groups.get('number_row_emulation').children[0].children[0];
	assert.equal(numberRow.checked, true, 'the number row is emulated with the layout, as shipped');
	assert.equal(numberRow.disabled, true, 'the controls follow the question, which starts at No');
	answer(page, true);
	groups = controlGroups(page);
	assert.equal(controlRadios(groups.get('emulated_layout')).get('ergopti').disabled, false);
	page.messages.splice(0);
	pick(page, 'emulated_layout', 'ergopti_plus');
	pick(page, 'number_row_order', 'digits');
	const box = controlGroups(page).get('number_row_emulation').children[0].children[0];
	box.checked = false;
	box.dispatch('change');
	assert.deepEqual(page.messages, [], 'a control changes the page alone: nothing reloads');
	assert.equal(page.el('page-title').textContent, locale('en')['menu.layout.title']);
	page.window.applyStrings({ locale: 'en', strings: locale('en') });
	answer(page, false);
	answer(page, true);
	groups = controlGroups(page);
	assert.equal(controlRadios(groups.get('emulated_layout')).get('ergopti_plus').checked, true);
	assert.equal(controlRadios(groups.get('number_row_order')).get('digits').checked, true);
	assert.equal(groups.get('number_row_emulation').children[0].children[0].checked, false);
	const operations = finish(page).answers.operations;
	const written = new Map(operations.map((operation) => [operation.path, operation.value]));
	assert.equal(written.get('category_enabled.layout'), true);
	assert.equal(written.get('layout.ergopti_base'), true);
	assert.equal(written.get('layout.ergopti_variant'), 'ergopti_plus');
	assert.equal(written.get('layout.direct_access_digits'), 'digits');
	assert.equal(written.get('layout.emulate_number_row'), false);
	assert.equal(
		written.has('layout.emulated_layout'),
		false,
		'a value already in force is not rewritten'
	);

	// A first run answered Yes with the controls untouched writes the switch alone.
	const fresh = openWizard({ platform: 'windows' });
	fresh.platform = 'windows';
	goToPage(fresh, 'keyboard_layout');
	answer(fresh, true);
	const neutral = finish(fresh).answers.operations.filter((operation) =>
		operation.path.startsWith('layout.')
	);
	assert.deepEqual(neutral, [], 'a new installation emulates nothing and reorders nothing');
})();

// A re-run keeps what the layout manager chose: a registry layout matches no
// built-in choice, so the control shows none selected and writes nothing until
// the user picks one (neutral-layout-wizard).
(function aRerunKeepsTheRegistryLayout() {
	const page = openWizard({
		platform: 'windows',
		current: {
			'category_enabled.layout': true,
			'layout.ergopti_base': true,
			'layout.emulated_layout': 'ergol',
			'layout.direct_access_digits': 'symbols'
		}
	});
	page.platform = 'windows';
	goToPage(page, 'keyboard_layout');
	const radios = controlRadios(controlGroups(page).get('emulated_layout'));
	assert.ok(
		[...radios.values()].every((radio) => !radio.checked),
		'no built-in choice claims Ergo-L'
	);
	assert.equal(
		controlRadios(controlGroups(page).get('number_row_order')).get('symbols').checked,
		true
	);
	const written = finish(page).answers.operations.map((operation) => operation.path);
	for (const path of [
		'layout.emulated_layout',
		'layout.ergopti_base',
		'layout.direct_access_digits'
	])
		assert.ok(!written.includes(path), path + ' stays as configured');
})();

// macOS and Linux emulate no layout and keep the native number row: the same
// controls are drawn greyed with why, and their hosts accept none of their paths.
(function theOtherDriversShowWhyTheyLackTheControls() {
	for (const platform of ['macos', 'linux']) {
		const page = openWizard({ platform });
		page.platform = platform;
		goToPage(page, 'keyboard_layout');
		const layout = pageOf(page, 'keyboard_layout');
		assert.ok(
			layout.controls.every((control) => !control.available),
			platform + ': no control applies'
		);
		const groups = controlGroups(page);
		assert.equal(groups.size, 4, platform + ': the four controls are drawn');
		for (const control of layout.controls) {
			const group = groups.get(control.id);
			const reason = group.children[group.children.length - 1];
			assert.equal(
				reason.textContent,
				locale('en')[control.reason_key],
				platform + ': ' + control.id + ' says why'
			);
		}
		assert.ok(
			!cataloguePaths(platform).has('layout.direct_access_digits'),
			platform + ': the host accepts no ordering answer'
		);
	}
})();

console.log(
	'Onboarding folder edits: delayed locale delivery, raw input, source admission and Finish passed.'
);
console.log(
	'Keyboard layout controls: neutral first run, persistent values, re-run and capability reasons passed.'
);
