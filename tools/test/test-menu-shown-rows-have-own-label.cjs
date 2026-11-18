// tools/test/test-menu-shown-rows-have-own-label.cjs

/**
 * ==============================================================================
 * MODULE: Shown Menu Rows Have Their Own Translated Label
 * DESCRIPTION:
 * Every manifest row a driver can show resolves to a label of its own in all 21
 * catalogues, and every static key a driver's menu code or the menu manifest
 * names exists in all 21.
 *
 * THE BUG THIS CLOSES:
 * The Windows tray showed `pause_switch_enabled`, `on_pause` and `on_resume` in
 * « Disposition ». `_LAY_LayoutFeatureAltGrRows` listed the whole `layout`
 * section minus a denylist, so three rows added later fell into it, and the
 * three carried the section's own key, `menu.layout`, which no catalogue holds.
 * `test-manifest-menu-labels-resolve.cjs` only looks at rows of type "feature",
 * these are "boolean" and "string", and its ratchet counted them as
 * "not rendered".
 *
 * WHAT COUNTS AS SHOWN:
 * 1. A row of `menu_manifest.json` carrying a `path`. Windows labels a `feature`
 *    row from the feature manifest whatever `i18n` says, so both are checked.
 * 2. Every row of a section a driver lists. Listing sites are found by scanning
 *    the drivers: a call naming a section this file does not know fails, so a
 *    new listing cannot pass unseen, and the rendered walks of each driver
 *    (test_tray_rows_read_as_text) catch what a scan cannot reach.
 *
 * KEYS READ AS THEIR NAMES (lot CB):
 * The Tap-Hold rows read LCtrl, RShift and a hold printed `lalt`. No row
 * text, nor any name of _shared/layouts/data/keycodes/key_names.json, may hold a key
 * id or abbreviation in any locale; the rendered walks apply the same judge.
 *
 * THE STRICT RULE, MENU OR NOT:
 * No feature may carry a section's own key. The exceptions below each give a
 * reason; an exception that stopped being true fails, so the list can only
 * shrink.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { candidateKeys } = require('../lib/manifest-label-keys.cjs');
const { RAW_KEY_SPELLINGS, rowTextDefect } = require('./lib/menu-row-text.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const ERGOPTI = path.join(ROOT, 'static', 'ergopti_plus');
const LOCALES = path.join(ERGOPTI, '_shared', 'core', 'i18n', 'data', 'locales');
const MENU_MANIFEST = path.join(ERGOPTI, '_shared', 'menu', 'data', 'menu_manifest.json');
const FEATURES = path.join(ERGOPTI, 'windows', '_generated', 'features_manifest.ahk');

const LOCALE_COUNT = 21;
// Floors: a scan that reads nothing passes for free.
const MIN_FEATURES = 150;
const MIN_SECTIONS = 20;
const MIN_MENU_ROWS = 15;
const MIN_DRIVER_KEYS = 500;

// Sections a driver lists row by row. The value says which rows of it are shown.
const LISTED_SECTIONS = new Map([
	['hotstrings.autocorrection', { skip: new Set() }],
	['hotstrings.distances_reduction', { skip: new Set() }],
	['hotstrings.sfbs_reduction', { skip: new Set() }],
	['hotstrings.rolls', { skip: new Set() }],
	['hotstrings.magic_key', { skip: new Set() }],
	['hotstrings.french_autocorrection', { skip: new Set() }],
	['hotstrings.french_distancesreduction', { skip: new Set() }],
	['hotstrings.french_magickey', { skip: new Set() }],
	// The master of the block, drawn by the category row; not one of its rows.
	['hotstrings.dynamic', { skip: new Set(['hotstrings.dynamic.enabled']) }],
	['shortcuts.caps_word.pointer', { skip: new Set() }]
]);

// Sections listed for something other than a label: settings I/O, inventories
// and tests of a state, never a row of text.
const LISTED_WITHOUT_A_LABEL = new Map([
	['shortcuts.script_control', 'its slots read the chord, the labels are its own rows'],
	['shortcuts.keyboard', 'the shortcut rows are labelled by the shortcut registry'],
	['shortcuts.key_combination_taps', 'read for its default actions, never drawn as rows']
]);

// A variable section argument: each site is read by hand and named here, so a
// new one fails until someone says what it lists.
const VARIABLE_LISTING_SITES = new Map([
	['windows/menu/ui/builder/submenus.ahk', 'V2Section: the hotstring categories listed above'],
	['windows/hotstrings/ui/menu/hotstrings.ahk', 'the hotstring categories listed above'],
	['windows/hotstrings/ui/menu/switches.ahk', 'paths only: the « all sections » writers'],
	['windows/menu/engine/manifest_menu.ahk', 'a `group_label` row, of which the manifest has none']
]);

// Features allowed to carry a section's key. Each entry is a setting no menu
// labels through that key.
const SECTION_KEY_EXCEPTIONS = new Map([
	['hotstrings.dynamic.enabled', 'the master of its block, shown by the category row'],
	['llm.user_profiles', 'stored data, the profile rows name each profile'],
	['category_enabled.key_combinations', 'the gate of the group the same key names'],
	['network.proxy_override', 'the single setting of its section, drawn with its own i18n row'],
	// A pair's row is written from the names of its two keys.
	['shortcuts.key_combination_taps.alt_gr_then_left_alt', 'labelled by its two keys'],
	['shortcuts.key_combination_taps.alt_gr_then_caps_lock', 'labelled by its two keys'],
	['shortcuts.key_combination_taps.left_alt_then_caps_lock', 'labelled by its two keys']
]);

// `hotstrings.personal.*`: the user's own sections, labelled by their TOML.
const USER_LABELLED_PREFIX = 'hotstrings.personal.';

const errors = [];

/**
 * Reads one catalogue.
 * @param {string} file Catalogue file name.
 * @returns {Object<string, string>} Its keys.
 */
