// tools/test/test-menu-reset-terminology.cjs

/**
 * ==============================================================================
 * MODULE: One Label for Restore, One for Clear
 * DESCRIPTION:
 * Every tray row that puts a section back to Ergopti's preset reads ONE shared
 * key, common.restore_recommended (« ↺ Restaurer les valeurs conseillées »), and
 * every row that removes a section's settings so the operating system behaves
 * as if Ergopti were absent reads ONE other, common.clear_to_system (« ✕ Tout
 * effacer (comportement du système) »).
 *
 * One concept had five labels before: « ↺ Valeurs par défaut », « ↩ Restaurer
 * les valeurs par défaut », « Réinitialiser les valeurs par défaut », « ✕
 * Désactiver tous les gestes » and « Tout désactiver ». The last two read like
 * the category switch, while they leave it on and empty every slot instead.
 *
 * WHAT THIS PINS, per surface, so a partial revert cannot pass:
 *   1. Every declared restore / clear row of the manifest uses the shared key
 *      its id means, and the menus that carry them still declare them.
 *   2. The two shared keys exist in all 21 locales with the approved French and
 *      English wording, and no locale keeps a retired per-menu label.
 *   3. The rows a driver still builds itself (word delimiters, wrapping
 *      symbols) read the shared key, and no source file names a retired key.
 * Every scan asserts it read something first: an empty scan would pass this
 * gate while checking nothing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { publishesMenuTemplate } = require('../lib/menu-shared-delegation.cjs');
const { scriptTokens } = require('../lib/script-source.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

const RESTORE_KEY = 'common.restore_recommended';
const CLEAR_KEY = 'common.clear_to_system';

// The approved wording, from the product decision that introduced the keys.
const APPROVED = {
	[RESTORE_KEY]: { fr: '↺ Restaurer les valeurs conseillées', en: '↺ Restore recommended values' },
	[CLEAR_KEY]: {
		fr: '✕ Tout effacer (comportement du système)',
		en: '✕ Clear all (system behaviour)'
	}
};

// Row ids that mean "restore the preset" and "clear to system behaviour".
const RESTORE_IDS = new Set([
	'restore_recommended',
	'restore_defaults',
	'reset_defaults',
	'scope_restore',
	'word_expanders_restore',
	'wrap_symbols_restore'
]);
const CLEAR_IDS = new Set(['disable_all', 'clear_to_system', 'scope_clear']);

// Menus that must keep declaring the rows: menu -> [restore rows, clear rows].
// Metrics and the AI menu declare the restore alone: the maintainer retired
// their clear rows on 2026-09-30 (ai-menu-no-clear). Where each row sits is
// test-menu-first-group.cjs's.
const EXPECTED_ROWS = {
	configuration_menu: [1, 1],
	gestures_menu: [1, 1],
	hotstrings_menu: [1, 1],
	layout_menu: [1, 1],
	llm_menu: [1, 0],
	metrics_menu: [1, 0],
	script_control_group: [1, 1],
	shortcuts_menu: [1, 1],
	tap_holds_menu: [1, 1],
	word_expanders_menu: [1, 0],
	wrap_symbols_global_controls: [1, 0]
};

const RETIRED_KEYS = [
	'menu.global.reset_defaults',
	'menu.gestures.restore_defaults',
	'menu.gestures.disable_all',
	'tap_hold.reset_defaults',
	'tap_hold.disable_all'
];

// Wrapping-symbol restore callbacks must reach their shared declaration.
const WRAP_RESET_CONSUMERS = [
	'macos/ui/menu/menu_shortcuts.lua',
	'windows/ui/menu/menu_shortcuts.ahk'
];

const errors = [];

// ==================================================
// ==================================================
// ======= 1/ The manifest ==========================
// ==================================================
// ==================================================

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
let checkedRows = 0;
for (const [menu, value] of Object.entries(manifest)) {
	if (!Array.isArray(value)) continue;
	let restores = 0;
	let clears = 0;
	for (const row of value) {
		if (!row || typeof row !== 'object' || typeof row.id !== 'string') continue;
		if (row.type !== 'command') continue;
		if (RESTORE_IDS.has(row.id)) {
			restores += 1;
			checkedRows += 1;
			if (row.i18n !== RESTORE_KEY) {
				errors.push(
					`${menu}.${row.id} restores a preset but reads "${row.i18n}", not ${RESTORE_KEY}.`
				);
			}
		} else if (CLEAR_IDS.has(row.id)) {
			clears += 1;
			checkedRows += 1;
			if (row.i18n !== CLEAR_KEY) {
				errors.push(
					`${menu}.${row.id} clears to system behaviour but reads "${row.i18n}", not ${CLEAR_KEY}.`
				);
			}
		}
	}
	const expected = EXPECTED_ROWS[menu];
	if (expected && (restores !== expected[0] || clears !== expected[1])) {
		errors.push(
			`${menu} declares ${restores} restore and ${clears} clear row(s), expected ${expected[0]} and ${expected[1]}.`
		);
	}
}
for (const menu of Object.keys(EXPECTED_ROWS)) {
	if (!Array.isArray(manifest[menu]))
		errors.push(`the manifest has no ${menu} — the row scan read nothing there.`);
}

// ==================================================
// ==================================================
// ======= 2/ The locales ===========================
// ==================================================
// ==================================================

const localeFiles = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
if (localeFiles.length !== 21)
	errors.push(`read ${localeFiles.length} locale file(s), expected 21.`);
for (const file of localeFiles) {
	const table = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	const loc = file.replace(/\.json$/, '');
	for (const key of [RESTORE_KEY, CLEAR_KEY]) {
		if (typeof table[key] !== 'string' || table[key] === '') {
			errors.push(`${file} has no value for ${key}.`);
		} else if (APPROVED[key][loc] !== undefined && table[key] !== APPROVED[key][loc]) {
			errors.push(`${file} reads "${table[key]}" for ${key}, approved: "${APPROVED[key][loc]}".`);
		}
	}
	for (const key of RETIRED_KEYS) {
		if (table[key] !== undefined) errors.push(`${file} still carries the retired key "${key}".`);
	}
}

// ==================================================
// ==================================================
// ======= 3/ The sources ===========================
// ==================================================
// ==================================================

for (const rel of WRAP_RESET_CONSUMERS) {
	const text = fs.readFileSync(path.join(SP, rel), 'utf8');
	const extension = path.extname(rel);
	if (
		!publishesMenuTemplate(text, extension, 'wrap_symbols_global_controls') ||
		!scriptTokens(text, extension).some(
			(token) => token.kind === 'string' && token.value === 'wrap_symbols_restore'
		)
	) {
		errors.push(
			`${rel} does not dispatch its restore through the shared wrapping-symbol declaration.`
		);
	}
}

// Every migrated native consumer must still delegate its actual restore callback
// to the declaration checked above; removing a native label must not remove coverage.
for (const rel of [
	'macos/ui/menu/menu_hotstrings_management.lua',
	'windows/ui/menu/menu_hotstrings.ahk',
	'linux/ui/menu/menu_builder.lua'
]) {
	const text = fs.readFileSync(path.join(SP, rel), 'utf8');
	for (const owner of ['word_expanders_menu', 'word_expanders_restore', 'word_expander_entries']) {
		if (!text.includes(`"${owner}"`)) {
			errors.push(`${rel} does not delegate its word-delimiter restore through ${owner}.`);
		}
	}
}

// Every source and data file of the driver tree, tests included, so a stale
// test fixture cannot keep a retired key alive. The *.tsv files are gitignored
// parse caches of the locales and are regenerated by the drivers.
const SOURCE_EXT = new Set(['.lua', '.ahk', '.js', '.cjs', '.html', '.toml', '.json']);
let scanned = 0;
(function walk(dir) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (!['node_modules', 'vendor'].includes(entry.name) && full !== LOCALES) walk(full);
		} else if (SOURCE_EXT.has(path.extname(entry.name))) {
			scanned += 1;
			const text = fs.readFileSync(full, 'utf8');
			const rel = path.relative(SP, full).split(path.sep).join('/');
			for (const key of RETIRED_KEYS) {
				if (text.includes(key)) errors.push(`${rel} still names the retired key "${key}".`);
			}
		}
	}
})(SP);
if (scanned < 500)
	errors.push(`scanned only ${scanned} source file(s) — the source scan is broken.`);

// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (checkedRows < 5)
	errors.push(`checked ${checkedRows} restore/clear row(s), expected at least 5.`);

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Restore / clear rows do not share their two labels:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${checkedRows} restore/clear row(s), ${localeFiles.length} locales and ${scanned} source ` +
		'files use the two shared labels.\x1b[0m'
);
