// tools/test/test-menu-first-group.cjs

/**
 * ==============================================================================
 * MODULE: Every Settings Menu Opens With Its Switch, Restore and Clear
 * DESCRIPTION:
 * The maintainer's rule of 2026-09-30, for every menu and submenu that owns
 * settings, on every driver: the first group is the menu's master switch (when
 * it has one), then « ↺ Restaurer les valeurs conseillées » (scope_restore),
 * then « ✕ Tout effacer (comportement du système) » (scope_clear), then a
 * separator, and no restore or clear row anywhere else in that menu.
 *
 * The Gestures menu is why it exists: its switch was followed by a separator,
 * the system rows, and only then its clear and restore, while the Tap-Holds
 * menu put them after the separator. The same two rows sat in a different place
 * in each menu, under three different ids.
 *
 * WHAT THIS HOLDS, for each platform's projection of the manifest (the rows
 * the shared renderers draw, in declared order, with platform-filtered rows
 * removed and separators collapsed the way both renderers collapse them):
 *   1. A scope row is a `command` row whose id and label agree: scope_restore
 *      reads common.restore_recommended and scope_clear common.clear_to_system,
 *      and no other row carries either label.
 *   2. A menu that shows a scope row opens with [switch] restore clear '---'.
 *      A declared restore-only menu shows no clear row at all.
 *   3. No scope row follows that first separator.
 *   4. A scope row left out of a platform is classified: greyed there with its
 *      reason (`unavailable = "grey"`, drawn and so held to 2 and 3) or hidden
 *      as not applicable (`unavailable = "hide"`).
 * The drivers' suites click the rows of the rendered menus themselves.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'menu',
	'menu_manifest.json'
);

const PLATFORMS = ['ahk', 'hs', 'linux'];
const RESTORE = { id: 'scope_restore', i18n: 'common.restore_recommended' };
const CLEAR = { id: 'scope_clear', i18n: 'common.clear_to_system' };
const WORD_EXPANDER_CONTROLS = JSON.parse(
	fs.readFileSync(
		path.join(
			ROOT,
			'static',
			'ergopti_plus',
			'_shared',
			'tests',
			'corpus',
			'menus',
			'word_expander_controls.json'
		),
		'utf8'
	)
).rows;

const WRAP_CONTROLS = JSON.parse(
	fs.readFileSync(
		path.join(
			ROOT,
			'static',
			'ergopti_plus',
			'_shared',
			'tests',
			'corpus',
			'menus',
			'wrap_symbol_controls.json'
		),
		'utf8'
	)
);
const WRAP_GLOBAL = WRAP_CONTROLS.sections.find(
	(section) => section.section === 'wrap_symbols_global_controls'
).rows;

// Menus whose clear row the maintainer retired: the first group is the switch
// and the restore alone, and a clear row there is a regression.
const RESTORE_ONLY = {
	llm_menu: 'the maintainer said clearing the AI settings makes no sense (ai-menu-no-clear)',
	metrics_menu: 'the maintainer said clearing the metrics settings makes no sense (2026-09-30)'
};

// The menus that must keep declaring a first group, so a rename or a deleted
// row cannot turn this gate into a scan of nothing.
const EXPECTED_MENUS = [
	'configuration_menu',
	'gestures_menu',
	'hotstrings_menu',
	'layout_menu',
	'llm_menu',
	'metrics_menu',
	'script_control_group',
	'shortcuts_menu',
	'tap_holds_menu'
];

// ==================================================
// ==================================================
// ======= 1/ The projection ========================
// ==================================================
// ==================================================

/**
 * Whether a row is declared for one platform.
 * @param {object} row Manifest row.
 * @param {string} platform 'ahk', 'hs' or 'linux'.
 * @returns {boolean}
 */
function shownOn(row, platform) {
	if (row.platforms === undefined || row.platforms === 'both') return true;
	return Array.isArray(row.platforms) && row.platforms.includes(platform);
}

/**
 * Whether a row is drawn on one platform: declared there, or greyed there as
 * not yet ported (`unavailable = "grey"`).
 * @param {object} row Manifest row.
 * @param {string} platform 'ahk', 'hs' or 'linux'.
 * @returns {boolean}
 */
function drawnOn(row, platform) {
	return shownOn(row, platform) || row.unavailable === 'grey';
}

/**
 * The rows one platform draws, separators collapsed: none first, none twice in
 * a row, none last — the shape both renderers give the tray.
 * @param {object[]} rows Manifest rows of one menu.
 * @param {string} platform
 * @returns {object[]}
 */
