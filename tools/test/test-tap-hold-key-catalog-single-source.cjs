// tools/test/test-tap-hold-key-catalog-single-source.cjs

/**
 * ==============================================================================
 * MODULE: One Tap-Hold Key Catalogue
 * DESCRIPTION:
 * The keys a tap-hold can be set on, their order in the tray, the hand each
 * belongs to and the label each carries are declared once, in
 * `[tap_hold.catalog]` of `_shared/tap_hold/defaults.toml`, and every driver
 * reads them there.
 *
 * ROOT CAUSE ENCODED:
 * the list lived in three copies that pointed at a fourth that never existed.
 * Windows kept `_TH_KeyDefs` "mirroring menu_manifest.json
 * tap_hold_keys_catalog", Linux kept its own `KEY_ORDER`, and the macOS menu
 * read that same missing manifest key, so its built-in fallback always won —
 * and the fallback said `action = true` where `fn = true` was meant, which put
 * Fn under « Main droite ». Nothing compared any of them.
 *
 * WHAT IS HELD:
 * 1. The catalogue parses, every entry names a hand and a translated label,
 *    and Fn sits on the left.
 * 2. Each driver's column is exactly the set of keys its engine can remap:
 *    macOS `tap_hold_keys.json` (in the same order), the Linux engine's evdev
 *    table, and the keys the Windows `platform/remap/*.ahk` hotkeys arm.
 * 3. Each driver reads the catalogue, and none keeps a list of its own.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DEFAULTS = path.join(SP, '_shared', 'tap_hold', 'defaults.toml');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');
const MAC_KEYS = path.join(SP, 'macos', 'platform', 'remap', 'data', 'tap_hold_keys.json');
const LINUX_ENGINE = path.join(SP, 'linux', 'platform', 'remap', 'tap_hold_engine.lua');
const WINDOWS_REMAP = path.join(SP, 'windows', 'platform', 'remap');

const PLATFORMS = ['ahk', 'hs', 'linux'];
const HANDS = new Set(['left', 'right']);

// Floors: a catalogue or a scan that yields nothing must not pass for free.
const MIN_ENTRIES = 14;
const MIN_PER_PLATFORM = 14;

const errors = [];

/**
 * Reads a file, recording its absence as a failure.
 * @param {string} file Absolute path.
 * @returns {string}
 */
function read(file) {
	try {
		return fs.readFileSync(file, 'utf8');
	} catch (e) {
		errors.push(`cannot read ${path.relative(ROOT, file)}: ${e.message}`);
		return '';
	}
}

/**
 * Removes Lua and AutoHotkey line comments, so a comment naming a key is
 * never mistaken for code that uses it.
 * @param {string} src Source text.
 * @param {string} ext ".lua" or ".ahk".
 * @returns {string}
 */
function stripLineComments(src, ext) {
	const marker = ext === '.ahk' ? /^\s*;.*$/gm : /^\s*--.*$/gm;
	return src.replace(marker, '');
}

// ==========================================
// ==========================================
// ======= 1/ The catalogue itself ==========
// ==========================================
// ==========================================

let entries = [];
try {
	const parsed = TOML.parse(read(DEFAULTS));
	const catalog = parsed.tap_hold && parsed.tap_hold.catalog;
	entries = catalog && Array.isArray(catalog.keys) ? catalog.keys : [];
} catch (e) {
	errors.push(`_shared/tap_hold/defaults.toml does not parse: ${e.message}`);
}

if (entries.length < MIN_ENTRIES) {
	errors.push(
		`[tap_hold.catalog] keys lists ${entries.length} key(s), expected at least ${MIN_ENTRIES}. ` +
			'Every tray builds its Tap-Hold key rows from it.'
	);
}

const locales = fs
	.readdirSync(LOCALES)
	.filter((f) => f.endsWith('.json'))
	.map((f) => ({ name: f, data: JSON.parse(read(path.join(LOCALES, f))) }));
