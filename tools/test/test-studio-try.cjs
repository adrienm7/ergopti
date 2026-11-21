// tools/test/test-studio-try.cjs

/**
 * ==============================================================================
 * MODULE: Studio « Essayer » Tab Gate
 * DESCRIPTION:
 * Ergopti Studio's « Essayer » tab (maintainer, 2026-11-21) types with any
 * layout of the Studio's library in the browser and replaces the site's
 * former « Essayer » page. This gate holds what runs without a browser.
 *
 * WHAT IS CHECKED:
 * 1. Typing (layout_try/typing.js on the generated library): a sample of
 *    Ergopti's keys on its four levels, its dead keys (a rule, Space, a key
 *    without a rule, a chained dead key), Caps Lock, keys the layout does not
 *    hold, and another layout (bépo) typing its own characters.
 * 2. Address: the frame takes ?layout= and the former page's anchors only,
 *    in French; the message and default layout the site and the page share
 *    are spelled the same on both sides.
 * 3. Site: the Studio lists the tab, frames the page, follows the layout
 *    picked; the Disposition Ergopti's « Essayer » opens the tab on Ergopti;
 *    /ergopti/utilisation redirects there and the former anchors follow, a
 *    visited query kept after the target's.
 * 4. Page: index.html loads its scripts in order, and every layout_try.* key
 *    the page shows exists in the 21 locales with English's placeholders.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { pathToFileURL } = require('node:url');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const UI = shared('ui');
const PAGE_DIR = path.join(UI, 'layout_try');
const LOCALES_DIR = shared('core', 'i18n', 'data', 'locales');
const SCRIPTS = [
	'../a11y_prefs.js',
	'../theme_choice.js',
	'../i18n.js',
	'../host_bridge.js',
	'../layout_analysis/_generated/analysis_data.js',
	'../layout_analysis/analysis_engine.js',
	'../layout_analysis/info_popover.js',
	'typing.js',
	'try_page.js'
];
// Floor: a page that lost its strings must not read as complete.
const MIN_KEYS = 12;

const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const read = (file) => fs.readFileSync(file, 'utf8');

/** The library and the typist, loaded as the page loads them. */
function load() {
	const context = vm.createContext({ window: {} });
	context.window = context;
	const data = read(path.join(UI, 'layout_analysis', '_generated', 'analysis_data.js')).replace(
		/^const LAYOUT_ANALYSIS_DATA =/m,
		'var LAYOUT_ANALYSIS_DATA ='
	);
	vm.runInContext(data, context, { filename: 'analysis_data.js' });
	vm.runInContext(read(path.join(PAGE_DIR, 'typing.js')), context, { filename: 'typing.js' });
	return vm.runInContext('({ DATA: LAYOUT_ANALYSIS_DATA, T: LAYOUT_TRY_TYPING })', context);
}

const { DATA, T } = load();
const layout = (id) => {
	const found = DATA.layouts.find((entry) => entry.id === id);
	assert.ok(found, `the library has ${id}`);
	return found;
};

/** Types a list of presses, each [code, held], and returns the text. */
function type(typist, presses) {
	let text = '';
	for (const [code, held] of presses) text += typist.press(code, held || {}).text;
	return text;
}

const plain = (value) => JSON.parse(JSON.stringify(value));
const SHIFT = { shift: true };
const ALTGR = { altgr: true };

test("Ergopti's keys type on their four levels", () => {
	const typist = T.create(layout('ergopti'));
	assert.equal(type(typist, [['KeyQ'], ['KeyW'], ['KeyE'], ['KeyA']]), 'èyoa');
	assert.equal(type(typist, [['KeyE', SHIFT]]), 'O');
	assert.equal(type(typist, [['KeyA', ALTGR]]), '<', 'AltGr reaches the third level');
	assert.equal(type(typist, [['KeyE', { shift: true, altgr: true }]]), 'Œ');
	assert.equal(type(typist, [['Digit1', SHIFT]]), '1');
	assert.equal(typist.level({ altgr: true }), 'altgr');
	assert.equal(typist.legend('KeyQ', 'base'), 'è');
});

