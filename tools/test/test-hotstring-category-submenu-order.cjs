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
 * THE ORDER BELOW IS THE SHARED ONE — the gate first, since everything under it
 * is inert while it is off:
 *
 *   gate checkbox, ouvrir le fichier, ─, « toutes les sections » checkbox, ─, sections
 *
 * Both controls are checkboxes with one label each. The gate read « ✅ Activée
 * (cliquer pour désactiver) » / « ❌ Désactivée (cliquer pour activer) », and the
 * sections came with a « Tout activer » / « Tout désactiver » pair: two keys per
 * control, and a state readable only from the words. The same single checkbox
 * replaces the pair at the top of each language submenu, the personal and
 * dynamic submenus and the Hotstrings menu itself.
 *
 * WHY A SOURCE SCAN: the three builders are written in three languages and none
 * of them can be executed by the other two's test runner. What CAN be compared
 * is the order in which each builds the shared controls, and that no driver
 * source still names a retired key. Each driver's own suite tests the rows
 * behaviourally (test_hotstring_bulk_checkboxes on all three).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const GATE_KEY = 'menu.hotstrings.category_enable';
const OPEN_FILE_KEY = 'menu.hotstrings.open_file';
const ALL_SECTIONS_KEY = 'menu.hotstrings.enable_all_sections';

// Label keys retired with the pairs and the alternating gate labels. A driver
// source still naming one draws the old controls. The quote closes each key so
// `enable_all` does not match `enable_all_sections`.
const RETIRED = [
	'menu.hotstrings.category_on',
	'menu.hotstrings.category_off',
	'menu.hotstrings.enable_all"',
	"menu.hotstrings.enable_all'",
	'menu.hotstrings.disable_all'
];

// The key fragments a driver could build a retired key from at run time, the
// way the Linux language rows once did with "menu.hotstrings." .. bulk.key, and
// the two command ids the manifest no longer declares.
const RETIRED_FRAGMENTS = [
	'key = "enable_all"',
	'key = "disable_all"',
	'"hotstrings_enable_all"',
	'"hotstrings_disable_all"'
];

// Each driver: the one helper that draws the « all sections » checkbox (it must
// name the shared key), and the files that build hotstring submenus.
const DRIVERS = [
	{
		driver: 'windows',
		helper: {
			file: 'windows/ui/menu/menu_hotstring_switches.ahk',
			from: '_HS_AllSectionsRow(AllOn, Apply) {',
			to: '\n}'
		},
		call: '_HS_AllSectionsRow(',
		files: [
			'windows/ui/menu/menu_hotstring_switches.ahk',
			'windows/ui/menu/menu_submenus.ahk',
			'windows/ui/menu/menu_hotstrings.ahk',
			'windows/ui/menu/menu_init.ahk'
		]
	},
	{
		driver: 'macos',
		helper: {
			file: 'macos/ui/menu/menu_hotstrings_custom.lua',
			from: 'function M.all_sections_row(',
			to: '\nend'
		},
		call: 'all_sections_row(',
		files: [
			'macos/ui/menu/menu_hotstrings.lua',
			'macos/ui/menu/menu_hotstrings_custom.lua',
			'macos/ui/menu/builder.lua'
		]
	},
	{
		driver: 'linux',
		helper: {
			file: 'linux/ui/menu/menu_builder.lua',
			from: 'local function all_sections_row(ids)',
			to: '\n\tend'
		},
		call: 'all_sections_row(',
		files: ['linux/ui/menu/menu_builder.lua']
	}
];

// Each driver's category-submenu builder, delimited by two literals unique to it.
const CATEGORY_REGIONS = [
	{
		driver: 'windows',
		file: 'windows/ui/menu/menu_hotstring_switches.ahk',
		from: '_HS_CategoryHeadRows(V1Cat, V2Section, TomlPath) {',
		to: '\treturn Rows\n}'
	},
	{
		driver: 'macos',
		file: 'macos/ui/menu/menu_hotstrings.lua',
		from: 'local sec_menu = {}',
		to: 'item.items = sec_menu'
	},
	{
		driver: 'linux',
		file: 'linux/ui/menu/menu_builder.lua',
		from: 'local function category_submenu(id)',
		to: 'items    = sub,'
	}
];