if (locales.length !== 21) errors.push(`expected 21 locale files, found ${locales.length}`);

const columns = { ahk: [], hs: [], linux: [] };
const seenIds = new Set();
for (const [index, entry] of entries.entries()) {
	const where = `[tap_hold.catalog] keys[${index + 1}]`;
	if (typeof entry.id !== 'string' || entry.id === '') {
		errors.push(`${where} has no id`);
		continue;
	}
	if (seenIds.has(entry.id)) errors.push(`${where}: id "${entry.id}" is listed twice`);
	seenIds.add(entry.id);
	if (!HANDS.has(entry.hand)) {
		errors.push(
			`${where} "${entry.id}": hand must be "left" or "right", got ${JSON.stringify(entry.hand)}`
		);
	}
	if (typeof entry.label_key !== 'string' || entry.label_key === '') {
		errors.push(`${where} "${entry.id}" has no label_key`);
	} else {
		for (const locale of locales) {
			if (typeof locale.data[entry.label_key] !== 'string') {
				errors.push(`${where} "${entry.id}": ${locale.name} has no "${entry.label_key}"`);
			}
		}
	}
	let platforms = 0;
	for (const platform of PLATFORMS) {
		if (entry[platform] === undefined) continue;
		if (typeof entry[platform] !== 'string' || entry[platform] === '') {
			errors.push(`${where} "${entry.id}": ${platform} must be a non-empty key id`);
			continue;
		}
		columns[platform].push(entry[platform]);
		platforms += 1;
	}
	if (platforms === 0) errors.push(`${where} "${entry.id}" names no driver's key`);
	for (const field of Object.keys(entry)) {
		if (!['id', 'hand', 'label_key', ...PLATFORMS].includes(field)) {
			errors.push(`${where} "${entry.id}": unknown field "${field}" — no driver reads it`);
		}
	}
}

for (const platform of PLATFORMS) {
	const ids = columns[platform];
	if (ids.length < MIN_PER_PLATFORM) {
		errors.push(
			`the ${platform} column lists ${ids.length} key(s), expected at least ${MIN_PER_PLATFORM}`
		);
	}
	if (new Set(ids).size !== ids.length) errors.push(`the ${platform} column repeats a key id`);
}

// The bug this catalogue replaced: Fn listed under the right hand on macOS.
const fn = entries.find((entry) => entry.hs === 'fn');
if (!fn) {
	errors.push('the catalogue has no macOS Fn key');
} else if (fn.hand !== 'left') {
	errors.push(`the macOS Fn key is on the "${fn.hand}" hand; it is a left-hand key`);
}

// ==========================================
// ==========================================
// ======= 2/ Each column is its engine =====
// ==========================================
// ==========================================

/**
 * Compares a catalogue column with the key set a driver's engine implements.
 * @param {string} platform Catalogue column.
 * @param {string[]} engine Engine key ids.
 * @param {string} owner Where the engine set comes from.
 * @param {boolean} ordered Whether the order must match too.
 */
function sameKeys(platform, engine, owner, ordered) {
	if (engine.length < MIN_PER_PLATFORM) {
		errors.push(`read only ${engine.length} key(s) from ${owner} — the scan is broken`);
		return;
	}
	const column = columns[platform];
	const missing = engine.filter((id) => !column.includes(id));
	const extra = column.filter((id) => !engine.includes(id));
	if (missing.length > 0) {
		errors.push(
			`${owner} remaps ${missing.join(', ')}, which the catalogue's ${platform} column omits`
		);
	}
	if (extra.length > 0) {
		errors.push(
			`the catalogue's ${platform} column names ${extra.join(', ')}, which ${owner} cannot remap`
		);
	}
	if (ordered && missing.length === 0 && extra.length === 0 && column.join() !== engine.join()) {
		errors.push(
			`the catalogue's ${platform} order (${column.join(', ')}) differs from ${owner} (${engine.join(', ')})`
		);
	}
}

