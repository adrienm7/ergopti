// tools/test/test-git-mv-resilience.cjs

/**
 * ==============================================================================
 * MODULE: Git-Move Resilience Check
 * DESCRIPTION:
 * Proves that the path-pinned reads in the three test suites are not stale:
 * every hardcoded driver-relative path a test opens still points at something
 * that exists on disk. If a source file or directory is renamed without updating
 * the test that pins it, this check fails immediately with an actionable list.
 *
 * WHAT IS PINNED, PER DRIVER:
 * - macOS  — `driver_root() .. "modules|lib|ui/….lua"` file pins.
 * - Linux  — `helpers.driver_root() .. "/…"` file and directory pins.
 * - Windows — `_DriverDirConcat("…")` DIRECTORY pins, plus driver-relative
 *   `.ahk` file paths written as string literals.
 *
 * ROOT CAUSE ENCODED:
 * A path-pinned test opens a file it does not own. When that file moves, the
 * test fails with "no such file", not "behaviour X regressed" — hiding the real
 * cause. Worse on Windows: `_DriverDirConcat` used to return "" for a missing
 * directory, so `InStr("", x)` was 0 and every "must NOT contain" assertion
 * built on it passed VACUOUSLY. The helper now throws, and this check is what
 * catches the same class at commit time rather than at test-run time.
 *
 * RELATIONSHIP TO THE NO-NEW-PINS RATCHETS:
 * test-no-pinned-source-reads*.cjs are MONOTONE gates — they stop the count of
 * path-pinned tests rising above the frozen baseline. This is the VALIDITY gate
 * — it stops existing pins decaying after a git mv. Together:
 *   1. No new location-pinned tests are added.
 *   2. Existing location-pinned tests always point at real files.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');

// Move-resilient macOS helpers — a test using one of these is not pinned.
const LUA_HELPER_RE = /read_driver_source|source_concat|list_lua_files\(/;

// macOS shape: driver_root() .. "modules|lib|ui/….lua".
const MACOS_PIN_RE = /driver_root\(\)\s*\.\.\s*["']([^"'\n]*(?:modules|lib|ui)[\\/][^"'\n]*\.lua)["']/g;

// Linux shape: helpers.driver_root() .. "/…" — any depth, files and directories,
// including the "/../_shared/…" escapes into the shared tree.
const LINUX_PIN_RE = /driver_root\(\)\s*\.\.\s*["']([^"'\n]+)["']/g;

// Windows directory pins — the argument is the one thing the helper hardcodes.
const AHK_DIR_PIN_RE = /_DriverDirConcat\(\s*["']([^"'\n]+)["']/g;

// Windows file pins — a driver-relative .ahk path written as a string literal.
const AHK_FILE_PIN_RE =
	/["']((?:lib|modules|ui|adapters|infra|platform|_generated|data)[\\/][A-Za-z0-9_\\/.-]+\.ahk)["']/g;

/**
 * Paths a test names precisely BECAUSE they must not exist. Each entry carries
 * the reason, so an exemption cannot be added silently.
 */
const INTENTIONALLY_ABSENT = new Map([
	[
		'lib/testing.ahk',
		'test_run_all_include_integrity.ahk asserts no test #Includes it — a historical typo that aborted the whole suite',
	],
]);

// ==================================================
// ==================================================
// ======= 1/ Collecting the test files =============
// ==================================================
// ==================================================

/**
 * Recursively collects every test file under a directory.
 * @param {string} dir Directory to walk.
 * @param {RegExp} nameRe Matches the basenames that count as tests.
 * @param {string[]} acc Accumulator.
 * @returns {string[]} Absolute paths.
 */
function collectTests(dir, nameRe, acc) {
	if (!fs.existsSync(dir)) return acc;
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) collectTests(full, nameRe, acc);
		else if (entry.isFile() && nameRe.test(entry.name)) acc.push(full);
	}
	return acc;
}

/**
 * Extracts every capture group 1 match, slash-normalised.
 * @param {string} src Test file content.
 * @param {RegExp} re Stateful global regex.
 * @returns {string[]} Pinned paths as written.
 */
function extract(src, re) {
	const pins = [];
	let m;
	re.lastIndex = 0;
	while ((m = re.exec(src)) !== null) pins.push(m[1].replace(/\\/g, '/'));
	return pins;
}

/**
 * True when the path resolves to a directory holding at least one .ahk file.
 * Mirrors what _DriverDirConcat itself now throws on: an existing but empty
 * directory concatenates to "" and disarms every assertion downstream just as
 * completely as a missing one.
 * @param {string} abs Absolute directory path.
 * @returns {boolean} Whether the directory carries AHK source.
 */
