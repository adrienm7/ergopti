// tools/test/browser/layout-optimizer.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Browser Regression
 * DESCRIPTION:
 * Drives the « Optimiser » tab of Ergopti Studio (the page the website
 * frames) in Chromium from a loopback server: a pasted text and an opened
 * file become the corpus, with a clear message for a text too short, a file
 * too large or of an unknown type; a run in Web Workers finishes with the
 * engine's score of its layout; a zone drawn on the board keeps a letter on
 * its keys; the choices survive a reload, and the page still works when the
 * browser refuses storage; the score is the Comparer's, with the Comparer's
 * saved settings (a weight raised there changes the optimizer's score and
 * its summary); Ctrl Z X C V kept on their QWERTY keys while the letters
 * move; it lays out at phone width in light and dark without a sideways
 * page scroll; no raw locale key shows in any of the 21 locales. Page
 * errors and requests outside the loopback origin fail the gate.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { chromium } = require('playwright');
const { shared } = require('../../lib/paths.cjs');

const LOCALES = JSON.parse(
	fs.readFileSync(shared('core', 'i18n', 'data', 'locale_order.json'), 'utf8')
).order;
const TYPES = {
	'.html': 'text/html',
	'.js': 'text/javascript',
	'.css': 'text/css',
	'.json': 'application/json'
};
const PAGE = '/ui/layout_optimizer/index.html';
// A French text long enough for the page's minimum, short enough for a fast run.
const TEXT =
	'Longtemps, je me suis couché de bonne heure. Parfois, à peine ma bougie éteinte, ' +
	'mes yeux se fermaient si vite que je n’avais pas le temps de me dire : je m’endors. ' +
	'Et, une demi-heure après, la pensée qu’il était temps de chercher le sommeil m’éveillait.';
const PHONE = { width: 375, height: 760 };

