// tools/test/test-ahk-suite-manifest.cjs

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');
const pipeline = require('./ci-pipeline.cjs');

// A completed TAP receipt cannot compensate for a missing native exit receipt.
// Start-Process without -Wait must retain its handle before the child exits.
const processReceipts = [];
for (const [job, name] of [
	['test-ahk', 'Run AHK test suite'],
	['e2e-ahk', 'Run E2E suite (Strategy A — pure engine injection)']
]) {
	const script = pipeline.runOf(pipeline.step(pipeline.job(job), name)).join('\n');
	const start = /\$proc = Start-Process[^\n]+\n([\s\S]*?)\$fstream =/.exec(script);
	assert.ok(start, `${name}: asynchronous process start must exist`);
	assert.match(
		start[1],
		/\$null = \$proc\.Handle/,
		`${name}: retain the native handle before polling`
	);
	const finish = /\$proc\.WaitForExit\(\)\s*\n\s*\$exit = \$proc\.ExitCode/.exec(script);
	assert.ok(finish, `${name}: join the process before reading its exit receipt`);
	processReceipts.push({ name, start: start[0].replace(/\$fstream =$/, ''), finish: finish[0] });
}

const ahkIndex = process.argv.indexOf('--ahk');
if (ahkIndex >= 0) {
	assert.equal(process.platform, 'win32', 'native exit receipt probes require Windows');
	const ahk = process.argv[ahkIndex + 1];
	assert.ok(ahk && fs.existsSync(ahk), 'native exit receipt probes require the actual AHK binary');
	const probeRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-exit-'));
	const quote = (value) => `'${value.replaceAll("'", "''")}'`;
	try {
		for (const receipt of processReceipts) {
			for (const expected of [0, 7]) {
				const runner = path.join(probeRoot, `exit-${expected}.ahk`);
				fs.writeFileSync(
					runner,
					`\uFEFF#Requires AutoHotkey v2.0\nSleep(200)\nExitApp(${expected})\n`
				);
				const command = [
					"$ErrorActionPreference = 'Stop'",
					`$ahk = ${quote(ahk)}; $runner = ${quote(runner)}`,
					receipt.start,
					'while (-not $proc.HasExited) { Start-Sleep -Milliseconds 10 }',
					receipt.finish,
					'if ($null -eq $exit) { throw "Native exit receipt is unavailable" }',
					'Write-Output $exit'
				].join('\n');
				const probe = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', command], {
					encoding: 'utf8',
					timeout: 30000
				});
				assert.equal(
					probe.status,
					0,
					`${receipt.name}: ${probe.stderr || probe.error || probe.stdout}`
				);
				assert.equal(
					probe.stdout.trim(),
					String(expected),
					`${receipt.name}: preserve native exit ${expected}`
				);
			}
		}
	} catch (error) {
		if (process.env.GITHUB_ACTIONS === 'true') {
			const message = error.message
				.replaceAll('%', '%25')
				.replaceAll('\r', '%0D')
				.replaceAll('\n', '%0A');
			console.error(`::error::AHK native exit probe failed: ${message}`);
		}
		throw error;
	} finally {
		fs.rmSync(probeRoot, { recursive: true, force: true });
	}
}

const beforeSlowTail = [
	'\uFEFF1..3',
	'RUNNING 1/3 - fast head',
	'ok 1 - fast head',
	'RUNNING 2/3 - ordinary middle',
	'ok 2 - ordinary middle',
	'# 2 passed, 0 failed.'
].join('\n');
const early = validateAhkSuiteManifest(beforeSlowTail);
assert.equal(
	early.complete,
	false,
	'a green-looking footer must not complete before the slow tail'
);
assert.match(early.errors.join('\n'), /planned test 3\/3 never started/);

const afterSlowTail = [
	'1..3',
	'RUNNING 1/3 - fast head',
	'ok 1 - fast head',
	'RUNNING 2/3 - ordinary middle',
	'ok 2 - ordinary middle',
	'RUNNING 3/3 - deliberately slow tail',
	'ok 3 - deliberately slow tail',
	'# 3 passed, 0 failed.'
].join('\n');
const complete = validateAhkSuiteManifest(afterSlowTail);
assert.equal(complete.complete, true, complete.errors.join('\n'));
assert.deepEqual(
	complete.executed.map((entry) => entry.index),
	[1, 2, 3]
);

for (const [status, detail] of [
	['ok', 'a different case'],
	['ok', 'fast head — unexpected suffix'],
	['not ok', 'a different case — injected failure'],
	['not ok', 'fast header — injected failure']
]) {
	const source = afterSlowTail
		.replace('ok 1 - fast head', `${status} 1 - ${detail}`)
		.replace(
			'# 3 passed, 0 failed.',
			status === 'ok' ? '# 3 passed, 0 failed.' : '# 2 passed, 1 failed.'
		);
	const mismatch = validateAhkSuiteManifest(source);
	assert.equal(
		mismatch.complete,
		false,
		`terminal identity mismatch must fail: ${status} ${detail}`
	);
	assert.match(mismatch.errors.join('\n'), /result ordinal 1.*name/);
}

const punctuationName = 'case — with diagnostic-like punctuation';
const punctuationSource = afterSlowTail.replaceAll('fast head', punctuationName);
assert.equal(
	validateAhkSuiteManifest(punctuationSource).complete,
	true,
	'a delimiter inside a passing test name is part of its identity'
);
const punctuationFailure = punctuationSource
	.replace(`ok 1 - ${punctuationName}`, `not ok 1 - ${punctuationName} — injected failure`)
	.replace('# 3 passed, 0 failed.', '# 2 passed, 1 failed.');
