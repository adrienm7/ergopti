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
 * TWO COUNTS, BECAUSE ONE WAS MEASURING THE WRONG THING:
 * The file count (16) says how many test files pin a path. The literal count
 * (326) says how many pins exist. The gap is the hole: a file already on the
 * list could add pins for free, and the helper exemption is per file, so one
 * _DriverFuncBody call — which takes a SYMBOL, not a path — exempted every raw
 * path beside it. A `git mv` breaks the pin, not the file, so the pin is the
 * unit that gets ratcheted.
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

// Second frozen baseline — the count of individual pinned path literals, not of
// files. Counting files alone left two holes: a file already on the list could
// grow from one pinned path to ten without moving the number, and the helper
// exemption is per FILE, so one _DriverFuncBody call made every raw path beside
// it invisible. A `git mv` breaks the path, not the file, so the path is what
// gets frozen. This count deliberately ignores HELPER_RE.
//
// The number is 326, not 16. That gap is the whole point: the per-file count
// said this ratchet was nearly solved, and it was measuring the wrong thing.
// _DriverFuncBody(Name) takes a SYMBOL, not a path, so a file can call it once,
// earn the exemption, and go on reading twenty driver sources by hardcoded path
// through a local FileRead wrapper of its own — test_webview2_temp_leak.ahk's
// _TWTL_ReadSource("modules/llm/ollama_webview.ahk") is the shape. None of that
// was counted. Do not read 326 as a regression; read 16 as an illusion.
// History: 326 (first honest measurement, 2026-07-31)
const READ_BASELINE = 326;

const HELPER_RE = /_DriverSourceConcat|_DriverFuncBody|_DriverDirConcat/;
// A quoted relative path into a driver SOURCE tree ending in .ahk, e.g.
// "modules/keylogger/x.ahk" or "..\\lib\\layout\\layout_altgr.ahk".
const SOURCE_PATH_RE = /["'][^"'\n]*(?:modules|lib|ui)[\\/][^"'\n]*\.ahk["']/i;
const SOURCE_PATH_RE_G = new RegExp(SOURCE_PATH_RE.source, 'gi');

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
 * plus an assertion message naming "infra/webview_utils.ahk" was enough to book a
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
const perFileReads = [];
let reads = 0;
for (const file of collectTests(TESTS_DIR, [])) {
	const src = stripComments(fs.readFileSync(file, 'utf8'));
	const rel = path.relative(ROOT, file).replace(/\\/g, '/');

	// Path-literal count first, and unconditionally: a helper elsewhere in the
	// file does not make a raw path beside it move-resilient. Files that never
	// read a source at all are still skipped — a path named only in an assertion
	// message goes stale on a move, it does not break.
	if (src.includes('FileRead')) {
		let hits = 0;
		for (const line of src.split('\n')) {
			// An Assert()/Test() line naming a file is prose: on a move it goes
			// stale, it does not break. Only paths the code actually resolves count.
			if (/^\s*(Assert\w*|Test)\s*\(/.test(line)) continue;
			hits += (line.match(SOURCE_PATH_RE_G) || []).length;
		}
		if (hits > 0) {
			reads += hits;
			perFileReads.push({ rel, hits });
		}
	}

	if (HELPER_RE.test(src)) continue; // already move-resilient
	if (!src.includes('FileRead')) continue; // not a source reader
	if (!SOURCE_PATH_RE.test(src)) continue; // reads a fixture, not a source file
	pinned.push(rel);
}

const count = pinned.length;
const measure = process.argv.includes('--measure');
if (measure) {
	console.log(`location-pinned source-reading test files: ${count}`);
	for (const f of pinned) console.log('  ' + f);
	console.log(`\npinned AHK source path literals: ${reads}`);
	for (const { rel, hits } of perFileReads.sort((a, b) => b.hits - a.hits)) {
		console.log(`  ${String(hits).padStart(3)}  ${rel}`);
	}
	process.exit(0);
}

let failed = false;
if (count > BASELINE) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] Location-pinned source reads in AHK tests rose to ${count} file(s) (baseline ${BASELINE}).\x1b[0m`
	);
	console.error(
		'  A new test reads a driver source file by a hardcoded path. Use a move-resilient\n' +
		'  helper instead — _DriverFuncBody("Fn") or _DriverSourceConcat() — so a file move\n' +
		'  does not break it, or assert behaviour directly. Do NOT raise the baseline.'
	);
}
if (reads > READ_BASELINE) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] Individual pinned AHK source paths rose to ${reads} (baseline ${READ_BASELINE}).\x1b[0m`
	);
	console.error(
		'  A file that already reads sources by hardcoded path gained another one — that used\n' +
		'  to be free, because only files were counted, and a single helper call exempted the\n' +
		'  whole file. Do NOT raise the baseline.'
	);
}
if (failed) {
	console.error('  Run `node tools/test/test-no-pinned-source-reads.cjs --measure` to list them.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No new location-pinned source reads (${count}/${BASELINE} file(s), ${reads}/${READ_BASELINE} literal(s)).\x1b[0m`
);
