// tools/test/test-linux-network-runtime-registration.cjs

/** Keeps portable registration separate from mandatory native execution. */
'use strict';
const { loadInventory } = require('./lib/js-feature-inventory.cjs');
const LinuxE2E = require('./fixtures/linux-e2e-shards.cjs');
/** Admit exactly one literal Node owner, retaining the declared command token. */
function ownsCheck(inventory, file, command = 'node') {
	const checks = inventory.checks.filter((check) => check.args.includes(file));
	return (
		checks.length === 1 &&
		checks[0].cmd === command &&
		checks[0].args.length === 1 &&
		checks[0].args[0] === file &&
		!checks[0].platforms
	);
}

const assert = require('node:assert/strict');
const { assertLinuxQualifiedRun } = require('./ci-linux-qualified-run.cjs');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { run } = require('./run-linux-network-runtime.cjs');
const ROOT = path.resolve(__dirname, '../..');
const read = (name) => fs.readFileSync(path.join(ROOT, name), 'utf8');
const aliases = JSON.parse(read('package.json')).scripts;
assert.equal(
	aliases['test:linux-network-runtime'],
	'node ./tools/test/test-linux-network-runtime.cjs'
);
assert.equal(
	aliases['test:linux:network-runtime'],
	'node ./tools/test/run-linux-network-runtime.cjs'
);
assert.equal(
	aliases['test:linux-network-runtime-registration'],
	'node ./tools/test/test-linux-network-runtime-registration.cjs'
);
const inventory = loadInventory(ROOT);
assert.ok(ownsCheck(inventory, 'tools/test/test-linux-network-runtime.cjs'));
assert.ok(ownsCheck(inventory, 'tools/test/test-linux-network-runtime-registration.cjs'));
assert.ok(
	!inventory.checks.some((check) =>
		check.args.includes('tools/test/run-linux-network-runtime.cjs')
	),
	'Native admission must not run in JS inventory'
);
const planner = require('./verify-change.cjs');
const sources = [
	'static/ergopti_plus/_shared/data/linux_native_runtime.json',
	'static/ergopti_plus/linux/platform/network/native_proxy_runtime.lua',
	'static/ergopti_plus/linux/platform/network/runtime_probe.lua',
	'static/ergopti_plus/linux/platform/network/system_proxy_probe.lua',
	'tools/test/run-linux-network-runtime.cjs',
	'tools/test/test-linux-network-runtime.cjs',
	'tools/test/fixtures/linux-network-runtime-factory.lua'
];
function validatePlanner(candidate) {
	assert.equal(candidate.GATE_COMMANDS['linux-network-runtime']?.npm, 'test:linux:network-runtime');
	for (const source of sources)
		assert.ok(candidate.selectGates([source]).has('linux-network-runtime'), source);
}
validatePlanner(planner);
assert.throws(() => validatePlanner({ ...planner, GATE_COMMANDS: {} }));
assert.throws(() => validatePlanner({ ...planner, selectGates: () => new Map() }));