function readCatalogue(file) {
	return JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
}

const catalogues = new Map();
for (const file of fs.readdirSync(LOCALES).filter((name) => name.endsWith('.json')))
	catalogues.set(file.replace('.json', ''), readCatalogue(file));
if (catalogues.size !== LOCALE_COUNT)
	errors.push(`expected ${LOCALE_COUNT} catalogues, found ${catalogues.size}`);

/**
 * Whether a catalogue holds a real text for a key.
 * @param {Object<string, string>} catalogue One catalogue.
 * @param {string} key Locale key.
 * @returns {boolean}
 */
function hasText(catalogue, key) {
	return typeof catalogue[key] === 'string' && catalogue[key].trim() !== '';
}

/**
 * The catalogues in which no candidate of a feature resolves.
 * @param {{key: string, path: string}} row Feature row.
 * @returns {string[]} Locale codes.
 */
function missingIn(row) {
	const candidates = candidateKeys(row.key, row.path);
	return [...catalogues]
		.filter(([, catalogue]) => !candidates.some((key) => hasText(catalogue, key)))
		.map(([code]) => code);
}

/**
 * Reads every feature and section of the generated manifest.
 * @returns {{features: Map<string, object>, sectionKeys: Set<string>}}
 */
function readManifest() {
	const source = fs.readFileSync(FEATURES, 'utf8');
	const features = new Map();
	for (const line of source.split('\n')) {
		const head = line.match(/Map\("path", "([^"]*)", "id", "([^"]*)", "section", "([^"]*)"/);
		if (!head) continue;
		const key = line.match(/"description_key", "([^"]*)"/);
		features.set(head[1], { path: head[1], id: head[2], section: head[3], key: key ? key[1] : '' });
	}
	const sectionKeys = new Set();
	for (const match of source.matchAll(
		/^\s*"[A-Za-z0-9_.]+",\s*Map\("description_key",\s*"([^"]*)"/gm
	))
		sectionKeys.add(match[1]);
	return { features, sectionKeys };
}

/**
 * Collects every object of the menu manifest.
 * @param {*} node Current node.
 * @param {object[]} out Accumulator.
 * @returns {object[]} Every object.
 */