/** Serves the shared tree read-only on loopback. */
function serve() {
	const root = shared();
	const server = http.createServer((request, response) => {
		const pathname = new URL(request.url, 'http://localhost').pathname;
		const file = path.resolve(root, decodeURIComponent(pathname.slice(1)));
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
 * Opens the page in a new context.
 * @param {object} browser - Chromium.
 * @param {string} origin - The loopback origin.
 * @param {{lang?: string, viewport?: object, colorScheme?: string, blockStorage?: boolean,
 *   context?: object}} [how] - blockStorage makes every localStorage access throw,
 *   as a browser that refuses site data does; context reuses a context (its storage).
 * @returns {Promise<{page: object, errors: string[], context: object}>}
 */
async function open(browser, origin, how) {
	const opts = how || {};
	const context =
		opts.context ||
		(await browser.newContext({
			viewport: opts.viewport || { width: 1280, height: 900 },
			colorScheme: opts.colorScheme || 'light'
		}));
	if (opts.blockStorage)
		await context.addInitScript(() => {
			Object.defineProperty(window, 'localStorage', {
				get() {
					throw new DOMException('The operation is insecure.', 'SecurityError');
				}
			});
		});
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	page.on('request', (request) => {
		if (!request.url().startsWith(origin + '/') && !request.url().startsWith('blob:'))
			errors.push(`unexpected request: ${request.url()}`);
	});
	page.on('dialog', (dialog) => errors.push(`native dialog: ${dialog.message()}`));
	await page.goto(`${origin}${PAGE}?lang=${opts.lang || 'en'}`);
	await page.waitForFunction(() => {
		const title = document.querySelector('.layout-optimizer h1');
		return title && title.textContent && !title.textContent.startsWith('layout_optimizer.');
	});
	return { page, errors, context };
}

/** The visible text of the page's status line under the text box. */
const textStatus = (page) => page.locator('#lo-text-status').textContent();

/** Sets a short budget: one restart of a few swaps, so a run ends in seconds. */
async function shortBudget(page) {
	// The budget is folded under « Search budget and seed ».
	await page.evaluate(() => {
		document.querySelector('.lo-advanced').open = true;
	});
	await page.fill('#lo-seconds', '20');
	await page.fill('#lo-iterations', '30');
	await page.fill('#lo-restarts', '1');
}

/** Runs the search and waits for its end; returns the status line. */
async function runToEnd(page) {
	// A page-thread run on a short text can end within one poll: the run is
	// over when the status says so (or turns to an error) and the button is back.
	await page.evaluate(() => {
		document.querySelector('#lo-status').textContent = '';
	});
	await page.click('#lo-run');
	try {
		await page.waitForFunction(
			() => {
				const status = document.querySelector('#lo-status');
				return (
					!document.querySelector('#lo-run').disabled &&
					(/^(Done|Stopped)/.test(status.textContent) || status.classList.contains('lo-error'))
				);
			},
			null,
			{ timeout: 180000 }
		);
	} catch (error) {
		const status = await page.locator('#lo-status').textContent();
		const corpus = await page.inputValue('#lo-corpus');
		throw new Error(
			`the run on ${corpus} at ${page.url()} did not start and end (status: ${status}): ${error.message}`
		);
	}
	return page.locator('#lo-status').textContent();
}

/**
 * Waits for the library comparison that follows a run, and checks its card:
 * a verdict naming the best existing layout, five alike layouts with their
 * bars, and labelled buttons to open each one.
 * @returns {Promise<string>} The verdict's words.
 */
async function libraryToEnd(page) {
	await page.waitForFunction(
		() =>
			document.querySelector('#lo-library-body .lo-library-content') ||
			document.querySelector('#lo-library-status.lo-error'),
		null,
		{ timeout: 180000 }
	);
	const status = await page.locator('#lo-library-status').textContent();
	assert.match(status, /library layouts scored/, `the library is compared: ${status}`);
	const card = await page.evaluate(() => {
		const body = document.querySelector('#lo-library-body');
		return {
			verdict: body.querySelector('.lo-library-verdict').textContent,
			best: body.querySelector('.lo-library-best .lo-library-name').textContent,
			items: body.querySelectorAll('.lo-library-item').length,
			bars: Array.from(
				body.querySelectorAll('.lo-library-item .lo-bar-key'),
				(bar) => bar.offsetWidth
			),
			labels: Array.from(body.querySelectorAll('button[data-open]'), (button) =>
				button.getAttribute('aria-label')
			)
		};
	});
	assert.ok(card.verdict.includes(card.best), `the verdict names ${card.best}: ${card.verdict}`);
	assert.equal(card.items, 5, 'five alike layouts');
	assert.ok(
		card.bars.every((width) => width > 0),
		`every alike layout has its bar: ${card.bars}`
	);
	assert.equal(card.labels.length, 12, 'a Compare and an Edit button per layout');
	assert.ok(
		card.labels.every((label) => /^(Compare|Edit) ./.test(label)),
		`the buttons name their layout: ${card.labels.join(', ')}`
	);
	return card.verdict;
}

/**
 * (progress-chart) A run draws the best score over its time while it runs:
 * a step line above the start's dashed line that gains points as the search
 * reports, its summary in words (the score, the gain, the evaluations per
 * second) and its points as a table with their units; the drawing itself is
 * hidden from assistive technology, the figure named by its caption.
 */
async function exerciseProgressChart(browser, origin) {
	const { page, errors, context } = await open(browser, origin);
	assert.equal(await page.isHidden('#lo-chart'), true, 'no chart before a run');
	await page.evaluate(() => {
		document.querySelector('.lo-advanced').open = true;
	});
	// A run long enough to report several times: two seconds of one restart.
	await page.fill('#lo-seconds', '2');
	await page.fill('#lo-iterations', '1000000');
	await page.fill('#lo-restarts', '1');
	await page.click('#lo-run');
	await page.waitForSelector('#lo-chart .lo-chart-line', { timeout: 120000 });
	const live = [];
	while (await page.isEnabled('#lo-stop')) {
		live.push(await page.locator('#lo-chart-rows tr').count());
		await page.waitForTimeout(150);
	}
	assert.ok(live.length > 0, 'the chart is drawn while the search runs');
	await page.waitForFunction(() => !document.querySelector('#lo-run').disabled);
	const chart = await page.evaluate(() => ({
		hidden: document.getElementById('lo-chart-svg').getAttribute('aria-hidden'),
		caption: document.querySelector('#lo-chart figcaption').textContent,
		labelled: document.getElementById('lo-chart').getAttribute('aria-labelledby'),
		path: document.querySelector('.lo-chart-line').getAttribute('d'),
		start: Boolean(document.querySelector('.lo-chart-start')),
		dot: Boolean(document.querySelector('.lo-chart-dot')),
		ticks: Array.from(document.querySelectorAll('.lo-chart-tick'), (n) => n.textContent),
		summary: document.getElementById('lo-chart-summary').textContent,
		rows: Array.from(document.querySelectorAll('#lo-chart-rows tr'), (tr) =>
			Array.from(tr.cells, (cell) => cell.textContent)
		)
	}));
	assert.equal(chart.hidden, 'true', 'the drawing is hidden from assistive technology');
	assert.equal(chart.caption, 'Best score over time');
	assert.equal(chart.labelled, 'lo-chart-title');
	assert.ok(chart.start && chart.dot, 'the start line and the last point are drawn');
	assert.ok((chart.path.match(/ V /g) || []).length >= 2, `a line of points: ${chart.path}`);
	assert.ok(
		chart.ticks.some((tick) => /^\d+\u00a0s$/.test(tick)),
		`the time axis has its unit: ${chart.ticks}`
	);
	assert.match(
		chart.summary,
		/^Best score -?\d[\d,]*\.\d\d\u00a0points, [+-]?\d[\d,]*\.\d\d\u00a0points over the start; last gain at \d+\.\d\u00a0s\. \d[\d,]*\u00a0layouts scored per second\.$/,
		`the chart in words: ${JSON.stringify(chart.summary)}`
	);
	assert.ok(chart.rows.length >= 2, `the table lists the points: ${chart.rows.length}`);
	for (const [time, best, gain] of chart.rows) {
		assert.match(time, /^\d+\.\d\u00a0s$/, time);
		assert.match(best, /\u00a0points$/, best);
		assert.match(gain, /^[+-]?\d[\d,]*\.\d\d\u00a0points$/, gain);
	}
	// The pointer over the drawing shows the point under it.
	const box = await page.locator('#lo-chart-svg').boundingBox();
	await page.hover('#lo-chart-svg', { position: { x: box.width * 0.9, y: box.height / 2 } });
	assert.match(await page.textContent('#lo-chart-tip'), / s · .* points$/);
	await page.mouse.move(0, 0);
	assert.equal(await page.isHidden('#lo-chart-tip'), true, 'leaving the drawing hides it');
	assert.deepEqual(errors, []);
	await context.close();
}

async function main() {
	const server = await serve();
	const origin = `http://127.0.0.1:${server.address().port}`;
	const browser = await chromium.launch();
	try {
		// ======= 0/ Framed by the site: the page posts its height =======
		// (mount's options were shadowed by an inner options() until 2026-11-17:
		// the frame never heard the height, nor the app window's host hooks.)
		{
			const context = await browser.newContext();
			const page = await context.newPage();
			await page.route(`${origin}/frame.html`, (route) =>
				route.fulfill({
					contentType: 'text/html',
					body:
						'<!doctype html><script>window.heights = [];' +
						"addEventListener('message', (e) => { if (e.data && e.data.type === 'ergopti-layout-optimizer:height') window.heights.push(e.data.height); });" +
						`</script><iframe src="${PAGE}?lang=en" style="width:900px;height:400px"></iframe>`
				})
			);
			await page.goto(`${origin}/frame.html`);
			await page.waitForFunction(() => window.heights.length > 0, null, { timeout: 60000 });
			const height = await page.evaluate(() => Math.max(...window.heights));
			assert.ok(height > 400, `the framed page reports its height (${height})`);
			await context.close();
		}

		// ======= 1/ Corpus: a pasted text, a file, and their refusals =======
		{
			const { page, errors, context } = await open(browser, origin);
			assert.equal(await page.locator('#lo-custom').isHidden(), true, 'the text box waits');
			await page.selectOption('#lo-corpus', 'custom');
			assert.equal(await page.locator('#lo-custom').isVisible(), true, 'the text box shows');
			await page.fill('#lo-text', 'trop court');
			await page.waitForFunction(() => document.querySelector('#lo-text-status').textContent);
			assert.match(await textStatus(page), /at least 200/, 'a short text is refused in words');
			assert.equal(
				await page.locator('#lo-text-status').evaluate((n) => n.classList.contains('lo-error')),
				true
			);
			// A run without a usable text says why instead of starting.
			await page.click('#lo-run');
			assert.match(
				await page.locator('#lo-status').textContent(),
				/Paste a text or open a file/,
				'a run without a text is refused'
			);
			await page.fill('#lo-text', TEXT);
			await page.waitForFunction(() =>
				/characters, counted/.test(document.querySelector('#lo-text-status').textContent)
			);
			// A file of a type the page cannot read, then a text file.
			await page.setInputFiles('#lo-file', {
				name: 'notes.xyz',
				mimeType: 'application/octet-stream',
				buffer: Buffer.from('x')
			});
			await page.waitForFunction(() =>
				/cannot read this type|can’t|cannot/i.test(
					document.querySelector('#lo-text-status').textContent
				)
			);
			await page.setInputFiles('#lo-file', {
				name: 'swann.txt',
				mimeType: 'text/plain',
				buffer: Buffer.from(TEXT.repeat(3), 'utf8')
			});
			await page.waitForFunction(() =>
				/characters, counted/.test(document.querySelector('#lo-text-status').textContent)
			);
			assert.equal(await page.inputValue('#lo-text'), TEXT.repeat(3), 'the file fills the box');
			// A file over the size limit is refused before it is read.
			await page.evaluate(() => {
				const input = document.querySelector('#lo-file');
				const big = new File(['x'], 'big.txt', { type: 'text/plain' });
				Object.defineProperty(big, 'size', { value: 60 * 1024 * 1024 });
				const transfer = new DataTransfer();
				transfer.items.add(big);
				input.files = transfer.files;
				input.dispatchEvent(new Event('change'));
			});
			await page.waitForFunction(() =>
				/up to 50\sMB/.test(document.querySelector('#lo-text-status').textContent)
			);
			await page.fill('#lo-text', TEXT.repeat(2));
			await shortBudget(page);
			const status = await runToEnd(page);
			assert.match(status, /^Done/, `the run on the pasted text ends: ${status}`);
			assert.equal(await page.locator('#lo-result').isVisible(), true, 'the result shows');
			assert.match(await page.locator('#lo-score').textContent(), /\d/, 'a score shows');
			// The library, scored in a worker on the same corpus, and its card.
			await libraryToEnd(page);
			const best = await page
				.locator('#lo-library-body .lo-library-best .lo-library-name')
				.textContent();
			// The layout handed to « Compare »: caught before the page leaves.
			await page.evaluate(() => {
				window.LAYOUT_ANALYSIS_FILES.handOff = (layout) => {
					window.__handed = layout;
					throw Object.assign(new Error('kept'), { code: 'studio_handoff_failed' });
				};
			});
			await page.click('#lo-library-body .lo-library-best button[data-open="comparer"]');
			const handed = await page.evaluate(() => window.__handed);
			assert.equal(handed && handed.name, best, 'Compare hands the library layout over');
			assert.deepEqual(errors, []);
			await context.close();
		}

		// ======= 2/ Zones: a letter kept on the keys clicked on the board =======
		{
			const { page, errors, context } = await open(browser, origin);
			// The zones are one sub-tab of « What may move »: one board at a time.
			assert.equal(await page.locator('#lo-zone-board').isHidden(), true, 'zones wait');
			await page.click('#lo-tab-zones');
			assert.equal(await page.locator('#lo-pin-board').isHidden(), true, 'one board shows');
			await page.selectOption('#lo-zone-char', 'e');
			// AZERTY's e is on KeyE: a zone that leaves it out moves it first.
			await page.click('#lo-zone-board [data-code="KeyJ"]');
			await page.click('#lo-zone-board [data-code="KeyK"]');
			assert.match(
				await page.locator('#lo-zones-summary').textContent(),
				/e: 2\skeys/,
				'the zone is summed up'
			);
			assert.equal(
				await page.locator('#lo-zone-board [data-code="KeyJ"]').getAttribute('aria-pressed'),
				'true'
			);
			await shortBudget(page);
			const status = await runToEnd(page);
			assert.match(status, /^Done/, `the zoned run ends: ${status}`);
			const legends = await page.$$eval('#lo-result-board [data-code]', (keys) =>
				Object.fromEntries(keys.map((key) => [key.dataset.code, key.textContent]))
			);
			assert.ok(
				legends.KeyJ === 'e' || legends.KeyK === 'e',
				`e ends in its zone: J ${legends.KeyJ}, K ${legends.KeyK}`
			);
			// Clearing the zone empties the summary.
			await page.click('#lo-zone-clear');
			assert.match(await page.locator('#lo-zones-summary').textContent(), /No zone/);
			assert.deepEqual(errors, []);
			await context.close();
		}

		// ======= 3/ The choices survive a reload; refused storage keeps the page working =======
		{
			const { page, errors, context } = await open(browser, origin);
			await page.selectOption('#lo-start', 'qwerty');
			await page.selectOption('#lo-corpus', 'custom');
			await page.fill('#lo-text', TEXT);
			await page.waitForFunction(() =>
				/characters, counted/.test(document.querySelector('#lo-text-status').textContent)
			);
			await page.check('#lo-switch-altgr');
			await page.click('.lo-advanced summary');
			await page.fill('#lo-seed', '7');
			await page.locator('#lo-seed').dispatchEvent('change');
			await page.click('#lo-pin-board [data-code="KeyA"]');
			await page.click('#lo-tab-zones');
			await page.selectOption('#lo-zone-char', 'e');
			await page.click('#lo-zone-board [data-code="KeyD"]');
			await page.reload();
			await page.waitForFunction(() => document.querySelector('#lo-zone-board [data-code]'));
			assert.equal(await page.inputValue('#lo-start'), 'qwerty', 'the start is kept');
			assert.equal(await page.inputValue('#lo-corpus'), 'custom', 'the corpus is kept');
			assert.equal(await page.inputValue('#lo-text'), TEXT, 'the text is kept');
			assert.equal(await page.isChecked('#lo-switch-altgr'), true, 'a switch is kept');
			assert.equal(await page.inputValue('#lo-seed'), '7', 'the seed is kept');
			assert.equal(
				await page.locator('#lo-pin-board [data-code="KeyA"]').getAttribute('aria-pressed'),
				'true',
				'a pinned key is kept'
			);
			assert.match(await page.locator('#lo-zones-summary').textContent(), /e: 1\skeys/);
			assert.equal(
				await page.locator('#lo-tab-zones').getAttribute('aria-selected'),
				'true',
				'the sub-tab is kept'
			);
			assert.deepEqual(errors, []);
			await context.close();
		}
		{
			const { page, errors, context } = await open(browser, origin, { blockStorage: true });
			await page.selectOption('#lo-corpus', 'custom');
			await page.fill('#lo-text', TEXT);
			await page.waitForFunction(() =>
				/characters, counted/.test(document.querySelector('#lo-text-status').textContent)
			);
			await page.check('#lo-switch-altgr');
			await page.click('#lo-pin-board [data-code="KeyA"]');
			await shortBudget(page);
			const status = await runToEnd(page);
			assert.match(status, /^Done/, `without storage the run ends: ${status}`);
			assert.deepEqual(errors, [], 'refused storage raises no page error');
			await context.close();
		}

		// ======= 4/ The app's Studio window: inlined scripts, « My typing », its own tabs =======
		// The macOS and Linux hosts inline every script and seed the strings: the
		// page has no script URL, so it runs the search on the page, never in a worker.
		{
			const context = await browser.newContext({ viewport: { width: 1180, height: 820 } });
			const page = await context.newPage();
			const errors = [];
			page.on('pageerror', (error) => errors.push(error.message));
			page.on('request', (request) => {
				if (!request.url().startsWith(origin + '/'))
					errors.push(`unexpected request: ${request.url()}`);
			});
			const inline = (file) =>
				fs
					.readFileSync(shared('ui', ...file.split('/')), 'utf8')
					.replace(/<\/script/gi, '<\\/script');
			const strings = JSON.parse(
				fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
			);
			const html =
				// The app's window declares its language, as layout_editor_window/index.html does.
				'<!doctype html><html lang="en"><head><meta charset="utf-8" />' +
				`<style>${inline('theme.css')}${inline('layout_optimizer/style.css')}</style>` +
				`<script>window._i18n_strings = ${JSON.stringify(strings).replace(/</g, '\\u003c')};` +
				'window.__workers = 0; const NativeWorker = window.Worker;' +
				'window.Worker = function (...args) { window.__workers += 1; return new NativeWorker(...args); };</script>' +
				[
					'_generated/key_legend.js',
					'layout_analysis/_generated/analysis_data.js',
					'layout_analysis/analysis_engine.js',
					'layout_analysis/pdf_text.js',
					'layout_analysis/info_popover.js',
					'layout_analysis/undo_offer.js',
					'layout_analysis/fingering_editor.js',
					'layout_analysis/corpus_files.js',
					'layout_analysis/score_settings.js',
					'layout_optimizer/optimizer_core.js',
					'layout_optimizer/optimizer_runner.js',
					'layout_optimizer/optimizer_page.js'
				]
					.map((file) => `<script>${inline(file)}</script>`)
					.join('') +
				'</head><body><section id="studio-optimizer"></section></body></html>';
			await page.route(`${origin}/studio-window.html`, (route) =>
				route.fulfill({ body: html, contentType: 'text/html; charset=utf-8' })
			);
			await page.goto(`${origin}/studio-window.html`);
			// The window reads the keystats before the tab first opens.
			await page.evaluate((text) => {
				const ngrams = Object.assign(window.LAYOUT_ANALYSIS.ngramsFromText(text), { total: 1 });
				document.dispatchEvent(new CustomEvent('studio-ngrams', { detail: ngrams }));
				window.__opened = [];
				window.LAYOUT_OPTIMIZER_PAGE.mount(document.getElementById('studio-optimizer'), {
					host: {
						openEditor: (layout) => window.__opened.push(['edit', layout.id]),
						openComparer: (layout) => window.__opened.push(['compare', layout.id])
					}
				});
			}, TEXT.repeat(4));
			assert.equal(await page.inputValue('#lo-corpus'), 'my_typing', '« My typing » is chosen');
			assert.equal(
				await page.locator('#lo-corpus option[value="my_typing"]').textContent(),
				'My typing'
			);
			await shortBudget(page);
			const status = await runToEnd(page);
			assert.match(status, /^Done/, `the inlined run ends: ${status}`);
			assert.equal(await page.evaluate(() => window.__workers), 0, 'no worker in an inlined page');
			await page.click('#lo-open-editor');
			await page.click('#lo-open-comparer');
			assert.deepEqual(
				await page.evaluate(() => window.__opened),
				[
					['edit', 'azerty_optimized'],
					['compare', 'azerty_optimized']
				],
				'the result opens in the window’s own tabs'
			);
			assert.deepEqual(errors, []);
			await context.close();
		}

		// ======= 4b/ A host page with no language, and runs that fail =======
		// A page that declared no language made the number formatter throw in
		// the middle of run(), and the page stayed on « Loading the corpus… »
		// with no message (until 2026-11-17). Now its numbers follow the
		// language of its strings (English here, info_popover.js locale(), the
		// fallback language only without strings), and a stage that fails says
		// so in words with « Try again ».
		{
			const context = await browser.newContext({ viewport: { width: 1180, height: 820 } });
			const page = await context.newPage();
			const errors = [];
			page.on('pageerror', (error) => errors.push(error.message));
			const inline = (file) =>
				fs
					.readFileSync(shared('ui', ...file.split('/')), 'utf8')
					.replace(/<\/script/gi, '<\\/script');
			const strings = JSON.parse(
				fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
			);
			const html =
				'<!doctype html><html><head><meta charset="utf-8" />' +
				`<style>${inline('theme.css')}${inline('layout_optimizer/style.css')}</style>` +
				`<script>window._i18n_strings = ${JSON.stringify(strings).replace(/</g, '\\u003c')};</script>` +
				[
					'_generated/key_legend.js',
					'layout_analysis/_generated/analysis_data.js',
					'layout_analysis/analysis_engine.js',
					'layout_analysis/pdf_text.js',
					'layout_analysis/info_popover.js',
					'layout_analysis/undo_offer.js',
					'layout_analysis/fingering_editor.js',
					'layout_analysis/corpus_files.js',
					'layout_analysis/score_settings.js',
					'layout_optimizer/optimizer_core.js',
					'layout_optimizer/optimizer_runner.js',
					'layout_optimizer/optimizer_page.js'
				]
					.map((file) => `<script>${inline(file)}</script>`)
					.join('') +
				'</head><body><section id="studio-optimizer"></section></body></html>';
			await page.route(`${origin}/no-language.html`, (route) =>
				route.fulfill({ body: html, contentType: 'text/html; charset=utf-8' })
			);
			await page.goto(`${origin}/no-language.html`);
			assert.equal(await page.evaluate(() => document.documentElement.lang), '', 'no language');
			await page.evaluate((text) => {
				const ngrams = Object.assign(window.LAYOUT_ANALYSIS.ngramsFromText(text), { total: 1 });
				window.LAYOUT_OPTIMIZER_PAGE.mount(document.getElementById('studio-optimizer'));
				document.dispatchEvent(new CustomEvent('studio-ngrams', { detail: ngrams }));
			}, TEXT.repeat(4));
			await shortBudget(page);
			let status = await runToEnd(page);
			assert.match(
				status,
				/^Done: \d+\slayouts scored in \d+\.\d\ss$/,
				`the strings’ numbers: ${status}`
			);
			assert.match(await page.locator('#lo-score').textContent(), /\d\.\d\d/, 'the score shows');
			// The library is scored on this page's thread: the engine is idle after it.
			await libraryToEnd(page);

			// Measuring the start fails once: the reason shows, then « Try again » runs.
			await page.evaluate(() => {
				const engine = window.LAYOUT_ANALYSIS;
				const analyse = engine.analyse;
				engine.analyse = () => {
					engine.analyse = analyse;
					throw new Error('injected failure');
				};
			});
			status = await runToEnd(page);
			assert.match(
				status,
				/^The start layout could not be measured: injected failure$/,
				`a failing stage says so: ${status}`
			);
			assert.equal(await page.locator('#lo-retry').isVisible(), true, '« Try again » shows');
			assert.equal(await page.locator('#lo-run').isDisabled(), false, 'Optimize is back');
			await page.evaluate(() => {
				document.querySelector('#lo-status').textContent = '';
			});
			await page.click('#lo-retry');
			await page.waitForFunction(
				() =>
					/^Done/.test(document.querySelector('#lo-status').textContent) &&
					!document.querySelector('#lo-run').disabled,
				null,
				{ timeout: 180000 }
			);
			assert.equal(await page.locator('#lo-retry').isHidden(), true, '« Try again » hides');
			assert.deepEqual(errors, [], 'a failing stage raises no page error');
			await context.close();
		}
		// A built-in corpus that cannot load says so, with « Try again ».
		{
			const { page, errors, context } = await open(browser, origin);
			const script = await page.evaluate(
				(id) => window.LAYOUT_ANALYSIS_DATA.corpora.find((corpus) => corpus.id === id).script,
				await page.inputValue('#lo-corpus')
			);
			const blocked = `**/${path.posix.basename(script)}`;
			await page.route(blocked, (route) => route.abort());
			await shortBudget(page);
			const status = await runToEnd(page);
			assert.match(status, /^The corpus could not be loaded: /, `a corpus failure: ${status}`);
			assert.equal(await page.locator('#lo-retry').isVisible(), true, '« Try again » shows');
			assert.deepEqual(errors, [], 'a corpus failure raises no page error');
			await context.close();
		}

		// ======= 4c/ The Comparer's score settings are the optimizer's =======
		// Until 2026-11-18 the optimizer kept weights of its own and scored
		// without the Comparer's ideal load, shortcut table, compact keyboards
		// and fingering: the same layout had two scores in the Studio.
		{
			const { page, errors, context } = await open(browser, origin);
			assert.equal(
				await page.locator('#lo-settings-list .lo-custom-setting').count(),
				0,
				'every setting is the default'
			);
			await shortBudget(page);
			let status = await runToEnd(page);
			assert.match(status, /^Done/, `the default run ends: ${status}`);
			const startTile = () => page.locator('#lo-score .lo-tile-value').first().textContent();
			const before = await startTile();
			// The Comparer saves a raised SFB weight and tells the page, as its save() does.
			await page.evaluate(() => {
				const weights = window.LAYOUT_ANALYSIS.defaultWeights();
				weights.sfb *= 3;
				window.localStorage.setItem(
					window.LAYOUT_ANALYSIS_FILES.SETTINGS_KEY,
					JSON.stringify({ weights })
				);
				window.LAYOUT_ANALYSIS_SCORE_SETTINGS.notify();
			});
			assert.match(
				await page.locator('#lo-settings-list .lo-custom-setting').textContent(),
				/Weights.*your own/,
				'the summary follows the Comparer'
			);
			status = await runToEnd(page);
			assert.match(status, /^Done/, `the weighted run ends: ${status}`);
			const after = await startTile();
			assert.notEqual(after, before, 'a Comparer weight changes the optimizer score');
			// The score is the engine's with the Comparer's weights, as the Comparer shows it.
			const expected = await page.evaluate(async () => {
				const E = window.LAYOUT_ANALYSIS;
				const corpus = window.LAYOUT_ANALYSIS_DATA.corpora.find(
					(c) => c.id === document.querySelector('#lo-corpus').value
				);
				const tables = await window.LAYOUT_ANALYSIS_FILES.builtinTables(corpus);
				const weights = E.defaultWeights();
				weights.sfb *= 3;
				const azerty = E.libraryLayouts().find((layout) => layout.id === 'azerty');
				return E.analyse(azerty, tables, {
					keyboard: 'iso',
					weights,
					format: E.defaultKeyboardFormat()
				}).score.total;
			});
			assert.equal(after, expected.toFixed(2), 'the start score is the Comparer score');
			assert.deepEqual(errors, []);
			await context.close();
		}

		// ======= 4d/ Ctrl Z X C V stay on QWERTY's keys while the letters move =======
		{
			const { page, errors, context } = await open(browser, origin);
			await page.click('#lo-tab-shortcuts');
			await page.check('input[name="lo-shortcut-mode"][value="shortcut"]');
			await page.click('#lo-qwerty-presets button >> nth=0');
			assert.equal(
				await page.locator('#lo-qwerty-board [data-code="KeyZ"]').getAttribute('aria-pressed'),
				'true',
				'the preset marks Z'
			);
			await shortBudget(page);
			const status = await runToEnd(page);
			assert.match(status, /^Done/, `the shortcut run ends: ${status}`);
			// The layout handed to « Compare » is the result: catch it before the page leaves.
			await page.evaluate(() => {
				window.LAYOUT_ANALYSIS_FILES.handOff = (layout) => {
					window.__handed = layout;
					throw Object.assign(new Error('kept'), { code: 'studio_handoff_failed' });
				};
			});
			await page.click('#lo-open-comparer');
			const layout = await page.evaluate(() => window.__handed);
			const kept = { z: 'KeyZ', x: 'KeyX', c: 'KeyC', v: 'KeyV' };
			for (const [letter, code] of Object.entries(kept))
				assert.ok(
					layout.rows[code][0] === letter || layout.command[code] === letter,
					`Ctrl+${letter} stays on ${code}: ${JSON.stringify(layout.command)}`
				);
			assert.ok(Object.keys(layout.command).length > 0, 'some kept shortcut left its letter');
			assert.deepEqual(errors, []);
			await context.close();
		}

		// ======= 4e/ The search's progress as a live chart =======
		await exerciseProgressChart(browser, origin);

		// ======= 5/ Light and dark at phone width, every locale =======
		for (const colorScheme of ['light', 'dark']) {
			const { page, errors, context } = await open(browser, origin, {
				viewport: PHONE,
				colorScheme
			});
			// With a result and its library card on the page.
			await page.selectOption('#lo-corpus', 'custom');
			await page.fill('#lo-text', TEXT.repeat(2));
			await shortBudget(page);
			assert.match(await runToEnd(page), /^Done/, `${colorScheme}: the phone run ends`);
			await libraryToEnd(page);
			const overflow = await page.evaluate(
				() => document.documentElement.scrollWidth - document.documentElement.clientWidth
			);
			assert.ok(overflow <= 0, `${colorScheme}: the page scrolls sideways by ${overflow}px`);
			const background = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
			const ink = await page.evaluate(() => getComputedStyle(document.body).color);
			assert.notEqual(background, ink, `${colorScheme}: text and background differ`);
			if (colorScheme === 'dark')
				assert.notEqual(background, 'rgb(255, 255, 255)', 'dark: the background is dark');
			assert.deepEqual(errors, []);
			await context.close();
		}
		for (const lang of LOCALES) {
			const { page, errors, context } = await open(browser, origin, { lang });
			await page.selectOption('#lo-corpus', 'custom');
			const raw = await page.evaluate(() => {
				const out = [];
				const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
				for (let node = walker.nextNode(); node; node = walker.nextNode())
					if (/\b(layout_optimizer|layout_analysis)\.[a-z_.]+/.test(node.textContent))
						out.push(node.textContent.trim());
				for (const node of document.querySelectorAll('[placeholder]'))
					if (/^layout_/.test(node.placeholder)) out.push(node.placeholder);
				return out;
			});
			assert.deepEqual(raw, [], `${lang}: raw keys shown`);
			assert.deepEqual(errors, [], `${lang}: page errors`);
			await context.close();
		}
	} finally {
		await browser.close();
		server.close();
	}
	console.log('PASS layout-optimizer.playwright');
}

module.exports = { exerciseProgressChart };

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exit(1);
	});
