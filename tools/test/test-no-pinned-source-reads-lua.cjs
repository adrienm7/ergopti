// tools/test/test-no-pinned-source-reads-lua.cjs

/**
 * ==============================================================================
 * MODULE: Location-Pinned Source-Read Ratchet (macOS Lua tests)
 * DESCRIPTION:
 * macOS twin of test-no-pinned-source-reads.cjs (the AHK ratchet). Freezes the
 * count of macOS tests that name a driver SOURCE file by a hardcoded path —
 * "modules/keymap/input_sources.lua" and the like — instead of loading the
 * module and asserting behaviour, or scanning via the move-resilient
 * symbol-keyed helper. These path-pinned introspection tests are the macOS half
 * of the #1 refactor pain: a `git mv` of the cited file breaks them with a path
 * error, never a behaviour signal, so they discourage the structural splits the
 * project wants.
 *
 * TWO COUNTS, BECAUSE ONE WAS MEASURING THE WRONG THING:
 * The file count says how many test files pin a path; the read count says how
 * many pins exist. A file already on the list could add pins for free, and the
 * helper exemption is per file. A `git mv` breaks the read, not the file, so the
 * read is the unit that gets ratcheted.
 *
 * ROOT CAUSE ENCODED:
 * A test naming a driver source path is location-pinned. This ratchet counts
 * them and FAILS if the count rises above the frozen baseline. Lower (never
 * raise) the baseline as tests migrate to behaviour assertions or to
 * helpers.read_driver_source(symbol). It is the test twin of the OS-purity
 * ratchets and of the AHK pinned-read ratchet.
 *
 * WHAT COUNTS lives in tools/lint/pinned-source-read.cjs, shared with the
 * auto-fixer. It has to be shared: while each carried its own regex they
 * disagreed by a factor of five, and "the fixer covers most of the lot" was a
 * claim about two different populations.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { findPinnedPaths, collectLuaTests } = require('../lint/pinned-source-read.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const TESTS_DIR = path.join(DRIVER_ROOT, 'tests');

// Frozen baseline — the count of macOS test FILES naming a driver source path.
// Drive toward zero by migrating each to a behaviour assertion or to
// helpers.read_driver_source(symbol); NEVER raise it to make a new test pass.
//
// History: 134 → 133 → 134 → 136 → 140 → 153 → 156 as deliberate source
//          invariants landed with bug fixes, each either audit-prescribed or
//          backed by a stronger behaviour section in the same file.
//          156 → 32 (fix-pinned-source-reads.cjs converted 153 reads once it was
//                    taught the two other handle shapes in the tree.)
//           32 → 41 (2026-08-02: NOT a regression — the scan was blind. The path
//                    pattern's `lib` arm had matched nothing since e97ddbd08
//                    renamed lib/ to infra/, and no arm ever reached the
//                    driver-root init.lua, the most-pinned file in the suite.)
//           41 → 104 (2026-08-02, and this is the last widening of its kind: the
//                    gate stopped matching the READ EXPRESSION and started
//                    matching the PATH LITERAL. Three separate widenings had
//                    each surfaced pins that were always there, because each
//                    guessed at the shapes someone writes around io.open —
//                    `local p = driver_root() .. "…"`, an inline io.open, and
//                    finally a local bound to driver_root() lines earlier and
//                    concatenated further down, which no adjacency pattern can
//                    reach. Fifteen files do not call driver_root() at all: they
//                    rebuild the root from debug.getinfo, or open
//                    "modules/keymap/llm_bridge.lua" relative to the runner's
//                    cwd. What a `git mv` breaks is the string naming the file,
//                    not the syntax around it. Not one test changed; 63 files
//                    that had been pinned the whole time became visible.
//                    Anything below 104 now is real conversion.)
//          104 → 70 (2026-08-02: the first real conversion. Once the fixer shared
//                    this definition and could generate a selector from a
//                    constant or an i18n key, it converted 44 reads across 35
//                    files with no test change.)
//           70 → 34 (2026-08-02: the local `read_source(rel)` helpers. Two thirds
//                    of the population was never written at the read site — the
//                    file declares one helper taking a driver-relative path and
//                    calls it a dozen times, so converting read sites alone left
//                    them all. The helper now takes a SELECTOR and each call site
//                    swaps its literal, keeping the module name as a trailing
//                    comment: a comment cannot break a test when the file moves,
//                    it can only go stale.)
//           34 → 33 (2026-08-02: the second-level wrappers, see the read baseline.)
//           33 → 32 (2026-08-02: the one refusal, split by hand — see the read
//                    baseline.)
const BASELINE = 32;

// Second frozen baseline — individual pinned READS, not files.
//
// Counting files alone left two holes, both of the kind a ratchet is supposed to
// make impossible. A file already on the list was free: it could grow from one
// pinned read to ten and the number never moved. And the helper exemption below
// is per FILE, so a test using read_driver_source() once could pin any number of
// raw paths beside it and disappear from the count entirely. The unit a `git mv`
// breaks is the read, so the read is what gets ratcheted. This count deliberately
// ignores HELPER_RE: raw pins are counted even in a file that is otherwise
// move-resilient.
//
// History: 40 (first measurement, 2026-07-31 — 32 files, so 8 reads were
//              invisible to the per-file count)
//       40 → 56 (2026-08-02: an `infra` arm and an init.lua arm; the measured
//              count before widening was 38, so the old 40 also carried 2 reads
//              of pure slack — a ratchet frozen above its own measurement lets
//              the next regression land for free.)
//       56 → 281 (2026-08-02: literal-based counting, see the file baseline. The
//              read count rose five-fold where the file count rose 2.5-fold,
//              which is the shape a per-file ratchet is blind to by
//              construction: the files worst affected were already on the list.)
//      281 → 237 (2026-08-02: 44 reads converted, see the file baseline.)
//      237 → 90 (2026-08-02: 147 more via the path-taking helpers. From 281 to 90
//              in one pass, so two thirds of what looked like an unbounded
//              migration was one rewrite applied 147 times.)
//       90 → 80 (2026-08-02: the second-level wrappers. assert_gc_pinned(rel)
//              forwards to read_source(rel) and reads no file itself, so it only
//              became convertible once its callee had been — and only if the
//              fixer seeds itself with helpers a PREVIOUS run converted, which
//              no longer look like reads.)
//       80 → 75 (2026-08-02: the one refusal, split by hand. A single reader
//              served both the driver tree and _shared/, so it would have had to
//              take a selector at three call sites and a path at the fourth;
//              splitting it in two let the fixer take the driver half.)
const READ_BASELINE = 75;

// A move-resilient scan helper (symbol-keyed whole-tree read), so converting a
// test to one of these drops it from the FILE count (never from the read count).
const HELPER_RE = /read_driver_source|source_concat|list_lua_files\(/;

const pinned = [];
const perFileReads = [];
let reads = 0;
for (const file of collectLuaTests(TESTS_DIR, [])) {
	const src = fs.readFileSync(file, 'utf8');
	const rel = path.relative(ROOT, file).replace(/\\/g, '/');

	// Only literals resolving to a real file count: a test asserting a module is
	// GONE must name it, and there is nothing there to convert.
	const hits = findPinnedPaths(src, DRIVER_ROOT).filter((h) => h.resolves);

	// Read count first, and unconditionally: a helper elsewhere in the file does
	// not make a raw pin beside it move-resilient.
	if (hits.length > 0) {
		reads += hits.length;
		perFileReads.push({ rel, hits: hits.length, paths: hits });
	}

	if (HELPER_RE.test(src)) continue; // already move-resilient
	if (hits.length === 0) continue; // reads a fixture, not a source file
	pinned.push(rel);
}

const count = pinned.length;
if (process.argv.includes('--measure')) {
	const verbose = process.argv.includes('--paths');
	console.log(`path-pinned macOS source-reading test files: ${count}`);
	for (const f of pinned) console.log('  ' + f);
	console.log(`\npinned macOS source READS: ${reads}`);
	for (const { rel, hits, paths } of perFileReads.sort((a, b) => b.hits - a.hits)) {
		console.log(`  ${String(hits).padStart(3)}  ${rel}`);
		if (verbose) for (const p of paths) console.log(`         ${p.line}: ${p.rel}`);
	}
	process.exit(0);
}

let failed = false;
if (count > BASELINE) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] Path-pinned source reads in macOS tests rose to ${count} file(s) (baseline ${BASELINE}).\x1b[0m`
	);
	console.error(
		'  A new test names a driver source file by a hardcoded path. Load the module and\n' +
			'  assert behaviour, or use helpers.read_driver_source(symbol), so a file move does\n' +
			'  not break it. Do NOT raise the baseline.'
	);
}
if (reads > READ_BASELINE) {
	failed = true;
	console.error(
		`\x1b[31m[ERROR] Individual pinned macOS source reads rose to ${reads} (baseline ${READ_BASELINE}).\x1b[0m`
	);
	console.error(
		'  A file already on the pinned list gained another hardcoded path — that used to be\n' +
			'  free, because only files were counted. The read is what a `git mv` breaks, so the\n' +
			'  read is what is frozen. Do NOT raise the baseline.'
	);
}
if (failed) {
	console.error(
		'  Run `node tools/test/test-no-pinned-source-reads-lua.cjs --measure [--paths]` to list them.'
	);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] No new path-pinned macOS source reads (${count}/${BASELINE} file(s), ${reads}/${READ_BASELINE} read(s)).\x1b[0m`
);
