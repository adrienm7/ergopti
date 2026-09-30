// tools/test/test-layer-editor-legends.cjs

/**
 * ==============================================================================
 * MODULE: Layer Editor Legends Gate
 * DESCRIPTION:
 * The navigation layer editor labels each key with what the user's layout
 * types on it and marks the key whose hold enters the layer. Three hosts
 * compute both (windows/ui/layer_editor/init.ahk, and
 * _shared/lua/keymap/layer_editor.lua for macOS and Linux) and the page reads
 * them; their shared corpus is _shared/tests/corpus/layer_editor/legends.json.
 * This gate holds the corpus and the hosts' copies to their sources.
 *
 * WHAT IS CHECKED:
 * 1. Corpus: every key the registry sends by scan code (`ahk_send: null`, the
 *    generated data's `character`) is either expected with the layout's text
 *    or listed unresolved, never both; a named key never has a legend; the
 *    expected text is the layout's, kept only when printable.
 * 2. Sources: the legend source names are one set in the Lua hosts, the
 *    Windows host and the page model.
 * 3. Layer keys: the Windows host's tap-hold id -> registry code table covers
 *    exactly the Windows column of [tap_hold.catalog], and each key is the one
 *    the Linux engine remaps (its evdev code) under the same catalogue entry;
 *    the corpus's recommended layer keys are what each driver's shipped
 *    tap-hold keys hold the layer with.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const DRIVERS = path.dirname(shared());
const read = (p) => fs.readFileSync(p, 'utf8').replace(/^﻿/, '');
const REGISTRY = JSON.parse(read(shared('data', 'keycodes', 'physical_keys.json')));
const CORPUS = JSON.parse(read(shared('tests', 'corpus', 'layer_editor', 'legends.json')));
const DEFAULTS = TOML.parse(read(shared('tap_hold', 'defaults.toml')));
const PRESET = TOML.parse(read(shared('keymap', 'layers.recommended.toml')));
const LUA_HOST = read(shared('lua', 'keymap', 'layer_editor.lua'));
const MODEL = read(shared('ui', 'layer_editor', 'layer_model.js'));
const WINDOWS_HOST = read(path.join(DRIVERS, 'windows', 'ui', 'layer_editor', 'init.ahk'));
const LINUX_ENGINE = read(path.join(DRIVERS, 'linux', 'platform', 'remap', 'tap_hold_engine.lua'));
const MACOS_NAV_LAYER = read(path.join(DRIVERS, 'macos', 'platform', 'remap', 'nav_layer.lua'));

// Floors: a corpus or a table that stopped being read must not pass empty.
const MIN_CHARACTER_KEYS = 45;
const MIN_TAP_HOLD_KEYS = 10;

const errors = [];
const fail = (msg) => errors.push(msg);

// ==========================
// ==========================
// ======= 1/ Corpus ========
// ==========================
// ==========================

const characterCodes = Object.entries(REGISTRY.keys)
	.filter(([, e]) => e.kind === 'key' && e.ahk_send === null)
	.map(([code]) => code)
	.sort();
if (characterCodes.length < MIN_CHARACTER_KEYS)
	fail(`only ${characterCodes.length} character keys in the registry`);

/** The contract's filter: printable, not blank, no C0/DEL/C1 control. */
function printable(text) {
	if (typeof text !== 'string' || text === '') return false;
	if (/[\u0000-\u001F\u007F-\u009F]/.test(text)) return false;
	return text.replace(/[\s  ]/g, '') !== '';
}

for (const vector of CORPUS.cases) {
	const where = `legends.json ${vector.name}`;
	if (!['emulation', 'os'].includes(vector.source))
		fail(`${where}: unknown source ${vector.source}`);
	const want = {};
	for (const code of characterCodes)
		if (printable(vector.layout[code])) want[code] = vector.layout[code];
	if (JSON.stringify(want) !== JSON.stringify(sortedCopy(vector.expected)))
		fail(`${where}: expected is not the layout's printable text on every character key`);
	const unresolved = characterCodes.filter((code) => !(code in want));
	if (JSON.stringify(unresolved) !== JSON.stringify(vector.unresolved))
		fail(
			`${where}: unresolved is ${JSON.stringify(vector.unresolved)}, not ${JSON.stringify(unresolved)}`
		);
	const named = Object.keys(vector.layout).filter((code) => !characterCodes.includes(code));
	if (named.length === 0)
		fail(`${where}: the layout types on no named key, so their exclusion is not tried`);
	if (vector.unresolved.length === 0)
		fail(`${where}: no unresolved key, so the fallback is not tried`);
}

/** An object with its keys sorted, for a key-order-free comparison. */
function sortedCopy(object) {
	return Object.fromEntries(
		Object.keys(object)
			.sort()
			.map((k) => [k, object[k]])
	);
}

// ============================
// ============================
// ======= 2/ Sources =========
// ============================
// ============================

const luaSources = [...LUA_HOST.matchAll(/^M\.LEGEND_SOURCE_[A-Z]+ = "([a-z]+)"$/gm)].map(
	(m) => m[1]
);
const ahkSources = [
	...WINDOWS_HOST.matchAll(/^global LAYER_EDITOR_LEGEND_SOURCE_[A-Z]+ := "([a-z]+)"$/gm)
].map((m) => m[1]);
const modelSources = /const LEGEND_SOURCES = \[([^\]]*)\]/.exec(MODEL);
const pageSources = modelSources
	? [...modelSources[1].matchAll(/'([a-z]+)'/g)].map((m) => m[1])
	: [];
for (const [name, list] of [
	['the Lua hosts', luaSources],
	['the Windows host', ahkSources],
	['the page model', pageSources]
])
	if (JSON.stringify([...list].sort()) !== JSON.stringify(['emulation', 'os']))
		fail(`${name} name the legend sources ${JSON.stringify(list)}`);

// ===============================
// ===============================
// ======= 3/ Layer keys =========
// ===============================
// ===============================

const tableMatch = /global LAYER_EDITOR_TAP_HOLD_KEY_CODES := Map\(([\s\S]*?)\n\)/.exec(
	WINDOWS_HOST
);
const windowsCodes = {};
if (!tableMatch) fail('init.ahk has no LAYER_EDITOR_TAP_HOLD_KEY_CODES table');
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
		`the Windows host maps the tap-hold keys ${JSON.stringify(Object.keys(windowsCodes).sort())}, the catalogue lists ${JSON.stringify([...ahkIds].sort())}`
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
			`${entry.id}: the Windows host says ${code} (evdev ${REGISTRY.keys[code].evdev}), the Linux engine remaps evdev ${linuxEvdev[entry.linux]}`
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
	console.error('\x1b[31m[FAIL] the layer editor legends disagree with their sources:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] layer editor legends: ${characterCodes.length} character keys, ${CORPUS.cases.length} corpus case(s), ` +
		`${Object.keys(windowsCodes).length} Windows tap-hold keys, one legend source set and the three layer keys agree.\x1b[0m`
);
