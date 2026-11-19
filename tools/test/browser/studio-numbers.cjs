// tools/test/browser/studio-numbers.cjs

/**
 * ==============================================================================
 * MODULE: Studio Numbers Browser Cases
 * DESCRIPTION:
 * Reads every number Ergopti Studio shows (the Comparer's result tabs, the
 * editor's panel and score chip) from the rendered DOM, its text, tooltips
 * and accessible names, in French and in English, driven in Chromium by
 * layout-editor.playwright.cjs on its loopback server; run alone, it serves
 * the shared tree itself. The maintainer asked on 2026-11-19 that every
 * number go through the one locale formatter (info_popover.js format(),
 * U+202F groups in French).
 *
 * HOW A BYPASS IS SEEN:
 * The page's Intl.NumberFormat and toLocaleString write Arabic-Indic digits
 * (numberingSystem 'arab') in this run. A number written through the
 * formatter shows them; one written by String(), a template or toFixed()
 * keeps ASCII digits. So any ASCII digit left in the reading is a bypass,
 * once the texts that hold digits of their own are left out: layout and
 * corpus names, the analysers' names, the locale's own strings (« 3-key
 * rolls »), Unicode code points, key codes and the characters a key or an
 * n-gram types.
 *
 * WHAT ELSE IS CHECKED:
 * 1. A number and the unit or counted word after it are tied by a no-break
 *    space (U+00A0, or the language's own before %), never U+0020,
 *    so the unit never wraps away from its number (maintainer, 2026-11-19).
 * 2. Every table cell (a td, or a figure's role="cell") that shows a number
 *    shows its unit too (« 12,3 % », « 45 ms », « 1 234 fois »), so a
 *    screen reader reads each cell with it; a rank (la-rank, la-cell-rank),
 *    an ordinal, is the one number written alone.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { shared } = require('../../lib/paths.cjs');

// The Comparer's tabs that show results (comparer_page.js TABS, « Home » aside).
const RESULT_TABS = [
	'overview',
	'fingers',
	'bigrams',
	'trigrams',
	'rows',
	'heatmaps',
	'misc',
	'analysers',
	'details'
];
const LANGS = ['fr', 'en'];
// Where a text names the characters of keys: a lone digit there is a key's
// character, not a number (a board's key, a key column, an n-gram, a pair).
const KEY_CONTEXT = '.la-key, .la-keys, .la-ngram, .la-cell-count, .la-fingering-key';
// The cells read whole, and the ranks among them, written without a unit.
const CELLS = 'td, [role="cell"]';
const RANKS = '.la-rank, .la-cell-rank';
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};

/** Runs in the page before its scripts: every Intl number in Arabic-Indic digits. */
function arabicDigits() {
	const Original = Intl.NumberFormat;
	const arab = (options) => Object.assign({}, options, { numberingSystem: 'arab' });
	function NumberFormat(locales, options) {
		return new Original(locales, arab(options));
	}
	NumberFormat.prototype = Original.prototype;
	NumberFormat.supportedLocalesOf = Original.supportedLocalesOf;
	Intl.NumberFormat = NumberFormat;
	const toLocaleString = Number.prototype.toLocaleString;
	Number.prototype.toLocaleString = function (locales, options) {
		return toLocaleString.call(this, locales, arab(options));
	};
}

/**
 * Runs in the page: every text node and every tooltip or accessible name
 * under the roots, each with where it was read and whether it names keys.
 * Each table cell is read whole too, marked as a cell (a rank apart).
 * @param {{selectors: string[], keyContext: string, cells: string, ranks: string}} options
 *   The roots, read whole (hidden parts too), and the selectors of the key
 *   contexts, the cells and the ranks.
 * @returns {{where: string, text: string, keys: boolean, cell?: boolean}[]}
 */
