// tools/test/test-site-accessibility-ratchet.cjs

/**
 * ==============================================================================
 * MODULE: Site Accessibility Ratchet Contract
 * DESCRIPTION:
 * The browser scan (tools/test/browser/site-accessibility.playwright.cjs) runs
 * in CI on the built site; this check runs everywhere, without a browser, and
 * proves the parts a passing scan cannot: the ratchet refuses a new or higher
 * count, the committed baseline is well formed, every real page of the site
 * is audited, and the visitor's accessibility preferences survive blocked
 * storage and refuse unknown values (static/ergopti_plus/_shared/ui/a11y_prefs.js).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const scan = require('./browser/site-accessibility.playwright.cjs');

const ROOT = path.resolve(__dirname, '../..');

/** The ratchet: new rows and higher counts fail, lower counts are reported. */
function checkComparison() {
	const baseline = {
		'a | light | page | rule': 3,
		'b | dark | page | rule': 1
	};
	assert.deepEqual(scan.compareWithBaseline({ ...baseline }, baseline), {
		regressions: [],
		improvements: []
	});
	const worse = scan.compareWithBaseline({ ...baseline, 'a | light | page | rule': 4 }, baseline);
	assert.equal(worse.regressions.length, 1, 'A higher count is a regression');
	const added = scan.compareWithBaseline({ ...baseline, 'c | light | page | new': 1 }, baseline);
	assert.equal(added.regressions.length, 1, 'A rule absent from the baseline is a regression');
	const better = scan.compareWithBaseline({ 'a | light | page | rule': 2 }, baseline);
	assert.deepEqual(better.regressions, []);
	assert.equal(
		better.improvements.length,
		2,
		'A lower or vanished count asks to lower the baseline'
	);
	assert.deepEqual(
		scan.countsOf([
			{ route: 'b', scheme: 'dark', frame: 'page', rule: 'r', nodes: 2 },
			{ route: 'a', scheme: 'light', frame: 'page', rule: 'r', nodes: 5 }
		]),
		{ 'a | light | page | r': 5, 'b | dark | page | r': 2 }
	);
}

/** The committed baseline only names audited pages, both schemes and positive counts. */
function checkBaseline() {
	const baseline = scan.readBaseline();
	for (const key of Object.keys(baseline)) {
		const [route, scheme] = key.split(' | ');
		assert.ok(scan.AUDITED_ROUTES.includes(route), 'Baseline names an unaudited page: ' + key);
		assert.ok(scan.COLOR_SCHEMES.includes(scheme), 'Baseline names an unknown scheme: ' + key);
	}
	assert.deepEqual([...scan.COLOR_SCHEMES], ['light', 'dark']);
	assert.ok(scan.WCAG_TAGS.includes('wcag22aa'), 'The target is WCAG 2.2 AA');
}

/** Every page of src/routes is audited, except the former addresses that redirect. */
function checkRouteCoverage() {
	const routesRoot = path.join(ROOT, 'src/routes');
	const pages = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (entry.name === '+page.svelte') pages.push(full);
		}
	};
	walk(routesRoot);
	assert.ok(pages.length >= 15, 'The route walk found the site pages');
	for (const file of pages) {
		if (fs.readFileSync(file, 'utf8').includes('LegacyRedirect')) continue;
		const route = '/' + path.relative(routesRoot, path.dirname(file)).split(path.sep).join('/');
		const normalized = route === '/' ? '/' : route.replace(/\/$/, '');
		assert.ok(
			scan.AUDITED_ROUTES.includes(normalized),
			'Page missing from the accessibility audit: ' + normalized
		);
	}
}

