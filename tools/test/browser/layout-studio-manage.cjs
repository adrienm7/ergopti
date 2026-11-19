// tools/test/browser/layout-studio-manage.cjs

/**
 * ==============================================================================
 * MODULE: Studio Layout Management Browser Cases
 * DESCRIPTION:
 * The cases of the Studio's import and layout management (docs/audits/
 * layout-analysers/ux-study.md, items 5, 9, 13, 14, 15 and 16), driven in
 * Chromium by layout-editor.playwright.cjs on its loopback server. Each case
 * carries the slug of its item so a failure names it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { shared } = require('../../lib/paths.cjs');
const { openOnErgopti } = require('./layout-editor-studio-ux.cjs');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const THIRD_PARTY = path.join(ROOT, 'tools', 'test', 'fixtures', 'layout-formats', 'third-party');
const EN = JSON.parse(
	fs.readFileSync(shared('core', 'i18n', 'data', 'locales', 'en.json'), 'utf8')
);
// cyanophage's playground link of a Colemak-like test layout (three rows of 11, Shift on the thumb).
const CYANO_LINK =
	'https://cyanophage.github.io/playground.html?layout=qwfpgjluy%3B-arstdhneio%27zxcvbkm%2C.%2F%5C%5E&mode=ergo&lan=english&thumb=l';

/** The text of a locale string before its first placeholder. */
function lead(key) {
	return EN[key].split('{')[0];
}

/**
 * Drops files or a text on an element as a browser would (a DataTransfer
 * through dragover then drop).
 * @param {import('playwright').Page} page
 * @param {string} selector
 * @param {{files?: {name: string, text: string}[], text?: string}} what
 */
async function dropOn(page, selector, what) {
	const transfer = await page.evaluateHandle((data) => {
		const dt = new DataTransfer();
		for (const file of data.files || []) dt.items.add(new File([file.text], file.name));
		if (data.text) dt.setData('text/plain', data.text);
		return dt;
	}, what);
	await page.dispatchEvent(selector, 'dragover', { dataTransfer: transfer });
	await page.dispatchEvent(selector, 'drop', { dataTransfer: transfer });
}

/** The Comparer of the site, its ranking drawn. */
async function openComparer(browser, origin, query) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(
		`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier${query || '&layouts=ergopti,azerty'}`
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	return { page, errors, context };
}

/** « Home », its layout list unfolded. */
async function openLayoutList(page) {
	await page.click('#la-tab-home');
	if (!(await page.$eval('#la-layouts-box', (box) => box.open)))
		await page.click('#la-layouts-summary');
}

/** The names of the ranking's rows. */
function rowNames(page) {
	return page.$$eval('#la-table tbody tr td:nth-child(2)', (cells) =>
		cells.map((cell) => cell.textContent)
	);
}

/**
 * (paste-import) The editor's « Paste a layout… » dialog says what format the
 * text is in as it is typed, refuses a broken text in the dialog with the line
 * that is wrong (the text kept), and opens a cyanophage link in a new tab;
 * files dropped on the editor open as « Import… » opens them.
 */
