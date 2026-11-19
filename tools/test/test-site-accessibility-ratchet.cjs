// tools/test/test-site-accessibility-ratchet.cjs

/**
 * ==============================================================================
 * MODULE: Site Accessibility Ratchet Contract
 * DESCRIPTION:
 * The browser scan (tools/test/browser/site-accessibility.playwright.cjs) runs
 * in CI on the built site; this check runs everywhere, without a browser, and
 * proves the parts a passing scan cannot: the ratchet refuses a new or higher
 * count, the committed baseline is well formed, every real page of the site
 * is audited, the visitor's accessibility preferences survive blocked
 * storage and refuse unknown values (static/ergopti_plus/_shared/ui/a11y_prefs.js),
 * the reading ratchet (site-reading.cjs) applies the WCAG 1.4.12 values and
 * names only known rows, no source justifies text, and nothing outside the
 * header offsets by its minimum height instead of its measured one.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const scan = require('./browser/site-accessibility.playwright.cjs');
const reading = require('./browser/site-reading.cjs');

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

/**
 * No button inside a link anywhere on the site: two focus stops for one
 * action and an invalid tree for assistive technology (axe does not flag a
 * button in a link). A download or a page reached from a button look is a
 * link styled as one (src/lib/css/buttons.css, .button-link).
 */
function checkNoButtonInLink() {
	const offenders = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (entry.name.endsWith('.svelte')) {
				const source = fs.readFileSync(full, 'utf8');
				// A link's opening tag, then a button before that link closes.
				for (const match of source.matchAll(/<a\b[^>]*>((?:(?!<\/a\s*>)[\s\S])*?)<button\b/g))
					offenders.push(path.relative(ROOT, full) + ' @' + match.index);
			}
		}
	};
	walk(path.join(ROOT, 'src'));
	assert.deepEqual(offenders, [], 'A button nested in a link');
	// The check itself finds the shape it forbids.
	assert.match('<a href="x" download>\n\t<button>y</button></a>', /<a\b[^>]*>[\s\S]*?<button\b/);
}

/**
 * The Ergopti+ hero demo cycles on its own for longer than five seconds, so
 * it offers a pause (WCAG 2.2.2): the button exists, stops the cycle and
 * starts it again, and the page translates its words.
 */
