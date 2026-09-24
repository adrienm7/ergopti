// tools/test/test-tap-keys-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Number-Row Tap Keys Single-Source Gate
 * DESCRIPTION:
 * The three number-row tap keys are declared once, in
 * _shared/modules/actions/tap_keys.json (id and each driver's key identity),
 * with their defaults in the features manifest (shortcuts.tap_keys.<id>). This
 * gate checks the two agree, that the Windows driver's static hotkeys and its
 * scancode table name the same keys in the same order, that those hotkeys are
 * created before the digit-row emulation's, and that every key has its
 * localized position name.
 *
 * WHY:
 * Windows cannot read the JSON for its hotkeys: a tap key must be a static
 * #HotIf hotkey created before the layout emulation's, so its scancodes are
 * written in AutoHotkey. Without this gate the two lists could drift and a key
 * would be offered in the menu that no hotkey listens to.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const KEYS = path.join(SP, '_shared', 'modules', 'actions', 'tap_keys.json');
const MANIFEST = path.join(SP, '_shared', 'modules', 'features', 'manifest.toml');
const AHK_LOGIC = path.join(SP, 'windows', 'infra', 'tap_keys.ahk');
const AHK_HOTKEYS = path.join(SP, 'windows', 'modules', 'shortcuts', 'tap_keys.ahk');
const AHK_ENTRY = path.join(SP, 'windows', 'ErgoptiPlus.ahk');
const AHK_WIN = path.join(SP, 'windows', 'modules', 'shortcuts', 'win.ahk');
const EN = path.join(SP, '_shared', 'data', 'locales', 'en.json');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const keys = JSON.parse(fs.readFileSync(KEYS, 'utf8')).keys;
check(Array.isArray(keys) && keys.length === 3, `tap_keys.json must declare 3 keys, found ${keys && keys.length}`);
const ids = keys.map((key) => key.id);
for (const key of keys) {
	check(/^SC0[0-9A-F]{2}$/.test(key.ahk), `${key.id}: ahk must be an AutoHotkey scancode name, got ${key.ahk}`);
	check(Array.isArray(key.hs) && key.hs.length > 0 && key.hs.every(Number.isInteger),
		`${key.id}: hs must list macOS keycodes`);
	check(Number.isInteger(key.linux) && key.linux > 0, `${key.id}: linux must be an evdev keycode`);
}

// Parsed as tools/build/build-features-manifest.js does: a nested
// [[features.X.Y]] block is, to TOML, a sub-array of the last [[features.X]]
// entry, so each block is rewritten into one flat [[entries]] array first.
const manifest = toml.parse(fs.readFileSync(MANIFEST, 'utf8').replace(
	/^\[\[features\.([^\]]+)\]\]\r?$/gm,
	(_match, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
));
const entries = (manifest.entries || []).filter((entry) => entry.path_prefix === 'shortcuts.tap_keys');
check(JSON.stringify(entries.map((entry) => entry.id)) === JSON.stringify(ids),
	`manifest shortcuts.tap_keys ids ${JSON.stringify(entries.map((e) => e.id))} must equal tap_keys.json ${JSON.stringify(ids)}`);
for (const entry of entries) {
	check(entry.type === 'action', `shortcuts.tap_keys.${entry.id} must be an action`);
	check(JSON.stringify(entry.platforms) === JSON.stringify(['ahk', 'hs', 'linux']),
		`shortcuts.tap_keys.${entry.id} must exist on all three drivers`);
}

// Windows: TAP_KEY_ORDER, TAP_KEY_SCANCODES and one static hotkey per key, each
// under the #HotIf of its own id, with no wildcard or pass-through prefix.
const read = (file) => fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
const ahk = read(AHK_LOGIC);
const hotkeys = read(AHK_HOTKEYS);
const order = (ahk.match(/global TAP_KEY_ORDER := \[([^\]]*)\]/) || [])[1] || '';
check(JSON.stringify(order.split(',').map((s) => s.trim().replace(/"/g, '')).filter(Boolean)) === JSON.stringify(ids),
	'windows TAP_KEY_ORDER must list the tap_keys.json ids in order');
for (const key of keys) {
	const code = parseInt(key.ahk.slice(2), 16);
	const hex = '0x' + code.toString(16).toUpperCase().padStart(2, '0');
	check(new RegExp(`"${key.id}", ${hex}\\b`).test(ahk), `windows TAP_KEY_SCANCODES must map ${key.id} to ${hex}`);
	const hotkey = new RegExp(`^#HotIf TapKeyShouldFire\\("${key.id}"\\)\\r?\\n${key.ahk}:: TapKeyFire\\("${key.id}"\\)$`, 'm');
	check(hotkey.test(hotkeys), `windows must bind ${key.ahk}:: (no * or ~) under #HotIf TapKeyShouldFire("${key.id}")`);
}

// The hotkeys must be created before the digit-row emulation's: AutoHotkey fires
// the earliest-created eligible #HotIf variant. And no other file binds a plain
// SC029 any more (the retired instant-screenshot hotkey did).
const entry = read(AHK_ENTRY);
const tapAt = entry.indexOf('#Include modules/shortcuts/tap_keys.ahk');
const layoutAt = entry.indexOf('#Include modules/keymap/layout.ahk');
check(tapAt > 0 && layoutAt > tapAt, 'ErgoptiPlus.ahk must include modules/shortcuts/tap_keys.ahk before modules/keymap/layout.ahk');
check(!/^SC029::/m.test(read(AHK_WIN)), 'modules/shortcuts/win.ahk must not bind SC029 itself');

// Every key names its position when it types nothing printable.
const en = JSON.parse(fs.readFileSync(EN, 'utf8'));
for (const id of ids) {
	check(typeof en[`menu.shortcuts.tap_keys.${id}`] === 'string', `en.json lacks menu.shortcuts.tap_keys.${id}`);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] number-row tap keys single source: ${checks} check(s) passed.\x1b[0m`);
