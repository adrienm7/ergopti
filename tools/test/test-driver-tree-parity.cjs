// tools/test/test-driver-tree-parity.cjs

/**
 * ==============================================================================
 * MODULE: Driver Tree Parity (I1)
 * DESCRIPTION:
 * Measures how much of the three drivers' directory structure is shared, and
 * ratchets it upward. This is invariant I1 of the simplification programme: the
 * same feature should live at the same path in every driver.
 *
 * WHY A RATCHET AND NOT AN EQUALITY CHECK:
 * The trees are 19% identical today. Asserting equality would fail on arrival
 * and stay failing for the length of a multi-lot refactor, which means it would
 * be disabled within a week and guard nothing. A ratchet is useful from the
 * first commit: it records where the reorganisation has got to, and refuses to
 * let it slide back while the lots land one at a time.
 *
 * WHAT COUNTS:
 * Depth-≤2 subdirectories of each driver, excluding tests/ (its layout mirrors
 * the code it covers rather than being structure of its own) and excluding
 * build/tooling residue that is not part of the driver's architecture —
 * .venv, __pycache__, .pytest_cache, node_modules and the macOS .app bundles,
 * none of which any other driver could meaningfully mirror.
 *
 * The metric is the share of DISTINCT directory paths that exist in all three
 * drivers. A path present in one driver only counts against it, which is the
 * point: `windows/modules/updater/` and `macos/modules/karabiner/` are both real
 * work that has no counterpart, and the number should say so.
 *
 * WHY IT IS NOT A LINE COUNT:
 * Sharing structure is what makes a change reviewable across drivers — knowing
 * that the gestures code is at modules/gestures/ everywhere is worth more than
 * any individual file being identical. Directory identity is the cheap proxy
 * for that, and unlike a line count it cannot be gamed by moving code around
 * inside a file.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DRIVERS = ['macos', 'windows', 'linux'];

// Not architecture: virtualenvs, caches, build output and macOS app bundles.
// Counting them would move the ratio for reasons that have nothing to do with
// how the drivers are organised.
const IGNORED = [
	/^\./, // .venv, .pytest_cache, …
	/^__pycache__$/,
	/^node_modules$/,
	/^tests$/,
	/^build$/,
	/^bin$/,
	/\.app$/
];

const isIgnored = (segment) => IGNORED.some((re) => re.test(segment));

/** Depth-≤2 directory paths of a driver, POSIX-style, architecture only. */
function treeOf(driver) {
	const base = path.join(SP, driver);
	const out = new Set();
	if (!fs.existsSync(base)) return out;
	for (const top of fs.readdirSync(base, { withFileTypes: true })) {
		if (!top.isDirectory() || isIgnored(top.name)) continue;
		out.add(top.name);
		for (const sub of fs.readdirSync(path.join(base, top.name), { withFileTypes: true })) {
			if (!sub.isDirectory() || isIgnored(sub.name)) continue;
			out.add(`${top.name}/${sub.name}`);
		}
	}
	return out;
}

const trees = new Map(DRIVERS.map((d) => [d, treeOf(d)]));

const errors = [];
for (const [d, t] of trees) {
	if (t.size === 0) {
		errors.push(`${d}/ produced no directories — the walk is broken, and a ratchet over nothing passes forever`);
	}
}

const union = new Set();
for (const t of trees.values()) for (const p of t) union.add(p);

const shared = [...union].filter((p) => DRIVERS.every((d) => trees.get(d).has(p))).sort();
const ratio = union.size === 0 ? 0 : (shared.length / union.size) * 100;

