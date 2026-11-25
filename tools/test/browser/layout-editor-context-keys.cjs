// tools/test/browser/layout-editor-context-keys.cjs

/**
 * ==============================================================================
 * MODULE: Repeat and Magic Keys Browser Cases
 * DESCRIPTION:
 * A layout's own repeat and magic keys in the editor's key panel
 * (docs/design/magic-and-repeat-keys.md, editor-context-keys): the kind
 * choice places a repeat key (last character or skip-repeat) and a magic key
 * on a key, the magic key's table of rules is edited with the keyboard alone,
 * a Kawalyzer « Clever Keys » file fills it and lists the rules it leaves out
 * with their reason, every control is a 44 px target, the saved source holds
 * the keys and the table, and the file opened again shows them. In the 21
 * locales the panel shows no raw locale key.
 * Run by layout-editor.playwright.cjs with its browser, loopback origin and
 * page helpers.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { parse: parseToml } = require('smol-toml');
const { shared } = require('../../lib/paths.cjs');

const FIXTURE = path.resolve(
	__dirname,
	'..',
	'fixtures',
	'layout-formats',
	'kawalyzer-clever-keys.json'
);
const LOCALES = JSON.parse(
	fs.readFileSync(shared('core', 'i18n', 'data', 'locale_order.json'), 'utf8')
).order;
// WCAG 2.5.5: 44 by 44 CSS pixels (tools/test/lib/target-size.cjs).
const { MINIMUM_PX } = require('../lib/target-size.cjs');

/** The legend a key of the board shows. */
function legend(page, code) {
	return page.textContent(`#le-board [data-code="${code}"] .le-legend`);
}

/** The rows of the magic table, as [after, types] pairs. */
function rules(page) {
	return page.$$eval('#le-magic-rules tbody tr', (rows) =>
		rows
			.filter((row) => row.cells.length === 3)
			.map((row) => [row.cells[0].textContent, row.cells[1].textContent])
	);
}

/** Places a magic key naming `table` on a key through the kind choice. */
async function placeMagic(page, code, table) {
	await page.click(`#le-board [data-code="${code}"]`);
	await page.selectOption('#le-kind', 'magic');
	await page.fill('#le-magic-table', table);
	await page.click('#le-apply');
	await page.waitForSelector('#le-magic');
}

/**
 * (editor-context-keys) The key panel places a repeat and a magic key, edits
 * the magic table with the keyboard, reads a Kawalyzer file into it, and the
 * saved source reads back the same.
 * @param {import('playwright').Browser} browser
 * @param {string} origin
 * @param {{open: Function, downloaded: Function}} helpers - The main file's
 *   page opener and download reader.
 */