// macOS: the Karabiner matcher data, whose order is also the generated rule order.
let macKeys = [];
try {
	macKeys = JSON.parse(read(MAC_KEYS)).map((key) => key.id);
} catch (e) {
	errors.push(`tap_hold_keys.json does not parse: ${e.message}`);
}
sameKeys('hs', macKeys, 'macos/platform/remap/data/tap_hold_keys.json', true);

// Linux: the evdev code table of the tap-hold engine.
const linuxEngine = stripLineComments(read(LINUX_ENGINE), '.lua');
const codes = linuxEngine.match(/M\.KEY_CODES\s*=\s*\{([\s\S]*?)\}/);
const linuxKeys = codes ? [...codes[1].matchAll(/([a-z_]+)\s*=\s*\d+/g)].map((m) => m[1]) : [];
sameKeys('linux', linuxKeys, 'linux/platform/remap/tap_hold_engine.lua KEY_CODES', false);

// Windows: every key a platform/remap hotkey reads a tap or a hold for.
const windowsKeys = new Set();
for (const file of fs.readdirSync(WINDOWS_REMAP).filter((f) => f.endsWith('.ahk'))) {
	const src = stripLineComments(read(path.join(WINDOWS_REMAP, file)), '.ahk');
	for (const m of src.matchAll(
		/TapHold(?:TapAction|HoldModifier|HoldLayer)\(TapHold,\s*"([a-z_]+)"\)/g
	)) {
		windowsKeys.add(m[1]);
	}
}
sameKeys('ahk', [...windowsKeys], 'windows/platform/remap/*.ahk', false);

// ==========================================
// ==========================================
// ======= 3/ Every driver reads it =========
// ==========================================
// ==========================================

const READERS = [
	{
		file: 'macos/ui/menu/menu_tap_holds.lua',
		reads: /require\("tap_hold\.key_catalog"\)/,
		retired: [/tap_hold_keys_catalog/, /LEFT_HAND_IDS/, /_load_left_hand_from_catalog/]
	},
	{
		file: 'linux/ui/menu/menu_builder.lua',
		reads: /\.key_catalog\(\)/,
		retired: [/KEY_ORDER/]
	},
	{
		file: 'linux/platform/remap/tap_hold_engine.lua',
		reads: null,
		retired: [/KEY_ORDER/]
	},
	{
		file: 'linux/platform/remap/tap_hold_loader.lua',
		reads: /require\("tap_hold\.key_catalog"\)/,
		retired: []
	},
	{
		file: 'windows/platform/remap/tap_hold_writer.ahk',
		reads: /"tap_hold\.catalog"/,
		retired: [/tap_hold_keys_catalog/, /Map\("id",\s*"[a-z_]+",\s*"i18n",\s*"tap_hold\.group\./]
	}
];

for (const reader of READERS) {
	const ext = path.extname(reader.file);
	const src = stripLineComments(read(path.join(SP, reader.file)), ext);
	if (src.length < 500) {
		errors.push(`${reader.file} is unreadable or nearly empty (${src.length} bytes)`);
		continue;
	}
	if (reader.reads && !reader.reads.test(src)) {
		errors.push(`${reader.file} does not read the shared [tap_hold.catalog]`);
	}
	for (const pattern of reader.retired) {
		if (pattern.test(src)) {
			errors.push(`${reader.file} still keeps a key list of its own (${pattern})`);
		}
	}
}

// ==========================
// ==========================
// ======= 4/ Verdict =======
// ==========================
// ==========================

if (errors.length > 0) {
	console.error(`\x1b[31m[FAIL] tap-hold key catalogue: ${errors.length} problem(s)\x1b[0m`);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] One tap-hold key catalogue: ${entries.length} key(s), ` +
		`${columns.ahk.length} Windows / ${columns.hs.length} macOS / ${columns.linux.length} Linux, ` +
		'each matching its engine and read by its tray.\x1b[0m'
);
