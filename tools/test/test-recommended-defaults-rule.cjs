// tools/test/test-recommended-defaults-rule.cjs

/**
 * ==============================================================================
 * MODULE: Recommended Defaults Rule Guard
 * DESCRIPTION:
 * Maintainer decision of 2026-10-24: recommend nothing that conflicts with the
 * system's own default, keep every combination reassignable, and say in the
 * menu to remove the system assignment first to avoid a double action. One
 * trigger debounce for all drivers, and MLX stays the macOS AI backend with its
 * reason shown where the recommendation appears.
 *
 * WHAT THIS PINS:
 *   1. Linux recommends "none" for every three- and four-finger swipe: the
 *      touchpad is read without being grabbed, so the desktop also acts.
 *   2. macOS recommends "none" for the three-finger tap (system Look up).
 *   3. The Gestures menu declares the shared note and both platform reasons,
 *      and the English locale carries their text. Each row Windows shows fits
 *      AutoHotkey's 260-unit menu item name in every locale.
 *   4. llm.trigger.debounce_ms is declared once: no per-platform override, the
 *      default and recommended equal _shared defaults.json, and every driver's
 *      generated config template carries that value.
 *   5. The macOS backend recommendation stays MLX, and the Backend submenu
 *      shows its reason (backend_mlx_suffix, naming Apple Silicon).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { parse: parseToml } = require('smol-toml');

const SP = path.resolve(__dirname, '..', '..', 'static', 'ergopti_plus');
const read = (rel) => fs.readFileSync(path.join(SP, rel), 'utf8');

const manifest = parseToml(
	read('_shared/modules/features/manifest.toml').replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_m, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	)
);
const entries = manifest.entries || [];

/** The recommended value of one entry on one platform. */
function recommended(prefix, id, platform) {
	const entry = entries.find((e) => e.path_prefix === prefix && e.id === id);
	assert.ok(entry, `manifest entry ${prefix}.${id} exists`);
	const perPlatform = entry.recommended_per_platform || {};
	return perPlatform[platform] !== undefined ? perPlatform[platform] : entry.recommended;
}

// 1. Linux: no recommended swipe the desktop also handles.
for (const finger of [3, 4]) {
	for (const dir of ['up', 'down', 'left', 'right']) {
		assert.equal(
			recommended('gestures', `swipe_${finger}_${dir}`, 'linux'),
			'none',
			`Linux must not recommend swipe_${finger}_${dir}: the desktop also acts on it`
		);
	}
}

// 2. macOS: the three-finger tap is the system's Look up.
assert.equal(recommended('gestures', 'tap_3', 'hs'), 'none', 'macOS tap_3 is Look up');

// 3. The menu says why and how to avoid the double action.
const en = JSON.parse(read('_shared/data/locales/en.json'));
const doc = parseToml(read('_shared/modules/features/manifest.toml'));
const listRow = ((doc.menu && doc.menu.gestures_menu) || []).find(
	(r) => r.id === 'gesture_recommended_notes'
);
assert.ok(listRow && listRow.type === 'list', 'the Gestures menu lists gesture_recommended_notes');
const templateRows = (doc.menu && doc.menu.gesture_recommended_notes) || [];
for (const [id, key] of [
	['gesture_recommended_note', 'menu.gestures.recommended_note'],
	['gesture_recommended_reason_linux', 'menu.gestures.recommended_reason_linux'],
	['gesture_recommended_reason_macos', 'menu.gestures.recommended_reason_macos'],
	['gesture_recommended_reason_windows', 'menu.gestures.recommended_reason_windows']
]) {
	const row = templateRows.find((r) => r.id === id);
	assert.ok(row, `the notes template declares ${id}`);
	assert.equal(row.type, 'label');
	assert.equal(row.i18n, key);
	assert.ok(typeof en[key] === 'string' && en[key].length > 20, `${key} has English text`);
}
// Each driver publishes the template.
for (const file of [
	'linux/ui/menu/menu_builder.lua',
	'macos/ui/menu/menu_gestures.lua',
	'windows/ui/menu/menu_gestures.ahk'
])
	assert.match(read(file), /"gesture_recommended_notes"/, `${file} publishes the notes`);
assert.match(en['menu.gestures.recommended_note'], /remove the system/i);
// Windows replaces the system's own assignment, so the "remove it first" advice
// is not shown there; its own note explains the greying instead.
const platformsOf = (id) => templateRows.find((r) => r.id === id).platforms;
assert.deepEqual(platformsOf('gesture_recommended_note'), ['hs', 'linux']);
assert.deepEqual(platformsOf('gesture_recommended_reason_windows'), ['ahk']);
assert.match(en['menu.gestures.recommended_reason_windows'], /greyed out/i);
assert.match(en['menu.gestures.recommended_reason_windows'], /no double action/i);
// AutoHotkey's Menu.Add refuses a name longer than MAX_PATH (260 UTF-16 units)
// with "Menu item name too long", and the row never appears. The French Windows
// note was 263 units: the tray lost it and startup logged an error. Every row of
// these notes that Windows shows must fit in every locale.
const AHK_MENU_ITEM_MAX_UNITS = 260;
const localeDir = path.join(SP, '_shared', 'data', 'locales');
const localeFiles = fs.readdirSync(localeDir).filter((name) => name.endsWith('.json'));
assert.ok(localeFiles.length >= 21, 'every locale is checked');
for (const row of templateRows) {
	if (row.type !== 'label' || (row.platforms && !row.platforms.includes('ahk'))) continue;
	for (const file of localeFiles) {
		const text = JSON.parse(fs.readFileSync(path.join(localeDir, file), 'utf8'))[row.i18n];
		assert.equal(typeof text, 'string', `${file} translates ${row.i18n}`);
		assert.ok(
			text.length <= AHK_MENU_ITEM_MAX_UNITS,
			`${file} ${row.i18n} is ${text.length} UTF-16 units; AutoHotkey menus refuse more than ${AHK_MENU_ITEM_MAX_UNITS}`
		);
	}
}

// 4. One debounce.
const defaults = JSON.parse(read('_shared/modules/llm/defaults.json'));
const debounce = entries.find((e) => e.path_prefix === 'llm.trigger' && e.id === 'debounce_ms');
assert.ok(debounce, 'llm.trigger.debounce_ms is declared');
assert.equal(debounce.recommended_per_platform, undefined, 'no per-platform recommended debounce');
assert.equal(debounce.default_per_platform, undefined, 'no per-platform default debounce');
assert.equal(debounce.default, defaults.llm_debounce_ms);
assert.equal(debounce.recommended, defaults.llm_debounce_ms);
for (const driver of ['windows', 'macos', 'linux']) {
	const template = parseToml(read(`${driver}/_generated/config_template.toml`));
	assert.equal(
		template.llm.trigger.debounce_ms,
		defaults.llm_debounce_ms,
		`${driver} config template debounce_ms`
	);
}

// 5. MLX on macOS, with its reason.
assert.equal(recommended('llm.models', 'selected', 'hs'), 'mlx');
assert.match(
	read('macos/ui/menu/menu_llm/backend_labels.lua'),
	/\bmlx\s*=\s*"menu\.llm\.backend_mlx_suffix"/
);
assert.match(en['menu.llm.backend_mlx_suffix'], /Apple Silicon/);

console.log('recommended defaults rule: ok');
