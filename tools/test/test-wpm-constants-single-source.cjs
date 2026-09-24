// tools/test/test-wpm-constants-single-source.cjs

/**
 * ==============================================================================
 * MODULE: WPM Readout Constants Single-Source Guard
 * DESCRIPTION:
 * _shared/modules/wpm_widget/constants.toml is the one description of how the
 * typing-speed readouts look on every driver. This gate keeps it that way:
 *   1. every key a driver reads exists in the canon — the shared Lua model's
 *      REQUIRED table (macOS and Linux) and the AHK loader's _WPMWidget_Need
 *      calls (Windows);
 *   2. every key in the canon is read by some driver, so a value cannot sit
 *      in the file changing nothing;
 *   3. no driver restates a canon value: the AHK loader passes no default to
 *      any read, and the Lua readouts hold no colour literal of their own;
 *   4. the refresh timers read the shared timings registry, not a literal.
 * It replaces a gate that pinned each driver's COPIES of the values to the
 * canon — the copies are gone.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static/ergopti_plus');

function read(rel) { return fs.readFileSync(path.join(SP, rel), 'utf8'); }

/**
 * The canon's keys as "section.key", from a flat TOML file of [section] tables.
 * @param {string} text
 * @returns {Set<string>}
 */
function tomlKeys(text) {
	const keys = new Set();
	let section = null;
	for (const raw of text.split(/\r?\n/)) {
		const line = raw.trim();
		if (!line || line.startsWith('#')) continue;
		const header = line.match(/^\[([a-z_]+)\]$/);
		if (header) { section = header[1]; continue; }
		const kv = line.match(/^([a-z_]+)\s*=/);
		if (kv && section) keys.add(`${section}.${kv[1]}`);
	}
	return keys;
}

/**
 * The keys the shared Lua model requires, from its REQUIRED table.
 * @param {string} src
 * @returns {Set<string>}
 */
function modelKeys(src) {
	const start = src.indexOf('local REQUIRED = {');
	if (start === -1) throw new Error('model.lua has no REQUIRED table');
	const body = src.slice(start, src.indexOf('\n}\n', start));
	const keys = new Set();
	for (const block of body.matchAll(/([a-z_]+) = \{([^}]*)\}/g)) {
		for (const key of block[2].matchAll(/([a-z_]+) = "/g)) keys.add(`${block[1]}.${key[1]}`);
	}
	return keys;
}

const errors = [];
const canon = tomlKeys(read('_shared/modules/wpm_widget/constants.toml'));
const model = modelKeys(read('_shared/lua/wpm_widget/model.lua'));
const ahkConfig = read('windows/ui/wpm/wpm_config.ahk');
const ahk = new Set([...ahkConfig.matchAll(/_WPMWidget_Need\(wpm_c, "([a-z_]+)", "([a-z_]+)"/g)]
	.map((m) => `${m[1]}.${m[2]}`));

if (model.size < 20) errors.push(`the model's REQUIRED table parsed to only ${model.size} key(s)`);
if (ahk.size < 20) errors.push(`the AHK loader's reads parsed to only ${ahk.size} key(s)`);

// 1. Every key read exists.
for (const key of model) if (!canon.has(key)) errors.push(`the shared model requires ${key}, absent from the canon`);
for (const key of ahk) if (!canon.has(key)) errors.push(`the AHK loader reads ${key}, absent from the canon`);

// 2. Every canon key is read. The neutral sources are read as a table.
for (const key of canon) {
	if (key.startsWith('neutral_sources.')) continue;
	if (!model.has(key) && !ahk.has(key)) errors.push(`${key} is in the canon and read by no driver`);
}

// 3. No restated values.
if (/IniCacheGet\((wpm_c|tim_c),[^)]*,[^)]*,[^)]*\)/.test(ahkConfig)) {
	errors.push('the AHK loader passes a default to a canon or timings read — a copy of the value');
}
for (const rel of ['macos/ui/wpm/shared.lua', 'macos/ui/wpm/wpm_widget.lua', 'macos/ui/wpm/wpm_menubar.lua',
	'linux/ui/wpm/widget.lua', 'linux/ui/wpm/tray_readout.lua']) {
	const src = read(rel).split('\n').filter((line) => !line.trim().startsWith('--')).join('\n');
	const literal = src.match(/["']#?[0-9a-fA-F]{6}["']/);
	if (literal) errors.push(`${rel} holds the colour literal ${literal[0]} — the canon owns colours`);
	// Directly, or through ui/wpm/shared.lua, which is itself checked here.
	if (!src.includes('require("wpm_widget.model")') && !src.includes('require("ui.wpm.shared")')) {
		errors.push(`${rel} does not draw through the shared model`);
	}
}

// 4. Refresh rates from the timings registry.
const pins = [
	['macos/ui/wpm/wpm_widget.lua', 'TimerScheduler.every(CONFIG.update_s'],
	['macos/ui/wpm/wpm_menubar.lua', 'Timings.sec("ui", "wpm_menubar_update_ms")'],
	['linux/ui/wpm/widget.lua', 'Timings.sec("ui", "wpm_widget_update_ms")'],
	['linux/ui/wpm/tray_readout.lua', 'Timings.sec("ui", "wpm_menubar_update_ms")'],
	['windows/ui/wpm/wpm_config.ahk', '_WPMWidget_NeedTiming("ui", "wpm_widget_update_ms"'],
];
for (const [rel, needle] of pins) {
	if (!read(rel).includes(needle)) errors.push(`${rel} must take its refresh from the timings registry (${needle})`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] WPM readout constants are not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] WPM readouts: ${canon.size} canon key(s), each read by a driver, none restated.\x1b[0m`);