/** A tiny DOM and storage, enough for a11y_prefs.js. */
function loadPreferences({ storage }) {
	const attributes = new Map();
	const head = [];
	const listeners = {};
	const root = {
		setAttribute: (name, value) => attributes.set(name, String(value)),
		removeAttribute: (name) => attributes.delete(name),
		getAttribute: (name) => (attributes.has(name) ? attributes.get(name) : null)
	};
	const document = {
		currentScript: {
			src: 'https://ergopti.fr/dev/ergopti_plus/_shared/ui/a11y_prefs.js'
		},
		documentElement: root,
		head: { appendChild: (node) => head.push(node) },
		getElementById: (id) => head.find((node) => node.id === id) || null,
		createElement: () => ({})
	};
	root.ownerDocument = document;
	const window = {
		localStorage: storage,
		matchMedia: () => ({ matches: false }),
		addEventListener: (type, listener) => (listeners[type] = listener)
	};
	const source = fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/ui/a11y_prefs.js'),
		'utf8'
	);
	vm.runInNewContext(source, {
		window,
		document,
		URL,
		JSON,
		Object,
		Boolean,
		String
	});
	return { api: window.ErgoptiA11yPrefs, attributes, head, listeners };
}

function memoryStorage(initial = {}) {
	const values = { ...initial };
	return {
		values,
		getItem: (key) => (Object.hasOwn(values, key) ? values[key] : null),
		setItem: (key, value) => (values[key] = String(value)),
		removeItem: (key) => delete values[key]
	};
}

function blockedStorage() {
	const refuse = () => {
		throw new Error('SecurityError');
	};
	return { getItem: refuse, setItem: refuse, removeItem: refuse };
}

function checkPreferences() {
	const key = 'ergopti-a11y-preferences';
	// Stored values apply before the first paint; unknown names and values are ignored.
	const stored = memoryStorage({
		[key]: JSON.stringify({
			motion: 'reduce',
			font: 'comic',
			text: '150',
			extra: 'x'
		})
	});
	const loaded = loadPreferences({ storage: stored });
	assert.equal(loaded.attributes.get('data-a11y-motion'), 'reduce');
	assert.equal(loaded.attributes.get('data-a11y-text'), '150');
	assert.equal(loaded.attributes.has('data-a11y-font'), false, 'Unknown value ignored');
	assert.equal(loaded.api.reducedMotion(), true, 'The site setting reduces motion');
	// The font stylesheet is linked once, relative to the script, under any base path.
	assert.equal(loaded.api.save({ font: 'hyperlegible' }), true);
	assert.equal(loaded.head.length, 1);
	assert.equal(loaded.head[0].href, 'https://ergopti.fr/dev/fonts/atkinson-hyperlegible/font.css');
	assert.equal(loaded.attributes.has('data-a11y-motion'), false, 'A save replaces the whole map');
	loaded.api.save({ font: 'hyperlegible', contrast: 'high' });
	assert.equal(loaded.head.length, 1, 'The font stylesheet is linked only once');
	assert.deepEqual(JSON.parse(stored.values[key]), {
		font: 'hyperlegible',
		contrast: 'high'
	});
	// Defaults remove the stored entry instead of writing a no-op map.
	loaded.api.save({ font: 'default' });
	assert.equal(Object.hasOwn(stored.values, key), false);
	// Another document (the site around a Studio frame) changed the storage.
	stored.values[key] = JSON.stringify({ spacing: 'wide' });
	loaded.listeners.storage({ key });
	assert.equal(loaded.attributes.get('data-a11y-spacing'), 'wide');
	// Blocked storage reads as no preference and a save still applies to the page.
	const blocked = loadPreferences({ storage: blockedStorage() });
	assert.equal(blocked.attributes.size, 0);
	assert.equal(blocked.api.save({ contrast: 'high' }), false, 'The refused write is reported');
	assert.equal(blocked.attributes.get('data-a11y-contrast'), 'high');
	// Malformed JSON is no preference, not a crash.
	assert.equal(loadPreferences({ storage: memoryStorage({ [key]: '{' }) }).attributes.size, 0);
}

checkComparison();
checkBaseline();
checkRouteCoverage();
checkPreferences();
console.log('ok - site accessibility ratchet, baseline, page coverage and preferences');