function project(rows, platform) {
	const kept = [];
	for (const row of rows) {
		if (!row || typeof row !== 'object' || !drawnOn(row, platform)) continue;
		if (row.type === '---') {
			if (kept.length > 0 && kept[kept.length - 1].type !== '---') kept.push(row);
		} else {
			kept.push(row);
		}
	}
	while (kept.length > 0 && kept[kept.length - 1].type === '---') kept.pop();
	return kept;
}

/**
 * Which scope row a manifest row is: 'restore', 'clear' or null.
 * @param {object} row
 * @returns {string|null}
 */
function scopeKind(row) {
	if (!row || typeof row !== 'object') return null;
	if (row.id === RESTORE.id || row.i18n === RESTORE.i18n) return 'restore';
	if (row.id === CLEAR.id || row.i18n === CLEAR.i18n) return 'clear';
	return null;
}

// ==================================================
// ==================================================
// ======= 2/ The rule ==============================
// ==================================================
// ==================================================

/**
 * Checks one menu against the rule on every platform.
 * @param {string} menu Manifest key.
 * @param {object[]} rows Its rows.
 * @param {string[]} errors Collected failures.
 * @returns {number} Platform projections that showed a scope row.
 */
function checkMenu(menu, rows, errors) {
	// This historical bulk-action head owns no settings scope or master switch.
	// Validate its exact declaration on all three platforms rather than exempting
	// every restore label outside a scope group from the first-group rule.
	if (menu === 'word_expanders_menu') {
		checkWordExpanderMenu(rows, errors);
		return 0;
	}
	if (menu === 'wrap_symbols_global_controls') {
		checkWrapBulkHead(rows, errors);
		return 0;
	}
	let checked = 0;
	for (const row of rows) {
		const kind = scopeKind(row);
		if (kind === null) continue;
		const want = kind === 'restore' ? RESTORE : CLEAR;
		if (row.type !== 'command' || row.id !== want.id || row.i18n !== want.i18n) {
			errors.push(
				`${menu}: a ${kind} row must be a command "${want.id}" reading ${want.i18n}, ` +
					`found ${row.type} "${row.id}" reading ${row.i18n}.`
			);
		}
		const hidden = PLATFORMS.some((platform) => !shownOn(row, platform));
		if (hidden && row.unavailable !== 'hide' && typeof row.reason_key !== 'string') {
			errors.push(
				`${menu}.${row.id} is left out of some platform without a reason_key or unavailable = "hide".`
			);
		}
	}
	for (const platform of PLATFORMS) {
		const shown = project(rows, platform);
		if (!shown.some((row) => scopeKind(row) !== null)) continue;
		checked += 1;
		const where = `${menu} (${platform})`;
		let at = shown[0] && shown[0].type === 'toggle' ? 1 : 0;
		const expected = [];
		if (at === 1) expected.push(shown[0].id);
		if (scopeKind(shown[at]) !== 'restore') {
			errors.push(`${where} must open with the restore row, found "${describe(shown[at])}".`);
			continue;
		}
		expected.push(RESTORE.id);
		at += 1;
		if (scopeKind(shown[at]) === 'clear') {
			if (RESTORE_ONLY[menu]) {
				errors.push(`${where} shows a clear row, retired there: ${RESTORE_ONLY[menu]}.`);
				continue;
			}
			expected.push(CLEAR.id);
			at += 1;
		} else if (!RESTORE_ONLY[menu]) {
			errors.push(`${where} has no clear row right after its restore row.`);
			continue;
		}
		if (!shown[at] || shown[at].type !== '---') {
			errors.push(
				`${where}: the first group [${expected.join(', ')}] must end with a separator, ` +
					`found "${describe(shown[at])}".`
			);
			continue;
		}
		for (const later of shown.slice(at + 1)) {
			if (scopeKind(later) !== null)
				errors.push(`${where} shows "${later.id}" after its first group.`);
		}
	}
	return checked;
}

/**
 * The existing three bulk commands, separator and dynamic catalogue must remain
 * one complete head on every driver. Expectations come from an independent corpus.
 * @param {object[]} rows Manifest rows.
 * @param {string[]} errors Collected failures.
 */
