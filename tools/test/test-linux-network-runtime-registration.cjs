// tools/test/test-linux-network-runtime-registration.cjs

/** Keeps portable registration separate from mandatory native execution. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
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
const inventory = read('tools/test/run-js-suite.cjs');
assert.ok(inventory.includes("args: ['tools/test/test-linux-network-runtime.cjs']"));
assert.ok(inventory.includes("args: ['tools/test/test-linux-network-runtime-registration.cjs']"));
assert.ok(
	!inventory.includes("args: ['tools/test/run-linux-network-runtime.cjs']"),
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
let passed = 0;
function exercise(transform = (result) => result) {
	const calls = [];
	const result = run({
		platform: 'linux',
		log: () => {},
		error: () => {},
		spawn: (command, args, options) => {
			const index = calls.length;
			calls.push({ command, args, options });
			return transform(
				{
					status: 0,
					signal: null,
					stdout: receipts[index],
					stderr: 'private witness not for export'
				},
				index
			);
		}
	});
	return { result, calls };
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
	(result) => ({ ...result, stdout: '' }),
	(result) => ({ ...result, stdout: result.stdout.replace('4 passed', '0 passed') }),
	(result) => ({ ...result, stdout: result.stdout.replace('0 skipped', '1 skipped') }),
	(result) => ({ ...result, stdout: result.stdout + 'foreign output\n' })
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
run({
	platform: 'linux',
	log: (line) => exported.push(line),
	error: (line) => exported.push(line),
	spawn: () => ({
		status: 1,
		stdout: 'private credential',
		stderr: 'private recipient',
		error: new Error('private raw error')
	})
});
assert.ok(exported.every((line) => !line.includes('private')));
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
	assert.equal(steps[at - 1].name, 'Qualify native HTTP streaming receipts');
	const native = Pipeline.step(e2e[0].body, NATIVE_STEP);
	assert.equal(Pipeline.stepField(native, 'if'), '${{ !cancelled() }}');
	assert.equal(Pipeline.stepField(native, 'continue-on-error'), null);
	assert.equal(Pipeline.stepField(native, 'timeout-minutes'), '3');
	assert.deepEqual(Pipeline.runOf(native), [
		'set -euo pipefail',
		'sudo apt-get install -y --no-install-recommends luajit lua-luv glib-networking gsettings-desktop-schemas',
		'npm run test:linux:network-runtime | tee "$RUNNER_TEMP/linux-network-runtime.log"'
	]);
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
		'- name: ' +
			NATIVE_STEP +
			'\n        if: ${{ !cancelled() }}\n        run: |\n          set -euo pipefail\n          sudo apt-get install -y --no-install-recommends luajit',
		'- name: ' +
			NATIVE_STEP +
			'\n        if: ${{ !cancelled() }}\n        run: |\n          set -eu\n          sudo apt-get install -y --no-install-recommends luajit'
	],
	[COUNT_LINE, 'network_runtime_assertions=4'],
	[COUNT_LINE, COUNT_LINE + '\n          ' + COUNT_LINE],
	[
		'--subject "managed-network-runtime=$network_runtime_assertions"',
		'--subject "managed-network-runtime=4"'
	],
	[
		'- name: ' + NATIVE_STEP + '\n        if: ${{ !cancelled() }}',
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
