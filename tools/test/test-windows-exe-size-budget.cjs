// tools/test/test-windows-exe-size-budget.cjs

/**
 * ==============================================================================
 * MODULE: Windows Executable Size Budget Gate
 * DESCRIPTION:
 * Proves that tools/ci/windows-exe-size-budget.cjs rejects a missing, empty or
 * over-budget exe and accepts one at the budget, and that the Windows build
 * stage runs it on the compiled exe after compiling it and before it signs or
 * uploads it. No suite runs a real build, so sparse files stand in for the exe.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');
const {
	WINDOWS_EXE_SIZE_BUDGET_BYTES,
	checkWindowsExeSize
} = require('../ci/windows-exe-size-budget.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(ROOT, 'tools', 'ci', 'windows-exe-size-budget.cjs');
const EXE_REL = 'static/ergopti_plus/windows/ErgoptiPlus.exe';
const STEP = 'Check the ErgoptiPlus.exe size budget';

// v1.0.4 shipped 11403776 bytes; a budget below that would fail every build.
assert.ok(
	Number.isSafeInteger(WINDOWS_EXE_SIZE_BUDGET_BYTES) && WINDOWS_EXE_SIZE_BUDGET_BYTES > 11403776,
	'the budget must admit the last released exe'
);

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-exe-budget-'));
try {
	const sized = (name, bytes) => {
		const file = path.join(root, name);
		fs.writeFileSync(file, '');
		fs.truncateSync(file, bytes);
		return file;
	};
	const atBudget = sized('at.exe', WINDOWS_EXE_SIZE_BUDGET_BYTES);
	const overBudget = sized('over.exe', WINDOWS_EXE_SIZE_BUDGET_BYTES + 1);
	const empty = sized('empty.exe', 0);

	assert.deepEqual(checkWindowsExeSize(atBudget), {
		size: WINDOWS_EXE_SIZE_BUDGET_BYTES,
		budget: WINDOWS_EXE_SIZE_BUDGET_BYTES
	});
	assert.throws(() => checkWindowsExeSize(overBudget), /over the \d+-byte budget by 1 bytes/);
	assert.throws(() => checkWindowsExeSize(empty), /is empty/);
	assert.throws(() => checkWindowsExeSize(path.join(root, 'missing.exe')), /ENOENT/);
	assert.throws(() => checkWindowsExeSize(root), /not a regular file/);
	assert.throws(() => checkWindowsExeSize(atBudget, 0), /Invalid Windows exe size budget/);

	// The CLI is what the workflow runs: its exit status is the gate.
	const run = (args) =>
		spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8', windowsHide: true });
	const pass = run([atBudget]);
	assert.equal(pass.status, 0, pass.stdout + pass.stderr);
	assert.match(pass.stdout, /^\[OK\] /);
	const fail = run([overBudget]);
	assert.equal(fail.status, 1, fail.stdout + fail.stderr);
	assert.match(fail.stderr, /\[FAIL\] .*over the \d+-byte budget/);
	assert.equal(run([]).status, 1, 'the CLI requires exactly one path');
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}

const packageWindows = pipeline.job('package-windows');
const gate = pipeline.step(packageWindows, STEP);
assert.equal(
	pipeline.runOf(gate)?.join('\n'),
	`node tools/ci/windows-exe-size-budget.cjs ${EXE_REL}`,
	'the build stage must run the budget gate on the compiled exe'
);
assert.equal(pipeline.stepField(gate, 'if'), null, 'the budget gate runs on every build');
assert.equal(
	pipeline.stepField(gate, 'continue-on-error'),
	null,
	'a budget failure must fail the build'
);
const names = pipeline.steps(packageWindows).map((candidate) => candidate.name);
const at = names.indexOf(STEP);
assert.ok(
	at > names.indexOf('Compile ErgoptiPlus.ahk') &&
		at < names.indexOf('Sign and verify ErgoptiPlus.exe') &&
		at < names.indexOf('Upload the application and layout'),
	`the budget gate must run after compiling and before signing and upload; got: ${names.join(' | ')}`
);

console.log(
	`[OK] ErgoptiPlus.exe size budget (${WINDOWS_EXE_SIZE_BUDGET_BYTES} bytes) is enforced by the Windows build stage.`
);
