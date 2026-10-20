// tools/test/test-macos-tooltip-canvas-admission.cjs

/**
 * ==============================================================================
 * MODULE: Mandatory macOS Tooltip Canvas Admission Tests
 * DESCRIPTION:
 * Requires the native canvas job before desktop admission and keeps its execution
 * unconditional on a separate Mac host. Missing GUI or cleanup cannot be hidden
 * behind a skipped job, while packaged launch evidence remains mandatory. Pure
 * Python and Lua observer controls inspect receipts, never native pixels.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { verify } = require('./desktop-ci-evidence.cjs');
const { coldBootstrapRecord } = require('./fixtures/macos-cold-bootstrap-receipt.cjs');
const pipeline = require('./ci-full-default.cjs');
const macRole = require('./fixtures/macos-stage-source.cjs');
const macPlans = require('../ci/macos-stage-roles.cjs');
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
		() =>
			verify(
				state({
					...oldNeeds,
					...independentNeeds,
					'tooltip-canvas': { result }
				})
			),
		/tooltip-canvas did not succeed/
	);
}
assert.throws(
	() =>
		verify(
			state({
				...oldNeeds,
				...independentNeeds,
				'tooltip-canvas': { result: 'success' }
			})
		),
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

const canvasStage = pipeline.job('e2e-hs');
const canvas = macRole.body(pipeline.file('.github/workflows/ci-macos.yml'), 'tooltip-canvas');
assert.deepEqual(pipeline.needsOf(canvasStage), ['test-hs']);
assert.equal(
	pipeline.field(canvasStage, 'runs-on'),
	'${{ fromJSON(needs.test-hs.outputs.e2e_metadata)[matrix.lot].runner }}'
);
assert.equal(pipeline.field(canvasStage, 'if'), null);
assert.equal(pipeline.field(canvasStage, 'continue-on-error'), null);
assert.equal(
	pipeline.field(canvasStage, 'timeout-minutes'),
	'${{ fromJSON(needs.test-hs.outputs.e2e_metadata)[matrix.lot].timeout_minutes }}'
);
for (const release of [false, true])
	for (const event_name of ['push', 'pull_request', 'workflow_dispatch']) {
		const cells = macPlans.plan('e2e', {
			source_sha: 'a'.repeat(40),
			run_id: '1',
			event_name,
			release,
			scenarios: ['clean']
		});
		assert.deepEqual(
			cells.filter((cell) => cell.role === 'tooltip-canvas'),
			[
				{
					role: 'tooltip-canvas',
					runner: 'macos-15',
					architecture: 'arm64',
					timeout_minutes: 10,
					scenario: ''
				}
			]
		);
	}
assert.deepEqual(pipeline.needsOf(pipeline.job('macos-ok')), ['launch']);
assert.ok(
	pipeline
		.step(pipeline.job('macos-ok'), 'Require the complete source-bound stage chain')
		.includes('macos-stage-roles.cjs verdict')
);
assert.ok(canvas.includes("python-version: '3.13'"));
const prepare = pipeline.step(canvas, 'Prepare independent pixel observer');
const acquire = pipeline.step(canvas, 'Acquire the pinned official Hammerspoon runtime');
const observe = pipeline.step(
	canvas,
	'Observe actual production canvas pixels and retire its native owner'
);
for (const step of [prepare, acquire, observe]) {
	assert.equal(pipeline.stepField(step, 'if'), macRole.condition('tooltip-canvas'));
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
assert.equal(pipeline.stepField(retain, 'if'), macRole.condition('tooltip-canvas', 'always()'));
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
const completed = {
	status: 0,
	stdout: '',
	stderr: 'Ran 54 tests in 0.01s\n\nOK\n'
};
const bindingCompleted = {
	...completed,
	stderr: 'Ran 34 tests in 0.01s\n\nOK\n'
};
const physicalCompleted = {
	...completed,
	stderr: 'Ran 23 tests in 0.01s\n\nOK\n'
};
const pickerCompleted = {
	...completed,
	stderr: 'Ran 19 tests in 0.01s\n\nOK\n'
};
const layoutCompleted = {
	...completed,
	stderr: 'Ran 22 tests in 0.01s\n\nOK\n'
};
const permissionCompleted = {
	...completed,
	stderr: 'Ran 23 tests in 0.01s\n\nOK\n'
};
const observerCompleted = {
	status: 0,
	stderr: '',
	stdout:
		Array.from({ length: 14 }, (_, index) => `PASS_PURE_OBSERVER\tcase ${index + 1}\n`).join('') +
		'PURE_OBSERVER_ONLY\t14\n'
};
/** Models process receipts independently from either Python or Lua implementation. */
function successfulControl(_command, args) {
	if (args[0] === '-v') return { status: 0, stdout: 'Lua 5.4', stderr: '' };
	if (args[0].endsWith('_observer_test.lua')) return observerCompleted;
	const receipts = {
		'macos_tooltip_canvas_test.py': completed,
		'macos_webview_binding_test.py': bindingCompleted,
		'macos_physical_shortcuts_close_test.py': physicalCompleted,
		'macos_action_picker_pool_test.py': pickerCompleted,
		'macos_layout_manager_pool_test.py': layoutCompleted,
		'macos_permission_dialog_pool_test.py': permissionCompleted
	};
	return receipts[args[6]] || { status: 1, stdout: '', stderr: 'unexpected control' };
}
assert.equal(
	run({
		...silent,
		env: { PYTHON: 'selected-python' },
		spawn: (...args) => {
			calls.push(args);
			return successfulControl(...args);
		}
	}),
	0
);
assert.equal(calls[0][0], 'selected-python');
assert.equal(calls.length, 11);
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
assert.equal(calls[1][0], 'selected-python');
assert.equal(calls[1][2].cwd, root);
assert.deepEqual(calls[1][1], [
	'-m',
	'unittest',
	'discover',
	'-s',
	'tools/diagnostics',
	'-p',
	'macos_webview_binding_test.py',
	'-v'
]);
assert.deepEqual(calls[2][1], [
	'-m',
	'unittest',
	'discover',
	'-s',
	'tools/diagnostics',
	'-p',
	'macos_physical_shortcuts_close_test.py',
	'-v'
]);
assert.deepEqual(calls[3][1], [
	'-m',
	'unittest',
	'discover',
	'-s',
	'tools/diagnostics',
	'-p',
	'macos_action_picker_pool_test.py',
	'-v'
]);
for (const [offset, script] of [
	[4, 'macos_layout_manager_pool_test.py'],
	[5, 'macos_permission_dialog_pool_test.py']
]) {
	assert.equal(calls[offset][0], 'selected-python');
	assert.deepEqual(calls[offset][1], [
		'-m',
		'unittest',
		'discover',
		'-s',
		'tools/diagnostics',
		'-p',
		script,
		'-v'
	]);
	assert.equal(calls[offset][2].cwd, root);
}
assert.deepEqual(calls[6].slice(0, 2), ['luajit', ['-v']]);
for (const [offset, script] of [
	[7, 'macos_layout_manager_pool_observer_test.lua'],
	[9, 'macos_permission_dialog_pool_observer_test.lua']
]) {
	for (const [index, order] of ['forward', 'reverse'].entries()) {
		assert.equal(calls[offset + index][0], 'luajit');
		assert(
			!calls[offset + index][1][0].includes('\\'),
			'Lua source directory locators require forward slashes, including on Windows'
		);
		assert.deepEqual(calls[offset + index][1], [
			path.join(root, 'tools', 'diagnostics', script).replaceAll('\\', '/'),
			order,
			path.join(root, 'static', 'ergopti_plus')
		]);
		assert.deepEqual(calls[offset + index][2], {
			cwd: root,
			env: { PYTHON: 'selected-python' },
			encoding: 'utf8'
		});
	}
}
for (const [script, count] of [
	['macos_layout_manager_pool_test.py', 22],
	['macos_permission_dialog_pool_test.py', 23]
]) {
	for (const receipt of [
		{ ...completed, status: 1 },
		{ ...completed, status: null },
		{ ...completed, status: '0' },
		{ ...completed, error: new Error('missing Python controls') },
		{ ...completed, stderr: '' },
		{ ...completed, stderr: `Ran 0${count} tests in 0.01s\n\nOK\n` },
		{ ...completed, stderr: `Ran ${count} tests in 0.01s\n\nOK\nRan 0 tests in 0.01s\n\nOK\n` },
		{ ...completed, stderr: `Ran ${count} tests in 0.01s\n\nOK\nFAILED (failures=1)\n` },
		...[0, count - 1, count + 1].map((value) => ({
			...completed,
			stderr: `Ran ${value} tests in 0.01s\n\nOK\n`
		})),
		{ ...completed, stderr: `Ran ${count} tests in 0.01s\n\nOK (skipped=1)\n` },
		{
			...completed,
			stderr: `Ran ${count} tests in 0.01s\n\nOK\n`,
			stdout: 'test_x ... skipped'
		},
		{
			...completed,
			stderr: { toString: () => `Ran ${count} tests in 0.01s\n\nOK\n` }
		},
		{
			...completed,
			stderr: `Ran ${count} tests in 0.01s\n\nOK\n`,
			signal: 'SIGTERM'
		}
	])
		assert.equal(
			run({
				...silent,
				spawn: (command, args) => (args[6] === script ? receipt : successfulControl(command, args))
			}),
			1
		);
}
for (const script of [
	'macos_layout_manager_pool_observer_test.lua',
	'macos_permission_dialog_pool_observer_test.lua'
]) {
	for (const order of ['forward', 'reverse']) {
		for (const receipt of [
			{ ...observerCompleted, status: 1 },
			{ ...observerCompleted, status: null },
			{ ...observerCompleted, status: '0' },
			{ ...observerCompleted, error: new Error('missing Lua observer') },
			{ ...observerCompleted, signal: 'SIGTERM' },
			{ ...observerCompleted, stdout: '' },
			{
				...observerCompleted,
				stdout: observerCompleted.stdout.replace('case 14', 'case 13')
			},
			{
				...observerCompleted,
				stdout: observerCompleted.stdout.replace('PASS_PURE_OBSERVER\tcase 14\n', '')
			},
			{
				...observerCompleted,
				stdout: observerCompleted.stdout.replace('ONLY\t14', 'ONLY\t13')
			},
			{
				...observerCompleted,
				stdout: observerCompleted.stdout.replace('ONLY\t14', 'ONLY\t014')
			},
			{
				...observerCompleted,
				stdout: observerCompleted.stdout.replace('PASS_PURE_OBSERVER', 'SKIP_PURE_OBSERVER')
			},
			{
				...observerCompleted,
				stdout: observerCompleted.stdout + 'unexpected output\n'
			},
			{ ...observerCompleted, stderr: 'observer failed' },
			{
				...observerCompleted,
				stdout: { toString: () => observerCompleted.stdout }
			}
		])
			assert.equal(
				run({
					...silent,
					spawn: (command, args) =>
						args[0] === path.join(root, 'tools', 'diagnostics', script).replaceAll('\\', '/') &&
						args[1] === order
							? receipt
							: successfulControl(command, args)
				}),
				1
			);
	}
}
const noRuntime = [];
assert.equal(
	run({
		...silent,
		spawn: (command, args) => {
			if (args[0] !== '-v') return successfulControl(command, args);
			noRuntime.push(command);
			return {
				error: Object.assign(new Error('missing runtime'), { code: 'ENOENT' })
			};
		}
	}),
	1
);
assert.deepEqual(noRuntime, ['luajit', 'lua5.4', 'lua']);
assert.equal(
	run({
		...silent,
		spawn: (command, args) =>
			args[0] === '-v'
				? { status: 1, stderr: 'broken installed runtime' }
				: successfulControl(command, args)
	}),
	1
);