assert.equal(
	validateAhkSuiteManifest(punctuationFailure).complete,
	true,
	'failed results must match the full registered name before diagnostic text'
);

const missingTerminal = validateAhkSuiteManifest(
	afterSlowTail.replace('ok 3 - deliberately slow tail\n', '')
);
assert.equal(
	missingTerminal.complete,
	false,
	'RUNNING without a terminal result must fail the manifest'
);

assert.equal(complete.timed_count, 0, 'legacy transcripts have no measured cases');
assert.deepEqual(
	complete.executed.map((entry) => entry.duration_ms),
	[null, null, null]
);

const timedSource = afterSlowTail
	.replace('ok 1 - fast head', 'ok 1 - fast head\n# duration_ms 1 0')
	.replace('ok 2 - ordinary middle', 'ok 2 - ordinary middle\n# duration_ms 2 12.375')
	.replace(
		'ok 3 - deliberately slow tail',
		'ok 3 - deliberately slow tail\n# duration_ms 3 2500.00'
	);
const timed = validateAhkSuiteManifest(timedSource);
assert.equal(timed.complete, true, timed.errors.join('\n'));
assert.equal(timed.timed_count, 3);
assert.deepEqual(
	timed.executed.map((entry) => entry.duration_ms),
	[0, 12.375, 2500]
);

function rejectsTiming(source, label) {
	const result = validateAhkSuiteManifest(source);
	assert.equal(result.complete, false, label);
	assert.ok(result.errors.length > 0, `${label}: rejection must explain the failure`);
}
rejectsTiming(timedSource.replace('# duration_ms 2 12.375\n', ''), 'mixed timed and untimed cases');
rejectsTiming(`${timedSource}\n# duration_ms 1 0`, 'duplicate timing');
rejectsTiming(`${timedSource}\n# duration_ms 4 1`, 'timing outside the plan');
rejectsTiming(`${timedSource}\n# duration_ms 0 1`, 'zero timing ordinal');
rejectsTiming(
	timedSource.replace('ok 2 - ordinary middle\n', ''),
	'timing without a terminal result'
);
rejectsTiming(
	timedSource.replace(
		'ok 2 - ordinary middle\n# duration_ms 2 12.375',
		'# duration_ms 2 12.375\nok 2 - ordinary middle'
	),
	'timing before its terminal result'
);
for (const value of [
	'NaN',
	'Infinity',
	'-1',
	'-0.5',
	'1e3',
	'1ms',
	'',
	'1 2',
	'.5',
	'1.',
	'9'.repeat(400)
]) {
	rejectsTiming(
		timedSource.replace('# duration_ms 2 12.375', `# duration_ms 2 ${value}`),
		`invalid duration ${value}`
	);
}
for (const comment of [
	'# duration_ms',
	'# duration_ms x 1',
	'# duration_ms 1.5 1',
	'# duration_ms 2'
]) {
	rejectsTiming(
		`${afterSlowTail}\n${comment}`,
		`malformed timing must not enable legacy mode: ${comment}`
	);
}
const failedTimed = validateAhkSuiteManifest(
	timedSource
		.replace('ok 2 - ordinary middle', 'not ok 2 - ordinary middle — injected failure')
		.replace('# 3 passed, 0 failed.', '# 2 passed, 1 failed.')
);
assert.equal(failedTimed.complete, true, failedTimed.errors.join('\n'));
assert.equal(failedTimed.failed, 1);
assert.equal(failedTimed.executed[1].duration_ms, 12.375, 'failed cases are measured too');

require('./support/ahk-timing-runtime.cjs')();

const diagnosticFixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-diagnostics-'));
try {
	const input = path.join(diagnosticFixture, 'results.tap');
	const output = path.join(diagnosticFixture, 'manifest.json');
	fs.writeFileSync(
		input,
		[
			'1..1',
			'RUNNING 1/1 - name with 100% identity',
			'ok 1 - a different identity',
			'# 1 passed, 0 failed.'
		].join('\n')
	);
	const result = spawnSync(
		process.execPath,
		[path.join(__dirname, 'validate-ahk-suite-manifest.cjs'), '--input', input, '--json', output],
		{ encoding: 'utf8', env: { ...process.env, GITHUB_ACTIONS: 'true' } }
	);
	assert.equal(result.status, 1, 'a green test count cannot override an invalid execution receipt');
	assert.match(
		result.stderr,
		/^::error::AHK execution manifest incomplete/m,
		'GitHub annotations must expose the actual receipt failure without downloading logs'
	);
	assert.match(
		result.stderr,
		/^::error::.*result ordinal 1.*100%25 identity/m,
		'the exact mismatching identity must be annotated, with reserved percent signs escaped'
	);
	const manifest = JSON.parse(fs.readFileSync(output, 'utf8'));
	assert.equal(manifest.complete, false);
	assert.equal(manifest.passed, 1);
	assert.equal(manifest.failed, 0);
	assert.match(manifest.errors.join('\n'), /result ordinal 1/);
} finally {
	fs.rmSync(diagnosticFixture, { recursive: true, force: true });
}

console.log('AHK suite execution manifest: completeness and per-case timing guards passed.');
