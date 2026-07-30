// tools/test/test-no-pinned-source-reads.cjs

/**
 * ==============================================================================
 * MODULE: Location-Pinned Source-Read Ratchet (AHK tests)
 * DESCRIPTION:
 * Freezes the count of AHK test files that read a driver SOURCE file by a
 * hardcoded path (e.g. FileRead of "modules/keylogger/keylogger_av_state.ahk")
 * instead of the move-resilient framework helpers (_DriverSourceConcat /
 * _DriverFuncBody / _DriverDirConcat). These location-pinned introspection tests
 * are the #1 refactor pain: they break on a simple file move (a path I/O error,
 * never a behaviour signal) and so discourage the very structural splits the
 * project wants. They cannot all be converted at once, but their number must
 * never GROW — every new test must either assert behaviour or use a helper that
 * survives a move.
 *
 * ROOT CAUSE ENCODED:
 * A test that FileReads a quoted "(modules|lib|ui)/…*.ahk" path and does not use
 * a _Driver* helper is location-pinned. This ratchet counts them and fails if
 * the count rises above the frozen baseline. Lower (never raise) the baseline as
 * tests migrate to _DriverFuncBody("Fn") / _DriverSourceConcat(). It is the test
 * twin of the OS-purity ratchets (test_ahk_os_purity_ratchet.ahk /
 * test_port_adapter_coverage.lua): no new instances of a tolerated-but-deprecated
 * pattern.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const TESTS_DIR = path.join(ROOT, 'static', 'ergopti_plus', 'windows', 'tests');

// Frozen baseline — the current count of location-pinned source-reading test
// files. Drive toward zero by migrating each to a _Driver* helper; NEVER raise
// it to make a new test pass.
// History: 19 → 20 (session 2026-07-10: test_hse_suppress_release_bounded.ahk
//                     added a raw FileRead of a driver source. This is an .ahk-only
//                     ratchet, so only .ahk tests count here — the .lua source-scan
//                     tests from the same session are tracked by the sibling
//                     test-no-pinned-source-reads-lua.cjs, not here.)
//          20 → 16 (three tap-hold / metrics / menu_llm tests moved to
//                     _DriverDirConcat, and the scan stopped counting PROSE — see
//                     stripComments below.)
// The 16 that remain each pin something on purpose: run_all.ahk itself, a
// _generated/ file (which _DriverSourceConcat deliberately excludes), a runner
// script, or a single file carrying an ABSENCE assertion that a directory-wide
// scan would weaken.
const BASELINE = 16;

const HELPER_RE = /_DriverSourceConcat|_DriverFuncBody|_DriverDirConcat/;
// A quoted relative path into a driver SOURCE tree ending in .ahk, e.g.
// "modules/keylogger/x.ahk" or "..\\lib\\layout\\layout_altgr.ahk".
const SOURCE_PATH_RE = /["'][^"'\n]*(?:modules|lib|ui)[\\/][^"'\n]*\.ahk["']/i;

/**
 * Recursively collects every test_*.ahk file under a directory.
 * @param {string} dir - Absolute directory to walk.
 * @param {string[]} acc - Accumulator for matched file paths.
 * @returns {string[]} The accumulator, populated with absolute paths.
 */
function collectTests(dir, acc) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			collectTests(full, acc);
		} else if (entry.isFile() && /^test_.*\.ahk$/.test(entry.name)) {
			acc.push(full);
		}
	}
	return acc;
}

/**
 * Drops every full-line `;` comment. Without this the scan counted PROSE: a
 * module docstring saying "source-introspection (FileRead + pattern match)"
 * plus an assertion message naming "lib/webview_utils.ahk" was enough to book a
 * file as location-pinned when it never opens a file at all. A ratchet inflated
 * by its own explanatory comments cannot be driven to zero.
 * @param {string} src Full file content.
 * @returns {string} The same source with full-line comments removed.
 */
function stripComments(src) {
	return src
		.split(/\r?\n/)
		.filter((line) => !/^\s*;/.test(line))
		.join('\n');
}

const pinned = [];
for (const file of collectTests(TESTS_DIR, [])) {
	const src = stripComments(fs.readFileSync(file, 'utf8'));
	if (HELPER_RE.test(src)) continue; // already move-resilient
	if (!src.includes('FileRead')) continue; // not a source reader
	if (!SOURCE_PATH_RE.test(src)) continue; // reads a fixture, not a source file
	pinned.push(path.relative(ROOT, file).replace(/\\/g, '/'));
}

const count = pinned.length;
const measure = process.argv.includes('--measure');
if (measure) {
	console.log(`location-pinned source-reading test files: ${count}`);
	for (const f of pinned) console.log('  ' + f);
	process.exit(0);
}

if (count > BASELINE) {
	console.error(
		`\x1b[31m[ERROR] Location-pinned source reads in AHK tests rose to ${count} (baseline ${BASELINE}).\x1b[0m`
	);
	console.error(
		'  A new test reads a driver source file by a hardcoded path. Use a move-resilient\n' +
		'  helper instead — _DriverFuncBody("Fn") or _DriverSourceConcat() — so a file move\n' +
		'  does not break it, or assert behaviour directly. Do NOT raise the baseline.'
	);
	console.error('  Run `node tools/test/test-no-pinned-source-reads.cjs --measure` to list them.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No new location-pinned source reads (${count}/${BASELINE} baseline).\x1b[0m`
);
