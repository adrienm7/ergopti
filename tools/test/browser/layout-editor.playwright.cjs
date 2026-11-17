// tools/test/browser/layout-editor.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Unified Layout Editor Browser Regression
 * DESCRIPTION:
 * Drives the standalone editor page (the one the website frames) in Chromium
 * from a loopback server: edit a key and see its legend, type through a dead
 * key in the live preview, save the TOML and read it back, import a registry
 * .keylayout, export it unchanged, convert it, import the navigation layer,
 * show and add the Base, Shift, AltGr and Shift+AltGr layers from the layer
 * selector, lay out at phone width in light and dark without a sideways page
 * scroll, fit every key label inside its key, override shortcuts per modifier
 * combination through save and reload, and check that no raw locale key is shown in any tool tab of the 21
 * locales. Page errors and requests outside the loopback origin fail the gate.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');
const { shared } = require('../../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const KEYLAYOUT = path.join(ROOT, 'static', 'layouts', 'registry', 'ergopti', 'ergopti.keylayout');
const NAV = shared('layouts', 'data', 'layers.recommended.toml');
const SOURCE_FIXTURE = shared('tests', 'corpus', 'layouts', 'source', 'source.toml');
const LOCALES = JSON.parse(
	fs.readFileSync(shared('core', 'i18n', 'data', 'locale_order.json'), 'utf8')
).order;
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};

// The XKB converter data the site serves beside the shared tree, at the URL the
// standalone host computes from the page (../../../../ergopti/linux/...).
const XKB_DATA_URL = '/ergopti/linux/xkb_generation/data/';
const XKB_DATA = path.join(ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data');

/** Serves the shared tree and the XKB converter data read-only on loopback. */
function serve() {
	const server = http.createServer((request, response) => {
		const pathname = new URL(request.url, 'http://localhost').pathname;
		const [root, relative] = pathname.startsWith(XKB_DATA_URL)
			? [XKB_DATA, pathname.slice(XKB_DATA_URL.length)]
			: [shared(), pathname.slice(1)];
		const file = path.resolve(root, relative);
		if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
			response.writeHead(404);
			response.end();
			return;
		}
		response.setHeader('Content-Type', TYPES[path.extname(file)] || 'application/octet-stream');
		fs.createReadStream(file).pipe(response);
	});
	return new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => resolve(server));
	});
}

/**
 * Gives every browser the removal semantics of the engines that commit a focused
 * field's change while removing it (Chromium in CI, the drivers' webviews):
 * replaceChildren removes the old children one by one and, before removing the
 * one holding focus, fires that field's change while it is still attached. A
 * handler that re-renders there makes the replacement throw, as it did in CI on
 * 2026-11-14; other Chromium builds do not fire it, so the page must not depend
 * on either behaviour. Runs in the page (from worker G's 90b2446702).
 */
function commitFocusedFieldOnRemoval() {
	const replace = Element.prototype.replaceChildren;
	Element.prototype.replaceChildren = function (...nodes) {
		for (const child of [...this.childNodes]) {
			const active = document.activeElement;
			if (active && active !== document.body && child.contains(active))
				active.dispatchEvent(new Event('change', { bubbles: true }));
			if (child.parentNode !== this)
				throw new DOMException(
					"Failed to execute 'replaceChildren' on 'Element': The node to be removed is no longer a child of this node.",
					'NotFoundError'
				);
			child.remove();
		}
		replace.apply(this, nodes);
	};
}

async function open(browser, origin, lang) {
	const context = await browser.newContext({
		acceptDownloads: true,
		viewport: { width: 1280, height: 900 }
	});
	await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin });
	await context.addInitScript(commitFocusedFieldOnRemoval);
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('request', (request) => {
		if (!request.url().startsWith(origin + '/') && !request.url().startsWith('blob:'))
			errors.push(`unexpected request: ${request.url()}`);
	});
	page.on('dialog', (dialog) => errors.push(`native dialog: ${dialog.message()}`));
	await page.goto(`${origin}/ui/layout_editor/index.html?lang=${lang}`);
	await page.waitForFunction(() => document.title && !document.title.startsWith('layout_editor.'));
	return { page, errors };
}

/** Shows one of the editor's secondary tools (the tab strip under the board). */
function tool(page, id) {
	return page.click(`#le-tools [data-tool="${id}"]`);
}

/**
 * Downloads one format through the export section's « Format » drop-down and
 * its « Download » button.
 * @param {import('playwright').Page} page
 * @param {string} id - A download id (toml, macos_iso, xkb, kla…).
 */
async function exportAs(page, id) {
	await page.selectOption('#le-export-format', id);
	await page.click('#le-export-download');
}

/**
 * The download ids the export « Format » drop-down offers, in order.
 * @param {import('playwright').Page} page
 * @returns {Promise<string[]>}
 */
function exportFormats(page) {
	return page.$$eval('#le-export-format option', (options) => options.map((o) => o.value));
}

/** The raw locale keys the page shows (texts, placeholders and titles). */
function rawKeys(page) {
	return page.evaluate(() => {
		const texts = [document.title];
		for (const node of document.querySelectorAll('body *')) {
			if (node.children.length === 0) texts.push(node.textContent);
			if (node.placeholder) texts.push(node.placeholder);
			if (node.title) texts.push(node.title);
			if (node.getAttribute('aria-label')) texts.push(node.getAttribute('aria-label'));
		}
		return texts.filter((text) => /layout_editor\.|sg_actions\.|layer_editor\./.test(text));
	});
}

async function downloaded(page, click) {
	const [download] = await Promise.all([page.waitForEvent('download'), click()]);
	return {
		name: download.suggestedFilename(),
		text: fs.readFileSync(await download.path(), 'utf8')
	};
}

/**
 * Answers every corpus request the window has posted (studio_corpus) as the app
 * hosts do: the generated file runs in the page, then the request settles.
 * @param {import('playwright').Page} page
 */
async function serveCorpora(page) {
	const ids = await page.evaluate(() => [
		...new Set(
			window.__posted.filter((p) => p.action === 'studio_corpus' && !p.served).map((p) => p.id)
		)
	]);
	for (const id of ids)
		await page.addScriptTag({
			path: shared('ui', 'layout_analysis', '_generated', 'corpus_' + id + '.js')
		});
	await page.evaluate(() => {
		for (const posted of window.__posted)
			if (posted.action === 'studio_corpus' && !posted.served) {
				posted.served = true;
				window.studioCorpus({ request: posted.request, ok: true });
			}
	});
}

/**
 * (studio-compare-edited) « Compare with other layouts » in the editor's
 * analysis panel shows the edited layout in « Comparer », ticked and ranked
 * with the layouts chosen there.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
/**
 * The Studio window in a dark system appearance and a wide window: the page
 * and the Comparer it hosts follow the dark theme (they were dark text on a
 * light page, from light-only tokens), the analysis panel spans the editor's
 * width in columns (a later 420 px cap left it one tall strip), and the tab
 * bar keeps its tabs' focus ring inside the window.
 */
async function exerciseStudioLayout(browser, origin) {
	const context = await browser.newContext({
		colorScheme: 'dark',
		viewport: { width: 1400, height: 900 }
	});
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.addInitScript(() => {
		window.webkit = {
			messageHandlers: { layout_editor_window_bridge: { postMessage: () => {} } }
		};
	});
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	await page.goto(`${origin}/ui/layout_editor_window/index.html`);
	await page.evaluate(
		(strings) => window.initData({ strings, state: { platform: 'linux' } }),
		strings
	);
	await page.evaluate(
		(text) => window.sourceData({ filename: 'source.toml', text, folder: 'layout_sources/' }),
		fs.readFileSync(SOURCE_FIXTURE, 'utf8')
	);
	await page.waitForSelector('#le-side-slot > .la-panel');
	const luminance = (color) => {
		const [r, g, b] = color.match(/\d+(\.\d+)?/g).map(Number);
		return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
	};
	const colours = await page.evaluate(() => ({
		body: getComputedStyle(document.body).backgroundColor,
		text: getComputedStyle(document.body).color,
		tabs: getComputedStyle(document.querySelector('.studio-tabs')).backgroundColor
	}));
	assert.ok(luminance(colours.body) < 0.3, `a dark page, got ${colours.body}`);
	assert.ok(luminance(colours.tabs) < 0.3, `a dark tab bar, got ${colours.tabs}`);
	assert.ok(luminance(colours.text) > 0.7, `light text, got ${colours.text}`);
	const widths = await page.evaluate(() => ({
		slot: document.getElementById('le-side-slot').getBoundingClientRect().width,
		panel: document.querySelector('#le-side-slot > .la-panel').getBoundingClientRect().width,
		columns: getComputedStyle(document.querySelector('.la-panel-body')).gridTemplateColumns.split(
			' '
		).length
	}));
	assert.ok(widths.panel >= widths.slot - 1, `the panel fills its slot: ${JSON.stringify(widths)}`);
	assert.equal(widths.columns, 3, 'a wide panel lays its sections out in three columns');
	const ring = await page.evaluate(() => {
		const tab = document.getElementById('studio-tab-edit');
		const box = tab.getBoundingClientRect();
		const offset = parseFloat(getComputedStyle(tab).outlineOffset);
		const width = parseFloat(getComputedStyle(tab).outlineWidth);
		return { top: box.top, left: box.left, reach: Math.max(0, width + offset) };
	});
	assert.ok(
		ring.top >= ring.reach && ring.left >= ring.reach,
		`the tab's ring stays inside the window: ${JSON.stringify(ring)}`
	);
	await page.click('#studio-tab-compare');
	// « My typing » first, under its own heading, at once while the app reads it,
	// then chosen when it arrives (maintainer, 2026-11-17).
	await page.evaluate(() =>
		document.dispatchEvent(
			new CustomEvent('studio-ngrams-state', { detail: { state: 'loading', reason: '' } })
		)
	);
	const first = await page.evaluate(() => {
		const option = document.querySelector('#la-corpus optgroup option');
		return { value: option.value, disabled: option.disabled };
	});
	assert.deepEqual(first, { value: 'my_typing', disabled: true }, 'listed first while it is read');
	await page.evaluate(() =>
		document.dispatchEvent(
			new CustomEvent('studio-ngrams', {
				detail: {
					schema: 1,
					source: 'keystats',
					total: 60,
					chars: { e: 20, s: 12, a: 10, n: 8, ' ': 10 },
					bigrams: { es: 6, en: 5, 'e ': 8, ' a': 4 },
					trigrams: { 'es ': 3 }
				}
			})
		)
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-chart .la-bar').length > 1);
	const comparer = await page.evaluate(() => ({
		corpus: document.getElementById('la-corpus').value,
		mine: document.getElementById('la-corpus').classList.contains('la-corpus-mine'),
		listOpen: document.getElementById('la-layouts-box').open,
		summary: document.getElementById('la-layouts-summary').textContent,
		widths: [...document.querySelectorAll('#la-chart .la-bar')].map((bar) =>
			parseFloat(bar.style.width)
		),
		zero: document.querySelectorAll('#la-chart .la-zero').length
	}));
	assert.equal(comparer.corpus, 'my_typing', 'the user’s typing becomes the corpus');
	assert.ok(comparer.mine, 'and the picker shows it');
	assert.equal(comparer.listOpen, false, 'the layout list is folded');
	assert.match(comparer.summary, /^\d+ layouts compared: /, 'its line counts the compared layouts');
	assert.equal(comparer.widths[0], 100, 'the best layout has the full bar');
	assert.deepEqual(
		comparer.widths,
		[...comparer.widths].sort((a, b) => b - a),
		'the bars shorten from the best to the weakest'
	);
	assert.equal(comparer.zero, 0, 'no zero line');
	const heading = await page.evaluate(
		() => getComputedStyle(document.querySelector('#studio-comparer')).color
	);
	assert.ok(luminance(heading) > 0.7, `the Comparer's text is light, got ${heading}`);
	// « Create or edit a layout… » on a Studio left on « Comparer » (maintainer,
	// 2026-11-17): the host's studioTab brings the editor back, and so does a
	// « Navigation layer » entry's studioNav.
	const shown = () =>
		page.evaluate(() => ({
			editor: !document.getElementById('layout-editor').hidden,
			comparer: !document.getElementById('studio-comparer').hidden,
			selected: document.getElementById('studio-tab-edit').getAttribute('aria-selected')
		}));
	await page.evaluate(() => window.studioTab('edit'));
	assert.deepEqual(await shown(), { editor: true, comparer: false, selected: 'true' });
	await page.click('#studio-tab-compare');
	await page.evaluate(() => window.studioTab('nowhere'));
	assert.equal((await shown()).comparer, true, 'an unknown tab changes nothing');
	await page.evaluate(() => window.studioNav({ text: '', hold: null }));
	assert.deepEqual(await shown(), { editor: true, comparer: false, selected: 'true' });
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseCompareEdited(browser, origin) {
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.addInitScript((strings) => {
		window._i18n_strings = strings;
		window.__posted = [];
		window.webkit = {
			messageHandlers: {
				layout_editor_window_bridge: { postMessage: (payload) => window.__posted.push(payload) }
			}
		};
	}, strings);
	await page.goto(`${origin}/ui/layout_editor_window/index.html`);
	await page.evaluate(() =>
		window.initData({ strings: {}, state: { platform: 'linux' }, studio_store: true })
	);
	await page.evaluate(
		(text) => window.sourceData({ filename: 'source.toml', text, folder: 'layout_sources/' }),
		fs.readFileSync(SOURCE_FIXTURE, 'utf8')
	);
	const button = page.locator('#la-panel-compare');
	await button.waitFor({ state: 'visible' });
	assert.equal((await button.textContent()).trim(), strings['layout_analysis.panel.compare']);
	await button.click();
	assert.equal(await page.isVisible('#studio-comparer'), true, 'the click opens « Comparer »');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'studio_layouts'));
	await page.evaluate(() => {
		const list = window.__posted.find((p) => p.action === 'studio_layouts');
		window.studioLayouts({ request: list.request, ok: true, layouts: [] });
	});
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'studio_corpus'));
	await serveCorpora(page);
	await page.waitForFunction(() =>
		[...document.querySelectorAll('#la-table tbody tr')].some((row) =>
			row.textContent.includes('Source Fixture')
		)
	);
	assert.equal(
		await page.evaluate(() =>
			[...document.querySelectorAll('#la-layout-list label')].some(
				(label) =>
					label.textContent.includes('Source Fixture') && label.querySelector('input').checked
			)
		),
		true,
		'the edited layout is ticked in the list'
	);
	// (compare-reuses-editor-entry) The click ticks the editor_… entry the
	// Comparer already lists: the edited layout once, never also as a copy.
	assert.deepEqual(
		await page.$$eval('#la-layout-list .la-layout', (labels) =>
			labels
				.filter((label) => label.textContent.includes('Source Fixture'))
				.map((label) => label.querySelector('input').checked)
		),
		[true],
		'the edited layout is listed once, ticked'
	);
	assert.equal(
		await page.evaluate(
			() => window.__posted.filter((p) => p.action === 'studio_layout_save').length
		),
		0,
		'the edited layout is not stored with the personal layouts'
	);
	assert.deepEqual(errors, []);
	await page.close();
}