function readTexts({ selectors, keyContext, cells, ranks }) {
	const out = [];
	const where = (node) => {
		const parts = [];
		for (let at = node; at && at.nodeType === 1 && parts.length < 4; at = at.parentElement)
			parts.unshift(at.id ? `#${at.id}` : `${at.tagName.toLowerCase()}.${at.className}`);
		return parts.join(' > ');
	};
	for (const selector of selectors)
		for (const root of document.querySelectorAll(selector)) {
			const walker = document.createTreeWalker(
				root,
				NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
			);
			for (let node = walker.currentNode; node; node = walker.nextNode()) {
				const element = node.nodeType === 3 ? node.parentElement : node;
				// Scripts, styles, a list's choices (names) and typed text.
				if (element.closest('script, style, option, textarea, code, kbd')) continue;
				const keys = Boolean(element.closest(keyContext));
				if (node.nodeType === 3) {
					if (node.data.trim()) out.push({ where: where(element), text: node.data, keys });
					continue;
				}
				if (node.matches(cells) && !node.matches(ranks))
					out.push({ where: where(node), text: node.textContent, keys: false, cell: true });
				for (const name of ['title', 'aria-label', 'aria-valuetext'])
					if (node.hasAttribute(name))
						out.push({ where: `${where(node)} [${name}]`, text: node.getAttribute(name), keys });
			}
		}
	return out;
}

/**
 * Runs in the page: the texts that hold digits of their own, longest first
 * (layout, corpus and keyboard names, the fixed parts of the locale's strings).
 * @returns {string[]}
 */
function ownTexts() {
	const texts = new Set();
	if (window.LAYOUT_ANALYSIS)
		for (const layout of window.LAYOUT_ANALYSIS.libraryLayouts()) texts.add(layout.name);
	for (const node of document.querySelectorAll(
		'option, .la-layout, .la-leader-name, .la-chart-label, .le-layout-name, #le-name'
	))
		texts.add(
			(node.value !== undefined && node.tagName === 'INPUT' ? node.value : node.textContent).trim()
		);
	if (window.LAYOUT_ANALYSER_SCORES)
		for (const analyser of window.LAYOUT_ANALYSER_SCORES.analysers()) texts.add(analyser.name);
	for (const value of Object.values(window._i18n_strings || {}))
		if (typeof value === 'string')
			for (const part of value.split(/\{[a-z_]+\}/)) texts.add(part.trim());
	return [...texts].filter((text) => /[0-9]/.test(text)).sort((a, b) => b.length - a.length);
}

/**
 * The bypasses of one reading: each ASCII digit left once the texts with
 * digits of their own are left out.
 * @param {{where: string, text: string, keys: boolean, cell?: boolean}[]} texts
 * @param {string[]} own - ownTexts() of the page.
 * @returns {string[]}
 */
function bypasses(texts, own) {
	const problems = [];
	for (const { where, text, keys, cell } of texts) {
		if (cell) {
			// A number alone, its sign and separators aside: the cell lost its unit.
			if (
				/^[\s+\-\u2212\u061c\u066b\u066c]*[\u0660-\u0669][\u0660-\u0669\s\u066b\u066c]*$/u.test(
					text
				)
			)
				problems.push(`a table cell without its unit: ${JSON.stringify(text)} at ${where}`);
			continue;
		}
		let rest = text;
		for (const part of own) if (rest.includes(part)) rest = rest.split(part).join(' ');
		// Unicode code points and the keys' codes (Digit1, Numpad0, F12).
		rest = rest.replace(/U\+[0-9A-F]{4,6}|\b(?:Digit|Numpad|F)[0-9]+\b/g, ' ');
		// A lone digit beside a key is the character it types.
		if (keys) rest = rest.replace(/(^|[^0-9\p{L}])[0-9](?=$|[^0-9\p{L}])/gu, '$1');
		if (/[0-9]/.test(rest))
			problems.push(`not written by the formatter: ${JSON.stringify(text)} at ${where}`);
		// A number, then a breaking space, then its unit or counted word (« 12,3 %», « 45 ms »).
		if (/[\u0660-\u0669] (?=[\p{L}%\u066a])/u.test(text))
			problems.push(`a breaking space before a unit: ${JSON.stringify(text)} at ${where}`);
	}
	return problems;
}

/**
 * A page of the Studio in a language, with the formatter's digits marked.
 * @returns {Promise<{page: import('playwright').Page, errors: string[], context: object}>}
 */
async function openMarked(browser, url) {
	const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
	await context.addInitScript(arabicDigits);
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(url);
	return { page, errors, context };
}

