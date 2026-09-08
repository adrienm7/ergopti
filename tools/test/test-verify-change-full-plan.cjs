// tools/test/test-verify-change-full-plan.cjs

/**
 * ==============================================================================
 * MODULE: Full Verification Plan Regression Tests
 * DESCRIPTION:
 * Runs the real planning CLI without executing any platform suite. Explicit
 * full audits must include the complete command inventory, while ordinary
 * verification remains scoped to the change.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { GATE_COMMANDS, selectGates } = require('./verify-change.cjs');

const root = path.resolve(__dirname, '../..');
const cli = path.join(__dirname, 'verify-change.cjs');

function plan(args) {
	const result = spawnSync(process.execPath, [cli, '--plan', '--range=HEAD..HEAD', ...args], {
		cwd: root, encoding: 'utf8', timeout: 10000,
	});
	assert.ifError(result.error);
	assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
	assert(!result.stdout.includes('=== js ==='), 'planning must never execute a gate');
	return [...result.stdout.matchAll(/^   - ([\w-]+)/gm)].map((match) => match[1]);
}

const failures = [];
for (const args of [['--all'], ['--all', '--diagnose']]) {
	try {
		const actual = plan(args);
		assert(actual.includes('hs') && actual.includes('hs-e2e'), 'a full audit must exercise Hammerspoon');
		assert.deepEqual([...actual].sort(), Object.keys(GATE_COMMANDS).sort(),
			'every declared gate must appear exactly once in the full plan');
		for (const driver of ['hs', 'linux']) {
			assert(actual.indexOf('js') < actual.indexOf(driver), 'generated writers must finish before driver readers');
		}
	} catch (error) {
		failures.push(`${args.join(' ')}: ${error.message}`);
	}
}
assert.deepEqual(plan([]), [], 'ordinary verification must not expand an empty change into a full audit');
assert.deepEqual([...selectGates(['static/ergopti_plus/macos/tests/unit/test_probe.lua']).keys()], ['hs'],
	'a focused Hammerspoon test change must not select unrelated platform suites');
assert.deepEqual(failures, [], 'explicit full verification cannot omit declared suites');
console.log('verify-change full plan: complete inventory, diagnostic mode and narrow defaults passed.');