function menuObjects(node, out = []) {
	if (Array.isArray(node)) node.forEach((value) => menuObjects(value, out));
	else if (node && typeof node === 'object') {
		out.push(node);
		Object.values(node).forEach((value) => menuObjects(value, out));
	}
	return out;
}

/**
 * Lists a driver's shipped source files.
 * @param {string} dir Directory.
 * @param {string} extension File extension.
 * @param {string[]} out Accumulator.
 * @returns {string[]} Files, without tests or generated output.
 */
function sourceFiles(dir, extension, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.name === 'tests' || entry.name === '_generated') continue;
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) sourceFiles(full, extension, out);
		else if (entry.name.endsWith(extension)) out.push(full);
	}
	return out;
}

const relative = (file) => path.relative(ERGOPTI, file).split(path.sep).join('/');

const DRIVERS = [
	{ dir: 'windows', extension: '.ahk' },
	{ dir: 'macos', extension: '.lua' },
	{ dir: 'linux', extension: '.lua' }
];
const drivers = DRIVERS.flatMap(({ dir, extension }) =>
	sourceFiles(path.join(ERGOPTI, dir), extension).map((file) => ({
		file: relative(file),
		source: fs.readFileSync(file, 'utf8')
	}))
);

// =================================================
// =================================================
// ======= 1/ The rows a driver lists itself =======
// =================================================
// =================================================

/**
 * Finds every section listing of the drivers, and refuses an unknown one.
 * @returns {number} How many listing sites were read.
 */
function auditListingSites() {
	let sites = 0;
	const listing = /\b(?:ManifestFeaturesForSection|declared_section_entries)\(([^)\n]*)\)/g;
	for (const { file, source } of drivers) {
		for (const match of source.matchAll(listing)) {
			const argument = match[1].trim();
			if (argument.startsWith('SectionPath') || argument === 'section') continue;
			sites += 1;
			const literal = argument.match(/^"([^"]+)"$/);
			if (literal) {
				if (!LISTED_SECTIONS.has(literal[1]) && !LISTED_WITHOUT_A_LABEL.has(literal[1]))
					errors.push(
						`${file} lists section "${literal[1]}": name the feature rows it draws instead, or add the section to LISTED_SECTIONS so each of its rows is checked`
					);
			} else if (file.startsWith('windows/ui/') && !VARIABLE_LISTING_SITES.has(file)) {
				errors.push(`${file} lists a section through ${argument}: say what it lists here`);
			}
		}
	}
	return sites;
}

// ==========================================
// ==========================================
// ======= 2/ Rows and their own keys =======
// ==========================================
// ==========================================

/**
 * Checks one shown row.
 * @param {{key: string, path: string}} row Feature row.
 * @param {string} where Why it is shown.
 * @param {Set<string>} sectionKeys Keys naming a section.
 */
function checkShownRow(row, where, sectionKeys) {
	if (row.path.startsWith(USER_LABELLED_PREFIX)) return;
	if (row.key === '') errors.push(`${row.path} (${where}) has no description_key`);
	if (sectionKeys.has(row.key))
		errors.push(`${row.path} (${where}) carries the section key "${row.key}", not its own`);
	const missing = missingIn(row);
	if (missing.length > 0)
		errors.push(
			`${row.path} (${where}, key "${row.key}") shows its raw id in: ${missing.join(' ')}`
		);
}

const { features, sectionKeys } = readManifest();
if (features.size < MIN_FEATURES) errors.push(`only ${features.size} features parsed`);
if (sectionKeys.size < MIN_SECTIONS) errors.push(`only ${sectionKeys.size} sections parsed`);

const sites = auditListingSites();
if (sites === 0) errors.push('no section listing found: the scan matches nothing');

for (const [section, { skip }] of LISTED_SECTIONS) {
	const rows = [...features.values()].filter((row) => row.section === section);
	if (rows.length === 0) errors.push(`listed section ${section} has no row`);
	for (const row of rows)
		if (!skip.has(row.path)) checkShownRow(row, `listed section ${section}`, sectionKeys);
}

