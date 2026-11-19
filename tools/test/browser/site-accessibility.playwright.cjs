// tools/test/browser/site-accessibility.playwright.cjs

/**
 * ==============================================================================
 * MODULE: Site Accessibility Ratchet
 * DESCRIPTION:
 * Runs axe-core (WCAG 2.0, 2.1 and 2.2, levels A and AA) on every page of a
 * built static site and inside every Ergopti Studio frame it embeds, in the
 * light and the dark colour schemes, in headless Chromium. Each violation is
 * counted per page, scheme, frame and rule, and compared with the committed
 * baseline: a new rule or a higher count fails the gate, so the number of
 * violations can only go down. A lower count asks for the baseline to be
 * lowered (--update-baseline) to lock the improvement in. The maintainer asked
 * for a totally accessible project on 2026-11-16 (TODO « Full accessibility »).
 * Each page is then measured for reading (site-reading.cjs): at 200 % zoom
 * with the WCAG 1.4.12 spacing and with the site's 200 % text and wide
 * spacing, no text may be clipped or drawn over another, no block justified,
 * no prose line longer than 80 characters and nothing placed under the
 * sticky header covered by it; those counts have their own
 * ratchet (site-reading-baseline.json).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const smoke = require('./site-artifact-smoke.playwright.cjs');
const reading = require('./site-reading.cjs');
const { SITE_ROUTES } = require('../../ci/site-artifact.cjs');

// Pages audited: every real page of the site, plus the pages the artifact
// smoke list does not carry (the Optimiser tab, the accessibility statement).
const AUDITED_ROUTES = Object.freeze([...SITE_ROUTES, '/studio/optimiser', '/accessibilite']);
const COLOR_SCHEMES = Object.freeze(['light', 'dark']);
// WCAG 2.2 level AA is the target; axe tags each rule with the versions and
// levels it checks.
const WCAG_TAGS = Object.freeze([
	'wcag2a',
	'wcag2aa',
	'wcag21a',
	'wcag21aa',
	'wcag22a',
	'wcag22aa'
]);
const VIEWPORT = Object.freeze({ width: 1440, height: 900 });
// A phone, for the reflow checks (WCAG 1.4.10 asks for 320 CSS pixels).
const PHONE_VIEWPORT = Object.freeze({ width: 320, height: 800 });
// The Studio bar's reflow widths: the smallest phone, a common phone, a tablet.
const STUDIO_BAR_WIDTHS = Object.freeze([320, 375, 768]);
const BASELINE_PATH = path.join(__dirname, 'site-accessibility-baseline.json');
// The reading checks' ratchet (site-reading.cjs): offending elements per page,
// reading mode and check.
const READING_BASELINE_PATH = path.join(__dirname, 'site-reading-baseline.json');
// Where a11y_prefs.js keeps the visitor's settings (the « text » reading mode).
const PREFERENCES_KEY = 'ergopti-a11y-preferences';
// A frame that settles its scripts after load (the Studio pages build their
// keyboards from fetched data) needs a quiet period before the scan.
const FRAME_QUIET_MS = 500;
// Longest a frame may stay busy (aria-busy="true") before the scan fails.
const BUSY_TIMEOUT_MS = 60000;
// Longer than one demo of the Ergopti+ hero (typing, preview, result: about 3.5 s).
const HERO_CYCLE_MS = 4500;

/**
 * Key of one counted violation row.
 * @param {{route: string, scheme: string, frame: string, rule: string}} row
 * @returns {string}
 */
function rowKey(row) {
	return [row.route, row.scheme, row.frame, row.rule].join(' | ');
}

/**
 * Turn the scan findings into the baseline shape: key to number of nodes.
 * @param {Array<{route: string, scheme: string, frame: string, rule: string, nodes: number}>} findings
 * @returns {Object<string, number>} Sorted by key so the file diff stays readable.
 */
function countsOf(findings) {
	const counts = {};
	for (const finding of findings) counts[rowKey(finding)] = finding.nodes;
	return Object.fromEntries(Object.entries(counts).sort(([a], [b]) => a.localeCompare(b)));
}

/**
 * Compare the measured counts with the baseline.
 * @param {Object<string, number>} current
 * @param {Object<string, number>} baseline
 * @returns {{regressions: string[], improvements: string[]}}
 */
