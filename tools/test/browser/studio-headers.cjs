// tools/test/browser/studio-headers.cjs

/**
 * ==============================================================================
 * MODULE: Studio Compact Headers Browser Cases
 * DESCRIPTION:
 * The Comparer's ranking table in its « Résumé » tab, driven in Chromium by
 * layout-editor.playwright.cjs on its loopback server (run alone, it serves
 * the shared tree itself), in French and in English. The maintainer asked on
 * 2026-11-19 for compact column headers: the usual acronyms, two lines at
 * most, the full name, the definition and the formula one key press away.
 *
 * WHAT IS CHECKED:
 * 1. A metric whose name ends with its acronym is headed by it (« SFB »),
 *    its sort button named in full; every metric header wraps on two lines
 *    at most and has one « i » button.
 * 2. From the keyboard alone, the « i » of a header opens its popover: the
 *    metric's full name (the dialog's name), its definition, its formula
 *    with the numbers written the page's way; Escape closes it and gives
 *    the focus back. The score's « i » gives the score's formula.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { shared } = require('../../lib/paths.cjs');

const LANGS = ['fr', 'en'];
const ACRONYMS = { sfb: 'SFB', sfs: 'SFS', lsb: 'LSB' };
// A header of two lines, with room for the rounding of its line boxes.
const TWO_LINES = 2.4;
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};

/** The locale's strings, read as the page reads them. */
function stringsOf(lang) {
	return JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', `${lang}.json`), 'utf8')
	);
}

/** Opens the « i » of one header from the keyboard and reads the popover it shows. */
async function openFromKeyboard(page, key) {
	const info = page.locator(`#la-table thead th:has(button[data-sort="${key}"]) .la-info`);
	await info.focus();
	await page.keyboard.press('Enter');
	await page.waitForSelector('#la-popover:not([hidden])');
	return page.evaluate(() => {
		const popover = document.getElementById('la-popover');
		const name = popover.querySelector('.la-popover-name');
		return {
			labelledBy: popover.getAttribute('aria-labelledby'),
			nameId: name.id,
			name: name.hidden ? null : name.textContent,
			texts: [...popover.querySelectorAll('.la-popover-text')].map((p) => p.textContent),
			formula: popover.querySelector('.la-popover-formula').textContent,
			focused: document.activeElement.className
		};
	});
}

/** One language: the headers, then the popovers of three of them. */
async function checkHeaders(browser, origin, lang) {
	const strings = stringsOf(lang);
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(`${origin}/ui/layout_analysis/index.html?lang=${lang}&corpus=fr_nemolivier`);
	await page.waitForSelector('#la-table thead th.la-th-metric', { timeout: 120000 });
	await page.click('#la-tab-overview');
	const headers = await page.$$eval('#la-table thead th.la-th-metric', (cells) =>
		cells.map((th) => {
			const button = th.querySelector('.la-sort');
			const style = getComputedStyle(button);
			return {
				key: button.dataset.sort,
				text: button.textContent,
				label: button.getAttribute('aria-label'),
				infos: th.querySelectorAll('.la-info').length,
				lines: button.getBoundingClientRect().height / parseFloat(style.lineHeight)
			};
		})
	);
	assert.ok(headers.length >= 10, `${lang}: the ranking shows its metric columns`);
	for (const header of headers) {
		const name = strings[`layout_analysis.metric.${header.key}`];
		if (ACRONYMS[header.key]) {
			assert.equal(
				header.text,
				ACRONYMS[header.key],
				`${lang}: ${header.key} is headed by its acronym`
			);
			assert.equal(header.label, name, `${lang}: ${header.key}'s sort button is named in full`);
		} else assert.equal(header.text, name, `${lang}: ${header.key} is headed by its name`);
		assert.equal(header.infos, 1, `${lang}: ${header.key} has one « i »`);
		assert.ok(
			header.lines <= TWO_LINES,
			`${lang}: ${header.key} wraps on two lines at most (${header.lines.toFixed(2)})`
		);
	}
	const sfb = await openFromKeyboard(page, 'sfb');
	assert.equal(
		sfb.name,
		strings['layout_analysis.metric.sfb'],
		`${lang}: the popover names SFB in full`
	);
	assert.equal(sfb.labelledBy, sfb.nameId, `${lang}: the dialog is named by the metric's name`);
	assert.deepEqual(sfb.texts, [strings['layout_analysis.info.sfb']], `${lang}: its definition`);
	assert.equal(
		sfb.formula,
		`${strings['layout_analysis.formula.label']} ${strings['layout_analysis.formula.bigrams']}`,
		`${lang}: a bigram share's formula`
	);
	assert.match(sfb.focused, /la-popover-close/, `${lang}: the focus moves into the popover`);
	await page.keyboard.press('Escape');
	assert.equal(await page.isHidden('#la-popover'), true, `${lang}: Escape closes the popover`);
	assert.equal(
		await page.evaluate(
			() => document.activeElement.closest('th').querySelector('.la-sort').dataset.sort
		),
		'sfb',
		`${lang}: the focus is back on the header's « i »`
	);
	const distance = await openFromKeyboard(page, 'distance');
	const key = await page.evaluate(() =>
		window.LAYOUT_ANALYSIS_INFO.measure(
			window.LAYOUT_ANALYSIS_DATA.model.key_unit_mm,
			2,
			window.LAYOUT_ANALYSIS_INFO.t('layout_analysis.unit.mm')
		)
	);
	assert.ok(
		distance.formula.includes(key) && key.includes('\u00a0'),
		`${lang}: the distance formula writes one key's width the page's way: ${distance.formula}`
	);
	await page.keyboard.press('Escape');
	const score = await openFromKeyboard(page, 'score');
	assert.equal(score.name, strings['layout_analysis.table.score'], `${lang}: the score's popover`);
	assert.ok(
		score.formula.endsWith(strings['layout_analysis.formula.score']),
		`${lang}: the score's formula`
	);
	await page.keyboard.press('Escape');
	assert.deepEqual(errors, [], `${lang}: no page error`);
	await context.close();
}

/**
 * (studio-header-popovers) The ranking's compact headers and their popovers.
 * @param {import('playwright').Browser} browser
 * @param {string} origin - The loopback server of the shared tree.
 */
async function exerciseHeaderPopovers(browser, origin) {
	for (const lang of LANGS) await checkHeaders(browser, origin, lang);
}

/** Serves the shared tree read-only on loopback (a run of this module alone). */
function serve() {
	const root = shared();
	const server = http.createServer((request, response) => {
		const file = path.resolve(root, new URL(request.url, 'http://localhost').pathname.slice(1));
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

async function main() {
	const { chromium } = require('playwright');
	const server = await serve();
	const browser = await chromium.launch();
	try {
		await exerciseHeaderPopovers(browser, `http://127.0.0.1:${server.address().port}`);
	} finally {
		await browser.close();
		server.close();
	}
	console.log('ok - studio headers');
}

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});

module.exports = { exerciseHeaderPopovers };
