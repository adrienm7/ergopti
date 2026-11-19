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

module.exports = {
	EN,
	openOnErgopti,
	analysed,
	shownChanges,
	swap,
	exercisePanelFirstChange
};
