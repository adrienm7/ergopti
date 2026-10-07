// tools/test/test-linux-portable-network-registration.cjs

/**
 * ==============================================================================
 * MODULE: Portable Linux Native Gate Registration
 * DESCRIPTION:
 * Refuses zero-exit producers with missing, duplicate or skipped native receipts,
 * and checks that package sources select the mandatory native gate. Process
 * doubles prove only gate admission; installed native proof runs separately.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Pipeline = require('./ci-pipeline.cjs');
const { selectGates, GATE_COMMANDS } = require('./verify-change.cjs');
const { run } = require('./run-linux-portable-network-native.cjs');

const ROOT = path.resolve(__dirname, '../..');
const COMPLETE =
	'PASS actual staged AppDir network runtime: 7 native groups; real AppImage/Flatpak delivery unqualified.\n' +
	'Actual PPID census controls: 2 passed; 0 skipped; native-7 credit unchanged.\n';
let passed = 0;
for (const result of [
	{ status: 0, stdout: '' },
	{ status: 0, stdout: COMPLETE.split('\n')[0] + '\n' },
	{ status: 0, stdout: COMPLETE.split('\n')[1] + '\n' },
	{ status: 0, stdout: COMPLETE + COMPLETE },
	{ status: 0, stdout: COMPLETE + '[SKIP] missing native component\n' },
	{ status: 0, stdout: COMPLETE + 'SKIP actual native group\n' },
	{ status: 1, stdout: COMPLETE },
	{ status: null, stdout: COMPLETE },
	{ status: 0, stdout: COMPLETE, error: new Error('Owned producer admission refused') }
]) {
	const errors = [];
	assert.notEqual(
		run({
			platform: 'linux',
			spawn: () => result,
			write() {},
			writeError() {},
			error: (message) => errors.push(message)
		}),
		0
	);
	assert.equal(errors.length, 1);
	passed++;
}
assert.equal(
	run({
		platform: 'linux',
		spawn: () => ({ status: 0, stdout: COMPLETE }),
		write() {},
		writeError() {},
		error() {
			assert.fail('Complete receipt refused');
		}
	}),
	0
);
passed++;
for (const platform of ['darwin', 'win32']) {
	const messages = [];
	assert.equal(
		run({
			platform,
			spawn() {
				assert.fail('Foreign host spawned native producer');
			},
			log: (message) => messages.push(message)
		}),
		0
	);
	assert.match(messages[0], /^\[DEFERRED\]/);
	passed++;
}
const gate = 'linux-portable-network-native';
for (const source of [
	'static/ergopti_plus/_shared/data/linux_native_runtime.json',
	'tools/build/build-linux-appimage.sh',
	'tools/build/build-linux-flatpak.sh',
	'tools/build/stage-linux-network-runtime.py',
	'tools/build/templates/linux-portable-runtime-env.sh',
	'tools/codegen/codegen-linux-native-runtime.cjs',
	'tools/test/test-linux-portable-network-runtime.cjs',
	'tools/test/run-linux-portable-network-native.cjs',
	'.github/workflows/ci-linux.yml'
])
	assert.ok(selectGates([source]).has(gate), `Missing mandatory gate for ${source}`);
const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
assert.equal(
	pkg.scripts[GATE_COMMANDS[gate].npm],
	'node ./tools/test/run-linux-portable-network-native.cjs'
);
const pipeline = Pipeline.open(ROOT);
const step = Pipeline.step(
	pipeline.job('e2e-linux'),
	'Qualify actual staged portable network runtime and retirement'
);
assert.equal(Pipeline.stepField(step, 'if'), '${{ !cancelled() }}');
assert.equal(Pipeline.stepField(step, 'continue-on-error'), null);
assert.equal(Pipeline.runOf(step).join('\n'), 'npm run test:linux:portable-network-native');
console.log(
	`Portable network native gate: ${passed} admission controls passed; native proof separate.`
);
