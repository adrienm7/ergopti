// tools/test/test-linux-fd-sha256-native-gate.cjs

/**
 * ==============================================================================
 * MODULE: Independent Native FD Digest Gate Admission Controls
 * DESCRIPTION:
 * Literal witnesses test receipt admission and the sole guardian invocation.
 * Controlled children provide portable gate models, not native digest evidence.
 * ==============================================================================
 */
'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { run, receipt, readCount } = require('./run-linux-fd-sha256-native.cjs');

// Manually fixed from the independent fixture, never generated from the reader.
const OUTPUT = [
	'PASS vector 1 native input bytes',
	'PASS vector 1 pathname absent before digest',
	'PASS vector 1 independent NIST SHA256',
	'PASS vector 1 read context timer retirement',
	'PASS vector 1 exact parent FD close',
	'PASS vector 1 no retained IO timer debt',
	'PASS vector 2 native input bytes',
	'PASS vector 2 pathname absent before digest',
	'PASS vector 2 independent NIST SHA256',
	'PASS vector 2 read context timer retirement',
	'PASS vector 2 exact parent FD close',
	'PASS vector 2 no retained IO timer debt',
	'12 PASS, 0 FAIL, 0 SKIP',
	'Native subreaper: 0 adopted descendants physically reaped',
	'Native subreaper closure: {"adopted": 0, "pending": 0, "rescue": 0}',
	''
].join('\n');
const completed = { status: 0, signal: null, sinks_closed: true, stdout: OUTPUT, stderr: '' };
let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log('PASS ' + name);
}

check('exact independently fixed twelve native checks and physical closure admit', () => {
	assert.equal(receipt(completed), true);
});
for (const [name, delta] of [
	['missing native receipt', { stdout: '' }],
	[
		'partial native inventory',
		{ stdout: OUTPUT.replace('PASS vector 2 independent NIST SHA256\n', '') }
	],
	[
		'duplicate native check',
		{
			stdout: OUTPUT.replace(
				'PASS vector 2 independent NIST SHA256',
				'PASS vector 1 independent NIST SHA256'
			)
		}
	],
	[
		'changed native count',
		{ stdout: OUTPUT.replace('12 PASS, 0 FAIL, 0 SKIP', '11 PASS, 0 FAIL, 0 SKIP') }
	],
	[
		'skipped native check',
		{ stdout: OUTPUT.replace('12 PASS, 0 FAIL, 0 SKIP', '12 PASS, 0 FAIL, 1 SKIP') }
	],
	[
		'missing guardian closure',
		{
			stdout: OUTPUT.replace(
				'Native subreaper closure: {"adopted": 0, "pending": 0, "rescue": 0}\n',
				''
			)
		}
	],
	['physical pending debt', { stdout: OUTPUT.replace('"pending": 0', '"pending": 1') }],
	['guardian rescued child', { stdout: OUTPUT.replace('"rescue": 0', '"rescue": 1') }],
	[
		'unexpected fixture descendant',
		{
			stdout: OUTPUT.replace('0 adopted descendants', '1 adopted descendants').replace(
				'"adopted": 0',
				'"adopted": 1'
			)
		}
	],
	[
		'unknown guardian field',
		{ stdout: OUTPUT.replace('"rescue": 0}', '"rescue": 0, "unknown": 0}') }
	],
	[
		'duplicate guardian field',
		{ stdout: OUTPUT.replace('"pending": 0', '"pending": 1, "pending": 0') }
	],
	[
		'malformed guardian receipt',
		{ stdout: OUTPUT.replace('{"adopted": 0, "pending": 0, "rescue": 0}', '{bad}') }
	],
	['private diagnostic refusal', { stderr: 'private fixed diagnostic' }],
	['nonzero fixture result', { status: 1 }],
	['signal retirement failure', { signal: 'SIGTERM' }],
	['failed guardian acquisition', { error: true }],
	['missing sink closure', { sinks_closed: false }],
	['extra native summary', { stdout: OUTPUT + '12 PASS, 0 FAIL, 0 SKIP\n' }],
	['extra native warning', { stdout: OUTPUT + 'fixed warning\n' }]
])
	check(name + ' refuses native credit', () =>
		assert.equal(receipt({ ...completed, ...delta }), false)
	);

