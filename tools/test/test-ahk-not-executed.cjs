// tools/test/test-ahk-not-executed.cjs

/**
 * A case the host cannot run is reported as NOT EXECUTED by the AHK runner,
 * the execution manifest and the CI summary, and is never counted as a pass.
 * A capability-gated case on a capable or unknown host still runs, so its
 * failure stays a failure. The native half runs the real framework on Windows.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');
const { parseResults } = require('./report.cjs');

const REASON = 'host capability example is absent: the fixture probe reports it missing';
const skippedLine = (index, name) => `ok ${index} - ${name} # SKIP NOT EXECUTED: ${REASON}`;

function transcript(footer, second = skippedLine(2, 'gated case')) {
	return [
		'1..3',
		'RUNNING 1/3 - plain case',
		'ok 1 - plain case',
		'# duration_ms 1 1.000',
		'RUNNING 2/3 - gated case',
		second,
		'# duration_ms 2 0.500',
		'RUNNING 3/3 - failing case',
		'not ok 3 - failing case — boom [x.ahk:1]',
		'# duration_ms 3 2.000',
		footer,
		''
	].join('\n');
}

// The manifest counts a not-executed case apart, never as a pass.
const manifest = validateAhkSuiteManifest(transcript('# 1 passed, 1 failed, 1 not executed.'));
assert.equal(manifest.complete, true, manifest.errors.join('\n'));
assert.equal(manifest.passed, 1, 'a not-executed case is not a pass');
assert.equal(manifest.failed, 1);
assert.equal(manifest.not_executed, 1);
assert.deepEqual(manifest.not_executed_cases, [{ index: 2, name: 'gated case', reason: REASON }]);
assert.equal(manifest.executed[1].status, 'not executed');

// Every footer that folds the skipped case into another count is refused.
for (const footer of [
	'# 2 passed, 1 failed.',
	'# 1 passed, 1 failed.',
	'# 1 passed, 2 failed.',
	'# 1 passed, 1 failed, 2 not executed.',
	'# 1 passed, 1 failed, 0 not executed.'
]) {
	assert.equal(validateAhkSuiteManifest(transcript(footer)).complete, false, footer);
}
// A marker without a reason, or on a foreign name, is refused.
assert.equal(
	validateAhkSuiteManifest(
		transcript('# 1 passed, 1 failed, 1 not executed.', 'ok 2 - gated case # SKIP NOT EXECUTED: ')
	).complete,
	false
);
assert.equal(
	validateAhkSuiteManifest(
		transcript('# 1 passed, 1 failed, 1 not executed.', skippedLine(2, 'other case'))
	).complete,
	false
);
// A failing line that merely quotes the marker stays a failure.
const quoted = validateAhkSuiteManifest(
	transcript(
		'# 1 passed, 2 failed.',
		`not ok 2 - gated case — saw " # SKIP NOT EXECUTED: x" [y.ahk:2]`
	)
);
assert.equal(quoted.complete, true, quoted.errors.join('\n'));
assert.equal(quoted.failed, 2);
assert.equal(quoted.not_executed, 0);

// The CI reporter lists it as NOT EXECUTED and keeps it out of the pass count.
const report = parseResults(transcript('# 1 passed, 1 failed, 1 not executed.'));
assert.equal(report.passed, 1);
assert.equal(report.failed, 1);
assert.equal(report.not_executed_count, 1);
assert.deepEqual(report.not_executed, [`gated case: ${REASON}`]);
assert.deepEqual(report.failures, ['failing case — boom [x.ahk:1]']);
const reporterDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-not-executed-report-'));
try {
	const input = path.join(reporterDir, 'tap.txt');
	fs.writeFileSync(
		input,
		transcript('# 1 passed, 0 failed, 1 not executed.', skippedLine(2, 'gated case')).replace(
			/RUNNING 3\/3[\s\S]*?# duration_ms 3 2\.000\n/,
			''
		)
	);
	const json = path.join(reporterDir, 'report.json');
	const summary = path.join(reporterDir, 'summary.md');
	const run = spawnSync(
		process.execPath,
		[
			path.join(__dirname, 'report.cjs'),
			'--name',
			'windows-ahk',
			'--json',
			json,
			'--',
			'PARSE_FILE',
			input
		],
		{
			encoding: 'utf8',
			env: { ...process.env, GITHUB_ACTIONS: 'true', GITHUB_STEP_SUMMARY: summary }
		}
	);
	assert.equal(run.status, 0, run.stdout + run.stderr);
	assert.match(
		run.stdout,
		/::warning title=windows-ahk test NOT EXECUTED::gated case: host capability example/
	);
	assert.match(run.stdout, /NOT EXECUTED\x1b\[0m — 1 passed, 0 failed, 1 NOT EXECUTED/);
	assert.doesNotMatch(
		run.stdout,
		/\bPASS\b/,
		'a run with a not-executed case is never reported as PASS'
	);
	assert.match(fs.readFileSync(summary, 'utf8'), /1 NOT EXECUTED on this host \(not passed\)/);
	const payload = JSON.parse(fs.readFileSync(json, 'utf8'));
	assert.equal(payload.passed, 1);
	assert.equal(payload.not_executed, 1);
	assert.deepEqual(payload.not_executed_cases, [`gated case: ${REASON}`]);
} finally {
	fs.rmSync(reporterDir, { recursive: true, force: true });
}

// The real runner: an incapable host is NOT EXECUTED, capable and unknown hosts fail.
function nativeRun() {
	if (process.platform !== 'win32') {
		console.log('SKIP (not executed): native AHK not-executed runner: requires Windows');
		return;
	}
	const ahk = [
		'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe',
		'C:/AutoHotkey/AutoHotkey64.exe'
	].find((candidate) => fs.existsSync(candidate));
	assert.ok(ahk, 'the native runner check requires the actual AutoHotkey v2 binary on Windows');
	const tests = path.resolve(__dirname, '../../static/ergopti_plus/windows/tests');
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-not-executed-'));
	try {
		const fixtures = path.join(temporary, 'fixtures');
		fs.mkdirSync(fixtures);
		for (const name of ['framework_not_executed_fixture.ahk', 'host_capability_gate.ahk'])
			fs.copyFileSync(path.join(tests, 'fixtures', name), path.join(fixtures, name));
		fs.copyFileSync(
			path.join(tests, 'test_framework.ahk'),
			path.join(temporary, 'test_framework.ahk')
		);
		const results = path.join(temporary, 'results.txt');
		const run = spawnSync(
			ahk,
			['/ErrorStdOut', path.join(fixtures, 'framework_not_executed_fixture.ahk')],
			{
				windowsHide: true,
				encoding: 'utf8',
				timeout: 15000,
				env: { ...process.env, TEMP: temporary, TMP: temporary, ERGOPTI_AHK_RESULTS_FILE: results }
			}
		);
		assert.ifError(run.error);
		assert.equal(
			run.status,
			1,
			`a capable or unknown host must still fail: ${run.stdout}\n${run.stderr}`
		);
		const tap = fs.readFileSync(results, 'utf8');
		assert.match(tap, /^ok 1 - not-executed fixture pass\r?$/m);
		assert.match(
			tap,
			/^ok 2 - not-executed fixture host lacks the capability # SKIP NOT EXECUTED: host capability example is absent: the fixture probe reports it missing\r?$/m
		);
		assert.match(
			tap,
			/^not ok 3 - not-executed fixture capable host still fails — intentional gated fixture failure/m
		);
		assert.match(
			tap,
			/^not ok 4 - not-executed fixture unknown capability still runs — intentional gated fixture failure/m
		);
		assert.match(tap, /^# NOT EXECUTED on this host: 1 case\(s\), none counted as passed:\r?$/m);
		assert.match(tap, /^# 1 passed, 2 failed, 1 not executed\.\r?$/m);
		const native = validateAhkSuiteManifest(tap);
		assert.equal(native.complete, true, native.errors.join('\n'));
		assert.equal(native.passed, 1);
		assert.equal(native.failed, 2);
		assert.equal(native.not_executed, 1);
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}
nativeRun();

console.log('AHK not-executed reporting: ok');
