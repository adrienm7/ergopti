// tools/test/browser/layout-editor-studio-ux.cjs

/**
 * ==============================================================================
 * MODULE: Studio Editor UX Browser Cases
 * DESCRIPTION:
 * The cases of the Studio editor's UX study (docs/audits/layout-analysers/
 * ux-study.md, section 6), driven in Chromium by layout-editor.playwright.cjs
 * on its loopback server. Each case carries the slug of its item so a failure
 * names it. The site's standalone editor opens on a copy of Ergopti from a
 * routed registry, as the website serves it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { shared } = require('../../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const KEYLAYOUT = path.join(ROOT, 'static', 'layouts', 'registry', 'ergopti', 'ergopti.keylayout');
const EN = JSON.parse(
	fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
);

/**
 * The site's editor on a copy of Ergopti, its analysis drawn.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 * @param {{lang?: string, viewport?: object, hash?: string, holdLayout?: boolean}} [options]
 *   holdLayout answers the Ergopti file only once the empty board is analysed.
 * @returns {Promise<{page: import('playwright').Page, errors: string[], context: object}>}
 */
async function openOnErgopti(browser, origin, options) {
	const opts = options || {};
	const context = await browser.newContext({
		acceptDownloads: true,
		viewport: opts.viewport || { width: 1400, height: 900 }
	});
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
	// Held until the empty board is analysed, as a slow network does on the site.
	let release = () => {};
	const held = new Promise((resolve) => {
		release = resolve;
	});
	if (!opts.holdLayout) release();
	await context.route('**/layouts/registry/ergopti.keylayout', async (route) => {
		await held;
		await route.fulfill({ contentType: 'text/plain', body: keylayout });
	});
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(
		`${origin}/ui/layout_editor/index.html?lang=${opts.lang || 'en'}${opts.hash || ''}`
	);
	if (opts.holdLayout) {
		await page.waitForSelector('.la-panel-metrics tr[data-metric="distinct_chars"]');
		release();
	}
	await page.waitForSelector('#le-board .le-legend.key-legend-dead');
	await page.waitForFunction(
		() => document.querySelector('#le-board [data-code="KeyQ"] .le-legend').textContent !== ''
	);
	await analysed(page);
	return { page, errors, context };
}

/** Waits for the panel's analysis of the layout on the board (more than the empty board's characters). */
function analysed(page) {
	return page.waitForFunction(() => {
		const row = document.querySelector('.la-panel-metrics tr[data-metric="distinct_chars"] td');
		return row && parseFloat(row.textContent.replace(/[^\d.,]/g, '').replace(',', '.')) > 40;
	});
}

/** The change cells of the panel's metrics that show a change. */
function shownChanges(page) {
	return page.$$eval('.la-panel-metrics tr[data-metric] td.la-panel-delta', (cells) =>
		cells.map((cell) => cell.textContent.trim()).filter(Boolean)
	);
}

/** Swaps two keys of the base layer with « Swap with the key ». */
async function swap(page, from, to) {
	await page.click(`#le-board [data-code="${from}"]`);
	await page.selectOption('#le-swap-target', to);
	await page.click('#le-swap');
}

/**
 * (panel-first-change) The first analysis of a layout shows no change: the empty
 * board drawn before the Ergopti copy arrived is another layout, so its metrics
 * are not a « before ». A swap then shows what it changed.
 */
async function exercisePanelFirstChange(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin, { holdLayout: true });
	// The panel's debounce: give a stale comparison the time to draw.
	await page.waitForTimeout(400);
	assert.deepEqual(await shownChanges(page), [], 'no change on the first analysis of Ergopti');
	await swap(page, 'KeyQ', 'KeyW');
	await page.waitForFunction(
		() =>
			[...document.querySelectorAll('.la-panel-metrics td.la-panel-delta')].some(
				(cell) => cell.textContent.trim() !== ''
			),
		null,
		{ timeout: 10000 }
	);
	assert.deepEqual(errors, []);
	await context.close();
}

