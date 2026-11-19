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

/** The names of the list's own layouts (each with its « Mine » actions). */
function ownNames(page) {
	return page.$$eval('.la-layout-item.la-own .la-layout-name', (nodes) =>
		nodes.map((node) => node.textContent)
	);
}

/**
 * (manage-layouts) On the site (this browser's storage): an own layout is
 * renamed in the list (Escape cancels, an empty name is refused in words),
 * duplicated as « (copy) » and ticked, removed with an « Undo » that brings it
 * back; each change survives a reload. Library layouts have no such actions.
 */
async function exerciseManageLayoutsSite(browser, origin) {
	const { page, errors, context } = await openComparer(browser, origin);
	await openLayoutList(page);
	await page.fill('#la-paste', 'qwfpgjluy;\narstdhneio\nzxcvbkm,./');
	await page.click('#la-paste-add');
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 1);
	const [first] = await ownNames(page);
	assert.equal(
		await page.locator('.la-layout-item:not(.la-own) [data-mine]').count(),
		0,
		'a library layout has no actions'
	);
	assert.equal(
		await page.getAttribute(`.la-own button[data-mine="rename"]`, 'aria-label'),
		EN['layout_analysis.mine.rename_named'].replace('{name}', first),
		'each action is named with its layout'
	);
	// Rename: Escape cancels and gives the focus back; an empty name is refused.
	await page.click('.la-own button[data-mine="rename"]');
	assert.equal(await page.evaluate(() => document.activeElement.id), 'la-rename-field');
	await page.keyboard.press('Escape');
	assert.equal(await page.evaluate(() => document.activeElement.dataset.mine), 'rename');
	await page.click('.la-own button[data-mine="rename"]');
	await page.fill('#la-rename-field', '   ');
	await page.keyboard.press('Enter');
	assert.equal(await page.textContent('#la-mine-status'), EN['layout_analysis.mine.name_empty']);
	await page.fill('#la-rename-field', 'My Colemak');
	await page.keyboard.press('Enter');
	await page.waitForFunction(() =>
		[...document.querySelectorAll('#la-table tbody tr td:nth-child(2)')].some(
			(cell) => cell.textContent === 'My Colemak'
		)
	);
	assert.deepEqual(await ownNames(page), ['My Colemak'], 'renamed in the list and the ranking');
	// Duplicate: a copy, ticked.
	await page.click('.la-own button[data-mine="duplicate"]');
	const copy = EN['layout_analysis.mine.copy_name'].replace('{name}', 'My Colemak');
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 2);
	assert.deepEqual((await ownNames(page)).sort(), ['My Colemak', copy].sort());
	await page.waitForFunction(
		(name) =>
			[...document.querySelectorAll('#la-table tbody tr td:nth-child(2)')].some(
				(cell) => cell.textContent === name
			),
		copy
	);
	// Reload: both kept, under their names.
	await page.reload();
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await openLayoutList(page);
	assert.deepEqual((await ownNames(page)).sort(), ['My Colemak', copy].sort(), 'kept on reload');
	// Remove, then Undo.
	await page.click(
		`.la-own button[aria-label="${EN['layout_analysis.mine.remove_named'].replace('{name}', copy)}"]`
	);
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 1);
	assert.equal(
		await page.evaluate(() => document.activeElement.className),
		'la-mine-undo',
		'the focus goes to « Undo »'
	);
	await page.click('.la-mine-undo');
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 2);
	await page.click(
		`.la-own button[aria-label="${EN['layout_analysis.mine.remove_named'].replace('{name}', copy)}"]`
	);
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 1);
	await page.reload();
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await openLayoutList(page);
	assert.deepEqual(await ownNames(page), ['My Colemak'], 'the removal is kept on reload');
	const names = await rowNames(page);
	assert.ok(!names.includes(copy), `the copy left the ranking: ${names}`);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (manage-layouts) In the app, the host's store keeps the user's layouts (the
 * same path on the three OS): a rename saves the same id under its new name,
 * a duplicate saves a new id, a remove asks the host to remove it, and Undo
 * saves it again. A store that refuses leaves the list unchanged, in words.
 */
