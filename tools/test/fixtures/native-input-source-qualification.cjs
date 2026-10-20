// tools/test/fixtures/native-input-source-qualification.cjs
'use strict';

/** Owns only the input-source native selector, refusal controls and portable isolation tests. */
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { pythonExecutable } = require('../../lib/python.cjs');
const ROOT = path.resolve(__dirname, '../../..');

module.exports = function createInputSourceQualification(guardedStep) {
	// This independent selector qualifies the native command and launcher cohorts, retaining the
	// blanket refusal for every full-package or foreign exclusion.
	const INPUT_SOURCE_FILTER = '--filter "(^|[.])$classname([/.]|$)"';
	const INPUT_SOURCE_STEP_SOURCE = guardedStep(
		'managed-ollama-native',
		fs.readFileSync(path.join(__dirname, 'native-input-source-command-step.txt'), 'utf8')
	);
	function admitNativeInputSourceSelector(mac) {
		if (mac.split(INPUT_SOURCE_FILTER).length !== 2) return null;
		const jobs = [...mac.matchAll(/^  e2e-hs:\n[\s\S]*?(?=^  [A-Za-z][\w-]*:|(?![\s\S]))/gm)];
		if (jobs.length !== 1) return null;
		const steps = [
			...jobs[0][0].matchAll(
				/^      - name: Qualify native input-source and launcher XCTest controls\n[\s\S]*?(?=^      - |(?![\s\S]))/gm
			)
		];
		if (steps.length !== 1) return null;
		const step = steps[0][0];
		if (step !== INPUT_SOURCE_STEP_SOURCE) return null;
		const carbon = jobs[0][0].indexOf(
			'      - name: Retain selected number-row Carbon XCTest diagnostics\n'
		);
		const pac = jobs[0][0].indexOf(
			'      - name: Qualify actual native PAC source ownership XCTest controls\n'
		);
		if (carbon < 0 || steps[0].index <= carbon || pac <= steps[0].index) return null;
		const position = jobs[0].index + steps[0].index + step.indexOf(INPUT_SOURCE_FILTER);
		return mac.slice(0, position) + mac.slice(position + INPUT_SOURCE_FILTER.length);
	}

	function runInputSourceControls({ workflow, admitNativeSdkSelector }) {
		// The separate census preserves the historical owner's control counts.
		assert.equal(
			admitNativeInputSourceSelector(workflow),
			workflow.replace(INPUT_SOURCE_FILTER, '')
		);
		const inputSourceStep =
			/^      - name: Qualify native input-source and launcher XCTest controls\n[\s\S]*?(?=^      - |(?![\s\S]))/m.exec(
				workflow
			)?.[0];
		assert.ok(inputSourceStep);
		let inputSourceSelectorControls = 0;
		for (const [from, to] of [
			[INPUT_SOURCE_FILTER, "--filter 'NativeInputSourceSelectionTests'"],
			[INPUT_SOURCE_FILTER, INPUT_SOURCE_FILTER + ' ' + INPUT_SOURCE_FILTER],
			['receipt.expected_count !== expectedCount', 'receipt.expected_count !== expectedCount - 1'],
			['receipt.received_count !== expectedCount', 'receipt.received_count !== expectedCount - 1'],
			['${input_source_statuses[0]}', '0'],
			['${input_source_statuses[1]}', '0'],
			['NativeInputSourceSelectionTests.swift', 'ForeignTests.swift'],
			['modules/keymap/input_sources.lua', 'modules/keymap/foreign.lua'],
			['test "$(git rev-parse HEAD)" = "$GITHUB_SHA"', ': "$GITHUB_SHA"'],
			['test "$architecture" = "$MACOS_STAGE_ARCHITECTURE"', ': "$MACOS_STAGE_ARCHITECTURE"'],
			['keyboard_geometry_xctest_receipt.py', 'missing_receipt.py'],
			['        shell: bash', '        continue-on-error: true\n        shell: bash']
		]) {
			assert.ok(inputSourceStep.includes(from));
			const changed = workflow.replace(inputSourceStep, inputSourceStep.replace(from, to));
			assert.equal(admitNativeInputSourceSelector(changed), null);
			assert.equal(admitNativeSdkSelector(changed), null);
			inputSourceSelectorControls++;
		}
		assert.equal(inputSourceSelectorControls, 12);
		console.log('PASS: native input-source exact-selector controls=12; native execution UNRUN.');
		let inputSourceCohortControls = 0;
		for (const [from, to] of [
			['NativeInputSourceSelectionTests:4', 'NativeInputSourceSelectionTests:3'],
			[' EmbeddedFatalReportTests:11', ''],
			['then overall_status=1; fi', 'then overall_status=1; break; fi']
		]) {
			assert.equal(inputSourceStep.split(from).length, 2);
			const changed = workflow.replace(inputSourceStep, inputSourceStep.replace(from, to));
			assert.equal(admitNativeInputSourceSelector(changed), null);
			assert.equal(admitNativeSdkSelector(changed), null);
			inputSourceCohortControls++;
		}
		assert.equal(inputSourceCohortControls, 3);
		console.log('PASS: native input-source closed-cohort controls=3; native execution UNRUN.');
		for (const [from, to] of [
			['for phase in forward reverse; do', 'for phase in forward; do'],
			['tools/diagnostics/input_source_xctest_isolation.py', 'tools/diagnostics/foreign.py'],
			[
				'--phase "$phase"; then\n              overall_status=1',
				'--phase "$phase"; then\n              overall_status=0'
			]
		]) {
			assert.ok(inputSourceStep.includes(from));
			const changed = workflow.replace(inputSourceStep, inputSourceStep.replaceAll(from, to));
			assert.equal(admitNativeInputSourceSelector(changed), null);
			assert.equal(admitNativeSdkSelector(changed), null);
		}
		console.log(
			'PASS: native input-source isolation execution controls=3; native execution UNRUN.'
		);
		const inputSourceComparisons =
			'          for source in "${sources[@]}"; do\n' +
			'            cmp "$source" "$evidence/$(basename "$source")"\n' +
			'          done\n';
		assert.equal(inputSourceStep.split(inputSourceComparisons).length, 2);
		for (const [name, step] of [
			[
				'early success',
				inputSourceStep.replace('          set +e\n', '          exit 0\n          set +e\n')
			],
			[
				'nonexecuting validator',
				inputSourceStep.replace('node - "$receipt" "$classname" "$expected_count"', 'cat')
			],
			[
				'comparisons before native execution',
				inputSourceStep
					.replace(inputSourceComparisons, '')
					.replace('          set +e\n', inputSourceComparisons + '          set +e\n')
			]
		]) {
			assert.notEqual(step, inputSourceStep, name);
			const changed = workflow.replace(inputSourceStep, () => step);
			assert.equal(admitNativeInputSourceSelector(changed), null, name);
			assert.equal(admitNativeSdkSelector(changed), null, name);
		}
		console.log('PASS: native input-source execution-bypass controls=3; native execution UNRUN.');
		// Pipeline owns these controls even when standalone leaf delegations are disabled.
		// A bare "python3" is the Microsoft Store alias on Windows, not CPython.
		execFileSync(
			pythonExecutable(),
			[path.join(__dirname, '../test_input_source_xctest_isolation.py')],
			{
				cwd: ROOT,
				stdio: 'pipe'
			}
		);
		// Windows has no POSIX process groups: the Python file skips those three.
		if (process.platform === 'win32')
			console.log(
				'SKIP (not executed): 3 isolated input-source process-group controls need POSIX process groups; hosted CI lanes execute them'
			);
		console.log(
			`PASS: isolated native input-source receipt controls=${process.platform === 'win32' ? 14 : 17}; Swift/native execution UNRUN.`
		);
	}

	return { admitNativeInputSourceSelector, runInputSourceControls };
};
