// tools/test/test-linux-version-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Linux Version Single-Source Guard
 * DESCRIPTION:
 * The Linux driver version has exactly one owner, linux/infra/version.lua
 * (M.VERSION), which resolves the `version=` entry a release build stamps into
 * the shared tree — the counterpart to the macOS/Windows BUNDLE_VERSION stamp.
 * Every surface that shows a version reads it from there.
 *
 * ROOT CAUSE ENCODED:
 * The version "3.0.0" was hardcoded in three places (tray menu header,
 * healthcheck snapshot, daemon build context), so a release bump had to touch all
 * three and would silently drift if one was missed. One of them also fell back to
 * Lua's built-in _VERSION (the interpreter version, "Lua 5.4") instead of the
 * driver version. This guard fails if a consumer re-types the version literal or
 * stops reading the single source.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LINUX = path.join(ROOT, 'static/ergopti_plus/linux');

function read(rel) {
	return fs.readFileSync(path.join(LINUX, rel), 'utf8');
}

// Strip Lua line comments so an explanatory comment mentioning a version string
// is never mistaken for a live literal.
function stripLua(src) {
	return src
		.split(/\r?\n/)
		.map((line) => line.replace(/--.*$/, ''))
		.join('\n');
}

const errors = [];

// ── Single owner: version.lua resolves the release build stamp ────────────
// A literal here is what shipped "3.0.0" to every install while the releases
// were 0.0.0-dev.N: no build rewrote it. The version now comes from the
// `version=` entry tools/build/write_build_stamp.sh writes in release builds.
const versionSrc = stripLua(read('infra/version.lua'));
if (/M\.VERSION\s*=\s*"/.test(versionSrc)) {
	errors.push('infra/version.lua: M.VERSION must be resolved from the build stamp, not typed as a literal');
}
if (!/Snapshot\.build_version\(/.test(versionSrc) || !/M\.VERSION\s*,\s*M\.SOURCE\s*=\s*M\.resolve\(\)/.test(versionSrc)) {
	errors.push('infra/version.lua: must resolve M.VERSION through Snapshot.build_version (the build stamp)');
}
// The updater validates a staged release against the same stamp entry.
const installerSrc = stripLua(read('modules/updater/installer.lua'));
if (!/Snapshot\.parse_build_version\(/.test(installerSrc) || /M%\.VERSION/.test(installerSrc)) {
	errors.push('modules/updater/installer.lua: must read the staged version from the build stamp');
}

// ── Consumers must read Version.VERSION, never re-type the literal ────────
const CONSUMERS = [
	'ui/menu/menu_builder.lua',
	'ui/healthcheck/bridge.lua',
	'ui/changelog/bridge.lua',
	'ui/paths_editor/bridge.lua',
	'ergopti_hotstrings.lua'
];
for (const rel of CONSUMERS) {
	const raw = read(rel);
	const code = stripLua(raw);
	if (!raw.includes('require("infra.version")')) {
		errors.push(`${rel}: must require("infra.version") for the driver version`);
	}
	if (!code.includes('Version.VERSION')) {
		errors.push(`${rel}: must read the version from Version.VERSION`);
	}
	const literal = code.match(/["']\d+\.\d+\.\d+["']/);
	if (literal) {
		errors.push(`${rel}: typed version literal ${literal[0]} — read Version.VERSION instead`);
	}
	if (/\b_VERSION\b/.test(code)) {
		errors.push(`${rel}: uses Lua's built-in _VERSION (interpreter version) — use Version.VERSION`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Linux driver version is not single-sourced from infra/version.lua:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Linux version single-sourced — infra/version.lua (build stamp) read by ${CONSUMERS.length} consumers; no re-typed literals.\x1b[0m`
);