function holdsAhk(abs) {
	if (!fs.existsSync(abs) || !fs.statSync(abs).isDirectory()) return false;
	const stack = [abs];
	while (stack.length > 0) {
		const dir = stack.pop();
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			if (entry.isDirectory()) stack.push(path.join(dir, entry.name));
			else if (entry.name.endsWith('.ahk')) return true;
		}
	}
	return false;
}

// ==================================================
// ==================================================
// ======= 2/ The three drivers =====================
// ==================================================
// ==================================================

/**
 * Each target declares where its tests live, how a pin is written, and how a pin
 * is resolved. Adding a driver is adding an entry, never editing the walk.
 */
const TARGETS = [
	{
		name: 'macOS',
		root: path.join(DRIVERS, 'macos'),
		testRe: /^test_.*\.lua$/,
		skipRe: LUA_HELPER_RE,
		pins: (src) => extract(src, MACOS_PIN_RE).map((p) => ({ pin: p, kind: 'file' })),
	},
	{
		name: 'Linux',
		root: path.join(DRIVERS, 'linux'),
		testRe: /^test_.*\.lua$/,
		skipRe: LUA_HELPER_RE,
		// A pin with no extension is a directory (the "/../_shared" escapes).
		pins: (src) =>
			extract(src, LINUX_PIN_RE).map((p) => ({ pin: p, kind: /\.[A-Za-z0-9]+$/.test(p) ? 'file' : 'dir' })),
	},
	{
		name: 'Windows',
		root: path.join(DRIVERS, 'windows'),
		testRe: /^(?:test|bench|run)_.*\.ahk$/,
		skipRe: null,
		pins: (src) => [
			...extract(src, AHK_DIR_PIN_RE).map((p) => ({ pin: p, kind: 'ahk-dir' })),
			...extract(src, AHK_FILE_PIN_RE).map((p) => ({ pin: p, kind: 'file' })),
		],
	},
];

const stale = [];
const inventory = [];

for (const target of TARGETS) {
	const testsDir = path.join(target.root, 'tests');
	const pinnedFiles = new Set();
	let pinCount = 0;

	for (const testFile of collectTests(testsDir, target.testRe, [])) {
		const src = fs.readFileSync(testFile, 'utf8');
		if (target.skipRe && target.skipRe.test(src)) continue;
		const pins = target.pins(src);
		if (pins.length === 0) continue;

		const relTest = path.relative(ROOT, testFile).replace(/\\/g, '/');
		pinnedFiles.add(relTest);
		pinCount += pins.length;

		for (const { pin, kind } of pins) {
			if (INTENTIONALLY_ABSENT.has(pin)) continue;
			const abs = path.join(target.root, pin.replace(/\//g, path.sep));
			const ok = kind === 'ahk-dir' ? holdsAhk(abs) : fs.existsSync(abs);
			if (!ok) stale.push({ driver: target.name, test: relTest, pin, kind });
		}
	}

	inventory.push({ driver: target.name, files: pinnedFiles.size, pins: pinCount });
}

// ==================================
// ==================================
// ======= 3/ Report ================
// ==================================
// ==================================

if (process.argv.includes('--measure')) {
	for (const row of inventory) {
		console.log(`${row.driver}: ${row.files} path-pinned test file(s), ${row.pins} pin(s)`);
	}
	console.log(`stale pins (target no longer exists): ${stale.length}`);
	for (const s of stale) console.log(`  STALE  [${s.driver}] ${s.pin}  (from ${s.test})`);
	process.exit(0);
}

if (stale.length > 0) {
	console.error(
		`\x1b[31m[ERROR] ${stale.length} path-pinned test read(s) are stale — the pinned target no longer exists.\x1b[0m`
	);
	console.error(
		'  A test reads a driver path it does not own. Either the source moved without updating\n' +
			'  the test, or the pin was added for something already absent. Fix: update the pin, or\n' +
			'  convert the test to an assertion that does not name a location. An "ahk-dir" pin that\n' +
			'  resolves to an empty directory counts as stale — it concatenates to "" and disarms\n' +
			'  every assertion built on it.'
	);
	for (const s of stale) console.error(`    [${s.driver}] ${s.pin}  ←  ${s.test}`);
	console.error('\n  Run `node tools/test/test-git-mv-resilience.cjs --measure` for the full inventory.');
	process.exit(1);
}

const total = inventory.reduce((a, r) => a + r.pins, 0);
console.log(
	`\x1b[32m[OK] All ${total} path pin(s) resolve — ` +
		inventory.map((r) => `${r.driver} ${r.pins}`).join(', ') +
		'.\x1b[0m'
);