// Closed expected receipts are independent of production exports, so removed
// phases, changed counts and skipped/native-zero substitutions cannot pass.
const receipts = [
	'PASS network runtime factory controls: 4 passed; 0 skipped\n',
	[
		'PASS actual LuaJIT refuses missing luv from an unrelated installed CWD',
		'PASS actual installed GLib with dummy resolver refuses native package admission',
		'PASS actual missing compiled schema refuses helper and installer before resolver construction',
		'PASS actual installed runtime locates native and shared sources independently of CWD',
		'Linux network runtime: 4 passed; 0 skipped. Actual native probes require --native.',
		''
	].join('\n')
];
/** Preserve genuine rejected-child bytes without exposing their contents in logs. */
function exercisePrivateFailure(mode) {
	const evidenceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-network-evidence-test-'));
	const exported = [];
	const captures = [];
	const stdout = Buffer.concat([Buffer.from('NETWORK_STDOUT_SECRET'), Buffer.from([0, 255, 254])]);
	const stderr = Buffer.concat([Buffer.from('NETWORK_STDERR_SECRET'), Buffer.from([128, 0, 253])]);
	const previousMask = mode === 'restrictive-umask' ? process.umask(0o777) : undefined;
	try {
		const result = run({
			platform: 'linux',
			evidenceRoot,
			log: (line) => exported.push(line),
			error: (line) => exported.push(line),
			spawn: (command, args, options) => {
				const index = captures.length;
				const body =
					index === 0
						? `process.stdout.write(${JSON.stringify(receipts[0])});`
						: [
								"const fs = require('node:fs');",
								mode === 'empty'
									? ''
									: `fs.writeSync(1, Buffer.from(${JSON.stringify([...stdout])}));`,
								mode === 'empty'
									? ''
									: `fs.writeSync(2, Buffer.from(${JSON.stringify([...stderr])}));`,
								mode === 'signal'
									? "process.kill(process.pid, 'SIGTERM');"
									: mode === 'buffer-error'
										? 'process.stdout.write(Buffer.alloc(128 * 1024, 97));'
										: `process.exit(${mode === 'wrong-receipt' ? 0 : 73});`
							].join('\n');
				const actual = spawnSync(
					index === 1 && mode === 'missing-program'
						? path.join(evidenceRoot, 'absent-program')
						: process.execPath,
					['-e', body],
					options
				);
				captures.push({ command, args, options, actual });
				return actual;
			}
		});
		assert.equal(result, 1, 'a retained failure must still block qualification');
		assert.equal(captures.length, 2);
		assert.equal(captures[0].actual.status, 0, 'the real independent model control must pass');
		if (mode === 'exit73') {
			assert.equal(captures[1].actual.status, 73);
			assert.ok(captures[1].actual.stdout.includes('NETWORK_STDOUT_SECRET'));
			assert.ok(captures[1].actual.stderr.includes('NETWORK_STDERR_SECRET'));
		}
		const failures = exported.filter((line) => line.includes('actual-native'));
		assert.equal(failures.length, 1);
		const location = / evidence=(".*")$/.exec(failures[0]);
		assert.ok(
			location,
			'(network-diagnostic-retention) a rejected child must retain private evidence'
		);
		const directory = JSON.parse(location[1]);
		assert.equal(path.dirname(directory), evidenceRoot);
		assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
		const metadata = JSON.parse(fs.readFileSync(path.join(directory, 'result.json'), 'utf8'));
		const child = captures[1].actual;
		assert.equal(metadata.phase, 'actual-native');
		assert.equal(metadata.command, captures[1].command);
		assert.deepEqual(metadata.args, captures[1].args);
		assert.equal(metadata.pid, child.pid);
		assert.equal(metadata.status, child.status);
		assert.equal(metadata.signal, child.signal);
		assert.equal(captures[0].options.timeout, 10000);
		assert.equal(captures[1].options.timeout, undefined);
		assert.equal(captures[1].options.maxBuffer, 65536);
		for (const name of ['stdout', 'stderr']) {
			if (child[name] === null || child[name] === undefined) {
				assert.deepEqual(metadata[name], { kind: child[name] === null ? 'null' : 'undefined' });
				assert.equal(fs.existsSync(path.join(directory, name + '.bin')), false);
			} else {
				assert.ok(Buffer.isBuffer(child[name]), 'native capture must preserve raw bytes');
				assert.equal(metadata[name].kind, 'buffer');
				assert.equal(metadata[name].bytes, child[name].length);
				assert.deepEqual(fs.readFileSync(path.join(directory, name + '.bin')), child[name]);
			}
		}
		if (mode === 'missing-program') {
			assert.equal(child.error.code, 'ENOENT');
			assert.equal(metadata.error.code, 'ENOENT');
		} else if (mode === 'buffer-error') {
			assert.equal(child.error.code, 'ENOBUFS');
			assert.equal(metadata.error.code, 'ENOBUFS');
		} else if (mode === 'signal') {
			assert.equal(child.signal, 'SIGTERM');
			assert.equal(metadata.error, null);
		} else {
			assert.equal(child.status, mode === 'wrong-receipt' ? 0 : 73);
			assert.equal(metadata.error, null);
			assert.deepEqual(child.stdout, mode === 'empty' ? Buffer.alloc(0) : stdout);
			assert.deepEqual(child.stderr, mode === 'empty' ? Buffer.alloc(0) : stderr);
		}
		for (const file of fs.readdirSync(directory))
			assert.equal(fs.statSync(path.join(directory, file)).mode & 0o777, 0o600);
		assert.ok(
			exported.every(
				(line) => !line.includes('NETWORK_STDOUT_SECRET') && !line.includes('NETWORK_STDERR_SECRET')
			)
		);
	} finally {
		if (previousMask !== undefined) process.umask(previousMask);
		fs.rmSync(evidenceRoot, { recursive: true, force: true });
	}
}
let diagnosticControls = 0;
if (process.platform === 'linux') {
	for (const mode of [
		'exit73',
		'signal',
		'buffer-error',
		'missing-program',
		'wrong-receipt',
		'empty',
		'restrictive-umask'
	]) {
		exercisePrivateFailure(mode);
		diagnosticControls++;
	}
	console.log(
		`Linux private network diagnostics: ${diagnosticControls} physical controls passed; 0 skipped.`
	);
}
let passed = 0;
function exercise(transform = (result) => result) {
	const calls = [];
	const evidenceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-network-model-evidence-'));
	try {
		const result = run({
			platform: 'linux',
			evidenceRoot,
			log: () => {},
			error: () => {},
			spawn: (command, args, options) => {
				const index = calls.length;
				calls.push({ command, args, options });
				return transform(
					{
						pid: 4242,
						status: 0,
						signal: null,
						stdout: Buffer.from(receipts[index]),
						stderr: Buffer.from('private witness not for export')
					},
					index
				);
			}
		});
		return { result, calls };
	} finally {
		fs.rmSync(evidenceRoot, { recursive: true, force: true });
	}
}
const positive = exercise();
assert.equal(positive.result, 0);
assert.equal(positive.calls.length, 2);
assert.equal(positive.calls[0].command, 'luajit');
assert.deepEqual(positive.calls[0].args, [
	path.join(ROOT, 'tools/test/fixtures/linux-network-runtime-factory.lua'),
	path.join(ROOT, 'static/ergopti_plus/linux')
]);
assert.equal(positive.calls[1].command, process.execPath);
assert.deepEqual(positive.calls[1].args, [
	path.join(ROOT, 'tools/test/test-linux-network-runtime.cjs'),
	'--native'
]);
passed++;
for (const refusal of [
	(result) => ({ ...result, status: 1 }),
	(result) => ({ ...result, error: new Error('private raw error') }),
	(result) => ({ ...result, signal: 'SIGKILL' }),
	(result) => ({ ...result, stdout: Buffer.alloc(0) }),
	(result) => ({
		...result,
		stdout: Buffer.from(result.stdout.toString().replace('4 passed', '0 passed'))
	}),
	(result) => ({
		...result,
		stdout: Buffer.from(result.stdout.toString().replace('0 skipped', '1 skipped'))
	}),
	(result) => ({
		...result,
		stdout: Buffer.concat([result.stdout, Buffer.from('foreign output\n')])
	})
]) {
	for (const phase of [0, 1]) {
		const attempt = exercise((result, index) => (index === phase ? refusal(result) : result));
		assert.equal(attempt.result, 1);
		assert.equal(
			attempt.calls.length,
			2,
			'One refusal must not omit the other independent qualification'
		);
		passed++;
	}
}
let spawned = 0;
assert.equal(
	run({
		platform: 'darwin',
		spawn: () => {
			spawned++;
		},
		log: () => {},
		error: () => {}
	}),
	0
);
assert.equal(spawned, 0);
passed++;
const exported = [];
const privacyEvidence = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-network-private-evidence-'));
try {
	run({
		platform: 'linux',
		evidenceRoot: privacyEvidence,
		log: (line) => exported.push(line),
		error: (line) => exported.push(line),
		spawn: () => ({
			pid: 4242,
			status: 1,
			signal: null,
			stdout: Buffer.from('private credential'),
			stderr: Buffer.from('private recipient'),
			error: new Error('private raw error')
		})
	});
	assert.ok(
		exported.every((line) =>
			['private credential', 'private recipient', 'private raw error'].every(
				(secret) => !line.includes(secret)
			)
		)
	);
} finally {
	fs.rmSync(privacyEvidence, { recursive: true, force: true });
}
passed++;
console.log(`Linux network runtime registration: ${passed} passed; 0 skipped.`);