check('Linux invokes only actual LuaJIT under the original sole guardian', () => {
	const logs = [],
		errors = [],
		calls = [];
	const environment = {
		LUA_PATH: '/foreign/?.lua',
		LUA_INIT: 'foreign',
		LUA_INIT_5_1: 'foreign',
		LUA_CPATH: '/actual/native/?.so',
		PATH: '/actual/bin',
		PYTHON: 'python3'
	};
	const before = JSON.stringify(environment);
	const root = path.join(path.sep, 'controlled', 'repository');
	const result = run({
		platform: 'linux',
		root,
		environment,
		log: (text) => logs.push(text),
		error: (text) => errors.push(text),
		executeChild: (program, args, options) => {
			calls.push({ program, args, options });
			return completed;
		}
	});
	assert.equal(result, 0);
	assert.equal(calls.length, 1);
	assert.equal(calls[0].program, 'python3');
	const driver = path.join(root, 'static/ergopti_plus/linux');
	assert.deepEqual(calls[0].args, [
		path.join(driver, 'tests/hardware/run_native_subreaper.py'),
		'luajit',
		path.join(driver, 'tests/hardware/run_fd_sha256_native.lua')
	]);
	assert.equal(calls[0].options.cwd, driver);
	assert.equal(calls[0].options.timeout, undefined);
	assert.equal(calls[0].options.maxBuffer, undefined);
	assert.equal(calls[0].options.env.LUA_INIT, undefined);
	assert.equal(calls[0].options.env.LUA_INIT_5_1, undefined);
	assert.equal(calls[0].options.env.LUA_PATH.includes('/foreign'), false);
	assert.equal(calls[0].options.env.LUA_CPATH, '/actual/native/?.so');
	assert.equal(JSON.stringify(environment), before);
	assert.deepEqual(logs, ['PASS native retained FD SHA-256: 12 checks; 0 failed; 0 skipped.']);
	assert.deepEqual(errors, []);
});
check('missing actual Linux prerequisites fail without private transcript output', () => {
	const logs = [],
		errors = [];
	assert.equal(
		run({
			platform: 'linux',
			executeChild: () => ({ ...completed, status: 1, stderr: 'private URL/token/path' }),
			log: (text) => logs.push(text),
			error: (text) => errors.push(text)
		}),
		1
	);
	assert.deepEqual(logs, []);
	assert.equal(errors.length, 1);
	assert.equal(errors[0].includes('private URL/token/path'), false);
});
check('throwing guardian acquisition fails with a fixed diagnostic', () => {
	const errors = [];
	assert.equal(
		run({
			platform: 'linux',
			executeChild: () => {
				throw new Error('private');
			},
			log: () => assert.fail('No credit'),
			error: (text) => errors.push(text)
		}),
		1
	);
	assert.equal(errors.length, 1);
	assert.equal(errors[0].includes('private'), false);
});
check('another host defers explicitly without invoking or crediting native checks', () => {
	const logs = [];
	assert.equal(
		run({
			platform: 'darwin',
			executeChild: () => assert.fail('No foreign native execution'),
			log: (text) => logs.push(text),
			error: () => assert.fail('No Linux failure')
		}),
		0
	);
	assert.deepEqual(logs, [
		'[DEFERRED] Native retained FD SHA-256 requires the Linux lane; no native credit.'
	]);
});
check('CI evidence admits only the independently fixed sole native witness', () => {
	assert.equal(readCount('PASS native retained FD SHA-256: 12 checks; 0 failed; 0 skipped.\n'), 12);
});
for (const text of [
	'',
	'PASS native retained FD SHA-256: 12 checks; 0 failed; 0 skipped.\nPASS native retained FD SHA-256: 12 checks; 0 failed; 0 skipped.\n',
	'PASS native retained FD SHA-256: 11 checks; 0 failed; 0 skipped.\n',
	'[DEFERRED] Native retained FD SHA-256 requires the Linux lane; no native credit.\n'
])
	check('missing duplicate changed or deferred CI witness refuses evidence', () => {
		assert.throws(() => readCount(text));
	});
