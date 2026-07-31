// tools/test/test-drift-guard-covers-every-output.cjs

/**
 * ==============================================================================
 * MODULE: Drift-Guard Coverage Meta Test
 * DESCRIPTION:
 * test-features-manifest-no-drift.cjs must guard EVERY file the manifest
 * generator writes, and must never eat an uncommitted change.
 *
 * ROOT CAUSE ENCODED:
 * build-features-manifest.js writes six files — a features manifest and a
 * config_template.toml for each of the three drivers. The drift guard listed
 * two. It snapshotted those two, ran the generator in place, and restored those
 * two, leaving the other four exactly as the generator had just rewritten them.
 *
 * So the guard did two wrong things at once, and the second is the dangerous
 * one. It never checked four of its six outputs for drift — the thing it exists
 * to do. And it silently reverted any uncommitted edit to those four: appending
 * a line to linux/_generated/config_template.toml and running the guard printed
 * "[OK] … no drift" and left `git status` clean. The edit was simply gone.
 *
 * A hand-maintained list of generator outputs falls behind the generator; this
 * one had fallen four behind, and nothing could tell you. The fix snapshots the
 * whole of each `_generated/` tree instead of naming files.
 *
 * WHY THIS TEST PERTURBS THE REPO:
 * The failure is only observable through a real edit surviving a real run. A
 * static check ("does the guard mention config_template?") would pass on a
 * guard that mentions it and still restores nothing. Every perturbation below
 * is restored from an in-memory snapshot in a finally block.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const GUARD = path.join(ROOT, 'tools/test/test-features-manifest-no-drift.cjs');

// One file per driver that the generator writes and the old list omitted. If
// the guard covers these, it covers the two it always did.
const PREVIOUSLY_UNGUARDED = [
	'static/ergopti_plus/macos/_generated/config_template.toml',
	'static/ergopti_plus/windows/_generated/config_template.toml',
	'static/ergopti_plus/linux/_generated/config_template.toml',
	'static/ergopti_plus/linux/_generated/features_manifest.lua'
];

const errors = [];

/** Runs the drift guard and returns {code, out}. */
function run_guard() {
	const r = spawnSync('node', [GUARD], { cwd: ROOT, encoding: 'utf8' });
	return { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
}

// ── 0. The guard must be green on the tree as we found it ───────────────────
//
// Everything below reads a non-zero exit as "the drift was detected". That
// inference is only valid if zero was the starting point.
{
	const base = run_guard();
	if (base.code !== 0) {
		console.error('\x1b[31m[ERROR] the drift guard is already failing before this test perturbs anything:\x1b[0m');
		console.error(base.out.trim());
		console.error('    Fix that first — this test cannot distinguish its own signal from pre-existing drift.');
		process.exit(1);
	}
}

for (const rel of PREVIOUSLY_UNGUARDED) {
	const abs = path.join(ROOT, rel);
	if (!fs.existsSync(abs)) {
		errors.push(`${rel}: missing — the generator's output moved and this test no longer covers it`);
		continue;
	}

	const original = fs.readFileSync(abs);
	try {
		// A comment line is inert in both TOML and Lua, so the perturbation
		// cannot break anything that reads the file mid-test.
		fs.writeFileSync(abs, Buffer.concat([original, Buffer.from('\n-- drift-guard coverage probe\n')]));

		const r = run_guard();

		if (r.code === 0) {
			errors.push(
				`${rel}: the drift guard passed with this file modified — it is not comparing it. ` +
					'This is the shipped bug: four of the generator\'s six outputs were never checked.'
			);
		}

		const after = fs.readFileSync(abs);
		if (after.equals(original)) {
			errors.push(
				`${rel}: the drift guard REVERTED an uncommitted edit and did not report it. ` +
					'A test that silently discards your working-tree changes is worse than no test, ' +
					'because you trust it.'
			);
		}
	} finally {
		fs.writeFileSync(abs, original);
	}
}

// ── The guard must leave the tree exactly as it found it on a clean run ─────
{
	const before = new Map();
	for (const rel of PREVIOUSLY_UNGUARDED) {
		const abs = path.join(ROOT, rel);
		if (fs.existsSync(abs)) before.set(rel, fs.readFileSync(abs));
	}
	const r = run_guard();
	if (r.code !== 0) {
		errors.push('the drift guard did not return to green after every perturbation was restored');
	}
	for (const [rel, bytes] of before) {
		if (!fs.readFileSync(path.join(ROOT, rel)).equals(bytes)) {
			errors.push(`${rel}: a clean drift-guard run modified it — the restore path is not unconditional`);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] drift-guard coverage:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] the drift guard detects a change to all ${PREVIOUSLY_UNGUARDED.length} previously ` +
		'unguarded generator output(s) and preserves uncommitted edits.\x1b[0m'
);