/** Reads the roots of a page and returns its bypasses, each named by the view. */
async function readView(page, label, selectors) {
	const own = await page.evaluate(ownTexts);
	const texts = await page.evaluate(readTexts, {
		selectors,
		keyContext: KEY_CONTEXT,
		cells: CELLS,
		ranks: RANKS
	});
	assert.ok(texts.length > 0, `${label}: nothing to read`);
	return bypasses(texts, own).map((problem) => `${label}: ${problem}`);
}

/** The Comparer's result tabs, a layout's details unfolded. */
async function comparerBypasses(browser, origin, lang) {
	const { page, errors, context } = await openMarked(
		browser,
		`${origin}/ui/layout_analysis/index.html?lang=${lang}&corpus=fr_nemolivier`
	);
	await page.waitForSelector('#la-table tbody tr', { timeout: 120000 });
	const problems = [];
	for (const id of RESULT_TABS) {
		await page.click(`#la-tab-${id}`);
		await page.waitForSelector(`#la-panel-${id}:not([hidden])`);
		if (id === 'details')
			await page.evaluate(() => {
				for (const node of document.querySelectorAll('#la-panel-details details')) node.open = true;
			});
		// The other analysers score one layout per idle slice.
		await page.waitForTimeout(id === 'analysers' ? 3000 : 300);
		problems.push(...(await readView(page, `${lang} ${id}`, [`#la-panel-${id}`, '#la-status'])));
	}
	assert.deepEqual(errors, [], `${lang}: no page error in the Comparer`);
	await context.close();
	return problems;
}

/** The editor's analysis panel and score chip. */
async function editorBypasses(browser, origin, lang) {
	const { page, errors, context } = await openMarked(
		browser,
		`${origin}/ui/layout_editor/index.html?lang=${lang}`
	);
	await page.waitForSelector('.la-panel-metrics tr[data-metric="distinct_chars"] td', {
		timeout: 120000
	});
	await page.evaluate(() => {
		document.getElementById('la-live-panel').open = true;
	});
	await page.waitForTimeout(1500);
	const problems = await readView(page, `${lang} editor`, ['#la-live-panel', '#le-score-chip']);
	assert.deepEqual(errors, [], `${lang}: no page error in the editor`);
	await context.close();
	return problems;
}

/** The optimiser after a short run: its tiles, its swaps and the library card. */
async function optimizerBypasses(browser, origin, lang) {
	const { page, errors, context } = await openMarked(
		browser,
		`${origin}/ui/layout_optimizer/index.html?lang=${lang}`
	);
	await page.waitForSelector('.layout-optimizer h1');
	// One restart of a few swaps (layout-optimizer.playwright.cjs shortBudget).
	await page.evaluate(() => {
		document.querySelector('.lo-advanced').open = true;
	});
	await page.fill('#lo-seconds', '20');
	await page.fill('#lo-iterations', '30');
	await page.fill('#lo-restarts', '1');
	await page.click('#lo-run');
	await page.waitForSelector('#lo-library-body .lo-library-content', { timeout: 180000 });
	const problems = await readView(page, `${lang} optimiser`, ['.layout-optimizer']);
	assert.deepEqual(errors, [], `${lang}: no page error in the optimiser`);
	await context.close();
	return problems;
}

/**
 * (studio-numbers) Every number of the Studio's results through the one
 * formatter, in French and in English.
 * @param {import('playwright').Browser} browser
 * @param {string} origin - The loopback server of the shared tree.
 */
async function exerciseNumbers(browser, origin) {
	const problems = [];
	for (const lang of LANGS) {
		problems.push(...(await comparerBypasses(browser, origin, lang)));
		problems.push(...(await editorBypasses(browser, origin, lang)));
		problems.push(...(await optimizerBypasses(browser, origin, lang)));
	}
	// One line per kind of place, so a bypass in a table names its column once.
	const kinds = [
		...new Map(problems.map((p) => [p.replace(/"[^"]*"/, '').replace(/\d+/g, ''), p])).values()
	];
	assert.deepEqual(kinds, [], 'every number the Studio shows is written by its formatter');
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
		await exerciseNumbers(browser, `http://127.0.0.1:${server.address().port}`);
	} finally {
		await browser.close();
		server.close();
	}
	console.log('ok - studio numbers');
}

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});

module.exports = { exerciseNumbers };
