// tools/test/browser/layout-levels.cjs

/**
 * ==============================================================================
 * MODULE: Layout Levels Browser Cases
 * DESCRIPTION:
 * A layout's own levels in the Studio (comparer-levels): the Comparer's
 * boards show Neo 2's Mod3 and Mod4 characters through a level choice, each
 * key naming what it types on every level. The editor's round trip of the
 * same levels is tools/test/test-layout-editor-levels.cjs.
 * Run by layout-editor.playwright.cjs with its browser and loopback origin.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');

// The library entry the cases open, and the characters only its Mod4 level types.
const NEO = 'neo2_new';
const MOD4_CHARACTERS = ['¡', '¿'];

/** Waits for the Comparer's ranking of the linked layouts. */
async function comparerReady(page) {
	await page.waitForFunction(
		() =>
			document.querySelectorAll('#la-table tbody tr').length > 0 &&
			document.getElementById('la-results').getAttribute('aria-busy') === 'false'
	);
}

/**
 * (comparer-levels) The details board and the side-by-side boards offer each
 * level of the layouts they draw, Neo 2's Mod4 among them; choosing it shows
 * the Mod4 characters, a key types nothing there is empty, and every key's
 * name says what it types on each level.
 */
async function exerciseComparerLevels(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(
		`${origin}/ui/layout_analysis/index.html?lang=en&layouts=${NEO},qwerty&details=${NEO}`
	);
	await comparerReady(page);
	await page.waitForSelector('#la-heatmap .la-key');
	const options = await page.$$eval('#la-heat-level option', (list) =>
		list.map((option) => [option.value, option.textContent])
	);
	assert.deepEqual(
		options.map(([value]) => value),
		['base', 'shift', 'mod3', 'shift+mod3', 'mod4', 'shift+mod4', 'mod3+mod4'],
		'the details board offers Neo 2 seven levels'
	);
	assert.ok(
		options.some(([value, label]) => value === 'mod4' && label === 'Mod4'),
		'the Mod4 level is named by its modifier'
	);
	assert.ok(
		await page.$eval('label:has(#la-heat-level)', (label) => label.textContent.trim().length > 0),
		'the level choice has a visible label'
	);
	const shown = () =>
		page.$$eval('#la-heatmap .la-key', (keys) => keys.map((key) => key.textContent));
	const base = await shown();
	for (const ch of MOD4_CHARACTERS) assert.ok(!base.includes(ch), `${ch} is not on the base level`);
	// Keyboard-operable: the choice is a select reached and changed from the keyboard.
	await page.focus('#la-heat-level');
	await page.selectOption('#la-heat-level', 'mod4');
	await page.waitForFunction(() => document.getElementById('la-heatmap').dataset.level === 'mod4');
	const mod4 = await shown();
	for (const ch of MOD4_CHARACTERS) assert.ok(mod4.includes(ch), `the Mod4 board shows ${ch}`);
	assert.ok(mod4.includes(''), 'a key with nothing on Mod4 is empty');
	const names = await page.$$eval('#la-heatmap .la-key', (keys) =>
		keys.map((key) => key.getAttribute('aria-label'))
	);
	assert.ok(
		names.some((name) => /Mod4 ¡/.test(name) && /Base /.test(name)),
		'a key names what it types on every level'
	);
	// The heatmaps tab offers the same choice for its boards.
	await page.click('#la-tab-heatmaps');
	await page.selectOption('#la-heats-level', 'mod4');
	await page.waitForFunction(() =>
		[...document.querySelectorAll('#la-heats .la-heatmap')].some(
			(box) => box.dataset.level === 'mod4'
		)
	);
	const grid = await page.$$eval('#la-heats .la-key', (keys) => keys.map((key) => key.textContent));
	for (const ch of MOD4_CHARACTERS)
		assert.ok(grid.includes(ch), `a side-by-side board shows ${ch}`);
	assert.deepEqual(errors, [], 'comparer levels: page errors');
	await context.close();
}

module.exports = { exerciseComparerLevels };
