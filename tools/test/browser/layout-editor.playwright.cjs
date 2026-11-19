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
 * combination through save and reload, keep a corpus the user picked when the
 * app's « Ma frappe » refreshes, and check that no raw locale key is shown in any tool tab of the 21
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
// The UX study's cases (docs/audits/layout-analysers/ux-study.md).
const studioUx = require('./layout-editor-studio-ux.cjs');
// Every number the Studio shows, through its one formatter (studio-numbers).
const studioNumbers = require('./studio-numbers.cjs');
// The ranking's compact headers and their popovers (studio-header-popovers).
const studioHeaders = require('./studio-headers.cjs');
const studioManage = require('./layout-studio-manage.cjs');

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
 * Shows a tab of the Comparer (its tabs lead the page, « Home » first)
 * unless it is shown already.
 * @param {import('playwright').Page} page
 * @param {string} id A TABS id of comparer_page.js.
 */
async function comparerTab(page, id) {
	if ((await page.getAttribute(`#la-tab-${id}`, 'aria-selected')) !== 'true')
		await page.click(`#la-tab-${id}`);
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
		tabs: getComputedStyle(document.querySelector('.studio-bar')).backgroundColor
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
	await page.waitForFunction(
		() =>
			document.querySelectorAll('#la-chart .la-bar').length > 1 &&
			document.getElementById('la-results').getAttribute('aria-busy') === 'false'
	);
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
	assert.match(
		comparer.summary,
		/^\d+\slayouts compared: /,
		'its line counts the compared layouts'
	);
	assert.equal(comparer.widths[0], 100, 'the best layout has the full bar');
	assert.deepEqual(
		comparer.widths,
		[...comparer.widths].sort((a, b) => b - a),
		'the bars shorten from the best to the weakest'
	);
	assert.equal(comparer.zero, 0, 'no zero line');
	// (comparer-incomplete) A layout that cannot type a letter in either case is
	// flagged with what it lacks and ranked after every complete layout, though
	// it scores as Ergopti does (maintainer, 2026-11-17).
	await page.evaluate(() => {
		const ergopti = window.LAYOUT_ANALYSIS.libraryLayouts().find((l) => l.id === 'ergopti');
		const rows = Object.fromEntries(
			Object.entries(ergopti.rows).map(([code, row]) => [
				code,
				row.map((cell) => (cell === 'k' || cell === 'K' ? null : cell))
			])
		);
		window.LAYOUT_ANALYSIS_COMPARER.addLayouts([
			{ id: 'user_ergopti_no_k', name: 'Ergopti without k', rows, dead: ergopti.dead }
		]);
	});
	// The chart draws its 40 best bars: the Ergopti layouts alone bring the
	// incomplete one into it.
	await page.evaluate(() => {
		document.getElementById('la-filters-box').open = true;
	});
	await comparerTab(page, 'overview');
	await page.fill('#la-row-name', 'Ergopti');
	await page.waitForFunction(() => document.querySelector('#la-chart .la-incomplete'));
	const incomplete = await page.evaluate(() => {
		const bars = [...document.querySelectorAll('#la-chart .la-chart-row')];
		const row = [...document.querySelectorAll('#la-table tbody tr')].find((tr) =>
			tr.textContent.includes('Ergopti without k')
		);
		const flags = bars.map((bar) => bar.classList.contains('la-incomplete'));
		return {
			labels: bars.map((bar) => bar.querySelector('.la-chart-label').textContent),
			// The bars of the complete layouts, then those of the incomplete ones.
			ordered: flags.indexOf(true) > flags.lastIndexOf(false),
			ergopti: Number(
				[...document.querySelectorAll('#la-table tbody tr')].find(
					(tr) => tr.cells[1].textContent === 'Ergopti'
				).cells[0].textContent
			),
			rank: Number(row.cells[0].textContent),
			tableFlag: row.querySelector('.la-incomplete-flag').textContent
		};
	});
	assert.ok(
		incomplete.labels.includes('Ergopti without k incomplete: lacks k K'),
		`flagged with what it lacks: ${incomplete.labels.join(' | ')}`
	);
	assert.ok(
		incomplete.ordered,
		`the incomplete layouts come last: ${incomplete.labels.join(' | ')}`
	);
	assert.ok(incomplete.rank > incomplete.ergopti, 'it ranks after Ergopti, which scores the same');
	assert.equal(incomplete.tableFlag, 'incomplete: lacks k K', 'the ranking table says so too');
	// (comparer-text-modes) Three texts to type (maintainer, 2026-11-17): the keys
	// typed, the final text (after hotstrings and AI), or the final text except
	// the layouts ticked « + », which type the keys typed and rank as « name+ ».
	// « My typing » of schema 2 brings both texts; a corpus of one text greys the
	// choice and says why.
	const status = () => page.evaluate(() => document.getElementById('la-status').textContent);
	await page.evaluate(() =>
		document.dispatchEvent(
			new CustomEvent('studio-ngrams', {
				detail: {
					schema: 2,
					source: 'keystats',
					total: 60,
					chars: { e: 20, s: 12, a: 10, n: 8, ' ': 10 },
					bigrams: { es: 6, en: 5, 'e ': 8, ' a': 4 },
					trigrams: { 'es ': 3 },
					final: {
						total: 90,
						chars: { e: 30, s: 18, a: 15, n: 12, ' ': 15 },
						bigrams: { es: 9, en: 7, 'e ': 12, ' a': 6 },
						trigrams: { 'es ': 5 }
					}
				}
			})
		)
	);
	await page.waitForFunction(() =>
		/ on 60\scharacters/.test(document.getElementById('la-status').textContent)
	);
	assert.equal(await page.isDisabled('#la-text-mode'), false, 'two texts: the choice is open');
	assert.equal(await page.inputValue('#la-text-mode'), 'typed', 'the keys typed until chosen');
	await comparerTab(page, 'home');
	await page.selectOption('#la-text-mode', 'final');
	await page.waitForFunction(() =>
		/ on 90\scharacters/.test(document.getElementById('la-status').textContent)
	);
	assert.equal(
		await page.locator('#la-layout-list .la-plus').count(),
		0,
		'no « + » outside its mode'
	);
	await page.selectOption('#la-text-mode', 'mixed');
	// One layout and its « + » twin in the chart, under its 40 bars.
	await comparerTab(page, 'overview');
	await page.fill('#la-row-name', 'QWERTY (US)');
	const before = await page.locator('#la-chart .la-chart-row').count();
	// The layout list is folded under its summary line.
	await comparerTab(page, 'home');
	await page.click('#la-layouts-summary');
	await page
		.locator('#la-layout-list .la-plus', { hasText: /^QWERTY \(US\)\+$/ })
		.locator('input')
		.check();
	await page.waitForFunction(
		(count) => document.querySelectorAll('#la-chart .la-chart-row').length === count + 1,
		before
	);
	const mixed = await page.evaluate(() =>
		[...document.querySelectorAll('#la-table tbody tr')].map((tr) => tr.cells[1].textContent)
	);
	assert.ok(
		mixed.includes('QWERTY (US)') && mixed.includes('QWERTY (US)+'),
		`QWERTY and QWERTY+ in one ranking: ${mixed.join(' | ')}`
	);
	assert.match(await status(), / on 90\scharacters/, 'the others type the final text');
	// A « + » layout's details are measured on the keys typed, like its rank.
	await page.evaluate(() =>
		[...document.querySelectorAll('#la-table tbody tr')]
			.find((tr) => tr.cells[1].textContent === 'QWERTY (US)+')
			.click()
	);
	assert.match(await page.textContent('#la-details-title'), /QWERTY \(US\)\+/);
	// A corpus of one text (« My typing » of schema 1 here, a book's tables
	// alike) greys the choice and the « + » boxes, and says why.
	await page.evaluate(() =>
		document.dispatchEvent(
			new CustomEvent('studio-ngrams', {
				detail: {
					schema: 1,
					source: 'keystats',
					total: 60,
					chars: { e: 20, s: 12, a: 10, n: 8, ' ': 10 },
					bigrams: { es: 6 },
					trigrams: {}
				}
			})
		)
	);
	await page.waitForFunction(
		() =>
			document.getElementById('la-text-mode').disabled &&
			document.getElementById('la-results').getAttribute('aria-busy') === 'false'
	);
	assert.match(
		await page.textContent('#la-text-mode-info'),
		/^This corpus is one text/,
		'the greyed choice says why'
	);
	assert.ok(
		await page.$$eval(
			'#la-layout-list .la-plus input',
			(boxes) => boxes.length > 0 && boxes.every((box) => box.disabled)
		),
		'the « + » boxes are greyed'
	);
	assert.ok(
		!(
			await page.evaluate(() =>
				[...document.querySelectorAll('#la-table tbody tr')].map((tr) => tr.cells[1].textContent)
			)
		).includes('QWERTY (US)+'),
		'one text: no « + » layout is ranked'
	);
	await comparerTab(page, 'overview');
	await page.fill('#la-row-name', '');
	const heading = await page.evaluate(
		() => getComputedStyle(document.querySelector('#studio-comparer')).color
	);
	assert.ok(luminance(heading) > 0.7, `the Comparer's text is light, got ${heading}`);
	// (score-settings-on-home) The optimizer's « Edit in Compare » opens the
	// score settings, which sit in the Comparer's « Home », from any of its tabs.
	await comparerTab(page, 'overview');
	await page.click('#studio-tab-optimize');
	await page.click('#lo-settings-edit');
	assert.equal(await page.isVisible('#la-settings'), true, 'the score settings are shown');
	assert.equal(await page.getAttribute('#la-tab-home', 'aria-selected'), 'true', 'on « Home »');
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
 * (studio-my-typing-refresh) The app answers « Ma frappe » twice: its saved
 * projection as soon as the window opens, before the editor's analysis panel
 * exists, then the fresh read. The first arrival selects « Ma frappe » in the
 * panel and in « Comparer »; the refresh replaces its tables, keeps a corpus
 * the user picked meanwhile and analyses again only while « Ma frappe » is
 * chosen.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseMyTypingRefresh(browser, origin) {
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
	// A saved « mixed » text mode, which a built-in text must neither show nor apply.
	await page.addInitScript(() =>
		window.localStorage.setItem('ergopti.layout_analysis.v1', JSON.stringify({ textMode: 'mixed' }))
	);
	// Each read differs by its character total, which the Comparer reports.
	const typing = (scale) => ({
		schema: 1,
		source: 'keystats',
		total: 60 * scale,
		chars: { e: 20 * scale, s: 12 * scale, a: 10 * scale, n: 8 * scale, ' ': 10 * scale },
		bigrams: { es: 6 * scale, en: 5 * scale, 'e ': 8 * scale, ' a': 4 * scale },
		trigrams: { 'es ': 3 * scale }
	});
	const answer = (ngrams) =>
		page.evaluate((ngrams) => window.keystatsNgrams({ ok: true, ngrams }), ngrams);
	const settle = () =>
		page.evaluate(
			() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
		);
	await page.goto(`${origin}/ui/layout_editor_window/index.html`);
	await page.evaluate(() =>
		window.initData({
			strings: {},
			state: { platform: 'linux' },
			studio_store: true,
			keystats: true
		})
	);
	assert.equal(
		await page.evaluate(() => window.__posted.filter((p) => p.action === 'keystats_ngrams').length),
		1,
		'the window reads « Ma frappe » when it opens'
	);
	// The saved projection arrives before the editor, hence before its panel.
	await answer(typing(1));
	await page.evaluate(
		(text) => window.sourceData({ filename: 'source.toml', text, folder: 'layout_sources/' }),
		fs.readFileSync(SOURCE_FIXTURE, 'utf8')
	);
	await page.waitForSelector('#la-panel-corpus');
	assert.equal(
		await page.inputValue('#la-panel-corpus'),
		'my_typing',
		'the panel selects « Ma frappe » that arrived before it'
	);

	await page.click('#studio-tab-compare');
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'studio_layouts'));
	await page.evaluate(() => {
		const list = window.__posted.find((p) => p.action === 'studio_layouts');
		window.studioLayouts({ request: list.request, ok: true, layouts: [] });
	});
	await page.waitForFunction(
		() =>
			document.querySelectorAll('#la-chart .la-bar').length > 1 &&
			document.getElementById('la-results').getAttribute('aria-busy') === 'false'
	);
	assert.equal(
		await page.inputValue('#la-corpus'),
		'my_typing',
		'the Comparer selects « Ma frappe »'
	);
	await page.evaluate(() => {
		window.__totals = [];
		window.LAYOUT_ANALYSIS_COMPARER.onResults((results, tables) =>
			window.__totals.push(tables.totalChars)
		);
	});
	const totals = () => page.evaluate(() => window.__totals.slice());
	assert.deepEqual(await totals(), [60], 'the saved projection is analysed');

	// The fresh read while « Ma frappe » is chosen: analysed again, still chosen.
	await answer(typing(2));
	await page.waitForFunction(() => window.__totals.length === 2);
	assert.deepEqual(await totals(), [60, 120], 'the fresh read replaces the saved one');
	assert.equal(await page.inputValue('#la-corpus'), 'my_typing');

	// (comparer-text-mode-place) The text typed sits under the corpus picker, on
	// « Ma frappe » only (maintainer, 2026-11-18).
	const textMode = () =>
		page.evaluate(() => {
			const field = document.getElementById('la-text-mode-field');
			const picker = document.getElementById('la-corpus');
			return {
				shown: !field.hidden,
				underPicker:
					field.closest('.la-corpus-card') === picker.closest('.la-corpus-card') &&
					Boolean(picker.compareDocumentPosition(field) & Node.DOCUMENT_POSITION_FOLLOWING),
				plus: document.querySelectorAll('#la-layout-list .la-plus').length,
				saved: JSON.parse(localStorage.getItem('ergopti.layout_analysis.v1')).textMode
			};
		});
	const onMine = await textMode();
	assert.equal(onMine.shown, true, '« Ma frappe » offers the text typed');
	assert.equal(onMine.underPicker, true, 'under the corpus picker, in its card');
	assert.ok(onMine.plus > 0, 'and its « + » layouts in the mixed mode');

	// The user picks a built-in text; a later read keeps it and analyses nothing.
	const builtin = await page.evaluate(
		() => document.querySelector('#la-corpus optgroup:nth-of-type(2) option').value
	);
	await page.selectOption('#la-corpus', builtin);
	assert.deepEqual(
		await textMode(),
		{ shown: false, underPicker: true, plus: 0, saved: 'mixed' },
		'a built-in text hides the text typed and applies none of it, the choice kept'
	);
	await page.waitForFunction(() => window.__posted.some((p) => p.action === 'studio_corpus'));
	await serveCorpora(page);
	await page.waitForFunction(() => window.__totals.length === 3);
	const builtinTotal = (await totals())[2];
	await answer(typing(3));
	await settle();
	assert.equal(await page.inputValue('#la-corpus'), builtin, 'a refresh keeps the user’s corpus');
	assert.deepEqual(await totals(), [60, 120, builtinTotal], 'and analyses nothing on it');
	// « Ma frappe » chosen again is analysed on the newest read.
	await page.selectOption('#la-corpus', 'my_typing');
	await page.waitForFunction(() => window.__totals.length === 4);
	assert.equal((await totals())[3], 180, 'the newest read is the one kept');

	// The same rule in the editor's panel.
	await page.click('#studio-tab-edit');
	const panelBuiltin = await page.evaluate(
		() =>
			[...document.querySelectorAll('#la-panel-corpus option')].find((o) => o.value !== 'my_typing')
				.value
	);
	await page.selectOption('#la-panel-corpus', panelBuiltin);
	await answer(typing(4));
	await settle();
	assert.equal(
		await page.inputValue('#la-panel-corpus'),
		panelBuiltin,
		'a refresh keeps the corpus picked in the panel'
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
	// The library grows (649 layouts on 2026-11-19): every match, and no other.
	const found = await page.$$eval('#le-start-layout option', (options) =>
		options.map((option) => option.textContent)
	);
	assert.ok(
		found.includes('Colemak-DH') && found.length < names.length,
		`the search narrows the list: ${found.join(' | ')}`
	);
	assert.deepEqual(
		found.filter((name) => !/colemak[- ]?dh/i.test(name)),
		[],
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
	assert.equal(await page.inputValue('#le-name'), 'My layout (based on Colemak-DH)');
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
/**
 * (comparer-sub-tabs) The results are sub-tabs (maintainer, 2026-11-18): the
 * arrows move between the tabs, one panel shows at a time, each themed tab
 * charts its metrics (one named chart each, read as a table) with a sortable
 * table, fingers and hands hold the finger load against the ideal and the
 * hand balance, trigrams and rows their stacked figures with a legend and a
 * table, the heat maps one board per layout shown, the other analysers their
 * ranks, and the filters (origin, completeness) narrow every figure.
 * @param {import('playwright').Page} page The Comparer on its overview.
 */
async function exerciseComparerTabs(page) {
	const results = await page.locator('#la-table tbody tr').count();
	const visiblePanels = () =>
		page.$$eval('.la-tab-panel', (panels) => panels.filter((p) => !p.hidden).map((p) => p.id));
	await page.focus('#la-tab-overview');
	await page.keyboard.press('ArrowRight');
	assert.deepEqual(await visiblePanels(), ['la-panel-fingers'], 'the arrow shows the next tab');
	assert.equal(
		await page.evaluate(() => document.activeElement.id),
		'la-tab-fingers',
		'and moves the focus to it'
	);
	assert.equal(await page.getAttribute('#la-tab-fingers', 'aria-selected'), 'true');
	// Fingers and hands: the ideal row, then one row per layout; a gap never reads « -0.0 ».
	assert.equal(await page.locator('#la-finger-table tbody tr').count(), results + 1);
	assert.ok(
		await page.$$eval('#la-finger-table .la-gap', (gaps) =>
			gaps.every((gap) => /^(\+|−|-)?\d/.test(gap.textContent) && gap.textContent !== '-0.0')
		),
		'every finger writes its gap to the ideal'
	);
	// A chart draws its 40 best bars (CHART_MAX_BARS), the table every layout.
	const bars = Math.min(results, 40);
	assert.equal(await page.locator('#la-hands .la-chart-row').count(), bars, 'a hand bar each');
	assert.equal(await page.locator('#la-hands-legend li').count(), 2, 'left and right named');
	// Each themed tab: one named chart per metric, read as a table, and the sortable table.
	for (const [tab, charts] of [
		['fingers', 3],
		// sfb_distance and pinky_ring joined the bigrams with the score floors.
		['bigrams', 12],
		['trigrams', 5],
		['rows', 6],
		['misc', 11]
	]) {
		await page.click(`#la-tab-${tab}`);
		const figures = await page.$$eval(`#la-charts-${tab} .la-figure`, (sections) =>
			sections.map((section) => ({
				id: section.getAttribute('aria-labelledby'),
				named: Boolean(
					document.getElementById(section.getAttribute('aria-labelledby'))?.textContent
				),
				table: section.querySelector('[role="table"], table') !== null
			}))
		);
		assert.equal(figures.length, charts + 1, `${tab}: ${charts} charts and a table`);
		assert.ok(
			figures.every((f) => f.named && f.table),
			`${tab}: every chart named, a table to AT: ${JSON.stringify(figures)}`
		);
		assert.equal(
			await page.locator(`#la-table-${tab} tbody tr`).count(),
			results,
			`${tab}: a table row per layout`
		);
	}
	// A metric column sorts its better value first, and says so in aria-sort.
	await page.click('#la-tab-bigrams');
	await page.click('#la-table-bigrams thead button[data-sort="sfb"]');
	// The value is the cell's first text; its percentile chip (« P70 ») follows it.
	const sfb = await page.$$eval('#la-table-bigrams tbody tr td:nth-child(4)', (cells) =>
		cells.map((cell) => Number(cell.firstChild.textContent.replace(/[^\d.]/g, '')))
	);
	assert.ok(
		sfb.every((v, i) => i === 0 || sfb[i - 1] <= v),
		`SFB sorted lowest first: ${sfb}`
	);
	assert.equal(
		await page.evaluate(() => document.activeElement.dataset.sort),
		'sfb',
		'the focus stays on the sorted header'
	);
	// Stacked figures: a legend entry per part and the values as a table.
	await page.click('#la-tab-trigrams');
	assert.equal(await page.locator('#la-trigram-mix .la-legend li').count(), 6, 'six classes');
	assert.equal(await page.locator('#la-table-trigram_mix tbody tr').count(), results);
	await page.click('#la-tab-rows');
	assert.equal(await page.locator('#la-row-mix .la-legend li').count(), 4, 'four rows');
	assert.equal(await page.locator('#la-travel-table tbody tr').count(), results);
	// Heat maps: a board per layout shown, up to the count chosen, each with its table.
	await page.click('#la-tab-heatmaps');
	await page.selectOption('#la-heats-count', '2');
	assert.equal(await page.locator('#la-heats .la-heat-card').count(), Math.min(2, results));
	assert.equal(
		await page.locator('#la-heats .la-heat-card').first().locator('table tbody tr').count(),
		await page.locator('#la-heats .la-heat-card').first().locator('.la-key').count(),
		'a board has its table'
	);
	await page.selectOption('#la-heats-metric', 'sfb');
	await page.uncheck('#la-heats-shared');
	assert.equal(
		await page.locator('#la-heats .la-heat-card .la-heat-legend').count(),
		Math.min(2, results),
		'each board its own scale'
	);
	await page.check('#la-heats-shared');
	await page.selectOption('#la-heats-count', '6');
	// The other analysers: their ranks, one blue ramp, the rank written.
	await page.click('#la-tab-analysers');
	await page.waitForFunction(
		() => !/…/.test(document.querySelector('.la-analysers-table tbody')?.textContent || '…'),
		null,
		{ timeout: 60000 }
	);
	// The whole library is compared: the analysers score its 40 best and say so.
	assert.equal(
		await page.locator('.la-analysers-table tbody tr').count(),
		Math.min(results, 40),
		'the other analysers score the 40 best layouts'
	);
	if (results > 40)
		assert.match(
			await page.textContent('#la-panel-analysers'),
			new RegExp(`Shows the 40\\sbest of the ranking's ${results}\\slayouts`),
			'and say so'
		);
	await page.selectOption('#la-analysers-view', 'ranks');
	assert.ok(
		await page.$$eval(
			'.la-analysers-table td.la-cell-rank',
			(cells) => cells.length > 0 && cells.every((cell) => /^\d+$/.test(cell.textContent))
		),
		'each analyser ranks the layouts'
	);
	await page.selectOption('#la-analysers-view', 'scores');
	// The filters narrow every figure: an origin, then the complete layouts only.
	await page.click('#la-tab-bigrams');
	await page.selectOption('#la-row-origin', 'registry');
	const registry = await page.locator('#la-table tbody tr').count();
	assert.ok(registry > 0 && registry < results, `the origin filter keeps ${registry}`);
	assert.equal(await page.locator('#la-table-bigrams tbody tr').count(), registry);
	await page.selectOption('#la-row-origin', '');
	await page.selectOption('#la-row-complete', 'no');
	assert.ok(
		await page.$$eval('#la-table tbody tr', (rows) =>
			rows.every((row) => row.querySelector('.la-incomplete-flag'))
		),
		'the incomplete layouts only'
	);
	await page.selectOption('#la-row-complete', 'all');
	await page.click('#la-tab-overview');
	assert.ok(
		(await page.locator('#la-leaders .la-leader').count()) >= 2,
		'the overview names the best layouts'
	);
}

/**
 * (comparer-whole-library) With nothing saved, the Comparer ticks every layout
 * it lists (maintainer, 2026-11-18), the other board's twin of a family
 * excepted, and scores them by slices, yielding to the page between them, so
 * the page answers while the library is scored; a saved selection stays.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseComparerWholeLibrary(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	// Every text the status line shows, in order.
	await page.addInitScript(() => {
		window.__statuses = [];
		new MutationObserver(() => {
			const status = document.getElementById('la-status');
			const text = status ? status.textContent : '';
			if (text && window.__statuses[window.__statuses.length - 1] !== text)
				window.__statuses.push(text);
		}).observe(document, { childList: true, subtree: true, characterData: true });
	});
	await page.goto(`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier`);
	await page.waitForFunction(() =>
		/\slayouts compared on /.test(document.getElementById('la-status').textContent)
	);
	const ticks = await page.evaluate(() => {
		const library = window.LAYOUT_ANALYSIS.libraryLayouts();
		const boxes = [...document.querySelectorAll('#la-layout-list .la-layout')].map((label) => ({
			name: label.textContent,
			checked: label.querySelector('input').checked
		}));
		return {
			library: library.length,
			listed: boxes.length,
			checked: boxes.filter((box) => box.checked).length,
			unchecked: boxes.filter((box) => !box.checked).map((box) => box.name)
		};
	});
	assert.equal(ticks.listed, ticks.library, 'the list holds the whole library');
	assert.ok(
		ticks.unchecked.every((name) => /ANSI|ISO|JIS|ABNT/.test(name)),
		`only the other board's twins stay unticked: ${ticks.unchecked.join(' | ')}`
	);
	assert.ok(
		ticks.checked >= ticks.library - ticks.unchecked.length && ticks.checked > 100,
		`the whole library is ticked: ${ticks.checked} of ${ticks.library}`
	);
	const statuses = await page.evaluate(() => window.__statuses.slice());
	const ready = statuses.findIndex((text) => /\slayouts compared on /.test(text));
	const slices = statuses
		.slice(0, ready)
		.filter((text) => /^Scoring the layouts: \d+\sof \d+…$/.test(text));
	assert.ok(
		slices.length >= Math.floor(ticks.checked / 4) - 1,
		`the page is given a turn between slices: ${slices.length} of ${statuses.join(' | ')}`
	);
	assert.match(
		statuses[ready],
		new RegExp(`^${ticks.checked}\\slayouts compared on `),
		'every ticked layout is ranked'
	);
	assert.equal(
		await page.getAttribute('#la-results', 'aria-busy'),
		'false',
		'the results are no longer busy once every slice is scored'
	);
	// A saved selection stays the user's.
	await comparerTab(page, 'home');
	await page.click('#la-layouts-summary');
	await page.click('#la-none');
	await page
		.locator('#la-layout-list .la-layout', { hasText: /^Ergopti$/ })
		.locator('input')
		.check();
	await page.reload();
	await page.waitForFunction(() =>
		/\slayouts compared on /.test(document.getElementById('la-status').textContent)
	);
	assert.match(
		await page.textContent('#la-status'),
		/^1\slayouts compared on /,
		'a saved selection is kept'
	);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (comparer-layout-list) The layout list is one alphabetical column under a
 * heading per first letter, with a letter index that jumps there; the search
 * reads the name, the authors and the family without accents and says how
 * many it shows; « Select all shown » ticks only what the search shows, and
 * « Untick every layout » clears the whole selection (maintainer, 2026-11-18).
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseComparerLayoutList(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier`);
	await page.waitForFunction(
		() => document.getElementById('la-results').getAttribute('aria-busy') === 'false'
	);
	await comparerTab(page, 'home');
	await page.click('#la-layouts-summary');
	// (layout-search-height) The search is one line high, not stretched by its row.
	const search = await page.locator('#la-filter').boundingBox();
	assert.ok(search.height < 60, `the search is ${search.height} px tall`);
	const fold = (text) => text.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
	const list = () =>
		page.$$eval('#la-layout-list .la-letter-group', (groups) =>
			groups.map((group) => ({
				letter: group.querySelector('h3.la-letter').textContent,
				labelled: group.getAttribute('aria-labelledby') === group.querySelector('h3').id,
				names: [...group.querySelectorAll('.la-layout-name')].map((n) => n.textContent),
				lefts: [...group.querySelectorAll('.la-layout-item')].map(
					(item) => item.getBoundingClientRect().left
				)
			}))
		);
	const count = () => page.textContent('#la-pick-count');
	const all = await list();
	assert.ok(all.length > 10, `a heading per first letter: ${all.map((g) => g.letter).join(' ')}`);
	assert.ok(
		all.every((g) => g.labelled),
		'each letter group is named by its heading'
	);
	const letters = all.map((g) => g.letter);
	assert.deepEqual(letters, [...new Set(letters)], 'each letter once');
	for (const group of all)
		for (const name of group.names)
			assert.ok(
				group.letter === '#' || fold(name).startsWith(group.letter.toLowerCase()),
				`${name} is listed under ${group.letter}`
			);
	const names = all.flatMap((g) => g.names);
	assert.deepEqual(
		names,
		[...names].sort((a, b) => fold(a).localeCompare(fold(b))),
		'in alphabetical order'
	);
	assert.equal(
		new Set(all.flatMap((g) => g.lefts)).size,
		1,
		'one column: every layout starts at the same left edge'
	);
	assert.equal(
		await page.getAttribute('#la-pick-count', 'role'),
		'status',
		'the count is announced'
	);
	// The letter index jumps to its heading and gives the focus to its first layout.
	const jumps = await page.$$eval('#la-letters a', (links) => links.map((a) => a.textContent));
	assert.deepEqual(jumps, letters, 'the index names every letter heading');
	assert.ok(
		(await page.getAttribute('#la-letters', 'aria-label')).length > 0,
		'the index is a named navigation'
	);
	await page.click('#la-letters a:text-is("E")');
	assert.equal(
		await page.evaluate(
			() => document.activeElement.closest('.la-letter-group').querySelector('h3').textContent
		),
		'E',
		'« E » moves the focus to the first layout under E'
	);
	// The search: accents do not matter, and the authors and family are read too.
	await page.fill('#la-filter', 'bepo');
	const bepo = (await list()).flatMap((g) => g.names);
	assert.ok(bepo.includes('bépo'), `« bepo » finds « bépo »: ${bepo.join(' | ')}`);
	assert.match(await count(), new RegExp(`^${bepo.length}\\sof \\d+\\sshown, \\d+\\sticked$`));
	const byAuthor = await page.evaluate(() => {
		const layout = window.LAYOUT_ANALYSIS.libraryLayouts().find(
			(l) =>
				Array.isArray(l.authors) &&
				l.authors.length > 0 &&
				!l.name.toLowerCase().includes(l.authors[0].toLowerCase())
		);
		return { name: layout.name, author: layout.authors[0] };
	});
	await page.fill('#la-filter', byAuthor.author);
	assert.ok(
		(await list()).flatMap((g) => g.names).includes(byAuthor.name),
		`the author ${byAuthor.author} finds ${byAuthor.name}`
	);
	// Select the shown layouts only.
	await page.fill('#la-filter', '');
	await page.click('#la-clear');
	assert.match(await count(), / 0\sticked$/, 'every layout unticked');
	await page.fill('#la-filter', 'colemak');
	const shown = (await list()).flatMap((g) => g.names);
	assert.ok(shown.length > 1, `« colemak » shows the family: ${shown.join(' | ')}`);
	await page.click('#la-all');
	assert.match(
		await count(),
		new RegExp(`^${shown.length}\\sof \\d+\\sshown, ${shown.length}\\sticked$`),
		'« Select all shown » ticks the shown layouts'
	);
	await page.fill('#la-filter', '');
	assert.equal(
		await page.locator('#la-layout-list .la-picked').count(),
		shown.length,
		'and those only, each marked as ticked'
	);
	await page.click('#la-every');
	assert.equal(
		await page.locator('#la-layout-list .la-picked').count(),
		await page.locator('#la-layout-list .la-layout-item').count(),
		'« Tick every layout » ticks them all'
	);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (comparer-home-tab) The Comparer's tabs lead the page, « Home » first: it
 * holds the corpus, the layout list and the score settings, and a fresh visit
 * opens it, while a link to a comparison opens its ranking (maintainer,
 * 2026-11-18). The ARIA tabs pattern holds, in light and dark and in every
 * locale.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseComparerHome(browser, origin) {
	for (const colorScheme of ['light', 'dark']) {
		const context = await browser.newContext({
			viewport: { width: 1280, height: 900 },
			colorScheme
		});
		const page = await context.newPage();
		const errors = [];
		page.on('pageerror', (error) => errors.push(error.message));
		await page.goto(`${origin}/ui/layout_analysis/index.html?lang=en`);
		await page.waitForFunction(
			() => document.getElementById('la-results').getAttribute('aria-busy') === 'false'
		);
		const layout = await page.evaluate(() => {
			const tabs = document.getElementById('la-tabs');
			const home = document.getElementById('la-panel-home');
			const before = (a, b) =>
				Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
			return {
				role: tabs.getAttribute('role'),
				first: tabs.querySelector('[role="tab"]').id,
				selected: [...tabs.querySelectorAll('[role="tab"]')]
					.filter((tab) => tab.getAttribute('aria-selected') === 'true')
					.map((tab) => tab.id),
				shown: [...document.querySelectorAll('.la-tab-panel')]
					.filter((panel) => !panel.hidden)
					.map((panel) => panel.id),
				tabsFirst: before(tabs, document.getElementById('la-corpus')),
				onTop: tabs.getBoundingClientRect().top < home.getBoundingClientRect().top,
				holds: ['la-corpus', 'la-layouts-box', 'la-settings'].every((id) =>
					home.contains(document.getElementById(id))
				),
				filters: document.getElementById('la-filters-box').hidden,
				panelRole: home.getAttribute('role'),
				labelled: home.getAttribute('aria-labelledby')
			};
		});
		assert.deepEqual(
			layout,
			{
				role: 'tablist',
				first: 'la-tab-home',
				selected: ['la-tab-home'],
				shown: ['la-panel-home'],
				tabsFirst: true,
				onTop: true,
				holds: true,
				filters: true,
				panelRole: 'tabpanel',
				labelled: 'la-tab-home'
			},
			`${colorScheme}: « Home » first, open on a fresh visit, holding the setup`
		);
		// (comparer-tab-icons) Each tab shows a decorative icon in its accent; its
		// text stays its name; the chosen tab is marked by a bar and weight, not
		// colour alone; icons hold 3:1 and labels 4.5:1 on their background.
		const tabs = await page.$$eval('#la-tabs [role="tab"]', (list) => {
			const rgb = (text) => (text.match(/[\d.]+/g) || []).slice(0, 4).map(Number);
			const luminance = ([r, g, b]) => {
				const lin = (c) => {
					const v = c / 255;
					return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
				};
				return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
			};
			const contrast = (a, b) => {
				const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m);
				return (x + 0.05) / (y + 0.05);
			};
			// The first opaque background behind a node.
			const backdrop = (node) => {
				for (let at = node; at; at = at.parentElement) {
					const colour = rgb(getComputedStyle(at).backgroundColor);
					if (colour.length >= 3 && (colour.length === 3 || colour[3] > 0.5)) return colour;
				}
				return [255, 255, 255];
			};
			return list.map((tab) => {
				const icon = tab.querySelector('svg.la-tab-icon');
				const style = getComputedStyle(tab);
				const back = backdrop(tab);
				return {
					id: tab.id,
					icon: Boolean(icon),
					hidden: icon ? icon.getAttribute('aria-hidden') === 'true' : false,
					focusable: icon ? icon.getAttribute('focusable') : null,
					name: tab.textContent.trim(),
					label: tab.querySelector('.la-tab-label')?.textContent.trim(),
					selected: tab.getAttribute('aria-selected') === 'true',
					bar: parseFloat(style.borderBottomWidth),
					barColour: style.borderBottomColor,
					weight: Number(style.fontWeight),
					iconContrast: icon ? contrast(rgb(getComputedStyle(icon).stroke), back) : 0,
					textContrast: contrast(rgb(style.color), back)
				};
			});
		});
		for (const tab of tabs) {
			assert.ok(tab.icon && tab.hidden && tab.focusable === 'false', `${tab.id}: a hidden icon`);
			assert.ok(tab.name && tab.name === tab.label, `${tab.id}: named by its text (${tab.name})`);
			assert.ok(tab.iconContrast >= 3, `${colorScheme} ${tab.id}: icon ${tab.iconContrast}`);
			assert.ok(tab.textContrast >= 4.5, `${colorScheme} ${tab.id}: text ${tab.textContrast}`);
		}
		const chosen = tabs.find((tab) => tab.selected);
		const others = tabs.filter((tab) => !tab.selected);
		assert.ok(
			others.every(
				(tab) => chosen.weight > tab.weight && !/rgba\(0, 0, 0, 0\)/.test(chosen.barColour)
			),
			`${colorScheme}: the chosen tab is heavier and barred, not only coloured`
		);
		assert.ok(chosen.bar >= 3, 'a bar of 3 px at least');
		assert.ok(
			(
				await page.$$eval('#la-tabs .la-tab-icon', (icons) => [
					...new Set(icons.map((icon) => getComputedStyle(icon).stroke))
				])
			).length >= 5,
			'the tabs carry several accents'
		);
		// The arrows move to the results and back, the focus following.
		await page.focus('#la-tab-home');
		await page.keyboard.press('ArrowRight');
		assert.equal(await page.evaluate(() => document.activeElement.id), 'la-tab-overview');
		assert.equal(await page.isHidden('#la-panel-home'), true, 'the ranking replaces « Home »');
		assert.equal(await page.isVisible('#la-filters-box'), true, 'with the results’ filters');
		await page.keyboard.press('Home');
		assert.equal(await page.evaluate(() => document.activeElement.id), 'la-tab-home');
		assert.deepEqual(errors, [], `${colorScheme}: page errors`);
		await context.close();
	}
	// A link to a comparison opens its ranking.
	const page = await browser.newPage();
	await page.goto(`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier`);
	await page.waitForSelector('#la-tab-overview[aria-selected="true"]');
	assert.equal(await page.isHidden('#la-panel-home'), true, 'a link opens the ranking');
	// Every locale names « Home ».
	for (const lang of LOCALES) {
		await page.goto(`${origin}/ui/layout_analysis/index.html?lang=${lang}&corpus=fr_nemolivier`);
		await page.waitForSelector('#la-tab-home');
		await page.waitForFunction(
			() =>
				!document.getElementById('la-tab-home').textContent.includes('layout_analysis.') &&
				document.getElementById('la-results').getAttribute('aria-busy') === 'false'
		);
		// (layout-count-locale) The layout list's count follows the strings that land.
		const count = await page.textContent('#la-pick-count');
		assert.ok(!count.includes('layout_analysis.'), `${lang}: the layout count reads ${count}`);
		const label = (await page.textContent('#la-tab-home')).trim();
		assert.ok(
			label !== '' && !label.startsWith('layout_analysis.'),
			`${lang}: « Home » is ${label}`
		);
	}
	await page.close();
}

/**
 * (studio-menu-bar) The Studio window's menu bar: « Ergopti Studio » and its
 * mark on the left, then the tabs, each with a hidden icon in its mark and
 * named by its text, the chosen one marked by more than colour, the arrows
 * moving between them, and nothing hidden or scrolled sideways at 320 px, in
 * light and dark (maintainer, 2026-11-18).
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseStudioBar(browser, origin) {
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	for (const colorScheme of ['light', 'dark']) {
		const context = await browser.newContext({
			viewport: { width: 1280, height: 800 },
			colorScheme
		});
		const page = await context.newPage();
		const errors = [];
		page.on('pageerror', (error) => errors.push(error.message));
		await page.addInitScript((strings) => {
			window._i18n_strings = strings;
			window.webkit = {
				messageHandlers: { layout_editor_window_bridge: { postMessage: () => {} } }
			};
		}, strings);
		await page.goto(`${origin}/ui/layout_editor_window/index.html`);
		await page.evaluate(() =>
			window.initData({ strings: {}, state: { platform: 'linux' }, studio_store: true })
		);
		await page.waitForSelector('#studio-tab-edit span:not(:empty)');
		const bar = await page.evaluate(() => {
			const rgb = (text) => (text.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
			const luminance = ([r, g, b]) => {
				const lin = (c) => {
					const v = c / 255;
					return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
				};
				return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
			};
			const contrast = (a, b) => {
				const [x, y] = [luminance(a), luminance(b)].sort((m, n) => n - m);
				return (x + 0.05) / (y + 0.05);
			};
			const back = rgb(getComputedStyle(document.querySelector('.studio-bar')).backgroundColor);
			const brand = document.querySelector('.studio-brand');
			const list = document.querySelector('.studio-tabs');
			return {
				brand: brand.textContent.trim(),
				logo: brand.querySelector('svg').getAttribute('aria-hidden'),
				brandLeft: brand.getBoundingClientRect().right <= list.getBoundingClientRect().left,
				listName: document.getElementById(list.getAttribute('aria-labelledby')).textContent,
				tabs: [...list.querySelectorAll('[role="tab"]')].map((tab) => {
					const icon = tab.querySelector('svg');
					const style = getComputedStyle(tab);
					return {
						id: tab.id,
						name: tab.textContent.trim(),
						hidden: icon && icon.getAttribute('aria-hidden') === 'true',
						controls: Boolean(document.getElementById(tab.getAttribute('aria-controls'))),
						tabIndex: tab.tabIndex,
						selected: tab.getAttribute('aria-selected') === 'true',
						weight: Number(style.fontWeight),
						shadow: style.boxShadow,
						icon: icon ? contrast(rgb(getComputedStyle(icon).stroke), back) : 0,
						text: contrast(rgb(style.color), back)
					};
				})
			};
		});
		assert.equal(bar.brand, 'Ergopti Studio', 'the bar names the Studio');
		assert.equal(bar.logo, 'true', 'its mark is decorative');
		assert.ok(bar.brandLeft, 'the name sits left of the tabs');
		assert.equal(bar.listName, 'Ergopti Studio', 'the tab list is named');
		assert.deepEqual(
			bar.tabs.map((tab) => [tab.id, tab.name, tab.hidden, tab.controls]),
			[
				['studio-tab-edit', 'Edit', true, true],
				['studio-tab-compare', 'Compare', true, true],
				['studio-tab-optimize', 'Optimize', true, true]
			],
			'three tabs, each with a hidden icon, named by its text, controlling its panel'
		);
		for (const tab of bar.tabs) {
			assert.ok(tab.icon >= 3, `${colorScheme} ${tab.id}: icon ${tab.icon}`);
			assert.ok(tab.text >= 4.5, `${colorScheme} ${tab.id}: text ${tab.text}`);
		}
		const [chosen, ...others] = bar.tabs;
		assert.ok(chosen.selected && chosen.tabIndex === 0, 'the chosen tab takes the focus');
		assert.ok(
			others.every((tab) => tab.tabIndex === -1 && tab.weight < chosen.weight),
			'the others leave the Tab order and are lighter'
		);
		assert.match(chosen.shadow, /inset/, 'the chosen tab has its bar');
		await page.focus('#studio-tab-edit');
		await page.keyboard.press('ArrowRight');
		assert.equal(await page.evaluate(() => document.activeElement.id), 'studio-tab-compare');
		assert.equal(await page.getAttribute('#studio-tab-compare', 'aria-selected'), 'true');
		assert.equal(await page.isVisible('#studio-comparer'), true, 'the arrow opens its panel');
		await page.keyboard.press('End');
		assert.equal(await page.evaluate(() => document.activeElement.id), 'studio-tab-optimize');
		await page.keyboard.press('Home');
		assert.equal(await page.evaluate(() => document.activeElement.id), 'studio-tab-edit');
		// 320 px: the tabs wrap under the name, none hidden, no sideways scroll.
		await page.setViewportSize({ width: 320, height: 640 });
		const narrow = await page.evaluate(() => ({
			scroll: document.documentElement.scrollWidth,
			inside: [...document.querySelectorAll('.studio-tabs [role="tab"]')].every((tab) => {
				const box = tab.getBoundingClientRect();
				return box.width > 0 && box.left >= 0 && box.right <= 320;
			})
		}));
		assert.deepEqual(narrow, { scroll: 320, inside: true }, `${colorScheme}: the bar fits 320 px`);
		assert.deepEqual(errors, [], `${colorScheme}: page errors`);
		await context.close();
	}
}

/**
 * (comparer-corpus-picker) One corpus picker: the user's own texts, then one
 * group per language with each entry's kind, code last; it is driven by the
 * keyboard, and the text typed is not offered on a built-in text. (comparer-phone-width) Every sub-tab fits a phone in
 * light and dark without a sideways page scroll.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 */
async function exerciseComparerPicker(browser, origin) {
	for (const colorScheme of ['light', 'dark']) {
		const context = await browser.newContext({
			viewport: { width: 375, height: 812 },
			colorScheme
		});
		const page = await context.newPage();
		const errors = [];
		page.on('pageerror', (error) => errors.push(error.message));
		await page.goto(`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier`);
		await page.waitForFunction(
			() =>
				document.querySelectorAll('#la-table tbody tr').length > 0 &&
				document.getElementById('la-results').getAttribute('aria-busy') === 'false'
		);
		if (colorScheme === 'light') {
			// One picker (maintainer, 2026-11-18): no language or kind filter beside it.
			assert.equal(
				await page.locator('#la-corpus-language, #la-corpus-kind').count(),
				0,
				'no filter repeats the picker'
			);
			const groups = await page.$$eval('#la-corpus optgroup', (list) =>
				list.map((g) => ({
					label: g.label,
					options: [...g.children].map((o) => ({ id: o.value, text: o.textContent }))
				}))
			);
			const labels = groups.map((g) => g.label);
			assert.deepEqual(
				labels,
				['On this PC', 'French', 'English', 'German', 'Italian', 'Spanish', 'Source code'],
				'the user’s texts, then one group per language, most texts first, code last'
			);
			assert.deepEqual(
				groups[0].options.map((o) => o.id),
				['custom'],
				'the user’s own text first'
			);
			const builtins = await page.evaluate(() => window.LAYOUT_ANALYSIS_DATA.corpora.length);
			const listed = groups.slice(1).flatMap((g) => g.options);
			assert.equal(listed.length, builtins, `every built-in text is listed (${builtins})`);
			assert.equal(
				await page.locator('#la-corpus > option').count(),
				0,
				'every entry sits in a group'
			);
			for (const group of groups.slice(1, -1))
				for (const option of group.options)
					assert.match(
						option.text,
						/ · (Books|Encyclopedia|News|Everyday sentences|Word lists)$/,
						`${group.label}: ${option.text} says its kind`
					);
			// The keyboard path: the picker takes the focus and an arrow moves the choice.
			await comparerTab(page, 'home');
			await page.focus('#la-corpus');
			const before = await page.inputValue('#la-corpus');
			await page.keyboard.press('ArrowDown');
			const after = await page.inputValue('#la-corpus');
			assert.notEqual(after, before, 'an arrow key chooses the next corpus');
			await page.waitForFunction(
				(id) => JSON.parse(localStorage.getItem('ergopti.layout_analysis.v1')).corpus === id,
				after
			);
			await page.keyboard.press('ArrowUp');
			assert.equal(await page.inputValue('#la-corpus'), before, 'and back');
			// The text typed means something on « Ma frappe » only: hidden on a book.
			assert.equal(
				await page.isHidden('#la-text-mode-field'),
				true,
				'no « text typed » choice on a built-in text'
			);
			assert.equal(
				await page.evaluate(() => document.getElementById('la-filters-box').open),
				false,
				'a phone folds the filters'
			);
		}
		for (const tab of await page.$$eval('#la-tabs [role="tab"]', (tabs) => tabs.map((t) => t.id))) {
			await page.click(`#${tab}`);
			assert.equal(
				await page.evaluate(() => document.documentElement.scrollWidth),
				375,
				`${colorScheme}: ${tab} fits the phone`
			);
		}
		assert.deepEqual(errors, [], `comparer at phone width (${colorScheme})`);
		await context.close();
	}
}

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
	await page.waitForFunction(
		() =>
			document.querySelectorAll('#la-table tbody tr').length > 0 &&
			document.getElementById('la-results').getAttribute('aria-busy') === 'false'
	);
	// English strings: the comparer reports its analysis, not a failure.
	assert.match(
		await page.evaluate(() => document.getElementById('la-status').textContent),
		/^\d+\slayouts compared on [\d,]+\scharacters/
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
	await comparerTab(page, 'home');
	await page.selectOption('#la-keyboard', 'ansi');
	assert.deepEqual(
		await ticks(),
		{ Ergopti: false, 'Ergopti+': false, 'Ergopti ANSI': true, 'Ergopti+ ANSI': true },
		'ANSI ticks their ANSI versions'
	);
	await comparerTab(page, 'home');
	await page.selectOption('#la-keyboard', 'iso');
	await page.waitForFunction(
		() =>
			document.querySelectorAll('#la-table tbody tr').length > 0 &&
			document.getElementById('la-results').getAttribute('aria-busy') === 'false'
	);
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
	// partners from the engine's worst groups. A row opened « One layout »,
	// whose own list picks the first of the ranking.
	assert.equal(await page.isVisible('#la-panel-details'), true, 'a row opens « One layout »');
	assert.equal(await page.isVisible('#la-panel-overview'), false, 'one panel at a time');
	await page.selectOption(
		'#la-details-layout',
		await page.$eval('#la-details-layout option', (option) => option.value)
	);
	await page.selectOption('#la-heat-metric', 'sfb');
	assert.ok(
		await page.$$eval('#la-heatmap .la-key', (keys) =>
			keys.some((key) => /: [\d.,]+\s?% — .+ [\d.,]+\s?%/.test(key.title))
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
			keys.some((key) => / — .+ [\d.,]+\s?%/.test(key.title))
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
	assert.match(await page.textContent('#la-worst tbody tr td:nth-child(3)'), /^[\d.,]+\s?%$/);
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
	assert.match(cells[0], /: [\d.,]+\s?% .+\(\d[\d,]*\s.+\), .+, [+−-]?[\d.,]+\s/);
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
	assert.match(await page.textContent('#la-words-mean'), /[\d.,]+\spoints over [\d,]+\swords/);
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
			keys.every((key) => / \+[\d.,]+(\s|%)/.test(key.title))
		),
		'a key with more is signed +'
	);
	await page.uncheck('#la-heat-diff');
	// (comparer-table-options) The ranking table's columns and rows are the
	// viewer's: a metric added, a name filter, both kept for the next visit.
	await page.click('#la-tab-overview');
	await exerciseComparerTabs(page);
	await page.click('#la-table-options > summary');
	const columnsBefore = await page.locator('#la-table thead th').count();
	await page.check('#la-column-list input[value="pinky_load"]');
	assert.equal(
		await page.locator('#la-table thead th').count(),
		columnsBefore + 1,
		'a column added'
	);
	const rowsBefore = await page.locator('#la-table tbody tr').count();
	await comparerTab(page, 'overview');
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
	await comparerTab(page, 'home');
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
	await comparerTab(page, 'home');
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
	assert.equal(
		inputs.length,
		4,
		'a corpus file, a layout file, a fingering profile and the score settings'
	);
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
	assert.equal(await page.inputValue('#le-name'), 'My layout (based on Ergopti)');
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
	assert.match(await crashed.textContent('#le-message'), /3\slayouts imported/);
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
		await page.waitForFunction(
			() =>
				document.querySelectorAll('#la-table tbody tr').length > 0 &&
				document.getElementById('la-results').getAttribute('aria-busy') === 'false'
		);
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
	await comparerTab(page, 'home');
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
		await exerciseMyTypingRefresh(browser, origin);
		await exerciseSiteOpensOnErgopti(browser, origin);
		await exerciseLayerSelector(browser, origin);
		await exercisePhoneWidth(browser, origin);
		await exerciseLongLabels(browser, origin);
		await exerciseShortcuts(browser, origin);
		await exerciseComparerLink(browser, origin);
		await exerciseComparerPicker(browser, origin);
		await exerciseComparerWholeLibrary(browser, origin);
		await exerciseComparerLayoutList(browser, origin);
		await exerciseComparerHome(browser, origin);
		await exerciseStudioBar(browser, origin);
		await exerciseWorkspace(browser, origin);
		await exerciseAppWorkspace(browser, origin);
		await exerciseHeatmap(browser, origin);
		await studioUx.exercisePanelFirstChange(browser, origin);
		await studioUx.exerciseOneInfoPerRow(browser, origin);
		await studioUx.exerciseHistoryShortcuts(browser, origin);
		await studioUx.exerciseImportFormats(browser, origin);
		await studioUx.exerciseScoreChip(browser, origin);
		await studioUx.exerciseShareLinkLayouts(browser, origin);
		await studioUx.exerciseWorstNgrams(browser, origin);
		await studioUx.exerciseBestSwaps(browser, origin);
		await studioUx.exerciseBoardImage(browser, origin);
		await studioNumbers.exerciseNumbers(browser, origin);
		await studioHeaders.exerciseHeaderPopovers(browser, origin);
		await studioManage.exerciseEditorPasteImport(browser, origin);
		await studioManage.exerciseComparerPasteImport(browser, origin);
		await studioManage.exerciseManageLayoutsSite(browser, origin);
		await studioManage.exerciseManageLayoutsStore(browser, origin);
		await studioManage.exercisePercentiles(browser, origin);
		await studioManage.exercisePresets(browser, origin);
		await studioManage.exerciseRankingViews(browser, origin);
		await studioManage.exerciseRankingCsv(browser, origin);
		await studioManage.exerciseTabRenameDuplicate(browser, origin);

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