function compareWithBaseline(current, baseline) {
	const regressions = [];
	const improvements = [];
	for (const [key, nodes] of Object.entries(current)) {
		const allowed = Object.hasOwn(baseline, key) ? baseline[key] : 0;
		if (nodes > allowed) regressions.push(key + ': ' + nodes + ' node(s), baseline ' + allowed);
		else if (nodes < allowed) improvements.push(key + ': ' + nodes + ' < ' + allowed);
	}
	for (const [key, allowed] of Object.entries(baseline))
		if (!Object.hasOwn(current, key)) improvements.push(key + ': 0 < ' + allowed);
	return { regressions, improvements };
}

/**
 * Key of one counted reading row (site-reading-baseline.json).
 * @param {{route: string, mode: string, check: string}} row
 * @returns {string}
 */
function readingKey(row) {
	return [row.route, row.mode, row.check].join(' | ');
}

/**
 * Turn the reading findings into the baseline shape: key to number of elements.
 * @param {Array<{route: string, mode: string, check: string, elements: string[]}>} findings
 * @returns {Object<string, number>} Sorted by key, rows without an element left out.
 */
function readingCountsOf(findings) {
	const counts = {};
	for (const finding of findings)
		if (finding.elements.length) counts[readingKey(finding)] = finding.elements.length;
	return Object.fromEntries(Object.entries(counts).sort(([a], [b]) => a.localeCompare(b)));
}

/**
 * Read a committed baseline; a missing or malformed file is an error, not an
 * empty baseline, so the gate cannot pass by losing its reference.
 * @param {string} [file] - The axe baseline by default, or the reading one.
 * @param {number} [parts] - Fields of each key (4 for axe rows, 3 for reading rows).
 * @returns {Object<string, number>}
 */
function readBaseline(file = BASELINE_PATH, parts = 4) {
	const baseline = JSON.parse(fs.readFileSync(file, 'utf8'));
	assert.ok(baseline && typeof baseline === 'object' && !Array.isArray(baseline), 'Baseline shape');
	for (const [key, nodes] of Object.entries(baseline)) {
		assert.equal(key.split(' | ').length, parts, 'Baseline key: ' + key);
		assert.ok(Number.isSafeInteger(nodes) && nodes > 0, 'Baseline count: ' + key);
	}
	return baseline;
}

/**
 * Name of a frame in the findings: « page » for the top document, else the
 * framed file's path inside the site.
 */
function frameName(frame, page, origin, basePath) {
	if (frame === page.mainFrame()) return 'page';
	const url = new URL(frame.url());
	assert.equal(url.origin, origin, 'Audited frame outside the site: ' + frame.url());
	return url.pathname.slice(basePath.length + 1);
}

/** Run axe in one frame, or one element of it, and return its violations as counted rows. */
async function scanFrame(frame, axeSource, selector = null) {
	await frame.evaluate(axeSource);
	return frame.evaluate(
		async ([tags, selector]) => {
			const result = await window.axe.run(selector ? document.querySelector(selector) : document, {
				runOnly: { type: 'tag', values: tags },
				resultTypes: ['violations'],
				iframes: false
			});
			return result.violations.map((violation) => ({
				rule: violation.id,
				impact: violation.impact,
				help: violation.help,
				nodes: violation.nodes.length,
				targets: violation.nodes.slice(0, 5).map((node) => node.target.join(' '))
			}));
		},
		[WCAG_TAGS, selector]
	);
}

/** Load one route in one colour scheme and scan the page and its frames. */
async function scanRoute(context, origin, basePath, route, scheme, inflight, axeSource) {
	const page = await context.newPage();
	try {
		await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
		const response = await page.goto(origin + basePath + route, { waitUntil: 'networkidle' });
		assert.ok(response?.ok(), 'Route refused: ' + route);
		await page.locator('main').first().waitFor({ state: 'visible' });
		await smoke.settleFrames(page);
		await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
		const findings = [];
		for (const frame of page.frames()) {
			if (frame !== page.mainFrame() && (frame.url() === '' || frame.url() === 'about:blank'))
				continue;
			const name = frameName(frame, page, origin, basePath);
			// A page computing a result marks it aria-busy and dims it (the
			// Comparer's ranking): scanning then would count the dimmed text as
			// low contrast, so the scan waits for the result, or fails.
			await frame.waitForFunction(() => !document.querySelector('[aria-busy="true"]'), null, {
				timeout: BUSY_TIMEOUT_MS
			});
			for (const violation of await scanFrame(frame, axeSource))
				findings.push({ route, scheme, frame: name, ...violation });
		}
		return findings;
	} finally {
		await page.close();
	}
}

