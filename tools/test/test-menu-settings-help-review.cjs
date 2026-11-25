// tools/test/test-menu-settings-help-review.cjs

/**
 * ==============================================================================
 * MODULE: Menu Settings Help Review
 * DESCRIPTION:
 * WCAG 3.3.5 (help) for the tray menus of the three drivers. A tray row has
 * no help line of its own, so every setting row (check, choice and toggle) of
 * menu.toml was reviewed: its label either says its effect, or it needs a
 * help text, and the reason says what that text must add. The review lives in
 * docs/audits/accessibility/tray-settings-help-review.json; this test requires exactly one
 * entry per setting row, so a new row fails until it is reviewed and a removed
 * row cannot leave a stale entry behind.
 *
 * Each « needs_help » row carries its help in its own label, the same on the
 * three trays (the agent's decision of 2026-11-25 in TODO.md: Win32 menus and
 * dbusmenu have no item tooltips). Its entry names the label key the row draws
 * and the text that key held in each locale before the help was written: the
 * row must still draw that key, and no locale may keep the old text.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { parse } = require('smol-toml');

const MENU_DATA = path.join(
	__dirname,
	'..',
	'..',
	'static',
	'ergopti_plus',
	'_shared',
	'menu',
	'data'
);
const REVIEW_PATH = path.join(
	__dirname,
	'..',
	'..',
	'docs',
	'audits',
	'accessibility',
	'tray-settings-help-review.json'
);
const LOCALES_DIR = path.join(
	__dirname,
	'..',
	'..',
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'i18n',
	'data',
	'locales'
);
const LOCALE_COUNT = 21;
const SETTING_TYPES = new Set(['check', 'choice', 'toggle']);
const VERDICTS = new Set(['self_explained', 'needs_help']);

/**
 * Lists the setting rows of a menu declaration as « array.id ».
 * @param {Record<string, unknown>} menu The parsed [menu] table.
 * @returns {Set<string>} The row names.
 */
function settingRows(menu) {
	return new Set(settingLabelKeys(menu).keys());
}

/**
 * Maps each setting row of a menu declaration to the label key it draws.
 * @param {Record<string, unknown>} menu The parsed [menu] table.
 * @returns {Map<string, string>} « array.id » to its i18n key.
 */
function settingLabelKeys(menu) {
	const rows = new Map();
	for (const [array, entries] of Object.entries(menu)) {
		if (!Array.isArray(entries)) continue;
		for (const entry of entries) {
			if (entry && SETTING_TYPES.has(entry.type)) rows.set(`${array}.${entry.id}`, entry.i18n);
		}
	}
	return rows;
}

/**
 * Checks that every « needs_help » row now says its effect in its label.
 * @param {Map<string, string>} labelKeys Each setting row's label key.
 * @param {Record<string, {verdict: string, help?: {label_key: string, before: Record<string, string>}}>} review The reviewed rows.
 * @param {Record<string, Record<string, string>>} catalogues Each locale's catalogue.
 * @returns {string[]} What is wrong, empty when every such row has its help.
 */
function helpProblems(labelKeys, review, catalogues) {
	const found = [];
	const locales = Object.keys(catalogues).sort();
	for (const [row, entry] of Object.entries(review)) {
		if (entry.verdict !== 'needs_help') continue;
		const help = entry.help;
		if (!help || typeof help.label_key !== 'string') {
			found.push(`no help text for ${row}`);
			continue;
		}
		if (labelKeys.has(row) && labelKeys.get(row) !== help.label_key)
			found.push(`${row} draws ${labelKeys.get(row)}, not its help key ${help.label_key}`);
		const before = help.before || {};
		if (Object.keys(before).sort().join() !== locales.join())
			found.push(`${row} does not record its old label in every locale`);
		for (const locale of locales) {
			const text = catalogues[locale][help.label_key];
			if (typeof text !== 'string' || text.trim() === '')
				found.push(`${row}: ${help.label_key} is missing in ${locale}`);
			else if (text === before[locale])
				found.push(`${row}: the ${locale} label still lacks its help (« ${text} »)`);
		}
	}
	return found;
}