/**
 * (studio-opens-on-ergopti) With no saved source, the Studio window opens on a
 * copy of Ergopti, not an empty keyboard, once the host lists its sources; a
 * file the user opened in the meantime is kept.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseOpensOnErgopti(browser, origin) {
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	const keylayout = fs.readFileSync(KEYLAYOUT, 'utf8');
	const openWindow = async () => {
		const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
		const errors = [];
		page.on('pageerror', (error) => errors.push(error.message));
		await page.addInitScript((strings) => {
			window._i18n_strings = strings;
			window.__posted = [];
			window.webkit = {
				messageHandlers: {
					layout_editor_window_bridge: { postMessage: (payload) => window.__posted.push(payload) }
				}
			};
		}, strings);
		await page.goto(`${origin}/ui/layout_editor_window/index.html`);
		await page.evaluate(() => window.initData({ strings: {}, state: { platform: 'linux' } }));
		await page.evaluate(() => window.sourceData({ text: null, folder: 'layout_sources/' }));
		await page.waitForSelector('#layout-editor #le-board');
		await page.waitForFunction(() => window.__posted.some((p) => p.action === 'composer_open'));
		return { page, errors };
	};
	const answer = (page) =>
		page.evaluate(
			(text) =>
				window.composerData({
					sources: [{ id: 'ergopti', name: 'Ergopti', convention: 'iso', text }]
				}),
			keylayout
		);
	const name = (page) => page.inputValue('#le-name');

	const { page, errors } = await openWindow();
	await answer(page);
	await tool(page, 'details');
	await page.waitForFunction(
		(expected) => document.querySelector('#le-name').value === expected,
		strings['layout_editor.start.copy_name'].replace('{name}', 'Ergopti')
	);
	assert.deepEqual(errors, []);
	await page.close();

	const kept = await openWindow();
	await kept.page.setInputFiles('#le-open-file', SOURCE_FIXTURE);
	await tool(kept.page, 'details');
	await kept.page.waitForFunction(
		() => document.querySelector('#le-name').value === 'Source Fixture'
	);
	// composerData settles the sources and the opening start in the same task.
	await answer(kept.page);
	assert.equal(await name(kept.page), 'Source Fixture', 'a file opened first is kept');
	assert.deepEqual(kept.errors, []);
	await kept.page.close();
}

/**
 * (studio-nav-entry) The drivers' « Navigation layer » entries open the Studio
 * on its nav layer: studioNav, pushed before the source as the hosts do, waits
 * for the opening start (a copy of Ergopti), then imports the user's
 * layers.toml as the nav layer held by the key the host names. Without that
 * key the « Navigation » tool opens and says to choose it.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseStudioNav(browser, origin) {
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	const keylayout = fs.readFileSync(KEYLAYOUT, 'utf8');
	const layers = fs.readFileSync(shared('layouts', 'data', 'layers.recommended.toml'), 'utf8');
	const openWindow = async (nav) => {
		const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
		const errors = [];
		page.on('pageerror', (error) => errors.push(error.message));
		await page.addInitScript((strings) => {
			window._i18n_strings = strings;
			window.__posted = [];
			window.webkit = {
				messageHandlers: {
					layout_editor_window_bridge: { postMessage: (payload) => window.__posted.push(payload) }
				}
			};
		}, strings);
		await page.goto(`${origin}/ui/layout_editor_window/index.html`);
		await page.evaluate(() => window.initData({ strings: {}, state: { platform: 'linux' } }));
		await page.evaluate((nav) => window.studioNav(nav), nav);
		await page.evaluate(() => window.sourceData({ text: null, folder: 'layout_sources/' }));
		await page.waitForSelector('#layout-editor #le-board');
		await page.waitForFunction(() => window.__posted.some((p) => p.action === 'composer_open'));
		await page.evaluate(
			(text) =>
				window.composerData({
					sources: [{ id: 'ergopti', name: 'Ergopti', convention: 'iso', text }]
				}),
			keylayout
		);
		return { page, errors };
	};

	const held = await openWindow({ text: layers, hold: 'CapsLock' });
	await held.page.waitForSelector('.le-tab.active[data-layer="nav"]');
	await tool(held.page, 'details');
	assert.equal(
		await held.page.inputValue('#le-name'),
		strings['layout_editor.start.copy_name'].replace('{name}', 'Ergopti'),
		'the nav layer joins the opening start, not a document it then replaces'
	);
	// Asked again on a document that has its nav layer: it is shown, not imported twice.
	await held.page.click('.le-tab[data-layer="base"], [data-layer="base"]');
	await held.page.evaluate((text) => window.studioNav({ text, hold: 'CapsLock' }), layers);
	await held.page.waitForSelector('.le-tab.active[data-layer="nav"]');
	assert.deepEqual(held.errors, []);
	await held.page.close();

	const unheld = await openWindow({ text: layers, hold: '' });
	await unheld.page.waitForSelector('#le-tool-tab-navigation.active');
	assert.equal(
		(await unheld.page.textContent('#le-message')).trim(),
		strings['layout_editor.status.nav_missing']
	);
	assert.equal(await unheld.page.$('.le-tab[data-layer="nav"]'), null, 'nothing is imported');
	assert.deepEqual(unheld.errors, []);
	await unheld.page.close();
}

/**
 * (site-opens-on-ergopti) The site's standalone editor opens on a copy of
 * Ergopti too, from the registry it serves; without that registry (the main
 * check's loopback server) it keeps the empty keyboard.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseSiteOpensOnErgopti(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const keylayout = fs.readFileSync(KEYLAYOUT, 'utf8');
	await context.route('**/layouts/registry/index.json', (route) =>
		route.fulfill({
			contentType: 'application/json',
			body: JSON.stringify({
				layouts: [
					{ id: 'ergopti', name: 'Ergopti', file: 'ergopti.keylayout', keycode_convention: 'iso' }
				]
			})
		})
	);
	await context.route('**/layouts/registry/ergopti.keylayout', (route) =>
		route.fulfill({ contentType: 'text/plain', body: keylayout })
	);
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(`${origin}/ui/layout_editor/index.html?lang=en`);
	await page.waitForSelector('#le-board .le-legend.key-legend-dead');
	// (keyboard-format) « Format » replaces the numeric keypad checkbox: each
	// format hides the blocks it lacks, TKL by default.
	assert.equal(await page.locator('#le-numpad').count(), 0, 'no numeric keypad checkbox');
	const shown = (code) => page.locator(`#le-board [data-code="${code}"]`).count();
	assert.equal(await page.inputValue('#le-board-format'), 'tkl');
	assert.deepEqual(
		[await shown('Numpad5'), await shown('ArrowUp'), await shown('Insert'), await shown('F5')],
		[0, 1, 1, 1],
		'TKL: no keypad'
	);
	await page.selectOption('#le-board-format', 'full');
	assert.equal(await shown('Numpad5'), 1, '100 %: the keypad');
	await page.selectOption('#le-board-format', '75');
	assert.deepEqual([await shown('Insert'), await shown('F5')], [0, 1], '75 %: no editing block');
	await page.selectOption('#le-board-format', '65');
	assert.deepEqual([await shown('F5'), await shown('ArrowUp')], [0, 1], '65 %: no F row');
	await page.selectOption('#le-board-format', '60');
	assert.deepEqual(
		[await shown('ArrowUp'), await shown('KeyQ'), await shown('Escape')],
		[0, 1, 1],
		'60 %: no arrows'
	);
	await page.selectOption('#le-board-format', 'tkl');
	// (centred-legend) A character key's legend is centred in its key, both ways.
	const offsets = await page.evaluate(() =>
		['KeyA', 'KeyQ', 'Digit5'].map((code) => {
			const key = document.querySelector(`#le-board [data-code="${code}"]`);
			const range = document.createRange();
			range.selectNodeContents(key.querySelector('.le-legend'));
			const text = range.getBoundingClientRect();
			const box = key.getBoundingClientRect();
			return {
				code,
				x: text.left + text.width / 2 - (box.left + box.width / 2),
				y: text.top + text.height / 2 - (box.top + box.height / 2)
			};
		})
	);
	for (const offset of offsets)
		assert.ok(
			Math.abs(offset.x) <= 2 && Math.abs(offset.y) <= 2,
			`${offset.code}: legend centred (${offset.x.toFixed(1)}, ${offset.y.toFixed(1)} px)`
		);
	// (dead-key-legend) A dead key is its bare accent with the shared marker
	// class, on the board and in the magnifier; no dotted circle anywhere.
	const dead = await page.$$eval('#le-board .le-legend.key-legend-dead', (nodes) =>
		nodes.map((node) => node.textContent)
	);
	assert.deepEqual(dead.sort(), ['^', '¨'].sort(), "Ergopti's base dead keys as bare accents");
	assert.ok(
		!(await page.textContent('#le-board')).includes('\u25cc'),
		'no dotted circle on the board'
	);
	await page.hover('#le-board .le-key.dead');
	// The magnifier shows once the character names are loaded.
	await page.waitForSelector('#le-magnifier-glyph');
	const glyph = await page.$eval('#le-magnifier-glyph', (node) => ({
		text: node.textContent,
		dead: node.classList.contains('key-legend-dead')
	}));
	assert.ok(glyph.dead && ['^', '¨'].includes(glyph.text), `magnifier: ${JSON.stringify(glyph)}`);
	await tool(page, 'details');
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	await page.waitForFunction(
		(expected) => document.querySelector('#le-name').value === expected,
		strings['layout_editor.start.copy_name'].replace('{name}', 'Ergopti')
	);
	assert.notEqual(
		await page.textContent('#le-board [data-code="KeyQ"] .le-legend'),
		'',
		'the board shows Ergopti'
	);
	await exerciseForeignFiles(page);
	await exerciseFingeringPerKeyboard(page);
	await exerciseStartAnyLayout(page);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (start-any-layout) « New » lists every layout of the library, sorted by
 * display name, with a search field; starting from one that is not a quick
 * pick (Colemak-DH) puts its letters on the board.
 * @param {import('playwright').Page} page
 */
async function exerciseStartAnyLayout(page) {
	await page.click('#le-new');
	const names = await page.$$eval('#le-start-layout option', (options) =>
		options.map((option) => option.textContent)
	);
	assert.ok(names.length > 100, `every library layout is listed (${names.length})`);
	assert.deepEqual(
		names,
		[...names].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' })),
		'sorted by display name'
	);
	assert.ok(!names.some((name) => /_/.test(name)), 'display names, not ids');
	await page.fill('#le-start-search', 'colemak-dh');
	assert.deepEqual(
		await page.$$eval('#le-start-layout option', (options) =>
			options.map((option) => option.textContent)
		),
		['Colemak-DH', 'Colemak-DH Angle', 'Colemak-DHv'],
		'the search narrows the list'
	);
	assert.equal(await page.inputValue('#le-start-layout'), 'colemak_dh');
	await page.click('#le-start-library-go');
	if (await page.locator('#le-confirm-yes').count()) await page.click('#le-confirm-yes');
	await page.waitForSelector('#le-start', { state: 'detached' });
	const legend = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
	assert.deepEqual(
		[await legend('KeyE'), await legend('KeyF'), await legend('KeyD'), await legend('KeyV')],
		['f', 't', 's', 'd'],
		"Colemak-DH's letters on the board"
	);
	await tool(page, 'details');
	assert.equal(await page.inputValue('#le-name'), 'My Colemak-DH');
}

/**
 * (editor-reads-every-format) « Open » reads another tool's layout file (here
 * Ergo-L's published Kalamine JSON) into an Ergopti source, and the layout
 * downloads as KLA JSON and Kalamine TOML, each saying what it cannot hold.
 * @param {import('playwright').Page} page
 */
async function exerciseForeignFiles(page) {
	const dir = path.join(ROOT, 'tools', 'test', 'fixtures', 'layout-formats', 'third-party');
	await page.setInputFiles('#le-open-file', path.join(dir, 'ergol.json'));
	await page.waitForFunction(() =>
		/ergol\.json/.test((document.getElementById('le-message') || {}).textContent || '')
	);
	const legend = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
	assert.deepEqual(
		[await legend('KeyQ'), await legend('KeyW'), await legend('KeyE')],
		['q', 'c', 'o'],
		"Ergo-L's letters on the board"
	);
	await tool(page, 'export');
	const kla = await downloaded(page, () => exportAs(page, 'kla'));
	assert.match(kla.name, /\.kla\.json$/);
	const json = JSON.parse(kla.text);
	assert.equal(json.keyboardType, 'european');
	assert.ok(
		json.keys.some((key) => key.primary === 'c'.codePointAt(0)),
		'KLA keys carry the letters'
	);
	assert.match(
		await page.textContent('#le-message'),
		/dead key/,
		"KLA says, in the page's language, that it cannot hold dead keys"
	);
	const kalamine = await downloaded(page, () => exportAs(page, 'kalamine'));
	assert.match(kalamine.name, /\.kalamine\.toml$/);
	assert.match(kalamine.text, /^name = "Ergo-L"/);
	assert.match(kalamine.text, /geometry = "ISO"/);
	assert.ok(
		await page.isVisible('#le-kbe-note'),
		'the export section says why .kbe is not offered'
	);
	// (editor-reads-klanext-and-kbe) A KLAnext ErgoDox file opens and names the
	// keys the ISO board lacks; a KbdEdit .kbe is recognised and refused with its reason.
	assert.match(await page.getAttribute('#le-open-file', 'accept'), /\.kbe/);
	await page.setInputFiles(
		'#le-open-file',
		path.join(ROOT, 'static', 'layouts', 'kla_ergodox', 'ergopti.v2.2.0.fr.ergodox.json')
	);
	await page.waitForFunction(() =>
		/ergodox\.json/.test((document.getElementById('le-message') || {}).textContent || '')
	);
	assert.match(await page.textContent('#le-message'), /key 39 \(z Z % ‰\) has no place/);
	await page.setInputFiles(
		'#le-open-file',
		path.join(ROOT, 'static', 'layouts', 'registry', 'bepo', 'kbdedit', 'French_Standard_BEPO.kbe')
	);
	await page.waitForFunction(() =>
		/KbdEdit encrypts/.test((document.getElementById('le-message') || {}).textContent || '')
	);
}

/**
 * (fingering-in-editor, fingering-per-keyboard) The editor's analysis panel
 * holds the fingering editor too, and each keyboard keeps its own profile: a
 * finger changed on ISO is ISO's alone, ANSI keeps its defaults.
 * @param {import('playwright').Page} page
 */
async function exerciseFingeringPerKeyboard(page) {
	const fingerOf = (code) =>
		page.$eval(
			`.la-panel-fingering .la-fingering-key[title^="${code} "]`,
			(node) => node.dataset.finger
		);
	const waitFinger = (code, finger) =>
		page.waitForFunction(
			([c, f]) => {
				const node = document.querySelector(
					`.la-panel-fingering .la-fingering-key[title^="${c} "]`
				);
				return node && node.dataset.finger === f;
			},
			[code, finger]
		);
	await waitFinger('KeyQ', 'lp');
	assert.ok(
		(await page.locator('.la-panel-fingering .la-fingering-key').count()) > 40,
		'the panel shows the key map'
	);
	await page.click('.la-panel-fingering .la-fingering-key[title^="KeyQ "]');
	await page.selectOption('.la-panel-fingering div.la-fingering-row select', 'lr');
	await waitFinger('KeyQ', 'lr');
	const stored = await page.evaluate(() =>
		JSON.parse(window.localStorage.getItem('ergopti.layout_analysis.profiles.v2'))
	);
	assert.equal(stored.version, 2);
	assert.equal(stored.profiles.iso.fingers.KeyQ, 'lr', 'stored as the ISO profile');
	assert.equal(stored.profiles.ansi, undefined, 'ANSI keeps its defaults');
	await page.selectOption('#la-panel-keyboard', 'ansi');
	await waitFinger('KeyQ', 'lp');
	await page.selectOption('#la-panel-keyboard', 'iso');
	await waitFinger('KeyQ', 'lr');
	assert.equal(await fingerOf('KeyQ'), 'lr');
	// « Reset » gives ISO its defaults back.
	await page.click('.la-panel-fingering .la-row button');
	await waitFinger('KeyQ', 'lp');
}

