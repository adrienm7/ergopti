// tools/test/test-secure-apps-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Secure Applications Single-Source Guard
 * DESCRIPTION:
 * A password manager is a secure field as a whole on every driver (ADD-1,
 * decided by the maintainer on 2026-11-11), from one list:
 * _shared/data/secure_apps.json. macOS, Linux and Windows each kept their own
 * list and the three had drifted apart.
 *
 * WHAT THIS PINS:
 *   1. The list is well formed: unique ids, a windows, macos and linux list
 *      on every row, lowercase Linux fragments, no empty identity.
 *   2. Neither Lua driver declares a list of its own: the detectors and the
 *      Linux metrics read the shared file through _shared/apps/engine/secure_apps.lua,
 *      over its generated projection secure_apps_data.lua, which matches it.
 *   3. Windows keeps no typed list: its secure-field detector reads the
 *      `windows` names of the shared file at run time.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const read = (rel) => fs.readFileSync(path.join(SP, rel), 'utf8');

const errors = [];
const document = JSON.parse(read('_shared/data/secure_apps.json'));

// 1. The list itself.
const ids = new Set();
const windowsNames = new Set();
if (!Array.isArray(document.apps) || document.apps.length === 0)
	errors.push('secure_apps.json declares no application');
for (const app of document.apps || []) {
	if (typeof app.id !== 'string' || !app.id || ids.has(app.id))
		errors.push(`secure_apps.json: missing or duplicate id ${app.id}`);
	ids.add(app.id);
	for (const platform of ['windows', 'macos', 'linux']) {
		if (!Array.isArray(app[platform])) {
			errors.push(`secure_apps.json: ${app.id} lacks its ${platform} list`);
			continue;
		}
		for (const identity of app[platform]) {
			if (typeof identity !== 'string' || !identity)
				errors.push(`secure_apps.json: ${app.id} holds an empty ${platform} identity`);
			else if (platform === 'linux' && identity !== identity.toLowerCase())
				errors.push(`secure_apps.json: Linux fragment ${identity} is not lowercase`);
			else if (platform === 'windows') windowsNames.add(identity.toLowerCase());
		}
	}
}

// 2. No local list in a Lua driver. A secure-app table is a Lua table literal
// keyed by a password manager's name next to `= true`, or a flat list of them.
const LUA_SOURCES = [
	'macos/platform/focus/secure_field_detector.lua',
	'linux/platform/focus/secure_field_detector.lua',
	'linux/modules/keystats/keystats.lua'
];
const LOCAL_LIST =
	/\[\s*"(?:1password|bitwarden|keepassxc|lastpass|dashlane)"\s*\]\s*=|^\s*"(?:1password|bitwarden|keepass|lastpass)"\s*,/im;
for (const rel of LUA_SOURCES) {
	const source = read(rel);
	if (LOCAL_LIST.test(source)) errors.push(`${rel} declares its own secure-app list`);
	if (!/secure_apps/.test(source)) errors.push(`${rel} does not read the shared secure-app list`);
}

const projected = read('_shared/apps/engine/secure_apps_data.lua');
for (const app of document.apps || [])
	for (const platform of ['windows', 'macos', 'linux'])
		for (const identity of app[platform] || [])
			if (!projected.includes(JSON.stringify(identity)))
				errors.push(
					`secure_apps_data.lua lacks ${platform} ${identity}: run node tools/codegen/codegen-secure-apps.cjs`
				);

// 3. Windows reads the file (ADD-1): no typed list is left in its detector.
const ahk = read('windows/platform/focus/secure_field_detector.ahk');
if (/global SFD_SECURE_APPS := Map\(/.test(ahk) || /"[^"]+\.exe",\s*true/.test(ahk))
	errors.push(
		'windows/platform/focus/secure_field_detector.ahk keeps a typed secure application list'
	);
if (!ahk.includes('\\data\\secure_apps.json'))
	errors.push(
		'windows/platform/focus/secure_field_detector.ahk does not read _shared/data/secure_apps.json'
	);

if (errors.length) {
	console.error(
		'\x1b[31m[ERROR] secure applications drifted from _shared/data/secure_apps.json:\x1b[0m'
	);
	for (const error of errors) console.error(`    - ${error}`);
	process.exit(1);
}
console.log(
	`PASS: ${ids.size} secure applications in one shared list, read by macOS, Linux and Windows.`
);
