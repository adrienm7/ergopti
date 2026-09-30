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
 *   4. A scope row hidden on a platform says why (reason_key).
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
 * Whether a row is drawn on one platform.
 * @param {object} row Manifest row.
 * @param {string} platform 'ahk', 'hs' or 'linux'.
 * @returns {boolean}
 */
function shownOn(row, platform) {
	if (row.platforms === undefined || row.platforms === 'both') return true;
	return Array.isArray(row.platforms) && row.platforms.includes(platform);
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
		if (!row || typeof row !== 'object' || !shownOn(row, platform)) continue;
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
		if (hidden && typeof row.reason_key !== 'string') {
			errors.push(`${menu}.${row.id} is hidden on some platform without a reason_key.`);
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