test("Ergopti's dead keys wait, then give their rule, their own character or both", () => {
	const typist = T.create(layout('ergopti'));
	// Backslash is the circumflex dead key of Ergopti's base level.
	assert.deepEqual(plain(typist.press('Backslash', {})), {
		owned: true,
		text: '',
		pending: 's1_circumflex'
	});
	assert.equal(typist.pending(), '^');
	assert.equal(type(typist, [['KeyD']]), 'ê', 'the rule: ^ then e');
	assert.equal(typist.pending(), null);
	assert.equal(type(typist, [['Backslash'], ['Space']]), '^', 'Space gives its own character');
	// The diaeresis dead key (BracketRight) and a key it has no rule for.
	const table = layout('ergopti').dead.s3_diaeresis;
	const lacking = ['KeyW', 'KeyJ', 'KeyH'].find(
		(code) => !(layout('ergopti').rows[code][0] in table)
	);
	assert.ok(lacking, 'a key without a diaeresis rule');
	const char = layout('ergopti').rows[lacking][0];
	assert.equal(
		type(typist, [['BracketRight'], [lacking]]),
		table[' '] + char,
		'no rule: the dead key then the key'
	);
	// Two dead keys: the rule for the second, or the first's character and the second waiting.
	typist.press('BracketRight', {});
	const second = typist.press('Backslash', {});
	const rule = table['dead:s1_circumflex'];
	if (typeof rule === 'string') assert.equal(second.text, rule);
	else assert.equal(second.text + String(second.pending), table[' '] + 's1_circumflex');
	typist.reset();
	assert.equal(typist.pending(), null);
});

test('Caps Lock shifts a letter, not a symbol', () => {
	const typist = T.create(layout('ergopti'));
	assert.equal(type(typist, [['KeyE', { caps: true }]]), 'O');
	assert.equal(type(typist, [['KeyE', { caps: true, shift: true }]]), 'O');
	assert.equal(type(typist, [['Digit1', { caps: true }]]), '1');
});

test('a key the layout does not hold is left to the browser', () => {
	const typist = T.create(layout('ergopti'));
	assert.deepEqual(plain(typist.press('Backspace', {})), { owned: false, text: '', pending: null });
	assert.equal(typist.owns('ArrowLeft'), false);
	assert.throws(() => T.create({ id: 'x' }), /rows/);
	assert.throws(() => typist.legend('KeyQ', 'level5'), /no level/);
	const broken = T.create({
		id: 'broken',
		rows: { KeyQ: [{ dead: 'nowhere' }, null, null, null] }
	});
	assert.throws(() => broken.press('KeyQ', {}), /undeclared dead key/);
});

test('another layout of the library types its own characters', () => {
	const typist = T.create(layout('bepo'));
	assert.equal(type(typist, [['KeyQ'], ['KeyW']]), 'bé');
	assert.notEqual(
		type(T.create(layout('azerty')), [['KeyQ']]),
		type(T.create(layout('qwerty')), [['KeyQ']])
	);
});

test('the frame takes ?layout= and the former anchors, in French, one spelling on both sides', async () => {
	const link = await import(
		pathToFileURL(path.join(REPO_ROOT, 'src', 'lib', 'js', 'tryLink.js')).href
	);
	const page = 'https://x/ui/layout_try/index.html';
	assert.equal(link.trySrc(page, '', ''), page + '?lang=fr');
	assert.equal(link.trySrc(page, '?layout=bepo&other=1', ''), page + '?lang=fr&layout=bepo');
	assert.equal(
		link.trySrc(page, '?layout=ergopti', '#input-text'),
		page + '?lang=fr&layout=ergopti#input-text'
	);
	assert.equal(link.trySrc(page, '', '#keyboard_emulation'), page + '?lang=fr#keyboard_emulation');
	assert.equal(
		link.trySrc(page, '', '#elsewhere'),
		page + '?lang=fr',
		'an unknown anchor is not handed on'
	);
	const source = read(path.join(PAGE_DIR, 'try_page.js'));
	assert.ok(
		source.includes(`const LAYOUT_MESSAGE = '${link.TRY_LAYOUT_MESSAGE}';`),
		'one message type'
	);
	assert.ok(
		source.includes(`const DEFAULT_LAYOUT = '${link.TRY_DEFAULT_LAYOUT}';`),
		'one default layout'
	);
	for (const anchor of link.TRY_ANCHORS)
		assert.ok(source.includes(`id="${anchor}"`), `the page has #${anchor}`);
});