/**
 * (layout-editor-download-error) A download whose converters cannot load says
 * why: in the macOS and Linux app windows the Lua VM of the XKB and KLC
 * builders can be missing, and its synchronous throw once escaped the click's
 * promise, so the click showed nothing and wrote nothing.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseDownloadWithoutLuaVm(browser, origin) {
	const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	await page.addInitScript((strings) => {
		window._i18n_strings = strings;
		window.__posted = [];
		window.webkit = {
			messageHandlers: {
				layout_editor_window_bridge: { postMessage: (payload) => window.__posted.push(payload) }
			}
		};
	}, strings);
	await page.goto(`${origin}/ui/layout_editor_window/index.html`);
	await page.evaluate(() =>
		window.initData({
			strings: {},
			state: { platform: 'linux' },
			source_editor: true,
			source_export: true
		})
	);
	await page.evaluate(
		(text) => window.sourceData({ filename: 'source.toml', text, folder: 'layout_sources/' }),
		fs.readFileSync(SOURCE_FIXTURE, 'utf8')
	);
	await page.waitForSelector('#le-tools');
	// The page as the inlining hosts leave it: the VM's script never ran.
	await page.evaluate(() => {
		if (window.exports) delete window.exports.fengari;
		delete window.fengari;
	});
	await tool(page, 'export');
	for (const target of ['xkb', 'klc']) {
		await exportAs(page, target);
		await page.waitForFunction(
			() => /\berror\b/.test((document.getElementById('le-message') || {}).className || ''),
			null,
			{ timeout: 5000 }
		);
		assert.equal(
			(await page.textContent('#le-message')).trim(),
			strings['layout_editor.error.lua_vm_unavailable'],
			`${target}: the reason is shown`
		);
		assert.equal(
			await page.evaluate(() => window.__posted.some((p) => p.action === 'source_export')),
			false,
			`${target}: nothing is written`
		);
		await page.evaluate(() => {
			document.getElementById('le-message').className = '';
		});
	}
	assert.deepEqual(errors, [], 'the failure is reported, not thrown');
	await page.close();
}

/**
 * (studio-comparer-tab) Ergopti Studio's « Comparer » tab in the app window:
 * the comparer mounts into the tab the first time it opens, lists the host's
 * stored layouts, asks the host for the chosen built-in corpus (studio_corpus)
 * and ranks the layouts on it.
 * @param {import('playwright').Page} page The editor window, after initData.
 */
async function exerciseStudioComparer(page) {
	assert.equal(
		await page.locator('#studio-comparer #la-table').count(),
		0,
		'nothing runs before the tab opens'
	);
	await page.click('#studio-tab-compare');
	assert.equal(await page.isVisible('#layout-editor'), false);
	assert.equal(await page.locator('#studio-comparer #la-table').count(), 1);
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'studio_layouts'));
	await page.evaluate(() => {
		const list = window.__posted.find((p) => p.action === 'studio_layouts');
		window.studioLayouts({ request: list.request, ok: true, layouts: [] });
	});
	// The chosen built-in corpus comes from the host (LAYOUT_ANALYSIS_HOST.loadCorpus):
	// like the macOS, Linux and Windows hosts, this one runs the generated file
	// in the page, then answers every pending request.
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'studio_corpus'));
	const corpus = await page.evaluate(
		() => window.__posted.find((p) => p.action === 'studio_corpus').id
	);
	assert.match(corpus, /^[a-z0-9_]+$/);
	await page.addScriptTag({
		path: shared('ui', 'layout_analysis', '_generated', 'corpus_' + corpus + '.js')
	});
	await page.evaluate((id) => {
		for (const posted of window.__posted)
			if (posted.action === 'studio_corpus' && posted.id === id)
				window.studioCorpus({ request: posted.request, ok: true });
	}, corpus);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	// English strings: the comparer reports its analysis, not a failure.
	assert.match(
		await page.evaluate(() => document.getElementById('la-status').textContent),
		/^\d+ layouts compared on [\d,]+ characters/
	);
	// (comparer-default-geometry) Until the user chooses, the ticked layouts
	// follow the keyboard: ISO ticks Ergopti and Ergopti+, ANSI their ANSI
	// versions; the other board's variants stay listed, unticked.
	const ticks = () =>
		page.$$eval('#la-layout-list .la-layout', (labels) =>
			Object.fromEntries(
				labels
					.map((label) => [label.textContent.trim(), label.querySelector('input').checked])
					.filter(([name]) => /^Ergopti\+?( ANSI)?$/.test(name))
			)
		);
	assert.deepEqual(
		await ticks(),
		{ Ergopti: true, 'Ergopti+': true, 'Ergopti ANSI': false, 'Ergopti+ ANSI': false },
		'ISO ticks Ergopti and Ergopti+'
	);
	await page.selectOption('#la-keyboard', 'ansi');
	assert.deepEqual(
		await ticks(),
		{ Ergopti: false, 'Ergopti+': false, 'Ergopti ANSI': true, 'Ergopti+ ANSI': true },
		'ANSI ticks their ANSI versions'
	);
	await page.selectOption('#la-keyboard', 'iso');
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	// (dead-key-legend) Ergopti's heatmap shows its dead keys as bare accents, marked.
	await page.evaluate(() =>
		[...document.querySelectorAll('#la-table tbody tr')]
			.find((row) => [...row.cells].some((cell) => cell.textContent.trim() === 'Ergopti'))
			.click()
	);
	const heat = await page.$$eval('#la-heatmap .la-key', (keys) =>
		keys.map((key) => ({ text: key.textContent, dead: key.classList.contains('key-legend-dead') }))
	);
	assert.ok(heat.length > 30, 'the heatmap shows the board');
	assert.ok(!heat.some((key) => key.text.includes('\u25cc')), 'no dotted circle on the heatmap');
	assert.deepEqual(
		heat
			.filter((key) => key.dead)
			.map((key) => key.text)
			.sort(),
		['^', '¨'].sort(),
		"Ergopti's base dead keys as bare accents"
	);
	// (studio-key-heatmap) A layout's details heatmap names each key's worst SFB
	// partners from the engine's worst groups.
	await page.click('#la-table tbody tr');
	await page.selectOption('#la-heat-metric', 'sfb');
	assert.ok(
		await page.$$eval('#la-heatmap .la-key', (keys) =>
			keys.some((key) => /: [\d.,]+ % — .+ [\d.,]+ %/.test(key.title))
		),
		'the Comparer heatmap names SFB partners'
	);
	// (comparer-heat-metrics) Every per-key metric of the engine, the presses and
	// the score; a bad event names its worst groups (the layout analysed with
	// keyGroups), and every key is reachable from the keyboard with its value.
	const heatChoices = await page.$$eval('#la-heat-metric option', (options) =>
		options.map((option) => option.value)
	);
	for (const id of ['presses', 'score', 'redirect_bad', 'distance', 'roll_in', 'alternation'])
		assert.ok(heatChoices.includes(id), `the heatmap offers ${id}`);
	await page.selectOption('#la-heat-metric', 'redirect_bad');
	assert.ok(
		await page.$$eval('#la-heatmap .la-key', (keys) =>
			keys.some((key) => / — .+ [\d.,]+ %/.test(key.title))
		),
		'the Comparer heatmap names the worst bad redirects'
	);
	assert.ok(
		await page.$$eval('#la-heatmap .la-key', (keys) =>
			keys.every(
				(key) =>
					key.tabIndex === 0 &&
					key.getAttribute('aria-label').startsWith(key.title + ' (') &&
					/\d.*\d\)$/.test(key.getAttribute('aria-label'))
			)
		),
		'every heatmap key is named with its value and its place, and focusable'
	);
	// (comparer-heat-table) The heatmap's numbers as a table, one row per drawn key.
	assert.equal(
		await page.locator('#la-heat-table tbody tr').count(),
		await page.locator('#la-heatmap .la-key').count(),
		'the heatmap has its table'
	);
	// (comparer-worst-groups) The board's worst pairs, with their counts and shares.
	await page.click('#la-details details:has(#la-worst-event) > summary');
	await page.selectOption('#la-worst-event', 'sfb');
	assert.ok(
		(await page.locator('#la-worst tbody tr').count()) > 1,
		'the worst SFB pairs are listed'
	);
	assert.match(await page.textContent('#la-worst tbody tr td:nth-child(3)'), /^[\d.,]+ %$/);
	assert.equal(await page.locator('#la-travel .la-chart-row').count(), 10, 'every finger travels');
	assert.ok(
		(await page.locator('#la-standing .la-chart-row').count()) > 10,
		'a standing per metric'
	);
	// (row-jump) Row jumps: a heatmap choice and a worst-pairs event, not scored.
	assert.ok(heatChoices.includes('row_jump'), 'the heatmap offers row jumps');
	await page.selectOption('#la-worst-event', 'row_jump');
	assert.ok(
		(await page.locator('#la-worst tbody tr').count()) > 0,
		'the worst row jumps are listed'
	);
	// (bigram-matrix) The key pair matrix: a named cell per pair, the busiest keys
	// on both axes, both colourings with a legend, and every pair in a sortable table.
	await page.evaluate(() => {
		for (const section of document.querySelectorAll('#la-details .la-section')) section.open = true;
	});
	const cells = await page.$$eval('#la-matrix td.la-cell-count', (tds) =>
		tds.map((td) => td.title)
	);
	assert.ok(cells.length > 100, `the matrix has ${cells.length} pairs`);
	assert.match(cells[0], /: [\d.,]+ % .+\(\d[\d,]* .+\), .+, [+−-]?[\d.,]+ /);
	assert.ok(
		await page.$$eval('#la-matrix td.la-cell-count', (tds) =>
			tds.every((td) => td.querySelector('.la-sr-only').textContent === td.title)
		),
		'every matrix cell is named to assistive technology'
	);
	assert.ok((await page.locator('#la-matrix thead th').count()) >= 26, 'a column per busy key');
	await page.selectOption('#la-matrix-by', 'points');
	assert.ok(
		(await page.locator('#la-matrix td.la-cell-loss').count()) > 0 &&
			(await page.locator('#la-matrix td.la-cell-gain').count()) > 0,
		'pairs gain and lose points'
	);
	assert.equal(
		await page.textContent('#la-matrix td.la-cell-loss span'),
		'−',
		'a lost pair is marked'
	);
	assert.equal(
		await page.locator('#la-matrix-legend .la-swatch').count(),
		2,
		'gain and loss legend'
	);
	assert.equal(
		await page.locator('#la-matrix-pairs tbody tr').count(),
		100,
		'100 pairs in the table'
	);
	await page.click('#la-matrix-pairs thead th:nth-child(6) button');
	const sortedPoints = await page.$$eval('#la-matrix-pairs tbody tr td:nth-child(6)', (tds) =>
		tds.map((td) => Number(td.textContent.replace(/[^\d.\-−+]/g, '').replace('−', '-')))
	);
	assert.ok(
		sortedPoints.every((v, i) => i === 0 || sortedPoints[i - 1] >= v),
		'the pair table sorts by points'
	);
	await page.selectOption('#la-matrix-by', 'count');
	// (word-effort) A built-in text corpus ships its word table: the mean, the
	// distribution over ten ranges and the hardest words.
	assert.equal(await page.isHidden('#la-words-none'), true, 'this corpus has a word table');
	assert.equal(await page.locator('#la-words-bins .la-chart-row').count(), 10, 'ten effort ranges');
	assert.equal(await page.locator('#la-words tbody tr').count(), 15, 'the 15 hardest words');
	assert.match(await page.textContent('#la-words-mean'), /[\d.,]+ points over [\d,]+ words/);
	// (matrix-phone-width) At phone width the matrix scrolls inside its own box.
	const viewport = page.viewportSize();
	await page.setViewportSize({ width: 360, height: 740 });
	const fit = await page.$eval('.la-matrix-wrap', (box) => ({
		inside: box.scrollWidth > box.clientWidth,
		right: box.getBoundingClientRect().right,
		width: window.innerWidth
	}));
	assert.ok(fit.inside, 'the matrix scrolls inside its box');
	assert.ok(fit.right <= fit.width, `the matrix box ends at ${fit.right} of ${fit.width}`);
	await page.setViewportSize(viewport);
	// (comparer-diff) « Compare with » puts a second layout's value and the
	// difference beside each metric, its verdict in words; the finger chart
	// marks each finger's ideal load.
	const versusId = await page.$eval(
		'#la-versus',
		(select) => [...select.options].find((option) => option.value !== '').value
	);
	await page.selectOption('#la-versus', versusId);
	assert.equal(
		await page.locator('#la-metrics thead th').count(),
		4,
		'metric, layout, the other layout, difference'
	);
	assert.ok(
		(await page.locator('#la-metrics .la-verdict').count()) > 20,
		'every metric has its verdict'
	);
	assert.equal(await page.locator('#la-fingers .la-target').count(), 8, 'eight ideal marks');
	// (comparer-heat-diff) Against the other layout, the heatmap shows the key-by-key
	// difference, both directions in words, each key's value signed.
	await page.check('#la-heat-diff');
	assert.ok(
		(await page.locator('#la-heatmap .la-key-more, #la-heatmap .la-key-less').count()) > 0,
		'keys differ between the two layouts'
	);
	assert.equal(await page.locator('#la-heat-legend .la-heat-key').count(), 2, 'more and less');
	assert.ok(
		await page.$$eval('#la-heatmap .la-key-more', (keys) =>
			keys.every((key) => / \+[\d.,]+ /.test(key.title))
		),
		'a key with more is signed +'
	);
	await page.uncheck('#la-heat-diff');
	// (comparer-table-options) The ranking table's columns and rows are the
	// viewer's: a metric added, a name filter, both kept for the next visit.
	await page.click('#la-table-options > summary');
	const columnsBefore = await page.locator('#la-table thead th').count();
	await page.check('#la-column-list input[value="pinky_load"]');
	assert.equal(
		await page.locator('#la-table thead th').count(),
		columnsBefore + 1,
		'a column added'
	);
	const rowsBefore = await page.locator('#la-table tbody tr').count();
	await page.fill('#la-row-name', 'ergopti');
	const rowsAfter = await page.locator('#la-table tbody tr').count();
	assert.ok(
		rowsAfter > 0 && rowsAfter < rowsBefore,
		`the name filter keeps ${rowsAfter} of ${rowsBefore}`
	);
	assert.match(
		await page.textContent('#la-table-count'),
		new RegExp(`^${rowsAfter}\\D+${rowsBefore}\\D`)
	);
	await page.fill('#la-row-min', '1000000');
	assert.equal(await page.locator('#la-table tbody tr').count(), 0, 'no layout scores that much');
	const keptTable = await page.evaluate(
		() => JSON.parse(window.localStorage.getItem('ergopti.layout_analysis.v1')).table
	);
	assert.equal(keptTable.name, 'ergopti');
	assert.equal(keptTable.min, 1000000);
	assert.ok(keptTable.columns.includes('pinky_load'), 'the chosen columns are kept');
	await page.click('#la-table-reset');
	assert.equal(await page.locator('#la-table tbody tr').count(), rowsBefore, 'every row is back');
	assert.equal(
		await page.locator('#la-table thead th').count(),
		columnsBefore,
		'the default columns'
	);
	// (comparer-share) « Copy the link » names the compared layouts and the
	// details; opening it shows them.
	await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
	await page.click('#la-share');
	await page.waitForFunction(() => !document.getElementById('la-share-status').hidden);
	const sharedLink = await page.evaluate(() => navigator.clipboard.readText());
	const sharedQuery = new URL(sharedLink).searchParams;
	assert.ok(sharedQuery.get('layouts').split(',').length >= 2, `shared layouts: ${sharedLink}`);
	assert.equal(sharedQuery.get('versus'), versusId, 'the shared link names the compared layout');
	// (editable-tables) The shortcut letters, their keys' ease and the compact
	// form factors' weights are edited, refused when out of range, saved and reset.
	// They sit in the folded score settings.
	await page.click('#la-settings > summary');
	assert.equal(await page.locator('#la-shortcut-letters input').count(), 26, 'every letter');
	assert.equal(await page.locator('#la-form-list input').count(), 4, 'every form factor');
	const letterZ = '#la-shortcut-letters input[data-id="z"]';
	await page.fill(letterZ, '11');
	await page.waitForFunction(
		() => document.getElementById('la-shortcuts-status').className === 'la-error'
	);
	assert.equal(await page.getAttribute(letterZ, 'aria-invalid'), 'true');
	await page.fill(letterZ, '4');
	await page.waitForFunction(() => {
		const saved = JSON.parse(window.localStorage.getItem('ergopti.layout_analysis.v1') || '{}');
		return saved.shortcuts && saved.shortcuts.letters.z === 4;
	});
	await page.fill('#la-form-list input[data-id="40"]', '3');
	await page.waitForFunction(() => {
		const saved = JSON.parse(window.localStorage.getItem('ergopti.layout_analysis.v1') || '{}');
		return saved.formWeights && saved.formWeights['40'] === 3;
	});
	await page.click('#la-shortcuts-restore');
	await page.click('#la-forms-restore');
	assert.equal(await page.inputValue(letterZ), '10', 'the default table is back');
	assert.equal(await page.inputValue('#la-form-list input[data-id="40"]'), '1');
	// (studio-file-buttons) The file inputs never show the browser's own words
	// (« Choose File », « No file chosen »): each is hidden inside a label whose
	// button carries the page's translated text.
	// The corpus file sits in the panel « custom text » opens: open it first.
	await page.selectOption('#la-corpus', 'custom');
	// (comparer-reads-pdf) A PDF's text becomes the corpus, read in the page.
	await page.setInputFiles(
		'#la-file',
		path.join(ROOT, 'static', 'documents', 'archives', 'Layout_Optim7.pdf')
	);
	await page.waitForFunction(() =>
		document.getElementById('la-text').value.includes('Exposants en AltGr E, Indices en AltGr I')
	);
	const inputs = await page.$$eval('#studio-comparer input[type="file"]', (nodes) =>
		nodes.map((node) => {
			const box = node.getBoundingClientRect();
			const button = node.closest('label').querySelector('.la-file-button');
			return {
				id: node.id || node.accept,
				hidden: box.width <= 1 && box.height <= 1,
				label: button ? button.textContent.trim() : '',
				shown: Boolean(button && button.getBoundingClientRect().width > 1)
			};
		})
	);
	assert.equal(inputs.length, 3, 'a corpus file, a layout file and a fingering profile');
	for (const input of inputs) {
		assert.ok(input.hidden, `${input.id}: the native file control is hidden`);
		assert.ok(input.shown, `${input.id}: its labelled button is shown`);
		assert.ok(
			input.label.length > 0 && !input.label.startsWith('layout_analysis.'),
			`${input.id}: the button is translated (${input.label})`
		);
	}
	await page.click('#studio-tab-edit');
	assert.equal(await page.isVisible('#studio-comparer'), false);
}