/**
 * What a scan cannot see: the keyboard reaches the skip link first and opens
 * the narrow-screen menu, the settings dialog has no violation of its own, and
 * a setting reaches the Studio frame, survives a reload and resets.
 */
async function exerciseKeyboardAndSettings(context, origin, basePath, inflight, axeSource) {
	const page = await context.newPage();
	const root = (target) =>
		target.evaluate(() => document.documentElement.getAttribute('data-a11y-contrast'));
	try {
		await page.goto(origin + basePath + '/studio', { waitUntil: 'networkidle' });
		await page.locator('main').first().waitFor({ state: 'visible' });
		await smoke.settleFrames(page);
		await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
		await page.keyboard.press('Tab');
		assert.equal(
			await page.evaluate(() => document.activeElement.classList.contains('skip-link')),
			true,
			'The skip link is the first keyboard stop'
		);
		await page.keyboard.press('Enter');
		assert.equal(await page.evaluate(() => document.activeElement.id), 'contenu');
		await page.click('#a11y-settings-button');
		await page.locator('#a11y-settings').waitFor({ state: 'visible' });
		assert.deepEqual(
			await scanFrame(page.mainFrame(), axeSource, '#a11y-settings'),
			[],
			'The settings dialog has no violation'
		);
		await page.check('#a11y-contrast');
		assert.equal(await root(page), 'high', 'The setting applies to the page');
		const editor = page.frames().find((frame) => frame.url().includes('/layout_editor/'));
		assert.ok(editor, 'The Studio frames the editor');
		await editor.waitForFunction(
			() => document.documentElement.getAttribute('data-a11y-contrast') === 'high'
		);
		await page.reload({ waitUntil: 'networkidle' });
		assert.equal(await root(page), 'high', 'The setting is remembered');
		await page.click('#a11y-settings-button');
		await page.getByRole('button', { name: 'Réinitialiser' }).click();
		assert.equal(await root(page), null, 'Reset removes the setting');
		await page.keyboard.press('Escape');
		// A narrow screen: the menu opens from the keyboard and hides its links when closed.
		await page.setViewportSize({ width: 390, height: 844 });
		await page.goto(origin + basePath + '/', { waitUntil: 'networkidle' });
		const firstLink = page.locator('#menu-pages > a').first();
		assert.equal(await firstLink.isVisible(), false, 'A closed menu hides its links');
		await page.focus('#menu-btn');
		await page.keyboard.press('Space');
		await firstLink.waitFor({ state: 'visible' });
	} finally {
		await page.close();
	}
}

/** The frame of a page whose address holds a part, once it has loaded and is not busy. */
async function studioFrame(page, part) {
	await smoke.settleFrames(page);
	const frame = page.frames().find((each) => each.url().includes(part));
	assert.ok(frame, 'The page frames ' + part);
	await frame.waitForFunction(() => !document.querySelector('[aria-busy="true"]'), null, {
		timeout: BUSY_TIMEOUT_MS
	});
	return frame;
}

/** Whether a document scrolls sideways (WCAG 1.4.10 reflow). */
function scrollsSideways(target) {
	return target.evaluate(
		() => document.documentElement.scrollWidth > document.documentElement.clientWidth
	);
}

/**
 * The Comparer's restores act at once and offer an « Undo » (WCAG 3.3.4):
 * a changed weight and a changed finger come back from the keyboard alone,
 * the offer is said in a status region one Tab after its button, and the
 * focus returns to the button. Leaves both offers shown for the scan.
 * @param {object} comparer - The Comparer's frame, its settings unfolded.
 * @param {object} page - The page holding the frame (its keyboard).
 * @returns {Promise<function(): Promise<void>>} Takes both offers back.
 */
