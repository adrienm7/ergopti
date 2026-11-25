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
 *    chart is a named image with one point per layout, the Principal and
 *    Comparison frame chooses the ringed layout, « Frontier only »
 *    keeps the frontier, and a new value redraws the table's header.
 * 2. Trace: the events table counts the text typed for the chosen layout, a
 *    second layout adds its column and the difference, the strip is hidden
 *    from assistive technology and its table names each character, and a
 *    character the layout cannot type is said in words; a penalised group
 *    opens the corpus words that type its keys in a row.
 * 3. Links: « Copy the link » on a tab carries the tab, the Pareto values or
 *    the trace's text and layouts, and the link opens on them.
 * 5. Worst n-grams: each row of the overview's cards opens the corpus words
 *    typing its keys in a row.
 * 6. Blends: two built-in corpora mixed by weight become the compared
 *    corpus, named with their shares; an invalid weight is refused in words;
 *    the link carries the recipe and the next visit mixes it again.
 * 7. The editor's analysis panel: its worst n-grams open their corpus words too.
 * 8. The frame on every result tab: both layouts marked in the figures, the
 *    same pair in « One layout ».
 * 9. Help: the « Help » tab names each task in a titled section, without the
 *    filters or the layout frame.
 * 14. Quantiles: the Pareto tab's spread marks P10 to P90 and lists P0 to
 *    P100 in a table, in order, P0 and P100 the lowest and highest values.
 * 15. Density: the spread draws the smoothed distribution of its values
 *    above the strip, hidden from assistive technology (the quantiles' table
 *    says it in numbers), within the strip's ends, its peak on its band's top.
 * 16. Principal − Comparison everywhere: each frame tab but the trace shows
 *    the difference of the two layouts on its values, equal to the engine's
 *    values and their difference with its verdict in words; without a
 *    Comparison it says how to choose one; the Pareto chart and spread mark
 *    the Comparison with a square and the spread says its value and gap.
 * 13. Values query: a query over the values (« sfb < … & complete ») keeps
 *    only the layouts it holds for, in every figure's rows; one that does not
 *    read filters nothing and says why and where in words; the names it may
 *    use are listed.
 * 12. Blends of the user's own text: the pasted text is a part the blend's
 *    pickers offer, the blend mixes it, says it stays on this device, and
 *    the link carries no blend; the next visit mixes it again.
 * 11. Movement percentiles: « Place among the library » measures the
 *    library's complete layouts on request, the status says how far it is,
 *    and then every movement and rhythm cell carries its percentile chip,
 *    neutral for a class with no better way; a comparison of too few layouts
 *    says so in words.
 * 10. Help in the editor and the Optimiser: the editor's last tool, « Help »,
 *    and the Optimiser's folded help under its header name each task in a
 *    titled section, the Optimiser's opened from the keyboard.
 * 4. Movements: « One layout » lists each pair class over adjacent pairs and
 *    skipgrams, with the compared layout's columns and their difference; the
 *    words' mean effort names the compared layout's and the gap.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { shared } = require('../../lib/paths.cjs');

