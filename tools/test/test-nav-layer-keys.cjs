// tools/test/test-nav-layer-keys.cjs

/**
 * ==============================================================================
 * MODULE: Navigation Layer Keys Gate
 * DESCRIPTION:
 * Ergopti Studio's « Navigation layer » entries import the user's layers.toml
 * as the source's nav layer, held by the key whose hold enters the layer
 * today. Each driver finds that key in its own vocabulary (the
 * nav_layer_save owners); this gate holds them to one answer.
 *
 * WHAT IS CHECKED:
 * 1. The Windows tap-hold id -> registry code table
 *    (windows/platform/remap/nav_layer_save.ahk) covers exactly the Windows
 *    column of [tap_hold.catalog], and each key is the one the Linux engine
 *    remaps (its evdev code) under the same catalogue entry.
 * 2. The corpus's recommended layer keys
 *    (_shared/tests/corpus/layer_editor/layer_keys.json, which the driver suites
 *    read) are what each driver's shipped tap-hold keys hold the layer with.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const DRIVERS = path.dirname(shared());
const read = (p) => fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '');
const REGISTRY = JSON.parse(read(shared('layouts', 'data', 'keycodes', 'physical_keys.json')));
const CORPUS = JSON.parse(read(shared('tests', 'corpus', 'layer_editor', 'layer_keys.json')));
const DEFAULTS = TOML.parse(read(shared('tap_hold', 'data', 'defaults.toml')));
const PRESET = TOML.parse(read(shared('layouts', 'data', 'layers.recommended.toml')));
const WINDOWS_NAV = read(path.join(DRIVERS, 'windows', 'platform', 'remap', 'nav_layer_save.ahk'));
const LINUX_ENGINE = read(path.join(DRIVERS, 'linux', 'platform', 'remap', 'tap_hold_engine.lua'));
const MACOS_NAV_LAYER = read(path.join(DRIVERS, 'macos', 'platform', 'remap', 'nav_layer.lua'));

// Floor: a table that stopped being read must not pass empty.
const MIN_TAP_HOLD_KEYS = 10;

const errors = [];
const fail = (msg) => errors.push(msg);

const tableMatch = /global NAV_LAYER_SAVE_TAP_HOLD_KEY_CODES := Map\(([\s\S]*?)\n\)/.exec(
	WINDOWS_NAV
);
const windowsCodes = {};
if (!tableMatch) fail('nav_layer_save.ahk has no NAV_LAYER_SAVE_TAP_HOLD_KEY_CODES table');
else {
	const pairs = [...tableMatch[1].matchAll(/"([a-z_]+)",\s*"([A-Za-z]+)"/g)];
	for (const [, id, code] of pairs) windowsCodes[id] = code;
}
const engineMatch = /M\.KEY_CODES\s*=\s*\{([\s\S]*?)\}/.exec(LINUX_ENGINE);
const linuxEvdev = {};
if (!engineMatch) fail('tap_hold_engine.lua has no KEY_CODES table');
else
	for (const [, id, n] of engineMatch[1].matchAll(/([a-z_]+)\s*=\s*(\d+)/g))
		linuxEvdev[id] = Number(n);

const catalog = DEFAULTS.tap_hold.catalog.keys;
const ahkIds = catalog.filter((e) => e.ahk).map((e) => e.ahk);
if (ahkIds.length < MIN_TAP_HOLD_KEYS)
	fail(`only ${ahkIds.length} Windows tap-hold keys in the catalogue`);
if (JSON.stringify(Object.keys(windowsCodes).sort()) !== JSON.stringify([...ahkIds].sort()))
	fail(
		`the Windows table maps the tap-hold keys ${JSON.stringify(Object.keys(windowsCodes).sort())}, the catalogue lists ${JSON.stringify([...ahkIds].sort())}`
	);
for (const entry of catalog) {
	if (!entry.ahk) continue;
	const code = windowsCodes[entry.ahk];
	if (!REGISTRY.keys[code]) {
		fail(`the Windows tap-hold key ${entry.ahk} maps to ${code}, not a registry key`);
		continue;
	}
	if (!entry.linux) {
		fail(`catalogue entry ${entry.id} has no Linux key to check the Windows mapping against`);
		continue;
	}
	if (REGISTRY.keys[code].evdev !== linuxEvdev[entry.linux])
		fail(
			`${entry.id}: the Windows table says ${code} (evdev ${REGISTRY.keys[code].evdev}), the Linux engine remaps evdev ${linuxEvdev[entry.linux]}`
		);
}

const layerId = Object.keys(PRESET.layers)[0];
const holdLayerKeys = (codeOf) =>
	Object.entries(DEFAULTS.tap_hold.keys)
		.filter(([, fields]) => fields.hold_layer === layerId)
		.map(([id]) => codeOf(id))
		.sort();
const byEvdev = (n) => Object.keys(REGISTRY.keys).find((code) => REGISTRY.keys[code].evdev === n);
const macosForm = /^local KEYBOARD_FORM = "([a-z]+)"$/m.exec(MACOS_NAV_LAYER);
const karabinerOf = (entry) => {
	const override = macosForm && entry['macos_' + macosForm[1]];
	return ((override && override.karabiner) || entry.karabiner || {}).key_code;
};
const macosHold = /^M\.HOLD_ACTION_ID = "([a-z_]+)"$/m.exec(MACOS_NAV_LAYER);
const derived = {
	windows: holdLayerKeys((id) => windowsCodes[id]),
	linux: holdLayerKeys((id) => byEvdev(linuxEvdev[id])),
	macos: Object.entries(DEFAULTS.hs_tap_hold)
		.filter(([, slot]) => macosHold && slot.hold === macosHold[1])
		.map(([id]) =>
			Object.keys(REGISTRY.keys).find((code) => karabinerOf(REGISTRY.keys[code]) === id)
		)
		.filter(Boolean)
		.sort()
};
for (const os of ['windows', 'macos', 'linux']) {
	if (derived[os].length === 0) fail(`no shipped ${os} tap-hold key holds the "${layerId}" layer`);
	if (JSON.stringify(derived[os]) !== JSON.stringify(CORPUS.recommended_layer_keys[os]))
		fail(
			`legends.json says the ${os} layer key is ${JSON.stringify(CORPUS.recommended_layer_keys[os])}, the shipped tap-holds say ${JSON.stringify(derived[os])}`
		);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the navigation layer keys disagree with their sources:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] navigation layer keys: ${Object.keys(windowsCodes).length} Windows tap-hold keys ` +
		`and the three drivers' layer keys agree.\x1b[0m`
);