// Each driver's language-submenu builder: one « toutes les sections » checkbox
// opens it, never the retired pair.
const LANGUAGE_REGIONS = [
	{
		driver: 'windows',
		file: 'windows/ui/menu/menu_submenus.ahk',
		from: '_HS_LanguageRows() {',
		to: 'Rows.Push(Map(\n\t\t\t"label", HotstringsLanguageName',
		// The language checkbox has a builder of its own here, which the unit
		// harness can reach; it draws the row through _HS_AllSectionsRow.
		call: '_HS_LanguageSwitchRow('
	},
	{
		driver: 'macos',
		file: 'macos/ui/menu/menu_hotstrings.lua',
		from: 'function M.build_language_bulk_actions(',
		to: 'local _mgmt = require'
	},
	{
		driver: 'linux',
		file: 'linux/ui/menu/menu_builder.lua',
		from: 'local function language_rows()',
		to: 'label = string.format("%s (%d)", language_label(pack.locale), total)'
	}
];

const errors = [];

/**
 * The text of a driver file, or null with an error recorded.
 * @param {string} driver
 * @param {string} file
 * @returns {string|null}
 */
function read(driver, file) {
	const full = path.join(SP, file);
	if (!fs.existsSync(full)) {
		errors.push(
			`${driver}: ${file} is gone — this gate compares nothing until the anchor is updated`
		);
		return null;
	}
	return fs.readFileSync(full, 'utf8');
}

/**
 * The source between two anchors, or null with an error recorded.
 * @param {string} driver
 * @param {{file: string, from: string, to: string}} region
 * @returns {string|null}
 */
function slice(driver, region) {
	const src = read(driver, region.file);
	if (src === null) return null;
	const start = src.indexOf(region.from);
	const end = src.indexOf(region.to, start + 1);
	if (start < 0 || end < 0) {
		errors.push(
			`${driver}: could not delimit ${region.file} (looked for ${JSON.stringify(region.from)} then ` +
				`${JSON.stringify(region.to)}). Re-anchor it rather than deleting the check.`
		);
		return null;
	}
	return src.slice(start, end);
}

let regions = 0;
const byDriver = new Map(DRIVERS.map((d) => [d.driver, d]));

for (const d of DRIVERS) {
	const helper = slice(d.driver, d.helper);
	if (helper !== null) {
		regions += 1;
		if (!helper.includes(ALL_SECTIONS_KEY)) {
			errors.push(`${d.driver}: the « all sections » helper never names ${ALL_SECTIONS_KEY}`);
		}
	}
	for (const file of d.files) {
		const src = read(d.driver, file);
		if (src === null) continue;
		regions += 1;
		for (const key of [...RETIRED, ...RETIRED_FRAGMENTS]) {
			if (src.includes(key)) {
				errors.push(
					`${d.driver}: ${file} still names ${key.replace(/["']$/, '')}. The pair and the alternating ` +
						'gate labels are one checkbox each now, with one key.'
				);
			}
		}
	}
}

for (const region of CATEGORY_REGIONS) {
	const text = slice(region.driver, region);
	if (text === null) continue;
	regions += 1;
	const order = [GATE_KEY, OPEN_FILE_KEY, byDriver.get(region.driver).call];
	const seen = [];
	for (const token of order) {
		const at = text.indexOf(token);
		if (at >= 0) seen.push({ token, at });
	}
	for (const required of [GATE_KEY, byDriver.get(region.driver).call]) {
		if (!seen.some((s) => s.token === required)) {
			errors.push(
				`${region.driver}: the category submenu never builds ${required}. Every driver shows this ` +
					'control; one that does not is a capability the user of that OS has to discover elsewhere, ' +
					'or does not have.'
			);
		}
	}
	const actual = [...seen]
		.sort((a, b) => a.at - b.at)
		.map((s) => s.token)
		.join(' → ');
	const wanted = seen.map((s) => s.token).join(' → ');
	if (actual !== wanted) {
		errors.push(
			`${region.driver}: the category submenu is built in the order\n        ${actual}\n      and the shared ` +
				`order is\n        ${wanted}\n      Three drivers with three orders for one submenu is what this ` +
				'gate exists to end.'
		);
	}
}

for (const region of LANGUAGE_REGIONS) {
	const text = slice(region.driver, region);
	if (text === null) continue;
	regions += 1;
	if (!text.includes(region.call || byDriver.get(region.driver).call)) {
		errors.push(
			`${region.driver}: the language submenu never opens with the « all sections » checkbox`
		);
	}
}

const expected =
	DRIVERS.reduce((n, d) => n + 1 + d.files.length, 0) +
	CATEGORY_REGIONS.length +
	LANGUAGE_REGIONS.length;
if (regions < expected && errors.length === 0) {
	errors.push(
		`only ${regions} of ${expected} region(s) were read — the gate compared less than it claims`
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the hotstring category submenus do not agree:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all three drivers build the hotstring category submenu in the same order ` +
		`(gate → open file → all sections → sections), open each language with one checkbox, and name no ` +
		`retired key (${regions} region(s) read).\x1b[0m`
);
