// tools/test/test-git-mv-resilience.cjs

/**
 * ==============================================================================
 * MODULE: Git-Move Resilience Check (P9.2)
 * DESCRIPTION:
 * Proves that the existing path-pinned macOS test reads are not stale: every
 * hardcoded driver_root() .. "…/some.lua" path actually points to a file that
 * still exists on disk. If a source file is renamed or moved without updating
 * the test that pins it, this check fails immediately with an actionable list
 * of stale pins.
 *
 * RELATIONSHIP TO THE RATCHET (P9.1):
 * test-no-pinned-source-reads-lua.cjs (P9.1) is a MONOTONE gate — it prevents
 * the count of path-pinned tests from rising above the frozen baseline. This
 * check (P9.2) is the VALIDITY gate — it prevents existing pins from silently
 * decaying after a git mv / git rm. Together they guarantee:
 *   1. No new location-pinned tests are added (P9.1).
 *   2. Existing location-pinned tests always point to real files (P9.2).
 *
 * ROOT CAUSE ENCODED:
 * A path-pinned test opens a file it does not own. When that file moves, the
 * test throws a Lua I/O error — "no such file", not "behaviour X regressed" —
 * hiding the real cause. This check surfaces the breakage at commit time, not
 * at test-run time on a developer's machine.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const TESTS_DIR = path.join(DRIVER_ROOT, 'tests');

// Same pattern as P9.1 — detects driver_root() .. "modules|lib|ui/….lua".
const SOURCE_PATH_RE = /driver_root\(\)\s*\.\.\s*["']([^"'\n]*(?:modules|lib|ui)[\\/][^"'\n]*\.lua)["']/g;

// Move-resilient helper pattern — if a test uses one of these, it is not pinned.
const HELPER_RE = /read_driver_source|source_concat|list_lua_files\(/;

/**
 * Recursively collects every test_*.lua file under a directory.
 * @param {string} dir
 * @param {string[]} acc
 * @returns {string[]}
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

/**
 * Extracts all pinned source paths from a test file's source text.
 * @param {string} src - Full content of the test file.
 * @returns {string[]} Relative paths as written in the test (slash-normalised).
 */
function extractPins(src) {
	const pins = [];
	let m;
	// Reset lastIndex because the regex is stateful (global flag).
	SOURCE_PATH_RE.lastIndex = 0;
	while ((m = SOURCE_PATH_RE.exec(src)) !== null) {
		pins.push(m[1].replace(/\\/g, '/'));
	}
	return pins;
}

const stale = [];
const pinnedFiles = [];

for (const testFile of collectTests(TESTS_DIR, [])) {
	const src = fs.readFileSync(testFile, 'utf8');
	if (HELPER_RE.test(src)) continue;
	const pins = extractPins(src);
	if (pins.length === 0) continue;

	const relTest = path.relative(ROOT, testFile).replace(/\\/g, '/');
	pinnedFiles.push(relTest);

	for (const pinned of pins) {
		// Resolve against the macOS driver root (same as driver_root() at runtime).
		const resolved = path.join(DRIVER_ROOT, pinned.replace(/\//g, path.sep));
		if (!fs.existsSync(resolved)) {
			stale.push({ test: relTest, pin: pinned, resolved });
		}
	}
}

if (process.argv.includes('--measure')) {
	console.log(`path-pinned macOS test files: ${pinnedFiles.length}`);
	console.log(`stale pins (file no longer exists): ${stale.length}`);
	if (stale.length > 0) {
		for (const s of stale) {
			console.log(`  STALE  ${s.pin}  (from ${s.test})`);
		}
	}
	process.exit(0);
}

if (stale.length > 0) {
	console.error(
		`\x1b[31m[ERROR] ${stale.length} path-pinned macOS test read(s) are stale — the pinned source file no longer exists.\x1b[0m`
	);
	console.error(
		'  A test reads a driver source file by a hardcoded driver_root() path that no longer\n' +
		"  resolves. Either the source file was moved without updating the test's io.open() call,\n" +
		'  or the test was added for a file that was already absent. Fix: update or remove the\n' +
		'  stale io.open() path, or convert the test to a behaviour assertion that does not pin\n' +
		'  a file path.'
	);
	console.error('  Stale pins:');
	for (const s of stale) {
		console.error(`    ${s.pin}  ←  ${s.test}`);
	}
	console.error(
		'\n  Run `node tools/test/test-git-mv-resilience.cjs --measure` for the full inventory.'
	);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] All ${pinnedFiles.length} path-pinned macOS test file(s) point to existing source files (P9.2).\x1b[0m`
);