assert.equal(checks, 29, 'Independent portable FD gate admission floor changed');
console.log('PASS portable native FD digest gate admission: 29 controls; 0 skipped.');

// Actual declarations bind the portable admission guard to required native CI.
const fs = require('node:fs');
const Pipeline = require('./ci-pipeline.cjs');
const { selectGates, GATE_COMMANDS } = require('./verify-change.cjs');
const ROOT = path.resolve(__dirname, '../..');
const gate = 'linux-fd-sha256-native';
const scripts = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).scripts;
assert.equal(GATE_COMMANDS[gate].npm, 'test:linux:fd-sha256-native');
assert.equal(scripts[GATE_COMMANDS[gate].npm], 'node ./tools/test/run-linux-fd-sha256-native.cjs');
assert.equal(
	scripts['test:linux-fd-sha256-native-gate'],
	'node ./tools/test/test-linux-fd-sha256-native-gate.cjs'
);
for (const source of [
	'tools/test/run-linux-fd-sha256-native.cjs',
	'tools/test/test-linux-fd-sha256-native-gate.cjs',
	'static/ergopti_plus/linux/tests/hardware/run_fd_sha256_native.lua',
	'static/ergopti_plus/linux/infra/fd_sha256.lua',
	'static/ergopti_plus/linux/infra/archive_output.lua',
	'static/ergopti_plus/linux/infra/managed_http_deadline.lua',
	'static/ergopti_plus/linux/infra/native_timer.lua',
	'static/ergopti_plus/linux/infra/monotonic.lua',
	'static/ergopti_plus/linux/tests/hardware/run_native_subreaper.py',
	'.github/workflows/ci-linux.yml',
	'.github/linux-ci-coverage.json'
])
	assert.ok(selectGates([source]).has(gate), `Native digest gate missing for ${source}`);
const pipeline = Pipeline.open(ROOT);
const step = Pipeline.step(pipeline.job('e2e-linux'), 'Qualify native retained FD SHA-256');
assert.equal(Pipeline.stepField(step, 'if'), '${{ !cancelled() }}');
assert.equal(Pipeline.stepField(step, 'continue-on-error'), null);
assert.equal(Pipeline.stepField(step, 'working-directory'), null);
assert.equal(Pipeline.stepField(step, 'timeout-minutes'), '3');
assert.deepEqual(Pipeline.runOf(step), [
	'set -euo pipefail',
	'npm run --silent test:linux:fd-sha256-native | tee "$RUNNER_TEMP/linux-fd-sha256-native.log"'
]);
const record = Pipeline.runOf(
	Pipeline.step(pipeline.job('e2e-linux'), 'Record mandatory E2E evidence')
);
assert.ok(
	record.includes(
		'fd_sha256_assertions=$(node tools/test/run-linux-fd-sha256-native.cjs --evidence "$RUNNER_TEMP/linux-fd-sha256-native.log")'
	)
);
assert.ok(
	record.includes(
		'    --subject "retained-fd-sha256=$fd_sha256_assertions" ' + String.fromCharCode(92)
	)
);
const coverage = JSON.parse(
	fs.readFileSync(path.join(ROOT, '.github/linux-ci-coverage.json'), 'utf8')
);
assert.equal(coverage.jobs['e2e-linux'].subjects['retained-fd-sha256'], 12);
assert.equal(coverage.jobs['e2e-linux'].subjects['http-stream-receipts'], 55);
assert.match(
	fs.readFileSync(path.join(ROOT, 'tools/test/test-ci-pipeline-wiring.cjs'), 'utf8'),
	/\[LINUX_BOX, 'e2e-linux', 'Qualify native retained FD SHA-256', NOT_CANCELLED\]/
);
console.log('PASS mandatory native FD digest npm, planner and CI registrations.');