async function exerciseManageLayoutsStore(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	await context.addInitScript(() => {
		const kept = new Map();
		window.__storeCalls = [];
		window.__storeRefuses = false;
		window.LAYOUT_ANALYSIS_HOST = {
			store: {
				list: () => Promise.resolve([...kept.values()].map((text) => JSON.parse(text))),
				save: (layout) => {
					window.__storeCalls.push(['save', layout.id, layout.name]);
					if (window.__storeRefuses) return Promise.reject({ code: 'studio_store_unreadable' });
					kept.set(layout.id, JSON.stringify(layout));
					return Promise.resolve();
				},
				remove: (id) => {
					window.__storeCalls.push(['remove', id]);
					kept.delete(id);
					return Promise.resolve();
				}
			}
		};
	});
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(
		`${origin}/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier&layouts=ergopti,azerty`
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await openLayoutList(page);
	await page.fill('#la-paste', 'qwfpgjluy;\narstdhneio\nzxcvbkm,./');
	await page.click('#la-paste-add');
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 1);
	const calls = () => page.evaluate(() => window.__storeCalls.splice(0));
	const [[, id]] = await calls();
	await page.click('.la-own button[data-mine="rename"]');
	await page.fill('#la-rename-field', 'Store name');
	await page.keyboard.press('Enter');
	await page.waitForFunction(
		() => document.querySelector('.la-own .la-layout-name').textContent === 'Store name'
	);
	assert.deepEqual(await calls(), [['save', id, 'Store name']], 'a rename saves the same id');
	await page.click('.la-own button[data-mine="duplicate"]');
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 2);
	assert.deepEqual(await calls(), [['save', `${id}_copy`, 'Store name (copy)']]);
	await page.click(`.la-own button[data-layout="${id}_copy"][data-mine="remove"]`);
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 1);
	assert.deepEqual(await calls(), [['remove', `${id}_copy`]], 'a removal asks the host');
	await page.click('.la-mine-undo');
	await page.waitForFunction(() => document.querySelectorAll('.la-own').length === 2);
	assert.deepEqual(
		await calls(),
		[['save', `${id}_copy`, 'Store name (copy)']],
		'Undo saves it again'
	);
	// A store that refuses: the name stays, the reason is said.
	await page.evaluate(() => {
		window.__storeRefuses = true;
	});
	await page.click(`.la-own button[data-layout="${id}"][data-mine="rename"]`);
	await page.fill('#la-rename-field', 'Refused');
	await page.keyboard.press('Enter');
	await page.waitForFunction(() =>
		/studio_store_unreadable/.test(document.getElementById('la-mine-status').textContent)
	);
	await page.keyboard.press('Escape');
	assert.ok(!(await ownNames(page)).includes('Refused'), 'a refused rename changes nothing');
	assert.deepEqual(errors, []);
	await context.close();
}

/** The SFB column of the ranking: each row's value and its percentile chip's number. */
function sfbColumn(page) {
	return page.evaluate(() => {
		const heads = [...document.querySelectorAll('#la-table thead th')];
		const at = heads.findIndex((th) => th.querySelector('button[data-sort="sfb"]'));
		return [...document.querySelectorAll('#la-table tbody tr')].map((tr) => {
			const cell = tr.children[at];
			const chip = cell.querySelector('.la-pct');
			return {
				value: parseFloat(cell.firstChild.textContent.replace(',', '.')),
				percent: chip ? Number(chip.textContent.slice(1)) : null,
				label: chip ? chip.getAttribute('aria-label') : null
			};
		});
	});
}

/**
 * (library-percentile) Beside each metric of the ranking, « P70 »: higher
 * for a better value (SFB: lower is better), named in full, explained in a
 * popover that closes with Escape back to its chip; a comparison of two
 * layouts has none (too few references); the editor's panel shows them too.
 */
