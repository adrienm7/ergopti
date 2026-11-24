// tools/test/browser/studio-views.cjs

/**
 * ==============================================================================
 * MODULE: Studio Pareto and Trace Browser Cases
 * DESCRIPTION:
 * The Comparer's « Pareto » and « Trace » tabs (ideas seen in the Layouts Wiki
 * playground, docs/audits/layout-analysers/layouts-wiki-playground.md), driven
 * in Chromium by layout-editor.playwright.cjs on its loopback server.
 *
 * WHAT IS CHECKED:
 * 1. Pareto: the table lists every compared complete layout with its layer,
 *    the frontier rows match the engine's E.pareto on the same values, the
 *    chart is a named image with one point per layout, « Frontier only »
 *    keeps the frontier, and a new value redraws the table's header.
 * 2. Trace: the events table counts the text typed for the chosen layout, a
 *    second layout adds its column and the difference, the strip is hidden
 *    from assistive technology and its table names each character, and a
 *    character the layout cannot type is said in words.
 * 3. Links: « Copy the link » on a tab carries the tab, the Pareto values or
 *    the trace's text and layouts, and the link opens on them.
 * 4. Movements: « One layout » lists each pair class over adjacent pairs and
 *    skipgrams, with the compared layout's columns and their difference.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { shared } = require('../../lib/paths.cjs');

const EN = JSON.parse(
	fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
);
const LAYOUTS = 'ergopti,azerty,bepo,qwerty,colemak';

/** A Comparer page on a few layouts, its ranking drawn. */
async function openComparer(browser, origin, query) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier&${query}`);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	return { context, page, errors };
}

/** The rows of a table body, each as its cells' texts. */
function tableRows(page, selector) {
	return page.$$eval(`${selector} tbody tr`, (rows) =>
		rows.map((row) => Array.from(row.children, (cell) => cell.textContent.trim()))
	);
}

async function exercisePareto(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-pareto');
	await page.waitForSelector('#la-pareto-table tbody tr');
	const rows = await tableRows(page, '#la-pareto-table');
	assert.equal(rows.length, 5, `pareto: every compared layout is a row (${rows.length})`);
	// The engine's own frontier on the two default values (SFB, LSB).
	const expected = await page.evaluate(() => {
		const E = window.LAYOUT_ANALYSIS;
		let results = [];
		// onResults calls back at once with the drawn results.
		window.LAYOUT_ANALYSIS_COMPARER.onResults((list) => {
			results = list.filter((r) => !r.incomplete);
		});
		return E.pareto(
			results.map((r) => ({ id: r.layout.name, values: [r.metrics.sfb, r.metrics.lsb] })),
			['lower', 'lower']
		)
			.filter((p) => p.front)
			.map((p) => p.id)
			.sort();
	});
	const front = rows
		.filter((cells) => cells[3] === EN['layout_analysis.pareto.layer_front'])
		.map((cells) => cells[0])
		.sort();
	assert.deepEqual(front, expected, 'pareto: the table frontier is the engine frontier');
	const chart = await page.$eval('#la-pareto-chart svg', (svg) => ({
		role: svg.getAttribute('role'),
		named: Boolean(svg.getAttribute('aria-labelledby')),
		points: svg.querySelectorAll('.la-pareto-point').length
	}));
	assert.deepEqual(chart, { role: 'img', named: true, points: 5 }, 'pareto: a named chart');
	await page.check('#la-pareto-front');
	const kept = await tableRows(page, '#la-pareto-table');
	assert.ok(
		kept.every(
			(cells) => cells[3] === EN['layout_analysis.pareto.layer_front'] || cells[0] === 'Ergopti'
		) && kept.length >= front.length,
		`pareto: « Frontier only » keeps the frontier (${kept.map((c) => c[0])})`
	);
	await page.uncheck('#la-pareto-front');
	await page.selectOption('#la-pareto-y', 'redirect');
	const header = await page.$$eval('#la-pareto-table thead th', (ths) =>
		ths.map((th) => th.textContent)
	);
	assert.equal(header[2], EN['layout_analysis.metric.redirect'], 'pareto: a new value redraws');
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseTrace(browser, origin) {
	const { context, page, errors } = await openComparer(
		browser,
		origin,
		`layouts=${LAYOUTS}&details=azerty`
	);
	await page.click('#la-tab-trace');
	await page.fill('#la-trace-text', 'Ça va ?');
	await page.waitForSelector('#la-trace-events tbody tr');
	assert.equal(await page.inputValue('#la-trace-layout'), 'azerty', 'trace: the detailed layout');
	const header = await page.$$eval('#la-trace-events thead th', (ths) => ths.length);
	assert.equal(header, 2, 'trace: one layout, one count column');
	// AZERTY types no capital Ç: it is said in words.
	assert.ok(
		await page
			.locator('#la-trace-out')
			.getByText(EN['layout_analysis.trace.unsupported'].replace('{count}', '1'))
			.isVisible(),
		'trace: the untyped character is counted in words'
	);
	await page.selectOption('#la-trace-versus', 'ergopti');
	const columns = await page.$$eval('#la-trace-events thead th', (ths) =>
		ths.map((th) => th.textContent)
	);
	assert.deepEqual(
		columns.slice(1),
		['AZERTY (FR)', 'Ergopti', EN['layout_analysis.trace.difference']],
		`trace: a second layout adds its column and the difference (${columns})`
	);
	const strips = await page.$$eval('.la-trace-strip', (lists) =>
		lists.map((list) => list.getAttribute('aria-hidden'))
	);
	assert.deepEqual(strips, ['true', 'true'], 'trace: the strips repeat the tables');
	const chars = await page.$$eval('.la-trace-layout:last-child table tbody th', (ths) =>
		ths.map((th) => th.textContent)
	);
	assert.deepEqual(chars, ['Ç', 'a', '␣', 'v', 'a', '␣', '?'], 'trace: one row per character');
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseViewLinks(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	const copy = async () => {
		await page.click('#la-share');
		await page.waitForFunction(() => !document.getElementById('la-share-status').hidden);
		return new URL(await page.evaluate(() => navigator.clipboard.readText()));
	};
	await page.click('#la-tab-pareto');
	await page.selectOption('#la-pareto-x', 'mark');
	await page.selectOption('#la-pareto-y', 'sfs');
	const pareto = await copy();
	assert.deepEqual(
		['tab', 'px', 'py'].map((name) => pareto.searchParams.get(name)),
		['pareto', 'mark', 'sfs'],
		`links: a Pareto link carries its values (${pareto.search})`
	);
	await page.click('#la-tab-trace');
	await page.fill('#la-trace-text', 'Noël à Zoé');
	await page.selectOption('#la-trace-layout', 'bepo');
	await page.selectOption('#la-trace-versus', 'qwerty');
	const trace = await copy();
	assert.deepEqual(
		['tab', 'text', 'details', 'versus'].map((name) => trace.searchParams.get(name)),
		['trace', 'Noël à Zoé', 'bepo', 'qwerty'],
		`links: a trace link carries its text and layouts (${trace.search})`
	);
	// A fresh visitor: the link alone opens the view.
	const fresh = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const reader = await fresh.newPage();
	reader.on('pageerror', (error) => errors.push(error.message));
	await reader.goto(`${origin}${pareto.pathname}${pareto.search}`);
	await reader.waitForSelector('#la-pareto-table tbody tr');
	assert.equal(await reader.getAttribute('#la-tab-pareto', 'aria-selected'), 'true');
	assert.deepEqual(
		[await reader.inputValue('#la-pareto-x'), await reader.inputValue('#la-pareto-y')],
		['mark', 'sfs'],
		'links: the Pareto link opens on its values'
	);
	await reader.goto(`${origin}${trace.pathname}${trace.search}`);
	await reader.waitForSelector('#la-trace-events tbody tr');
	assert.deepEqual(
		[
			await reader.inputValue('#la-trace-text'),
			await reader.inputValue('#la-trace-layout'),
			await reader.inputValue('#la-trace-versus')
		],
		['Noël à Zoé', 'bepo', 'qwerty'],
		'links: the trace link opens on its text and layouts'
	);
	assert.deepEqual(errors, []);
	await fresh.close();
	await context.close();
}

async function exerciseMovement(browser, origin) {
	const { context, page, errors } = await openComparer(
		browser,
		origin,
		`layouts=${LAYOUTS}&details=azerty&versus=ergopti`
	);
	await page.waitForSelector('#la-movement tbody tr', { state: 'attached' });
	const header = await page.$$eval('#la-movement thead th', (ths) => ths.length);
	assert.equal(header, 7, 'movement: class, two columns per layout, two differences');
	const rows = await tableRows(page, '#la-movement');
	const sfb = rows.find((cells) => cells[0] === EN['layout_analysis.metric.sfb']);
	assert.ok(sfb, 'movement: the SFB row');
	const value = (text) => Number(text.replace(/[^0-9.+−-]/g, '').replace('−', '-'));
	assert.ok(
		Math.abs(value(sfb[3]) - value(sfb[1]) - value(sfb[5])) < 0.011,
		`movement: the difference is the second minus the first (${sfb})`
	);
	assert.deepEqual(errors, []);
	await context.close();
}

module.exports = { exercisePareto, exerciseTrace, exerciseViewLinks, exerciseMovement };