test('the site lists the tab, frames the page and redirects the former page there', async () => {
	const nav = await import(
		pathToFileURL(path.join(REPO_ROOT, 'src', 'lib', 'js', 'siteNavigation.js')).href
	);
	assert.ok(
		nav.STUDIO_PAGES.some(
			(entry) => entry.route === '/studio/essayer' && entry.label === 'Essayer'
		),
		'the Studio tab bar lists « Essayer »'
	);
	const essayer = nav.LAYOUT_PAGES.find((entry) => entry.label === 'Essayer');
	assert.deepEqual([essayer.route, essayer.query], ['/studio/essayer', 'layout=ergopti']);
	assert.equal(nav.LEGACY_PAGES['/ergopti/utilisation'].target, '/studio/essayer?layout=ergopti');
	assert.equal(
		nav.legacyTarget(nav.LEGACY_PAGES['/utilisation'], '#input-text'),
		'/studio/essayer?layout=ergopti#input-text'
	);
	assert.equal(
		nav.resolveWithQuery('/studio/essayer?layout=ergopti', (route) => '/dev' + route),
		'/dev/studio/essayer?layout=ergopti'
	);
	assert.equal(
		nav.resolveWithQuery('/studio', (route) => '/dev' + route),
		'/dev/studio'
	);
	// The inline redirect, run on the former address with an anchor and a query.
	const component = read(path.join(REPO_ROOT, 'src', 'lib', 'components', 'LegacyRedirect.svelte'));
	const expression = component.match(/let forward = \$derived\(([\s\S]*?)\n\t\);/);
	assert.ok(expression, 'the inline redirect script');
	const forward = (from, href) => {
		const legacy = nav.LEGACY_PAGES[from];
		const tag = vm.runInNewContext(expression[1], { JSON, from, legacy });
		const code = tag.replace(/^<script>/, '').replace(/<\/script>$/, '');
		const url = new URL(href);
		let replaced = null;
		const location = {
			pathname: url.pathname,
			hash: url.hash,
			search: url.search,
			replace: (to) => (replaced = to)
		};
		vm.runInNewContext(code, { location, window: {}, decodeURIComponent });
		return replaced;
	};
	assert.equal(
		forward('/ergopti/utilisation', 'https://x/dev/ergopti/utilisation'),
		'/dev/studio/essayer?layout=ergopti'
	);
	assert.equal(
		forward('/ergopti/utilisation', 'https://x/ergopti/utilisation/?a=1#input-text'),
		'/studio/essayer?layout=ergopti&a=1#input-text'
	);
	assert.equal(
		forward('/utilisation', 'https://x/utilisation#keyboard_emulation'),
		'/studio/essayer?layout=ergopti#keyboard_emulation'
	);
	assert.equal(
		forward('/utilisation', 'https://x/utilisation#linux'),
		'/ergopti/installation#linux'
	);
	const route = read(path.join(REPO_ROOT, 'src', 'routes', 'studio', 'essayer', '+page.svelte'));
	assert.ok(
		route.includes("asset('ergopti_plus/_shared/ui/layout_try/index.html')"),
		'the tab frames the page'
	);
	assert.ok(route.includes('TRY_LAYOUT_MESSAGE'), 'the tab follows the layout picked');
	const former = read(
		path.join(REPO_ROOT, 'src', 'routes', 'ergopti', 'utilisation', '+page.svelte')
	);
	assert.ok(
		former.includes('<LegacyRedirect from="/ergopti/utilisation" />'),
		'the former page redirects'
	);
});

test('the page loads its scripts in order and its strings exist in 21 locales', () => {
	const html = read(path.join(PAGE_DIR, 'index.html'));
	assert.deepEqual(
		[...html.matchAll(/<script src="([^"]+)"/g)].map((m) => m[1]),
		SCRIPTS
	);
	for (const file of SCRIPTS) assert.ok(fs.existsSync(path.join(PAGE_DIR, file)), `${file} exists`);
	const source = read(path.join(PAGE_DIR, 'try_page.js'));
	const keys = new Set();
	for (const m of source.matchAll(/data-i18n="(layout_try\.[a-z_.]+)"/g)) keys.add(m[1]);
	for (const m of source.matchAll(/`\$\{PREFIX\}([a-z_.]+)`/g)) keys.add(`layout_try.${m[1]}`);
	for (const level of T.LEVELS) keys.add(`layout_try.level.${level}`);
	for (const origin of ['registry', 'reference'])
		keys.add(`layout_analysis.filter.origin_${origin}`);
	assert.ok(keys.size >= MIN_KEYS, `only ${keys.size} keys were found`);
	const order = JSON.parse(read(shared('core', 'i18n', 'data', 'locale_order.json'))).order;
	const en = JSON.parse(read(path.join(LOCALES_DIR, 'en.json')));
	const placeholders = (text) => [...String(text).matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
	for (const lang of order) {
		const catalogue = JSON.parse(read(path.join(LOCALES_DIR, `${lang}.json`)));
		for (const key of keys) {
			assert.equal(typeof catalogue[key], 'string', `${lang}.json lacks ${key}`);
			assert.deepEqual(placeholders(catalogue[key]), placeholders(en[key]), `${lang} ${key}`);
		}
	}
});

(async () => {
	let failed = 0;
	for (const [name, fn] of tests) {
		try {
			await fn();
			console.log(`ok - ${name}`);
		} catch (error) {
			failed += 1;
			console.error(`not ok - ${name}\n${error.stack}`);
		}
	}
	if (failed) {
		console.error(`FAIL test-studio-try (${failed} of ${tests.length})`);
		process.exit(1);
	}
	console.log(`PASS test-studio-try (${tests.length} tests)`);
})();
