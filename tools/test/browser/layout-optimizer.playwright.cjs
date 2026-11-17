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
 * browser refuses storage; it lays out at phone width in light and dark
 * without a sideways page scroll; no raw locale key shows in any of the 21
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
				/up to 50 MB/.test(document.querySelector('#lo-text-status').textContent)
			);
			await page.fill('#lo-text', TEXT.repeat(2));
			await shortBudget(page);
			const status = await runToEnd(page);
			assert.match(status, /^Done/, `the run on the pasted text ends: ${status}`);
			assert.equal(await page.locator('#lo-result').isVisible(), true, 'the result shows');
			assert.match(await page.locator('#lo-score').textContent(), /\d/, 'a score shows');
			assert.deepEqual(errors, []);
			await context.close();
		}

		// ======= 2/ Zones: a letter kept on the keys clicked on the board =======
		{
			const { page, errors, context } = await open(browser, origin);
			await page.selectOption('#lo-zone-char', 'e');
			// AZERTY's e is on KeyE: a zone that leaves it out moves it first.
			await page.click('#lo-zone-board [data-code="KeyJ"]');
			await page.click('#lo-zone-board [data-code="KeyK"]');
			assert.match(
				await page.locator('#lo-zones-summary').textContent(),
				/e: 2 keys/,
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
			await page.fill('#lo-seed', '7');
			await page.locator('#lo-seed').dispatchEvent('change');
			await page.click('#lo-pin-board [data-code="KeyA"]');
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
			assert.match(await page.locator('#lo-zones-summary').textContent(), /e: 1 keys/);
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
					'layout_analysis/corpus_files.js',
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

		// ======= 5/ Light and dark at phone width, every locale =======
		for (const colorScheme of ['light', 'dark']) {
			const { page, errors, context } = await open(browser, origin, {
				viewport: PHONE,
				colorScheme
			});
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

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