async function exercisePercentiles(browser, origin) {
	const { page, errors, context } = await openComparer(browser, origin, '&keyboard=iso');
	await page.waitForFunction(() =>
		/^\d+\s+layouts compared/.test(document.getElementById('la-status').textContent)
	);
	const rows = (await sfbColumn(page)).filter((row) => row.percent !== null);
	assert.ok(rows.length >= 20, `percentiles shown: ${rows.length}`);
	// Values shown rounded: equal ones may hide an order the percentiles keep.
	const sorted = rows.slice().sort((a, b) => a.value - b.value || b.percent - a.percent);
	for (let i = 1; i < sorted.length; i++)
		assert.ok(
			sorted[i].percent <= sorted[i - 1].percent,
			`a higher SFB never has a higher percentile: ${JSON.stringify([sorted[i - 1], sorted[i]])}`
		);
	assert.ok(sorted[0].percent >= 95, `the lowest SFB is near P100: ${sorted[0].percent}`);
	// Named after the « P70 » it shows (WCAG 2.5.3), then in full.
	assert.match(
		sorted[0].label,
		/^P\d+, Percentile \d+\s+on .*: better than \d+\s+% of \d+\s+complete layouts/
	);
	const chip = page.locator('#la-table tbody tr .la-pct').first();
	const text = await chip.textContent();
	await chip.click();
	await page.waitForSelector('#la-popover:not([hidden])');
	const said = await page.textContent('#la-popover .la-popover-texts');
	// The number keeps its next word with a no-break space (studio-numbers).
	assert.ok(
		said.replace(/\s/g, ' ').startsWith(`${text} is this layout’s percentile on `),
		`explained: ${said}`
	);
	assert.equal(await page.$eval('#la-popover ul', (ul) => ul.hidden), true, 'no references list');
	await page.keyboard.press('Escape');
	assert.equal(
		await page.evaluate(() => document.activeElement.classList.contains('la-pct')),
		true,
		'Escape gives the focus back to the chip'
	);
	await context.close();
	const two = await openComparer(browser, origin);
	assert.equal(
		await two.page.locator('#la-table .la-pct').count(),
		0,
		'two layouts: no percentile'
	);
	await two.context.close();
	const editor = await openOnErgopti(browser, origin);
	await editor.page.waitForSelector('.la-panel-metrics tr[data-metric="sfb"] .la-pct');
	assert.match(
		await editor.page.textContent('.la-panel-metrics tr[data-metric="sfb"] .la-pct'),
		/^P\d+$/,
		'the editor panel shows the percentile'
	);
	assert.deepEqual(errors.concat(two.errors, editor.errors), []);
	await editor.context.close();
}

/** The first ranked row's score, as shown. */
function topScore(page) {
	return page.$eval('#la-table tbody tr td:nth-child(3)', (cell) => cell.firstChild.textContent);
}

/**
 * (score-presets) The built-in presets apply every weight at once, the one
 * in use marked in words, with an « Undo »; a penalty floor is edited in its
 * weight's card and moves the score; the current settings saved under a name
 * survive a reload, apply, rename and remove with an « Undo ». The settings
 * file is version 2 with its floors, and a version 1 file is refused by its
 * version.
 */
