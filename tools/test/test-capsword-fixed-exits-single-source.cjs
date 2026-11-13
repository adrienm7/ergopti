// tools/test/test-capsword-fixed-exits-single-source.cjs

/**
 * ==============================================================================
 * MODULE: CapsWord Fixed Exits Single Source
 * DESCRIPTION:
 * Escape, Delete, the arrows, Home/End, Page Up/Down and F1-F12 always end
 * CapsWord (maintainer decision of 2026-11-06, aligned on macOS). The shared
 * policy's FIXED_EXIT_KEYS (_shared/keyboard/engine/caps_word_auto_off.lua) is the list;
 * this test pins the three driver copies to it: the macOS Karabiner anchor's
 * kept exits (capsword.json), the Windows virtual-key map
 * (CAPSWORD_FIXED_EXIT_VKS) and the Linux hook's control-key names.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = path.join(ROOT, 'static', 'ergopti_plus');

/**
 * Reads one tracked source file as text.
 * @param {string} rel Path under static/ergopti_plus.
 * @returns {string}
 */
function read(rel) {
	return fs.readFileSync(path.join(PLUS, rel), 'utf8').replace(/^﻿/, '');
}

/**
 * Sorted copy of a list, for order-free comparison.
 * @param {string[]} list
 * @returns {string[]}
 */
function sorted(list) {
	return [...list].sort();
}

/**
 * The shared list, read from the Lua source.
 * @returns {string[]}
 */
function sharedKeys() {
	const source = read('_shared/keyboard/engine/caps_word_auto_off.lua');
	const match = source.match(/M\.FIXED_EXIT_KEYS = \{([^}]*)\}/);
	if (!match) throw new Error('FIXED_EXIT_KEYS is missing from the shared CapsWord policy');
	return [...match[1].matchAll(/"([a-z0-9_]+)"/g)].map((m) => m[1]);
}

// Karabiner key_code -> shared name; settings-owned exits are excluded.
const KARABINER_NAMES = {
	escape: 'escape',
	delete_forward: 'delete',
	up_arrow: 'up',
	down_arrow: 'down',
	left_arrow: 'left',
	right_arrow: 'right',
	home: 'home',
	end: 'end',
	page_up: 'page_up',
	page_down: 'page_down'
};
const SETTING_EXITS = new Set(['spacebar', 'return_or_enter', 'tab', 'g', 'v', 'caps_lock']);

/**
 * The fixed exits macOS keeps in its Karabiner rule.
 * @returns {string[]}
 */
function macosKeys() {
	const rule = JSON.parse(read('macos/keyboard/data/capsword.json'));
	const keys = [];
	for (const manipulator of rule.manipulators) {
		const active = (manipulator.conditions || []).some(
			(c) => c.name === 'capsword' && c.type === 'variable_if' && c.value === 1
		);
		const code = manipulator.from && manipulator.from.key_code;
		if (!active || !code || SETTING_EXITS.has(code)) continue;
		keys.push(/^f\d+$/.test(code) ? code : KARABINER_NAMES[code] || `unmapped:${code}`);
	}
	return keys;
}

/**
 * The names of the Windows virtual-key map.
 * @returns {string[]}
 */
function windowsKeys() {
	const source = read('windows/modules/shortcuts/capsword_auto_off.ahk');
	const match = source.match(/CAPSWORD_FIXED_EXIT_VKS := Map\(([^)]*)\)/);
	if (!match)
		throw new Error('CAPSWORD_FIXED_EXIT_VKS is missing from the Windows CapsWord auto-off');
	return [...match[1].matchAll(/0x[0-9A-Fa-f]+, "([a-z0-9_]+)"/g)].map((m) => m[1]);
}

/**
 * The shared names the Linux hook can produce, through the manager's spelling map.
 * @returns {string[]}
 */
function linuxKeys() {
	const codes = read('linux/platform/input/evdev_codes.lua');
	const table = codes.match(/M\.CONTROL_NAME_OF = \{([\s\S]*?)\n\}/);
	if (!table) throw new Error('CONTROL_NAME_OF is missing from the Linux evdev codes');
	const names = [...table[1].matchAll(/= "([a-z0-9_]+)"/g)].map((m) => m[1]);
	const manager = read('linux/modules/shortcuts/manager.lua');
	const spelling = manager.match(/CAPS_WORD_HOOK_KEY_NAMES = \{([^}]*)\}/);
	if (!spelling)
		throw new Error('CAPS_WORD_HOOK_KEY_NAMES is missing from the Linux shortcuts manager');
	const rename = Object.fromEntries(
		[...spelling[1].matchAll(/(\w+) = "(\w+)"/g)].map((m) => [m[1], m[2]])
	);
	return [...new Set(names.map((name) => rename[name] || name))];
}

const shared = sharedKeys();
const failures = [];
if (shared.length !== new Set(shared).size) failures.push('FIXED_EXIT_KEYS repeats a key');
const expected = JSON.stringify(sorted(shared));
for (const [driver, keys] of [
	['macOS capsword.json', macosKeys()],
	['Windows CAPSWORD_FIXED_EXIT_VKS', windowsKeys()]
]) {
	if (JSON.stringify(sorted(keys)) !== expected) {
		failures.push(`${driver} names ${JSON.stringify(sorted(keys))}, the shared list ${expected}`);
	}
}
const linux = new Set(linuxKeys());
for (const key of shared) {
	if (!linux.has(key)) failures.push(`the Linux hook never reports the fixed exit '${key}'`);
}

if (failures.length > 0) {
	for (const failure of failures) console.error(`[FAIL] ${failure}`);
	process.exit(1);
}
console.log(
	`[OK] CapsWord fixed exits: ${shared.length} keys, one list on macOS, Windows and Linux.`
);