/**
 * Compares the rows with the review.
 * @param {Set<string>} rows The setting rows.
 * @param {Record<string, {verdict: string, why: string}>} review The reviewed rows.
 * @returns {string[]} What is wrong, empty when the review covers every row.
 */
function problems(rows, review) {
	const found = [];
	for (const row of rows) if (!(row in review)) found.push(`not reviewed: ${row}`);
	for (const [row, entry] of Object.entries(review)) {
		if (!rows.has(row)) found.push(`no longer a setting row: ${row}`);
		else if (!VERDICTS.has(entry.verdict))
			found.push(`unknown verdict for ${row}: ${entry.verdict}`);
		else if (typeof entry.why !== 'string' || entry.why.trim().length < 10)
			found.push(`no reason for ${row}`);
	}
	return found;
}

// The comparison itself: an unreviewed row, a stale entry and a bare verdict
// are each refused.
assert.deepEqual(problems(new Set(['a.b']), {}), ['not reviewed: a.b']);
assert.deepEqual(
	problems(new Set(), { 'a.b': { verdict: 'self_explained', why: 'says what it does' } }),
	['no longer a setting row: a.b']
);
assert.deepEqual(problems(new Set(['a.b']), { 'a.b': { verdict: 'needs_help', why: '' } }), [
	'no reason for a.b'
]);
assert.deepEqual(
	[
		...settingRows({
			x: [
				{ type: 'check', id: 'c' },
				{ type: 'command', id: 'd' }
			]
		})
	],
	['x.c']
);

// A needs_help row without its help, with its old label kept in one locale,
// or drawing another key than its help key is refused.
const catalogues = { en: { k: 'Words per minute (WPM)' }, fr: { k: 'MPM' } };
const helped = (before) => ({
	'a.b': { verdict: 'needs_help', why: 'an abbreviation', help: { label_key: 'k', before } }
});
assert.deepEqual(
	helpProblems(new Map([['a.b', 'k']]), helped({ en: 'WPM', fr: 'MPM' }), catalogues),
	['a.b: the fr label still lacks its help (« MPM »)']
);
assert.deepEqual(
	helpProblems(new Map(), { 'a.b': { verdict: 'needs_help', why: 'an abbreviation' } }, catalogues),
	['no help text for a.b']
);
assert.deepEqual(
	helpProblems(new Map([['a.b', 'other']]), helped({ en: 'WPM', fr: 'Mots' }), catalogues),
	['a.b draws other, not its help key k']
);
assert.deepEqual(helpProblems(new Map([['a.b', 'k']]), helped({ en: 'WPM' }), catalogues), [
	'a.b does not record its old label in every locale'
]);

const menu = parse(fs.readFileSync(path.join(MENU_DATA, 'menu.toml'), 'utf8')).menu;
const review = JSON.parse(fs.readFileSync(REVIEW_PATH, 'utf8')).rows;
const rows = settingRows(menu);
assert.ok(rows.size > 50, `menu.toml must declare its setting rows (found ${rows.size})`);
const localeFiles = fs.readdirSync(LOCALES_DIR).filter((name) => name.endsWith('.json'));
assert.equal(localeFiles.length, LOCALE_COUNT, `expected ${LOCALE_COUNT} locale catalogues`);
const localeCatalogues = Object.fromEntries(
	localeFiles.map((name) => [
		path.basename(name, '.json'),
		JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, name), 'utf8'))
	])
);
const found = [
	...problems(rows, review),
	...helpProblems(settingLabelKeys(menu), review, localeCatalogues)
];
if (found.length > 0) {
	console.error(
		'Tray setting rows and their help review (tray-settings-help-review.json) differ:\n  ' +
			found.join('\n  ')
	);
	process.exit(1);
}
const needing = Object.values(review).filter((entry) => entry.verdict === 'needs_help').length;
console.log(
	`test-menu-settings-help-review: OK — ${rows.size} setting rows reviewed, the ${needing} that need a help text carry it in their label in ${LOCALE_COUNT} locales.`
);
