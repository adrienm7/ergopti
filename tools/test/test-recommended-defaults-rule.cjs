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
 *   2. The three-finger tap recommends left_click_toggle on every driver,
 *      macOS included although the system uses it for Look up (maintainer's
 *      choice, 2026-10-28).
 *   3. The Gestures menu shows a short « Infos… » command instead of the
 *      explanation rows; each driver opens its native info dialog with the
 *      shared note and its platform's reason (Windows: its reason only), and
 *      every row the menu declares stays a short caption in every locale.
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

// 2. macOS: the three-finger tap is the system's Look up, yet it stays
// recommended like on Windows and Linux by the maintainer's choice (2026-10-28).
for (const platform of ['ahk', 'hs', 'linux'])
	assert.equal(
		recommended('gestures', 'tap_3', platform),
		'left_click_toggle',
		`tap_3 recommends left_click_toggle on ${platform}`
	);

// 3. The menu says why and how to avoid the double action, behind « Infos… ».
const en = JSON.parse(read('_shared/data/locales/en.json'));
const doc = parseToml(read('_shared/modules/features/manifest.toml'));
const gesturesMenu = (doc.menu && doc.menu.gestures_menu) || [];
const infoRow = gesturesMenu.find((r) => r.id === 'gesture_recommended_info');
assert.ok(infoRow && infoRow.type === 'command', 'the Gestures menu declares the Infos command');
assert.equal(infoRow.i18n, 'menu.gestures.recommended_info');
assert.equal(infoRow.platforms, undefined, 'the Infos row is on every driver');
// The explanation used to be menu rows: a whole paragraph in the tray, and a
// French Windows row AutoHotkey dropped (Menu.Add refuses more than 260 units).
assert.ok(
	!gesturesMenu.some((r) => r.type === 'label' || r.id === 'gesture_recommended_notes'),
	'the Gestures menu shows no explanation row'
);
assert.equal(doc.menu.gesture_recommended_notes, undefined, 'the notes template is retired');
for (const key of [
	'menu.gestures.recommended_note',
	'menu.gestures.recommended_reason_linux',
	'menu.gestures.recommended_reason_macos',
	'menu.gestures.recommended_reason_windows'
])
	assert.ok(typeof en[key] === 'string' && en[key].length > 20, `${key} has English text`);
assert.match(en['menu.gestures.recommended_note'], /remove the system/i);
assert.match(en['menu.gestures.recommended_reason_macos'], /Look up/);
assert.match(en['menu.gestures.recommended_reason_windows'], /greyed out/i);
assert.match(en['menu.gestures.recommended_reason_windows'], /no double action/i);
// Every row the Gestures menu declares itself stays a short menu caption.
const MENU_CAPTION_MAX_UNITS = 80;
const localeDir = path.join(SP, '_shared', 'data', 'locales');
const localeFiles = fs.readdirSync(localeDir).filter((name) => name.endsWith('.json'));
assert.ok(localeFiles.length >= 21, 'every locale is checked');
for (const file of localeFiles) {
	const strings = JSON.parse(fs.readFileSync(path.join(localeDir, file), 'utf8'));
	const info = strings['menu.gestures.recommended_info'];
	assert.equal(typeof info, 'string', `${file} translates menu.gestures.recommended_info`);
	assert.ok(info.endsWith('…') && info.length <= 16, `${file} Infos caption is short: ${info}`);
	for (const row of gesturesMenu) {
		if (typeof row.i18n !== 'string') continue;
		const text = strings[row.i18n];
		assert.equal(typeof text, 'string', `${file} translates ${row.i18n}`);
		assert.ok(
			text.length <= MENU_CAPTION_MAX_UNITS,
			`${file} ${row.i18n} is ${text.length} UTF-16 units; a Gestures menu row is a caption, not a paragraph`
		);
	}
}
// Each driver opens its existing native info dialog with the explanation. On
// Windows the driver takes the system's assignment over itself, so the shared
// "remove it first" note is not shown there.
const DIALOG_OWNERS = [
	{
		file: 'windows/ui/menu/menu_gestures.ahk',
		register: /MenuCommand\.GESTURE_RECOMMENDED_INFO, \(\*\) => GestureShowRecommendedInfo\(\)/,
		body: /\nGestureShowRecommendedInfo\(\) \{\n([\s\S]*?)\n\}/,
		helper: 'Ui_MsgBox(',
		keys: ['menu.gestures.recommended_reason_windows'],
		absent: ['menu.gestures.recommended_note']
	},
	{
		file: 'macos/ui/menu/menu_gestures.lua',
		register: /COMMAND\.GESTURE_RECOMMENDED_INFO\] = cmd_recommended_info\n/,
		body: /local function cmd_recommended_info\(\)\n([\s\S]*?)\n\tend\n/,
		helper: 'dialog.block_alert(',
		keys: ['menu.gestures.recommended_note', 'menu.gestures.recommended_reason_macos'],
		absent: []
	},
	{
		file: 'linux/ui/menu/menu_builder.lua',
		register: /COMMAND\.GESTURE_RECOMMENDED_INFO\] = function\(\)\n([\s\S]*?)\n\tend\n/,
		body: /COMMAND\.GESTURE_RECOMMENDED_INFO\] = function\(\)\n([\s\S]*?)\n\tend\n/,
		helper: 'show_info(',
		keys: ['menu.gestures.recommended_note', 'menu.gestures.recommended_reason_linux'],
		absent: []
	}
];
for (const owner of DIALOG_OWNERS) {
	const source = read(owner.file);
	assert.match(source, owner.register, `${owner.file} registers the Infos command`);
	assert.doesNotMatch(source, /gesture_recommended_notes/, `${owner.file} publishes no notes rows`);
	const body = (source.match(owner.body) || [])[1];
	assert.ok(body, `${owner.file} defines the Infos handler`);
	assert.ok(body.includes(owner.helper), `${owner.file} Infos uses ${owner.helper.slice(0, -1)}`);
	for (const key of owner.keys)
		assert.ok(body.includes(`"${key}"`), `${owner.file} Infos shows ${key}`);
	for (const key of owner.absent)
		assert.ok(!body.includes(`"${key}"`), `${owner.file} Infos does not show ${key}`);
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