async function exerciseUndo(comparer, page) {
	const weight = comparer.locator('#la-weight-list input').first();
	const initial = await weight.inputValue();
	await weight.fill(String(Number(initial) + 7));
	await comparer.locator('#la-restore').click();
	assert.equal(await weight.inputValue(), initial, 'The restore acts at once');
	const line = comparer.locator('#la-restore + .la-undo');
	assert.equal(await line.getAttribute('role'), 'status', 'The undo line is announced');
	assert.equal(await line.locator('button').count(), 1, 'A restore offers an undo');
	const fingering = comparer.locator('#la-fingering');
	const key = fingering.locator('.la-fingering-key').first();
	await key.click();
	const finger = await key.getAttribute('data-finger');
	const other = finger === 'lp' ? 'lr' : 'lp';
	await fingering.locator('.la-fingering-row select').last().selectOption(other);
	assert.equal(
		await fingering.locator('.la-fingering-key').first().getAttribute('data-finger'),
		other
	);
	const reset = fingering.locator('.la-row button').first();
	await reset.click();
	assert.equal(
		await fingering.locator('.la-fingering-key').first().getAttribute('data-finger'),
		finger
	);
	assert.equal(await fingering.locator('.la-undo button').count(), 1, 'The reset offers an undo');
	return async () => {
		await comparer.locator('#la-restore').focus();
		await page.keyboard.press('Tab');
		assert.equal(
			await comparer.evaluate(() => document.activeElement.closest('.la-undo') !== null),
			true,
			'The undo is the next keyboard stop'
		);
		await page.keyboard.press('Enter');
		assert.equal(
			await weight.inputValue(),
			String(Number(initial) + 7),
			'Undo puts the weight back'
		);
		assert.equal(
			await comparer.evaluate(() => document.activeElement.id),
			'la-restore',
			'The focus returns to the restore button'
		);
		assert.equal(await line.locator('button').count(), 0, 'An undo is used once');
		await fingering.locator('.la-undo button').click();
		assert.equal(
			await fingering.locator('.la-fingering-key').first().getAttribute('data-finger'),
			other,
			'Undo puts the fingering back'
		);
		await reset.click();
		await comparer.locator('#la-restore').click();
	};
}

/**
 * Ergopti Studio's bar (its name, tabs and « Apparence ») reflows on a phone
 * and a tablet, in both schemes, with the default text and with the site's
 * 200 % text: no sideways page scroll and every part of the bar, each tab
 * among them, wholly in view (WCAG 1.4.10). The bar's name and tab icons once pushed the tabs to 327 px at
 * 320 px.
 * @param {object} browser
 * @param {string} origin
 * @param {string} basePath
 */
async function exerciseStudioBar(browser, origin, basePath) {
	for (const preferences of [null, reading.READING_MODES.text.preferences])
		for (const colorScheme of COLOR_SCHEMES)
			await withContext(browser, origin, { colorScheme }, async (context) => {
				if (preferences)
					await context.addInitScript(
						([key, value]) => window.localStorage.setItem(key, value),
						[PREFERENCES_KEY, JSON.stringify(preferences)]
					);
				const page = await context.newPage();
				try {
					for (const width of STUDIO_BAR_WIDTHS) {
						await page.setViewportSize({ width, height: PHONE_VIEWPORT.height });
						await page.goto(origin + basePath + '/studio/comparer', { waitUntil: 'load' });
						await page.locator('.studio-bar nav.subnav a').first().waitFor();
						const where = [width + ' px', colorScheme, preferences ? '200 % text' : 'default text'];
						// The whole page's reflow at 200 % text also involves the site
						// header, which is not the bar's; the bar's own parts are measured.
						if (!preferences)
							assert.equal(
								await scrollsSideways(page),
								false,
								'The Studio page fits ' + where.join(', ')
							);
						const outside = await page.evaluate(() =>
							[...document.querySelectorAll('.studio-bar, .studio-bar *')]
								.filter((part) => {
									const box = part.getBoundingClientRect();
									return box.left < 0 || box.right > document.documentElement.clientWidth;
								})
								.map((part) => part.tagName.toLowerCase() + '.' + part.classList[0])
						);
						assert.deepEqual(
							outside,
							[],
							'The Studio bar and its tabs are in view at ' + where.join(', ')
						);
					}
				} finally {
					await page.close();
				}
			});
}