for (const receipt of [
	{ ...pickerCompleted, status: 1 },
	{ ...pickerCompleted, status: null },
	{ ...pickerCompleted, error: new Error('ActionPicker Python unavailable') },
	{ ...pickerCompleted, stderr: 'Ran 0 tests in 0.01s\n\nOK\n' },
	{ ...pickerCompleted, stderr: 'Ran 18 tests in 0.01s\n\nOK\n' },
	{ ...pickerCompleted, stderr: 'Ran 19 tests in 0.01s\n\nOK (skipped=1)\n' }
]) {
	assert.equal(
		run({
			...silent,
			spawn: (_python, args) =>
				args[6] === 'macos_action_picker_pool_test.py'
					? receipt
					: args[6] === 'macos_webview_binding_test.py'
						? bindingCompleted
						: args[6] === 'macos_physical_shortcuts_close_test.py'
							? physicalCompleted
							: completed
		}),
		1
	);
}
for (const receipt of [
	{ ...physicalCompleted, status: 1 },
	{ ...physicalCompleted, status: null },
	{
		...physicalCompleted,
		error: new Error('Physical interpreter unavailable')
	},
	{ ...physicalCompleted, stderr: 'Ran 0 tests in 0.01s\n\nOK\n' },
	{ ...physicalCompleted, stderr: 'Ran 21 tests in 0.01s\n\nOK\n' },
	{ ...physicalCompleted, stderr: 'Ran 22 tests in 0.01s\n\nOK\n' },
	{ ...physicalCompleted, stderr: 'Ran 23 tests in 0.01s\n\nOK (skipped=1)\n' }
]) {
	assert.equal(
		run({
			...silent,
			spawn: (_python, args) =>
				args[6] === 'macos_physical_shortcuts_close_test.py'
					? receipt
					: args[6] === 'macos_webview_binding_test.py'
						? bindingCompleted
						: completed
		}),
		1
	);
}
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
	{ ...completed, stderr: 'Ran 48 tests in 0.01s\n\nOK\n' },
	{ ...completed, stderr: 'Ran 53 tests in 0.01s\n\nOK\n' },
	{ ...completed, stderr: 'Ran 38 tests in 0.01s\n\nOK (skipped=1)\n' }
])
	assert.equal(run({ ...silent, spawn: () => receipt }), 1);

