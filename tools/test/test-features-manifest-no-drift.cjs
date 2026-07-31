// tools/test/test-features-manifest-no-drift.cjs

/**
 * ==============================================================================
 * MODULE: Generated Features Manifest — No Drift Guard
 * DESCRIPTION:
 * static/ergopti_plus/{macos,windows,linux}/_generated/ are git-tracked, NOT
 * gitignored. CI always regenerates-then-tests, so a stale hand-edit is
 * invisible there — but it ships to users unregenerated in any local build that
 * never re-runs `npm run build:manifest`, silently diverging from
 * manifest.toml. This guard runs the REAL generator and diffs its output,
 * byte for byte, against what is committed.
 *
 * ROOT CAUSE ENCODED — THE GUARD'S OWN BUG, WHICH WAS WORSE THAN THE DRIFT:
 * build-features-manifest.js writes SIX files: a features manifest and a
 * config_template.toml for each of the three drivers. This guard listed TWO of
 * them. It snapshotted those two, ran the generator in place, diffed the two,
 * and restored the two.
 *
 * The other four were therefore left exactly as the generator had just written
 * them — silently overwritten in the working tree, and never checked for drift.
 * Demonstrated before the fix: appending a line to
 * linux/_generated/config_template.toml and running this guard printed
 * "[OK] … no drift" and left `git status` completely clean. The uncommitted edit
 * was gone. A test that discards your working-tree changes and then reports
 * success is worse than no test, because you trust it.
 *
 * THE FIX, AND WHY IT IS SHAPED THIS WAY:
 * The list is no longer written down. This snapshots every file under all three
 * `_generated/` trees and compares every one of them afterwards, so the day the
 * generator gains a seventh output it is covered without anyone remembering to
 * add it here. Files written by OTHER generators sit in the same directories
 * and are simply unchanged by this run — they cost one read each and cannot
 * produce a false drift.
 *
 * FEATURES & RATIONALE:
 * 1. Byte-for-byte diff against the REAL generator, not a hand-rolled
 *    parse-and-compare — the strongest guarantee against drift, and exactly
 *    what a reviewer would run manually to double-check a suspicious diff.
 * 2. Restore is unconditional and happens BEFORE any assertion, so neither a
 *    real drift nor a crash mid-run can leave the tree modified.
 * 3. A file the generator CREATES that is not committed is reported as drift
 *    and then removed — an uncommitted generated file is exactly the state this
 *    guard exists to prevent, and leaving it behind would hide it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
// Every generator that writes into the _generated/ trees below. A list, because
// a single hardcoded generator is the same shape of mistake as the single
// hardcoded file list this gate already had: adding one must not depend on
// somebody remembering to widen a guard.
const GENERATORS = [
	'tools/build/build-features-manifest.js',
	'tools/codegen/codegen-logger-sub-files.cjs'
];

// Every directory the generator can write into. Deliberately NOT a list of
// files: the whole point of the fix is that no file list has to be kept in sync
// by hand, because the previous one silently fell four files behind.
const GENERATED_DIRS = [
	'static/ergopti_plus/macos/_generated',
	'static/ergopti_plus/windows/_generated',
	'static/ergopti_plus/linux/_generated'
];

// The files this guard is specifically about. Used only to sanity-check that
// the scan below actually covered them — if a rename moves one out of the
// snapshotted directories, the guard would go green over nothing.
const EXPECTED_TARGETS = [
	'static/ergopti_plus/macos/_generated/features_manifest.lua',
	'static/ergopti_plus/windows/_generated/features_manifest.ahk',
	'static/ergopti_plus/linux/_generated/features_manifest.lua',
	'static/ergopti_plus/macos/_generated/config_template.toml',
	'static/ergopti_plus/windows/_generated/config_template.toml',
	'static/ergopti_plus/linux/_generated/config_template.toml',
	'static/ergopti_plus/macos/_generated/logger_sub_files.lua',
	'static/ergopti_plus/windows/_generated/logger_sub_files.ahk'
];

/** Every file under a directory, as repo-relative POSIX paths. */
function walk(absDir, acc = []) {
	if (!fs.existsSync(absDir)) return acc;
	for (const e of fs.readdirSync(absDir, { withFileTypes: true })) {
		const p = path.join(absDir, e.name);
		if (e.isDirectory()) walk(p, acc);
		else acc.push(path.relative(ROOT, p).split(path.sep).join('/'));
	}
	return acc;
}

// ── Snapshot ────────────────────────────────────────────────────────────────

const snapshots = new Map();
for (const dir of GENERATED_DIRS) {
	for (const rel of walk(path.join(ROOT, dir))) {
		snapshots.set(rel, fs.readFileSync(path.join(ROOT, rel)));
	}
}

const setupErrors = [];
for (const rel of EXPECTED_TARGETS) {
	if (!snapshots.has(rel)) {
		setupErrors.push(
			`${rel} was not found under any snapshotted _generated/ directory — ` +
				'it moved, and this guard would have passed without ever comparing it'
		);
	}
}
if (setupErrors.length > 0) {
	console.error('\x1b[31m[ERROR] features-manifest drift guard is not covering its targets:\x1b[0m');
	for (const e of setupErrors) console.error('    - ' + e);
	process.exit(1);
}

// ── Regenerate, then restore unconditionally ────────────────────────────────

let regenerationFailed = false;
let regenerationError = null;
const drifted = [];
const created = [];

try {
	for (const gen of GENERATORS) {
		execFileSync('node', [path.join(ROOT, gen)], { cwd: ROOT, stdio: 'pipe' });
	}
} catch (err) {
	regenerationFailed = true;
	regenerationError = err;
} finally {
	// Compare and restore in one pass, BEFORE any assertion — a failing
	// assertion below must never leave the repo changed relative to how this
	// test found it.
	for (const dir of GENERATED_DIRS) {
		for (const rel of walk(path.join(ROOT, dir))) {
			const abs = path.join(ROOT, rel);
			const before = snapshots.get(rel);
			if (before === undefined) {
				// The generator produced a file that is not committed.
				created.push(rel);
				fs.unlinkSync(abs);
				continue;
			}
			if (!before.equals(fs.readFileSync(abs))) drifted.push(rel);
		}
	}
	// Anything that existed before and is gone now counts as drift too, and has
	// to be put back.
	for (const [rel, before] of snapshots) {
		const abs = path.join(ROOT, rel);
		if (!fs.existsSync(abs)) drifted.push(rel);
		fs.writeFileSync(abs, before);
	}
}

// ── Report ──────────────────────────────────────────────────────────────────

if (regenerationFailed) {
	console.error('\x1b[31m[ERROR] failed to run a _generated/ tree generator:\x1b[0m');
	console.error('  ' + (regenerationError && regenerationError.message));
	process.exit(1);
}

if (drifted.length > 0 || created.length > 0) {
	console.error('\x1b[31m[ERROR] generated output has drifted from manifest.toml:\x1b[0m');
	for (const f of drifted) {
		console.error(
			`  - ${f} differs from what \`npm run build:manifest\` produces — ` +
				're-run the generator and commit the refreshed file.'
		);
	}
	for (const f of created) {
		console.error(`  - ${f} is produced by the generator but is not committed — commit it.`);
	}
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${snapshots.size} committed _generated/ file(s) across the three drivers ` +
		'match the live generator output (no drift).\x1b[0m'
);