function checkWordExpanderMenu(rows, errors) {
	for (const platform of PLATFORMS) {
		const shown = project(rows, platform);
		const where = `word_expanders_menu (${platform})`;
		if (shown.length !== 5) {
			errors.push(`${where} must retain three bulk commands, a separator and its catalogue.`);
		}
		for (const [index, expected] of WORD_EXPANDER_CONTROLS.entries()) {
			const row = shown[index];
			if (
				!row ||
				row.type !== 'command' ||
				row.id !== expected.id ||
				row.i18n !== expected.i18n ||
				(row.command !== undefined && row.command !== expected.id) ||
				JSON.stringify(row.disabled_when) !== JSON.stringify(['word_expanders_ready'])
			) {
				errors.push(
					`${where} bulk command ${index + 1} must retain ${expected.id}, its label and readiness owner.`
				);
			}
		}
		if (!shown[3] || shown[3].type !== '---') {
			errors.push(`${where} must separate the bulk commands from individual delimiters.`);
		}
		if (!shown[4] || shown[4].type !== 'list' || shown[4].id !== 'word_expander_entries') {
			errors.push(`${where} must retain its native delimiter catalogue provider.`);
		}
	}
}

/** The existing native bulk head keeps its complete independent declaration. */
function checkWrapBulkHead(rows, errors) {
	for (const platform of PLATFORMS) {
		// Its trailing separator separates the subsequent native catalogue;
		// projection must retain that boundary within this composed fragment.
		const shown = rows.filter((row) => shownOn(row, platform));
		const expected = WRAP_CONTROLS.platforms.includes(platform) ? WRAP_GLOBAL : [];
		if (shown.length !== expected.length)
			errors.push(`wrap_symbols_global_controls (${platform}) lost its complete bulk head.`);
		for (const [index, wanted] of expected.entries()) {
			const row = shown[index];
			const valid = wanted.separator
				? row?.type === '---'
				: row?.type === 'command' &&
					row.id === wanted.id &&
					row.i18n === wanted.i18n &&
					(row.command === undefined || row.command === wanted.id) &&
					JSON.stringify(row.disabled_when) === JSON.stringify(wanted.disabled_when);
			if (!valid)
				errors.push(`wrap_symbols_global_controls (${platform}) changed bulk row ${index + 1}.`);
		}
		for (const row of rows) {
			if (
				row.unavailable !== 'hide' ||
				!Array.isArray(row.platforms) ||
				JSON.stringify(row.platforms) !== JSON.stringify(WRAP_CONTROLS.platforms)
			)
				errors.push('Wrapping controls must keep their declared native capability boundary.');
		}
	}
}

/**
 * A row as a failure message names it.
 * @param {object|undefined} row
 * @returns {string}
 */
function describe(row) {
	if (!row) return 'nothing';
	return row.type === '---' ? '---' : row.id || row.i18n || row.type;
}

// The rule on the shapes it must tell apart, so a broken projection cannot pass.
// A defect every platform shows counts once per platform.
{
	const toggle = { type: 'toggle', id: 'x_toggle', i18n: 'menu.x.enable' };
	const restore = { type: 'command', ...RESTORE };
	const clear = { type: 'command', ...CLEAR };
	const sep = { type: '---' };
	const other = { type: 'command', id: 'other', i18n: 'menu.other' };
	const run = (rows, menu = 'fixture_menu') => {
		const errors = [];
		checkMenu(menu, rows, errors);
		return errors;
	};
	assert.deepEqual(run([toggle, restore, clear, sep, other]), []);
	assert.deepEqual(run([restore, clear, sep, other]), [], 'a menu without a switch');
	assert.equal(run([toggle, clear, restore, sep, other]).length, 3, 'clear before restore');
	assert.equal(run([toggle, sep, other, restore, clear]).length, 3, 'rows after the separator');
	assert.equal(run([toggle, restore, sep, other]).length, 3, 'a missing clear');
	assert.deepEqual(run([toggle, restore, sep, other], 'metrics_menu'), [], 'a restore-only menu');
	assert.equal(
		run([toggle, restore, clear, sep, other], 'llm_menu').length,
		3,
		'a restore-only menu shows no clear row'
	);
	assert.equal(run([toggle, restore, clear, other, sep]).length, 3, 'no separator after the group');
	assert.equal(run([toggle, restore, clear, sep, other, clear]).length, 3, 'a second clear row');
	const hidden = { ...clear, platforms: ['ahk'] };
	assert.equal(run([toggle, restore, hidden, sep, other]).length, 3, 'hs and linux lose the clear');
	const greyed = { ...clear, platforms: ['ahk'], unavailable: 'grey', reason_key: 'r' };
	assert.deepEqual(
		run([toggle, restore, greyed, sep, other]),
		[],
		'a greyed clear is drawn in place'
	);
	const reorderedGrey = { ...restore, platforms: ['ahk'], unavailable: 'grey', reason_key: 'r' };
	assert.equal(
		run([toggle, clear, reorderedGrey, sep, other]).length,
		3,
		'a greyed row keeps its order'
	);
	const renamed = { type: 'command', id: 'disable_all', i18n: CLEAR.i18n };
	assert.equal(
		run([toggle, restore, renamed, sep, other]).length,
		1,
		'a clear row under another id'
	);
	const onlyAhk = { ...sep, platforms: ['ahk'] };
	assert.equal(
		run([toggle, restore, clear, onlyAhk, other]).length,
		2,
		'hs/linux lose the separator'
	);
}