/** The layout editor's own window with a recording Linux-style bridge, as ErgoptiPlus hosts it. */
async function exerciseManager(browser, origin) {
	const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	await page.addInitScript((strings) => {
		window._i18n_strings = strings;
		window.__posted = [];
		window.webkit = {
			messageHandlers: {
				layout_editor_window_bridge: { postMessage: (payload) => window.__posted.push(payload) }
			}
		};
	}, strings);
	await page.goto(`${origin}/ui/layout_editor_window/index.html`);
	const state = {
		platform: 'linux',
		shortcut_menu_path: 'shortcuts/menu.lua',
		index: { layouts: [] },
		installed: {},
		provided: {},
		builtin: {}
	};
	await page.evaluate(
		(state) =>
			window.initData({
				strings: {},
				state,
				source_editor: true,
				source_pick: true,
				nav_apply: true,
				emulate: true,
				studio_store: true
			}),
		state
	);
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'ready'));
	await exerciseStudioComparer(page);
	// The host answers the window's ready with the last saved source.
	await page.evaluate(() => window.sourceData({ text: null, folder: 'layout_sources/' }));
	await page.waitForSelector('#layout-editor #le-board');
	// (keyboard-format) The editor's « Format » is the Comparer's.
	await page.selectOption('#le-board-format', '65');
	await page.click('#studio-tab-compare');
	assert.equal(await page.inputValue('#la-format'), '65', "the Comparer takes the editor's format");
	await page.click('#studio-tab-edit');
	await page.selectOption('#le-board-format', 'tkl');
	// (editor-layouts-in-comparer) The layouts open in « Éditer » are in the
	// Comparer's list, ticked, and follow the editor: a rename shows there.
	const listed = () =>
		page.$$eval('#la-layout-list .la-layout', (labels) =>
			labels.map((label) => [label.textContent.trim(), label.querySelector('input').checked])
		);
	await tool(page, 'details');
	await page.fill('#le-name', 'Studio canary');
	await page.dispatchEvent('#le-name', 'change');
	await page.click('#studio-tab-compare');
	await page.waitForFunction(() =>
		[...document.querySelectorAll('#la-layout-list .la-layout')].some(
			(label) => label.textContent.trim() === 'Studio canary'
		)
	);
	assert.deepEqual(
		(await listed()).filter(([name]) => name === 'Studio canary'),
		[['Studio canary', true]],
		"the editor's layout, once and ticked"
	);
	await page.click('#studio-tab-edit');
	await page.fill('#le-name', 'Studio canary 2');
	await page.dispatchEvent('#le-name', 'change');
	await page.click('#studio-tab-compare');
	await page.waitForFunction(() => {
		const names = [...document.querySelectorAll('#la-layout-list .la-layout')].map((label) =>
			label.textContent.trim()
		);
		return names.includes('Studio canary 2') && !names.includes('Studio canary');
	});
	await page.click('#studio-tab-edit');
	// (layout-editor-no-null-text) A section that renders nothing (the « Start
	// from » panel when no start is open) leaves no text node behind: the root
	// once received null and showed « null » under the toolbar.
	assert.deepEqual(
		await page.evaluate(() =>
			Array.from(document.getElementById('layout-editor').childNodes)
				.filter((node) => node.nodeType === Node.TEXT_NODE)
				.map((node) => node.textContent)
		),
		[],
		'the editor root holds elements only'
	);
	// The inline host lists the names table: the magnifier names a character at once.
	assert.equal(await page.evaluate(() => typeof UNICODE_NAMES_DATA), 'object');
	await page.click('#le-board [data-code="KeyQ"]');
	await page.selectOption('#le-kind', 'text');
	await page.click('.le-palette summary');
	await page.hover('#le-palette .le-glyph[title="U+00E9"]');
	assert.match(await page.textContent('#le-magnifier-rows'), /LATIN SMALL LETTER E WITH ACUTE/);
	await page.click('#le-save');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'source_save'));
	const posted = await page.evaluate(() => window.__posted.find((p) => p.action === 'source_save'));
	assert.equal(posted.filename, 'my_layout.toml');
	assert.match(posted.text, /format = "ergopti-layout"/);
	await page.evaluate(() =>
		window.sourceResult({ ok: true, detail: '/c/my_layout.toml', filename: 'my_layout.toml' })
	);
	assert.match(await page.textContent('#le-message'), /Ergopti\+/);

	// Fill sources come from the composer host's own list.
	await tool(page, 'fill');
	await page.click('#le-fill-load');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'composer_open'));
	const keylayoutText = fs.readFileSync(KEYLAYOUT, 'utf8');
	await page.evaluate(
		(text) =>
			window.composerData({
				sources: [{ id: 'ergopti', name: 'Ergopti', convention: 'iso', text }]
			}),
		keylayoutText
	);
	await page.waitForSelector('#le-fill-source option[value="ergopti"]', { state: 'attached' });

	// A host with a native panel (macOS) opens files for the page.
	await page.click('#le-open');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'source_pick'));
	await page.evaluate((text) => window.sourcePicked({ filename: 'mine.toml', text }), posted.text);
	assert.match(await page.textContent('#le-message'), /mine\.toml/);

	// The source's navigation layer applies through the host's navigation layer save.
	await tool(page, 'navigation');
	await page.selectOption('#le-nav-hold', 'CapsLock');
	await page.setInputFiles('#le-nav-file', NAV);
	await page.waitForSelector('[data-layer="nav"].active');
	await tool(page, 'export');
	await page.click('#le-apply-nav');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'nav_save'));
	const nav = await page.evaluate(() => window.__posted.find((p) => p.action === 'nav_save'));
	assert.match(nav.text, /\[layers\.nav\.all\]/);
	await page.evaluate(() => window.navResult({ saved: true, applied: true, errors: [] }));
	assert.equal(await page.textContent('#le-message'), strings['layout_editor.status.nav_applied']);
	await page.click('#le-apply-nav');
	await page.evaluate(() =>
		window.navResult({
			saved: false,
			applied: false,
			errors: [{ code: 'unknown_action', detail: 'KeyA' }]
		})
	);
	assert.match(await page.textContent('#le-message'), /unknown_action/);

	// « Install and use » goes through the composer host with the source and its compiled layout.
	await page.click('#le-install');
	await page.click('#le-confirm-yes');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'composer_save'));
	const install = await page.evaluate(() =>
		window.__posted.find((p) => p.action === 'composer_save')
	);
	assert.equal(install.use, true);
	assert.match(install.source, /format = "ergopti-layout"/);
	assert.match(install.keylayout, /<keyboard /);
	assert.equal(install.declaration, undefined);
	// The drivers perform this table for what the .keylayout cannot hold.
	const table = JSON.parse(install.emulation);
	assert.equal(table.format, 'ergopti-layout-emulation');
	assert.match(install.source, new RegExp(`id = "${table.layout}"`));
	await page.evaluate(() =>
		window.composerResult({ action: 'composer_save', ok: true, used: true })
	);
	assert.equal(await page.textContent('#le-message'), strings['layout_editor.status.installed']);

	// « Emulate without installing » stores the source for the driver's emulation alone.
	assert.equal(await page.textContent('#le-install'), strings['layout_editor.btn.install']);
	assert.equal(await page.textContent('#le-install-hint'), strings['layout_editor.install_hint']);
	assert.equal(await page.textContent('#le-emulate-hint'), strings['layout_editor.emulate_hint']);
	await page.click('#le-emulate');
	await page.click('#le-confirm-yes');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'composer_emulate'));
	const emulate = await page.evaluate(() =>
		window.__posted.find((p) => p.action === 'composer_emulate')
	);
	assert.equal(emulate.use, undefined, 'nothing is selected in the system');
	assert.equal(emulate.source, install.source);
	assert.equal(emulate.keylayout, install.keylayout);
	assert.equal(emulate.emulation, install.emulation);
	await page.evaluate(() =>
		window.composerResult({ action: 'composer_emulate', ok: false, code: 'emulate_failed' })
	);
	assert.equal(
		await page.textContent('#le-message'),
		strings['layout_editor.error.emulate_failed']
	);
	await page.click('#le-emulate');
	await page.click('#le-confirm-yes');
	await page.evaluate(() =>
		window.composerResult({ action: 'composer_emulate', ok: true, used: true })
	);
	assert.equal(await page.textContent('#le-message'), strings['layout_editor.status.emulated']);

	// « New » starts from a file, blank, or from a reference or a catalogue layout of the host.
	await page.click('#le-new');
	const starts = await page.$$eval('#le-start [data-start]', (buttons) =>
		buttons.map((button) => button.dataset.start)
	);
	assert.deepEqual(starts, ['file', 'blank', 'qwerty', 'azerty', 'ergopti']);
	await page.click('#le-start [data-start="ergopti"]');
	if (await page.locator('#le-confirm-yes').count()) await page.click('#le-confirm-yes');
	await page.waitForSelector('#le-start', { state: 'detached' });
	await tool(page, 'details');
	assert.equal(await page.inputValue('#le-name'), 'My Ergopti');
	await page.click('#le-new');
	await page.click('#le-start [data-start="blank"]');
	await page.waitForSelector('#le-start', { state: 'detached' });
	assert.equal(await page.inputValue('#le-name'), strings['layout_editor.default_name']);
	await exerciseStartAnyLayout(page);
	// « Close » closes the editor's own window through the host.
	await page.click('#le-close');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'close'));
	assert.deepEqual(errors, []);
	await page.close();
}

/**
 * The layer selector shows the four character levels of any layout, adds a missing
 * one in one click, finds a level by its modifiers whatever the layer is called,
 * and lists the layout's other layers.
 */
