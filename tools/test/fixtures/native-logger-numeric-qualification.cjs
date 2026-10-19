// tools/test/fixtures/native-logger-numeric-qualification.cjs
'use strict';

/** Constructed native receipts and isolated real Git/CLI controls; no Darwin credit. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { bashExecutable } = require('../../lib/git-bash.cjs');
const reader = require('../../diagnostics/native_logger_numeric_xctest_evidence.cjs');
const ROOT = path.resolve(__dirname, '../../..');
const NUMERIC_SOURCE =
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/LoggerDatagramNumericTests.swift';
const expected = [
	'testUnrepresentableEnvelopeNumbersRefuseWithoutCrashingOrConfiguring',
	'testUnrepresentableConfigureNumbersCannotCreateAConfiguredDirectory',
	'testUnrepresentableRecordAndBatchSequencesCannotWriteOrAdvance'
];

module.exports = function run({
	workflow,
	admitNativeSdkSelector,
	LOGGER_NUMERIC_COMMAND,
	LOGGER_NUMERIC_STEP
}) {
	assert.deepEqual(reader.METHODS, expected);
	const summary = 'Executed 3 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds';
	const rows = [
		"Test Suite 'Selected tests' started at fixed",
		"Test Suite 'ErgoptiPlusPackageTests.xctest' started at fixed",
		"Test Suite 'LoggerDatagramNumericTests' started at fixed"
	];
	for (const method of expected) {
		const name = `-[ErgoptiPlusTests.LoggerDatagramNumericTests ${method}]`;
		rows.push(`Test Case '${name}' started.`, `Test Case '${name}' passed (0.001 seconds).`);
	}
	for (const suite of [
		'LoggerDatagramNumericTests',
		'ErgoptiPlusPackageTests.xctest',
		'Selected tests'
	])
		rows.push(`Test Suite '${suite}' passed at fixed`, summary);
	const valid = rows.join('\n') + '\n';
	let parserControls = 0;
	const check = (body) => {
		body();
		parserControls++;
	};
	check(() => assert.equal(reader.evaluate(valid, 0, 0).exit_status, 0));
	for (const [from, to] of [
		['passed (0.001 seconds).', 'skipped (0.001 seconds).'],
		['passed (0.001 seconds).', 'failed (0.001 seconds).'],
		['Executed 3 tests', 'Executed 0 tests'],
		['Executed 3 tests', 'Executed 42 tests'],
		['0 failures (0 unexpected)', '1 failures (0 unexpected)'],
		['LoggerDatagramNumericTests', 'LoggerDatagramWorkerTests'],
		[expected[0], 'testForeignNumericCase'],
		["Test Suite 'Selected tests' passed", "Test Suite 'Selected tests' failed"]
	])
		check(() => assert.notEqual(reader.evaluate(valid.replaceAll(from, to), 0, 0).exit_status, 0));
	for (const changed of [
		'',
		valid.replace(rows[3] + '\n', ''),
		valid.replace(rows[4] + '\n', ''),
		valid.replace(rows[3], rows[3] + '\n' + rows[3]),
		valid.replace(rows[4], rows[4] + '\n' + rows[4]),
		valid.replace(rows[3] + '\n' + rows[4], rows[4] + '\n' + rows[3]),
		valid + valid,
		valid.slice(0, valid.lastIndexOf("Test Suite 'Selected tests' passed")),
		valid.replace(summary + '\n', '')
	])
		check(() => assert.notEqual(reader.evaluate(changed, 0, 0).exit_status, 0));
	check(() => assert.equal(reader.evaluate(valid, 42, 0).exit_status, 42));
	check(() => assert.equal(reader.evaluate(valid, 0, 17).exit_status, 17));
	assert.equal(parserControls, 20);

	assert.ok(
		LOGGER_NUMERIC_COMMAND.startsWith(
			'          bash tools/diagnostics/run_logger_numeric_native.sh '
		)
	);
	assert.notEqual(admitNativeSdkSelector(workflow), null);
	let selectorControls = 0;
	for (const [from, to] of [
		['run_logger_numeric_native.sh', 'foreign_numeric_runner.sh'],
		['"$GITHUB_SHA"', '"foreign"'],
		['"$GITHUB_RUN_ID"', '"1"'],
		['"$GITHUB_RUN_ATTEMPT"', '"1"'],
		['"$ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE"', '"arm64"'],
		['"$ERGOPTI_OLLAMA_BUILD_ROOT"', '"/tmp/foreign"']
	]) {
		assert.ok(LOGGER_NUMERIC_COMMAND.includes(from));
		assert.equal(
			admitNativeSdkSelector(
				workflow.replace(LOGGER_NUMERIC_COMMAND, LOGGER_NUMERIC_COMMAND.replace(from, to))
			),
			null
		);
		selectorControls++;
	}
	for (const changed of [
		workflow.replace(LOGGER_NUMERIC_COMMAND, ''),
		workflow.replace(LOGGER_NUMERIC_COMMAND, LOGGER_NUMERIC_COMMAND + LOGGER_NUMERIC_COMMAND),
		workflow.replace(LOGGER_NUMERIC_COMMAND, '          exit 0\n' + LOGGER_NUMERIC_COMMAND),
		workflow.replace(
			LOGGER_NUMERIC_STEP,
			LOGGER_NUMERIC_STEP.replace(
				'        run: |\n',
				'        run: |\n          shopt -s expand_aliases\n          alias bash=true\n'
			)
		),
		workflow.replace(
			LOGGER_NUMERIC_COMMAND,
			"          cat <<'UNEXECUTED'\n" + LOGGER_NUMERIC_COMMAND + 'UNEXECUTED\n'
		),
		workflow.replace(LOGGER_NUMERIC_COMMAND, LOGGER_NUMERIC_COMMAND.trimEnd() + ' || true\n')
	]) {
		assert.equal(admitNativeSdkSelector(changed), null);
		selectorControls++;
	}
	assert.equal(
		admitNativeSdkSelector(
			workflow.replace(
				LOGGER_NUMERIC_STEP,
				LOGGER_NUMERIC_STEP.replace(
					'        run: |\n',
					'        run: |\n          bash() { true; }\n'
				)
			)
		),
		null
	);
	selectorControls++;
	assert.equal(selectorControls, 13);

	// Exercise the genuine CLI against its own complete, clean, tracked checkout.
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-numeric-logger-source-'));
	const env = {
		...Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^GIT_/i.test(key))),
		GIT_CONFIG_NOSYSTEM: '1',
		GIT_CONFIG_GLOBAL: '/dev/null'
	};
	const git = (args) =>
		execFileSync('git', args, {
			cwd: fixture,
			env,
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe']
		});
	const inputs = [
		...new Set([
			...reader.INPUTS,
			'tools/diagnostics/managed_http_pac_xctest_evidence.cjs',
			'.github/ci/stable_v102_macos_native_qualification_exception.json',
			...['.github/ci/stable_v103_macos_native_qualification_exception.json'].filter((file) =>
				fs.existsSync(path.join(ROOT, file))
			),
			...[
				'ReleaseArchiveStagingTests',
				'SparkleArchiveUpdateAcceptanceTests',
				'HomebrewArchiveAcceptanceTests'
			].map((name) => `static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/${name}.swift`)
		])
	];
	let sourceControls = 0;
	try {
		for (const file of inputs) {
			const dest = path.join(fixture, file);
			fs.mkdirSync(path.dirname(dest), { recursive: true });
			fs.copyFileSync(path.join(ROOT, file), dest);
		}
		git(['init', '--quiet']);
		git(['add', '--', '.github', 'tools', 'static']);
		git([
			'-c',
			'user.name=Numeric logger control',
			'-c',
			'user.email=numeric-control@example.invalid',
			'commit',
			'--quiet',
			'-m',
			'Independent numeric logger source fixture'
		]);
		const candidate = git(['rev-parse', 'HEAD']).trim();
		const evidence = path.join(fixture, 'evidence');
		fs.mkdirSync(evidence, { mode: 0o700 });
		const transcript = path.join(evidence, 'transcript.log');
		fs.writeFileSync(transcript, valid);
		const script = path.join(
			fixture,
			'tools/diagnostics/native_logger_numeric_xctest_evidence.cjs'
		);
		let serial = 0;
		const fresh = (name) => path.join(evidence, `${name}-${++serial}.json`);
		const cli = (args) => {
			const result = spawnSync(process.execPath, [script, ...args], {
				cwd: fixture,
				env,
				encoding: 'utf8'
			});
			assert.equal(result.error, undefined);
			assert.equal(result.signal, null);
			return result;
		};
		const before = fresh('source');
		const begin = (out) => cli(['begin', candidate, '12345', '1', 'arm64', out]);
		const judge = (source = before, architecture = 'arm64', hash = candidate) =>
			cli([
				'judge',
				transcript,
				'0',
				'0',
				hash,
				'12345',
				'1',
				architecture,
				source,
				fresh('verdict')
			]);
		assert.equal(begin(before).status, 0);
		sourceControls++;
		assert.equal(judge().status, 0);
		sourceControls++;
		const bound = JSON.parse(fs.readFileSync(before));
		assert.equal(bound.scope, 'native-logger-numeric-three');
		assert.equal(bound.candidate, candidate);
		assert.equal(bound.architecture, 'arm64');
		assert.ok(bound.sources[NUMERIC_SOURCE]);
		sourceControls++;
		assert.notEqual(judge(before, 'amd64').status, 0);
		sourceControls++;
		assert.notEqual(judge(before, 'arm64', 'f'.repeat(40)).status, 0);
		sourceControls++;
		const critical = path.join(fixture, NUMERIC_SOURCE);
		const original = fs.readFileSync(critical);
		fs.appendFileSync(critical, '\n// changed after admission\n');
		assert.notEqual(judge().status, 0);
		sourceControls++;
		fs.writeFileSync(critical, original);
		const forged = fresh('forged');
		fs.writeFileSync(forged, JSON.stringify({ ...bound, run_id: '54321' }));
		assert.notEqual(judge(forged).status, 0);
		sourceControls++;
		fs.writeFileSync(transcript, valid.replace(rows[4] + '\n', ''));
		assert.notEqual(judge().status, 0);
		sourceControls++;
		fs.writeFileSync(transcript, valid);
		const extra = path.join(
			fixture,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/Untracked.swift'
		);
		fs.writeFileSync(extra, '// compiler input\n');
		assert.notEqual(begin(fresh('extra')).status, 0);
		sourceControls++;
		fs.unlinkSync(extra);
		assert.equal(begin(fresh('healthy')).status, 0);
		sourceControls++;
		// Run the real Bash/Node/source chain. Only Darwin and Swift boundaries are doubled.
		const bin = path.join(fixture, 'boundary bin with spaces');
		fs.mkdirSync(bin);
		const executable = (name, body) =>
			fs.writeFileSync(path.join(bin, name), body, { mode: 0o700 });
		executable(
			'uname',
			`#!/usr/bin/env bash
case "$1" in
 -s) printf '%s\n' "\${NUMERIC_FIXTURE_KERNEL:-Darwin}" ;;
 -m) printf '%s\n' "\${NUMERIC_FIXTURE_MACHINE:-arm64}" ;;
 *) exit 1 ;;
esac
`
		);
		const swiftChild = path.join(bin, 'swift child with spaces.cjs');
		fs.writeFileSync(
			swiftChild,
			`const fs=require('node:fs');
fs.writeFileSync(process.env.NUMERIC_FIXTURE_ARGUMENTS,JSON.stringify(process.argv.slice(2)));
process.stdout.write(fs.readFileSync(process.env.NUMERIC_FIXTURE_TRANSCRIPT));
process.exit(Number(process.env.NUMERIC_FIXTURE_STATUS||0));
`
		);
		executable(
			'swift',
			`#!/usr/bin/env bash
node "$NUMERIC_FIXTURE_SWIFT_JS" "$@"
`
		);
		executable(
			'tee',
			`#!/usr/bin/env bash
/usr/bin/tee "$@"
exit "\${NUMERIC_FIXTURE_CAPTURE_STATUS:-0}"
`
		);
		let runnerControls = 0;
		const runNative = (text, options = {}) => {
			const out = path.join(evidence, 'runner-' + ++serial);
			fs.mkdirSync(out);
			fs.writeFileSync(transcript, text);
			const argsFile = path.join(out, 'swift-arguments.json');
			const result = spawnSync(
				bashExecutable(),
				[
					'tools/diagnostics/run_logger_numeric_native.sh',
					candidate,
					'12345',
					'1',
					options.architecture || 'arm64',
					out
				],
				{
					cwd: fixture,
					encoding: 'utf8',
					env: {
						...env,
						PATH: bin + path.delimiter + env.PATH,
						NUMERIC_FIXTURE_ARGUMENTS: argsFile,
						NUMERIC_FIXTURE_TRANSCRIPT: transcript,
						NUMERIC_FIXTURE_SWIFT_JS: swiftChild,
						...options.env
					}
				}
			);
			assert.equal(result.error, undefined);
			assert.equal(result.signal, null);
			runnerControls++;
			return { result, out, argsFile };
		};
		const healthy = runNative(valid);
		assert.equal(healthy.result.status, 0, healthy.result.stderr);
		assert.deepEqual(JSON.parse(fs.readFileSync(healthy.argsFile)), [
			'test',
			'--package-path',
			'static/ergopti_plus/macos/launcher',
			'--scratch-path',
			healthy.out + '/swift',
			'--filter',
			'(^|[.])LoggerDatagramNumericTests([/.]|$)'
		]);
		const receipt = JSON.parse(
			fs.readFileSync(path.join(healthy.out, 'logger-numeric-3-verdict.json'))
		);
		assert.equal(receipt.complete, true);
		assert.equal(receipt.observed, 3);
		assert.equal(receipt.source.candidate, candidate);
		assert.equal(receipt.full_package_qualified, false);
		assert.equal(
			runNative(valid, { architecture: 'amd64', env: { NUMERIC_FIXTURE_MACHINE: 'x86_64' } }).result
				.status,
			0
		);
		for (const text of [
			valid.replace(rows[7] + '\n' + rows[8] + '\n', ''),
			valid.replace(rows[8] + '\n', ''),
			valid.replace('passed (0.001 seconds).', 'skipped (0.001 seconds).'),
			valid.replace('passed (0.001 seconds).', 'failed (0.001 seconds).'),
			'Build complete!\n'
		])
			assert.notEqual(runNative(text).result.status, 0);
		assert.equal(runNative(valid, { env: { NUMERIC_FIXTURE_STATUS: '91' } }).result.status, 91);
		assert.equal(
			runNative(valid, { env: { NUMERIC_FIXTURE_CAPTURE_STATUS: '17' } }).result.status,
			17
		);
		const mismatch = runNative(valid, { env: { NUMERIC_FIXTURE_MACHINE: 'x86_64' } });
		assert.notEqual(mismatch.result.status, 0);
		assert.equal(fs.existsSync(mismatch.argsFile), false);
		const foreign = runNative(valid, { env: { NUMERIC_FIXTURE_KERNEL: 'Linux' } });
		assert.notEqual(foreign.result.status, 0);
		assert.equal(fs.existsSync(foreign.argsFile), false);
		assert.equal(runnerControls, 11);
		console.log(
			`PASS: numeric logger real-runner boundary controls=${runnerControls}; Darwin/Swift doubled, native UNRUN.`
		);
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
	assert.equal(sourceControls, 10);
	console.log(
		`PASS: numeric logger exact-three parser=${parserControls} selector=${selectorControls} source=${sourceControls}; native execution UNRUN.`
	);
};
