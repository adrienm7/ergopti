// tools/test/test-menu-toggle-registered.cjs

/**
 * ==============================================================================
 * MODULE: Every Category Switch Is Registered By Every Driver That Shows It
 * DESCRIPTION:
 * Each feature submenu opens with its category switch, the manifest's `toggle`
 * row. The row is drawn only when the driver registers a command under its id,
 * so a driver that shows the row and registers nothing leaves the category with
 * no way to be switched on from its submenu.
 *
 * WHY IT EXISTS: macOS registered no command for the Gestures, Shortcuts,
 * Metrics and Hotstrings switches, on the premise that "an hs.menubar parent can
 * be clicked". It cannot — AppKit never sends the action of an item that opens
 * a submenu — so those four features could not be turned on from the menu bar.
 * The coverage gate exempted `toggle` rows on that same premise, and the shared
 * renderer skipped the row with a DEBUG line. This asserts the registration in
 * each driver's source, and that every feature menu declares its switch first.
 *
 * A source scan is the right tool at this boundary: whether the command reaches
 * the rendered row is tested behaviourally in each driver's suite (macOS
 * test_every_category_toggle_reachable, Linux test_menu_toggle_row_is_check,
 * Windows test_category_toggle_checkbox). This gate is the one place that sees
 * all three drivers against the one declaration, so a new toggle row cannot be
 * shown on a driver that forgot it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const manifest = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json'), 'utf8')
);

// The feature submenus whose first row must be the category switch.
const FEATURE_MENUS = [
	'layout_menu',
	'hotstrings_menu',
	'llm_menu',
	'metrics_menu',
	'shortcuts_menu',
	'tap_holds_menu',
	'gestures_menu',
];

const DRIVERS = [
	{ platform: 'ahk', dir: 'windows', ext: '.ahk' },
	{ platform: 'hs', dir: 'macos', ext: '.lua' },
	{ platform: 'linux', dir: 'linux', ext: '.lua' },
];

/**
 * Removes comments so prose that names an id cannot count as its registration.
 * @param {string} source
 * @param {string} ext
 * @returns {string}
 */
function stripComments(source, ext) {
	if (ext === '.ahk') {
		return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s);.*$/gm, '$1');
	}
	return source.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, '').replace(/--.*$/gm, '');
}

/**
 * The production source of one driver, comments removed.
 * @param {{dir: string, ext: string}} driver
 * @returns {string}
 */
function driverSource(driver) {
	const parts = [];
	(function walk(dir) {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (!['tests', 'vendor', 'node_modules', '_generated'].includes(entry.name)) walk(full);
			} else if (full.endsWith(driver.ext)) {
				parts.push(stripComments(fs.readFileSync(full, 'utf8'), driver.ext));
			}
		}
	})(path.join(SP, driver.dir));
	return parts.join('\n');
}

/**
 * True when the driver source registers `id` as a command key: a bracketed Lua
 * table key (`["id"] =`) or an AutoHotkey Map entry (`"id",`).
 * @param {string} source
 * @param {string} ext
 * @param {string} id
 * @returns {boolean}
 */
function registers(source, ext, id) {
	const quoted = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const pattern = ext === '.ahk'
		? new RegExp(`"${quoted}"\\s*,`)
		: new RegExp(`\\[\\s*["']${quoted}["']\\s*\\]\\s*=`);
	return pattern.test(source);
}

const visible = (row, platform) => !Array.isArray(row.platforms) || row.platforms.includes(platform);
const errors = [];

for (const key of FEATURE_MENUS) {
	const rows = manifest[key];
	if (!Array.isArray(rows) || rows.length === 0) {
		errors.push(`${key}: the feature menu is not declared`);
		continue;
	}
	if (rows[0].type !== 'toggle') {
		errors.push(`${key}: its first row is a "${rows[0].type}", not the category switch`);
	}
}

let registrations = 0;
for (const driver of DRIVERS) {
	const source = driverSource(driver);
	if (source.length < 100000) {
		errors.push(`${driver.dir}: production source unreadable (${source.length} bytes)`);
		continue;
	}
	for (const [key, rows] of Object.entries(manifest)) {
		if (!Array.isArray(rows)) continue;
		for (const row of rows) {
			if (!row || row.type !== 'toggle' || !visible(row, driver.platform)) continue;
			const command = row.command || row.id;
			if (registers(source, driver.ext, command)) {
				registrations += 1;
			} else {
				errors.push(
					`${driver.dir} shows ${key}.${row.id} and registers no "${command}" command — the ` +
						'category has no switch in its submenu, and no tray can switch it from the parent row'
				);
			}
		}
	}
}

// Seven switches on Windows, six on macOS (no layout emulation), five on Linux
// (no layout emulation, tap-holds under kanata). A scan that matched nothing
// would pass by finding nothing to check.
const FLOOR = 18;
if (registrations < FLOOR && errors.length === 0) {
	errors.push(`only ${registrations} switch registration(s) found, expected at least ${FLOOR}`);
}

if (errors.length > 0) {
	console.error('[31m[FAIL] a category switch is unreachable:[0m');
	for (const e of errors) console.error(`    - ${e}`);
	process.exit(1);
}
console.log(
	`[32m[OK] ${FEATURE_MENUS.length} feature menus open with their switch; ${registrations} ` +
		'switch registration(s) found across the three drivers.[0m'
);
