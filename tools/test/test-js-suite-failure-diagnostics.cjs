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
	const progressAtSpawn = [];
	let pendingLine = '';
	let lastCompletedLine = '';
	function captureBytes(bytes) {
		const lines = (pendingLine + bytes).split('\n');
		pendingLine = lines.pop();
		if (lines.length) lastCompletedLine = lines.at(-1);
	}
	const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-js-timing-test-'));
	const stopped = {};
	let calls = 0;
	let outputBeforeSecondSpawn;
	let exitCode;
	let clock = 0;
	let appendCalls = 0;
	let writeCalls = 0;
	let spawnOptions;
	let thrown;
	try {
		vm.runInNewContext(
			source,
			{
				__dirname,
				require(name) {
					if (
						[
							'./lib/js-feature-inventory.cjs',
							'./lib/js-suite-spawn.cjs',
							'./lib/host-capabilities.cjs'
						].includes(name)
					)
						return require(name);
					if (name === 'child_process')
						return {
							spawnSync(_command, _args, settings) {
								const first = calls++ === 0;
								if (first) spawnOptions = settings;
								progressAtSpawn.push({ line: lastCompletedLine, pending: pendingLine });
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
						writeFileSync(...args) {
							if (++writeCalls === options.failWrite) {
								throw Object.assign(new Error('synthetic capture disk failure'), { code: 'EIO' });
							}
							return fs.writeFileSync(...args);
						},
						appendFileSync(...args) {
							if (++appendCalls === options.failAppend) {
								throw Object.assign(new Error('synthetic timing disk failure'), { code: 'EIO' });
							}
							return fs.appendFileSync(...args);
						}
					};
				},
				console: {
					log: (...args) => {
						const line = args.join(' ');
						output.push(line);
						captureBytes(line + '\n');
					}
				},
				process: {
					execPath: process.execPath,
					argv: options.full ? ['node', 'run-js-suite.cjs', '--full'] : [],
					env: { RUNNER_TEMP: options.local ? undefined : temporaryRoot, GITHUB_SHA: options.sha },
					platform: process.platform,
					arch: process.arch,
					version: process.version,
					stdout: {
						write: (value) => {
							output.push(value);
							captureBytes(value);
						}
					},
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
		const failureRoot = reports.length ? path.join(path.dirname(reports[0]), 'failures') : '';
		const captures =
			failureRoot && fs.existsSync(failureRoot)
				? fs.readdirSync(failureRoot).map((id) => {
						const directory = path.join(failureRoot, id);
						return {
							id,
							directory,
							files: Object.fromEntries(
								fs
									.readdirSync(directory)
									.map((name) => [name, fs.readFileSync(path.join(directory, name), 'utf8')])
							)
						};
					})
				: [];
		return {
			captures,
			spawnOptions,
			output: output.join('\n'),
			records,
			calls,
			exitCode,
			thrown,
			outputBeforeSecondSpawn,
			progressAtSpawn
		};
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
const middleCause = 'Error: hidden middle cause é🙂';
const longFailure = {
	status: 1,
	stdout: stack.join('\n'),
	stderr: [
		'Error: synthetic native failure ETIMEDOUT',
		...stack.slice(0, 20),
		middleCause,
		...stack.slice(20),
		'synthetic-terminal-detail'
	].join('\r\n')
};
const retained = run(longFailure);
assert.ifError(retained.thrown);
assert.ok(retained.calls > 1, 'the real runner must execute its registered checks');
assert.equal(retained.exitCode, 1, 'a child failure must keep the aggregate red');
const long = retained.output;
assert.ok(
	long.includes('Error: synthetic native failure ETIMEDOUT'),
	'the error headline must survive a long stack'
);
assert.ok(long.includes('synthetic-terminal-detail'), 'retain the terminal detail');
assert.ok(long.includes('lines omitted'), 'report truncation explicitly');
assert.ok(!long.includes('syntheticFrame20'), 'bound the displayed stack');
assert.ok(!long.includes(middleCause), 'the middle cause lies outside the bounded console preview');
assert.equal(retained.captures.length, 1, 'only the failed check retains raw output');
const captured = retained.captures[0];
assert.ok(
	captured.files['stderr.txt'].includes(middleCause),
	'the original hidden exception remains available'
);
assert.equal(captured.files['stdout.txt'], longFailure.stdout);
assert.equal(captured.files['stderr.txt'], longFailure.stderr);
assert.ok(
	captured.files['stderr.txt'].includes('syntheticFrame20'),
	'retain the original missing middle'
);
const captureReceipt = JSON.parse(captured.files['receipt.json']);
const failedTiming = retained.records.find((record) => record.type === 'result');
for (const field of [
	'ordinal',
	'check_id',
	'global_ordinal',
	'name',
	'reproduce',
	'status',
	'exit_code',
	'signal',
	'error_code'
])
	assert.equal(captureReceipt[field], failedTiming[field]);
assert.equal(
	captureReceipt.capture.stdout.captured_utf8_bytes,
	Buffer.byteLength(longFailure.stdout)
);
assert.equal(
	captureReceipt.capture.stderr.captured_utf8_bytes,
	Buffer.byteLength(longFailure.stderr)
);
assert.equal(captureReceipt.capture.max_buffer_bytes, retained.spawnOptions.maxBuffer);
assert.equal(retained.spawnOptions.maxBuffer, 1024 * 1024, 'preserve the existing capture bound');
assert.equal(captureReceipt.capture.child_output_completeness, 'unknown');
assert.equal(captureReceipt.capture.spawn_error, false);
assert.ok(retained.outputBeforeSecondSpawn.includes(captured.directory));
assert.ok(
	!JSON.stringify(retained.records).includes('syntheticFrame20'),
	'raw text stays out of timings'
);

const overflow = run({
	status: null,
	error: { code: 'ENOBUFS' },
	stdout: 'captured é🙂 prefix',
	stderr: ''
});
assert.ifError(overflow.thrown);
assert.equal(overflow.exitCode, 1);
const overflowReceipt = JSON.parse(overflow.captures[0].files['receipt.json']);
assert.equal(overflowReceipt.error_code, 'ENOBUFS');
assert.equal(overflowReceipt.capture.spawn_error, true);
assert.equal(overflowReceipt.capture.child_output_completeness, 'unknown');
assert.equal(
	overflowReceipt.capture.stdout.captured_utf8_bytes,
	Buffer.byteLength('captured é🙂 prefix')
);
assert.equal(overflowReceipt.capture.stderr.captured_utf8_bytes, 0);
assert.equal(overflow.captures[0].files['stdout.txt'], 'captured é🙂 prefix');
assert.ok(overflow.output.includes('Uncaptured or child-truncated output is unknown.'));

for (const failWrite of [1, 2, 3]) {
	const broken = run(
		{ status: 7, stderr: 'original failure survives capture write refusal' },
		{ failWrite }
	);
	assert.equal(broken.thrown?.code, 'EIO');
	assert.equal(broken.exitCode, undefined, 'failed retention cannot publish an aggregate verdict');
	assert.equal(broken.calls, 1, 'stop before starting another check after retention fails');
	assert.equal(broken.records.at(-1).type, 'result');
	assert.equal(broken.records.at(-1).status, 'FAIL');
	assert.ok(broken.output.includes('original failure survives capture write refusal'));
	assert.equal(
		broken.captures[0].files['receipt.json'],
		undefined,
		'no receipt before both text writes succeed'
	);
	assert.equal(Object.keys(broken.captures[0].files).length, failWrite - 1);
}

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
	assert.equal(
		measured.progressAtSpawn[index].pending,
		'',
		'complete the progress line before launching the child'
	);
	assert.equal(
		measured.progressAtSpawn[index].line,
		`  RUNNING ${index + 1}/${measured.calls} — ${result.name}`,
		'the last completed line identifies the child that is about to run'
	);
	assert.equal(result.ordinal, starts[index].ordinal);
	assert.ok(
		measured.output
			.split('\n')
			.includes(`  ${result.status} ${index + 1}/${measured.calls} — ${result.name}`),
		'the completed result line preserves verdict, ordinal and child identity'
	);
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
assert.equal(full.captures.length, 0, 'passing checks do not retain raw output');
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
assert.equal(JSON.parse(thrownSpawn.captures[0].files['receipt.json']).capture.spawn_threw, true);

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
assert.equal(
	pipeline.stepField(upload, 'if'),
	"always() && steps.common-lot.outputs.suite == 'js'"
);
assert.equal(pipeline.stepField(upload, 'uses'), 'actions/upload-artifact@v4');
assert.match(
	upload,
	/^ {10}name: core-js-timings-\$\{\{ steps\.common-lot\.outputs\.feature \}\}$/m
);
assert.match(upload, /^ {10}overwrite: true$/m);
assert.match(upload, /^ {10}path: \$\{\{ runner.temp \}\}\/ergopti-js-suite-\*\/timings\.ndjson$/m);
assert.doesNotMatch(
	upload,
	/assets-qualification/,
	'timings are not a native qualification receipt'
);

const failureStep = pipeline.findStep('Retain captured JS failure output');
assert.equal(failureStep.file, '.github/workflows/ci-common.yml');
assert.equal(failureStep.job, 'shared-validation');
const failureUpload = failureStep.body;
assert(
	core.indexOf(failureUpload) > core.indexOf(pipeline.step(core, 'Run shared validation suite'))
);
assert.equal(
	pipeline.stepField(failureUpload, 'if'),
	"always() && steps.common-lot.outputs.suite == 'js'"
);
assert.equal(pipeline.stepField(failureUpload, 'uses'), 'actions/upload-artifact@v4');
assert.match(
	failureUpload,
	/^ {10}name: core-js-failures-\$\{\{ steps\.common-lot\.outputs\.feature \}\}$/m
);
assert.match(
	failureUpload,
	/^ {10}path: \$\{\{ runner.temp \}\}\/ergopti-js-suite-\*\/failures\/\*\*$/m
);
assert.match(failureUpload, /^ {10}if-no-files-found: ignore$/m);
assert.match(failureUpload, /^ {10}overwrite: true$/m);
assert.doesNotMatch(failureUpload, /continue-on-error|core-js-timings|assets-qualification/);
const download = pipeline.findStep('Download completed feature timings').body;
assert.match(download, /^ {10}pattern: core-js-timings-\*$/m);
assert.doesNotMatch(download, /core-js-failures/, 'raw text cannot enter the strict timing union');

// A passing check that could not execute a case on this host must say so in
// the summary instead of reading as a plain pass.
{
	const skipped = run({
		status: 0,
		stdout: 'ok 1 - executed\nSKIP (not executed): synthetic case: synthetic reason\n'
	});
	assert.ifError(skipped.thrown);
	assert.equal(skipped.exitCode, 0, 'a not-executed case alone does not fail the suite');
	assert.match(skipped.output, /^ {4}SKIP \(not executed\): synthetic case: synthetic reason$/m);
	assert.match(skipped.output, /^1 case\(s\) in 1 check\(s\) were NOT EXECUTED on this host:$/m);
	const plain = run({ status: 0, stdout: 'ok 1 - executed\n' });
	assert.doesNotMatch(plain.output, /NOT EXECUTED/);
}

// A Node installed under a directory with a space ("C:\Program Files\nodejs")
// once turned every "$NODE_EXECUTABLE" check into the command "C:\Program":
// the runner spawned it through a shell, which joins the program unquoted.
// Start a real Node through the plan from a path that contains a space.
{
	const { spawnSync } = require('node:child_process');
	const { spawnPlan } = require('./lib/js-suite-spawn.cjs');
	const spacedRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti js suite spawn '));
	try {
		const spacedNode = path.join(spacedRoot, 'node with space' + path.extname(process.execPath));
		// Windows refuses unprivileged symlinks and hard links into Program Files.
		if (process.platform === 'win32') fs.copyFileSync(process.execPath, spacedNode);
		else fs.symlinkSync(process.execPath, spacedNode);
		const probe = path.join(spacedRoot, 'probe arg.cjs');
		fs.writeFileSync(probe, 'process.stdout.write(JSON.stringify(process.argv.slice(2)));\n');
		const plan = spawnPlan(
			{ id: 'probe', cmd: '$NODE_EXECUTABLE', args: [probe, 'a b', '&echo injected'] },
			spacedNode
		);
		assert.equal(plan.shell, false, 'the Node executable path must not pass through a shell');
		const result = spawnSync(plan.command, plan.args, { encoding: 'utf8', shell: plan.shell });
		assert.equal(result.error, undefined, `spawn failed: ${result.error}`);
		assert.equal(result.status, 0, `spaced Node path must start: ${result.stderr}`);
		assert.deepEqual(JSON.parse(result.stdout), ['a b', '&echo injected']);
	} finally {
		fs.rmSync(spacedRoot, { recursive: true, force: true });
	}
	assert.deepEqual(spawnPlan({ id: 'n', cmd: 'npm', args: ['run', 'x'] }, process.execPath), {
		command: 'npm',
		args: ['run', 'x'],
		shell: true
	});
	assert.throws(
		() => spawnPlan({ id: 'u', cmd: 'python', args: [] }, process.execPath),
		/unsupported/
	);
}

console.log('JS suite failure diagnostics: OK');