const menuRows = menuObjects(JSON.parse(fs.readFileSync(MENU_MANIFEST, 'utf8')));
const pathRows = menuRows.filter((row) => typeof row.path === 'string' && row.type);
if (pathRows.length < MIN_MENU_ROWS) errors.push(`only ${pathRows.length} menu path rows parsed`);
for (const row of pathRows) {
	const feature = features.get(row.path);
	if (feature && (row.type === 'feature' || typeof row.i18n !== 'string'))
		checkShownRow(feature, `menu row ${row.path}`, sectionKeys);
}

for (const row of features.values()) {
	if (!sectionKeys.has(row.key) || SECTION_KEY_EXCEPTIONS.has(row.path)) continue;
	errors.push(`${row.path} carries the section key "${row.key}": give it a key of its own`);
}
for (const [featurePath, reason] of SECTION_KEY_EXCEPTIONS) {
	const row = features.get(featurePath);
	if (!row || !sectionKeys.has(row.key))
		errors.push(`the exception for ${featurePath} (${reason}) no longer applies: delete it`);
}

// ==========================================
// ==========================================
// ======= 3/ Every key the code names ======
// ==========================================
// ==========================================

/**
 * Whether a key is written in every catalogue.
 * @param {string} key Locale key.
 * @param {string} where Who names it.
 */
function checkKeyEverywhere(key, where) {
	const missing = [...catalogues]
		.filter(([, catalogue]) => !hasText(catalogue, key))
		.map(([code]) => code);
	if (missing.length > 0) errors.push(`${where} names "${key}", absent from: ${missing.join(' ')}`);
}

const MENU_KEY_FIELDS = ['i18n', 'reason_key', 'disabled_reason_key', 'label_key', 'title_key'];
let menuKeys = 0;
for (const row of menuRows) {
	for (const field of MENU_KEY_FIELDS) {
		if (typeof row[field] !== 'string' || row[field] === '') continue;
		menuKeys += 1;
		checkKeyEverywhere(row[field], `menu_manifest.json ${field}`);
	}
}

const ACCESSOR =
	/(?:^|[^A-Za-z0-9_.])(?:t|i18n\.get|i18n\.section|ctx\.t|i18n_safe)\(\s*"([a-z][a-z0-9_]*(?:\.[A-Za-z0-9_]+)+)"\s*[,)]/gm;
let driverKeys = 0;
for (const { file, source } of drivers) {
	for (const match of source.matchAll(ACCESSOR)) {
		driverKeys += 1;
		checkKeyEverywhere(match[1], file);
	}
}
if (menuKeys + driverKeys < MIN_DRIVER_KEYS)
	errors.push(`only ${menuKeys + driverKeys} static keys found: the scan matches almost nothing`);

// ==========================================
// ==========================================
// ======= 4/ Keys read as their names ======
// ==========================================
// ==========================================

// Lot CB: the Tap-Hold rows read LCtrl, RShift in every locale. A row key's
// text, and every name of the shared key name table, holds no key id or
// abbreviation (case-exact, as the rendered walks judge a row).
const rowKeys = new Set();
for (const row of menuRows)
	for (const field of MENU_KEY_FIELDS)
		if (typeof row[field] === 'string' && row[field] !== '') rowKeys.add(row[field]);
for (const key of Object.keys(catalogues.get('en')))
	if (/^(key_name|tap_hold|gesture\.slots)\./.test(key)) rowKeys.add(key);
let keyTexts = 0;
for (const [code, catalogue] of catalogues) {
	for (const key of rowKeys) {
		if (!hasText(catalogue, key)) continue;
		keyTexts += 1;
		const raw = catalogue[key]
			.split(/[^\p{L}\p{N}_]+/u)
			.find((word) => RAW_KEY_SPELLINGS.has(word));
		if (raw) errors.push(`${code}: ${key} shows the raw key "${raw}": name it through key_name.*`);
	}
}
// The judge the rendered walks use refuses each raw spelling and passes the names.
for (const [text, refused] of [
	['LCtrl  :  Copier  /  Ctrl', true],
	['Hold → lalt', true],
	['caps_lock + tab', true],
	['Ctrl gauche  :  Copier  /  Maj', false],
	['Échap + Tab', false]
])
	if (Boolean(rowTextDefect(text, new Set(), [])) !== refused)
		errors.push(`the row judge ${refused ? 'passes' : 'refuses'} "${text}"`);
