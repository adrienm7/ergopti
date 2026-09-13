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
const fs = require('node:fs');
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
		assert.deepEqual([...actual].sort(), Object.keys(GATE_COMMANDS).filter((gate) => !GATE_COMMANDS[gate].coveredBy).sort(),
			'every independent gate must appear exactly once in the full plan');
		for (const [gate, spec] of Object.entries(GATE_COMMANDS)) {
			if (spec.coveredBy) assert(actual.includes(spec.coveredBy) && !actual.includes(gate),
				`${gate}: the covering suite must execute instead of its duplicate`);
		}
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
assert.deepEqual([...selectGates(['docs/audits/performance/ahk/2026_09_13/probe/report.md']).keys()], ['report-style'],
	'a historical performance report must not rebuild every driver or run the complete JS suite');
assert.deepEqual([...selectGates(['docs/audits/performance/ahk/report.md', 'tools/test/probe.cjs']).keys()], ['js'],
	'tool changes must retain the full JS gate, which already covers report style');
const mixedAhk = selectGates(['docs/audits/performance/ahk/report.md',
	'static/ergopti_plus/windows/modules/keylogger/keylogger_reader_db.ahk']);
for (const gate of ['report-style', 'ahk-encoding', 'ahk-suite', 'ahk-parse', 'ahk-e2e']) {
	assert(mixedAhk.has(gate), `mixed report and production AHK must retain ${gate}`);
}
for (const file of ['docs/memory/windows-ahk.md', '.agents/skills/verify-change/SKILL.md',
	'static/ergopti_plus/docs/architecture.md', 'docs/audits/ahk/report.md',
	'docs/audits/performance/probe.json']) {
	assert(selectGates([file]).has('js'), `${file}: non-report consumers retain the JS gate`);
}
assert.deepEqual(failures, [], 'explicit full verification cannot omit declared suites');
assert.equal(GATE_COMMANDS['report-style'].npm, 'lint:conventions:strict');
assert.match(fs.readFileSync(path.join(__dirname, 'run-js-suite.cjs'), 'utf8'),
	/args: \['run', '--silent', 'lint:conventions:strict'\]/,
	'the JS suite must retain the exact command that subsumes report-style');
console.log('verify-change full plan: complete inventory, diagnostic mode and narrow defaults passed.');
