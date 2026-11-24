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
	// A ResizeObserver loop is an error event with no exception behind it, so
	// Playwright's pageerror never sees it: the page says it on the console.
	await page.addInitScript(() => {
		window.addEventListener('error', (event) => {
			if (!event.error) console.error(`window error: ${event.message}`);
		});
	});
	page.on('console', (message) => {
		if (message.type() === 'error' && message.text().startsWith('window error: '))
			errors.push(message.text());
	});
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
			document.querySelector('#lo-library-body .lo-library-verdict') ||
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
		/^Best score -?\d[\d,]*\.\d\d, [+-]?\d[\d,]*\.\d\d\u00a0points over the start; last gain at \d+\.\d\u00a0s\. \d[\d,]*\u00a0layouts scored per second\.$/,
		`the chart in words: ${JSON.stringify(chart.summary)}`
	);
	assert.ok(chart.rows.length >= 2, `the table lists the points: ${chart.rows.length}`);
	for (const [time, best, gain] of chart.rows) {
		assert.match(time, /^\d+\.\d\u00a0s$/, time);
		// The best is a mark (an index on QWERTY, no unit), its gain in points.
		assert.match(best, /^-?\d[\d,]*\.\d\d$/, best);
		assert.match(gain, /^[+-]?\d[\d,]*\.\d\d\u00a0points$/, gain);
	}
	// The pointer over the drawing shows the point under it.
	const box = await page.locator('#lo-chart-svg').boundingBox();
	await page.hover('#lo-chart-svg', { position: { x: box.width * 0.9, y: box.height / 2 } });
	assert.match(await page.textContent('#lo-chart-tip'), /\u00a0s · -?\d[\d,]*\.\d\d$/);
	await page.mouse.move(0, 0);
	assert.equal(await page.isHidden('#lo-chart-tip'), true, 'leaving the drawing hides it');
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (result-board-table) The start and best boards have a table view of their
 * own, their text alternative: folded under its summary, a focusable region
 * named by it, a row per drawn key in reading order headed by where the key
 * is, what it types on each layout (as the boards draw it, a dead key and
 * Space in words) and whether it changed, in words, marking the same keys as
 * the dashed outline. Until 2026-11-19 only « Open in the editor » gave one.
 */