async function exerciseKeyPanel(browser, origin, { open, downloaded }) {
	const { page, errors } = await open(browser, origin, 'en');
	const labels = await page.evaluate(() => LAYOUT_ANALYSIS_DATA.model.context_keys.labels);

	// A magic key on KeyL, its new table « sfb » created empty.
	await placeMagic(page, 'KeyL', 'sfb');
	assert.equal(await legend(page, 'KeyL'), labels.magic, 'the board labels the magic key');
	assert.deepEqual(await rules(page), [], 'a new table has no rule');

	// A rule typed and added with the keyboard alone: after, types, Add.
	await page.focus('#le-magic-after');
	await page.keyboard.type('e');
	await page.keyboard.press('Tab');
	assert.equal(await page.evaluate(() => document.activeElement.id), 'le-magic-types');
	await page.keyboard.type('d');
	await page.keyboard.press('Tab');
	assert.equal(await page.evaluate(() => document.activeElement.id), 'le-magic-add');
	await page.keyboard.press('Enter');
	await page.waitForFunction(
		() => document.querySelectorAll('#le-magic-rules [data-after]').length === 1
	);
	assert.deepEqual(await rules(page), [['e', 'd']]);
	// A context longer than two characters is refused, the table unchanged.
	await page.fill('#le-magic-after', 'abc');
	await page.fill('#le-magic-types', 'z');
	await page.click('#le-magic-add');
	assert.match(await page.textContent('#le-message'), /two characters/);
	assert.deepEqual(await rules(page), [['e', 'd']]);
	// Another rule, then removed by its button, which names its context.
	await page.fill('#le-magic-after', 'ce');
	await page.fill('#le-magic-types', 's');
	await page.click('#le-magic-add');
	assert.deepEqual(await rules(page), [
		['e', 'd'],
		['ce', 's']
	]);
	await page.click('#le-magic-rules [aria-label="Remove the rule after ce"]');
	assert.deepEqual(await rules(page), [['e', 'd']]);
	await page.fill('#le-magic-fallback', 'x');
	await page.click('#le-magic-fallback-apply');
	assert.equal(await page.inputValue('#le-magic-fallback'), 'x');

	// A Kawalyzer « Clever Keys » file replaces the rules; the rules a table
	// cannot hold are listed with their reason.
	await page.setInputFiles('#le-magic-file', FIXTURE);
	await page.waitForSelector('#le-magic-imported');
	assert.equal(
		await page.textContent('#le-magic-imported p'),
		'Rules read: 4. Left out: 7.',
		'three rules and the fallback read'
	);
	assert.deepEqual(await rules(page), [
		['é', 'e'],
		['s', 'c'],
		['ea', 'u']
	]);
	assert.equal(await page.inputValue('#le-magic-fallback'), 'à');
	assert.equal(await page.locator('#le-magic-skipped li').count(), 7);
	assert.equal(
		await page.textContent('#le-magic-skipped li:nth-child(3)'),
		'ment (m#): the magic key would type more than one character'
	);
	// Undo takes the whole import back in one step.
	await page.keyboard.press('Control+z');
	await page.waitForFunction(
		() => document.querySelectorAll('#le-magic-rules [data-after]').length === 1
	);
	await page.keyboard.press('Control+y');
	await page.waitForFunction(
		() => document.querySelectorAll('#le-magic-rules [data-after]').length === 3
	);

	// A skip-repeat key on the ISO key left of Z.
	await page.click('#le-board [data-code="IntlBackslash"]');
	await page.selectOption('#le-kind', 'repeat');
	await page.selectOption('#le-repeat', '2');
	await page.click('#le-apply');
	assert.equal(await legend(page, 'IntlBackslash'), labels.repeat_2);
	assert.equal(await page.inputValue('#le-repeat'), '2', 'the panel shows the key it placed');

	// Every control of a repeat or magic key is a 44 px target.
	for (const code of ['IntlBackslash', 'KeyL']) {
		await page.click(`#le-board [data-code="${code}"]`);
		const small = await page.$$eval(
			'.le-context-target',
			(nodes, minimum) =>
				nodes
					.filter((node) => node.offsetParent !== null || node.getClientRects().length > 0)
					.map((node) => [node.id || node.getAttribute('aria-label'), node.getBoundingClientRect()])
					.filter(([, box]) => box.width < minimum || box.height < minimum)
					.map(([id, box]) => `${id} ${box.width}×${box.height}`),
			MINIMUM_PX
		);
		assert.deepEqual(small, [], `${code}: targets below ${MINIMUM_PX} px`);
	}

	// Saved through the layout source, and opened again.
	const saved = await downloaded(page, () => page.click('#le-save'));
	// smol-toml gives null-prototype tables: compared as plain JSON.
	const source = JSON.parse(JSON.stringify(parseToml(saved.text)));
	const base = source.layers.find((layer) => layer.id === 'base');
	assert.deepEqual(base.keys.KeyL, { magic: 'sfb' });
	assert.deepEqual(base.keys.IntlBackslash, { repeat: 2 });
	assert.deepEqual(source.magic, [
		{
			id: 'sfb',
			fallback: 'à',
			rules: [
				{ after: 'é', types: 'e' },
				{ after: 's', types: 'c' },
				{ after: 'ea', types: 'u' }
			]
		}
	]);
	const file = path.join(os.tmpdir(), `layout-context-keys-${process.pid}.toml`);
	fs.writeFileSync(file, saved.text);
	try {
		const reopened = await open(browser, origin, 'en');
		await reopened.page.setInputFiles('#le-open-file', file);
		await reopened.page.waitForFunction(
			(magic) =>
				document.querySelector('#le-board [data-code="KeyL"] .le-legend').textContent === magic,
			labels.magic
		);
		await reopened.page.click('#le-board [data-code="KeyL"]');
		assert.equal(await reopened.page.inputValue('#le-kind'), 'magic');
		assert.equal((await rules(reopened.page)).length, 3);
		assert.deepEqual(reopened.errors, [], 'reopened: page errors');
		await reopened.page.context().close();
	} finally {
		fs.rmSync(file, { force: true });
	}
	assert.deepEqual(errors, [], 'key panel: page errors');
	await page.context().close();
}

/**
 * (editor-context-keys-locales) In each of the 21 locales the panel of a
 * magic key and of a repeat key shows its own words, never a raw locale key.
 */
async function exerciseKeyPanelLocales(browser, origin, { open }) {
	for (const lang of LOCALES) {
		const { page, errors } = await open(browser, origin, lang);
		await placeMagic(page, 'KeyL', 'sfb');
		const magicText = await page.textContent('.le-mapping-fields');
		await page.click('#le-board [data-code="IntlBackslash"]');
		await page.selectOption('#le-kind', 'repeat');
		const repeatText = await page.textContent('.le-mapping-fields');
		for (const text of [magicText, repeatText])
			assert.doesNotMatch(text, /layout_editor\.|edit_history\./, `${lang}: a raw locale key`);
		assert.deepEqual(errors, [], `${lang}: page errors`);
		await page.context().close();
	}
}

module.exports = { exerciseKeyPanel, exerciseKeyPanelLocales };
