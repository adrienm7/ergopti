// tools/test/test-features-manifest-no-drift.cjs

/**
 * ==============================================================================
 * MODULE: Generated Output — No Drift Guard
 * DESCRIPTION:
 * static/ergopti_plus/{macos,windows,linux}/_generated/ are git-tracked, NOT
 * gitignored. CI always regenerates-then-tests, so a stale hand-edit is
 * invisible there — but it ships to users unregenerated in any local build that
 * never re-runs `npm run gen`, silently diverging from
 * manifest.toml. This guard runs the REAL generators and diffs their
 * output, byte for byte, against what is committed.
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
 * THE FIX, IN TWO STEPS:
 * First the hand-written list became a scan of the three `_generated/` trees.
 * Better, but still a guess — and wrong for the generators that write OUTSIDE
 * those directories. Measured: build-domain.cjs writes twelve files, two of them
 * (`_shared/lua/keymap/terminators_catalogue.lua`,
 * `_shared/modules/menu/menu_manifest.json`) nowhere near a `_generated/`
 * folder, and gen-architecture-diagram.cjs writes `docs/architecture.md`. Under
 * a directory-scoped gate those three would be overwritten in the working tree
 * and never restored — the identical bug, one layer up.
 *
 * So the gate now reads tools/build/generators.cjs: every generator declares the
 * files it writes, `npm run gen` runs that same registry, and the two cannot
 * disagree about what exists. A generator that gains an output updates one list.
 *
 * FEATURES & RATIONALE:
 * 1. Byte-for-byte diff against the REAL generators, not a hand-rolled
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
// Generators and their outputs both come from the shared registry, so "what
// gets regenerated" and "what gets checked" cannot disagree.
//
// The snapshot set is the registry's DECLARED outputs, not a directory scan.
// The directory scan this replaced was already an improvement on a hand-written
// two-file list, but it was still a guess — and a wrong one for the generators
// that write outside _generated/: build-domain.cjs alone writes
// _shared/lua/keymap/terminators_catalogue.lua and
// _shared/modules/menu/menu_manifest.json, and gen-architecture-diagram.cjs
// writes docs/architecture.md. Under a directory-scoped gate those three would
// be overwritten in the working tree and never restored — the same bug this
// guard was fixed for once already, one layer up.
const { GENERATORS, allOutputs } = require('../build/generators.cjs');

// Sanity: the files this guard is specifically about must be in the registry.
// If one moves, the gate would otherwise go green over nothing.
const EXPECTED_TARGETS = [
	'static/ergopti_plus/macos/_generated/features_manifest.lua',
	'static/ergopti_plus/windows/_generated/features_manifest.ahk',
	'static/ergopti_plus/linux/_generated/features_manifest.lua',
	'static/ergopti_plus/macos/_generated/config_template.toml',
	'static/ergopti_plus/windows/_generated/config_template.toml',
	'static/ergopti_plus/linux/_generated/config_template.toml',
	'static/ergopti_plus/macos/_generated/logger_sub_files.lua',
	'static/ergopti_plus/windows/_generated/logger_sub_files.ahk',
	'static/ergopti_plus/macos/_generated/locale_table.lua',
	'static/ergopti_plus/linux/_generated/locale_table.lua',
	'static/ergopti_plus/windows/_generated/locale_table.ahk'
];

// ── Snapshot ────────────────────────────────────────────────────────────────

const DECLARED = allOutputs();

const snapshots = new Map();
for (const rel of DECLARED) {
	const abs = path.join(ROOT, rel);
	if (fs.existsSync(abs)) snapshots.set(rel, fs.readFileSync(abs));
}

const setupErrors = [];
for (const rel of EXPECTED_TARGETS) {
	if (!DECLARED.includes(rel)) {
		setupErrors.push(
			`${rel} is not declared by any generator in tools/build/generators.cjs — it moved or its ` +
				'generator stopped claiming it, and this guard would pass without ever comparing it'
		);
	}
}
if (DECLARED.length < 15) {
	setupErrors.push(`the registry declares only ${DECLARED.length} output(s) — it is not the full set`);
}
if (setupErrors.length > 0) {
	console.error('[31m[ERROR] no-drift guard is not covering its targets:[0m');
	for (const e of setupErrors) console.error('    - ' + e);
	process.exit(1);
}

// ── Regenerate, then restore unconditionally ────────────────────────────────

let regenerationFailed = false;
let regenerationError = null;
const drifted = [];
const created = [];

try {
	for (const g of GENERATORS) {
		execFileSync('node', [path.join(ROOT, 'tools', g.script)], { cwd: ROOT, stdio: 'pipe' });
	}
} catch (err) {
	regenerationFailed = true;
	regenerationError = err;
} finally {
	// Compare and restore in one pass, BEFORE any assertion — a failing
	// assertion below must never leave the repo changed relative to how this
	// test found it.
	for (const rel of DECLARED) {
		const abs = path.join(ROOT, rel);
		const before = snapshots.get(rel);
		const exists = fs.existsSync(abs);
		if (before === undefined) {
			if (exists) {
				created.push(rel);
				fs.unlinkSync(abs);
			}
			continue;
		}
		if (!exists || !before.equals(fs.readFileSync(abs))) drifted.push(rel);
		fs.writeFileSync(abs, before);
	}
}

// ── Report ──────────────────────────────────────────────────────────────────

if (regenerationFailed) {
	console.error('\x1b[31m[ERROR] failed to run a generator:\x1b[0m');
	console.error('  ' + (regenerationError && regenerationError.message));
	process.exit(1);
}

if (drifted.length > 0 || created.length > 0) {
	console.error('\x1b[31m[ERROR] generated output has drifted from its source:\x1b[0m');
	for (const f of drifted) {
		console.error(
			`  - ${f} differs from what \`npm run gen\` produces — ` +
				're-run the generator and commit the refreshed file.'
		);
	}
	for (const f of created) {
		console.error(`  - ${f} is produced by the generator but is not committed — commit it.`);
	}
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${snapshots.size} declared output(s) of ${GENERATORS.length} generator(s) ` +
		'match the live generator output (no drift).\x1b[0m'
);
