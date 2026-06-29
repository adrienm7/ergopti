// tools/test/test-no-pinned-source-reads-lua.cjs

/**
 * ==============================================================================
 * MODULE: Location-Pinned Source-Read Ratchet (macOS Lua tests)
 * DESCRIPTION:
 * macOS twin of test-no-pinned-source-reads.cjs (the AHK ratchet). Freezes the
 * count of macOS test_*.lua files that read a driver SOURCE file by a hardcoded
 * path — io.open(driver_root() .. "modules/keymap/input_sources.lua") and the
 * like — instead of loading the module and asserting behaviour, or scanning via
 * a move-resilient whole-tree helper. These path-pinned introspection tests are
 * the macOS half of the #1 refactor pain (far more numerous than the 19 on AHK):
 * a `git mv` of the cited file breaks them with a path error, never a behaviour
 * signal, so they discourage the structural splits the project wants.
 *
 * ROOT CAUSE ENCODED:
 * A test that concatenates driver_root() with a quoted "(modules|lib|ui)/….lua"
 * path is location-pinned. This ratchet counts them and FAILS if the count rises
 * above the frozen baseline. Lower (never raise) the baseline as tests migrate
 * to behaviour assertions or a move-resilient symbol-keyed scan (REFACTOR_GUIDE
 * P9.2/P9.4). It is the test twin of the OS-purity ratchets and of the AHK
 * pinned-read ratchet.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const TESTS_DIR = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'tests');

// Frozen baseline — the current count of path-pinned source-reading macOS test
// files. Drive toward zero by migrating each to a behaviour assertion or a
// move-resilient helper; NEVER raise it to make a new test pass.
const BASELINE = 133;

// A move-resilient scan helper (symbol-keyed whole-tree read). None exists yet;
// listed so that converting a test to such a helper drops it from the count.
const HELPER_RE = /read_driver_source|source_concat|list_lua_files\(/;
// driver_root() concatenated with a quoted relative path into a driver SOURCE
// tree ending in .lua, e.g. driver_root() .. "modules/keymap/input_sources.lua".
const SOURCE_PATH_RE = /driver_root\(\)\s*\.\.\s*["'][^"'\n]*(?:modules|lib|ui)[\\/][^"'\n]*\.lua["']/;

/**
 * Recursively collects every test_*.lua file under a directory.
 * @param {string} dir - Absolute directory to walk.
 * @param {string[]} acc - Accumulator for matched absolute file paths.
 * @returns {string[]} The accumulator, populated with absolute paths.
 */
function collectTests(dir, acc) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			collectTests(full, acc);
		} else if (entry.isFile() && /^test_.*\.lua$/.test(entry.name)) {
			acc.push(full);
		}
	}
	return acc;
}

const pinned = [];
for (const file of collectTests(TESTS_DIR, [])) {
	const src = fs.readFileSync(file, 'utf8');
	if (HELPER_RE.test(src)) continue; // already move-resilient
	if (!SOURCE_PATH_RE.test(src)) continue; // reads a fixture, not a source file
	pinned.push(path.relative(ROOT, file).replace(/\\/g, '/'));
}

const count = pinned.length;
if (process.argv.includes('--measure')) {
	console.log(`path-pinned macOS source-reading test files: ${count}`);
	for (const f of pinned) console.log('  ' + f);
	process.exit(0);
}

if (count > BASELINE) {
	console.error(
		`\x1b[31m[ERROR] Path-pinned source reads in macOS tests rose to ${count} (baseline ${BASELINE}).\x1b[0m`
	);
	console.error(
		'  A new test reads a driver source file by a hardcoded driver_root() path. Load the\n' +
		'  module and assert behaviour, or use a move-resilient symbol-keyed scan, so a file\n' +
		'  move does not break it. Do NOT raise the baseline.'
	);
	console.error('  Run `node tools/test/test-no-pinned-source-reads-lua.cjs --measure` to list them.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No new path-pinned macOS source reads (${count}/${BASELINE} baseline).\x1b[0m`
);
