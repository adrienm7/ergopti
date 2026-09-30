// tools/test/test-shortcuts-wrap-group.cjs

/**
 * ==============================================================================
 * MODULE: The Wrap Toggle and Its Symbols Form One Group, Named Without AltGr
 * DESCRIPTION:
 * The maintainer's request of 2026-09-30, from the macOS Shortcuts menu: no
 * separator between « AltGr + symbole encadre la sélection » and « Symboles
 * encadrants », which go together, and the toggle renamed « Taper un symbole
 * encadre la sélection », because the symbols are on AltGr only in Ergopti,
 * not in other layouts.
 *
 * WHAT THIS HOLDS:
 *   1. In every platform's projection of shortcuts_menu, the wrap toggle row is
 *      followed directly by the wrap-symbols row. (Each driver's suite renders
 *      its menu: macOS draws both from the symbols provider.)
 *   2. Neither the toggle's label nor the trigger the setup wizard shows for it
 *      names AltGr, in any of the 21 locales.
 *   3. The retired `menu.shortcuts.altgr_symbol` key is gone from the locales
 *      and from every source, generated catalogues included.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

const WRAP_PATH = 'shortcuts.wrap_text_if_selected';
const LABEL_KEYS = ['shortcuts.label_wrap_text', 'menu.shortcuts.selection_symbol'];
const RETIRED_KEY = 'menu.shortcuts.altgr_symbol';
const PLATFORMS = ['ahk', 'hs', 'linux'];

const errors = [];

// 1/ The manifest projection.
const rows = JSON.parse(fs.readFileSync(MANIFEST, 'utf8')).shortcuts_menu || [];
for (const platform of PLATFORMS) {
	const shown = rows.filter(
		(row) =>
			row &&
			(row.platforms === undefined ||
				(Array.isArray(row.platforms) && row.platforms.includes(platform)))
	);
	const at = shown.findIndex((row) => row.type === 'feature' && row.path === WRAP_PATH);
	if (at < 0) {
		errors.push(`shortcuts_menu (${platform}) no longer declares the wrap toggle ${WRAP_PATH}.`);
	} else if (!shown[at + 1] || shown[at + 1].id !== 'wrap_symbols_menu') {
		const next = shown[at + 1] ? shown[at + 1].id || shown[at + 1].type : 'nothing';
		errors.push(
			`shortcuts_menu (${platform}): the wrap toggle is followed by "${next}", not its symbols.`
		);
	}
}

// 2/ The labels, in every locale.
const localeFiles = fs.readdirSync(LOCALES).filter((file) => file.endsWith('.json'));
if (localeFiles.length !== 21)
	errors.push(`read ${localeFiles.length} locale file(s), expected 21.`);
for (const file of localeFiles) {
	const table = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	for (const key of LABEL_KEYS) {
		if (typeof table[key] !== 'string' || table[key] === '') errors.push(`${file} has no ${key}.`);
		else if (/altgr/i.test(table[key])) errors.push(`${file}: ${key} still names AltGr.`);
	}
	if (table[RETIRED_KEY] !== undefined) errors.push(`${file} still carries ${RETIRED_KEY}.`);
}

// 3/ Every source, generated catalogues included.
const EXT = new Set(['.lua', '.ahk', '.js', '.cjs', '.toml', '.json', '.html']);
let scanned = 0;
(function walk(dir) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (!['node_modules', 'vendor'].includes(entry.name) && full !== LOCALES) walk(full);
		} else if (EXT.has(path.extname(entry.name))) {
			scanned += 1;
			if (fs.readFileSync(full, 'utf8').includes(RETIRED_KEY))
				errors.push(`${path.relative(SP, full)} still names ${RETIRED_KEY}.`);
		}
	}
})(SP);
if (scanned < 500) errors.push(`scanned only ${scanned} file(s) — the source scan is broken.`);

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] The wrap toggle and its symbols must form one AltGr-free group:\x1b[0m'
	);
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] the wrap toggle and its symbols form one group on ${PLATFORMS.length} platforms, ` +
		`named without AltGr in ${localeFiles.length} locales; ${RETIRED_KEY} is gone from ${scanned} files.\x1b[0m`
);
