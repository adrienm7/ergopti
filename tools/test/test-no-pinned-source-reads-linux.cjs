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
// driver source path, and the pinned reads they hold.
const BASELINE = 74;
const READ_BASELINE = 136;
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