async function exerciseEditorPasteImport(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin);
	const tabs = () => page.locator('.le-layout-tab').count();
	await page.click('#le-tabs-paste');
	assert.equal(await page.$eval('#le-paste-dialog', (d) => d.open), true, 'the dialog opens');
	assert.equal(
		await page.evaluate(() => document.activeElement.id),
		'le-paste-text',
		'the field has the focus'
	);
	assert.equal(await page.isDisabled('#le-paste-open'), true, 'nothing to open yet');
	await page.fill('#le-paste-text', '{\n  "keyboardType": "european",\n  "keys": [,]\n}');
	assert.match(
		await page.textContent('#le-paste-detected'),
		/KLA \/ KLAnext JSON/,
		'the format is recognised while typing'
	);
	await page.click('#le-paste-open');
	const refusal = await page.textContent('#le-paste-refusal');
	assert.ok(
		refusal.startsWith('Line 3, column ') && refusal.includes('JSON'),
		`the refusal names the line: ${refusal}`
	);
	assert.equal(await page.$eval('#le-paste-dialog', (d) => d.open), true, 'the dialog stays open');
	assert.match(await page.inputValue('#le-paste-text'), /keyboardType/, 'the text is kept');
	const before = await tabs();
	await page.fill('#le-paste-text', CYANO_LINK);
	assert.match(await page.textContent('#le-paste-detected'), /cyanophage/);
	await page.click('#le-paste-open');
	await page.waitForFunction(
		(count) => document.querySelectorAll('.le-layout-tab').length > count,
		before
	);
	assert.equal(await page.$eval('#le-paste-dialog', (d) => d.open), false, 'the dialog closes');
	assert.equal(await page.textContent('#le-board [data-code="KeyE"] .le-legend'), 'f', 'its keys');
	assert.match(await page.textContent('#le-message'), /cyanophage/, 'the format is named');
	// Files dropped anywhere on the editor open in new tabs.
	const dropped = await tabs();
	await dropOn(page, '#layout-editor', {
		files: [
			{ name: 'ergol.json', text: fs.readFileSync(path.join(THIRD_PARTY, 'ergol.json'), 'utf8') }
		]
	});
	await page.waitForFunction(
		(count) => document.querySelectorAll('.le-layout-tab').length > count,
		dropped
	);
	assert.equal(
		await page.textContent('#le-board [data-code="KeyW"] .le-legend'),
		'c',
		'Ergo-L dropped'
	);
	assert.equal(
		await page.$eval('#layout-editor', (node) => node.classList.contains('le-drop-active')),
		false,
		'the drop hint goes'
	);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (paste-import) The Comparer's « Add a layout » card: a pasted cyanophage
 * link is recognised, added and ranked with its format named; a character on
 * two keys is refused with both places; a KLA file dropped on the card joins.
 */
async function exerciseComparerPasteImport(browser, origin) {
	const { page, errors, context } = await openComparer(browser, origin);
	await openLayoutList(page);
	assert.equal(await page.isDisabled('#la-paste-add'), true, 'nothing to add yet');
	await page.fill('#la-paste', CYANO_LINK);
	assert.equal(
		await page.textContent('#la-paste-detected'),
		`✓ ${EN['layout_analysis.formats.detected'].replace('{format}', 'cyanophage')}`
	);
	await page.click('#la-paste-add');
	await page.waitForFunction(() =>
		[...document.querySelectorAll('#la-table tbody tr td:nth-child(2)')].some((cell) =>
			cell.textContent.includes('Cyanophage layout')
		)
	);
	assert.match(await page.textContent('#la-import-report'), /\(cyanophage\)/);
	assert.equal(await page.inputValue('#la-paste'), '', 'the field empties once added');
	await page.fill('#la-paste', 'qwertyuiop\nasdfghjkla\nzxcvbnm,./');
	assert.match(await page.textContent('#la-paste-detected'), /rows of characters/);
	await page.click('#la-paste-add');
	const refusal = await page.textContent('#la-import-report');
	assert.ok(
		refusal.startsWith('“a” is on two keys (row 2, column 1 and row 2, column 10)'),
		`the refusal names both keys: ${refusal}`
	);
	assert.equal(await page.inputValue('#la-paste'), 'qwertyuiop\nasdfghjkla\nzxcvbnm,./', 'kept');
	const ergol = fs.readFileSync(path.join(THIRD_PARTY, 'ergol.json'), 'utf8');
	await dropOn(page, '.la-layouts', { files: [{ name: 'ergol.json', text: ergol }] });
	await page.waitForFunction(() =>
		/Kalamine JSON/.test(document.getElementById('la-import-report').textContent)
	);
	const names = await rowNames(page);
	assert.ok(
		names.some((name) => /Ergo-?L/i.test(name)),
		`Ergo-L joins: ${names}`
	);
	assert.deepEqual(errors, []);
	await context.close();
}

module.exports = {
	dropOn,
	openComparer,
	openLayoutList,
	rowNames,
	lead,
	exerciseEditorPasteImport,
	exerciseComparerPasteImport
};