async function exerciseLayerSelector(browser, origin) {
	const { page, errors } = await open(browser, origin, 'en');
	const levels = () =>
		page.$$eval('#le-layerbar [data-level]', (buttons) =>
			buttons.map((b) => [
				b.dataset.level,
				b.dataset.layer || null,
				b.classList.contains('missing')
			])
		);
	assert.deepEqual(await levels(), [
		['base', 'base', false],
		['shift', null, true],
		['altgr', null, true],
		['shift_altgr', null, true]
	]);
	assert.equal(await page.getAttribute('[data-layer="base"]', 'aria-selected'), 'true');
	// A blank layout names no key by its raw code (« KeyQ », « Digit1 », « MetaLeft »).
	const codes = await page.$$eval('#le-board .le-key', (keys) =>
		keys
			.filter((key) => key.querySelector('.le-code').textContent === key.dataset.code)
			.map((key) => key.dataset.code)
	);
	assert.deepEqual(codes, [], 'raw key codes shown on the board');
	// A missing level is added with its modifiers and shown at once.
	await page.click('#le-layerbar [data-level="altgr"]');
	await page.waitForSelector('[data-layer="altgr"].active');
	const map = async (code, text) => {
		await page.click(`#le-board [data-code="${code}"]`);
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', text);
		await page.click('#le-apply');
	};
	await map('KeyQ', '@');
	const legendOf = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
	assert.equal(await legendOf('KeyQ'), '@');
	await page.click('[data-layer="base"]');
	assert.equal(await legendOf('KeyQ'), '', 'the base layer keeps its own key');
	await map('KeyW', 'w');
	await page.click('[data-layer="altgr"]');
	// Another layer shows its own value only, never the base character as a hint.
	assert.equal(await legendOf('KeyW'), '');
	assert.equal(await page.textContent('#le-board [data-code="KeyW"] .le-code'), '');
	await page.click('[data-layer="altgr"]');
	assert.equal(await legendOf('KeyQ'), '@');
	const saved = await downloaded(page, () => page.click('#le-save'));
	assert.match(saved.text, /id = "altgr"\s+required = \[ ?"alt" ?\]/);
	// « Manage layers… » opens the layer tool; Undo removes the added level again.
	await page.click('#le-manage-layers');
	await page.waitForSelector('#le-layers #le-layer-add');
	// Three edits: the AltGr layer, its KeyQ and the base KeyW.
	for (let undo = 0; undo < 3; undo++) await page.click('#le-undo');
	await page.waitForSelector('#le-layerbar [data-level="altgr"].missing');
	// A source names its levels freely: AltGr is the layer held with Right Alt.
	await page.setInputFiles('#le-open-file', SOURCE_FIXTURE);
	await page.waitForSelector('[data-layer="option"][data-level="altgr"]');
	assert.deepEqual(await levels(), [
		['base', 'base', false],
		['shift', 'shift', false],
		['altgr', 'option', false],
		['shift_altgr', null, true]
	]);
	assert.deepEqual(
		await page.$$eval('#le-layerbar .le-other-layers [data-layer]', (buttons) =>
			buttons.map((b) => b.dataset.layer)
		),
		['kana', 'command']
	);
	// The chips read as the keycaps name their modifiers; the id stays in the tooltip.
	const chips = await page.$$eval('#le-layerbar .le-other-layers [data-layer]', (buttons) =>
		buttons.map((b) => [b.textContent, b.title])
	);
	assert.deepEqual(chips, [
		['kana_lock', 'kana (kana_lock)'],
		['Win / ⌘ / Super', 'command (meta)']
	]);
	const en = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	await tool(page, 'layers');
	await page.fill('#le-layer-id', 'shift_caps_lock');
	await page.check('#le-layer-required input[value="shift"]');
	await page.check('#le-layer-required input[value="caps_lock"]');
	await page.click('#le-layer-add');
	assert.equal(
		await page.textContent('[data-layer="shift_caps_lock"]'),
		`${en['layer_editor.key.shift']} + ${en['layer_editor.key.caps_lock']}`
	);
	assert.match(
		await page.getAttribute('[data-layer="shift_caps_lock"]', 'title'),
		/^shift_caps_lock /
	);
	await page.click('[data-layer="option"]');
	assert.equal(await page.getAttribute('[data-layer="option"]', 'aria-selected'), 'true');
	// The analysis panel lives in the side slot and survives a render.
	const panel = await page.$('#le-side-slot > .la-panel');
	assert.ok(panel, 'the analysis panel is in the side slot');
	await page.click('[data-layer="base"]');
	assert.ok(
		await panel.evaluate((node) => node.isConnected && node.parentElement.id === 'le-side-slot')
	);
	// Every section reaches the page as an element: a hidden one is not printed as « null ».
	assert.deepEqual(
		await page.$$eval('#layout-editor', ([root]) =>
			[...root.childNodes].filter((node) => node.nodeType !== 1).map((node) => node.textContent)
		),
		[]
	);
	assert.deepEqual(errors, []);
	await page.context().close();
}

/**
 * The « Shortcuts » view: a key with no override reads « = » (same as the base
 * key); an override for any modifier combination sends any chord, is marked on
 * the board, listed with Edit and Remove, named by the export tab for the
 * targets that cannot hold it, and kept through save and reload.
 */
async function exerciseShortcuts(browser, origin) {
	const { page, errors } = await open(browser, origin, 'en');
	// « é » on the base layer, where Ergopti has it, so Ctrl+é is Ctrl + that key.
	await page.click('#le-board [data-code="KeyW"]');
	await page.selectOption('#le-kind', 'text');
	await page.fill('#le-text', 'é');
	await page.click('#le-apply');
	await page.click('#le-shortcut-view');
	assert.equal(await page.getAttribute('#le-shortcut-view', 'aria-pressed'), 'true');
	assert.equal(await page.getAttribute('[data-layer="base"]', 'aria-selected'), 'false');
	const key = (code) =>
		page.$eval(`#le-board [data-code="${code}"]`, (node) => ({
			legend: node.querySelector('.le-legend').textContent,
			overridden: node.classList.contains('overridden'),
			same: node.classList.contains('same')
		}));
	assert.deepEqual(await key('KeyW'), { legend: '=', overridden: false, same: true });
	assert.equal(await page.locator('#le-shortcut-none').count(), 1);
	const define = async (code, from, sendKey, to) => {
		await page.click(`#le-board [data-code="${code}"]`);
		for (const mod of from) await page.check(`#le-shortcut-from input[value="${mod}"]`);
		await page.selectOption('#le-shortcut-send', sendKey);
		for (const mod of to) await page.check(`#le-shortcut-to input[value="${mod}"]`);
		// (layout-editor-shortcut-form-render) A render before « Add » keeps the
		// choices: the locale's late i18n:applied once rebuilt the form empty, and
		// « Add » refused the combination for want of a modifier (a dev CI flake).
		await page.evaluate(() => document.dispatchEvent(new CustomEvent('i18n:applied')));
		await page.click('#le-shortcut-add');
	};
	// Ctrl+é sends Ctrl+Shift+C; Ctrl+A sends Ctrl+B.
	await define('KeyW', ['control'], 'KeyC', ['control', 'shift']);
	await define('KeyQ', ['control'], 'KeyB', ['control']);
	assert.ok((await key('KeyW')).overridden, 'Ctrl+é is overridden after a render before « Add »');
	assert.ok((await key('KeyQ')).overridden, 'Ctrl+A is overridden after a render before « Add »');
	assert.ok((await key('KeyE')).same);
	// A combination needs a modifier: the refusal says so and nothing is added.
	await page.click('#le-board [data-code="KeyE"]');
	await page.click('#le-shortcut-add');
	assert.match(await page.textContent('#le-message'), /modifier/);
	assert.ok((await key('KeyE')).same);
	// Edit changes the chord sent; Cancel leaves the override as it was.
	await page.click('#le-board [data-code="KeyQ"]');
	assert.equal(await page.locator('#le-shortcuts li').count(), 1);
	await page.click('#le-shortcuts .le-shortcut-edit');
	assert.ok(await page.isChecked('#le-shortcut-from input[value="control"]'));
	assert.equal(await page.inputValue('#le-shortcut-send'), 'KeyB');
	await page.click('#le-shortcut-cancel');
	await page.click('#le-shortcuts .le-shortcut-edit');
	await page.check('#le-shortcut-from input[value="alt"]');
	await page.click('#le-shortcut-add');
	assert.equal(
		await page.locator('#le-shortcuts li').count(),
		1,
		'the edited combination replaces the old one'
	);
	await page.click('#le-undo');
	assert.equal(await page.locator('#le-shortcuts li').count(), 1);
	// Remove, then undo, keeps the history honest.
	await page.click('#le-shortcuts .le-shortcut-remove');
	assert.equal(await page.locator('#le-shortcuts li').count(), 0);
	await page.click('#le-undo');
	assert.equal(await page.locator('#le-shortcuts li').count(), 1);
	// The one-action default: every other combination of é acts as the key C,
	// chosen in the list; the explicit Ctrl override above still wins.
	await page.click('#le-board [data-code="KeyW"]');
	await page.selectOption('#le-shortcut-key', 'KeyC');
	assert.equal((await key('KeyW')).legend, 'C +1');
	// … or picked on the board: KeyE acts as KeyR.
	await page.click('#le-board [data-code="KeyE"]');
	await page.click('#le-shortcut-key-pick');
	assert.equal(await page.getAttribute('#le-shortcut-key-pick', 'aria-pressed'), 'true');
	await page.click('#le-board [data-code="KeyR"]');
	assert.equal((await key('KeyE')).legend, 'R');
	assert.ok((await key('KeyE')).overridden);
	assert.equal(await page.inputValue('#le-shortcut-key'), 'KeyR');
	// « Same as the base key » clears it, and undo brings it back.
	await page.selectOption('#le-shortcut-key', '');
	assert.ok((await key('KeyE')).same);
	await page.click('#le-undo');
	assert.equal((await key('KeyE')).legend, 'R');
	// The export tab names the targets that cannot hold them.
	await tool(page, 'export');
	assert.match(await page.textContent('#le-export-shortcuts'), /\(4\)/);
	assert.match(await page.textContent('#le-export-shortcuts'), /Ergopti\+/);
	// Save and reload: both overrides come back from the TOML.
	const saved = await downloaded(page, () => page.click('#le-save'));
	const sorted = (list) => list.slice().sort();
	assert.deepEqual(
		require('smol-toml')
			.parse(saved.text)
			.shortcuts.map((entry) => [
				entry.key,
				sorted(entry.modifiers),
				entry.send_key,
				sorted(entry.send_modifiers)
			]),
		[
			['KeyW', ['control'], 'KeyC', ['control', 'shift']],
			['KeyQ', ['control'], 'KeyB', ['control']]
		]
	);
	const parsedKeys = require('smol-toml').parse(saved.text).keys;
	assert.equal(parsedKeys.KeyW.shortcut_key, 'KeyC');
	assert.equal(parsedKeys.KeyE.shortcut_key, 'KeyR');
	const reopened = path.join(require('node:os').tmpdir(), `layout-shortcuts-${process.pid}.toml`);
	fs.writeFileSync(reopened, saved.text);
	const english = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	// The file is read asynchronously: wait until the editor says it opened it.
	const openReopened = async () => {
		await page.setInputFiles('#le-open-file', reopened);
		await page.waitForFunction(
			(opened) => (document.getElementById('le-message') || {}).textContent === opened,
			english['layout_editor.status.opened'].replace('{name}', path.basename(reopened))
		);
	};
	try {
		await page.click('#le-new');
		await page.click('#le-start [data-start="blank"]');
		if (await page.locator('#le-confirm-yes').count()) await page.click('#le-confirm-yes');
		await openReopened();
		await page.click('#le-shortcut-view');
		assert.ok((await key('KeyW')).overridden, 'the reopened TOML overrides Ctrl+é');
		assert.ok((await key('KeyQ')).overridden, 'the reopened TOML overrides Ctrl+A');
		// An « Edit » under way belongs to the document it was started in: opening
		// a file from the « Shortcuts » view ends it.
		await page.click('#le-board [data-code="KeyQ"]');
		await page.click('#le-shortcuts .le-shortcut-edit');
		assert.equal(
			await page.locator('#le-shortcut-cancel').count(),
			1,
			'the override is being edited'
		);
		await page.evaluate(() => {
			document.getElementById('le-message').textContent = '';
		});
		await openReopened();
		await page.click('#le-board [data-code="KeyQ"]');
		assert.equal(
			await page.locator('#le-shortcut-cancel').count(),
			0,
			'opening a file ends the « Edit » begun in the previous document'
		);
	} finally {
		fs.rmSync(reopened);
	}
	await page.click('#le-board [data-code="KeyW"]');
	assert.match(await page.textContent('#le-shortcuts li'), /→ .*C/);
	assert.equal(await page.inputValue('#le-shortcut-key'), 'KeyC');
	assert.equal((await key('KeyE')).legend, 'R');
	// Back on a layer, the board edits mappings again.
	await page.click('[data-layer="base"]');
	assert.equal(await page.textContent('#le-board [data-code="KeyW"] .le-legend'), 'é');
	assert.deepEqual(errors, []);
	await page.context().close();
}

/**
 * Every key label stays inside its key: a long one shrinks to fit, and one still
 * too long at the smallest size is cut with an ellipsis and shown whole in the
 * key's tooltip, on every layer, both geometries, wide and at phone width.
 */
async function exerciseLongLabels(browser, origin) {
	const { page, errors } = await open(browser, origin, 'en');
	const map = async (code, text) => {
		await page.click(`#le-board [data-code="${code}"]`);
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', text);
		await page.click('#le-apply');
	};
	const LONG = 'Bonjour tout le monde, voici un très long texte';
	await map('KeyA', LONG);
	await map('KeyS', 'ÉÉÉÉ');
	await map('Space', '→ → → → → → → → → → → →');
	await map('Backspace', 'Effacer en arrière');
	// A dead key with a long terminator, and the same labels on a second layer.
	await tool(page, 'dead_keys');
	await page.fill('#le-dead-id', 'long');
	await page.fill('#le-dead-terminator', 'ˆ˜¨˝˘');
	await page.click('#le-dead-add');
	await page.click('#le-board [data-code="KeyD"]');
	await page.selectOption('#le-kind', 'dead_key');
	await page.selectOption('#le-dead', 'long');
	await page.click('#le-apply');
	await page.click('#le-layerbar [data-level="altgr"]');
	await page.waitForSelector('[data-layer="altgr"].active');
	await map('KeyQ', LONG);
	await map('Digit1', '«»«»«»«»');
	const overflowing = () =>
		page.$$eval('#le-board .le-key', (keys) =>
			keys
				.map((key) => {
					const legend = key.querySelector('.le-legend');
					const box = key.getBoundingClientRect();
					const text = legend.getBoundingClientRect();
					const inside =
						legend.scrollWidth <= legend.clientWidth ||
						getComputedStyle(legend).textOverflow === 'ellipsis';
					const fits = text.left >= box.left - 0.5 && text.right <= box.right + 0.5;
					const whole = !legend.textContent || key.title.includes(legend.textContent);
					return inside && fits && whole ? null : key.dataset.code;
				})
				.filter(Boolean)
		);
	for (const width of [1440, 375]) {
		await page.setViewportSize({ width, height: 900 });
		for (const form of ['iso', 'ansi', 'jis', 'abnt']) {
			await page.selectOption('#le-board-form', form);
			for (const layer of ['base', 'altgr']) {
				await page.click(`[data-layer="${layer}"]`);
				assert.deepEqual(await overflowing(), [], `${width}px ${form} ${layer}: labels overflow`);
			}
		}
	}
	// The long sentence is cut and named whole by its tooltip; a short one only shrinks.
	await page.setViewportSize({ width: 1440, height: 900 });
	await page.click('[data-layer="base"]');
	assert.ok(
		await page.$eval('#le-board [data-code="KeyA"] .le-legend', (n) => n.classList.contains('cut'))
	);
	// The key's own line comes first; once the panel's analysis lands, « Key colours »
	// adds its cost on a line of its own (applyHeat), so the label is not the title's end.
	const title = await page.getAttribute('#le-board [data-code="KeyA"]', 'title');
	assert.ok(title.split('\n')[0].endsWith(LONG), `the tooltip holds the whole label: ${title}`);
	const ss = await page.$eval('#le-board [data-code="KeyS"] .le-legend', (n) => ({
		cut: n.classList.contains('cut'),
		size: parseFloat(getComputedStyle(n).fontSize)
	}));
	assert.ok(!ss.cut && ss.size >= 9, 'a short label is not cut');
	assert.deepEqual(errors, []);
	await page.context().close();
}