async function exercisePresets(browser, origin) {
	const { page, errors, context } = await openComparer(browser, origin);
	await page.click('#la-tab-home');
	await page.click('#la-settings > summary');
	const pressed = () =>
		page.$$eval('#la-preset-list button[aria-pressed="true"]', (b) =>
			b.map((n) => n.dataset.preset)
		);
	assert.deepEqual(await pressed(), ['balanced'], 'the defaults are « Balanced »');
	const before = await topScore(page);
	await page.click('#la-preset-list button[data-preset="rolls"]');
	assert.deepEqual(await pressed(), ['rolls']);
	assert.equal(await page.inputValue('#la-weight-roll_in'), '3', 'its weights are in the fields');
	assert.ok(
		(await page.textContent('#la-config-status')).startsWith(
			EN['layout_analysis.presets.applied'].replace(
				'{name}',
				EN['layout_analysis.presets.rolls.name']
			)
		)
	);
	await page.waitForFunction((score) => {
		const cell = document.querySelector('#la-table tbody tr td:nth-child(3)');
		return cell && cell.firstChild.textContent !== score;
	}, before);
	await page.click('#la-config-status .la-mine-undo');
	assert.deepEqual(await pressed(), ['balanced'], 'Undo brings the previous settings back');
	assert.equal(await page.inputValue('#la-weight-roll_in'), '1');
	// A floor: a large SFB floor makes SFB cost nothing, so the score moves.
	const plain = await topScore(page);
	await page.fill('#la-floor-sfb', '100');
	await page.waitForFunction((score) => {
		const cell = document.querySelector('#la-table tbody tr td:nth-child(3)');
		return cell && cell.firstChild.textContent !== score;
	}, plain);
	assert.deepEqual(await pressed(), [], 'an edited floor matches no built-in preset');
	assert.equal(
		await page.getAttribute('#la-floor-sfb', 'aria-label'),
		EN['layout_analysis.weights.floor_named'].replace('{metric}', EN['layout_analysis.metric.sfb'])
	);
	// The export holds the floors, at version 2.
	const [exported] = await Promise.all([
		page.waitForEvent('download'),
		page.click('#la-config-export')
	]);
	const file = JSON.parse(fs.readFileSync(await exported.path(), 'utf8'));
	assert.equal(file.schema_version, 2);
	assert.equal(file.floors.sfb, 100, 'the floor is exported');
	const old = Object.assign({}, file, { schema_version: 1 });
	delete old.floors;
	await page.setInputFiles('#la-config-import', {
		name: 'old.json',
		mimeType: 'application/json',
		buffer: Buffer.from(JSON.stringify(old))
	});
	// The file is read asynchronously: wait for its refusal.
	await page.waitForFunction(() =>
		/version 1; this Studio reads version 2/.test(
			document.getElementById('la-config-status').textContent
		)
	);
	// Save the settings as a preset, then reload.
	await page.fill('#la-preset-name', 'Floor test');
	await page.click('#la-preset-save button[type="submit"]');
	assert.match(await page.textContent('#la-preset-mine'), /Floor test/);
	assert.equal(await page.locator('#la-preset-mine .la-preset-active').count(), 1, 'in use');
	await page.reload();
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await page.click('#la-tab-home');
	await page.click('#la-settings > summary');
	assert.equal(await page.inputValue('#la-floor-sfb'), '100', 'the floor is kept');
	await page.click('#la-preset-list button[data-preset="balanced"]');
	assert.equal(await page.inputValue('#la-floor-sfb'), '0');
	await page.click('#la-preset-mine .la-preset-use');
	assert.equal(await page.inputValue('#la-floor-sfb'), '100', 'the saved preset applies its floor');
	await page.click('#la-preset-mine button[data-mine="rename"]');
	await page.fill('#la-preset-rename-field', 'Renamed preset');
	await page.keyboard.press('Enter');
	assert.equal(await page.textContent('#la-preset-mine .la-preset-name'), 'Renamed preset');
	await page.click('#la-preset-mine button[data-mine="remove"]');
	assert.equal(await page.locator('#la-preset-mine li').count(), 0);
	assert.equal(await page.isVisible('#la-preset-none'), true);
	await page.click('#la-config-status .la-mine-undo');
	assert.equal(await page.textContent('#la-preset-mine .la-preset-name'), 'Renamed preset');
	assert.deepEqual(errors, []);
	await context.close();
}

/** The ranking's rows: each layout id (from its pin) and family. */
function rankingRows(page) {
	return page.evaluate(() => {
		const families = new Map(
			window.LAYOUT_ANALYSIS.libraryLayouts().map((l) => [l.id, l.family || ''])
		);
		return [...document.querySelectorAll('#la-table tbody tr')].map((tr) => {
			const id = tr.querySelector('button.la-pin').dataset.pin;
			return { id, family: families.get(id) || '', pinned: tr.classList.contains('la-row-pinned') };
		});
	});
}

/**
 * (ranking-views) « Fold each family » leaves one row per family, its best
 * ranked, and « +n » shows the others (the focus kept on it); a pinned row
 * stays first under another sort and after a reload, with the folding.
 */
