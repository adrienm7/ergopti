// tools/test/test-menu-manifest-keys-have-readers.cjs

/**
 * ==============================================================================
 * MODULE: Menu Manifest Reader Guard
 * DESCRIPTION:
 * Every top-level key in _shared/modules/menu/menu_manifest.json must be read by
 * at least one driver. A key nobody reads is not neutral: it looks authoritative,
 * so the next person to change the menu edits it and nothing happens.
 *
 * ROOT CAUSE ENCODED:
 * Two such keys existed. `dynamic_hotstrings_order` duplicated
 * _DYNAMIC_HOTSTRINGS_ORDER in windows/ui/tray_menu.ahk — and DISAGREED with it,
 * spelling the separator "---" where the live one spells it "-". Whichever a
 * reader trusted, one of them was lying. `word_delimiter_defs` carried 20 entries
 * no driver ever asked for.
 *
 * WHY THE MATCH IS DELIBERATELY GENEROUS:
 * A first attempt at this check searched for `"key"` in quotes and reported five
 * dead keys. Three were false positives, and each shows a way a manifest key is
 * legitimately reached:
 *   - `root.gesture_slots` — Lua dot access, no quotes anywhere.
 *   - `modifier_combos_group` / `accented_letters_group` — dispatched BY VALUE,
 *     the id arriving from the manifest at runtime and never appearing as a
 *     literal in the code that handles it.
 * So a key counts as read if its name appears anywhere in production source, in
 * any form. That cannot prove the read is meaningful, but it does catch the case
 * this guard is for — a key no code mentions at all — without sending anyone to
 * delete a key that is very much alive.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');

/** Production source across the three drivers and the shared Lua tree. */
function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests' && e.name !== 'node_modules') walk(p, acc);
		} else if (/\.(lua|ahk|js|cjs)$/.test(e.name)) {
			acc.push(p);
		}
	}
	return acc;
}

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const keys = Object.keys(manifest).filter((k) => !k.startsWith('_'));

const files = [
	...walk(path.join(SP, 'windows')),
	...walk(path.join(SP, 'macos')),
	...walk(path.join(SP, 'linux')),
	...walk(path.join(SP, '_shared', 'lua')),
	...walk(path.join(SP, '_shared', 'ui')),
];
const corpus = files.map((f) => fs.readFileSync(f, 'utf8')).join('\n');

const errors = [];

if (keys.length < 10) {
	errors.push(`the manifest has only ${keys.length} top-level key(s) — it failed to parse, or the shape changed`);
}
if (files.length < 200) {
	errors.push(`walked only ${files.length} production file(s) — the scan is broken, and every key would look dead`);
}

for (const key of keys) {
	if (!corpus.includes(key)) {
		errors.push(
			`"${key}": no driver mentions this key anywhere. Either wire it up or remove it — a key ` +
				'nobody reads still looks authoritative, so the next person to change the menu edits ' +
				'it and nothing happens.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu_manifest.json holds keys no driver reads:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] All ${keys.length} menu-manifest key(s) are referenced by production code ` +
		`(${files.length} file(s) scanned).\x1b[0m`
);
