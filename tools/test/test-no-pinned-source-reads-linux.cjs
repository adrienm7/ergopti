// tools/test/test-no-pinned-source-reads-linux.cjs

/**
 * ==============================================================================
 * MODULE: Location-Pinned Source-Read Ratchet (Linux Lua tests)
 * DESCRIPTION:
 * Linux twin of test-no-pinned-source-reads-lua.cjs (macOS). Freezes the count
 * of Linux tests that name a driver SOURCE file by a hardcoded path instead of
 * loading the module and asserting behaviour. Until now only the macOS and AHK
 * trees had this ratchet, so the Linux tree could gain source-text tests for
 * free (audit item 14 of "Test parity across the drivers").
 *
 * FEATURES & RATIONALE:
 * 1. What counts is tools/lint/pinned-source-read.cjs, the macOS definition:
 *    one definition, so the two drivers' numbers mean the same thing.
 * 2. Two counts, files and reads, for the reason the macOS twin gives: a file
 *    already on the list could otherwise add pins for free.
 * 3. Lower, never raise, the baselines as tests move to behaviour.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { findPinnedPaths, collectLuaTests } = require('../lint/pinned-source-read.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const TESTS_DIR = path.join(DRIVER_ROOT, 'tests');
// Frozen on 2026-10-31, the day the ratchet started: Linux test files naming a
// driver source path, and the pinned reads they hold. 74 → 72 files and 137 →
// 135 reads the same day: the version literal and debounce clock scans became
// a fresh module load over a stamp and a debounce driven by a controlled clock.
// 72 → 65 files and 135 → 122 reads: eight tests load their module by name
// through helpers.fresh_module instead of dofile or loadfile on its path.
// 65 → 61 files and 122 → 116 reads: six describe labels named their module
// by path; they name it by module now.
// 61 → 61 files and 116 → 111 reads: the input_reader half of the keycode
// single-source test loads the reader over a shared-table double instead of
// reading its source.
// 61 → 55 files and 111 → 100 reads: the managed_http fixture group loads
// http_client, system_proxy, managed_http_deadline and the shared proxy
// policy by module name, and its import-isolation test fails the import
// through package.preload instead of matching dofile paths.
// 55 → 51 files and 100 → 96 reads: four managed-network tests load
// managed_http, managed_http_deadline, http_client and the shared proxy
// policy by module name instead of dofile on their paths.
// 51 → 43 files and 96 → 88 reads: helpers.read_driver_unit(symbol), the
// twin of the macOS helper, selects a production file by a declaration unique
// to it; eight source invariants use it instead of the file's path.
// 43 → 30 files and 88 → 75 reads: thirteen more source invariants select
// their file through helpers.read_driver_unit (shortcuts manager, keystats
// reader and writer, injector, webview manager, keyboard layout and hook,
// logger sink, expansion delay, prediction engine, menu builder).
// 30 → 25 files and 75 → 61 reads: the keycode single-source, model
// selector listing, keystats privacy filter, token prompt setter and pause
// layout switch invariants select their files by declaration.
// 25 → 23 files and 61 → 53 reads: the dashboard bridge actions and the
// keystats SQLite writer schema cases select their files by declaration.
// 23 → 19 files and 53 → 47 reads: the CapsWord auto-off, word reset and
// loader delegation tests select their files by declaration, the timed TOML
// reader's delegation is checked by a recording shared reader, and the signal
// handler test resolves its chunk from the module name.
// 19 → 13 files and 47 → 41 reads: the archive_output tar feeder tests (the
// sliced-source compiles) and the webview manager loadfile resolve their file
// with package.searchpath from the module name; the dynamic hotstrings
// manager, tap-hold lifecycle and clipboard preparation reads select theirs by
// declaration.
// 13 → 8 files and 41 → 18 reads: helpers.read_module_source(name) resolves a
// module through package.searchpath; the spawn-args sites, the http_client
// and api_ollama pair, the sqlite_command callers, the CapsWord pointer map,
// the native dialog title inventory and the webview app names list modules
// by name instead of by path.
// 8 → 7 files and 18 → 13 reads: the locale, network policy, shared loader
// and keyboard source fixture copies take their source from the module name,
// and the menu language producer is checked against the file require resolves.
//
// What is left is legitimate, and each holds a path because the path is the
// behaviour under test: the paths, locale, policy and shared loader layout
// tests stage a copy at a named layout (/usr/lib/ergopti/infra/paths.lua,
// ./infra/locale.lua) because the module derives its roots from its own
// location; the keyboard source fixture asserts the hardware harnesses never
// load the production writer by that path; the startup soak runs the actual
// e2e child fragment, which loads the event loop by that path; the healthcheck
// asserts the opener worker's argv, which is that path. Converting them would
// pin a different string, not remove the pin.
const BASELINE = 7;
const READ_BASELINE = 13;
const HELPER_RE = /read_driver_source|source_concat|list_lua_files\(/;

const pinned = [];
const perFileReads = [];
let reads = 0;
for (const file of collectLuaTests(TESTS_DIR, [])) {
	const src = fs.readFileSync(file, 'utf8');
	const rel = path.relative(ROOT, file).replace(/\\/g, '/');
	// Only literals resolving to a real file count: a test asserting a module is
	// gone must name it, and there is nothing there to convert.
	const hits = findPinnedPaths(src, DRIVER_ROOT).filter((hit) => hit.resolves);
	if (hits.length > 0) {
		reads += hits.length;
		perFileReads.push({ rel, hits: hits.length });
	}
	if (HELPER_RE.test(src) || hits.length === 0) continue;
	pinned.push(rel);
}

if (process.argv.includes('--measure')) {
	console.log(`path-pinned Linux source-reading test files: ${pinned.length}`);
	console.log(`pinned Linux source READS: ${reads}`);
	for (const { rel, hits } of perFileReads.sort((a, b) => b.hits - a.hits))
		console.log(`  ${String(hits).padStart(3)}  ${rel}`);
	process.exit(0);
}

const problems = [];
if (pinned.length > BASELINE)
	problems.push(
		`Path-pinned source reads in Linux tests rose to ${pinned.length} file(s) (baseline ${BASELINE}).`
	);
if (reads > READ_BASELINE)
	problems.push(
		`Individual pinned Linux source reads rose to ${reads} (baseline ${READ_BASELINE}).`
	);
// A ratchet left above the measurement lets the next pin land unseen.
if (pinned.length < BASELINE || reads < READ_BASELINE)
	problems.push(
		`The measurement fell to ${pinned.length} file(s) and ${reads} read(s): lower BASELINE and READ_BASELINE to it.`
	);
if (problems.length > 0) {
	for (const problem of problems) console.error(`\x1b[31m[ERROR] ${problem}\x1b[0m`);
	console.error(
		'  Load the module and assert behaviour, or read it by symbol, so a file move does not\n' +
			'  break the test. Do NOT raise a baseline. List them with --measure.'
	);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] No new path-pinned Linux source reads (${pinned.length}/${BASELINE} file(s), ${reads}/${READ_BASELINE} read(s)).\x1b[0m`
);
