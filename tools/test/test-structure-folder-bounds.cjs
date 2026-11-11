// tools/test/test-structure-folder-bounds.cjs

/**
 * ==============================================================================
 * MODULE: Structure Folder Bounds Ratchet (Rule B)
 * DESCRIPTION:
 * Holds the shape of the driver trees to the counts measured when the
 * structure plan was written (docs/design/structure-plan.md): folders outside
 * the 2..20 entry bounds (40 in tests), per tree, and the layer and domain
 * folders (depth two) present on one or two drivers only. No count may rise; a count that falls
 * fails too until the baseline is lowered in the same change, so the ratchet
 * never carries slack a regression could hide in.
 *
 * WHY A RATCHET:
 * The plan moves about three thousand files in some fifty steps, after the
 * feature work in flight lands. Until then the trees keep growing, and the
 * one thing that must not happen is a new oversized or single-entry folder,
 * or a new folder on one driver only, making the plan longer while it waits.
 *
 * The measurement is tools/audit/structure/census.cjs, which reads the Git
 * index only. `--update-baseline` rewrites the baseline and refuses while any
 * count is above it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Census = require('../audit/structure/census.cjs');

const BASELINE_FILE = path.join(__dirname, 'structure-folder-bounds-baseline.json');
const KEYS = ['code_oversized', 'code_singleton', 'tests_oversized', 'tests_singleton'];

/** The ratcheted numbers of a census. */
function numbers(census) {
	const out = {};
	for (const [tree, s] of Object.entries(census.summary)) {
		for (const k of KEYS) out[`${tree}.${k}`] = s[k];
		// A singleton kept for parity is still a singleton: the plan turns plain
		// ones into parity ones, so the two are ratcheted together.
		out[`${tree}.code_singleton`] += s.code_singleton_parity;
		out[`${tree}.tests_singleton`] += s.tests_singleton_parity;
	}
	// Layer and domain level only: below it a sub-module exists where its code
	// exists, and the plan creates such asymmetric sub-folders on purpose.
	out['drivers.mismatched_folders_depth2'] = census.mismatches.filter(
		(m) => m.folder.split('/').length <= 2
	).length;
	return out;
}

/** Compares measured numbers with the baseline; returns the failures. */
function compare(measured, baseline) {
	const failures = [];
	for (const [key, value] of Object.entries(measured)) {
		if (!(key in baseline)) failures.push(`${key}: ${value} has no baseline entry`);
		else if (value > baseline[key])
			failures.push(`${key} rose to ${value} (baseline ${baseline[key]})`);
		else if (value < baseline[key])
			failures.push(
				`${key} fell to ${value} (baseline ${baseline[key]}): lower the baseline in this change (--update-baseline)`
			);
	}
	for (const key of Object.keys(baseline))
		if (!key.startsWith('_') && !(key in measured))
			failures.push(`${key}: baseline entry without a measurement`);
	return failures;
}

/** The gate can fail: synthetic trees that break each bound. */
function selfTest() {
	const files = [];
	for (const d of Census.DRIVERS)
		for (let i = 0; i < 3; i++)
			files.push(
				`${d}/infra/a${i}.lua`,
				`${d}/ui/x/f${i}.lua`,
				`${d}/ui/z/f${i}.lua`,
				`${d}/modules/m${i}.lua`
			);
	const clean = Census.measure(files);
	const crowded = Census.measure([
		...files,
		...Array.from({ length: 25 }, (_, i) => `linux/infra/b${i}.lua`)
	]);
	assert.equal(clean.summary.linux.code_oversized, 0);
	assert.equal(crowded.summary.linux.code_oversized, 1, 'a 28-entry folder is oversized');
	const lonely = Census.measure([...files, 'macos/modules/only/one.lua']);
	assert.equal(lonely.summary.macos.code_singleton, 1, 'a one-entry folder is a singleton');
	assert.equal(
		numbers(lonely)['drivers.mismatched_folders_depth2'],
		1,
		'a folder on one driver is a mismatch'
	);
	const parity = Census.measure([
		...files,
		'macos/ui/y/a.lua',
		'macos/ui/y/b.lua',
		'linux/ui/y/a.lua',
		'windows/ui/y.ahk'
	]);
	assert.equal(
		parity.summary.linux.code_singleton_parity,
		1,
		'a singleton mirroring a real folder is counted apart'
	);
	assert.equal(
		parity.mismatches.length,
		0,
		'a module that is one file on a driver is not a mismatch'
	);
	const exempt = Census.measure([...files, 'windows/vendor/one/x.ahk']);
	assert.equal(exempt.summary.windows.code_singleton, 0, 'vendor is exempt');
	assert.deepEqual(compare({ a: 2 }, { a: 1 }).length, 1, 'a rise fails');
	assert.deepEqual(
		compare({ a: 0 }, { a: 1 }).length,
		1,
		'a fall without lowering the baseline fails'
	);
	assert.deepEqual(compare({ a: 1 }, { a: 1 }), []);
}

function main() {
	selfTest();
	const census = Census.census();
	const totalFolders = Object.values(census.summary).reduce((n, s) => n + s.folders, 0);
	// A broken walk would measure nothing and pass forever.
	assert.ok(totalFolders > 500, `the census walked only ${totalFolders} folders`);
	const measured = numbers(census);
	const baseline = JSON.parse(fs.readFileSync(BASELINE_FILE, 'utf8'));
	const failures = compare(measured, baseline);

	if (process.argv.includes('--update-baseline')) {
		const rising = failures.filter((f) => / rose to |has no baseline/.test(f));
		if (rising.length > 0) {
			console.error(
				'[ERROR] refusing to raise the structure baseline:\n    - ' + rising.join('\n    - ')
			);
			process.exit(1);
		}
		const out = { _comment: baseline._comment, ...measured };
		fs.writeFileSync(BASELINE_FILE, JSON.stringify(out, null, '\t') + '\n', 'utf8');
		console.log('[OK] structure folder bounds baseline lowered to the measurement.');
		return;
	}
	if (failures.length > 0) {
		console.error('\x1b[31m[ERROR] structure folder bounds (Rule B):\x1b[0m');
		for (const f of failures) console.error('    - ' + f);
		console.error(
			'    See docs/design/structure-plan.md; `node tools/audit/structure/census.cjs` measures the tree.'
		);
		process.exit(1);
	}
	console.log(
		`\x1b[32m[OK] structure folder bounds (Rule B): ${Object.keys(measured).length} counts at or below the ` +
			`baseline; ${census.mismatches.length} architecture folders on one or two drivers.\x1b[0m`
	);
}

main();
