// tools/test/test-menu-titles-single-key.cjs

/**
 * ==============================================================================
 * MODULE: One Menu, One Label Key
 * DESCRIPTION:
 * The top-level tray entries exist on more than one driver, and each of them
 * must read the SAME translation key on every driver that has it.
 *
 * WHAT THIS CAUGHT (2026-08-07):
 *   - four of them existed TWICE in all twenty-one locale files. Windows read
 *     `category.gestures`, `category.shortcuts`, `category.tapholds`; macOS and
 *     Linux read `menu.gestures.title`, `menu.shortcuts.title`,
 *     `menu.tapholds.title`. The strings happened to be identical, so nothing
 *     looked wrong — until a translator edits one of the two.
 *     `category.layout` was a fifth copy that no driver read at all.
 *   - macOS spelled the Hotstrings entry out in its source: "⚡ Hotstrings (N)".
 *     `menu.hotstrings.title` is translated in every locale — « ⚡ ホットストリング »
 *     in Japanese — so that one top-level entry stayed untranslated on that
 *     driver while the other two translated it.
 *
 * WHY A GATE AND NOT A CONVENTION:
 * neither failure is visible from inside one driver. Each is only a divergence
 * when the three are read side by side, which is exactly what nobody does.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

// Each top-level entry, the key every driver must read for it, and which drivers
// actually have the entry. A driver that does not have the menu is not required
// to name its key — but one that HAS it may not invent a second.
const TITLES = [
	{ key: 'menu.layout.title', on: ['windows', 'macos', 'linux'] },
	{ key: 'menu.hotstrings.title', on: ['windows', 'macos', 'linux'] },
	{ key: 'menu.shortcuts.title', on: ['windows', 'macos', 'linux'] },
	// Windows only at top level: Linux keeps its tap-holds inside the kanata
	// submenu (`kanata_tap_holds`) and macOS inside Karabiner, which is what the
	// manifest's platforms list says for the top-level row.
	{ key: 'menu.tapholds.title', on: ['windows'] },
	{ key: 'menu.gestures.title', on: ['windows', 'macos', 'linux'] },
	{ key: 'menu.metrics.title', on: ['windows', 'macos', 'linux'] },
	{ key: 'menu.llm.title', on: ['windows', 'macos', 'linux'] },
	{ key: 'menu.debug.title', on: ['windows', 'macos', 'linux'] },
];

const EXT = { windows: '.ahk', macos: '.lua', linux: '.lua' };

/** Every production source file of one driver, concatenated. */
function driverSource(driver) {
	const out = [];
	(function walk(dir) {
		if (!fs.existsSync(dir)) return;
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (!['tests', 'vendor', 'node_modules', '_generated'].includes(e.name)) walk(p);
			} else if (p.endsWith(EXT[driver])) {
				out.push(fs.readFileSync(p, 'utf8'));
			}
		}
	})(path.join(SP, driver));
	return out.join('\n');
}

const sources = Object.fromEntries(['windows', 'macos', 'linux'].map((d) => [d, driverSource(d)]));

// The manifest names keys on the drivers' behalf: a row declared there is
// rendered from the declaration, so the driver never spells the key out.
const manifest = fs.readFileSync(path.join(SP, '_shared', 'modules', 'features', 'manifest.toml'), 'utf8');
const menuManifest = fs.readFileSync(path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json'), 'utf8');

const errors = [];

for (const { key, on } of TITLES) {
	for (const driver of on) {
		const named = sources[driver].includes(key) || manifest.includes(key) || menuManifest.includes(key);
		if (!named) {
			errors.push(
				`${driver} has the "${key}" menu and names no key for it. Either it reads a SECOND key ` +
					'for the same row — two copies of one label, one translator away from two different ' +
					'menus — or it spells the label out, which leaves that entry untranslated on this ' +
					'driver alone.'
			);
		}
	}
}

// The second half: no locale may still carry a key that duplicates one of these.
// A duplicate is not detectable from a driver, only from the catalogue.
const fr = JSON.parse(fs.readFileSync(path.join(LOCALES, 'fr.json'), 'utf8'));
const canonical = new Map();
for (const { key } of TITLES) {
	if (typeof fr[key] === 'string') canonical.set(fr[key], key);
}
for (const [key, value] of Object.entries(fr)) {
	if (typeof value !== 'string') continue;
	if (!canonical.has(value)) continue;
	// Only inside the MENU's own namespaces. A window title or a dialog heading
	// legitimately repeats the wording of the entry that opens it — that is one
	// string used in two places, not one row named twice.
	if (!/^(menu|category)\./.test(key)) continue;
	const owner = canonical.get(value);
	if (key === owner) continue;
	errors.push(
		`"${key}" holds the same string as "${owner}" ("${value}"). One menu row, one key: a second ` +
			'copy is maintained in twenty-one files and read by a different driver than the first.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] a menu row is named by more than one key, or by none:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${TITLES.length} top-level menu title(s) each read from a single shared key on every ` +
		'driver that has them.\x1b[0m'
);