async function exerciseRankingViews(browser, origin) {
	const { page, errors, context } = await openComparer(browser, origin, '&keyboard=iso');
	await page.waitForFunction(() =>
		/^\d+\s+layouts compared/.test(document.getElementById('la-status').textContent)
	);
	const all = await rankingRows(page);
	await page.check('#la-table-fold');
	const folded = await rankingRows(page);
	assert.ok(folded.length < all.length, `folded: ${folded.length} of ${all.length}`);
	const seen = new Set();
	for (const row of folded.filter((r) => r.family !== '')) {
		assert.ok(!seen.has(row.family), `one row per family: ${row.family} twice`);
		seen.add(row.family);
	}
	const fold = page.locator('#la-table button.la-fold').first();
	const family = await fold.getAttribute('data-family');
	const count = Number((await fold.getAttribute('data-count')).slice(1));
	assert.equal(await fold.getAttribute('aria-expanded'), 'false');
	assert.match(
		await fold.getAttribute('aria-label'),
		/^Show the \d+\s+other layouts of the family of /
	);
	await fold.click();
	assert.equal((await rankingRows(page)).length, folded.length + count, 'its members are shown');
	assert.equal(
		await page.evaluate(() => document.activeElement.dataset.family),
		family,
		'the focus stays on its button'
	);
	assert.equal(await page.locator('#la-table tr.la-row-member').count(), count);
	// Pin the last row: first under any sort, kept on reload.
	const last = folded[folded.length - 1].id;
	await page.click(`#la-table button.la-pin[data-pin="${last}"]`);
	assert.equal((await rankingRows(page))[0].id, last, 'a pinned row comes first');
	assert.equal(
		await page.getAttribute(`#la-table button.la-pin[data-pin="${last}"]`, 'aria-pressed'),
		'true'
	);
	await page.click('#la-table button[data-sort="sfb"]');
	assert.equal((await rankingRows(page))[0].id, last, 'first under another sort');
	await page.reload();
	await page.waitForFunction(() =>
		/^\d+\s+layouts compared/.test(document.getElementById('la-status').textContent)
	);
	const again = await rankingRows(page);
	assert.equal(again[0].id, last, 'still first after a reload');
	assert.equal(await page.isChecked('#la-table-fold'), true, 'the folding is kept');
	await page.click(`#la-table button.la-pin[data-pin="${last}"]`);
	assert.notEqual((await rankingRows(page))[0].id, last, 'unpinned, it leaves the top');
	assert.deepEqual(errors, []);
	await context.close();
}

/** A minimal RFC 4180 reader: rows of fields, quotes and doubled quotes undone. */
function parseCsv(text) {
	const rows = [];
	let row = [];
	let field = '';
	let quoted = false;
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (quoted) {
			if (ch === '"' && text[i + 1] === '"') {
				field += '"';
				i++;
			} else if (ch === '"') quoted = false;
			else field += ch;
		} else if (ch === '"') quoted = true;
		else if (ch === ',') {
			row.push(field);
			field = '';
		} else if (ch === '\r' && text[i + 1] === '\n') {
			row.push(field);
			rows.push(row);
			row = [];
			field = '';
			i++;
		} else field += ch;
	}
	return rows;
}

/**
 * (ranking-csv) « Download the table (CSV) » writes the ranking as shown:
 * its headers in the page's language, its rows in their order (a pinned row
 * first), its visible columns, the values unrounded with a dot, a layout
 * name with a comma or a quote quoted, and a name read as a formula made
 * inert.
 */