for (const receipt of [
	{ ...bindingCompleted, status: 1 },
	{ ...bindingCompleted, status: null },
	{ ...bindingCompleted, error: new Error('Binding interpreter unavailable') },
	{ ...bindingCompleted, stderr: 'Ran 0 tests in 0.01s\n\nOK\n' },
	{ ...bindingCompleted, stderr: 'Ran 17 tests in 0.01s\n\nOK\n' },
	{ ...bindingCompleted, stderr: 'Ran 18 tests in 0.01s\n\nOK\n' },
	{ ...bindingCompleted, stderr: 'Ran 20 tests in 0.01s\n\nOK\n' },
	{ ...bindingCompleted, stderr: 'Ran 21 tests in 0.01s\n\nOK\n' },
	{ ...bindingCompleted, stderr: 'Ran 18 tests in 0.01s\n\nOK (skipped=1)\n' },
	{ ...bindingCompleted, stderr: 'Ran 21 tests in 0.01s\n\nOK (skipped=1)\n' },
	{ ...bindingCompleted, stderr: 'Ran 22 tests in 0.01s\n\nOK (skipped=1)\n' },
	{ ...bindingCompleted, stderr: 'Ran 32 tests in 0.01s\n\nOK\n' },
	{ ...bindingCompleted, stderr: 'Ran 33 tests in 0.01s\n\nOK (skipped=1)\n' },
	{ ...bindingCompleted, stderr: 'Ran 33 tests in 0.01s\n\nOK\n' },
	{ ...bindingCompleted, stderr: 'Ran 34 tests in 0.01s\n\nOK (skipped=1)\n' }
]) {
	assert.equal(
		run({
			...silent,
			spawn: (_python, args) => (args[6] === 'macos_webview_binding_test.py' ? receipt : completed)
		}),
		1
	);
}