function checkHeroPause() {
	const hero = fs.readFileSync(path.join(ROOT, 'src/routes/ergopti-plus/Hero.svelte'), 'utf8');
	assert.match(
		hero,
		/class="demo-pause"[^>]*onclick=\{togglePause\}/,
		'The hero has a pause button'
	);
	assert.match(hero, /if \(!cycles \|\| paused\) \{/, 'A pause stops the cycle');
	const english = fs.readFileSync(path.join(ROOT, 'src/routes/ergopti-plus/locales/en.js'), 'utf8');
	for (const words of ['Mettre la démo en pause', 'Relancer la démo'])
		assert.ok(english.includes(`'${words}'`), 'English for ' + words);
}

/**
 * The reading ratchet (site-reading.cjs): its rows are counted per page,
 * reading mode and check, its baseline only names audited pages, known modes
 * and their checks, and the « zoom » mode applies the WCAG 1.4.12 values.
 */
function checkReadingRatchet() {
	assert.deepEqual(Object.keys(reading.READING_MODES).sort(), ['default', 'text', 'zoom']);
	for (const value of [
		'line-height: 1.5',
		'letter-spacing: 0.12em',
		'word-spacing: 0.16em',
		'margin-bottom: 2em'
	])
		assert.ok(reading.TEXT_SPACING_CSS.includes(value), 'WCAG 1.4.12 spacing: ' + value);
	assert.deepEqual(reading.READING_MODES.text.preferences, { text: '200', spacing: 'wide' });
	// 200 % zoom of the scan's 1440 × 900 window: half the CSS pixels, twice the device pixels.
	assert.deepEqual(reading.READING_MODES.zoom.viewport, { width: 720, height: 450 });
	assert.equal(reading.READING_MODES.zoom.deviceScaleFactor, 2);
	assert.equal(reading.MAX_LINE_CHARACTERS, 80);
	assert.deepEqual(
		scan.readingCountsOf([
			{ route: '/b', mode: 'text', check: 'text-clipped', elements: ['x', 'y'] },
			{ route: '/a', mode: 'zoom', check: 'text-overlap', elements: [] }
		]),
		{ '/b | text | text-clipped': 2 },
		'Rows without an element are left out'
	);
	for (const key of Object.keys(scan.readBaseline(scan.READING_BASELINE_PATH, 3))) {
		const [route, mode, check] = key.split(' | ');
		assert.ok(
			scan.AUDITED_ROUTES.includes(route),
			'Reading baseline names an unaudited page: ' + key
		);
		assert.ok(
			reading.READING_MODES[mode]?.checks.includes(check),
			'Reading baseline names an unknown mode or check: ' + key
		);
	}
	const options = reading.optionsFor('default');
	assert.deepEqual(options.checks, ['justified-text', 'line-length']);
	// The header grows with the text: what sits under it is checked where it grows.
	for (const mode of ['zoom', 'text'])
		assert.ok(reading.READING_MODES[mode].checks.includes('header-cover'), mode + ' header cover');
	assert.equal(reading.optionsFor('text').headerSelector, reading.SITE_HEADER_SELECTOR);
	assert.throws(() => reading.optionsFor('huge'), /Unknown reading mode/);
}

/**
 * No justified text anywhere on the site (WCAG 1.4.8): the uneven word gaps
 * make « rivers » that dyslexic readers lose their line in. The browser gate
 * counts justified blocks on the built pages; this one refuses the rule in the
 * sources, where it is cheaper to see.
 */
function checkNoJustifiedText() {
	const offenders = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (/\.(css|svelte)$/.test(entry.name)) {
				const source = fs.readFileSync(full, 'utf8');
				for (const match of source.matchAll(/text-align\s*:\s*justify|text-justify\s*:/g))
					offenders.push(path.relative(ROOT, full) + ' @' + match.index);
			}
		}
	};
	walk(path.join(ROOT, 'src'));
	assert.deepEqual(offenders, [], 'Justified text on the site');
}

/**
 * The sticky header is at least --header-height tall and grows with the
 * text, so a box placed under it offsets by --header-offset, its measured
 * height (Header.svelte). Only the header itself reads the minimum; a new
 * offender would be listed here, so the list can only shrink.
 */
const HEADER_HEIGHT_PENDING = Object.freeze([]);
function checkHeaderOffset() {
	const users = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (/\.(css|svelte)$/.test(entry.name)) {
				const source = fs.readFileSync(full, 'utf8');
				if (source.includes('var(--header-height)'))
					users.push(path.relative(ROOT, full).split(path.sep).join('/'));
			}
		}
	};
	walk(path.join(ROOT, 'src'));
	assert.deepEqual(
		users.sort(),
		['src/lib/components/Header.svelte', ...HEADER_HEIGHT_PENDING].sort(),
		'Offset by var(--header-offset), the header measured height, not its minimum'
	);
	const header = fs.readFileSync(path.join(ROOT, 'src/lib/components/Header.svelte'), 'utf8');
	assert.match(header, /new ResizeObserver/, 'The header measures itself');
	assert.match(header, /setProperty\('--header-offset'/, 'The header publishes its height');
}

checkComparison();
checkBaseline();
checkRouteCoverage();
checkPreferences();
checkNoButtonInLink();
checkHeroPause();
checkReadingRatchet();
checkNoJustifiedText();
checkHeaderOffset();
console.log(
	'ok - site accessibility ratchet, baseline, page coverage, preferences, links, hero pause, reading ratchet, no justified text and header offset'
);
