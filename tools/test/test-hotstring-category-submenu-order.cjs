// tools/test/test-hotstring-category-submenu-order.cjs

/**
 * ==============================================================================
 * MODULE: One Hotstring Category Submenu, One Order
 * DESCRIPTION:
 * Explicit category commands replace the former gate and all-sections switches.
 * The manifest owns their order, the optional file row and the section provider.
 * Native suites invoke both commands and verify the scoped transaction; this
 * gate rejects independent driver heads and declaration drift. Language and
 * whole-tree section checkboxes remain separate from these category commands.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const assert = require('node:assert/strict');
const path = require('path');
const { scriptTokens } = require('../lib/script-source.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

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

// Native category bindings consume the same menu key and supply its commands
// and providers. Their data lists cannot reintroduce either old switch.
const CATEGORY_REGIONS = [
	{
		driver: 'windows',
		file: 'windows/ui/menu/menu_hotstring_switches.ahk',
		from: '_HS_CategoryMenu(V1Cat, TomlPath, Sections,',
		to: '\n}'
	},
	{
		driver: 'macos',
		file: 'macos/ui/menu/menu_hotstrings.lua',
		from: 'local render_ctx = { commands = {',
		to: '\n\t\tend'
	},
	{
		driver: 'linux',
		file: 'linux/ui/menu/menu_builder.lua',
		from: 'local render_ctx = { commands = {\n\t\t\t["hotstring_category_enable_all"]',
		to: '\n\t\treturn {'
	}
];

// Personal data views consume the category declaration through their own
// persistence owners. Linux already sends personal groups through group_row;
// Windows additional personal files remain an explicit TODO outside this slice.
const PERSONAL_REGIONS = [
	{
		driver: 'windows',
		file: 'windows/ui/menu/menu_hotstrings.ahk',
		from: '_HS_PersonalRows(Options := unset) {',
		to: '\n\t\tPersonalActiveCount :=',
		tokens: ['_HS_CategoryMenu(', 'HotstringsPersonalScopeApply(Enabled, Options)']
	},
	{
		driver: 'macos',
		file: 'macos/ui/menu/menu_hotstrings_custom.lua',
		from: 'function M.build_custom(',
		to: '\nreturn M',
		tokens: [
			'"hotstring_category_menu"',
			'"hotstring_category_enable_all"',
			'"hotstring_category_disable_all"',
			'M.category_scope_fn(ctx, names,',
			'submenu = scope_menu(scope_names, {}, menu_items)',
			'submenu = file_menu_for_group(gname, g_rows, admission, readonly)',
			'PersonalFileScope.bind(ctx, record)',
			'PersonalFiles.components(gname)',
			'record and record.admitted == false'
		]
	},
	{
		driver: 'linux',
		file: 'linux/ui/menu/menu_builder.lua',
		from: '["hotstring_personal"] = function()',
		to: '["hotstring_extensions"] = function()',
		tokens: ['group_row(name)']
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

const expectedDeclaration = [
	{
		type: 'command',
		id: 'hotstring_category_enable_all',
		i18n: 'menu.hotstrings.scope_enable_all'
	},
	{
		type: 'command',
		id: 'hotstring_category_disable_all',
		i18n: 'menu.hotstrings.scope_disable_all'
	},
	{ type: 'list', id: 'hotstring_category_file' },
	{ type: '---' },
	{ type: 'list', id: 'hotstring_category_sections' }
];
function validateDeclaration(rows) {
	assert.deepEqual(rows, expectedDeclaration);
}
const manifest = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared/modules/menu/menu_manifest.json'), 'utf8')
);
try {
	validateDeclaration(manifest.hotstring_category_menu);
	// Independent negative controls keep the oracle sensitive to the old toggle,
	// a reordered command, a missing section list and a platform-only fork.
	for (const mutate of [
		(rows) => {
			rows[0].type = 'check';
		},
		(rows) => {
			[rows[0], rows[1]] = [rows[1], rows[0]];
		},
		(rows) => {
			rows.pop();
		},
		(rows) => {
			rows[0].platforms = ['ahk'];
		}
	]) {
		const changed = structuredClone(expectedDeclaration);
		mutate(changed);
		assert.throws(() => validateDeclaration(changed));
	}
} catch (error) {
	errors.push(`shared category declaration: ${error.message}`);
}

for (const region of CATEGORY_REGIONS) {
	const text = slice(region.driver, region);
	if (text === null) continue;
	regions += 1;
	for (const token of [
		'"hotstring_category_menu"',
		...expectedDeclaration.filter((r) => r.id).map((r) => r.id)
	]) {
		if (!text.includes(token))
			errors.push(`${region.driver}: category binding is missing ${token}`);
	}
	for (const token of [
		'menu.hotstrings.category_enable',
		ALL_SECTIONS_KEY,
		byDriver.get(region.driver).call
	]) {
		if (text.includes(token))
			errors.push(`${region.driver}: category binding still builds the redundant ${token}`);
	}
}

for (const region of PERSONAL_REGIONS) {
	const text = slice(region.driver, region);
	if (text === null) continue;
	regions += 1;
	// Keep the native canonical binding causal: removing either identity
	// admission or its captured callback must make this same oracle reject it.
	if (region.driver === 'macos') {
		const executableRange = (source, fragment) => {
			const tokens = scriptTokens(source, '.lua');
			const expected = scriptTokens(fragment, '.lua');
			const index = tokens.findIndex((_, index) =>
				expected.every(
					(token, offset) =>
						tokens[index + offset]?.kind === token.kind &&
						tokens[index + offset]?.value === token.value
				)
			);
			return index < 0
				? null
				: { start: tokens[index].start, end: tokens[index + expected.length - 1].end };
		};
		const actualRoute = [
			'local parts = PersonalFiles.components(gname)',
			'local admission = gname ~= "personal" and PersonalFileScope.bind(ctx, record) or nil',
			'local readonly = record and record.admitted == false',
			'submenu = file_menu_for_group(gname, g_rows, admission, readonly)',
			'M.category_scope_fn(ctx, { gname }, true, check)',
			'M.category_scope_fn(ctx, { gname }, false, check)',
			'local controls = PersonalFileMenu.build({ manifest = ManifestMenu, current = personal_current'
		];
		const validatesBinding = (source) =>
			region.tokens.every((token) => source.includes(token)) &&
			actualRoute.every((fragment) => executableRange(source, fragment) !== null);
		assert.equal(
			actualRoute.length,
			7,
			'the owner, admission, destination and callbacks all have causal controls'
		);
		assert.equal(validatesBinding(text), true);
		for (const removed of actualRoute) {
			const range = executableRange(text, removed);
			assert.notEqual(range, null, 'the mutation must replace the actual executable owner route');
			for (const dormant of ['-- ' + removed + '\n', 'local dormant = [[' + removed + ']]\n']) {
				assert.equal(
					validatesBinding(text.slice(0, range.start) + dormant + text.slice(range.end)),
					false
				);
			}
		}
	}
	for (const token of region.tokens) {
		if (!text.includes(token))
			errors.push(`${region.driver}: personal binding is missing ${token}`);
	}
	for (const token of [
		'menu.hotstrings.category_enable',
		ALL_SECTIONS_KEY,
		byDriver.get(region.driver).call
	]) {
		if (text.includes(token))
			errors.push(`${region.driver}: personal binding still builds the redundant ${token}`);
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
	PERSONAL_REGIONS.length +
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
	`\x1b[32m[OK] all three drivers consume the shared category commands, file and section order, ` +
		`retain language section controls, and name no retired key (${regions} region(s) read).\x1b[0m`
);