async function exerciseRankingCsv(browser, origin) {
	const context = await browser.newContext({
		acceptDownloads: true,
		viewport: { width: 1280, height: 900 }
	});
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.goto(
		`${origin}/ui/layout_analysis/index.html?lang=fr&corpus=fr_nemolivier&layouts=ergopti,azerty,bepo`
	);
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length > 0);
	await page.evaluate(() => {
		const azerty = window.LAYOUT_ANALYSIS.libraryLayouts().find((l) => l.id === 'azerty');
		window.LAYOUT_ANALYSIS_COMPARER.addLayouts([
			{
				id: 'user_odd',
				name: '=SUM(1,2) "quoted"',
				rows: azerty.rows,
				dead: azerty.dead,
				origin: 'user'
			}
		]);
	});
	await page.waitForFunction(() => document.querySelectorAll('#la-table tbody tr').length === 4);
	await page.click('#la-table button.la-pin[data-pin="bepo"]');
	const shown = await page.$$eval('#la-table tbody tr', (rows) =>
		rows.map((tr) => tr.querySelector('button.la-pin').dataset.pin)
	);
	const heads = await page.$$eval('#la-table thead th button.la-sort', (b) =>
		b.map((n) => n.textContent)
	);
	const [file] = await Promise.all([page.waitForEvent('download'), page.click('#la-table-csv')]);
	assert.equal(file.suggestedFilename(), 'ergopti-ranking.csv');
	const text = fs.readFileSync(await file.path(), 'utf8').replace(/^﻿/, '');
	const rows = parseCsv(text);
	assert.deepEqual(rows[0], heads, 'the headers as shown, in French');
	assert.equal(rows.length, shown.length + 1, 'one line per row shown');
	const names = await page.evaluate(
		(ids) =>
			ids.map((id) => {
				const l = window.LAYOUT_ANALYSIS.libraryLayouts().find((x) => x.id === id);
				return l ? l.name : null;
			}),
		shown
	);
	assert.equal(rows[1][1], names[0], 'the pinned row first');
	assert.ok(
		rows.some((r) => r[1] === `'=SUM(1,2) "quoted"`),
		`a formula made inert: ${text}`
	);
	const score = rows[1][2];
	assert.match(score, /^-?\d+(\.\d+)?$/, `the score with a dot, unrounded: ${score}`);
	assert.match(await page.textContent('#la-table-csv-status'), /ergopti-ranking\.csv/);
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (tab-rename-duplicate) In the editor, « ⧉ » opens the layout's copy in the
 * next tab, named as a copy with the same keys and the original untouched;
 * F2 or a double-click renames a tab in place (Escape keeps the name, an
 * empty name is refused in words), as one edit Undo takes back.
 */
async function exerciseTabRenameDuplicate(browser, origin) {
	const { page, errors, context } = await openOnErgopti(browser, origin);
	const tabNames = () =>
		page.$$eval('.le-layout-tab', (tabs) => tabs.map((tab) => tab.textContent.replace(/ •$/, '')));
	const [original] = await tabNames();
	await page.click('.le-layout-tab-duplicate[data-duplicate-tab="0"]');
	const copy = EN['layout_analysis.mine.copy_name'].replace('{name}', original);
	assert.deepEqual(await tabNames(), [original, copy], 'the copy opens next to it');
	assert.equal(await page.getAttribute('.le-layout-tab[data-tab="1"]', 'aria-current'), 'true');
	const legends = () =>
		page.$$eval('#le-board [data-code] .le-legend', (nodes) =>
			nodes.map((n) => n.textContent).join('')
		);
	const copyKeys = await legends();
	// F2 renames; Escape keeps the name.
	await page.focus('.le-layout-tab[data-tab="1"]');
	await page.keyboard.press('F2');
	assert.equal(await page.evaluate(() => document.activeElement.id), 'le-tab-rename');
	await page.keyboard.press('Escape');
	assert.deepEqual(await tabNames(), [original, copy]);
	assert.equal(
		await page.evaluate(() => document.activeElement.dataset.tab),
		'1',
		'focus back on the tab'
	);
	await page.dblclick('.le-layout-tab[data-tab="1"]');
	await page.fill('#le-tab-rename', '');
	await page.keyboard.press('Enter');
	assert.equal(await page.textContent('#le-message'), EN['layout_analysis.mine.name_empty']);
	await page.fill('#le-tab-rename', 'My variant');
	await page.keyboard.press('Enter');
	assert.deepEqual(await tabNames(), [original, 'My variant'], 'renamed in place');
	await page.keyboard.press('Control+z');
	assert.deepEqual(await tabNames(), [original, copy], 'Undo takes the rename back');
	await page.click('.le-layout-tab[data-tab="0"]');
	assert.deepEqual((await tabNames())[0], original, 'the original is untouched');
	assert.equal(await legends(), copyKeys, 'the copy has the same keys');
	assert.deepEqual(errors, []);
	await context.close();
}

/**
 * (comparer-edit-copy) « Edit » on a ranking row opens a copy of that layout,
 * named « AZERTY (copy) », in a new tab of « Éditer »: on the site the framed
 * Comparer leaves it in the tab's storage and asks the Studio for the
 * editor, which opens it; in the app the host's openEditor shows it at once.
 * A layout open in the editor has no such button.
 */
