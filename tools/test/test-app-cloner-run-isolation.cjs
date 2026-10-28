// tools/test/test-app-cloner-run-isolation.cjs

/**
 * ============================================================================
 * MODULE: App Cloner Run Isolation - Source Contract Guard
 * DESCRIPTION:
 * Verifies that each App Cloner run owns a private temporary directory and
 * that result, status, and completion files never use shared /tmp names.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE_PATH = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'apps',
	'App Cloner.app',
	'Contents',
	'Resources',
	'ShortcutBuilder.applescript'
);
const source = fs.readFileSync(SOURCE_PATH, 'utf8');
const results = [];

function test(name, ok, detail = '') {
	results.push({ name, ok, detail });
}

function count(haystack, needle) {
	return haystack.split(needle).length - 1;
}

function contract(candidate) {
	return {
		privateRoot: candidate.includes('mktemp -d \\"${TMPDIR:-/tmp}/ergopti-appcloner.XXXXXXXX\\"'),
		derivedFiles:
			candidate.includes('set resultPath to runDir & "/result"') &&
			candidate.includes('set statusPath to runDir & "/status"') &&
			candidate.includes('set donePath to runDir & "/done"'),
		quotedBoundaries:
			count(candidate, 'quoted form of resultPath') >= 3 &&
			count(candidate, 'quoted form of statusPath') >= 2 &&
			count(candidate, 'quoted form of donePath') >= 2,
		noSharedSentinels:
			!candidate.includes('/tmp/appcloner_done') && !candidate.includes('/tmp/appcloner_result')
	};
}

const actual = contract(source);
test(
	'each run allocates a private temporary directory under TMPDIR',
	actual.privateRoot,
	JSON.stringify(actual)
);
test(
	'result, status, and completion paths derive from the private directory',
	actual.derivedFiles && actual.quotedBoundaries,
	JSON.stringify(actual)
);
test(
	'shared predictable App Cloner sentinel names are absent',
	actual.noSharedSentinels,
	JSON.stringify(actual)
);

const fixedSentinelMutant = source
	.replace(/quoted form of donePath/g, '"/tmp/appcloner_done"')
	.replace(/quoted form of resultPath/g, '"/tmp/appcloner_result"');
const mutant = contract(fixedSentinelMutant);
test(
	'the guard rejects a regression to fixed cross-run sentinel paths',
	!mutant.noSharedSentinels && !mutant.quotedBoundaries,
	JSON.stringify(mutant)
);

if (process.platform !== 'win32') {
	const bash = bashExecutable();
	const produced = spawnSync(
		pythonExecutable(),
		[
			path.join(ROOT, 'tools', 'test', 'lib', 'app-cloner-worker-signal-probe.py'),
			SOURCE_PATH,
			bash
		],
		{ encoding: 'utf8', timeout: 30000 }
	);
	if (produced.error || produced.status !== 0) {
		throw new Error(
			`The actual worker signal probe did not execute: ${produced.error?.message || ''}\n${produced.stderr || ''}`
		);
	}
	const report = JSON.parse(produced.stdout);
	const names = [
		'success',
		'failure',
		'limited-success',
		'limited-failure',
		'child-signal',
		'limited-child-signal'
	];
	const shells = ['/bin/sh', bash];
	const expected = new Set(shells.flatMap((shell) => names.map((name) => `${shell}:${name}`)));
	const complete =
		report.cases.length === expected.size &&
		new Set(report.cases.map((row) => `${row.shell}:${row.name}`)).size === expected.size &&
		report.cases.every((row) => expected.has(`${row.shell}:${row.name}`));
	const completion = report.cases.filter((row) => row.name === 'limited-success');
	test(
		'the worker publishes completion when a file-size limit refuses its status write',
		complete &&
			completion.length === shells.length &&
			completion.every(
				(row) =>
					row.ownership_closed === true &&
					row.wait_status === 0 &&
					row.done &&
					row.status_text === ''
			),
		JSON.stringify(completion)
	);
	const uncaught = report.uncaught_supervisor_mutant;
	const signalStatus = 128 + require('node:os').constants.signals.SIGXFSZ;
	test(
		'the guard rejects a worker that SIGXFSZ can kill before completion',
		uncaught.length === shells.length &&
			new Set(uncaught.map((row) => row.shell)).size === shells.length &&
			uncaught.every(
				(row) =>
					shells.includes(row.shell) &&
					row.name === 'uncaught-supervisor-mutant' &&
					row.ownership_closed === true &&
					row.wait_status === signalStatus &&
					!row.done &&
					row.status_present &&
					row.status_text === ''
			),
		JSON.stringify(uncaught)
	);
	const negatives = [
		'missing-block',
		'ambiguous-block',
		'unknown-operand',
		'missing-operand',
		'duplicate-operand',
		'unquoted-path',
		'missing-binding',
		'trailing-operand',
		'trailing-concatenation',
		'unsupported-escape'
	];
	test(
		'the actual worker expression parser rejects every incomplete or ambiguous source boundary',
		report.parser_negatives.length === negatives.length &&
			new Set(report.parser_negatives.map((row) => row.name)).size === negatives.length &&
			report.parser_negatives.every(
				(row) => negatives.includes(row.name) && row.rejected && row.error.length > 0
			),
		JSON.stringify(report.parser_negatives)
	);
	const ordinary = report.cases.filter((row) => row.name === 'success' || row.name === 'failure');
	test(
		'the actual background worker preserves ordinary success and nonzero helper status',
		complete &&
			ordinary.length === shells.length * 2 &&
			ordinary.every(
				(row) =>
					row.ownership_closed === true &&
					row.wait_status === 0 &&
					row.done &&
					row.result_present &&
					row.status_present &&
					row.status_text === (row.name === 'success' ? '0\n' : '7\n') &&
					!row.survived
			),
		JSON.stringify(ordinary)
	);
	const limited = report.cases.filter((row) => row.limited);
	test(
		'a real zero file-size limit cannot kill supervisor completion or falsely publish success',
		complete &&
			limited.length === shells.length * 3 &&
			limited.every(
				(row) =>
					row.ownership_closed === true &&
					row.wait_status === 0 &&
					row.done &&
					row.result_present &&
					row.status_present &&
					row.status_text === '' &&
					!row.survived
			),
		JSON.stringify(limited)
	);
	const ignored = report.before_child_mutant;
	const ignoredExpected = new Set(
		shells.flatMap((shell) => [false, true].map((limited) => `${shell}:${limited}`))
	);
	const ignoredComplete =
		ignored.length === ignoredExpected.size &&
		new Set(ignored.map((row) => `${row.shell}:${row.limited}`)).size === ignoredExpected.size &&
		ignored.every(
			(row) =>
				row.name === 'before-child-mutant' &&
				typeof row.limited === 'boolean' &&
				ignoredExpected.has(`${row.shell}:${row.limited}`)
		);
	const signalled = report.cases.filter((row) => row.kind === 'signal');

	test(
		'the helper retains default SIGXFSZ behavior and the before-child ignore mutant is rejected',
		complete &&
			signalled.length === shells.length * 2 &&
			signalled.every(
				(row) =>
					row.ownership_closed === true &&
					row.wait_status === 0 &&
					row.done &&
					row.result_present &&
					row.status_present &&
					!row.survived &&
					row.status_text === (row.limited ? '' : `${signalStatus}\n`)
			) &&
			ignoredComplete &&
			ignored.every(
				(row) =>
					row.ownership_closed === true &&
					row.wait_status === 0 &&
					row.done &&
					row.survived &&
					row.status_text === (row.limited ? '' : '0\n')
			),
		JSON.stringify({ actual: signalled, mutant: report.before_child_mutant })
	);
}

console.log('TAP version 14');
console.log(`1..${results.length}`);
results.forEach((result, index) => {
	console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
	if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
});
console.log(`# passed: ${results.filter((result) => result.ok).length}/${results.length}`);
if (results.some((result) => !result.ok)) process.exitCode = 1;
