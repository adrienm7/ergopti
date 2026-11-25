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
const SETTING_TYPES = new Set(['check', 'choice', 'toggle']);
const VERDICTS = new Set(['self_explained', 'needs_help']);

/**
 * Lists the setting rows of a menu declaration as « array.id ».
 * @param {Record<string, unknown>} menu The parsed [menu] table.
 * @returns {Set<string>} The row names.
 */
function settingRows(menu) {
	const rows = new Set();
	for (const [array, entries] of Object.entries(menu)) {
		if (!Array.isArray(entries)) continue;
		for (const entry of entries) {
			if (entry && SETTING_TYPES.has(entry.type)) rows.add(`${array}.${entry.id}`);
		}
	}
	return rows;
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

const menu = parse(fs.readFileSync(path.join(MENU_DATA, 'menu.toml'), 'utf8')).menu;
const review = JSON.parse(fs.readFileSync(REVIEW_PATH, 'utf8')).rows;
const rows = settingRows(menu);
assert.ok(rows.size > 50, `menu.toml must declare its setting rows (found ${rows.size})`);
const found = problems(rows, review);
if (found.length > 0) {
	console.error(
		'Tray setting rows and their help review (tray-settings-help-review.json) differ:\n  ' +
			found.join('\n  ')
	);
	process.exit(1);
}
const needing = Object.values(review).filter((entry) => entry.verdict === 'needs_help').length;
console.log(
	`test-menu-settings-help-review: OK — ${rows.size} setting rows reviewed, ${needing} need a help text.`
);