// The bounded bulk-head exception must refuse malformed and platform-specific
// declarations, while all original scope-shape assertions above remain intact.
{
	assert.equal(
		WORD_EXPANDER_CONTROLS.length,
		3,
		'the independent corpus covers every bulk command'
	);
	const valid = [
		...WORD_EXPANDER_CONTROLS.map((row) => ({
			type: 'command',
			...row,
			disabled_when: ['word_expanders_ready']
		})),
		{ type: '---' },
		{ type: 'list', id: 'word_expander_entries' }
	];
	const run = (rows) => {
		const errors = [];
		checkMenu('word_expanders_menu', rows, errors);
		return errors;
	};
	assert.deepEqual(run(valid), []);
	const mutate = (fn) => {
		const rows = JSON.parse(JSON.stringify(valid));
		fn(rows);
		assert.ok(run(rows).length > 0, 'a changed bulk head must be rejected');
	};
	mutate((rows) => rows.splice(0, 1));
	mutate((rows) => ([rows[0], rows[2]] = [rows[2], rows[0]]));
	mutate((rows) => (rows[2].i18n = 'common.other'));
	mutate((rows) => (rows[2].id = 'scope_restore'));
	mutate((rows) => (rows[0].type = 'toggle'));
	mutate((rows) => delete rows[0].disabled_when);
	mutate((rows) => (rows[0].platforms = ['ahk']));
	mutate((rows) => (rows[3].type = 'command'));
	mutate((rows) => (rows[4].id = 'missing_catalogue'));
	mutate((rows) => rows.push({ type: 'command', ...RESTORE }));
}

// The bulk-management fragment cannot be treated as an arbitrary scope exception.
{
	assert.equal(WRAP_GLOBAL.length, 4);
	const valid = WRAP_GLOBAL.map((row) => ({
		...(row.separator ? { type: '---' } : { type: 'command', ...row }),
		platforms: ['ahk', 'hs'],
		unavailable: 'hide'
	}));
	const run = (rows) => {
		const errors = [];
		checkMenu('wrap_symbols_global_controls', rows, errors);
		return errors;
	};
	assert.deepEqual(run(valid), []);
	for (const mutate of [
		(rows) => rows.splice(0, 1),
		(rows) => ([rows[0], rows[2]] = [rows[2], rows[0]]),
		(rows) => (rows[2].i18n = 'wrong'),
		(rows) => (rows[2].id = 'scope_restore'),
		(rows) => (rows[0].type = 'toggle'),
		(rows) => delete rows[0].disabled_when,
		(rows) => (rows[0].platforms = ['ahk']),
		(rows) => rows[0].platforms.push('linux'),
		(rows) => delete rows[3].unavailable,
		(rows) => (rows[3].type = 'command'),
		(rows) => rows.push({ type: 'command', ...CLEAR })
	]) {
		const rows = JSON.parse(JSON.stringify(valid));
		mutate(rows);
		assert.ok(run(rows).length > 0);
	}
}

// ==================================================
// ==================================================
// ======= 3/ The manifest ==========================
// ==================================================
// ==================================================

const errors = [];
const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
let projections = 0;
const menusWithScopes = new Set();
for (const [menu, rows] of Object.entries(manifest)) {
	if (!Array.isArray(rows) || menu === 'top_level') continue;
	const checked = checkMenu(menu, rows, errors);
	if (checked > 0) menusWithScopes.add(menu);
	projections += checked;
}
if (!Array.isArray(manifest.wrap_symbols_global_controls)) {
	errors.push('Wrapping-symbol bulk declaration is missing.');
}
if (!Array.isArray(manifest.word_expanders_menu)) {
	errors.push('word_expanders_menu is missing: the shared bulk-head scan read nothing.');
}
for (const menu of EXPECTED_MENUS) {
	if (!menusWithScopes.has(menu))
		errors.push(`${menu} shows no scope row on any platform — the scan read nothing there.`);
}
for (const menu of Object.keys(RESTORE_ONLY)) {
	if (!Array.isArray(manifest[menu]))
		errors.push(`the restore-only exception names ${menu}, which the manifest no longer has.`);
}

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] A settings menu must open with [switch] restore clear, then a separator:\x1b[0m'
	);
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${menusWithScopes.size} settings menu(s), ${projections} platform projection(s): ` +
		'each opens with [switch] restore clear then a separator, and no scope row follows.\x1b[0m'
);