/**
 * What the scan cannot open: the Comparer's details and settings at phone
 * width (no sideways page scroll, every figure a named table, the heatmap's
 * numbers as a table, no violation once unfolded), the restores' undo, and the editor's board
 * (every key named with its place and its layers, the layout as a table, a
 * swap without dragging, WCAG 2.5.7).
 */
async function exerciseStudio(context, origin, basePath, inflight, axeSource) {
	const page = await context.newPage();
	try {
		await page.setViewportSize(PHONE_VIEWPORT);
		await page.goto(origin + basePath + '/studio/comparer', { waitUntil: 'networkidle' });
		await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
		const comparer = await studioFrame(page, '/layout_analysis/');
		assert.equal(await scrollsSideways(page), false, 'The Comparer page fits a phone');
		assert.equal(await scrollsSideways(comparer), false, 'The Comparer fits a phone');
		await comparer
			.locator('#la-results[aria-busy="false"] #la-chart .la-chart-row')
			.first()
			.click();
		await comparer.evaluate(() =>
			document.querySelectorAll('#la-details details, #la-settings').forEach((node) => {
				node.open = true;
			})
		);
		assert.equal(await scrollsSideways(comparer), false, 'The unfolded figures fit a phone');
		const figures = await comparer.evaluate(() => ({
			keys: document.querySelectorAll('#la-heatmap .la-key').length,
			rows: document.querySelectorAll('#la-heat-table tbody tr').length,
			bars: Array.from(document.querySelectorAll('#la-details .la-bars'), (box) => ({
				id: box.id,
				table: box.getAttribute('role') === 'table' && box.hasAttribute('aria-labelledby'),
				rows: box.querySelectorAll(
					'[role="row"] > [role="rowheader"] + [aria-hidden] + [role="cell"]'
				).length,
				drawn: box.querySelectorAll('.la-chart-row').length
			}))
		}));
		assert.ok(figures.keys > 0 && figures.rows === figures.keys, 'The heatmap has its table');
		for (const box of figures.bars)
			assert.ok(box.table && box.rows === box.drawn, 'A figure reads as a table: ' + box.id);
		assert.deepEqual(
			await scanFrame(comparer, axeSource, '#la-details'),
			[],
			'No violation in #la-details'
		);
		// The score settings sit in « Home », the Comparer's first tab.
		await comparer.locator('#la-tab-home').click();
		assert.equal(await scrollsSideways(comparer), false, 'The unfolded settings fit a phone');
		const undoBoth = await exerciseUndo(comparer, page);
		assert.deepEqual(
			await scanFrame(comparer, axeSource, '#la-settings'),
			[],
			'No violation in #la-settings'
		);
		await undoBoth();

		await page.setViewportSize({ ...VIEWPORT });
		await page.goto(origin + basePath + '/studio', { waitUntil: 'networkidle' });
		await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
		const editor = await studioFrame(page, '/layout_editor/');
		await editor.locator('#le-board [data-code="KeyA"]').waitFor();
		const names = await editor.evaluate(() =>
			Array.from(document.querySelectorAll('#le-board .le-key'), (key) => ({
				label: key.getAttribute('aria-label') || '',
				dead: key.classList.contains('dead')
			}))
		);
		assert.ok(names.length > 40, 'The editor draws its board');
		for (const name of names)
			assert.match(name.label, /rangée \d+, touche \d+/, 'A key says where it is: ' + name.label);
		assert.ok(
			names.some((name) => name.dead && name.label.includes('touche morte')),
			'A dead key is named as one'
		);
		await editor.locator('#le-board-table > summary').click();
		await editor.locator('#le-board-table tbody tr').first().waitFor();
		assert.equal(await editor.locator('#le-board-table tbody tr').count(), names.length);
		assert.deepEqual(await scanFrame(editor, axeSource, '#le-board-table'), []);
		const legend = (code) =>
			editor.locator('#le-board [data-code="' + code + '"] .le-legend').textContent();
		const before = [await legend('KeyA'), await legend('KeyS')];
		assert.notEqual(before[0], before[1], 'Two different keys to swap');
		await editor.locator('#le-board [data-code="KeyA"]').click();
		await editor.selectOption('#le-swap-target', 'KeyS');
		await editor.locator('#le-swap').click();
		await editor.waitForFunction(
			(was) =>
				document.querySelector('#le-board [data-code="KeyA"] .le-legend').textContent === was,
			before[1]
		);
		assert.equal(await legend('KeyS'), before[0], 'The swap moved both keys without a drag');
	} finally {
		await page.close();
	}
}

