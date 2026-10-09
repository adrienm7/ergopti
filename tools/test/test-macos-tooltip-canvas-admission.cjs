// tools/test/test-macos-tooltip-canvas-admission.cjs

/**
 * ==============================================================================
 * MODULE: Mandatory macOS Tooltip Canvas Admission Tests
 * DESCRIPTION:
 * Requires the native canvas job before desktop admission and keeps its execution
 * unconditional on a separate Mac host. Missing GUI or cleanup cannot be hidden
 * behind a skipped job, while packaged launch evidence remains mandatory. Pure
 * Python registration controls inspect process receipts, never native pixels.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { verify } = require('./desktop-ci-evidence.cjs');
const { coldBootstrapRecord } = require('./fixtures/macos-cold-bootstrap-receipt.cjs');
const pipeline = require('./ci-pipeline.cjs');
const { run } = require('./run-macos-tooltip-canvas-tests.cjs');
const { selectGates, GATE_COMMANDS } = require('./verify-change.cjs');

/** Deliberately omits all image/package evidence to identify the first admission debt. */
function state(needs) {
	return {
		platform: 'macos',
		release: false,
		sha: 'a'.repeat(40),
		scenarios: ['clean', 'upgraded', 'karabiner_config'],
		evidence: [],
		coldBootstrap: [coldBootstrapRecord()],
		needs
	};
}

const oldJobs = ['test-hs', 'e2e-hs', 'package-macos', 'launch'];
const oldNeeds = Object.fromEntries(oldJobs.map((job) => [job, { result: 'success' }]));
// Independent transport/bootstrap jobs remain mandatory while this fixture
// isolates canvas refusal ahead of missing launch/package observations.
const independentNeeds = {
	'managed-ollama-native': { result: 'success' },
	'cold-bootstrap-native': { result: 'success' }
};
// This first control rejects the original four-job admission before artifact
// checks, so missing-canvas refusal is causal rather than another missing PNG.
assert.throws(() => verify(state(oldNeeds)), /Mandatory jobs differ/);
assert.throws(() => verify(state({ ...oldNeeds, ...independentNeeds })), /Mandatory jobs differ/);
for (const result of ['failure', 'cancelled', 'skipped', undefined]) {
	assert.throws(
		() => verify(state({ ...oldNeeds, ...independentNeeds, 'tooltip-canvas': { result } })),
		/tooltip-canvas did not succeed/
	);
}
assert.throws(
	() =>
		verify(state({ ...oldNeeds, ...independentNeeds, 'tooltip-canvas': { result: 'success' } })),
	/Missing, duplicate or unexpected launch evidence/,
	'green canvas must not replace the original package/install observations'
);

// The supplementary native successes isolate this canvas fixture; they never
// turn a failed supplementary job into desktop admission.
for (const job of ['managed-ollama-native', 'cold-bootstrap-native']) {
	for (const result of ['failure', 'cancelled', 'skipped', undefined]) {
		assert.throws(
			() =>
				verify(
					state({
						...oldNeeds,
						...independentNeeds,
						'tooltip-canvas': { result: 'success' },
						[job]: { result }
					})
				),
			new RegExp(`${job} did not succeed`)
		);
	}
}