if (keyTexts < MIN_MENU_ROWS * LOCALE_COUNT)
	errors.push(`only ${keyTexts} row texts judged for raw keys: the scan reads almost nothing`);

// ==================================================
// ==================================================
// ======= 5/ Modifier templates name no key ========
// ==================================================
// ==================================================

// Lot CH: the shortcut group headings and Add rows spelled their modifiers in
// each locale's text (French « Raccourcis ^⇧ Ctrl+Shift », macOS « ⎇ Alt »
// for Option). Each is now a template whose {1} the drivers fill from the key
// name table, so no locale may write a modifier, its glyph or a stand-in of
// its own into one: a spelled key would never follow the table again.
const MODIFIER_TEMPLATES = [];
for (const family of ['alt', 'ctrl', 'ctrl_shift', 'cmd', 'cmd_shift', 'win', 'super'])
	for (const part of ['group', 'add']) MODIFIER_TEMPLATES.push(`menu.shortcuts.${family}_${part}`);
const MODIFIER_IDS = ['shift', 'ctrl', 'alt', 'option', 'cmd', 'win', 'super', 'fn', 'alt_gr'];
const MODIFIER_GLYPHS = ['⌃', '⌥', '⇧', '⌘', '⊞', '❖', '⎇', '^'];
const englishNames = MODIFIER_IDS.map((id) => catalogues.get('en')[`key_name.${id}`]);
let templatesJudged = 0;
for (const [code, catalogue] of catalogues) {
	const names = new Set([
		...englishNames,
		...MODIFIER_IDS.map((id) => catalogue[`key_name.${id}`]),
		'Shift',
		'Command'
	]);
	for (const key of MODIFIER_TEMPLATES) {
		const text = catalogue[key];
		if (typeof text !== 'string') {
			errors.push(`${code}: ${key} is missing`);
			continue;
		}
		templatesJudged += 1;
		if (text.split('{1}').length !== 2)
			errors.push(`${code}: ${key} must hold exactly one {1}, the group's modifiers`);
		const spelled = text.split(/[^\p{L}\p{N}_]+/u).find((word) => names.has(word));
		if (spelled)
			errors.push(`${code}: ${key} spells the modifier "${spelled}" instead of filling {1}`);
		const glyph = MODIFIER_GLYPHS.find((mark) => text.includes(mark));
		if (glyph) errors.push(`${code}: ${key} draws the glyph "${glyph}" instead of filling {1}`);
	}
}
if (templatesJudged !== MODIFIER_TEMPLATES.length * LOCALE_COUNT)
	errors.push(`only ${templatesJudged} modifier templates judged in ${catalogues.size} catalogues`);
// The judge refuses the old French heading and passes its template.
for (const [text, refused] of [
	['Raccourcis ^⇧ Ctrl+Shift', true],
	['Raccourcis {1}', false]
]) {
	const names = new Set(englishNames);
	const defect =
		text.split('{1}').length !== 2 ||
		text.split(/[^\p{L}\p{N}_]+/u).some((word) => names.has(word)) ||
		MODIFIER_GLYPHS.some((mark) => text.includes(mark));
	if (defect !== refused)
		errors.push(`the modifier template judge ${refused ? 'passes' : 'refuses'} "${text}"`);
}

if (errors.length > 0) {
	console.error(`\x1b[31m[ERROR] ${errors.length} menu label defect(s):\x1b[0m`);
	for (const error of [...new Set(errors)]) console.error(`  ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] ${features.size} features, ${sites} listing sites, ${menuKeys} menu keys and ${driverKeys} driver keys hold in ${catalogues.size} catalogues.\x1b[0m`
);
