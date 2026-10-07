// tools/test/test-windows-native-desktop.cjs

/** Requires the real desktop runner, its exact native receipts and mandatory CI evidence. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');
const { stripComments } = require('../lib/script-source.cjs');

const root = path.resolve(__dirname, '../..');
const runner = fs.readFileSync(path.join(__dirname, 'run-windows-native-desktop.ps1'), 'utf8');
const expected = [
	'Console capture: real hidden Edit reads remain stale (native-console-capture)',
	'Console capture: public refresh exposes the real runtime (native-console-capture)',
	'Console capture: final-state restoration retains native disruption (native-console-capture)',
	'Console capture: KeyHistory capacity is not fresh capture (native-console-capture)',
	'Console capture: three native causal controls break independent proofs (native-console-capture)',
	'key combinations: standard AltGr suffix chooses its actual pair hold owner (todo91-altgr-suffix)',
	'key combinations: native AltGr prefix does not supply an admitted first key (todo91-altgr-suffix)',
	'key combinations: suppressed AltGr pair returns the fake Ctrl owner before action (todo91-altgr-suffix)',
	'key combinations: native AltGr pair retains and closes its Ctrl release debt (todo91-altgr-suffix)',
	'key combinations: custom AltGr variants are registered before the standalone owner (todo91-altgr-suffix)',
	'key combinations: interpreted native hook selects the earlier custom AltGr owner with bypass control (todo91-altgr-suffix)'
];

/** Preserve the reviewed canonical asynchronous native-handle and exact completion policy. */
function checkRunner(source) {
	source = source.replace(/^\s*#.*$/gm, '');
	assert.match(source, /if \(Test-Path -LiteralPath \$evidence\) \{ throw/);
	assert.match(source, /Start-Process -FilePath \$ahk/);
	assert.match(source, /\$null = \$proc\.Handle/);
	assert.match(source, /while \(-not \$proc\.HasExited\)/);
	assert.match(source, /\$proc\.WaitForExit\(\)/);
	assert.match(source, /\$record\.native_exit = \$proc\.ExitCode/);
	assert.match(source, /\$NativeExit -isnot \[int\]/);
	assert.match(source, /\$NativeExit -ne 0/);
	assert.match(source, /\$Stdout\) -cne \(& \$normalize \$Transcript\)/);
	assert.match(source, /IsNullOrWhiteSpace\(\$Stderr\)/);
	assert.match(source, /\$Manifest\.timed_count -ne \$count/);
	assert.match(source, /\$entry\.name -cne \$ExpectedNames\[\$index\]/);
	assert.match(source, /\$summary\.executed_cases -ne 11/);
	assert.match(source, /@\(\$summary\.runs\)\.Count -ne 2/);
	assert.match(source, /foreach \(\$cohort in \$cohorts\)/);
	assert.match(source, /--interactive --only \$\(\$cohort\.filter\)/);
	assert.match(source, /validate-ahk-suite-manifest\.cjs/);
	assert.match(source, /if \(\$LASTEXITCODE -ne 0\) \{ throw/);
	assert.match(source, /\$env:ERGOPTI_AHK_RESULTS_FILE = \$previousReceipt/);
	assert.match(source, /\$summary\.status = 'failed'/);
	assert.doesNotMatch(source, /--only[^\r\n]*native-console-capture\|todo91-altgr-suffix/);
	for (const name of expected) assert.equal(source.split("'" + name + "'").length, 2);
}

/** The unqualified ordinary main suite cannot stand in for interactive desktop observations. */
function checkWorkflow(body) {
	const main = pipeline.step(body, 'Run AHK test suite');
	const native = pipeline.step(body, 'Run native desktop AHK cohorts');
	const upload = pipeline.step(body, 'Publish native desktop AHK evidence');
	assert.equal(pipeline.stepField(native, 'run'), './tools/test/run-windows-native-desktop.ps1');
	assert.equal(pipeline.stepField(native, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(native, 'timeout-minutes'), '25');
	assert.equal(pipeline.stepField(native, 'if'), null);
	assert.equal(pipeline.stepField(native, 'continue-on-error'), null);
	assert.ok(body.indexOf(main) < body.indexOf(native));
	assert.ok(body.indexOf(native) < body.indexOf(upload));
	assert.equal(pipeline.stepField(upload, 'if'), 'always()');
	assert.equal(pipeline.stepField(upload, 'uses'), 'actions/upload-artifact@v4');
	assert.equal(pipeline.stepField(upload, 'continue-on-error'), null);
	assert.match(upload, /name: windows-ahk-native-desktop\n/);
	assert.match(upload, /path: \$\{\{ runner\.temp \}\}\/windows-ahk-native-desktop\/\n/);
	assert.match(upload, /if-no-files-found: error/);
	assert.match(upload, /overwrite: true/);
}

/** Follows one real authored cohort include, refusing absent or duplicate ownership. */
function readCohortOwner(file) {
	const names = new Map([
		['unit/test_console_window.ahk', 'console_capture_cohort.ahk'],
		['unit/test_key_combinations.ahk', 'altgr_suffix_cohort.ahk']
	]);
	assert.ok(names.has(file));
	const owner = fs.readFileSync(path.join(root, 'static/ergopti_plus/windows/tests', file), 'utf8');
	const include = '#Include ../support/' + names.get(file);
	const code = stripComments(owner, '.ahk');
	assert.equal(
		code.split(include).length,
		2,
		'the original owner has exactly one actual cohort include'
	);
	assert.match(code, new RegExp('^' + include.replace(/[.*+?^${}()|[\\]\\]/g, '\\$&') + '$', 'm'));
	const shared = fs.readFileSync(
		path.join(root, 'static/ergopti_plus/windows/tests/support', names.get(file)),
		'utf8'
	);
	assert.ok(shared.length > 1000, 'the actual shared cohort must contain its source definitions');
	return owner + '\n' + shared;
}

/** Keeps the canonical producer narrow while every stdout diagnostic still refuses. */
function checkDesktopOwner(source, sources) {
	const code = stripComments(source, '.ahk');
	assert.match(code, /^#Warn All, StdOut$/m);
	assert.match(code, /^#Warn VarUnset, Off$/m);
	assert.match(code, /^#Include test_framework\.ahk$/m);
	assert.match(code, /^_TestResultsBeginRun\(\)$/m);
	assert.match(code, /^#Include support\/console_capture_cohort\.ahk$/m);
	assert.match(code, /^#Include support\/altgr_suffix_cohort\.ahk$/m);
	assert.match(code, /^RunTests\(\)$/m);
	const outputCalls = (code.match(/\bFileAppend\(/g) || []).length;
	assert.equal(
		outputCalls,
		2,
		'only argument refusal and the retained watchdog own direct diagnostics'
	);
	assert.match(code, /^SetTimer\(_WatchdogFire, -_SUITE_TIMEOUT_MS\)$/m);
	assert.match(code, /^global _SUITE_TIMEOUT_MS := 1320000$/m);
	const included = [...code.matchAll(/^#Include ([^\r\n]+)$/gm)].map((match) => match[1]);
	assert.deepEqual(included, [
		'test_framework.ahk',
		'../infra/tick_count.ahk',
		'../infra/wall_clock.ahk',
		'../infra/logger.ahk',
		'../infra/toml/toml_helpers.ahk',
		'../platform/remap/tap_hold_loader.ahk',
		'../platform/remap/tap_hold_writer.ahk',
		'../adapters/key_state.ahk',
		'../adapters/text_sender.ahk',
		'../adapters/shell_runner.ahk',
		'../platform/remap/constants.ahk',
		'../platform/remap/altgr_criteria.ahk',
		'../infra/key_combinations.ahk',
		'support/console_capture_cohort.ahk',
		'support/altgr_suffix_cohort.ahk'
	]);
	const registrations = sources.flatMap((item) =>
		[...stripComments(item, '.ahk').matchAll(/^Test\("([^"\r\n]+)"/gm)].map((match) => match[1])
	);
	assert.deepEqual(
		registrations,
		expected,
		'the canonical producer registers only the eleven original ordered cases'
	);
	for (const cohort of sources) {
		assert.ok(cohort.length > 1000);
		assert.match(
			cohort,
			/^[A-Za-z_][A-Za-z_0-9]*\([^\r\n]*\) \{$/m,
			'the registration subject retains actual callable definitions'
		);
	}
	assert.deepEqual(
		[...code.matchAll(/^#Warn ([^\r\n]+)$/gm)].map((match) => match[1]),
		['All, StdOut', 'VarUnset, Off']
	);
	assert.doesNotMatch(code, /#Include .*run_all|#Include .*test_stubs/);
}

checkRunner(runner);
const body = pipeline.job('test-ahk');
checkWorkflow(body);
const registrations = ['unit/test_console_window.ahk', 'unit/test_key_combinations.ahk'].map(
	(file) => stripComments(readCohortOwner(file), '.ahk')
);
for (const name of expected) {
	assert.equal(registrations.join('\n').split('Test("' + name + '",').length, 2);
}
// The source registrations explicitly isolate the six true desktop cases.
assert.equal(
	(registrations[0].match(/native-console-capture\)",\s*[A-Za-z_][A-Za-z_0-9]*, true\)/g) || [])
		.length,
	5
);
assert.equal(
	(registrations[1].match(/todo91-altgr-suffix\)",\s*[A-Za-z_][A-Za-z_0-9]*, true\)/g) || [])
		.length,
	1
);
let refused = 0;
for (const [before, after] of [
	['$null = $proc.Handle', '$null = $null'],
	['$proc.WaitForExit()', '$null = $proc'],
	['$NativeExit -isnot [int]', '$false'],
	['$NativeExit -ne 0', '$false'],
	['$Manifest.timed_count -ne $count', '$false'],
	['$entry.name -cne $ExpectedNames[$index]', '$false'],
	['$summary.executed_cases -ne 11', '$summary.executed_cases -ne 0'],
	['--interactive --only $($cohort.filter)', '--only $($cohort.filter)']
]) {
	const changed = runner.replace(before, after);
	assert.notEqual(changed, runner);
	assert.throws(() => checkRunner(changed));
	refused += 1;
}
for (const [before, after] of [
	['run: ./tools/test/run-windows-native-desktop.ps1', 'run: echo skipped'],
	[
		'run: ./tools/test/run-windows-native-desktop.ps1',
		'if: false\n        run: ./tools/test/run-windows-native-desktop.ps1'
	],
	[
		'run: ./tools/test/run-windows-native-desktop.ps1',
		'continue-on-error: true\n        run: ./tools/test/run-windows-native-desktop.ps1'
	],
	[
		'name: Publish native desktop AHK evidence\n        if: always()',
		'name: Publish native desktop AHK evidence\n        if: success()'
	],
	['path: ${{ runner.temp }}/windows-ahk-native-desktop/', 'path: unrelated/'],
	['if-no-files-found: error', 'if-no-files-found: warn']
]) {
	const changed = body.replace(before, after);
	assert.notEqual(changed, body);
	assert.throws(() => checkWorkflow(changed));
	refused += 1;
}
// PowerShell's actual AST and guard are exercised on Windows. These handwritten
// portable inputs are not native desktop observations or qualification artifacts.
if (process.platform === 'win32') {
	const result = spawnSync(
		'pwsh.exe',
		[
			'-NoProfile',
			'-NonInteractive',
			'-File',
			path.join(__dirname, 'windows-native-desktop-controls.ps1')
		],
		{ encoding: 'utf8', timeout: 30000 }
	);
	assert.equal(result.error, undefined);
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.match(result.stdout, /17 refusals, causal native-exit mutation exposed and restored/);
} else {
	console.log(
		'[SKIP] Windows PowerShell guard execution; workflow and source contracts were checked.'
	);
}
console.log(
	`Windows native desktop wiring PASS: eleven authored cases, six interactive registrations, ${refused} causal source/workflow refusals. Native desktop execution is not claimed.`
);

const desktop = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/tests/run_desktop.ahk'),
	'utf8'
);
const cohorts = ['console_capture_cohort.ahk', 'altgr_suffix_cohort.ahk'].map((file) =>
	fs.readFileSync(path.join(root, 'static/ergopti_plus/windows/tests/support', file), 'utf8')
);
checkDesktopOwner(desktop, cohorts);
assert.match(runner, /tests\\run_desktop\.ahk'/);
for (const [before, after] of [
	['#Warn All, StdOut', '#Warn All, Off'],
	['#Include test_framework.ahk', '#Include test_stubs.ahk'],
	['#Include support/console_capture_cohort.ahk', ''],
	['#Include support/altgr_suffix_cohort.ahk', ''],
	['RunTests()', 'ExitApp(0)'],
	['global _SUITE_TIMEOUT_MS := 1320000', 'global _SUITE_TIMEOUT_MS := 1000'],
	[
		'#Include ../infra/key_combinations.ahk',
		'#Include ../infra/key_combinations.ahk\n#Include unit/test_llm_agent.ahk'
	],
	['RunTests()', 'FileAppend("Warning: extraneous producer", "*")\nRunTests()']
]) {
	const changed = desktop.replace(before, after);
	assert.notEqual(changed, desktop);
	assert.throws(() => checkDesktopOwner(changed, cohorts));
}
for (const [index, changed] of [
	[0, cohorts[0].replace(/^Test\("[^"\r\n]+",\n[^\r\n]+\)\n/m, '')],
	[1, cohorts[1] + '\nTest("foreign producer", () => true)\n']
]) {
	assert.notEqual(changed, cohorts[index]);
	const changedCohorts = [...cohorts];
	changedCohorts[index] = changed;
	assert.throws(() => checkDesktopOwner(desktop, changedCohorts));
}
console.log(
	'Canonical desktop source isolation PASS: eleven unchanged authored registrations and ten causal admission refusals; native AHK remains unrun.'
);
