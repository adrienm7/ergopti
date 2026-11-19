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

module.exports = {
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