// Native CI/evidence admission is independent of the portable/model wrapper.
const Pipeline = require('./ci-pipeline.cjs');
const { readActualNativeCount } = require('./linux-network-runtime-evidence.cjs');
const NATIVE_STEP = 'Qualify native managed network runtime';
const COUNT_LINE =
	'network_runtime_assertions=$(node tools/test/linux-network-runtime-evidence.cjs "$RUNNER_TEMP/linux-network-runtime.log")';
function validateRuntimeCI(workflow, coverage) {
	const jobs = Pipeline.jobsOfText(workflow, '.github/workflows/ci-linux.yml');
	const e2e = jobs.filter((job) => job.id === 'e2e-linux');
	assert.equal(e2e.length, 1);
	const steps = Pipeline.steps(e2e[0].body);
	const at = steps.findIndex((step) => step.name === NATIVE_STEP);
	assert.ok(at > 0);
	assert.equal(steps[at - 1].name, 'Install prerequisites for ' + NATIVE_STEP);
	assert.equal(steps[at - 2].name, 'Qualify native HTTP streaming receipts');
	const native = Pipeline.step(e2e[0].body, NATIVE_STEP);
	assert.equal(
		Pipeline.stepField(native, 'if'),
		LinuxE2E.condition(NATIVE_STEP, '${{ !cancelled() }}')
	);
	assert.equal(Pipeline.stepField(native, 'continue-on-error'), null);
	assert.equal(Pipeline.stepField(native, 'timeout-minutes'), '3');
	assertLinuxQualifiedRun(Pipeline.runOf(native), [
		'set -euo pipefail',
		'npm run test:linux:network-runtime | tee "$RUNNER_TEMP/linux-network-runtime.log"'
	]);
	// The install keeps the scoped full branch: a deferred scope installs nothing.
	const install = Pipeline.runOf(steps[at - 1].body);
	assert.ok(install.includes('elif [ "$mode" = full ]; then'));
	assert.ok(
		install.includes(
			'sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends luajit lua-luv glib-networking gsettings-desktop-schemas'
		)
	);
	assert.ok(
		install.indexOf('elif [ "$mode" = full ]; then') <
			install.findIndex((line) => line.includes('ubuntu_apt.py')),
		'the install runs only in the full scope'
	);
	const record = Pipeline.runOf(Pipeline.step(e2e[0].body, 'Record mandatory E2E evidence'));
	assert.equal(record.filter((line) => line === COUNT_LINE).length, 1);
	assert.equal(
		record.filter(
			(line) =>
				line.trim() ===
				'--subject "managed-network-runtime=$network_runtime_assertions" ' + String.fromCharCode(92)
		).length,
		1
	);
	assert.equal(coverage.jobs['e2e-linux'].classification, 'mandatory');
	assert.equal(coverage.jobs['e2e-linux'].subjects['managed-network-runtime'], 4);
	assert.equal(coverage.jobs['e2e-linux'].subjects['http-stream-receipts'], 55);
}
assert.ok(
	read('tools/test/test-npm-aliases-match-the-suite.cjs').includes(
		"'tools/test/run-linux-network-runtime.cjs',"
	),
	'Native runtime alias must retain its separate execution owner'
);
for (const source of [
	'tools/test/linux-network-runtime-evidence.cjs',
	'.github/linux-ci-coverage.json'
])
	assert.ok(planner.selectGates([source]).has('linux-network-runtime'), source);