const canvas = pipeline.job('tooltip-canvas');
assert.deepEqual(pipeline.needsOf(canvas), ['e2e-hs']);
assert.equal(pipeline.field(canvas, 'runs-on'), 'macos-15');
assert.equal(pipeline.field(canvas, 'if'), null);
assert.equal(pipeline.field(canvas, 'continue-on-error'), null);
assert.equal(pipeline.field(canvas, 'timeout-minutes'), '10');
assert.deepEqual(
	pipeline.needsOf(pipeline.job('macos-ok')).sort(),
	[...oldJobs, 'tooltip-canvas', 'managed-ollama-native', 'cold-bootstrap-native'].sort()
);
assert.ok(canvas.includes("python-version: '3.13'"));
const prepare = pipeline.step(canvas, 'Prepare independent pixel observer');
const acquire = pipeline.step(canvas, 'Acquire the pinned official Hammerspoon runtime');
const observe = pipeline.step(
	canvas,
	'Observe actual production canvas pixels and retire its native owner'
);
for (const step of [prepare, acquire, observe]) {
	assert.equal(pipeline.stepField(step, 'if'), null);
	assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
}
assert.ok(prepare.includes('Pillow==11.3.0'));
assert.ok(prepare.includes('node tools/test/run-macos-tooltip-canvas-tests.cjs'));
assert.ok(acquire.includes("--proto '=https' --proto-redir '=https'"));
assert.ok(acquire.includes('11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa'));
assert.ok(acquire.includes('codesign --verify --strict --deep'));
assert.ok(acquire.includes('codesign --display --verbose=4'));
assert.ok(acquire.includes('spctl --assess --type execute --verbose=4'));
assert.ok(observe.includes('git rev-parse HEAD'));
assert.ok(observe.includes('python3 tools/diagnostics/macos_tooltip_canvas.py'));
assert.ok(observe.includes('--repo "$PWD"'));
assert.ok(observe.includes('--app "$RUNNER_TEMP/tooltip-hammerspoon/Hammerspoon.app"'));
assert.doesNotMatch(canvas, /tccutil|continue-on-error:\s*true|if:\s*false|\|\|\s*true/);
const retain = pipeline.step(
	canvas,
	'Retain native captures, source, provisioning and retirement receipts'
);
assert.equal(pipeline.stepField(retain, 'if'), 'always()');
assert.ok(retain.includes('if-no-files-found: error'));
assert.ok(
	retain.includes(
		'macos-tooltip-canvas-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}'
	)
);
assert.ok(retain.includes('${{ runner.temp }}/tooltip-canvas-evidence'));
assert.ok(retain.includes('${{ runner.temp }}/tooltip-provisioning'));

const root = path.resolve(__dirname, '..', '..');
const calls = [];
const silent = { log: () => {}, error: () => {} };
const completed = { status: 0, stdout: '', stderr: 'Ran 48 tests in 0.01s\n\nOK\n' };
assert.equal(
	run({
		...silent,
		env: { PYTHON: 'selected-python' },
		spawn: (...args) => {
			calls.push(args);
			return completed;
		}
	}),
	0
);
assert.equal(calls[0][0], 'selected-python');
assert.equal(calls[0][2].cwd, root);
assert.deepEqual(calls[0][1], [
	'-m',
	'unittest',
	'discover',
	'-s',
	'tools/diagnostics',
	'-p',
	'macos_tooltip_canvas_test.py',
	'-v'
]);
for (const receipt of [
	{ ...completed, status: 1 },
	{ ...completed, status: null },
	{ ...completed, error: new Error('Python unavailable') },
	{ ...completed, stderr: 'Ran 0 tests in 0.01s\n\nOK\n' },
	{ ...completed, stderr: 'Ran 37 tests in 0.01s\n\nOK\n' },
	{ ...completed, stderr: 'Ran 38 tests in 0.01s\n\nOK\n' },
	{ ...completed, stderr: 'Ran 44 tests in 0.01s\n\nOK\n' },
	{ ...completed, stderr: 'Ran 45 tests in 0.01s\n\nOK (skipped=1)\n' },
	{ ...completed, stderr: 'Ran 45 tests in 0.01s\n\nOK\n' },
	{ ...completed, stderr: 'Ran 47 tests in 0.01s\n\nOK\n' },
	{ ...completed, stderr: 'Ran 48 tests in 0.01s\n\nOK (skipped=1)\n' },
	{ ...completed, stderr: 'Ran 38 tests in 0.01s\n\nOK (skipped=1)\n' }
])
	assert.equal(run({ ...silent, spawn: () => receipt }), 1);

assert.equal(GATE_COMMANDS['macos-tooltip-canvas'].npm, 'test:macos-tooltip-canvas');
for (const file of [
	'tools/diagnostics/macos_tooltip_canvas.py',
	'tools/diagnostics/macos_tooltip_canvas.lua',
	'tools/diagnostics/macos_tooltip_canvas_observer.py',
	'tools/diagnostics/macos_tooltip_canvas_test.py',
	'tools/diagnostics/macos_owned_process.py',
	'tools/test/run-macos-tooltip-canvas-tests.cjs'
]) {
	assert(
		selectGates([file]).has('macos-tooltip-canvas'),
		`${file}: pure controls must be selected`
	);
	assert(
		selectGates([file]).has('js'),
		`${file}: wiring and independent admission must be selected`
	);
}
assert(selectGates(['.github/workflows/ci-macos.yml']).has('js'));
console.log(
	'Mandatory macOS canvas job, inherited desktop evidence and pure Python registration admitted.'
);