/**
 * The Ergopti+ hero demo, with motion allowed, cycles on its own; its pause
 * button stops it on the shown result (WCAG 2.2.2) and starts it again.
 */
async function exerciseHeroPause(context, origin, basePath, inflight) {
	const page = await context.newPage();
	try {
		await page.emulateMedia({ reducedMotion: 'no-preference' });
		await page.goto(origin + basePath + '/ergopti-plus', { waitUntil: 'networkidle' });
		await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
		const pause = page.locator('.demo-pause');
		await pause.click();
		await page.locator('.demo-pause', { hasText: 'Relancer la démo' }).waitFor();
		const shown = await page.locator('.demo-typed').textContent();
		await page.waitForTimeout(HERO_CYCLE_MS);
		assert.equal(await page.locator('.demo-typed').textContent(), shown, 'A paused demo stays');
		await pause.click();
		await page.locator('.demo-pause', { hasText: 'Mettre la démo en pause' }).waitFor();
		// Read in English, the document says so (WCAG 3.1.1), then French again.
		const lang = () => page.evaluate(() => document.documentElement.lang);
		await page.getByRole('button', { name: 'EN', exact: true }).click();
		await page.waitForFunction(() => document.documentElement.lang === 'en');
		await page.getByRole('button', { name: 'FR', exact: true }).click();
		assert.equal(await lang(), 'fr', 'The French page is French again');
	} finally {
		await page.close();
	}
}

/**
 * Open a browser context on the served site, with the same inert fixtures as
 * the structure gate (the scan never depends on the network), and track its
 * requests so a page can wait for its network to settle.
 * @param {object} browser
 * @param {string} origin
 * @param {object} options - Extra newContext options (viewport, deviceScaleFactor).
 * @param {function(object, Set): Promise<void>} visit - Receives the context and its in-flight requests.
 */
async function withContext(browser, origin, options, visit) {
	const context = await browser.newContext({
		serviceWorkers: 'block',
		viewport: { ...VIEWPORT },
		...options
	});
	try {
		context.setDefaultTimeout(30000);
		const inflight = new Set();
		context.on('request', (request) => {
			if (new URL(request.url()).origin === origin) inflight.add(request);
		});
		for (const settled of ['requestfinished', 'requestfailed'])
			context.on(settled, (request) => inflight.delete(request));
		await context.route('**/*', async (route) => {
			const url = route.request().url();
			if (new URL(url).origin === origin) return route.continue();
			const fixture = smoke.githubFixture(url);
			if (fixture !== null)
				return route.fulfill({
					status: 200,
					contentType: 'application/json',
					headers: { 'Access-Control-Allow-Origin': '*' },
					body: JSON.stringify(fixture)
				});
			const external = smoke.authoredExternalFixture(url);
			if (external !== null) return route.fulfill({ status: 200, ...external });
			return route.abort();
		});
		await visit(context, inflight);
	} finally {
		await context.close();
	}
}

/**
 * Measure every page in one reading mode (site-reading.cjs): its window, its
 * spacing style sheet or the site's own reading settings, then the mode's
 * checks in the page's own document (the Studio frames have their own gates).
 * @returns {Promise<Array<{route: string, mode: string, check: string, elements: string[]}>>}
 */
