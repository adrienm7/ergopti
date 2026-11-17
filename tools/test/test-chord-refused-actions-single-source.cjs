// tools/test/test-chord-refused-actions-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Chord Refused Actions Single Source
 * DESCRIPTION:
 * No key-combination chord runs the one-shot Shift, on any OS (maintainer
 * decision of 2026-11-06). The shared policy's CHORD_REFUSED_EVERYWHERE
 * (_shared/tap_hold/engine/key_combinations.lua) names it under both its ids;
 * macOS and Linux read that table. This test pins the Windows copy
 * (KEY_COMBINATION_CHORD_REFUSED_ACTIONS) to it, and pins the actions Windows and
 * Linux refuse beyond it (their chords have no native receiving for them) to
 * one list, so the read, the menu and the bulk copy refuse the same actions.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = path.join(ROOT, 'static', 'ergopti_plus');

// The Karabiner spelling of the one-shot Shift; Windows and Linux name it one_shot_shift.
const MACOS_ONLY_IDS = new Set(['sticky_shift']);

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
function sharedActions() {
	const source = read('_shared/tap_hold/engine/key_combinations.lua');
	const match = source.match(/M\.CHORD_REFUSED_EVERYWHERE = \{([^}]*)\}/);
	if (!match) throw new Error('CHORD_REFUSED_EVERYWHERE is missing from the shared pair policy');
	return [...match[1].matchAll(/([a-z0-9_]+) = true/g)].map((m) => m[1]);
}

/**
 * The Windows refusal map's keys.
 * @returns {string[]}
 */
function windowsActions() {
	const source = read('windows/infra/key_combinations.ahk');
	const match = source.match(/KEY_COMBINATION_CHORD_REFUSED_ACTIONS := Map\(([^)]*)\)/);
	if (!match)
		throw new Error('KEY_COMBINATION_CHORD_REFUSED_ACTIONS is missing from the Windows driver');
	return [...match[1].matchAll(/"([a-z0-9_]+)", true/g)].map((m) => m[1]);
}

/**
 * The Linux refusals: the shared table plus the actions it adds.
 * @returns {{readsShared: boolean, extra: string[]}}
 */
function linuxActions() {
	const source = read('linux/modules/shortcuts/key_combinations.lua');
	const readsShared =
		/CHORD_REFUSED_ACTIONS = TableUtil\.shallow_copy\(Shared\.CHORD_REFUSED_EVERYWHERE\)/.test(
			source
		);
	const extra = [...source.matchAll(/CHORD_REFUSED_ACTIONS\.([a-z0-9_]+)/g)].map((m) => m[1]);
	return { readsShared, extra };
}

const failures = [];
const shared = sharedActions();
if (!shared.includes('one_shot_shift') || !shared.includes('sticky_shift')) {
	failures.push('the shared list must name the one-shot Shift under both its ids');
}
const sharedGeneric = shared.filter((id) => !MACOS_ONLY_IDS.has(id));
const windows = windowsActions();
const windowsExtra = windows.filter((id) => !sharedGeneric.includes(id));
for (const id of sharedGeneric) {
	if (!windows.includes(id))
		failures.push(`Windows KEY_COMBINATION_CHORD_REFUSED_ACTIONS lacks '${id}'`);
}
const linux = linuxActions();
if (!linux.readsShared)
	failures.push('the Linux chord refusals no longer start from the shared table');
if (JSON.stringify(sorted(linux.extra)) !== JSON.stringify(sorted(windowsExtra))) {
	failures.push(
		`Linux refuses ${JSON.stringify(sorted(linux.extra))} beyond the shared list, ` +
			`Windows ${JSON.stringify(sorted(windowsExtra))}`
	);
}
const macosSources = [
	'macos/ui/menu/menu_tap_holds.lua',
	'macos/platform/remap/init.lua',
	'macos/platform/remap/generator.lua',
	'macos/platform/remap/config.lua'
];
for (const rel of macosSources) {
	if (!read(rel).includes('CHORD_REFUSED_EVERYWHERE')) {
		failures.push(`${rel} no longer refuses the shared chord actions`);
	}
}

if (failures.length > 0) {
	for (const failure of failures) console.error(`[FAIL] ${failure}`);
	process.exit(1);
}
console.log(
	`[OK] Chord refused actions: ${shared.join(', ')} everywhere, ${windowsExtra.join(', ')} on Windows and Linux.`
);
