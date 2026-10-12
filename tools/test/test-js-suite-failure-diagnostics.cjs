// tools/test/test-js-suite-failure-diagnostics.cjs

/** Verify failure receipts through the real runner without launching its suites. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'run-js-suite.cjs'), 'utf8');

function run(failure, options = {}) {
	const output = [];
	const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-js-timing-test-'));
	const stopped = {};
	let calls = 0;
	let outputBeforeSecondSpawn;
	let exitCode;
	let clock = 0;
	let appendCalls = 0;
	let thrown;
	try {
		vm.runInNewContext(
			source,
			{
				__dirname,
				require(name) {
					if (name === 'child_process')
						return {
							spawnSync() {
								const first = calls++ === 0;
								if (calls === 2) outputBeforeSecondSpawn = output.join('\n');
								if (options.spawnThrows && first) throw options.spawnThrows;
								return first ? failure : { status: 0 };
							}
						};
					if (name === 'path') return path;
					if (name === 'node:os') return { ...os, tmpdir: () => temporaryRoot };
					if (name === 'node:perf_hooks') return { performance: { now: () => (clock += 7.25) } };
					assert.equal(name, 'node:fs');
					return {
						...fs,
						appendFileSync(...args) {
							if (++appendCalls === options.failAppend) {
								throw Object.assign(new Error('synthetic timing disk failure'), { code: 'EIO' });
							}
							return fs.appendFileSync(...args);
						}
					};
				},
				console: { log: (...args) => output.push(args.join(' ')) },
				process: {
					argv: options.full ? ['node', 'run-js-suite.cjs', '--full'] : [],
					env: { RUNNER_TEMP: options.local ? undefined : temporaryRoot, GITHUB_SHA: options.sha },
					platform: process.platform,
					arch: process.arch,
					version: process.version,
					stdout: { write: (value) => output.push(value) },
					exit: (code) => {
						exitCode = code;
						throw stopped;
					}
				}
			},
			{ filename: 'run-js-suite.cjs' }
		);
	} catch (error) {
		if (error !== stopped) thrown = error;
	}
	try {
		const reports = fs
			.readdirSync(temporaryRoot)
			.map((name) => path.join(temporaryRoot, name, 'timings.ndjson'));
		assert.ok(reports.length <= 1, 'one invocation must produce at most one timing journal');
		const records = reports.length
			? fs.readFileSync(reports[0], 'utf8').trim().split('\n').map(JSON.parse)
			: [];
		return { output: output.join('\n'), records, calls, exitCode, thrown, outputBeforeSecondSpawn };
	} finally {
		assert.equal(fs.realpathSync(path.dirname(temporaryRoot)), fs.realpathSync(os.tmpdir()));
		assert.ok(path.basename(temporaryRoot).startsWith('ergopti-js-timing-test-'));
		fs.rmSync(temporaryRoot, { recursive: true });
	}
}

function failureOutput(failure) {
	const result = run(failure);
	assert.ifError(result.thrown);
	assert.ok(result.calls > 1, 'the real runner must execute its registered checks');
	assert.equal(result.exitCode, 1, 'a child failure must keep the aggregate red');
	return result.output;
}

const stack = Array.from({ length: 40 }, (_, i) => `    at syntheticFrame${i}`);
const long = failureOutput({
	status: 1,
	stdout: stack.join('\n'),
	stderr: ['Error: synthetic native failure ETIMEDOUT', ...stack, 'synthetic-terminal-detail'].join(
		'\r\n'
	)
});
assert.ok(
	long.includes('Error: synthetic native failure ETIMEDOUT'),
	'the error headline must survive a long stack'
);
assert.ok(long.includes('synthetic-terminal-detail'), 'retain the terminal detail');
assert.ok(long.includes('lines omitted'), 'report truncation explicitly');
assert.ok(!long.includes('syntheticFrame20'), 'bound the displayed stack');

const short = failureOutput({ status: 7, stdout: 'synthetic-single-line\n' });
assert.equal(
	short.split('synthetic-single-line').length - 1,
	1,
	'short diagnostics must not be duplicated by head and tail'
);
assert.ok(short.includes('status=7'), 'retain the native exit status');

const spawn = failureOutput({ status: null, signal: null, error: { code: 'ENOENT' } });
assert.ok(spawn.includes('ENOENT'), 'an empty-output spawn failure needs its error code');
const signal = failureOutput({ status: null, signal: 'SIGTERM' });
assert.ok(signal.includes('SIGTERM'), 'retain termination by signal');

const immediate = run({ status: 17, stderr: 'early-child-failure-detail' });
assert.ifError(immediate.thrown);
assert.equal(immediate.exitCode, 1);
assert.ok(
	immediate.outputBeforeSecondSpawn.includes('early-child-failure-detail'),
	'report a failed child before another check starts'
);
assert.ok(immediate.outputBeforeSecondSpawn.includes('reproduce:'));
assert.ok(immediate.outputBeforeSecondSpawn.includes('process: status=17'));
assert.equal(
	immediate.output.split('early-child-failure-detail').length - 1,
	1,
	'the final failure index must not repeat the child transcript'
);

const measured = run({ status: 7, stderr: 'private-child-output', error: { code: 'ETIMEDOUT' } });
assert.ifError(measured.thrown);
assert.equal(
	measured.records[0]?.type,
	'suite',
	'every run must create its timing journal by default'
);
const header = measured.records[0];
assert.equal(header.planned_count, measured.calls);
assert.equal(header.mode, 'default');
assert.equal(header.platform, process.platform);
assert.equal(header.architecture, process.arch);
assert.equal(header.node_version, process.version);
assert.equal(
	header.ci_source_sha,
	null,
	'a local working tree must not claim a CI source identity'
);
const cases = measured.records.filter((record) => record.type === 'result');
const starts = measured.records.filter((record) => record.type === 'start');
assert.equal(
	cases.length,
	measured.calls,
	'time every success and failure, without changing enrollment'
);
assert.equal(starts.length, measured.calls);
cases.forEach((result, index) => {
	assert.equal(result.ordinal, index + 1);
	assert.equal(result.duration_ms, 7.25, 'use the elapsed monotonic child clock');
	assert.equal(result.name, starts[index].name);
	assert.equal(result.ordinal, starts[index].ordinal);
	assert.ok(result.reproduce.length > 0, 'each measurement identifies its reproduction command');
});
assert.equal(cases[0].status, 'FAIL');
assert.equal(cases[0].exit_code, 7);
assert.equal(cases[0].error_code, 'ETIMEDOUT');
assert.ok(cases.slice(1).every((record) => record.status === 'PASS'));
assert.equal(measured.exitCode, 1);
const complete = measured.records.at(-1);
assert.equal(complete.type, 'complete');
assert.equal(complete.executed_count, measured.calls);
assert.equal(complete.failed, 1);
assert.equal(complete.passed, measured.calls - 1);
assert.equal(complete.child_duration_ms, measured.calls * 7.25);
assert.ok(complete.duration_ms >= complete.child_duration_ms);
assert.ok(
	!JSON.stringify(measured.records).includes('private-child-output'),
	'timing reports must not copy child output'
);
assert.ok(measured.output.includes('Slowest JS checks'));

const full = run({ status: 0 }, { full: true, sha: 'a'.repeat(40) });
assert.ifError(full.thrown);
assert.equal(full.exitCode, 0);
assert.equal(full.records[0].mode, 'full');
assert.equal(full.records[0].ci_source_sha, 'a'.repeat(40));
assert.ok(
	full.calls > measured.calls,
	'full mode still enrolls the optional property and mutation suites'
);
assert.equal(full.records.at(-1).failed, 0);
assert.ok(full.output.includes(`All ${full.calls} JS check(s) passed.`));

const interrupted = run({ status: 0 }, { failAppend: 4 });
assert.equal(interrupted.thrown?.code, 'EIO', 'a broken report write must fail loudly');
assert.equal(
	interrupted.exitCode,
	undefined,
	'do not publish an aggregate success after failed reporting'
);
assert.equal(interrupted.calls, 1, 'refuse further work when its start cannot be recorded');
assert.deepEqual(
	interrupted.records.map((record) => record.type),
	['suite', 'start', 'result']
);

const failedResult = run({ status: 0 }, { failAppend: 3 });
assert.equal(failedResult.thrown?.code, 'EIO');
assert.equal(failedResult.exitCode, undefined);
assert.equal(failedResult.calls, 1);
assert.deepEqual(
	failedResult.records.map((record) => record.type),
	['suite', 'start']
);

const thrownSpawn = run(null, {
	spawnThrows: Object.assign(new Error('synthetic spawn throw'), { code: 'EACCES' })
});
assert.ifError(thrownSpawn.thrown);
assert.equal(thrownSpawn.exitCode, 1);
assert.equal(thrownSpawn.records.find((record) => record.type === 'result').error_code, 'EACCES');
assert.equal(thrownSpawn.records.at(-1).failed, 1);
assert.ok(thrownSpawn.output.includes('synthetic spawn throw'), 'retain thrown spawn diagnostics');

const local = run({ status: 0 }, { local: true, sha: 'not-a-commit' });
assert.ifError(local.thrown);
assert.equal(local.exitCode, 0);
assert.equal(local.records[0].ci_source_sha, null);
assert.equal(local.records.at(-1).executed_count, local.calls);

for (const failure of [
	{ status: null, signal: 'SIGTERM' },
	{ status: 0, error: { code: 'ETIMEDOUT' } },
	{ status: 0, signal: 'SIGTERM' }
]) {
	const result = run(failure);
	assert.ifError(result.thrown);
	assert.equal(result.exitCode, 1, 'an error or signal cannot qualify as success');
	const first = result.records.find((record) => record.type === 'result');
	assert.equal(first.status, 'FAIL');
	assert.equal(first.exit_code, failure.status);
	assert.equal(first.signal, failure.signal ?? null);
	assert.equal(first.error_code, failure.error?.code ?? null);
}

const failedCompletion = run({ status: 0 }, { failAppend: 2 * measured.calls + 2 });
assert.equal(failedCompletion.thrown?.code, 'EIO');
assert.equal(failedCompletion.exitCode, undefined);
assert.equal(failedCompletion.calls, measured.calls);
assert.equal(
	failedCompletion.records.at(-1).type,
	'result',
	'a failed footer cannot certify completion'
);

const pipeline = require('./ci-pipeline.cjs');
const timingStep = pipeline.findStep(
	'Retain shared validation timings, including interrupted runs'
);
assert.equal(timingStep.file, '.github/workflows/ci-common.yml');
assert.equal(timingStep.job, 'shared-validation');
const upload = timingStep.body;
const core = pipeline.job('shared-validation');
assert(core.indexOf(upload) > core.indexOf(pipeline.step(core, 'Run shared validation suite')));
assert.equal(pipeline.stepField(upload, 'if'), "always() && matrix.suite == 'js'");
assert.equal(pipeline.stepField(upload, 'uses'), 'actions/upload-artifact@v4');
assert.match(upload, /^ {10}name: core-js-timings$/m);
assert.match(upload, /^ {10}path: \$\{\{ runner.temp \}\}\/ergopti-js-suite-\*\/timings\.ndjson$/m);
assert.doesNotMatch(
	upload,
	/assets-qualification/,
	'timings are not a native qualification receipt'
);

console.log('JS suite failure diagnostics: OK');