async function scanReading(browser, origin, basePath, routes, mode) {
	const settings = reading.READING_MODES[mode];
	const findings = [];
	await withContext(
		browser,
		origin,
		{ viewport: { ...settings.viewport }, deviceScaleFactor: settings.deviceScaleFactor },
		async (context, inflight) => {
			if (settings.preferences)
				await context.addInitScript(
					([key, value]) => window.localStorage.setItem(key, value),
					[PREFERENCES_KEY, JSON.stringify(settings.preferences)]
				);
			for (const route of routes) {
				const page = await context.newPage();
				try {
					await page.emulateMedia({ reducedMotion: 'reduce' });
					const response = await page.goto(origin + basePath + route, {
						waitUntil: 'networkidle'
					});
					assert.ok(response?.ok(), 'Route refused: ' + route);
					await page.locator('main').first().waitFor({ state: 'visible' });
					await smoke.settleFrames(page);
					await smoke.settleNetwork(inflight, { quietMs: FRAME_QUIET_MS });
					if (settings.preferences)
						assert.equal(
							await page.evaluate(() => document.documentElement.getAttribute('data-a11y-text')),
							settings.preferences.text,
							'The reading settings apply to ' + route
						);
					if (settings.styleSheet) await page.addStyleTag({ content: settings.styleSheet });
					// From the top of the page (a sticky header covers what scrolls under
					// it by design), once the page's scripts that fit text to its boxes
					// (the keyboard drawings) have answered the new style: two frames,
					// then a quiet period.
					await page.evaluate(
						() =>
							new Promise((resolve) => {
								window.scrollTo(0, 0);
								requestAnimationFrame(() => requestAnimationFrame(resolve));
							})
					);
					await page.waitForTimeout(FRAME_QUIET_MS);
					const options = reading.optionsFor(mode);
					const measured = await page.evaluate(reading.measureReading, options);
					// Scrolls the page, so after the measures taken from its top.
					if (settings.checks.includes('header-cover'))
						measured['header-cover'] = await page.evaluate(reading.measureHeaderCover, options);
					for (const check of settings.checks)
						findings.push({ route, mode, check, elements: measured[check] });
				} finally {
					await page.close();
				}
			}
		}
	);
	return findings;
}

/**
 * Serve the built site on loopback and scan every audited page in Chromium:
 * axe in both colour schemes and the behaviour checks, unless readingOnly,
 * then the reading checks in every reading mode.
 * @returns {Promise<{findings: object[], reading: object[]}>}
 */
async function scanSite(site, basePath, chromium, routes = AUDITED_ROUTES, readingOnly = false) {
	const axeSource = fs.readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8');
	// Resource integrity is the artifact smoke and structure gates' job; this
	// scan only answers. The loopback host also makes isDev.js probe absent
	// version.json files (src/lib/js/isDev.js), which must not fail the scan.
	const server = http.createServer((request, response) =>
		smoke.serveRequest(site, basePath, request, response, [])
	);
	await new Promise((resolve, reject) => {
		server.once('error', reject);
		server.listen(0, '127.0.0.1', resolve);
	});
	try {
		const origin = 'http://127.0.0.1:' + server.address().port;
		return await smoke.withBrowser(chromium, async (browser) => {
			const findings = [];
			if (!readingOnly)
				await withContext(browser, origin, {}, async (context, inflight) => {
					for (const route of routes)
						for (const scheme of COLOR_SCHEMES)
							findings.push(
								...(await scanRoute(context, origin, basePath, route, scheme, inflight, axeSource))
							);
					await exerciseKeyboardAndSettings(context, origin, basePath, inflight, axeSource);
					await exerciseStudio(context, origin, basePath, inflight, axeSource);
					await exerciseHeroPause(context, origin, basePath, inflight);
				});
			if (!readingOnly) await exerciseStudioBar(browser, origin, basePath);
			const readingFindings = [];
			for (const mode of Object.keys(reading.READING_MODES))
				readingFindings.push(...(await scanReading(browser, origin, basePath, routes, mode)));
			return { findings, reading: readingFindings };
		});
	} finally {
		await new Promise((resolve, reject) =>
			server.close((error) => (error ? reject(error) : resolve()))
		);
	}
}

/** Print the per-page totals, the rows a reader acts on. */
function printSummary(findings, routes) {
	const perPage = new Map();
	for (const finding of findings) {
		const key = finding.route + ' (' + finding.scheme + ')';
		perPage.set(key, (perPage.get(key) || 0) + finding.nodes);
	}
	for (const route of routes)
		for (const scheme of COLOR_SCHEMES) {
			const key = route + ' (' + scheme + ')';
			console.log('  ' + key + ': ' + (perPage.get(key) || 0) + ' node(s)');
		}
}

/** Print each reading finding with its elements, the rows a reader fixes. */
function printReading(findings, keys = null) {
	for (const finding of findings)
		if (keys === null || keys.has(readingKey(finding)))
			for (const element of finding.elements)
				console.log('  ' + readingKey(finding) + ': ' + element);
}