const studioUx = require('./layout-editor-studio-ux.cjs');

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
	// The frame's Principal layout is the one ringed and selected in the table.
	assert.ok(await page.isVisible('#la-frame'), 'pareto: the frame is shown');
	await page.selectOption('#la-frame-main', 'bepo');
	const selected = await page.$$eval('#la-pareto-table tr.la-selected th', (ths) =>
		ths.map((th) => th.textContent)
	);
	assert.deepEqual(selected, ['bépo'], 'pareto: the frame chooses the ringed layout');
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
	assert.equal(await page.inputValue('#la-frame-main'), 'azerty', 'trace: the detailed layout');
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
	await page.selectOption('#la-frame-comp', 'ergopti');
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
	// The drill-down from a penalised group to the corpus's words.
	await page.fill('#la-trace-text', 'le cœur des sœurs');
	const button = page.locator('.la-trace-words-button').first();
	await button.waitFor();
	await button.click();
	assert.equal(await button.getAttribute('aria-expanded'), 'true', 'trace: the words open');
	const words = page.locator(`#${await button.getAttribute('aria-controls')}`);
	assert.ok(await words.isVisible(), 'trace: the words are shown');
	assert.notEqual((await words.textContent()).trim(), '', 'trace: the words are listed');
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
	await page.selectOption('#la-frame-main', 'bepo');
	await page.selectOption('#la-frame-comp', 'qwerty');
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
			await reader.inputValue('#la-frame-main'),
			await reader.inputValue('#la-frame-comp')
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
	const rhythmHeader = await page.$$eval('#la-rhythm thead th', (ths) => ths.length);
	assert.equal(rhythmHeader, 6, 'rhythm: class, all and no thumbs per layout, one difference');
	assert.equal((await tableRows(page, '#la-rhythm')).length, 8, 'rhythm: eight classes');
	// The words' mean effort names the Comparison's beside it, with the gap.
	await page.waitForFunction(() => document.querySelector('#la-words-mean').textContent !== '');
	const mean = await page.textContent('#la-words-mean');
	assert.match(mean, /Ergopti: [\d.]+ points per word \(Principal − Comparison: [+−-]?[\d.]+\)/);
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseWorstWords(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	const button = page.locator('#la-ngrams-list .la-ngram-words').first();
	await button.waitFor();
	const name = await button.getAttribute('aria-label');
	assert.ok(
		name.startsWith(EN['layout_analysis.trace.words']),
		`worst words: the name starts with the visible text (${name})`
	);
	await button.click();
	assert.equal(await button.getAttribute('aria-expanded'), 'true', 'worst words: opened');
	const found = page.locator(`#${await button.getAttribute('aria-controls')}`);
	assert.ok(await found.isVisible(), 'worst words: the words are shown');
	assert.notEqual((await found.textContent()).trim(), '', 'worst words: listed');
	await button.click();
	assert.ok(await found.isHidden(), 'worst words: folded again');
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseBlend(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-home');
	await page.locator('#la-blend > summary').click();
	await page.selectOption('#la-blend-corpus-0', 'fr_nemolivier');
	await page.selectOption('#la-blend-corpus-1', 'en_carroll_alice');
	await page.fill('#la-blend-weight-0', '70');
	await page.fill('#la-blend-weight-1', '30');
	await page.fill('#la-blend-weight-2', '0');
	await page.click('#la-blend-use');
	await page.waitForFunction(() => document.getElementById('la-corpus').value === 'blend');
	const title = await page.$eval('#la-corpus', (select) => select.selectedOptions[0].textContent);
	assert.ok(
		title.startsWith(EN['layout_analysis.blend.entry'].split('{parts}')[0]) &&
			title.includes('70') &&
			title.includes('30'),
		`blend: the corpus list names the blend (${title})`
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await page.fill('#la-blend-weight-0', '-5');
	await page.click('#la-blend-use');
	assert.equal(
		await page.textContent('#la-blend-status'),
		EN['layout_analysis.blend.weight_invalid'].replace('{n}', '1'),
		'blend: an invalid weight is refused in words'
	);
	// The link names the blend, and opens on it for a fresh visitor.
	await page.click('#la-share');
	await page.waitForFunction(() => !document.getElementById('la-share-status').hidden);
	const link = new URL(await page.evaluate(() => navigator.clipboard.readText()));
	assert.equal(
		link.searchParams.get('blend'),
		'fr_nemolivier:70,en_carroll_alice:30',
		`blend: the link carries the recipe (${link.search})`
	);
	const fresh = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const reader = await fresh.newPage();
	reader.on('pageerror', (error) => errors.push(error.message));
	await reader.goto(`${origin}${link.pathname}${link.search}`);
	await reader.waitForFunction(() => document.getElementById('la-corpus').value === 'blend');
	// The same visitor finds it again on the next visit.
	await page.reload();
	await page.waitForFunction(() => document.getElementById('la-corpus').value === 'blend');
	assert.deepEqual(errors, []);
	await fresh.close();
	await context.close();
}

async function exerciseBlendOwnText(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-home');
	await page.selectOption('#la-corpus', 'custom');
	await page.fill(
		'#la-text',
		'Mon propre texte, tapé souvent : des accents, des virgules et du code. '.repeat(20)
	);
	await page.locator('#la-blend > summary').click();
	// The text is read after its typing pause (TEXT_DEBOUNCE_MS).
	await page.waitForSelector('#la-blend-corpus-0 option[value="custom"]', { state: 'attached' });
	const offered = await page.$$eval('#la-blend-corpus-0 option', (options) =>
		options.map((option) => option.value)
	);
	assert.ok(
		offered.includes('custom'),
		`own blend: the pasted text is offered (${offered.slice(0, 5)})`
	);
	await page.selectOption('#la-blend-corpus-0', 'custom');
	await page.selectOption('#la-blend-corpus-1', 'fr_nemolivier');
	await page.fill('#la-blend-weight-0', '40');
	await page.fill('#la-blend-weight-1', '60');
	await page.fill('#la-blend-weight-2', '0');
	await page.click('#la-blend-use');
	await page.waitForFunction(() => document.getElementById('la-corpus').value === 'blend');
	assert.ok(
		(await page.textContent('#la-blend-status')).endsWith(
			EN['layout_analysis.blend.done_own'].split('{title}')[1]
		),
		'own blend: it stays on this device, said in words'
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await page.click('#la-share');
	await page.waitForFunction(() => !document.getElementById('la-share-status').hidden);
	const link = new URL(await page.evaluate(() => navigator.clipboard.readText()));
	assert.equal(link.searchParams.get('blend'), null, 'own blend: no link carries it');
	assert.equal(
		await page.textContent('#la-share-status'),
		EN['layout_analysis.share.copied_partial'],
		'own blend: the link says the text is left out'
	);
	await page.reload();
	await page.waitForFunction(() => document.getElementById('la-corpus').value === 'blend');
	assert.equal(
		await page.inputValue('#la-blend-corpus-0'),
		'custom',
		'own blend: kept for the next visit'
	);
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseValuesQuery(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-overview');
	const filters = page.locator('#la-filters-box > summary');
	if (!(await page.$eval('#la-filters-box', (box) => box.open))) await filters.click();
	const names = () =>
		page.$$eval('#la-table tbody tr', (trs) => trs.map((tr) => tr.dataset.id || tr.textContent));
	const all = (await names()).length;
	assert.equal(all, 5, 'query: five layouts at first');
	await page.fill('#la-row-query', 'mark > 100000');
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length === 0);
	assert.equal(
		await page.textContent('#la-row-query-status'),
		'',
		'query: a readable query says nothing'
	);
	await page.fill('#la-row-query', 'complete & !mine & mark >= 0');
	await page.waitForFunction(
		(n) => document.querySelectorAll('#la-table tbody tr').length === n,
		all
	);
	await page.fill('#la-row-query', 'sfb <');
	await page.waitForFunction(
		() => document.getElementById('la-row-query-status').textContent !== ''
	);
	assert.ok(
		(await page.textContent('#la-row-query-status')).startsWith(
			EN['layout_analysis.filter.query_invalid'].split('{reason}')[0]
		),
		'query: one that does not read says so'
	);
	assert.equal((await names()).length, all, 'query: one that does not read filters nothing');
	const listed = await page.$$eval('#la-query-names code', (codes) =>
		codes.map((c) => c.textContent)
	);
	assert.ok(listed.includes('mark') && listed.includes('sfb'), 'query: the names are listed');
	assert.deepEqual(errors, []);
	await context.close();
}

async function exercisePanelWords(browser, origin) {
	const { page, errors, context } = await studioUx.openOnErgopti(browser, origin);
	const button = page.locator('.la-panel-ngrams .la-ngram-words').first();
	await button.waitFor({ state: 'attached' });
	await button.scrollIntoViewIfNeeded();
	// The editor's 32 px rule for its buttons once outranked the 44 px of
	// WCAG 2.5.5 that the button keeps in the Comparer (site accessibility gate).
	const box = await button.boundingBox();
	assert.ok(
		box.height >= 44 && box.width >= 44,
		`panel words: a 44 px target (${box.width}×${box.height})`
	);
	await button.click();
	assert.equal(await button.getAttribute('aria-expanded'), 'true', 'panel words: opened');
	const found = page.locator(`#${await button.getAttribute('aria-controls')}`);
	assert.notEqual((await found.textContent()).trim(), '', 'panel words: listed');
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseFrameEverywhere(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-bigrams');
	assert.ok(await page.isVisible('#la-frame'), 'frame: shown on a themed tab');
	await page.selectOption('#la-frame-main', 'qwerty');
	await page.selectOption('#la-frame-comp', 'ergopti');
	const marked = await page.$$eval('#la-charts-bigrams .la-chart-row', (rows) => ({
		main: rows.filter((r) => r.classList.contains('la-selected')).length,
		comp: rows.filter((r) => r.classList.contains('la-versus')).length
	}));
	assert.ok(
		marked.main > 0 && marked.comp > 0,
		`frame: both layouts marked (${JSON.stringify(marked)})`
	);
	await page.click('#la-tab-details');
	assert.ok(await page.isHidden('#la-frame'), 'frame: « One layout » keeps its own pickers');
	assert.equal(await page.inputValue('#la-details-layout'), 'qwerty', 'frame: the same Principal');
	assert.equal(await page.inputValue('#la-versus'), 'ergopti', 'frame: the same Comparison');
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseHelp(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-help');
	const titles = await page.$$eval('#la-panel-help h3', (hs) => hs.map((h) => h.textContent));
	assert.deepEqual(
		titles,
		['compare', 'rank', 'pareto', 'trace', 'words', 'blend', 'share'].map(
			(id) => EN[`layout_analysis.help.${id}_title`]
		),
		'help: one titled section per task'
	);
	assert.ok(await page.isHidden('#la-filters-box'), 'help: no filter applies to it');
	assert.ok(await page.isHidden('#la-frame'), 'help: no layout frame');
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseEditorOptimizerHelp(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(`${origin}/ui/layout_editor/index.html?lang=en`);
	await page.waitForSelector('#le-board .le-key');
	const tools = await page.$$eval('.le-tool-tabs [role="tab"]', (tabs) =>
		tabs.map((tab) => tab.id)
	);
	assert.equal(tools[tools.length - 1], 'le-tool-tab-help', 'editor help: the last tool');
	await page.click('#le-tool-tab-help');
	assert.deepEqual(
		await page.$$eval('#le-help h3', (hs) => hs.map((h) => h.textContent)),
		['start', 'keys', 'layers', 'undo', 'versions', 'analyse', 'save', 'export'].map(
			(id) => EN[`layout_editor.help.${id}_title`]
		),
		'editor help: one titled section per task'
	);
	assert.ok(
		(await page.textContent('#le-help')).includes(EN['layout_editor.btn.undo']),
		'editor help: the labels are the buttons’ own'
	);
	await page.goto(`${origin}/ui/layout_optimizer/index.html?lang=en`);
	await page.waitForSelector('#lo-help-title:not(:empty)');
	assert.equal(
		await page.getAttribute('#lo-help', 'open'),
		null,
		'Optimiser help: folded at first'
	);
	await page.focus('#lo-help > summary');
	await page.keyboard.press('Enter');
	assert.equal(
		await page.getAttribute('#lo-help', 'open'),
		'',
		'Optimiser help: opened by keyboard'
	);
	assert.deepEqual(
		await page.$$eval('#lo-help h3', (hs) => hs.map((h) => h.textContent)),
		['setup', 'move', 'run', 'result', 'get', 'shelf'].map(
			(id) => EN[`layout_optimizer.help.${id}_title`]
		),
		'Optimiser help: one titled section per task'
	);
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseMovementPercentiles(browser, origin) {
	const few = await openComparer(browser, origin, `layouts=${LAYOUTS}&details=azerty`);
	await few.page.click('#la-movement-name');
	await few.page.click('#la-movement-rank');
	assert.match(
		await few.page.textContent('#la-movement-rank-status'),
		/^This comparison holds only \d+\s+complete library layouts/,
		'percentiles: too few references said in words'
	);
	assert.deepEqual(few.errors, []);
	await few.context.close();
	const { context, page, errors } = await openComparer(browser, origin, 'details=azerty');
	await page.click('#la-movement-name');
	assert.equal(
		await page.locator('#la-movement .la-pct').count(),
		0,
		'percentiles: on request only'
	);
	await page.click('#la-movement-rank');
	await page.waitForFunction(
		() => /^Each cell carries/.test(document.getElementById('la-movement-rank-status').textContent),
		null,
		{ timeout: 120000 }
	);
	const rows = await page.$$eval('#la-movement tbody tr', (trs) =>
		trs.map((tr) =>
			[...tr.querySelectorAll('td')].map((td) => td.querySelector('.la-pct') !== null)
		)
	);
	assert.ok(
		rows.length > 0 && rows.every((cells) => cells.every(Boolean)),
		'percentiles: every movement cell'
	);
	assert.ok(
		(await page.locator('#la-rhythm tbody .la-pct').count()) === 8 * 2,
		'percentiles: every rhythm cell'
	);
	const neutral = page.locator('#la-movement .la-pct-neutral').first();
	assert.match(
		await neutral.getAttribute('aria-label'),
		/^P\d+, Percentile \d+\s+on .*: higher than/
	);
	const chip = page.locator('#la-movement .la-pct:not(.la-pct-neutral)').first();
	assert.match(await chip.getAttribute('aria-label'), /^P\d+, Percentile \d+\s+on .*: better than/);
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseQuantiles(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-pareto');
	await page.waitForSelector('#la-pareto-quantiles tbody tr');
	const rows = await tableRows(page, '#la-pareto-quantiles');
	assert.deepEqual(
		rows.map((cells) => cells[0]),
		['P0', 'P10', 'P25', 'P50', 'P75', 'P90', 'P100'],
		'quantiles: seven rows, in order'
	);
	const number = (text) =>
		Number(
			text
				.replace(/[^0-9.,−-]/g, '')
				.replace(',', '.')
				.replace('−', '-')
		);
	const values = rows.map((cells) => number(cells[1]));
	assert.ok(
		values.every((v, i) => i === 0 || v >= values[i - 1]),
		`quantiles: never decreasing (${values})`
	);
	const pareto = (await tableRows(page, '#la-pareto-table')).map((cells) => number(cells[1]));
	assert.ok(
		Math.abs(values[0] - Math.min(...pareto)) < 0.011 &&
			Math.abs(values[6] - Math.max(...pareto)) < 0.011,
		`quantiles: P0 and P100 are the extremes (${values} against ${pareto})`
	);
	assert.equal(
		await page.locator('#la-pareto-spread .la-pareto-quantile').count(),
		5,
		'quantiles: five marks'
	);
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseDensity(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-pareto');
	await page.waitForSelector('#la-pareto-spread .la-pareto-density');
	const curve = await page.$eval('#la-pareto-spread svg', (svg) => {
		const path = svg.querySelector('.la-pareto-density');
		const group = path.parentNode;
		const numbers = path
			.getAttribute('d')
			.split(/[MLZ ]+/)
			.filter((part) => part !== '')
			.map(Number);
		const xs = numbers.filter((_, i) => i % 2 === 0);
		const ys = numbers.filter((_, i) => i % 2 === 1);
		const ticks = Array.from(svg.querySelectorAll('.la-pareto-spread-tick'), (tick) =>
			Number(tick.getAttribute('x1'))
		);
		return {
			hidden: group.getAttribute('aria-hidden'),
			samples: xs.length,
			left: Math.min(...xs),
			right: Math.max(...xs),
			top: Math.min(...ys),
			tickLeft: Math.min(...ticks),
			tickRight: Math.max(...ticks)
		};
	});
	assert.equal(curve.hidden, 'true', 'density: decorative, hidden from assistive technology');
	assert.ok(curve.samples > 20, `density: a smooth curve (${curve.samples} samples)`);
	assert.ok(
		curve.left >= curve.tickLeft - 0.01 &&
			curve.right <= curve.tickRight + 0.01 &&
			curve.right - curve.left > 0.9 * (curve.tickRight - curve.tickLeft),
		`density: within the strip's ends (${JSON.stringify(curve)})`
	);
	assert.ok(Math.abs(curve.top - 4) < 0.01, `density: its peak at the band's top (${curve.top})`);
	assert.deepEqual(errors, []);
	await context.close();
}

async function exerciseFrameDiff(browser, origin) {
	const { context, page, errors } = await openComparer(browser, origin, `layouts=${LAYOUTS}`);
	await page.click('#la-tab-bigrams');
	await page.selectOption('#la-frame-main', 'ergopti');
	await page.selectOption('#la-frame-comp', '');
	assert.ok(await page.isVisible('#la-frame-diff-none'), 'frame diff: says how to choose one');
	assert.ok(
		await page.isHidden('#la-frame-diff-wrap'),
		'frame diff: no table without a Comparison'
	);
	await page.selectOption('#la-frame-comp', 'bepo');
	assert.equal(
		await page.textContent('#la-frame-diff-label'),
		'Difference: Ergopti − bépo',
		'frame diff: named by both layouts'
	);
	const engine = await page.evaluate(() => {
		let results = [];
		window.LAYOUT_ANALYSIS_COMPARER.onResults((list) => {
			results = list;
		});
		const [a, b] = ['ergopti', 'bepo'].map((id) => results.find((r) => r.layout.id === id));
		return { a: a.metrics.sfb, b: b.metrics.sfb };
	});
	const number = (text) => Number(text.replace(/[^0-9.−+-]/g, '').replace('−', '-'));
	const rows = await tableRows(page, '#la-frame-diff-table');
	assert.equal(rows.length, 12, `frame diff: one row per bigram metric (${rows.length})`);
	const sfb = rows.find((cells) => cells[0].startsWith(EN['layout_analysis.metric.sfb']));
	assert.ok(sfb, 'frame diff: the SFB row');
	assert.ok(
		Math.abs(number(sfb[1]) - engine.a) < 0.006 && Math.abs(number(sfb[2]) - engine.b) < 0.006,
		`frame diff: the engine's values (${sfb} against ${JSON.stringify(engine)})`
	);
	const delta = number(sfb[3].split(' ')[0]);
	assert.ok(Math.abs(delta - (engine.a - engine.b)) < 0.006, `frame diff: a − b (${sfb[3]})`);
	const verdict = EN[`layout_analysis.details.verdict_${engine.a < engine.b ? 'better' : 'worse'}`];
	assert.ok(sfb[3].endsWith(verdict), `frame diff: the verdict in words (${sfb[3]})`);
	// Every frame tab but the trace has it, each with its own values.
	const counts = {};
	for (const tab of ['overview', 'fingers', 'trigrams', 'rows', 'heatmaps', 'misc', 'pareto']) {
		await page.click(`#la-tab-${tab}`);
		assert.ok(await page.isVisible('#la-frame-diff-table'), `frame diff: shown on ${tab}`);
		counts[tab] = (await tableRows(page, '#la-frame-diff-table')).length;
	}
	assert.equal(counts.pareto, 2, 'frame diff: the Pareto tab compares its two values');
	assert.ok(counts.fingers > counts.heatmaps, 'frame diff: fingers adds its metrics to the loads');
	await page.click('#la-tab-trace');
	assert.ok(await page.isHidden('#la-frame-diff'), 'frame diff: the trace counts its own');
	await page.click('#la-tab-pareto');
	assert.equal(
		await page.locator('#la-pareto-chart .la-pareto-versus').count(),
		1,
		'pareto: a square'
	);
	assert.equal(
		await page.locator('#la-pareto-spread .la-pareto-versus').count(),
		1,
		'spread: a square'
	);
	assert.ok(
		(await page.textContent('#la-pareto-spread-text')).includes('bépo:'),
		'spread: the Comparison in words'
	);
	assert.deepEqual(errors, []);
	await context.close();
}

module.exports = {
	exerciseFrameDiff,
	exerciseDensity,
	exerciseQuantiles,
	exerciseValuesQuery,
	exerciseBlendOwnText,
	exerciseMovementPercentiles,
	exerciseEditorOptimizerHelp,
	exerciseHelp,
	exerciseFrameEverywhere,
	exercisePanelWords,
	exerciseBlend,
	exercisePareto,
	exerciseTrace,
	exerciseViewLinks,
	exerciseMovement,
	exerciseWorstWords
};
