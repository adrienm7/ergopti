// tools/test/test-hotstring-category-submenu-order.cjs

/**
 * ==============================================================================
 * MODULE: One Hotstring Category Submenu, One Order
 * DESCRIPTION:
 * Every hotstring category (Autocorrection, Rolls, SFB, distances, magic key)
 * opens a submenu with the same controls on all three drivers. Until 2026-08-07
 * they came in three different orders, and macOS was missing one of them:
 *
 *   Windows   gate, tout activer, tout désactiver, ouvrir le fichier, ─, sections
 *   Linux     gate, ouvrir le fichier, ─, tout activer, tout désactiver, ─, sections
 *   macOS     ouvrir le fichier, ─, tout activer, tout désactiver, ─, sections
 *
 * macOS relied on the PARENT row toggling the group when clicked. It works, and
 * nobody discovers it: the parent of a submenu reads as something you open, not
 * something you switch off.
 *
 * THE ORDER BELOW IS THE SHARED ONE — Linux's, because it reads best: the gate
 * first, since everything under it is inert while it is off.
 *
 * WHY A SOURCE SCAN: the three builders are written in three languages and none
 * of them can be executed by the other two's test runner. What CAN be compared
 * is the order in which each names the four shared label keys, which is exactly
 * the thing that differed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

// The canonical sequence. `open_file` is optional per category (a category with
// no TOML on disk has nothing to open), so it is checked only where it appears.
const ORDER = [
	'menu.hotstrings.category_o', // category_on / category_off — the gate
	'menu.hotstrings.open_file',
	'menu.hotstrings.enable_all',
	'menu.hotstrings.disable_all',
];

// Each driver's category-submenu builder, delimited by two literals unique to it.
const REGIONS = [
	{
		driver: 'windows',
		file: 'windows/ui/menu/menu_submenus.ahk',
		from: 'for _, V1Cat in _FLAT_HOTSTRING_V1_CATS',
		to: 'SubMenus[V1Cat] := SubMenu',
	},
	{
		driver: 'macos',
		file: 'macos/ui/menu/menu_hotstrings.lua',
		from: 'local sec_menu = {}',
		to: 'item.items = sec_menu',
	},
	{
		driver: 'linux',
		file: 'linux/ui/menu/menu_builder.lua',
		from: 'local function category_submenu(id)',
		to: 'items    = sub,',
	},
];

const errors = [];

for (const { driver, file, from, to } of REGIONS) {
	const full = path.join(SP, file);
	if (!fs.existsSync(full)) {
		errors.push(`${driver}: ${file} is gone — this gate compares nothing until the anchor is updated`);
		continue;
	}
	const src = fs.readFileSync(full, 'utf8');
	const start = src.indexOf(from);
	const end = src.indexOf(to, start + 1);
	if (start < 0 || end < 0) {
		errors.push(
			`${driver}: could not delimit the category-submenu builder (looked for ${JSON.stringify(from)} then ` +
				`${JSON.stringify(to)}). Re-anchor it rather than deleting the check.`
		);
		continue;
	}
	const region = src.slice(start, end);

	const seen = [];
	for (const key of ORDER) {
		const at = region.indexOf(key);
		if (at >= 0) seen.push({ key, at });
	}

	// The gate row and the two bulk actions are not optional anywhere.
	for (const required of ['menu.hotstrings.category_o', 'menu.hotstrings.enable_all', 'menu.hotstrings.disable_all']) {
		if (!seen.some((s) => s.key === required)) {
			errors.push(
				`${driver}: the category submenu never names ${required}. Every driver shows this control; ` +
					'one that does not is a capability the user of that OS has to discover elsewhere, or does ' +
					'not have.'
			);
		}
	}

	const sorted = [...seen].sort((a, b) => a.at - b.at);
	const actual = sorted.map((s) => s.key).join(' → ');
	const wanted = seen.map((s) => s.key).join(' → ');
	if (actual !== wanted) {
		errors.push(
			`${driver}: the category submenu is built in the order\n        ${actual}\n      and the shared ` +
				`order is\n        ${wanted}\n      Three drivers with three orders for one submenu is what this ` +
				'gate exists to end.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the hotstring category submenus do not agree:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] all three drivers build the hotstring category submenu in the same order ' +
		'(gate → open file → bulk actions → sections).\x1b[0m'
);