// ── The ratchet ─────────────────────────────────────────────────────────────
//
// 2026-08-01: 14 of 50 distinct paths are present in all three drivers (28.0 %).
// Raise BASELINE_SHARED as Lots 3–6 land; never lower it to make a change pass.
//
// History, so the ratchet reads as a trajectory rather than a number:
//   11/51 (21.6 %) — first measurement.
//   12/51 (23.5 %) — crash_reporter promoted out of lib/ into modules/diagnostics
//                    on macOS and Windows, where Linux already had it. The union
//                    did not grow: the path already existed, on one driver.
//   13/50 (26.0 %) — updater promoted the same way. Here the union SHRANK too,
//                    because Windows had a whole lib/updater/ directory that
//                    moved rather than a single file: one unshared path removed
//                    and one shared path gained, from the same move.
//   14/50 (28.0 %) — dynamic_hotstrings. macOS and Linux both had
//                    modules/dynamic_hotstrings/; on Windows the same behaviour
//                    was section 5 of modules/hotstrings/hotstrings_text_expansion.ahk.
//                    Found only after this file's OWN report was fixed: it used
//                    to print a two-driver path once under each driver's
//                    "unique to it" list, so the strongest promotion candidate
//                    in the tree read as two unrelated private folders.
//
// Written as a literal, not as `shared.length`. Deriving the baseline from the
// value it is supposed to constrain makes the comparison `x <= x` — a check that
// passes for every possible input, which is the precise definition of the false
// green this repo already ratchets against elsewhere.
const BASELINE_SHARED = 14;

// The union is ratcheted too, downward: a driver that grows a new unshared
// directory dilutes the ratio even when nothing was removed. Bounding it stops
// the programme drifting sideways — adding structure to one driver while the
// shared count stands still.
const BASELINE_UNION = 50;

if (shared.length < BASELINE_SHARED) {
	errors.push(
		`only ${shared.length} director(ies) are present in all three drivers, below the recorded ` +
			`${BASELINE_SHARED}. Either the reorganisation regressed, or one driver moved a directory ` +
			'without its counterparts. Run with --measure to see which.'
	);
}
if (union.size > BASELINE_UNION) {
	errors.push(
		`the union of driver directories grew to ${union.size} (recorded ${BASELINE_UNION}). A new ` +
			'directory in one driver only dilutes I1 even when nothing was removed — add its ' +
			'counterparts, or raise this deliberately with a note saying why the structure is ' +
			'genuinely per-driver.'
	);
}

if (process.argv.includes('--measure')) {
	console.log(`union: ${union.size} distinct path(s) across ${DRIVERS.length} driver(s)`);
	console.log(`shared by all three: ${shared.length} (${ratio.toFixed(1)} %)\n`);
	console.log('shared:');
	for (const p of shared) console.log('  ' + p);
	// Two classes, not one. The report used to print every non-shared path under
	// "per driver, unique to it", which listed a path held by TWO drivers once
	// under each of them — so modules/dynamic_hotstrings appeared as if macOS and
	// Linux each had a private directory of that name. That is backwards for the
	// one question this report exists to answer: the repo's objective promotion
	// test is "where does the same code live in the other drivers?", and a path
	// two drivers already agree on is the strongest evidence there is. Printing it
	// as two separate one-driver paths hid the shortest route to raising I1.
	const holders = (p) => DRIVERS.filter((d) => trees.get(d).has(p));

	const onTwo = [...union].filter((p) => holders(p).length === 2).sort();
	console.log(`\ntwo drivers agree, one is missing — ${onTwo.length} promotion candidate(s):`);
	for (const p of onTwo) {
		const has = holders(p);
		const missing = DRIVERS.filter((d) => !has.includes(d));
		console.log(`  ${p}  (on ${has.join(' + ')}, absent on ${missing.join(', ')})`);
	}

	console.log('\ngenuinely single-driver:');
	for (const d of DRIVERS) {
		const only = [...trees.get(d)].filter((p) => holders(p).length === 1).sort();
		console.log(`  ${d} (${only.length}): ${only.join(', ')}`);
	}
	process.exit(0);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] driver tree parity (I1):\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	console.error('    Run with --measure to see the full breakdown.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] driver tree parity (I1): ${shared.length}/${union.size} director(ies) shared by all ` +
		`three drivers — ${ratio.toFixed(1)} %.\x1b[0m`
);