const workflow = read('.github/workflows/ci-linux.yml');
const coverage = JSON.parse(read('.github/linux-ci-coverage.json'));
validateRuntimeCI(workflow, coverage);
let evidenceControls = 1;
const actualReceipt =
	'[OK] Linux network runtime actual-native: 4 actual native groups passed; 0 skipped.\n';
assert.equal(
	readActualNativeCount(
		'[OK] Linux network runtime factory-model: 4 model groups passed; 0 skipped.\n' + actualReceipt
	),
	4
);
evidenceControls++;
for (const log of [
	'',
	actualReceipt + actualReceipt,
	actualReceipt.replace('4 actual', '0 actual'),
	actualReceipt.replace('0 skipped', '1 skipped'),
	actualReceipt.replace('[OK]', '[FAIL]'),
	actualReceipt.replace('passed;', 'passed'),
	actualReceipt.replace('\n', '\r\n'),
	actualReceipt + '[FAIL] Linux network runtime actual-native: refused.\n',
	'[DEFERRED] Linux network runtime requires Linux.\n' + actualReceipt,
	'private credential marker',
	'x'.repeat(65537),
	null
]) {
	assert.throws(
		() => readActualNativeCount(log),
		/^Error: Native network runtime receipt refused\.$/
	);
	evidenceControls++;
}
for (const [before, after] of [
	['- name: ' + NATIVE_STEP, '- name: omitted native runtime'],
	['npm run test:linux:network-runtime | tee', 'npm run test:linux-network-runtime | tee'],
	[
		'elif [ "$mode" = full ]; then\n          sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends luajit lua-luv glib-networking gsettings-desktop-schemas',
		'elif false; then\n          sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends luajit lua-luv glib-networking gsettings-desktop-schemas'
	],
	[COUNT_LINE, 'network_runtime_assertions=4'],
	[COUNT_LINE, COUNT_LINE + '\n          ' + COUNT_LINE],
	[
		'--subject "managed-network-runtime=$network_runtime_assertions"',
		'--subject "managed-network-runtime=4"'
	],
	[
		'- name: ' +
			NATIVE_STEP +
			'\n        if: ' +
			LinuxE2E.condition(NATIVE_STEP, '${{ !cancelled() }}'),
		'- name: ' + NATIVE_STEP + '\n        if: ${{ success() }}'
	],
	[
		'- name: ' + NATIVE_STEP + '\n        if:',
		'- name: ' + NATIVE_STEP + '\n        continue-on-error: true\n        if:'
	]
]) {
	assert.ok(workflow.includes(before), 'Causal mutation must hit its intended declaration');
	assert.equal(
		workflow.split(before).length - 1,
		1,
		'Causal mutation must hit exactly one declaration'
	);
	assert.throws(() => validateRuntimeCI(workflow.replace(before, after), coverage));
	evidenceControls++;
}
for (const floor of [0, 3, undefined]) {
	const mutated = structuredClone(coverage);
	mutated.jobs['e2e-linux'].subjects['managed-network-runtime'] = floor;
	assert.throws(() => validateRuntimeCI(workflow, mutated));
	evidenceControls++;
}
console.log(`Linux network runtime CI evidence: ${evidenceControls} passed; 0 skipped.`);