/** The number of « i » buttons in each row header of a table, by its text. */
function infoPerRow(page, selector) {
	return page.$$eval(`${selector} tr`, (rows) =>
		rows
			.map((row) => row.querySelector('th'))
			.filter(Boolean)
			.map((th) => [
				th.textContent.replace(/\s*i\s*$/g, '').trim(),
				th.querySelectorAll('.la-info').length
			])
	);
}

/**
 * (one-info-per-row) Every metric row of « All measures » (Comparer › One
 * layout) and of the editor panel has one « i »: the left-hand shortcuts row
 * had a second one for the letters' usefulness, which its single popover now
 * explains after its own text.
 */
async function exerciseOneInfoPerRow(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(
		`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier&layouts=ergopti,azerty&details=ergopti&versus=azerty`
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await page.click('#la-tab-details');
	await page.waitForSelector('#la-metrics tbody tr');
	const rows = await infoPerRow(page, '#la-metrics tbody');
	assert.ok(rows.length >= 20, `all measures: ${rows.length} rows`);
	const metricRows = rows.filter(([, count]) => count > 0);
	assert.deepEqual(
		metricRows.filter(([, count]) => count !== 1),
		[],
		'one « i » per row of All measures'
	);
	const shortcutRow = page
		.locator('#la-metrics tbody tr')
		.filter({ hasText: EN['layout_analysis.metric.shortcut_left'] });
	await shortcutRow.locator('.la-info').click();
	const texts = await page.$$eval('#la-popover .la-popover-text', (nodes) =>
		nodes.map((node) => node.textContent)
	);
	assert.deepEqual(
		texts,
		[EN['layout_analysis.info.shortcut_left'], EN['layout_analysis.info.shortcut_letters']],
		'its popover explains the letters too'
	);
	assert.deepEqual(errors, []);
	await context.close();

	const editor = await openOnErgopti(browser, origin);
	const panelRows = await infoPerRow(editor.page, '.la-panel-metrics:not(.la-panel-analysers)');
	assert.ok(panelRows.length > 10, `panel: ${panelRows.length} rows`);
	assert.deepEqual(
		panelRows.filter(([, count]) => count !== 1),
		[],
		'one « i » per row of the panel'
	);
	assert.deepEqual(editor.errors, []);
	await editor.context.close();
}

/**
 * (history-shortcuts) Ctrl/Cmd+Z undoes and Ctrl/Cmd+Y or Ctrl/Cmd+Shift+Z
 * redoes in the editor, from a key or with nothing focused; a text field keeps
 * its own undo. The buttons name their shortcut.
 */
async function exerciseHistoryShortcuts(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin);
	const legend = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
	const [q, w] = [await legend('KeyQ'), await legend('KeyW')];
	await swap(page, 'KeyQ', 'KeyW');
	assert.equal(await legend('KeyQ'), w, 'the swap moved the key');
	await page.focus('#le-board [data-code="KeyE"]');
	await page.keyboard.press('Control+z');
	assert.equal(await legend('KeyQ'), q, 'Ctrl+Z on a key undoes');
	await page.evaluate(() => document.activeElement.blur());
	await page.keyboard.press('Control+y');
	assert.equal(await legend('KeyQ'), w, 'Ctrl+Y with nothing focused redoes');
	await page.keyboard.press('Meta+z');
	assert.equal(await legend('KeyQ'), q, 'Cmd+Z undoes');
	await page.keyboard.press('Control+Shift+z');
	assert.equal(await legend('KeyQ'), w, 'Ctrl+Shift+Z redoes');
	// A text field: its Ctrl+Z is its own.
	await page.click('#le-tools [data-tool="details"]');
	await page.fill('#le-name', 'Typed name');
	await page.focus('#le-name');
	await page.keyboard.press('Control+z');
	assert.equal(await legend('KeyQ'), w, 'Ctrl+Z in a text field leaves the layout alone');
	const names = await page.$$eval('#le-undo, #le-redo', (buttons) =>
		buttons.map((button) => ({
			label: button.getAttribute('aria-label'),
			title: button.title,
			keys: button.getAttribute('aria-keyshortcuts')
		}))
	);
	assert.match(names[0].label, /^Undo \(.*Z\)$/, `undo names its shortcut: ${names[0].label}`);
	assert.match(names[1].label, /^Redo \(.*Y.*Z\)$/, `redo names its shortcuts: ${names[1].label}`);
	assert.equal(names[0].title, names[0].label);
	assert.equal(names[0].keys, 'Control+Z Meta+Z');
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (import-formats) « Import… » accepts every file « Open… » accepts, and its
 * .zip backups: a KLA JSON opens as a new tab through the same reader as
 * « Open… »; a file of another type names what Import takes.
 */
async function exerciseImportFormats(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin);
	const opened = (await page.getAttribute('#le-open-file', 'accept')).split(',');
	const imported = (await page.getAttribute('#le-tabs-import-file', 'accept')).split(',');
	assert.ok(opened.length >= 10, `Open… accepts ${opened.join(' ')}`);
	assert.deepEqual(
		imported,
		opened.concat(['.zip']),
		'Import… accepts what Open… accepts, and backups'
	);
	const dir = path.join(ROOT, 'tools', 'test', 'fixtures', 'layout-formats', 'third-party');
	const tabs = () => page.locator('.le-layout-tab').count();
	const before = await tabs();
	await page.setInputFiles('#le-tabs-import-file', [path.join(dir, 'ergol.json')]);
	await page.waitForFunction(
		(count) => document.querySelectorAll('.le-layout-tab').length > count,
		before
	);
	assert.equal(
		await page.textContent('#le-board [data-code="KeyW"] .le-legend'),
		'c',
		"the KLA JSON's tab shows Ergo-L"
	);
	await page.setInputFiles('#le-tabs-import-file', {
		name: 'notes.pdf',
		mimeType: 'application/pdf',
		buffer: Buffer.from('%PDF-1.4')
	});
	await page.waitForFunction(() =>
		/notes\.pdf/.test(document.getElementById('le-message').textContent)
	);
	const message = await page.textContent('#le-message');
	assert.ok(
		message.includes('.kbe') && message.includes('.zip'),
		`the refusal names the formats: ${message}`
	);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (score-chip) Above the board, a chip shows the score and rank, then the
 * change of the last edit, better or worse in words and by a mark; its live
 * region (one node across renders) announces each new score politely; it stays
 * on screen while the page scrolls to the analysis, and a click unfolds and
 * shows the analysis.
 */
async function exerciseScoreChip(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin);
	await page.waitForFunction(
		() => document.querySelector('#le-score-chip .le-score-value').textContent !== '—'
	);
	const chip = () =>
		page.evaluate(() => ({
			score: document.querySelector('#le-score-chip .le-score-value').textContent,
			change: document.querySelector('#le-score-chip .le-score-change').textContent,
			live: document.getElementById('le-score-live').textContent
		}));
	const first = await chip();
	assert.match(first.score, /^\d+([.,]\d)?$/, `the chip shows the score: ${JSON.stringify(first)}`);
	assert.equal(first.change, '', 'no change on the first analysis');
	assert.match(first.live, /^Score .* · rank \d+\sof \d+$/, `announced: ${first.live}`);
	const live = await page.$eval('#le-score-live', (node) => [
		node.getAttribute('role'),
		node.getAttribute('aria-live')
	]);
	assert.deepEqual(live, ['status', 'polite']);
	await page.evaluate(() => {
		document.getElementById('le-score-live').dataset.kept = 'yes';
	});
	const sticky = await page.$eval('#le-score-chip', (node) => getComputedStyle(node).position);
	assert.equal(sticky, 'sticky');
	const chipBox = await page.$eval('#le-score-chip', (node) => node.getBoundingClientRect().bottom);
	const boardBox = await page.$eval('#le-board', (node) => node.getBoundingClientRect().top);
	assert.ok(chipBox <= boardBox, 'the chip sits above the board');
	// A render or a rename analyses the same keys again: still no change.
	await page.evaluate(() => window.layoutEditor.render());
	await page.waitForTimeout(400);
	assert.equal((await chip()).change, '', 'the same keys analysed again show no change');
	await swap(page, 'KeyQ', 'KeyW');
	await page.waitForFunction(
		() => document.querySelector('#le-score-chip .le-score-change').textContent !== ''
	);
	const after = await chip();
	// Another key colour analyses the swapped keys again: the swap's change stays.
	await page.selectOption('#la-panel-heat', 'presses');
	await page.waitForTimeout(400);
	assert.equal((await chip()).change, after.change, 'a new key colour keeps the change shown');
	assert.match(after.change, /^(▲|▼|=)/, `the change has its mark: ${JSON.stringify(after)}`);
	assert.match(after.live, /since the last edit|unchanged by the last edit/, after.live);
	const verdict = await page.$eval('#le-score-chip .le-score-change', (node) => node.className);
	assert.match(verdict, /le-score-(better|worse|same)/);
	assert.equal(
		await page.$eval('#le-score-live', (node) => node.dataset.kept),
		'yes',
		'one live region across renders'
	);
	// Scrolled down to the analysis, the chip is still on screen.
	await page.$eval('#la-live-panel', (node) => node.scrollIntoView({ block: 'end' }));
	const top = await page.$eval('#le-score-chip', (node) => node.getBoundingClientRect().top);
	assert.ok(top >= 0 && top < 200, `the chip stays in view: top ${top}`);
	await page.evaluate(() => {
		document.getElementById('la-live-panel').open = false;
		window.scrollTo(0, 0);
	});
	await page.waitForFunction(
		() => document.querySelector('#le-score-chip .le-score-value').textContent === '—'
	);
	await page.click('#le-score-open');
	assert.equal(await page.$eval('#la-live-panel', (node) => node.open), true, 'a click unfolds it');
	assert.equal(
		await page.evaluate(() => document.activeElement.classList.contains('la-panel-title')),
		true,
		'and moves the focus to its title'
	);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (share-link-layouts) « Copy the link » carries the visitor's own layouts in
 * the URL fragment; opening the link compares them again, named « from a
 * link »; a damaged fragment is refused in words and the rest still opens.
 */
async function exerciseShareLinkLayouts(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	const rowNames = () =>
		page.$$eval('#la-table tbody tr td:nth-child(2)', (cells) =>
			cells.map((cell) => cell.textContent)
		);
	await page.goto(
		`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier&layouts=ergopti,azerty`
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await page.evaluate(() => {
		const azerty = window.LAYOUT_ANALYSIS.libraryLayouts().find((l) => l.id === 'azerty');
		const rows = Object.assign({}, azerty.rows, { KeyQ: azerty.rows.KeyW, KeyW: azerty.rows.KeyQ });
		window.LAYOUT_ANALYSIS_COMPARER.addLayouts([
			{ id: 'user_mine', name: 'My swap', rows, dead: azerty.dead, origin: 'user' }
		]);
	});
	await page.waitForFunction(() =>
		[...document.querySelectorAll('#la-table tbody tr td:nth-child(2)')].some((th) =>
			th.textContent.includes('My swap')
		)
	);
	await page.click('#la-share');
	await page.waitForFunction(() => !document.getElementById('la-share-status').hidden);
	const link = await page.evaluate(() => navigator.clipboard.readText());
	const url = new URL(link);
	assert.match(
		url.hash,
		/^#l=1\.[A-Za-z0-9_-]+$/,
		`the link carries the layout: ${link.slice(0, 120)}`
	);
	assert.equal(url.searchParams.get('layouts').split(',').sort().join(','), 'azerty,ergopti');
	assert.equal(
		await page.textContent('#la-share-status'),
		EN['layout_analysis.share.copied'],
		'a short link with a built-in text: everything is in it'
	);
	await page.goto(`${origin}${url.pathname}${url.search}${url.hash}`);
	const mark = `My swap (${EN['layout_analysis.share.from_link']})`;
	await page.waitForFunction(
		(name) =>
			[...document.querySelectorAll('#la-table tbody tr td:nth-child(2)')].some((th) =>
				th.textContent.includes(name)
			),
		mark
	);
	const names = await rowNames();
	assert.ok(
		names.some((name) => name.includes('AZERTY')),
		`the library layouts too: ${names}`
	);
	// Another document first: a change of fragment alone would not reload the page.
	await page.goto('about:blank');
	await page.goto(`${origin}${url.pathname}${url.search}#l=1.AAAA`);
	await page.waitForFunction(() => !document.getElementById('la-share-status').hidden);
	const refusal = await page.textContent('#la-share-status');
	assert.ok(
		refusal.startsWith(EN['layout_analysis.share.link_refused'].split('{reason}')[0]) &&
			refusal.includes(EN['layout_analysis.formats.refused.link_damaged'].split(' (')[0]),
		`a damaged link is refused in words: ${refusal}`
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	assert.deepEqual(errors, []);
	await context.close();
}

/** The keys outlined on a board and their order numbers. */
function outlined(page, board) {
	return page.$$eval(`${board} .la-ngram-key`, (keys) =>
		keys.map((key) => `${key.dataset.code}:${key.getAttribute('data-ngram-order')}`)
	);
}

/**
 * (worst-ngrams) The worst pairs and trigrams show in the editor panel and in
 * the Comparer's overview; hovering or focusing one outlines its keys on the
 * board, numbered in typing order, and Escape, blur or leaving it clears them.
 */
async function exerciseWorstNgrams(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin);
	await page.waitForSelector('#la-panel-ngrams .la-ngram-sfb .la-ngram');
	const cards = await page.$$eval('#la-panel-ngrams .la-ngram-card h4', (titles) =>
		titles.map((title) => title.textContent)
	);
	assert.deepEqual(
		cards,
		['sfb', 'sfs', 'lsb', 'scissors', 'redirect_bad'].map(
			(id) => EN[`layout_analysis.metric.${id}`]
		)
	);
	const first = page.locator('#la-panel-ngrams .la-ngram-sfb .la-ngram').first();
	const label = await first.getAttribute('aria-label');
	assert.match(label, /^\S+ \S+: \d+[.,]\d+\s?%$/, `a row says its keys and share: ${label}`);
	await first.focus();
	const focused = await outlined(page, '#le-board');
	assert.equal(focused.length, 2, `focus outlines the pair's two keys: ${focused}`);
	assert.deepEqual(focused.map((key) => key.split(':')[1]).sort(), ['1', '2']);
	await page.keyboard.press('Escape');
	assert.deepEqual(await outlined(page, '#le-board'), [], 'Escape clears them');
	await page.locator('#la-panel-ngrams .la-ngram-redirect_bad .la-ngram').first().hover();
	const hovered = await outlined(page, '#le-board');
	assert.ok(hovered.length >= 2, `hover outlines the trigram's keys: ${hovered}`);
	await page.mouse.move(0, 0);
	assert.deepEqual(await outlined(page, '#le-board'), [], 'leaving the row clears them');
	assert.deepEqual(errors, []);
	await context.close();

	const comparer = await browser.newPage({ viewport: { width: 1280, height: 900 } });
	const comparerErrors = [];
	comparer.on('pageerror', (error) => comparerErrors.push(error.message));
	await comparer.goto(
		`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier&layouts=ergopti,azerty&details=azerty`
	);
	// A link that names a detailed layout opens « One layout »: back to the overview.
	await comparer.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await comparer.click('#la-tab-overview');
	await comparer.waitForSelector('#la-ngrams-list .la-ngram-sfb .la-ngram');
	assert.match(await comparer.textContent('#la-ngrams-caption'), /AZERTY/, 'the detailed layout');
	await comparer.locator('#la-ngrams-list .la-ngram-sfb .la-ngram').first().focus();
	const onBoard = await outlined(comparer, '#la-ngrams-board');
	assert.equal(onBoard.length, 2, `the overview's board outlines the pair: ${onBoard}`);
	await comparer.keyboard.press('Tab');
	const next = await outlined(comparer, '#la-ngrams-board');
	assert.equal(next.length, 2, 'Tab moves to the next pair and outlines it');
	assert.deepEqual(comparerErrors, []);
	await comparer.close();
}

/**
 * (best-swaps) « Best swaps » ranks the single swaps in slices (the progress
 * moves while the page stays responsive), lists those that raise the score
 * best first, and one click applies a swap as one edit that Ctrl+Z undoes.
 */
async function exerciseBestSwaps(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin);
	const legend = (code) => page.textContent(`#le-board [data-code="${code}"] .le-legend`);
	await page.click('#la-swaps-run');
	// The bar moves in steps: the search yields between slices.
	const seen = new Set();
	await page.waitForFunction(
		() => {
			const bar = document.getElementById('la-swaps-progress');
			return bar.hidden || bar.value > 0;
		},
		null,
		{ timeout: 60000 }
	);
	for (let i = 0; i < 40 && !(await page.isHidden('#la-swaps-progress')); i++) {
		seen.add(await page.$eval('#la-swaps-progress', (bar) => bar.value));
		await page.waitForTimeout(25);
	}
	assert.ok(seen.size >= 2, `the progress moves in steps: ${[...seen].join(', ')}`);
	await page.waitForSelector('#la-swaps-list .la-swap', { timeout: 60000 });
	const swaps = await page.$$eval('#la-swaps-list .la-swap-apply', (buttons) =>
		buttons.map((button) => ({
			codes: button.dataset.codes.split(' '),
			label: button.getAttribute('aria-label')
		}))
	);
	assert.ok(swaps.length > 0 && swaps.length <= 10, `${swaps.length} swaps`);
	assert.match(swaps[0].label, /^Swap \S+ and \S+ \(\+\d+[.,]\d+\)$/, swaps[0].label);
	const [a, b] = swaps[0].codes;
	const before = [await legend(a), await legend(b)];
	await page.click('#la-swaps-list .la-swap-apply');
	assert.deepEqual([await legend(a), await legend(b)], [before[1], before[0]], 'applied');
	await page.waitForFunction(() =>
		document.querySelector('#le-score-chip .le-score-change').classList.contains('le-score-better')
	);
	await page.waitForFunction(
		(text) => document.querySelector('.la-swaps-status').textContent === text,
		EN['layout_analysis.swaps.stale']
	);
	assert.equal(await page.locator('#la-swaps-list .la-swap').count(), 0, 'the old list is gone');
	await page.evaluate(() => document.activeElement.blur());
	await page.keyboard.press('Control+z');
	assert.deepEqual([await legend(a), await legend(b)], before, 'one edit: Ctrl+Z undoes it');
	assert.deepEqual(errors, []);
	await context.close();
}

/** The bytes of a download a click starts. */
async function downloadOf(page, selector) {
	const [download] = await Promise.all([page.waitForEvent('download'), page.click(selector)]);
	return { name: download.suggestedFilename(), bytes: fs.readFileSync(await download.path()) };
}

/** A PNG's signature and its pixel size (IHDR). */
function pngSize(bytes) {
	assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', 'a PNG signature');
	return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

/**
 * (board-image) The editor's board and the Comparer's heatmaps save as SVG and
 * PNG: on the site as a browser download, in the app through the host's
 * download path (source_export, the Downloads folder on the three OS). The SVG
 * draws every key with its legend and its heat colour; the PNG is it at twice
 * its size.
 */
async function exerciseBoardImage(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin);
	const svg = await downloadOf(page, '#le-board-image-svg');
	assert.match(svg.name, /^my-ergopti\.svg$|\.svg$/);
	const text = svg.bytes.toString('utf8');
	assert.match(text, /^<svg [^>]*xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
	const width = Number(/width="(\d+)"/.exec(text)[1]);
	const keyCount = await page.locator('#le-board [data-code]').count();
	assert.ok((text.match(/<rect /g) || []).length >= keyCount - 1, 'every key is drawn');
	assert.ok(text.includes('>é</text>') && text.includes('>^</text>'), 'with its legend');
	const fills = new Set(Array.from(text.matchAll(/<rect [^>]*fill="([^"]+)"/g), (m) => m[1]));
	assert.ok(fills.size >= 6, `the heat colours are drawn: ${fills.size} fills`);
	const png = await downloadOf(page, '#le-board-image-png');
	assert.match(png.name, /\.png$/);
	assert.equal(pngSize(png.bytes)[0], width * 2, 'the PNG is the SVG at twice its size');
	assert.match(
		await page.textContent('#le-board-image-png ~ .la-image-status'),
		/^Image downloaded: /
	);
	assert.deepEqual(errors, []);
	await context.close();

	// The Comparer's detail heatmap and a side-by-side card.
	const comparer = await browser.newPage({
		viewport: { width: 1280, height: 900 },
		acceptDownloads: true
	});
	await comparer.goto(
		`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier&layouts=ergopti,azerty&details=ergopti`
	);
	await comparer.waitForSelector('#la-heatmap .la-key');
	const heat = await downloadOf(comparer, '#la-heatmap-image-svg');
	assert.match(heat.name, /^ergopti-heatmap-.+\.svg$/, heat.name);
	await comparer.click('#la-tab-heatmaps');
	await comparer.waitForSelector('.la-heat-card .la-image-save');
	const card = await downloadOf(comparer, '.la-heat-card [id$="-png"]');
	pngSize(card.bytes);
	await comparer.close();

	// The app: the bytes go to the host's download path, which answers with the file's path.
	const app = await browser.newPage({ viewport: { width: 1400, height: 900 } });
	const appErrors = [];
	app.on('pageerror', (error) => appErrors.push(error.message));
	await app.addInitScript((strings) => {
		window._i18n_strings = strings;
		window.__posted = [];
		window.webkit = {
			messageHandlers: {
				layout_editor_window_bridge: { postMessage: (payload) => window.__posted.push(payload) }
			}
		};
	}, EN);
	await app.goto(`${origin}/ui/layout_editor_window/index.html`);
	await app.evaluate(() =>
		window.initData({ strings: {}, state: { platform: 'linux' }, source_export: true })
	);
	await app.evaluate(() => window.sourceData({ text: null, folder: 'layout_sources/' }));
	await app.waitForSelector('#le-board-image-png');
	await app.click('#le-board-image-png');
	await app.waitForFunction(() => window.__posted.some((p) => p.action === 'source_export'));
	const posted = await app.evaluate(() => {
		const request = window.__posted.find((p) => p.action === 'source_export');
		return { filename: request.filename, head: atob(request.data).slice(1, 4) };
	});
	assert.match(posted.filename, /^[A-Za-z0-9][A-Za-z0-9_.-]*\.png$/, 'a name the hosts write');
	assert.equal(posted.head, 'PNG');
	// The host reports where it wrote the file; any absolute path stands in for it.
	const writtenPath = path.join(ROOT, 'build', 'x.png');
	await app.evaluate((written) => window.exportResult({ ok: true, path: written }), writtenPath);
	await app.waitForFunction(
		(written) =>
			document
				.querySelector('#le-board-image-png ~ .la-image-status')
				.textContent.includes(written),
		writtenPath
	);
	assert.deepEqual(appErrors, []);
	await app.close();
}

module.exports = {
	exerciseBoardImage,
	exerciseBestSwaps,
	exerciseWorstNgrams,
	exerciseShareLinkLayouts,
	exerciseScoreChip,
	exerciseImportFormats,
	exerciseHistoryShortcuts,
	exerciseOneInfoPerRow,
	EN,
	openOnErgopti,
	analysed,
	shownChanges,
	swap,
	exercisePanelFirstChange
};