assert.equal(GATE_COMMANDS['macos-tooltip-canvas'].npm, 'test:macos-tooltip-canvas');
for (const file of [
	'tools/diagnostics/macos_tooltip_canvas.py',
	'tools/diagnostics/macos_tooltip_canvas.lua',
	'tools/diagnostics/macos_tooltip_canvas_observer.py',
	'tools/diagnostics/macos_tooltip_canvas_test.py',
	'tools/diagnostics/macos_webview_binding.lua',
	'tools/diagnostics/macos_webview_binding.py',
	'tools/diagnostics/macos_webview_binding_test.py',
	'tools/diagnostics/macos_webview_raw_delete.lua',
	'tools/diagnostics/macos_physical_shortcuts_close.lua',
	'tools/diagnostics/macos_physical_shortcuts_close.py',
	'tools/diagnostics/macos_physical_shortcuts_close_test.py',
	'tools/diagnostics/macos_action_picker_pool.lua',
	'tools/diagnostics/macos_action_picker_pool.py',
	'tools/diagnostics/macos_action_picker_pool_observer.lua',
	'tools/diagnostics/macos_action_picker_pool_test.py',
	'tools/diagnostics/macos_layout_manager_pool.lua',
	'tools/diagnostics/macos_layout_manager_pool.py',
	'tools/diagnostics/macos_layout_manager_pool_test.py',
	'tools/diagnostics/macos_layout_manager_pool_observer.lua',
	'tools/diagnostics/macos_layout_manager_pool_observer_test.lua',
	'tools/diagnostics/macos_permission_dialog_pool.lua',
	'tools/diagnostics/macos_permission_dialog_pool.py',
	'tools/diagnostics/macos_permission_dialog_pool_test.py',
	'tools/diagnostics/macos_permission_dialog_pool_observer.lua',
	'tools/diagnostics/macos_permission_dialog_pool_observer_test.lua',
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
assert(selectGates(['tools/diagnostics/macos_action_picker_pool_observer.lua']).has('hs'));
assert(selectGates(['.github/workflows/ci-macos.yml']).has('js'));
console.log(
	'Mandatory macOS canvas job, inherited desktop evidence and pure Python/Lua observer registration admitted.'
);