async function exerciseResultTable(browser, origin) {
	const { page, errors, context } = await open(browser, origin);
	await shortBudget(page);
	assert.match(await runToEnd(page), /^Done/);
	const summary = page.locator('#lo-board-table > summary');
	assert.equal(await summary.textContent(), 'Show both layouts as a table');
	assert.equal(await page.locator('#lo-board-table').getAttribute('open'), null, 'folded');
	await summary.click();
	const region = page.getByRole('region', { name: 'Show both layouts as a table' });
	assert.equal(await region.getAttribute('tabindex'), '0', 'the region takes the focus');
	const view = await page.evaluate(() => {
		const drawn = (id) =>
			new Map(
				Array.from(document.querySelectorAll(`#${id} .lo-key`), (key) => [
					key.dataset.code,
					{ text: key.textContent, changed: key.classList.contains('lo-changed') }
				])
			);
		const cols = Array.from(
			document.querySelectorAll('#lo-board-table thead th'),
			(th) => `${th.getAttribute('scope')}:${th.textContent}`
		);
		const rows = Array.from(document.querySelectorAll('#lo-board-rows tr'), (tr) => ({
			code: tr.dataset.code,
			scope: tr.cells[0].getAttribute('scope'),
			// What a screen reader says: the mark's glyph is hidden from it.
			cells: Array.from(tr.cells, (cell) => {
				const said = cell.cloneNode(true);
				for (const hidden of said.querySelectorAll('[aria-hidden="true"]')) hidden.remove();
				return said.textContent.trim();
			}),
			glyph: (tr.cells[3].querySelector('[aria-hidden="true"]') || {}).textContent,
			changed: tr.classList.contains('lo-board-row-changed')
		}));
		return {
			cols,
			rows,
			start: Object.fromEntries(drawn('lo-start-board')),
			best: Object.fromEntries(drawn('lo-result-board')),
			count: document.querySelector('#lo-changed').textContent
		};
	});
	assert.deepEqual(view.cols, [
		'col:Key',
		'col:Start layout',
		'col:Best layout',
		'col:Key changed'
	]);
	assert.equal(view.rows.length, Object.keys(view.best).length, 'a row per drawn key');
	const spoken = (text, code) => (code === 'Space' ? 'Space' : text);
	let changed = 0;
	view.rows.forEach((row, index) => {
		assert.equal(row.scope, 'row', `${row.code}: its place heads the row`);
		assert.match(row.cells[0], /^row \d+, key \d+$/, `${row.code}: ${row.cells[0]}`);
		const start = view.start[row.code];
		const best = view.best[row.code];
		for (const [cell, key] of [
			[row.cells[1], start],
			[row.cells[2], best]
		])
			if (/^dead key /.test(cell)) assert.ok(cell.endsWith(key.text), `${row.code}: ${cell}`);
			else assert.equal(cell, spoken(key.text, row.code), `${row.code}: as the board draws it`);
		assert.equal(row.changed, best.changed, `${row.code}: marked as the board outlines it`);
		assert.equal(row.cells[3], best.changed ? 'Changed' : 'Unchanged', row.code);
		assert.equal(row.glyph, best.changed ? '⇄' : '·', `${row.code}: its mark, not colour alone`);
		if (row.changed) changed += 1;
		if (index > 0) assert.notEqual(row.cells[0], view.rows[index - 1].cells[0], 'one row a key');
	});
	assert.ok(changed > 0, 'the search moved some key');
	assert.match(view.count, new RegExp(`^${changed}\\u00a0keys changed`), view.count);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (thumb-keys-switch) The thumb keys' switch is off by default and disabled
 * on a keyboard without thumb keys, whose help line names the keyboards
 * that have them; its « i » opens a popover that says why it is off by
 * default and gives the focus back on Escape. On the Corne it can be
 * switched on: the run's problem then places the Corne's thumb keys, the
 * choice is kept across a reload, and switching to ISO leaves it out.
 */
async function exerciseThumbKeys(browser, origin) {
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	const { page, errors, context } = await open(browser, origin);
	const thumb = '#lo-switch-thumbKeys';
	await page.selectOption('#lo-keyboard', 'iso');
	assert.equal(await page.isChecked(thumb), false, 'off by default');
	assert.equal(await page.isDisabled(thumb), true, 'disabled on ISO, which has no thumb key');
	const absent = await page.textContent('#lo-thumb-help');
	assert.ok(
		absent.startsWith(
			strings['layout_optimizer.option.thumbKeys.absent'].split('{keyboards}')[0]
		) &&
			absent.includes(strings['layout_analysis.keyboard.corne']) &&
			!absent.includes(strings['layout_analysis.keyboard.ansi']),
		`the help names the keyboards with thumb keys: ${absent}`
	);
	assert.equal(await page.getAttribute(thumb, 'aria-describedby'), 'lo-thumb-help');
	// The « i »: why it is off, in a popover that gives the focus back.
	assert.equal(
		await page.getAttribute('#lo-thumb-why', 'aria-label'),
		strings['layout_optimizer.option.thumbKeys.why_label']
	);
	await page.click('#lo-thumb-why');
	await page.waitForSelector('#la-popover:not([hidden])');
	assert.equal(
		await page.textContent('#la-popover .la-popover-texts'),
		strings['layout_optimizer.option.thumbKeys.why']
	);
	assert.equal(await page.isHidden('#la-popover .la-popover-name'), true, 'a note has no title');
	await page.keyboard.press('Escape');
	assert.equal(await page.isHidden('#la-popover'), true);
	assert.equal(await page.evaluate(() => document.activeElement.id), 'lo-thumb-why');
	// The Corne has thumb keys: the switch is offered and reaches the problem.
	await page.selectOption('#lo-keyboard', 'corne');
	assert.equal(await page.isDisabled(thumb), false, 'enabled on the Corne');
	assert.equal(
		await page.textContent('#lo-thumb-help'),
		strings['layout_optimizer.option.thumbKeys.help']
	);
	await page.check(thumb);
	await page.evaluate(() => {
		const problem = window.LAYOUT_OPTIMIZER.problem;
		window.__thumbKeys = [];
		window.LAYOUT_OPTIMIZER.problem = (engine, layout, options) => {
			window.__thumbKeys.push(options.thumbKeys);
			return problem(engine, layout, options);
		};
	});
	await shortBudget(page);
	assert.match(await runToEnd(page), /^Done/, 'a run with the thumb keys ends');
	assert.deepEqual(await page.evaluate(() => window.__thumbKeys), ['corne']);
	await page.reload();
	await page.waitForSelector(thumb);
	assert.equal(await page.inputValue('#lo-keyboard'), 'corne');
	assert.equal(await page.isChecked(thumb), true, 'the choice is kept across a reload');
	await page.selectOption('#lo-keyboard', 'iso');
	assert.equal(await page.isDisabled(thumb), true);
	await page.evaluate(() => {
		const problem = window.LAYOUT_OPTIMIZER.problem;
		window.__thumbKeys = [];
		window.LAYOUT_OPTIMIZER.problem = (engine, layout, options) => {
			window.__thumbKeys.push(options.thumbKeys);
			return problem(engine, layout, options);
		};
	});
	await shortBudget(page);
	assert.match(await runToEnd(page), /^Done/);
	assert.deepEqual(await page.evaluate(() => window.__thumbKeys), [null], 'ISO: no thumb key');
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (results-shelf) A run keeps its best distinct layouts on a shelf, best
 * first and at most five, each named with its rank, its score, its gain and
 * the keys it moves in words, and buttons that open that very layout in the
 * editor or the Comparer.
 */
/**
 * The search method list: every method of the core is offered, the default
 * one marked, each with its explanation and « i »; the method chosen is the
 * one the search reports it ran (the result says so), and a reload keeps it.
 */
async function exerciseSearchMethod(browser, origin) {
	const { page, errors, context } = await open(browser, origin);
	const methods = await page.evaluate(() => Array.from(window.LAYOUT_OPTIMIZER.METHODS));
	const fallback = await page.evaluate(() => window.LAYOUT_OPTIMIZER.DEFAULT_METHOD);
	const options = await page.$$eval('#lo-method option', (nodes) =>
		nodes.map((node) => ({ value: node.value, text: node.textContent }))
	);
	assert.deepEqual(
		options.map((option) => option.value),
		methods,
		'the list offers every method'
	);
	assert.equal(await page.inputValue('#lo-method'), fallback, 'the default method is chosen');
	assert.match(
		options.find((option) => option.value === fallback).text,
		/\(default\)$/,
		'the default method is marked'
	);
	const seen = new Set();
	for (const method of methods) {
		await page.selectOption('#lo-method', method);
		const help = await page.locator('#lo-method-help').textContent();
		const note = await page.locator('#lo-method-info').getAttribute('data-note');
		assert.ok(help && !help.startsWith('layout_optimizer.'), `${method} is explained: ${help}`);
		assert.ok(note && !note.startsWith('layout_optimizer.'), `${method} has its « i »`);
		assert.ok(!seen.has(help), `${method} has its own explanation`);
		seen.add(help);
	}
	assert.equal(
		await page.getAttribute('#lo-method', 'aria-describedby'),
		'lo-method-help',
		'the list is described by the explanation'
	);
	await page.selectOption('#lo-corpus', 'custom');
	await page.fill('#lo-text', TEXT);
	await page.waitForFunction(() =>
		/characters, counted/.test(document.querySelector('#lo-text-status').textContent)
	);
	await shortBudget(page);
	for (const [method, name] of [
		['tabu', 'Tabu search'],
		['genetic', 'Genetic algorithm']
	]) {
		await page.selectOption('#lo-method', method);
		assert.match(await runToEnd(page), /^Done/, `a ${method} run ends`);
		assert.equal(
			await page.locator('#lo-result-method').textContent(),
			`Found by: ${name}`,
			`the run used ${method}`
		);
	}
	await page.reload();
	await page.waitForFunction(() => document.querySelector('#lo-method option'));
	assert.equal(await page.inputValue('#lo-method'), 'genetic', 'the method is kept');
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseResultsShelf(browser, origin) {
	const { page, errors, context } = await open(browser, origin);
	assert.equal(await page.isHidden('#lo-shelf'), true, 'no shelf before a run');
	await page.evaluate(() => {
		document.querySelector('.lo-advanced').open = true;
	});
	await page.fill('#lo-seconds', '2');
	await page.fill('#lo-iterations', '1000000');
	await page.fill('#lo-restarts', '2');
	assert.match(await runToEnd(page), /^Done/);
	const items = await page.$$eval('#lo-shelf-list .lo-shelf-item', (nodes) =>
		nodes.map((node) => ({
			rank: node.dataset.rank,
			name: node.querySelector('.lo-shelf-name').textContent,
			facts: node.querySelector('.lo-shelf-facts').textContent,
			labels: Array.from(node.querySelectorAll('button'), (b) => b.getAttribute('aria-label'))
		}))
	);
	assert.ok(items.length >= 2 && items.length <= 5, `${items.length} layouts on the shelf`);
	assert.deepEqual(
		items.map((item) => item.rank),
		items.map((_, i) => String(i + 1))
	);
	assert.equal(new Set(items.map((item) => item.name)).size, items.length, 'one name each');
	const scores = items.map((item) => {
		const match =
			/^Score (-?[\d,]+\.\d\d) \([+-]?[\d,]+\.\d\d\u00a0points over the start\) · \d+\u00a0keys moved$/.exec(
				item.facts
			);
		assert.ok(match, `the facts in words: ${JSON.stringify(item.facts)}`);
		return Number(match[1].replace(/,/g, ''));
	});
	assert.ok(
		scores.every((score, i) => i === 0 || scores[i - 1] >= score),
		`best first: ${scores}`
	);
	assert.match(items[0].name, /^AZERTY \(FR\) \(optimized, no\. 1\)$/, items[0].name);
	assert.deepEqual(items[1].labels, [`Edit ${items[1].name}`, `Compare ${items[1].name}`]);
	// The second layout's « Edit » hands that layout over.
	await page.evaluate(() => {
		window.LAYOUT_ANALYSIS_FILES.handOffToEditor = (layout) => {
			window.__handed = layout;
			throw Object.assign(new Error('kept'), { code: 'studio_handoff_failed' });
		};
	});
	await page.click('#lo-shelf-list .lo-shelf-item[data-rank="2"] button[data-shelf="editor"]');
	const handed = await page.evaluate(() => window.__handed);
	assert.equal(handed.name, items[1].name);
	assert.ok(handed.rows && handed.rows.KeyQ, 'a whole layout');
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (change-penalty) « Changes from the start layout »: the presets set the
 * slider, its value is said in words, and « at most N changed characters »
 * holds the run: the result's trade-off says the gain, the characters moved
 * (never more than N), their weighted share and the penalty paid, and lists
 * them most typed first, each bar with its number. The choices survive a
 * reload. On the site, « get it » only downloads (install and emulate say
 * why not), through « Éditer »'s hand-off with the chosen format.
 */
async function exerciseChangePenalty(browser, origin) {
	const { page, errors, context } = await open(browser, origin);
	const strings = JSON.parse(
		fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
	);
	const preset = () =>
		page.$eval('input[name="lo-change-preset"]:checked', (input) => input.value).catch(() => null);
	assert.equal(await preset(), 'free', 'the free preset is the first one');
	assert.equal(await page.inputValue('#lo-change-weight'), '0');
	assert.equal(
		await page.textContent('#lo-change-weight-value'),
		'0.0\u00a0points per % of the typed characters moved'
	);
	assert.equal(await page.isDisabled('#lo-change-max'), true, 'the limit waits for its switch');
	await page.check('input[name="lo-change-preset"][value="few"]');
	assert.equal(await page.inputValue('#lo-change-weight'), '3', 'a preset sets the slider');
	assert.equal(
		await page.getAttribute('#lo-change-weight', 'aria-valuetext'),
		'3.0\u00a0points per % of the typed characters moved'
	);
	// A value of its own ticks no preset.
	await page.$eval('#lo-change-weight', (input) => {
		input.value = '2.5';
		input.dispatchEvent(new Event('input', { bubbles: true }));
	});
	assert.equal(await preset(), null, 'no preset for a value of its own');
	await page.check('input[name="lo-change-preset"][value="few"]');
	await page.check('#lo-change-limit');
	await page.fill('#lo-change-max', '2');
	await page.evaluate(() => {
		document.querySelector('.lo-advanced').open = true;
	});
	await page.fill('#lo-seconds', '4');
	await page.fill('#lo-iterations', '300');
	await page.fill('#lo-restarts', '1');
	assert.match(await runToEnd(page), /^Done/);
	const tradeoff = await page.evaluate(() => ({
		terms: Array.from(document.querySelectorAll('#lo-tradeoff-facts dt'), (n) => n.textContent),
		values: Array.from(document.querySelectorAll('#lo-tradeoff-facts dd'), (n) => n.textContent),
		items: Array.from(document.querySelectorAll('#lo-tradeoff-list li'), (n) => n.textContent),
		bars: Array.from(document.querySelectorAll('#lo-tradeoff-list meter'), (n) =>
			n.getAttribute('aria-hidden')
		),
		meter: document.getElementById('lo-tradeoff-meter').value
	}));
	assert.deepEqual(tradeoff.terms, [
		'Score gain',
		'Characters moved',
		'Typed characters changed (weighted)',
		'Change penalty'
	]);
	const moved = Number(tradeoff.values[1]);
	assert.ok(moved <= 2, `at most 2 characters moved, yet ${moved}`);
	assert.match(tradeoff.values[2], /^\d+\.\d%$/, tradeoff.values[2]);
	// The meter holds the share; its text rounds it to one decimal.
	assert.ok(
		Math.abs(tradeoff.meter - Number(tradeoff.values[2].replace('%', ''))) <= 0.05,
		`the meter ${tradeoff.meter} is the share ${tradeoff.values[2]}`
	);
	if (moved === 0) assert.deepEqual(tradeoff.items, [strings['layout_optimizer.tradeoff.none']]);
	else {
		assert.equal(tradeoff.items.length, moved, `one line per moved character: ${tradeoff.items}`);
		assert.ok(
			tradeoff.items.every((text) => /\d\.\d%/.test(text)),
			`each with its share: ${tradeoff.items}`
		);
		assert.ok(
			tradeoff.bars.every((hidden) => hidden === 'true'),
			'the bars repeat their text'
		);
	}
	// The site downloads only; installing and emulating say why not.
	assert.equal(await page.isDisabled('#lo-get-install'), true);
	assert.equal(await page.isDisabled('#lo-get-emulate'), true);
	assert.equal(
		await page.textContent('#lo-get-install-note'),
		strings['layout_optimizer.get.app_only']
	);
	assert.equal(
		await page.textContent('#lo-get-emulate-note'),
		strings['layout_optimizer.get.app_only']
	);
	await page.evaluate(() => {
		window.LAYOUT_ANALYSIS_FILES.handOffToEditor = (layout, intent) => {
			window.__handed = { id: layout.id, rows: Boolean(layout.rows.KeyQ), intent };
			throw Object.assign(new Error('kept'), { code: 'studio_handoff_failed' });
		};
	});
	await page.selectOption('#lo-get-format', 'klc');
	await page.click('#lo-get-download');
	assert.deepEqual(await page.evaluate(() => window.__handed), {
		id: 'azerty_optimized',
		rows: true,
		intent: { action: 'download', format: 'klc' }
	});
	// The choices come back on the next visit.
	await page.reload();
	await page.waitForFunction(() => {
		const title = document.querySelector('.layout-optimizer h1');
		return title && !title.textContent.startsWith('layout_optimizer.');
	});
	assert.equal(await preset(), 'few');
	assert.equal(await page.isChecked('#lo-change-limit'), true);
	assert.equal(await page.inputValue('#lo-change-max'), '2');
	assert.equal(await page.inputValue('#lo-get-format'), 'klc');
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * The page by keyboard alone: the sub-tabs follow the ARIA tabs pattern
 * (arrows round the list, Home and End, one tab stop); a board of keys is
 * one tab stop whose arrows move between keys, and a key pressed with Enter
 * or Space keeps the focus although the board is drawn again; the score
 * tiles are outputs that stay in place, so each new best score is said.
 */
async function exerciseKeyboard(browser, origin) {
	const { page, errors, context } = await open(browser, origin);
	const focused = () =>
		page.evaluate(() => ({
			id: document.activeElement.id,
			code: document.activeElement.dataset.code || null,
			board: document.activeElement.closest('.lo-board')?.id || null,
			pressed: document.activeElement.getAttribute('aria-pressed'),
			top: document.activeElement.style.top
		}));
	const stops = () =>
		page.$$eval('.lo-tabs [role="tab"]', (tabs) =>
			tabs.filter((tab) => tab.tabIndex === 0).map((tab) => tab.id)
		);

	// The tabs: End, Home, and the arrows going round.
	await page.focus('#lo-tab-pins');
	await page.keyboard.press('End');
	assert.equal((await focused()).id, 'lo-tab-zones', 'End reaches the last tab');
	assert.equal(await page.getAttribute('#lo-tab-zones', 'aria-selected'), 'true');
	assert.equal(await page.locator('#lo-panel-zones').isVisible(), true, 'End shows its panel');
	assert.deepEqual(await stops(), ['lo-tab-zones'], 'one tab stop');
	await page.keyboard.press('Home');
	assert.equal((await focused()).id, 'lo-tab-pins', 'Home reaches the first tab');
	await page.keyboard.press('ArrowLeft');
	assert.equal((await focused()).id, 'lo-tab-zones', 'ArrowLeft goes round to the last tab');
	await page.keyboard.press('ArrowRight');
	assert.equal((await focused()).id, 'lo-tab-pins', 'ArrowRight goes round to the first tab');

	// The fixed keys' board: one tab stop, then the arrows.
	assert.equal(await page.getAttribute('#lo-pin-board', 'role'), 'toolbar');
	const boardStops = await page.$$eval('#lo-pin-board .lo-key', (keys) =>
		keys.filter((key) => key.tabIndex === 0).map((key) => key.dataset.code)
	);
	assert.equal(boardStops.length, 1, `one tab stop on the board: ${boardStops}`);
	await page.keyboard.press('Tab');
	let at = await focused();
	assert.equal(
		at.board,
		'lo-pin-board',
		`Tab from the tabs enters the board: ${JSON.stringify(at)}`
	);
	const first = at.code;
	const firstRow = at.top;
	await page.keyboard.press('ArrowRight');
	at = await focused();
	assert.ok(at.board === 'lo-pin-board' && at.code !== first, `ArrowRight moves on: ${at.code}`);
	assert.equal(at.top, firstRow, 'ArrowRight stays on the row');
	await page.keyboard.press('ArrowLeft');
	assert.equal((await focused()).code, first, 'ArrowLeft comes back');
	await page.keyboard.press('ArrowDown');
	at = await focused();
	assert.ok(
		at.board === 'lo-pin-board' && at.top !== firstRow,
		`ArrowDown goes to the next row: ${at.code}`
	);
	// Up goes to the nearest key of the row above, on a staggered row not always the first.
	await page.keyboard.press('ArrowUp');
	assert.equal((await focused()).top, firstRow, 'ArrowUp comes back to the first row');
	await page.keyboard.press('End');
	at = await focused();
	assert.ok(at.top === firstRow && at.code !== first, `End reaches the row's end: ${at.code}`);
	await page.keyboard.press('Home');
	assert.equal((await focused()).code, first, "Home reaches the row's start");
	await page.keyboard.press('ArrowDown');
	const down = (await focused()).code;
	// Enter pins the key and redraws the board: the focus stays on that key.
	await page.keyboard.press('Enter');
	at = await focused();
	assert.deepEqual(
		[at.board, at.code, at.pressed],
		['lo-pin-board', down, 'true'],
		'Enter pins the key and keeps the focus'
	);
	await page.keyboard.press('Space');
	at = await focused();
	assert.deepEqual([at.code, at.pressed], [down, 'false'], 'Space frees it, focus kept');
	await page.keyboard.press('Tab');
	assert.notEqual((await focused()).board, 'lo-pin-board', 'one Tab leaves the board');

	// The score: three outputs, filled in place by the run.
	await shortBudget(page);
	assert.match(await runToEnd(page), /^Done/);
	const tiles = await page.$$eval('#lo-score dd > output', (outputs) =>
		outputs.map((output) => output.value)
	);
	assert.equal(tiles.length, 3, 'the start, the best and the change are outputs');
	assert.ok(
		tiles.every((value) => /\d/.test(value)),
		`each output holds its number: ${tiles}`
	);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * The page opened on its own (the app's Ergopti+ window) and resized: the
 * boards and the chart are redrawn on the next frame, never inside the
 * ResizeObserver, which raised « ResizeObserver loop completed with
 * undelivered notifications » until 2026-11-22.
 */
async function exerciseResize(browser, origin) {
	const { page, errors, context } = await open(browser, origin);
	await shortBudget(page);
	assert.match(await runToEnd(page), /^Done/);
	const nextFrames = () =>
		page.evaluate(
			() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
		);
	const boards = () => page.locator('#lo-result-board .lo-key').count();
	assert.ok((await boards()) > 0, 'the result board is drawn before the resize');
	for (const width of [1100, 900, 720, 560, 420, 375, 1280]) {
		await page.setViewportSize({ width, height: 900 });
		await nextFrames();
	}
	assert.ok((await boards()) > 0, 'the result board is drawn again after the resize');
	assert.deepEqual(errors, [], 'resizing the page raises no error');
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
					// Every host of the page loads it (test-layout-optimizer-page pins
					// both): a run that ends reads its reduced-motion choice.
					'a11y_prefs.js',
					'_generated/key_legend.js',
					'layout_analysis/_generated/analysis_data.js',
					'layout_analysis/analysis_engine.js',
					'layout_analysis/pdf_text.js',
					'layout_analysis/info_popover.js',
					'layout_analysis/undo_offer.js',
					'edit_history.js',
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
				window.__emulates = false;
				window.LAYOUT_OPTIMIZER_PAGE.mount(document.getElementById('studio-optimizer'), {
					host: {
						openEditor: (layout) => window.__opened.push(['edit', layout.id]),
						openComparer: (layout) => window.__opened.push(['compare', layout.id]),
						exportLayout: (layout, intent) => window.__opened.push(['get', layout.id, intent]),
						emulates: () => window.__emulates
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
			// (optimizer-get-it) « Get it » hands the result to the window's
			// « Éditer » with what to do: a download of the chosen format, an
			// install, an emulation where the driver emulates (said when not).
			assert.equal(await page.isEnabled('#lo-get-install'), true, 'the app installs');
			assert.equal(await page.isEnabled('#lo-get-emulate'), false, 'no emulation on this host');
			assert.equal(
				await page.textContent('#lo-get-emulate-note'),
				strings['layout_optimizer.get.no_emulation']
			);
			assert.equal(
				await page.textContent('#lo-get-install-note'),
				strings['layout_optimizer.get.install_note']
			);
			const formats = await page.$$eval('#lo-get-format option', (options) =>
				options.map((option) => [option.value, option.textContent])
			);
			assert.deepEqual(
				formats.map(([id]) => id),
				await page.evaluate(() =>
					window.LAYOUT_ANALYSIS_FILES.EDITOR_DOWNLOADS.filter((id) => id !== 'nav')
				),
				'the editor’s downloads, in its order'
			);
			assert.ok(
				formats.every(([id, text]) => text === strings[`layout_editor.export.option.${id}`]),
				`each format in the editor’s words: ${JSON.stringify(formats)}`
			);
			await page.selectOption('#lo-get-format', 'kalamine');
			await page.click('#lo-get-download');
			await page.click('#lo-get-install');
			// The driver's emulation, once the window says it has one (read when drawn).
			await page.evaluate(() => {
				window.__emulates = true;
				document.dispatchEvent(new CustomEvent('i18n:applied'));
			});
			assert.equal(await page.isEnabled('#lo-get-emulate'), true, 'the app emulates');
			assert.equal(
				await page.textContent('#lo-get-emulate-note'),
				strings['layout_optimizer.get.emulate_note']
			);
			await page.click('#lo-get-emulate');
			assert.deepEqual(
				(await page.evaluate(() => window.__opened)).slice(2),
				[
					['get', 'azerty_optimized', { action: 'download', format: 'kalamine' }],
					['get', 'azerty_optimized', { action: 'install' }],
					['get', 'azerty_optimized', { action: 'emulate' }]
				],
				'each action hands the layout and its intent to the host'
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
					// Every host of the page loads it (test-layout-optimizer-page pins
					// both): a run that ends reads its reduced-motion choice.
					'a11y_prefs.js',
					'_generated/key_legend.js',
					'layout_analysis/_generated/analysis_data.js',
					'layout_analysis/analysis_engine.js',
					'layout_analysis/pdf_text.js',
					'layout_analysis/info_popover.js',
					'layout_analysis/undo_offer.js',
					'edit_history.js',
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
				}).score.mark;
			});
			// The tile shows the mark (total − zero), grouped by thousands as the page writes numbers.
			assert.equal(
				after.replace(/,/g, ''),
				expected.toFixed(2),
				'the start mark is the Comparer mark'
			);
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

		// ======= 4f/ The thumb keys' switch =======
		await exerciseThumbKeys(browser, origin);

		// ======= 4g/ The results shelf =======
		await exerciseResultsShelf(browser, origin);
		await exerciseSearchMethod(browser, origin);
		await exerciseChangePenalty(browser, origin);

		// ======= 4h/ The result boards as a table =======
		await exerciseResultTable(browser, origin);

		// ======= 4i/ The keyboard: tabs, boards and the live score =======
		await exerciseKeyboard(browser, origin);

		// ======= 4j/ Resized on its own, no ResizeObserver loop =======
		await exerciseResize(browser, origin);

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

module.exports = {
	exerciseProgressChart,
	exerciseThumbKeys,
	exerciseResultsShelf,
	exerciseResultTable,
	exerciseResize
};

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exit(1);
	});