async function exerciseComparerEditCopy(browser, origin) {
	const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
	const page = await context.newPage();
	const errors = [];
	page.on('pageerror', (error) => errors.push(error.message));
	await page.route(`${origin}/studio-frame.html`, (route) =>
		route.fulfill({
			contentType: 'text/html',
			body:
				'<!doctype html><script>window.posted = [];' +
				"addEventListener('message', (e) => window.posted.push(e.data && e.data.type));" +
				'</script><iframe id="comparer" src="/ui/layout_analysis/index.html?lang=en&corpus=fr_nemolivier&layouts=ergopti,azerty" style="width:1260px;height:850px"></iframe>'
		})
	);
	await page.goto(`${origin}/studio-frame.html`);
	const frame = page.frameLocator('#comparer');
	const edit = frame.locator('#la-table button.la-edit[data-edit="azerty"]');
	await edit.waitFor({ timeout: 120000 });
	assert.equal(await edit.getAttribute('aria-label'), 'Edit a copy of AZERTY (FR)');
	await edit.click();
	await page.waitForFunction(() => window.posted.includes('ergopti-studio:open-editor'));
	const handed = await page.evaluate(() =>
		JSON.parse(window.sessionStorage.getItem('ergopti.studio.editor_handoff.v1'))
	);
	const name = EN['layout_analysis.mine.copy_name'].replace('{name}', 'AZERTY (FR)');
	assert.equal(handed.name, name);
	assert.equal(handed.origin, 'user');
	// The Studio opens « Éditer » in the same tab: the copy has a tab of its own.
	await page.goto(`${origin}/ui/layout_editor/index.html?lang=en`);
	await page.waitForFunction(
		(wanted) =>
			[...document.querySelectorAll('.le-layout-tab')].some((tab) =>
				tab.textContent.startsWith(wanted)
			),
		name,
		{ timeout: 60000 }
	);
	assert.equal(
		await page.textContent('#le-board [data-code="KeyQ"] .le-legend'),
		'a',
		'the copy types AZERTY'
	);
	assert.deepEqual(errors, []);
	await context.close();

	// The app: the host's openEditor shows « Éditer » with the copy.
	const app = await browser.newPage({ viewport: { width: 1400, height: 900 } });
	const appErrors = [];
	app.on('pageerror', (error) => appErrors.push(error.message));
	await app.addInitScript((strings) => {
		window._i18n_strings = strings;
		window.webkit = { messageHandlers: { layout_editor_window_bridge: { postMessage() {} } } };
	}, EN);
	await app.goto(`${origin}/ui/layout_editor_window/index.html`);
	await app.evaluate(() => window.initData({ strings: {}, state: { platform: 'linux' } }));
	// A saved source: the editor opens it, with no start copy to wait for.
	await app.evaluate(
		(text) => window.sourceData({ filename: 'source.toml', text, folder: 'layout_sources/' }),
		fs.readFileSync(shared('tests', 'corpus', 'layouts', 'source', 'source.toml'), 'utf8')
	);
	await app.waitForSelector('#le-board [data-code="KeyQ"]');
	await app.click('#studio-tab-compare');
	await app.evaluate(
		(layout) => window.LAYOUT_ANALYSIS_HOST.openEditor(layout),
		Object.assign({}, handed)
	);
	assert.equal(await app.getAttribute('#studio-tab-edit', 'aria-selected'), 'true');
	await app.waitForFunction(
		(wanted) =>
			[...document.querySelectorAll('.le-layout-tab')].some((tab) =>
				tab.textContent.startsWith(wanted)
			),
		name
	);
	assert.deepEqual(appErrors, []);
	await app.close();
}

module.exports = {
	exerciseComparerEditCopy,
	exerciseTabRenameDuplicate,
	exerciseRankingCsv,
	exerciseRankingViews,
	exercisePresets,
	exercisePercentiles,
	exerciseManageLayoutsSite,
	exerciseManageLayoutsStore,
	dropOn,
	openComparer,
	openLayoutList,
	rowNames,
	lead,
	exerciseEditorPasteImport,
	exerciseComparerPasteImport
};
