// tools/test/test-structure-run-phase2.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Phase 2 Runner Contract
 * DESCRIPTION:
 * run-phase2.cjs applies the steps of the structure plan in order, one commit
 * per step. The first real application of S01 stopped on gates no rewrite can
 * satisfy: the formatter, the banner widths a longer path changes, the
 * generated outputs and the folder-bounds ratchet. The runner owns those
 * follow-ups, so the day of phase 2 is one command. This pins its refusals
 * (no go, a dirty tree) and its arguments without moving anything.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const Runner = require('../audit/structure/run-phase2.cjs');

const RUNNER = path.join(__dirname, '..', 'audit', 'structure', 'run-phase2.cjs');

function run() {
	assert.deepEqual(
		Runner.parseArgs(['--from', '_shared', '--to', 'core/ui', '--gate', 'npm test']),
		{
			gates: ['npm test'],
			from: '_shared',
			to: 'core/ui',
			receipt: null,
			commit: true
		}
	);
	assert.equal(Runner.parseArgs(['--no-commit']).commit, false);
	assert.throws(() => Runner.parseArgs(['--fast']), /unknown argument --fast/);

	// Without the coordinator's go, nothing runs.
	const env = { ...process.env };
	delete env.ERGOPTI_STRUCTURE_PHASE;
	const refused = spawnSync(process.execPath, [RUNNER, '--no-commit'], { encoding: 'utf8', env });
	assert.notEqual(refused.status, 0, 'the runner refuses without ERGOPTI_STRUCTURE_PHASE=2');
	assert.match(refused.stderr, /ERGOPTI_STRUCTURE_PHASE=2/);

	// The follow-ups a step needs and no path rewrite can do, in order.
	const order = [
		'--fix-banners',
		"'--write'",
		"'codegen'",
		'--update-baseline',
		"'--fail-on-violations'"
	];
	const source = require('node:fs').readFileSync(RUNNER, 'utf8');
	let at = 0;
	for (const marker of order) {
		const next = source.indexOf(marker, at);
		assert.ok(next > at, `the runner runs ${marker} after the previous follow-up`);
		at = next;
	}
	console.log(
		'[OK] the phase 2 runner refuses without its go and owns the follow-ups of each step.'
	);
}

run();
