// tools/test/test-menu-category-off-rule.cjs

/**
 * ==============================================================================
 * MODULE: One Category-Off Rule, Declared in the Manifest
 * DESCRIPTION:
 * The maintainer's rule of 2026-11-02 for every top-level category. The row in
 * the main menu is never greyed; while the category is off, its submenu keeps
 * only the row that turns it on and the rows that only read data, every other
 * row greyed with a reason.
 *
 * WHAT THIS HOLDS:
 *   1. Each category's menu declares its enable row, on the platforms that
 *      have an off state; the parents in the main menu declare no greying.
 *   2. The reader rows are the listed ones: a new exception is a decision.
 *   3. The generator refuses a declaration the renderers cannot honour.
 *   4. The reason opens with a short head in every locale.
 *   5. Both renderers apply the rule in their build, and no driver restates a
 *      refusal behind a reader row.
 * Each driver's suite builds its real menus: the rows themselves are held there.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const { shared } = require('../lib/paths.cjs');
const availability = require('../lib/menu-row-availability.cjs');

const ROOT = path.join(__dirname, '..', '..');
const manifest = JSON.parse(fs.readFileSync(shared('menu/data/menu_manifest.json'), 'utf8'));
const REASON_KEY = 'menu.category_off_reason';
const REASON_HEAD_MAX = 32;

// Parent id -> its menu, its enable row and the drivers that have an off state.
// The layout is installed as a system input source on macOS and Linux, so only
// Windows, which emulates it, can switch it off.
const ALL = ['ahk', 'hs', 'linux'];
const CATEGORIES = {
	tap_holds: { menu: 'tap_holds_menu', enable: 'tapholds_toggle', platforms: ALL },
	shortcuts: { menu: 'shortcuts_menu', enable: 'shortcuts_toggle', platforms: ALL },
	gestures: { menu: 'gestures_menu', enable: 'gestures_toggle', platforms: ALL },
	keyboard_layout: { menu: 'layout_menu', enable: 'layout_toggle', platforms: ['ahk'] },
	hotstrings: { menu: 'hotstrings_menu', enable: 'hotstrings_toggle', platforms: ALL },
	metrics: { menu: 'metrics_menu', enable: 'metrics_toggle', platforms: ALL },
	llm: { menu: 'llm_menu', enable: 'llm_toggle', platforms: ALL },
	agent: { menu: 'agent_menu', enable: 'agent_mode', platforms: ALL }
};
const READERS = ['metrics_menu.show_typing', 'metrics_menu.show_apps'];

/**
 * Runs the validator over a one-menu table.
 * @param {object[]} rows The menu's rows.
 * @returns {Function} What assert.throws calls.
 */
function validating(rows) {
	return () => availability.validateMenuAvailability({ probe: rows });
}

const toggle = { type: 'toggle', id: 'probe', i18n: 'x', submenu_off_reason_key: REASON_KEY };
const reader = { type: 'command', id: 'reader', i18n: 'x', readable_when_off: true };

for (const [parent, category] of Object.entries(CATEGORIES)) {
	const rows = manifest[category.menu];
	const enable = rows.find((row) => row.id === category.enable);
	assert.ok(enable, `${category.menu} holds its enable row`);
	assert.equal(enable.submenu_off_reason_key, REASON_KEY, `${parent} declares the rule`);
	assert.deepEqual(enable.platforms || ALL, category.platforms, `${parent} off state`);
	const top = manifest.top_level.find((row) => row.id === parent);
	assert.ok(top, `${parent} is a top-level category`);
	assert.equal(top.disabled_when, undefined, `${parent}: the main-menu row is never greyed`);
}
// A new top-level checkbox is a new category: it has to join the table.
for (const row of manifest.top_level) {
	if (row.checked_when !== undefined)
		assert.ok(CATEGORIES[row.id], `top-level row ${row.id} is listed as a category`);
}

const readers = [];
for (const [key, rows] of Object.entries(manifest)) {
	if (!Array.isArray(rows)) continue;
	for (const row of rows) {
		if (row?.readable_when_off) readers.push(`${key}.${row.id}`);
		if (row?.submenu_off_reason_key)
			assert.ok(
				Object.values(CATEGORIES).some((category) => category.menu === key),
				`${key}: only a top-level category is gated`
			);
	}
}
assert.deepEqual(readers.sort(), [...READERS].sort(), 'the rows flagged as readers');

validating([toggle, reader])();
assert.throws(validating([toggle, toggle]), /one enable row/);
assert.throws(validating([reader]), /gated menu/);
assert.throws(validating([toggle, { ...reader, type: 'check' }]), /gated menu/);
assert.throws(validating([toggle, { ...reader, disabled_when: ['x'] }]), /grey on state/);
assert.throws(validating([{ ...toggle, submenu_off_value: 'off' }]), /toggle, or a choice/);
assert.throws(
	validating([
		{ ...toggle, type: 'choice', submenu_off_value: 'none', choices: [{ value: 'off' }] }
	]),
	/one of the row's choices/
);

const localesDir = shared('core/i18n/data/locales');
for (const file of fs.readdirSync(localesDir).filter((name) => name.endsWith('.json'))) {
	const text = JSON.parse(fs.readFileSync(path.join(localesDir, file), 'utf8'))[REASON_KEY];
	assert.equal(typeof text, 'string', `${file} names the reason`);
	const head = text.split(/[:：]/)[0].trim();
	assert.ok(head !== text && head.length <= REASON_HEAD_MAX, `${file}: short head "${head}"`);
}

const lua = fs.readFileSync(shared('menu/engine/renderer.lua'), 'utf8');
assert.match(lua, /apply_category_off\(finished, roles, off_reason_key\)/);
const windows = 'static/ergopti_plus/windows/';
const ahk = fs.readFileSync(path.join(ROOT, windows, 'infra/manifest_menu.ahk'), 'utf8');
assert.match(ahk, /_MR_ApplyCategoryOff\(Result, OffRule\)/);
const keystats = fs.readFileSync(
	path.join(ROOT, windows, 'modules/keystats/keystats_ui.ahk'),
	'utf8'
);
assert.doesNotMatch(keystats, /RequireEnabled/, 'a reader row opens its window with metrics off');

console.log('test-menu-category-off-rule: passed.');