/**
 * Usage: site-directory base-path [--update-baseline] [--report=file.json]
 * [--only=route,…] [--reading-only]. The report holds every finding with its
 * impact and first targets, the raw material of docs/audits/accessibility/.
 * --reading-only skips axe and the behaviour checks and compares the reading
 * baseline alone.
 */
async function main(args = process.argv.slice(2)) {
	const flags = args.filter((arg) => arg.startsWith('--'));
	const positional = args.filter((arg) => !arg.startsWith('--'));
	assert.equal(positional.length, 2, 'Expected site-directory base-path (empty or /dev)');
	const [site, basePath] = [path.resolve(positional[0]), positional[1]];
	assert.ok(basePath === '' || basePath === '/dev', 'Unknown site base path');
	for (const flag of flags)
		assert.ok(
			flag === '--update-baseline' || flag === '--reading-only' || /^--(report|only)=/.test(flag),
			'Unknown flag ' + flag
		);
	// --only=route[,route] scans a subset while fixing a page; it reports
	// without comparing, since the other pages are not measured.
	const only = flags.find((flag) => flag.startsWith('--only='));
	const readingOnly = flags.includes('--reading-only');
	const routes = only ? only.slice('--only='.length).split(',') : AUDITED_ROUTES;
	for (const route of routes) assert.ok(AUDITED_ROUTES.includes(route), 'Unknown route ' + route);
	assert.ok(
		!(only && flags.includes('--update-baseline')),
		'A partial scan cannot set the baseline'
	);
	const scanned = await scanSite(
		site,
		basePath,
		require('playwright').chromium,
		routes,
		readingOnly
	);
	const findings = scanned.findings;
	const report = flags.find((flag) => flag.startsWith('--report='));
	if (report)
		fs.writeFileSync(
			report.slice('--report='.length),
			JSON.stringify({ axe: findings, reading: scanned.reading }, null, '\t') + '\n'
		);
	const current = countsOf(findings);
	const total = Object.values(current).reduce((sum, nodes) => sum + nodes, 0);
	const currentReading = readingCountsOf(scanned.reading);
	const readingTotal = Object.values(currentReading).reduce((sum, count) => sum + count, 0);
	if (!readingOnly) printSummary(findings, routes);
	if (only) {
		for (const finding of findings)
			console.log(
				'  ' +
					rowKey(finding) +
					' [' +
					finding.impact +
					'] ' +
					finding.nodes +
					': ' +
					finding.targets.join(', ')
			);
		printReading(scanned.reading);
		return;
	}
	if (flags.includes('--update-baseline')) {
		if (!readingOnly) fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, '\t') + '\n');
		fs.writeFileSync(READING_BASELINE_PATH, JSON.stringify(currentReading, null, '\t') + '\n');
		console.log(
			'Site accessibility: baseline(s) written (' +
				(readingOnly ? 'axe not scanned' : total + ' node(s)') +
				', ' +
				readingTotal +
				' reading element(s)).'
		);
		return;
	}
	const axe = readingOnly
		? { regressions: [], improvements: [] }
		: compareWithBaseline(current, readBaseline());
	const read = compareWithBaseline(currentReading, readBaseline(READING_BASELINE_PATH, 3));
	const improvements = [...axe.improvements, ...read.improvements];
	if (improvements.length)
		console.log(
			'Site accessibility: fewer violations than the baseline; lower it with --update-baseline:\n  ' +
				improvements.join('\n  ')
		);
	printReading(scanned.reading, new Set(read.regressions.map((line) => line.split(':')[0])));
	assert.deepEqual(
		axe.regressions,
		[],
		'New accessibility violations (the ratchet only goes down)'
	);
	assert.deepEqual(
		read.regressions,
		[],
		'New reading problems: clipped, overlapping, justified or too long text (the ratchet only goes down)'
	);
	console.log(
		'Site accessibility: ' +
			(readingOnly ? '' : total + ' node(s) and ') +
			readingTotal +
			' reading element(s), within the baseline(s), PASS in Chromium.'
	);
}

module.exports = {
	AUDITED_ROUTES,
	COLOR_SCHEMES,
	WCAG_TAGS,
	BASELINE_PATH,
	READING_BASELINE_PATH,
	rowKey,
	countsOf,
	readingKey,
	readingCountsOf,
	compareWithBaseline,
	readBaseline,
	scanSite,
	main
};
if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exitCode = 1;
	});
