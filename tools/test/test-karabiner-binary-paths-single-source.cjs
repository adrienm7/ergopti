// tools/test/test-karabiner-binary-paths-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Karabiner Binary Paths Are Declared Once
 * DESCRIPTION:
 * The absolute path of every Karabiner-Elements binary the macOS driver shells
 * out to lives in platform/remap/ke_paths.lua, and nowhere else.
 *
 * WHY THIS IS NOT A STYLE RULE:
 * `karabiner_cli` was written out as a literal in three separate files —
 * ke_lifecycle.lua (the IPC probe), onboarding.lua (the "is it installed?"
 * check) and watchers.lua (the CapsWord reset) — and the gesture bridge was
 * about to make it four. Karabiner v16 (May 2026) already renamed one binary in
 * that same directory once. A rename that reaches two copies out of four gives a
 * driver that reports Karabiner as installed, passes its onboarding, and then
 * cannot set a single variable: three subsystems disagreeing about whether the
 * software exists, each of them individually correct.
 *
 * WHAT COUNTS AS A VIOLATION:
 * any occurrence of the install directory outside ke_paths.lua. The check is
 * deliberately on the DIRECTORY rather than on each binary name, because the
 * next binary someone reaches for will be one this file has never heard of, and
 * the failure mode is identical.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const OWNER = path.join(MACOS, 'platform', 'remap', 'ke_paths.lua');

// The PKG install directory. Every Karabiner binary lives under it, so a literal
// containing it is a hardcoded path by definition.
const INSTALL_DIR = '/Library/Application Support/org.pqrs/Karabiner-Elements/bin/';

// The names ke_paths.lua must expose. A binary the driver uses but the module
// does not name is how the fourth copy gets written.
const REQUIRED_EXPORTS = ['CLI', 'CONSOLE_USER_SERVER', 'GRABBER', 'GRABBER_V16'];

// Trees excluded from the scan. Tests may name the path when asserting against
// it, and vendored code is not ours to change.
const SKIP_DIRS = new Set(['tests', 'vendor', 'node_modules', '.venv', '_generated']);

const errors = [];

if (!fs.existsSync(OWNER)) {
	console.error(`\x1b[31m[FAIL] ${path.relative(ROOT, OWNER)} does not exist — nothing owns these paths.\x1b[0m`);
	process.exit(1);
}

const ownerSrc = fs.readFileSync(OWNER, 'utf8');
if (!ownerSrc.includes(INSTALL_DIR)) {
	errors.push(
		`ke_paths.lua no longer contains the install directory "${INSTALL_DIR}". Either the path ` +
			'changed and this gate is stale, or the module stopped being the source of truth.'
	);
}
for (const name of REQUIRED_EXPORTS) {
	if (!new RegExp(`\\bM\\.${name}\\s*=`).test(ownerSrc)) {
		errors.push(
			`ke_paths.lua exports no M.${name}. A binary the driver uses but this module does not name ` +
				'is exactly how the next hardcoded copy gets written.'
		);
	}
}

/** Every .lua file under the macOS driver, minus the excluded trees. */
function luaFiles(dir, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.isDirectory()) {
			if (!SKIP_DIRS.has(entry.name)) luaFiles(path.join(dir, entry.name), out);
		} else if (entry.name.endsWith('.lua')) {
			out.push(path.join(dir, entry.name));
		}
	}
	return out;
}

const files = luaFiles(MACOS);

// Floor: a walk that resolves to nothing would report no duplicates forever.
if (files.length < 100) {
	errors.push(`the driver walk found ${files.length} .lua file(s) — it is broken, not the tree`);
}

const offenders = [];
for (const file of files) {
	if (path.resolve(file) === path.resolve(OWNER)) continue;
	const src = fs.readFileSync(file, 'utf8');
	if (!src.includes(INSTALL_DIR)) continue;
	const lines = src.split(/\r?\n/);
	for (let i = 0; i < lines.length; i++) {
		if (lines[i].includes(INSTALL_DIR)) {
			offenders.push(`${path.relative(ROOT, file).split(path.sep).join('/')}:${i + 1}`);
		}
	}
}

if (offenders.length > 0) {
	errors.push(
		`${offenders.length} hardcoded Karabiner path(s) outside ke_paths.lua:\n      ` +
			offenders.join('\n      ') +
			'\n    Require platform.remap.ke_paths instead. Karabiner has renamed a binary in this ' +
			'directory once already, and a rename that reaches some copies but not others produces a ' +
			'driver that believes Karabiner is installed and cannot talk to it.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Karabiner binary paths:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] the ${REQUIRED_EXPORTS.length} Karabiner binary path(s) are declared once, in ` +
		`ke_paths.lua; ${files.length} driver file(s) scanned, none hardcodes the install directory.\x1b[0m`
);
