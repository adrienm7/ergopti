// tools/test/test-linux-version-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Linux Version Single-Source Guard
 * DESCRIPTION:
 * The Linux driver version lives exactly once, in linux/infra/version.lua
 * (M.VERSION) — the counterpart to the macOS/Windows BUNDLE_VERSION stamp. Every
 * surface that shows a version reads it from there.
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

// ── Single source: version.lua must define M.VERSION as a version string ──
const versionSrc = read('infra/version.lua');
const m = versionSrc.match(/M\.VERSION\s*=\s*"(\d+\.\d+\.\d+)"/);
if (!m) {
	errors.push('infra/version.lua: must define M.VERSION = "<x.y.z>" (the single source)');
}
const VERSION = m ? m[1] : null;

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
	if (VERSION && new RegExp(`"${VERSION.replace(/\./g, '\\.')}"`).test(code)) {
		errors.push(`${rel}: re-typed version literal "${VERSION}" — read Version.VERSION instead`);
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
	`\x1b[32m[OK] Linux version single-sourced — infra/version.lua (${VERSION}) read by ${CONSUMERS.length} consumers; no re-typed literals.\x1b[0m`
);