/** At phone width, in light and dark, the page never scrolls sideways and stacks its columns. */
/**
 * (layout-editor-workspace) Several personal layouts, never lost, on the
 * website: each layout has its tab, « + » opens another, every tab and its
 * unsaved edits come back after F5 and after a crash (a new page of the same
 * browser profile, with no pagehide), persistent storage is asked for, a
 * damaged store is never saved over, and « Export all » then « Import »
 * restores every tab from the backup ZIP.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseWorkspace(browser, origin) {
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	const context = await browser.newContext({
		acceptDownloads: true,
		viewport: { width: 1280, height: 900 }
	});
	await context.addInitScript(() => {
		// Records the persistent storage request; the page must ask it once per mount.
		window.__persistAsked = 0;
		const storage = navigator.storage;
		storage.persist = () => {
			window.__persistAsked += 1;
			return Promise.resolve(false);
		};
	});
	const errors = [];
	const watch = (page) => {
		page.on('pageerror', (error) => errors.push(error.message));
		page.on('dialog', (dialog) => errors.push(`native dialog: ${dialog.message()}`));
		return page;
	};
	const url = `${origin}/ui/layout_editor/index.html?lang=en`;
	const saved = strings['layout_editor.tabs.autosave.saved'];
	const settled = (page) =>
		page.waitForFunction((text) => {
			const node = document.querySelector('#le-autosave');
			return node && node.textContent.startsWith(text);
		}, saved);
	const tabNames = (page) =>
		page.$$eval('#le-layout-tabs .le-layout-tab', (tabs) => tabs.map((tab) => tab.textContent));
	const legendOf = (page, code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
	const mapKey = async (page, code, text) => {
		await page.click(`#le-board [data-code="${code}"]`);
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', text);
		await page.click('#le-apply');
	};

	const page = watch(await context.newPage());
	await page.goto(url);
	await page.waitForSelector('#le-board');
	await settled(page);
	assert.equal(
		await page.evaluate(() => window.__persistAsked),
		1,
		'persistent storage is asked for'
	);
	assert.match(
		await page.textContent('#le-autosave'),
		/export a backup/,
		'a refused persistent storage is said'
	);
	await mapKey(page, 'KeyQ', 'ŵ');
	// « + » opens a blank layout in a new tab with « Start from » open.
	await page.click('#le-tab-add');
	await page.waitForSelector('#le-start');
	assert.equal(
		await page.locator('#le-start [data-start="file"]').count(),
		1,
		'« Start from » opens a file'
	);
	await page.click('#le-start [data-start="qwerty"]');
	await page.waitForSelector('#le-start', { state: 'detached' });
	assert.equal(await legendOf(page, 'KeyQ'), 'q', 'the new tab starts from QWERTY');
	await page.fill('#le-name', 'Second');
	await page.press('#le-name', 'Tab');
	await mapKey(page, 'KeyW', 'ŷ');
	assert.deepEqual(await tabNames(page), ['My layout •', 'Second •']);
	// Each tab keeps its own document and history.
	await page.click('#le-layout-tabs [data-tab="0"]');
	assert.equal(await legendOf(page, 'KeyQ'), 'ŵ');
	assert.equal(await page.isDisabled('#le-undo'), false, 'the first tab keeps its own undo');
	await page.click('#le-layout-tabs [data-tab="1"]');
	assert.equal(await legendOf(page, 'KeyW'), 'ŷ');
	await settled(page);

	// F5: every tab and its unsaved edits come back, on the tab shown.
	await page.reload();
	await page.waitForSelector('#le-board');
	await settled(page);
	assert.deepEqual(await tabNames(page), ['My layout •', 'Second •']);
	assert.equal(await page.getAttribute('#le-layout-tabs [data-tab="1"]', 'aria-current'), 'true');
	assert.equal(await legendOf(page, 'KeyW'), 'ŷ');
	await page.click('#le-layout-tabs [data-tab="0"]');
	assert.equal(await legendOf(page, 'KeyQ'), 'ŵ');
	await mapKey(page, 'KeyE', 'ẽ');
	await settled(page);

	// A crash: the page is gone without its pagehide; a new page restores the last save.
	const crashed = watch(await context.newPage());
	await page.close({ runBeforeUnload: false });
	await crashed.goto(url);
	await crashed.waitForSelector('#le-board');
	await settled(crashed);
	assert.deepEqual(await tabNames(crashed), ['My layout •', 'Second •']);
	assert.equal(await legendOf(crashed, 'KeyE'), 'ẽ', 'the edit made just before the crash is back');

	// « Export all » writes one ZIP of every tab's source.
	const [download] = await Promise.all([
		crashed.waitForEvent('download'),
		crashed.click('#le-tabs-export')
	]);
	assert.equal(download.suggestedFilename(), 'ergopti-studio-layouts.zip');
	const archive = fs.readFileSync(await download.path());
	assert.equal(archive.subarray(0, 2).toString('latin1'), 'PK');
	assert.deepEqual(
		await crashed.evaluate(
			(bytes) =>
				LayoutEditorWorkspace.readArchive(new Uint8Array(bytes)).then((files) =>
					files.map((file) => [file.name, /name = "([^"]*)"/.exec(file.text)[1]])
				),
			[...archive]
		),
		[
			['my_layout.toml', 'My layout'],
			['qwerty_custom.toml', 'Second']
		]
	);

	// Closing an unsaved tab asks first; closing every tab leaves one blank layout.
	await crashed.click('#le-layout-tabs [data-close-tab="1"]');
	await crashed.click('#le-confirm-yes');
	await crashed.click('#le-layout-tabs [data-close-tab="0"]');
	await crashed.click('#le-confirm-yes');
	assert.deepEqual(await tabNames(crashed), ['My layout']);
	// « Import » opens every layout of the backup in its own tab.
	const backup = path.join(require('node:os').tmpdir(), `layout-editor-backup-${process.pid}.zip`);
	fs.writeFileSync(backup, archive);
	try {
		// The page reads the chosen files after the pick: the file stays until it has.
		await crashed.setInputFiles('#le-tabs-import-file', [backup, KEYLAYOUT]);
		await crashed.waitForFunction(
			() => document.querySelectorAll('#le-layout-tabs .le-layout-tab').length === 4
		);
	} finally {
		fs.rmSync(backup);
	}
	assert.deepEqual((await tabNames(crashed)).slice(1, 3), ['My layout', 'Second']);
	assert.equal(await legendOf(crashed, 'KeyE'), 'ẽ', 'the imported tab is shown with its edits');
	assert.match(await crashed.textContent('#le-message'), /3 layouts imported/);
	await settled(crashed);

	// A damaged store is said and never saved over, even after an edit.
	await crashed.evaluate(
		() =>
			new Promise((resolve, reject) => {
				const open = indexedDB.open('ergopti-studio', 1);
				open.onerror = () => reject(open.error);
				open.onsuccess = () => {
					const put = open.result
						.transaction('workspace', 'readwrite')
						.objectStore('workspace')
						.put('{broken', 'editor');
					put.onsuccess = () => resolve();
					put.onerror = () => reject(put.error);
				};
			})
	);
	await crashed.reload();
	await crashed.waitForSelector('#le-board');
	await crashed.waitForSelector('#le-autosave.failed');
	assert.match(await crashed.textContent('#le-message'), /could not be restored/);
	await mapKey(crashed, 'KeyR', 'ŕ');
	await crashed.waitForTimeout(800);
	const kept = await crashed.evaluate(
		() =>
			new Promise((resolve) => {
				const open = indexedDB.open('ergopti-studio', 1);
				open.onsuccess = () => {
					const get = open.result.transaction('workspace').objectStore('workspace').get('editor');
					get.onsuccess = () => resolve(get.result);
				};
			})
	);
	assert.equal(kept, '{broken', 'the damaged workspace is left as it was');
	assert.deepEqual(errors, [], 'workspace: page errors');
	await context.close();
}

/**
 * (layout-editor-workspace) The app window keeps the tabs in the user's data
 * folder through the host: it reads them with studio_workspace_load when it
 * mounts, restores them, saves every change with studio_workspace_save, and
 * saves before « Close » closes the window.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseAppWorkspace(browser, origin) {
	const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	await page.addInitScript((strings) => {
		window._i18n_strings = strings;
		window.__posted = [];
		window.webkit = {
			messageHandlers: {
				layout_editor_window_bridge: { postMessage: (payload) => window.__posted.push(payload) }
			}
		};
	}, strings);
	await page.goto(`${origin}/ui/layout_editor_window/index.html`);
	await page.evaluate(() =>
		window.initData({
			strings: {},
			state: {
				platform: 'linux',
				index: { layouts: [] },
				installed: {},
				provided: {},
				builtin: {}
			},
			source_editor: true,
			source_export: true,
			studio_store: true,
			studio_workspace: true
		})
	);
	await page.evaluate(() => window.sourceData({ text: null, folder: 'layout_sources/' }));
	await page.waitForSelector('#layout-editor #le-board');
	await page.waitForFunction(() =>
		window.__posted.some((p) => p.action === 'studio_workspace_load')
	);
	const source = fs.readFileSync(SOURCE_FIXTURE, 'utf8');
	await page.evaluate((source) => {
		const asked = window.__posted.find((p) => p.action === 'studio_workspace_load');
		window.studioWorkspace({
			request: asked.request,
			ok: true,
			workspace: JSON.stringify({
				schema: 1,
				active: 1,
				tabs: [
					{ text: source, dirty: false },
					{ text: source.replace('name = "Source Fixture"', 'name = "Edited"'), dirty: true }
				]
			})
		});
	}, source);
	await page.waitForFunction(
		() => document.querySelectorAll('#le-layout-tabs .le-layout-tab').length === 2
	);
	assert.deepEqual(
		await page.$$eval('#le-layout-tabs .le-layout-tab', (tabs) =>
			tabs.map((tab) => tab.textContent)
		),
		['Source Fixture', 'Edited •']
	);
	assert.equal(await page.inputValue('#le-name'), 'Edited', 'the stored active tab is shown');
	// A restored workspace wins over the window's start copy of Ergopti: answering
	// the catalogue, if the page asked for it, must not replace a restored tab.
	await page.evaluate(
		(keylayout) => {
			if (window.__posted.some((p) => p.action === 'composer_open'))
				window.composerData({
					sources: [{ id: 'ergopti', name: 'Ergopti', convention: 'iso', text: keylayout }]
				});
		},
		fs.readFileSync(KEYLAYOUT, 'utf8')
	);
	await page.waitForTimeout(300);
	assert.deepEqual(
		await page.$$eval('#le-layout-tabs .le-layout-tab', (tabs) =>
			tabs.map((tab) => tab.textContent)
		),
		['Source Fixture', 'Edited •'],
		'the restored tabs stay'
	);
	assert.equal(await page.inputValue('#le-name'), 'Edited');
	await page.fill('#le-name', 'Edited again');
	await page.press('#le-name', 'Tab');
	await page.waitForFunction(() =>
		window.__posted.some((p) => p.action === 'studio_workspace_save')
	);
	const save = await page.evaluate(() =>
		window.__posted.filter((p) => p.action === 'studio_workspace_save').pop()
	);
	const stored = JSON.parse(save.text);
	assert.equal(stored.active, 1);
	assert.match(stored.tabs[1].text, /name = "Edited again"/);
	await page.evaluate(
		(request) => window.studioWorkspaceResult({ request, ok: true }),
		save.request
	);
	await page.waitForFunction(
		(text) => document.querySelector('#le-autosave').textContent === text,
		strings['layout_editor.tabs.autosave.saved']
	);
	// A refused save is said, not hidden.
	await page.fill('#le-name', 'Third');
	await page.press('#le-name', 'Tab');
	await page.waitForFunction(
		(count) => window.__posted.filter((p) => p.action === 'studio_workspace_save').length > count,
		1
	);
	const refused = await page.evaluate(() =>
		window.__posted.filter((p) => p.action === 'studio_workspace_save').pop()
	);
	await page.evaluate(
		(request) =>
			window.studioWorkspaceResult({
				request,
				ok: false,
				code: 'studio_write_failed',
				detail: 'disk full'
			}),
		refused.request
	);
	await page.waitForSelector('#le-autosave.failed');
	assert.match(await page.textContent('#le-autosave'), /could not write to your data folder/);
	// « Close » saves the last edit before the window closes.
	await page.fill('#le-name', 'Last');
	await page.press('#le-name', 'Tab');
	await page.click('#le-close');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'close'));
	const order = await page.evaluate(() =>
		window.__posted
			.filter((p) => p.action === 'studio_workspace_save' || p.action === 'close')
			.map((p) =>
				p.action === 'close'
					? 'close'
					: JSON.parse(p.text).tabs[1].text.match(/name = "([^"]*)"/)[1]
			)
	);
	assert.deepEqual(
		order.slice(-2),
		['Last', 'close'],
		'the last edit is saved before the window closes'
	);
	assert.deepEqual(errors, [], 'app workspace: page errors');
	await page.close();
}

/**
 * (studio-key-heatmap) « Key colours » of the analysis panel colours the
 * editor's own keys live: QWERTY's « e » and « d » share a finger, so with the
 * SFB metric they are red with each other named as their worst pair; moving a
 * character away recolours them at once; the global score names the points a
 * key loses; « None » clears every colour.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseHeatmap(browser, origin) {
	const { page, errors } = await open(browser, origin, 'en');
	await page.click('#le-new');
	await page.click('#le-start [data-start="qwerty"]');
	await page.waitForSelector('#le-start', { state: 'detached' });
	await page.waitForSelector('#la-panel-heat');
	const heatOf = (code) =>
		page.evaluate((code) => {
			const key = document.querySelector(`#le-board [data-code="${code}"]`);
			return key.classList.contains('le-heat')
				? { heat: Number(key.style.getPropertyValue('--le-heat')), title: key.title }
				: null;
		}, code);
	const settle = (code, test) =>
		page.waitForFunction(
			({ code, test }) => {
				const key = document.querySelector(`#le-board [data-code="${code}"]`);
				const heat = key.classList.contains('le-heat')
					? Number(key.style.getPropertyValue('--le-heat'))
					: null;
				return new Function('heat', `return ${test}`)(heat);
			},
			{ code, test },
			{ timeout: 15000 }
		);
	// The default is the global score: every key says the points it loses.
	await settle('KeyE', 'heat !== null');
	// (panel-rank-selection) « Rank among » ranks the edited layout among the
	// layouts ticked in the Comparer (its saved selection) instead of the library;
	// the finger load marks each finger's ideal.
	const rankCount = () =>
		page.evaluate(() => {
			const m = document.querySelector('.la-panel-score').textContent.match(/of (\d+)/);
			return m ? Number(m[1]) : null;
		});
	await page.waitForFunction(() =>
		/of \d+/.test(document.querySelector('.la-panel-score').textContent)
	);
	assert.ok((await rankCount()) > 100, 'ranked among the whole library');
	assert.equal(await page.locator('.la-panel-target').count(), 8, 'eight ideal marks');
	await page.evaluate(() => {
		const key = 'ergopti.layout_analysis.v1';
		const saved = JSON.parse(window.localStorage.getItem(key) || '{}');
		window.localStorage.setItem(
			key,
			JSON.stringify(Object.assign(saved, { selected: ['qwerty', 'dvorak', 'bepo'] }))
		);
	});
	await page.selectOption('#la-panel-rank', 'selection');
	await page.waitForFunction(() =>
		/of 4\b/.test(document.querySelector('.la-panel-score').textContent)
	);
	await page.selectOption('#la-panel-rank', 'library');
	await page.waitForFunction(() =>
		/of \d{3}/.test(document.querySelector('.la-panel-score').textContent)
	);
	assert.match((await heatOf('KeyE')).title, /points lost/);
	await page.selectOption('#la-panel-heat', 'sfb');
	await page.waitForFunction(() =>
		/worst: e d/.test(document.querySelector('#le-board [data-code="KeyE"]').title)
	);
	const before = await heatOf('KeyE');
	assert.ok(before.heat > 0.3, `KeyE is among the worst SFB keys (${before.heat})`);
	assert.match(before.title, /Same-finger bigrams|SFB/i);
	assert.equal(
		(await heatOf('Space')) && (await heatOf('Space')).heat,
		0,
		'a key without SFB is green'
	);
	// Moving « e » onto another finger's key recolours KeyE at once.
	await page.click('#le-board [data-code="KeyE"]');
	await page.selectOption('#le-kind', 'text');
	await page.fill('#le-text', 'ẑ');
	await page.click('#le-apply');
	await settle('KeyE', `heat !== null && heat < ${before.heat / 2}`);
	// The colours follow every render and leave with « None ».
	await page.selectOption('#la-panel-heat', 'off');
	await page.waitForFunction(() => document.querySelectorAll('#le-board .le-heat').length === 0);
	assert.deepEqual(errors, [], 'heatmap: page errors');
	await page.context().close();
}

async function exercisePhoneWidth(browser, origin) {
	const backgrounds = [];
	for (const colorScheme of ['light', 'dark']) {
		const context = await browser.newContext({
			viewport: { width: 375, height: 812 },
			colorScheme
		});
		const page = await context.newPage();
		const errors = [];
		page.on('pageerror', (error) => errors.push(error.message));
		await page.goto(`${origin}/ui/layout_editor/index.html?lang=fr`);
		await page.waitForSelector('#le-board');
		await page.click('#le-board [data-code="KeyA"]');
		const layout = await page.evaluate(() => {
			const box = (selector) => document.querySelector(selector).getBoundingClientRect();
			const inside = (selector) =>
				[...document.querySelectorAll(selector)].every((node) => {
					const rect = node.getBoundingClientRect();
					return rect.left >= 0 && rect.right <= window.innerWidth;
				});
			return {
				pageWidth: document.documentElement.scrollWidth,
				viewport: window.innerWidth,
				toolbarInside: inside('.le-toolbar button'),
				tabsInside: inside('#le-layout-tabs button'),
				levelsInside: inside('#le-layerbar [data-level]'),
				toolTabsInside: inside('#le-tools [data-tool]'),
				boardScrolls: (() => {
					const scroller = document.querySelector('.le-board-scroll');
					return scroller.scrollWidth > scroller.clientWidth;
				})(),
				smallestKey: Math.min(
					...[...document.querySelectorAll('#le-board .le-key')].map(
						(key) => key.getBoundingClientRect().width
					)
				),
				inspectorBelowBoard: box('#le-inspector').top >= box('#le-board').bottom,
				toolsBelowInspector: box('#le-tools').top >= box('#le-inspector').bottom,
				background: getComputedStyle(document.querySelector('#layout-editor')).backgroundColor
			};
		});
		assert.equal(layout.pageWidth, layout.viewport, `${colorScheme}: no sideways page scroll`);
		assert.ok(layout.toolbarInside, `${colorScheme}: the primary toolbar fits the screen`);
		assert.ok(layout.tabsInside, `${colorScheme}: the layout tabs fit the screen`);
		assert.ok(layout.levelsInside, `${colorScheme}: the four levels fit the screen`);
		assert.ok(layout.inspectorBelowBoard, `${colorScheme}: the inspector stacks under the board`);
		assert.ok(layout.toolsBelowInspector, `${colorScheme}: the tools come last`);
		assert.ok(layout.toolTabsInside, `${colorScheme}: every tool tab is shown whole`);
		// The keys keep a readable size: the board scrolls sideways on its own, the page does not.
		assert.ok(layout.boardScrolls, `${colorScheme}: the board has its own sideways scroll`);
		assert.ok(
			layout.smallestKey >= 36,
			`${colorScheme}: keys stay readable (${layout.smallestKey})`
		);
		// Every key can be reached: the last one scrolls into view and is clicked.
		await page.locator('#le-board [data-code="ArrowRight"]').scrollIntoViewIfNeeded();
		await page.click('#le-board [data-code="ArrowRight"]');
		assert.equal(
			await page.textContent('#le-inspector h2'),
			await page.getAttribute('#le-board [data-code="ArrowRight"]', 'title')
		);
		assert.equal(
			await page.evaluate(() => document.documentElement.scrollWidth),
			layout.viewport,
			`${colorScheme}: scrolling the board does not scroll the page`
		);
		// Every tool opens without widening the page.
		for (const id of await page.$$eval('#le-tools [data-tool]', (tabs) =>
			tabs.map((tab) => tab.dataset.tool)
		)) {
			await tool(page, id);
			assert.equal(
				await page.evaluate(() => document.documentElement.scrollWidth),
				layout.viewport,
				`${colorScheme}: the ${id} tool fits the screen`
			);
		}
		backgrounds.push(layout.background);
		assert.deepEqual(errors, []);
		await context.close();
	}
	assert.notEqual(backgrounds[0], backgrounds[1], 'the dark theme changes the page background');
}

/**
 * (benchmarks-shared-engine) A link opens the Comparer on a corpus, a
 * keyboard and a keyboard format over the saved choice, as the site's benchmark page does; a value
 * the page does not know is named in the console and the saved choice stays.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseComparerLink(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	const warnings = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('console', (message) => {
		if (message.type() === 'warning') warnings.push(message.text());
	});
	const choices = async (query) => {
		await page.goto(`${origin}/ui/layout_analysis/index.html?lang=en&${query}`);
		await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
		return [
			await page.inputValue('#la-corpus'),
			await page.inputValue('#la-keyboard'),
			await page.inputValue('#la-format')
		];
	};
	assert.deepEqual(await choices('corpus=fr_nemolivier&keyboard=ergodox&format=60'), [
		'fr_nemolivier',
		'ergodox',
		'60'
	]);
	// The link wins over the choice the visitor saved last time.
	await page.selectOption('#la-keyboard', 'ansi');
	assert.deepEqual((await choices('corpus=en_wikipedia&keyboard=iso')).slice(0, 2), [
		'en_wikipedia',
		'iso'
	]);
	const [corpus, keyboard] = await choices('corpus=nowhere&keyboard=nokeyboard&format=nope');
	// A link's choice is not saved: the visitor's last own choice (ANSI) stays.
	assert.equal(corpus, 'fr_nemolivier', 'an unknown corpus keeps the saved one');
	assert.equal(keyboard, 'ansi', 'an unknown keyboard keeps the saved one');
	assert.ok(warnings.some((text) => /no built-in corpus nowhere/.test(text)));
	assert.ok(warnings.some((text) => /no keyboard nokeyboard/.test(text)));
	assert.ok(warnings.some((text) => /no keyboard format nope/.test(text)));
	// (comparer-share) A link names the compared layouts, the one in detail and
	// the one it is compared with; an unknown layout is named in the console.
	await choices('layouts=qwerty,dvorak,nolayout&details=qwerty&versus=dvorak');
	assert.deepEqual(
		(
			await page.$$eval('#la-table tbody tr', (rows) => rows.map((row) => row.cells[1].textContent))
		).sort(),
		['Dvorak', 'QWERTY (US)'],
		'the two linked layouts'
	);
	assert.equal(await page.isVisible('#la-details'), true, 'the linked details are open');
	assert.equal(await page.inputValue('#la-versus'), 'dvorak');
	assert.ok(warnings.some((text) => /no layout nolayout/.test(text)));
	// The link's layouts are shown, not saved: the next plain visit has the saved selection.
	await choices('');
	assert.ok(
		(await page.locator('#la-table tbody tr').count()) > 2,
		'a plain visit keeps the visitor’s own selection'
	);
	assert.deepEqual(errors, [], 'comparer link: page errors');
	await context.close();
}

(async () => {
	const server = await serve();
	const origin = `http://127.0.0.1:${server.address().port}`;
	const browser = await chromium.launch(
		process.env.CHROMIUM_EXECUTABLE ? { executablePath: process.env.CHROMIUM_EXECUTABLE } : {}
	);
	try {
		const { page, errors } = await open(browser, origin, 'en');

		// A key edit shows on the board and in the saved source.
		await page.click('#le-board [data-code="KeyA"]');
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', 'æ');
		await page.click('#le-apply');
		assert.equal(await page.textContent('#le-board [data-code="KeyA"] .le-legend'), 'æ');

		// A tap-hold delay or a virtual key outside its shared value schema
		// declaration is refused with the text naming the range, and nothing is
		// applied (value-validation).
		const strings = JSON.parse(
			fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
		);
		const thresholdRange = strings['dialog.value_check.range_integer_unit']
			.replace('{1}', '1')
			.replace('{2}', '10000')
			.replace('{3}', strings['value_check.unit.ms']);
		await page.click('#le-group-tap_hold summary');
		await page.click('#le-group-key summary');
		for (const typed of ['0', '10001', '2.5', '']) {
			await page.fill('#le-threshold', typed);
			await page.click('#le-tap-hold-apply');
			assert.equal(await page.textContent('#le-message'), thresholdRange, `threshold ${typed}`);
			assert.equal(
				await page.locator('#le-tap-hold-remove').count(),
				0,
				`no tap-hold for ${typed}`
			);
		}
		const virtualKeyRange = strings['dialog.value_check.range_integer']
			.replace('{1}', '0')
			.replace('{2}', '255');
		for (const typed of ['256', '-1']) {
			await page.fill('#le-virtual-key', typed);
			await page.click('#le-key-apply');
			assert.equal(await page.textContent('#le-message'), virtualKeyRange, `virtual key ${typed}`);
		}

		// The name search loads the names table lazily, then maps a result to the key.
		assert.equal(await page.evaluate(() => typeof UNICODE_NAMES_DATA), 'undefined');
		await page.click('#le-board [data-code="KeyW"]');
		await page.selectOption('#le-kind', 'text');
		await page.click('.le-palette summary');
		await page.fill('#le-name-search', 'e*acute');
		await page.fill('#le-name-limit', '3');
		await page.press('#le-name-search', 'Enter');
		await page.waitForSelector('#le-name-results [data-point="U+00E9"]');
		assert.equal(await page.locator('#le-name-results .le-glyph').count(), 3);
		assert.match(await page.textContent('#le-name-count'), /3/);
		await page.hover('#le-name-results [data-point="U+00E9"]');
		assert.equal(await page.textContent('#le-magnifier-glyph'), 'é');
		assert.match(
			await page.textContent('#le-magnifier-rows'),
			/U\+00E9 LATIN SMALL LETTER E WITH ACUTE · Latin-1 Supplement/
		);
		await page.click('#le-name-results [data-point="U+00E9"]');
		assert.equal(await page.inputValue('#le-text'), 'é');
		await page.click('#le-apply');
		assert.equal(await page.textContent('#le-board [data-code="KeyW"] .le-legend'), 'é');
		// A rendered page keeps the palette open with its last answer.
		assert.equal(await page.locator('#le-name-results [data-point="U+00E9"]').count(), 1);
		// Dropping a result on another key maps that key to the character (the two are
		// far apart on the page, so the drag events carry one DataTransfer directly).
		const transfer = await page.evaluateHandle(() => new DataTransfer());
		await page.dispatchEvent('#le-name-results [data-point="U+00C9"]', 'dragstart', {
			dataTransfer: transfer
		});
		await page.dispatchEvent('#le-board [data-code="KeyE"]', 'drop', { dataTransfer: transfer });
		assert.equal(await page.textContent('#le-board [data-code="KeyE"] .le-legend'), 'É');
		// Hovering a key magnifies its legend; Copy puts it on the clipboard.
		await page.hover('#le-board [data-code="KeyE"]');
		assert.equal(await page.textContent('#le-magnifier-glyph'), 'É');
		await page.click('#le-magnifier-copy');
		// The clipboard write is asynchronous: wait until it holds the glyph.
		await page.waitForFunction(async () => (await navigator.clipboard.readText()) === 'É');
		await page.click('#le-undo');
		await page.click('#le-undo');

		// A dead key with a rule types its composition in the preview.
		await tool(page, 'dead_keys');
		await page.fill('#le-dead-id', 'circ');
		await page.fill('#le-dead-terminator', '^');
		await page.click('#le-dead-add');
		await page.fill('#le-rule-input', 'æ');
		await page.fill('#le-rule-output', 'ǣ');
		await page.click('#le-rule-add');
		await page.click('#le-board [data-code="BracketLeft"]');
		await page.selectOption('#le-kind', 'dead_key');
		await page.selectOption('#le-dead', 'circ');
		await page.click('#le-apply');
		await page.focus('#le-preview-input');
		await page.keyboard.press('BracketLeft');
		await page.keyboard.press('KeyA');
		await page.keyboard.press('BracketLeft');
		await page.keyboard.press('BracketLeft');
		assert.equal(await page.textContent('#le-preview-output'), 'ǣ^');
		// (try-input-bar) « Essayer » is one input bar: the result shows inside it,
		// the clear button sits inside it at its end, there is no separate
		// « Clear » button, and the focused bar shows the accent ring.
		const bar = await page.evaluate(() => {
			const box = (node) => node.getBoundingClientRect();
			const outer = box(document.getElementById('le-try'));
			const inside = (node) => {
				const inner = box(node);
				return (
					inner.left >= outer.left &&
					inner.right <= outer.right &&
					inner.top >= outer.top &&
					inner.bottom <= outer.bottom
				);
			};
			const style = getComputedStyle(document.getElementById('le-try'));
			return {
				output: inside(document.getElementById('le-preview-output')),
				clear: inside(document.getElementById('le-preview-clear')),
				field: inside(document.getElementById('le-preview-input')),
				clearAtEnd: box(document.getElementById('le-preview-clear')).right > outer.right - 40,
				rounded: parseFloat(style.borderTopLeftRadius) >= 8,
				ring: style.boxShadow !== 'none',
				buttons: document.querySelectorAll('.le-preview button').length
			};
		});
		assert.deepEqual(
			bar,
			{
				output: true,
				clear: true,
				field: true,
				clearAtEnd: true,
				rounded: true,
				ring: true,
				buttons: 1
			},
			'one input bar with its clear button inside'
		);
		await page.click('#le-preview-clear');
		assert.equal(await page.textContent('#le-preview-output'), '', 'the bar is cleared');
		assert.equal(
			await page.$eval('#le-preview-clear', (node) => getComputedStyle(node).visibility),
			'hidden',
			'an empty bar shows no clear button'
		);

		const saved = await downloaded(page, () => page.click('#le-save'));
		assert.equal(saved.name, 'my_layout.toml');
		assert.match(saved.text, /format = "ergopti-layout"/);
		assert.match(saved.text, /dead_key = "circ"/);

		// Undo reverts the last edit.
		await page.click('#le-undo');
		assert.equal(await page.textContent('#le-board [data-code="BracketLeft"] .le-legend'), '');

		// A .keylayout imports verbatim, exports unchanged, then converts to editable layers.
		await tool(page, 'details');
		await page.selectOption('#le-import-convention', 'iso');
		await page.setInputFiles('#le-open-file', KEYLAYOUT);
		await page.waitForSelector('#le-preserved');
		await tool(page, 'export');
		assert.equal(await page.locator('#le-macos-format').count(), 0, 'an import keeps its variant');
		assert.deepEqual(
			(await exportFormats(page)).filter((id) => id.startsWith('macos_')),
			['macos_iso'],
			'an imported .keylayout offers only its own variant'
		);
		const exported = await downloaded(page, () => exportAs(page, 'macos_iso'));
		assert.equal(exported.text, fs.readFileSync(KEYLAYOUT, 'utf8'));
		await page.click('#le-convert');
		await page.click('#le-confirm-yes');
		await page.waitForSelector('#le-lost');
		assert.notEqual(await page.textContent('#le-board [data-code="KeyA"] .le-legend'), '');
		// The converted source compiles both variants through the shared compiler.
		// The macOS drop-down chooses the download: one .keylayout, or the bundle as one ZIP.
		const compiled = await downloaded(page, () => exportAs(page, 'macos_ansi'));
		assert.match(compiled.text, /<keyboard /);
		assert.notEqual(compiled.text, fs.readFileSync(KEYLAYOUT, 'utf8'));
		const iso = await downloaded(page, () => exportAs(page, 'macos_iso'));
		assert.notEqual(iso.text, compiled.text, 'ISO and ANSI differ');
		const [bundle] = await Promise.all([
			page.waitForEvent('download'),
			exportAs(page, 'macos_bundle')
		]);
		assert.match(bundle.suggestedFilename(), /\.bundle\.zip$/);
		assert.equal(
			fs
				.readFileSync(await bundle.path())
				.subarray(0, 2)
				.toString('latin1'),
			'PK'
		);

		// Linux XKB and Windows KLC download from the shared converters run in the page.
		const [xkb] = await Promise.all([page.waitForEvent('download'), exportAs(page, 'xkb')]);
		assert.equal(xkb.suggestedFilename(), 'ergopti_xkb.zip');
		const xkbBytes = fs.readFileSync(await xkb.path());
		assert.equal(xkbBytes.subarray(0, 2).toString('latin1'), 'PK');
		for (const name of ['ergopti.xkb', 'ergopti.XCompose', 'xkb_types.txt', 'export.json'])
			assert(xkbBytes.includes(`ergopti_xkb/${name}`), `the XKB archive holds ${name}`);
		// The KLC needs its Windows metadata first: the refusal says so.
		await exportAs(page, 'klc');
		await page.waitForSelector('.le-message.error');
		await tool(page, 'windows');
		await page.fill('#le-win-locale', 'fr-FR');
		await page.fill('#le-win-layout-id', '0000040c');
		await page.fill('#le-win-dll-name', 'kbdergo');
		await page.click('#le-win-klc-apply');
		await tool(page, 'export');
		const [klc] = await Promise.all([page.waitForEvent('download'), exportAs(page, 'klc')]);
		assert.equal(klc.suggestedFilename(), 'kbdergo.klc');
		// The site says where the Windows DLL and installer come from, and offers no
		// in-app install or emulation.
		assert.match(await page.textContent('#le-dll-note'), /node tools\/kbd-dll\.cjs build/);
		// The four Windows DLLs, written in the page with no compiler.
		const [dll] = await Promise.all([page.waitForEvent('download'), exportAs(page, 'dll')]);
		assert.equal(dll.suggestedFilename(), 'kbdergo-windows.zip');
		const dllZip = fs.readFileSync(await dll.path());
		assert.deepEqual([...dllZip.subarray(0, 4)], [0x50, 0x4b, 0x03, 0x04], 'a ZIP');
		for (const arch of ['x86', 'wow64', 'x64', 'arm64'])
			assert.ok(dllZip.includes(`kbdergo/${arch}/kbdergo.dll`), `${arch} image in the ZIP`);
		// (windows-package) The generic installer and the layout.ini it reads.
		assert.ok(dllZip.includes('kbdergo/kbdergo-setup.exe'), 'the installer in the ZIP');
		assert.ok(dllZip.includes('kbdergo/layout.ini'), 'its layout.ini in the ZIP');
		assert.ok(
			dllZip.includes(Buffer.from('[layout]\r\ndll_name=kbdergo\r\n', 'utf16le')),
			'layout.ini names the layout file'
		);
		assert.ok(
			dllZip.includes(Buffer.from('KbdLayerDescriptor')),
			'the images export KbdLayerDescriptor'
		);
		assert.equal(await page.locator('#le-install, #le-emulate').count(), 0);
		const klcBytes = fs.readFileSync(await klc.path());
		assert.deepEqual([...klcBytes.subarray(0, 2)], [0xff, 0xfe], 'MSKLC UTF-16LE with a BOM');
		assert.match(klcBytes.toString('utf16le'), /KBD\tkbdergo\t/);
		await page.click('#le-undo');

		// Drag and drop swaps two keys; copy and paste repeats one.
		const legendOf = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
		const [a, s] = [await legendOf('KeyA'), await legendOf('KeyS')];
		await page.dragAndDrop('#le-board [data-code="KeyA"]', '#le-board [data-code="KeyS"]');
		assert.deepEqual([await legendOf('KeyA'), await legendOf('KeyS')], [s, a]);
		await page.click('#le-board [data-code="KeyA"]');
		await page.click('#le-copy');
		await page.click('#le-board [data-code="KeyD"]');
		await page.click('#le-paste');
		assert.equal(await legendOf('KeyD'), s);

		// The ANSI board has no ISO extra key; Windows flags and exact stickers apply.
		await page.selectOption('#le-board-form', 'ansi');
		assert.equal(await page.locator('#le-board [data-code="IntlBackslash"]').count(), 0);
		// (jis-abnt-boards) The JIS and ABNT boards draw their own keys, each named by its tooltip.
		const drawn = async (code) => page.locator(`#le-board [data-code="${code}"]`).count();
		await page.selectOption('#le-board-form', 'jis');
		for (const code of ['IntlYen', 'IntlRo', 'NonConvert', 'Convert', 'KanaMode'])
			assert.equal(await drawn(code), 1, `JIS draws ${code}`);
		assert.equal(await drawn('IntlBackslash'), 0, 'JIS has no ISO key left of Z');
		const henkan = await page.getAttribute('#le-board [data-code="Convert"]', 'title');
		assert.ok(henkan && henkan !== 'Convert', `Henkan has a translated name: ${henkan}`);
		// The keypad comma is a keypad key: drawn on the full-size format.
		const shownFormat = await page.inputValue('#le-board-format');
		await page.selectOption('#le-board-format', 'full');
		await page.selectOption('#le-board-form', 'abnt');
		for (const code of ['IntlRo', 'NumpadComma', 'IntlBackslash'])
			assert.equal(await drawn(code), 1, `ABNT draws ${code}`);
		assert.equal(await drawn('IntlYen'), 0, 'ABNT has no Yen');
		await page.selectOption('#le-board-format', 'tkl');
		assert.equal(await drawn('NumpadComma'), 0, 'a TKL board has no keypad comma');
		await page.selectOption('#le-board-format', shownFormat);
		await page.selectOption('#le-board-form', 'iso');
		await tool(page, 'windows');
		await page.fill('#le-win-flags', 'kllf_altgr');
		await page.click('#le-win-flags-apply');
		assert.equal(await page.inputValue('#le-win-flags'), 'kllf_altgr');
		await tool(page, 'stickers');
		await page.fill('#le-sticker-mm', '18');
		await page.dispatchEvent('#le-sticker-mm', 'change');
		assert.match(await page.getAttribute('#le-stickers', 'style'), /--le-sticker-size:18mm/);
		await page.click('#le-undo');

		// KbdEdit's automatic case mapping fills Shift, replacing it only when asked.
		await page.click('[data-layer="base"]');
		await page.click('#le-board [data-code="KeyD"]');
		await page.selectOption('#le-kind', 'text');
		await page.fill('#le-text', 'ŵ');
		await page.check('#le-case-overwrite');
		await page.click('#le-apply');
		await page.click('[data-layer="shift"]');
		assert.equal(await legendOf('KeyD'), 'Ŵ');
		// Stickers print the chosen levels and can hide a Shift legend that is only the capital.
		const sticker = (level) =>
			page.evaluate(
				(cls) =>
					[...document.querySelectorAll(`#le-stickers .le-sticker-${cls}`)].map(
						(e) => e.textContent
					),
				level
			);
		assert.ok((await sticker('shift')).includes('Ŵ'));
		await tool(page, 'stickers');
		await page.check('#le-sticker-hide-case');
		assert.ok(!(await sticker('shift')).includes('Ŵ'), 'the capital of the base is hidden');
		await page.uncheck('#le-sticker-layer-shift');
		assert.equal((await sticker('shift')).length, 0, 'an unchosen level is not printed');
		// « Move every key »: the Shift layer's mappings go to the base layer at once.
		await tool(page, 'layers');
		await page.selectOption('#le-move-target', 'base');
		await page.click('#le-move-layer');
		assert.equal(await legendOf('KeyD'), '', 'the moved layer is empty');
		await page.click('[data-layer="base"]');
		assert.equal(await legendOf('KeyD'), 'Ŵ');
		await page.click('#le-undo');
		await page.click('#le-undo');

		// The composer's job: fill the base layer from AZERTY. This loopback server
		// has no registry folder, so the panel says the catalogue list failed.
		await page.click('[data-layer="base"]');
		await tool(page, 'fill');
		// The site's start on Ergopti already asked for the list when the page opened.
		await page.waitForSelector('#le-fill-source');
		assert.equal(await page.locator('#le-fill .le-message.error').count(), 1);
		await page.selectOption('#le-fill-source', 'azerty');
		await page.selectOption('#le-fill-level', 'base');
		await page.click('#le-fill-apply');
		await page.click('#le-confirm-yes');
		assert.equal(await legendOf('KeyQ'), 'a');

		// The navigation layer imports as a layer and exports as layers.toml again.
		await tool(page, 'navigation');
		await page.selectOption('#le-nav-hold', 'CapsLock');
		await page.setInputFiles('#le-nav-file', NAV);
		await page.waitForSelector('[data-layer="nav"].active');
		await tool(page, 'export');
		// (export-format-dropdown) One « Format » drop-down lists every download, with
		// one « Download » button; the viewer's choice survives a redraw and is kept in this browser.
		assert.deepEqual(await exportFormats(page), [
			'toml',
			'macos_bundle',
			'macos_iso',
			'macos_ansi',
			'xkb',
			'klc',
			'dll',
			'kla',
			'kalamine',
			'dof',
			'genkey',
			'cmini',
			'nav'
		]);
		assert.equal(await page.locator('#le-export button[id^="le-export-"]').count(), 1);
		const nav = await downloaded(page, () => exportAs(page, 'nav'));
		assert.equal(
			await page.evaluate(() => localStorage.getItem('ergopti.studio.export_format')),
			'nav'
		);
		await tool(page, 'details');
		await tool(page, 'export');
		assert.equal(await page.inputValue('#le-export-format'), 'nav', 'the choice survives a redraw');
		assert.equal(nav.name, 'layers.toml');
		assert.match(nav.text, /\[layers\.nav\.all\]/);

		// Reopening the saved source restores it.
		const reopened = path.join(require('node:os').tmpdir(), `layout-editor-${process.pid}.toml`);
		fs.writeFileSync(reopened, saved.text);
		await tool(page, 'details');
		try {
			await page.setInputFiles('#le-open-file', reopened);
			await page.waitForFunction(() => document.querySelector('#le-name').value === 'My layout');
		} finally {
			fs.rmSync(reopened);
		}

		// A render that does not move the focus (the locale arriving, a host answer) while a
		// field holds an uncommitted edit: removing the field fires its blur, whose change
		// renders again inside the first render, and the outer replaceChildren once threw
		// « The node to be removed is no longer a child … blur event handler » (CI 43611195865).
		await page.fill('#le-description', 'typed, not yet committed');
		assert.equal(
			await page.evaluate(() => document.activeElement && document.activeElement.id),
			'le-description',
			'the edited field keeps the focus'
		);
		await page.evaluate(() => window.layoutEditor.render());
		assert.deepEqual(errors, [], 'a render while a field is being edited throws nothing');
		assert.equal(
			await page.inputValue('#le-description'),
			'typed, not yet committed',
			'the edit is committed, not lost, by that render'
		);
		// A file opened while a text field holds an uncommitted edit: the edit belongs to
		// the document being replaced, so the opened file keeps its own name (worker G's case).
		await page.fill('#le-name', 'Uncommitted edit');
		await page.setInputFiles('#le-open-file', SOURCE_FIXTURE);
		await page.waitForFunction(() => document.querySelector('#le-name').value === 'Source Fixture');
		assert.deepEqual(errors, [], 'opening a file while a field is being edited throws nothing');

		// The preview types through the web emulation: a tap-hold's tap and a shortcut.
		await page.setInputFiles('#le-open-file', SOURCE_FIXTURE);
		await page.waitForFunction(() => document.querySelector('#le-name').value === 'Source Fixture');
		await page.focus('#le-preview-input');
		await page.keyboard.press('KeyA');
		await page.keyboard.press('Space');
		await page.keyboard.press('Control+KeyA');
		assert.equal(await page.textContent('#le-preview-output'), 'a ⟨control+KeyB⟩');
		assert.deepEqual(errors, []);
		await page.close();

		// Inside the layout manager window, the same editor saves through the host.
		await exerciseManager(browser, origin);
		await exerciseDownloadWithoutLuaVm(browser, origin);
		await exerciseOpensOnErgopti(browser, origin);
		await exerciseStudioNav(browser, origin);
		await exerciseStudioLayout(browser, origin);
		await exerciseCompareEdited(browser, origin);
		await exerciseSiteOpensOnErgopti(browser, origin);
		await exerciseLayerSelector(browser, origin);
		await exercisePhoneWidth(browser, origin);
		await exerciseLongLabels(browser, origin);
		await exerciseShortcuts(browser, origin);
		await exerciseComparerLink(browser, origin);
		await exerciseWorkspace(browser, origin);
		await exerciseAppWorkspace(browser, origin);
		await exerciseHeatmap(browser, origin);

		// Every locale names every visible string.
		for (const lang of LOCALES) {
			const opened = await open(browser, origin, lang);
			await opened.page.click('#le-board [data-code="KeyQ"]');
			for (const summary of await opened.page.$$('#le-inspector details > summary'))
				await summary.click();
			const raw = await rawKeys(opened.page);
			const tools = await opened.page.$$eval('#le-tools [data-tool]', (tabs) =>
				tabs.map((tab) => tab.dataset.tool)
			);
			for (const id of tools) {
				await tool(opened.page, id);
				raw.push(...(await rawKeys(opened.page)));
			}
			await opened.page.click('#le-shortcut-view');
			await opened.page.click('#le-board [data-code="KeyQ"]');
			raw.push(...(await rawKeys(opened.page)));
			assert.deepEqual(raw, [], `${lang}: raw locale keys are shown`);
			assert.deepEqual(opened.errors, [], `${lang}: page errors`);
			await opened.page.close();
		}
		console.log(
			`ok - layout editor page: editing, layer selector, phone width, preview, files and ${LOCALES.length} locales`
		);
	} finally {
		await browser.close();
		server.close();
	}
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
