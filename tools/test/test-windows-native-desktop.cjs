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
	const receipt = pipeline.step(body, 'Retain the source-bound Windows qualification receipt');
	const upload = pipeline.step(body, 'Publish native desktop AHK evidence');
	// Keep selection, receipt revalidation and the full runner in one closed
	// protocol. A deferred receipt reports missing proof, never native success.
	assert.deepEqual(pipeline.runOf(native), [
		"$receipt = Join-Path $env:RUNNER_TEMP 'stable-windows-native-desktop.json'",
		'node tools/ci/dev-release-qualification.cjs --scope windows-native-desktop --receipt $receipt',
		"if ($LASTEXITCODE -ne 0) { throw 'Native desktop qualification selection refused.' }",
		'$mode = node tools/ci/dev-release-qualification.cjs --scope windows-native-desktop --validate-scope-receipt $receipt',
		"if ($LASTEXITCODE -ne 0) { throw 'Native desktop qualification receipt refused.' }",
		"if ($mode -ceq 'deferred') {",
		"    Write-Host '[DEFERRED] windows-native-desktop: qualified=false; no desktop cohort executed.'",
		"} elseif ($mode -ceq 'full') {",
		'    ./tools/test/run-windows-native-desktop.ps1',
		'} else {',
		"    throw 'Invalid native desktop qualification disposition.'",
		'}'
	]);
	assert.equal(pipeline.stepField(native, 'shell'), 'pwsh');
	assert.equal(pipeline.stepField(native, 'timeout-minutes'), '25');
	assert.equal(pipeline.stepField(native, 'if'), null);
	assert.equal(pipeline.stepField(native, 'continue-on-error'), null);
	assert.ok(body.indexOf(main) < body.indexOf(native));
	assert.ok(body.indexOf(native) < body.indexOf(receipt));
	assert.ok(body.indexOf(receipt) < body.indexOf(upload));
	assert.equal(pipeline.stepField(receipt, 'if'), 'always()');
	assert.equal(pipeline.stepField(receipt, 'uses'), 'actions/upload-artifact@v4');
	assert.equal(pipeline.stepField(receipt, 'continue-on-error'), null);
	assert.match(receipt, /name: assets-qualification-windows\n/);
	assert.match(receipt, /path: \$\{\{ runner\.temp \}\}\/stable-windows-native-desktop\.json\n/);
	assert.equal(pipeline.stepField(upload, 'if'), 'always()');
	assert.equal(pipeline.stepField(upload, 'uses'), 'actions/upload-artifact@v4');
	assert.equal(pipeline.stepField(upload, 'continue-on-error'), null);
	assert.match(upload, /name: windows-ahk-native-desktop\n/);
	assert.match(
		upload,
		/^          path: \|\n            \$\{\{ runner\.temp \}\}\/windows-ahk-native-desktop\/\n            \$\{\{ runner\.temp \}\}\/stable-windows-native-desktop\.json\n          if-no-files-found: error$/m
	);
	assert.match(upload, /if-no-files-found: error/);
	assert.match(upload, /overwrite: true/);
}

/** Validate every retained wrapper before inspecting this raw native owner. */
function admittedNativeWorkflow(files) {
	const admitted = require('./ci-full-default.cjs').fromFiles(files);
	const file = admitted
		.rawFiles()
		.find((entry) => entry.rel === '.github/workflows/ci-windows.yml');
	const jobs = pipeline.jobsOfText(file.text, file.rel).filter((job) => job.id === 'test-ahk');
	assert.equal(jobs.length, 1);
	return jobs[0].body;
}

checkRunner(runner);
const body = admittedNativeWorkflow(pipeline.files());
checkWorkflow(body);
for (const [before, after] of [
	['  macos:', '  omitted-macos:'],
	['  core:', '  omitted-core:']
]) {
	const files = pipeline.files();
	const caller = files.find((file) => file.rel === '.github/workflows/ci.yml');
	assert.equal(caller.text.split(before).length, 2);
	const changed = files.map((file) =>
		file === caller ? { ...file, text: file.text.replace(before, after) } : file
	);
	assert.throws(() => admittedNativeWorkflow(changed), /ambiguous\/missing job/);
}
const registrations = ['unit/test_console_window.ahk', 'unit/test_key_combinations.ahk'].map(
	(file) =>
		stripComments(
			fs.readFileSync(path.join(root, 'static/ergopti_plus/windows/tests', file), 'utf8'),
			'.ahk'
		)
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
for (const [stepName, before, after] of [
	['Run native desktop AHK cohorts', './tools/test/run-windows-native-desktop.ps1', 'echo skipped'],
	['Run native desktop AHK cohorts', 'run: |', 'if: false\n        run: |'],
	['Run native desktop AHK cohorts', 'run: |', 'continue-on-error: true\n        run: |'],
	[
		'Publish native desktop AHK evidence',
		'name: Publish native desktop AHK evidence\n        if: always()',
		'name: Publish native desktop AHK evidence\n        if: success()'
	],
	[
		'Publish native desktop AHK evidence',
		'${{ runner.temp }}/windows-ahk-native-desktop/',
		'unrelated/'
	],
	['Publish native desktop AHK evidence', 'if-no-files-found: error', 'if-no-files-found: warn'],
	['Run native desktop AHK cohorts', 'timeout-minutes: 25', 'timeout-minutes: 30'],
	[
		'Run native desktop AHK cohorts',
		"$receipt = Join-Path $env:RUNNER_TEMP 'stable-windows-native-desktop.json'",
		"$receipt = Join-Path $env:RUNNER_TEMP 'unrelated.json'"
	],
	[
		'Run native desktop AHK cohorts',
		'--scope windows-native-desktop --receipt $receipt',
		'--scope windows-pac-full-url --receipt $receipt'
	],
	[
		'Run native desktop AHK cohorts',
		"if ($LASTEXITCODE -ne 0) { throw 'Native desktop qualification selection refused.' }",
		"if ($false) { throw 'Native desktop qualification selection refused.' }"
	],
	[
		'Run native desktop AHK cohorts',
		'$mode = node tools/ci/dev-release-qualification.cjs --scope windows-native-desktop --validate-scope-receipt $receipt',
		"$mode = 'deferred'"
	],
	[
		'Run native desktop AHK cohorts',
		'--scope windows-native-desktop --validate-scope-receipt $receipt',
		'--scope windows-pac-full-url --validate-scope-receipt $receipt'
	],
	[
		'Run native desktop AHK cohorts',
		'--validate-scope-receipt $receipt',
		'--validate-scope-receipt "$env:RUNNER_TEMP/stale.json"'
	],
	[
		'Run native desktop AHK cohorts',
		"if ($LASTEXITCODE -ne 0) { throw 'Native desktop qualification receipt refused.' }",
		"if ($false) { throw 'Native desktop qualification receipt refused.' }"
	],
	['Run native desktop AHK cohorts', "$mode -ceq 'deferred'", "$mode -ceq 'full'"],
	['Run native desktop AHK cohorts', 'qualified=false', 'qualified=true'],
	['Run native desktop AHK cohorts', "$mode -ceq 'full'", '$true'],
	[
		'Run native desktop AHK cohorts',
		"throw 'Invalid native desktop qualification disposition.'",
		"Write-Host 'Invalid native desktop qualification disposition.'"
	],
	[
		'Run native desktop AHK cohorts',
		'    ./tools/test/run-windows-native-desktop.ps1',
		'    # ./tools/test/run-windows-native-desktop.ps1'
	],
	[
		'Publish native desktop AHK evidence',
		'${{ runner.temp }}/stable-windows-native-desktop.json',
		'${{ runner.temp }}/stale.json'
	],
	['Retain the source-bound Windows qualification receipt', 'if: always()', 'if: success()'],
	[
		'Retain the source-bound Windows qualification receipt',
		'${{ runner.temp }}/stable-windows-native-desktop.json',
		'${{ runner.temp }}/stale.json'
	]
]) {
	// Bind every mutation to its own step; earlier diagnostics share upload fields.
	const target = pipeline.step(body, stepName);
	assert.equal(
		target.split(before).length,
		2,
		'the mutation must have one exact step-local target'
	);
	const changedTarget = target.replace(before, after);
	assert.notEqual(changedTarget, target, 'the mutation must alter the native desktop step');
	const changed = body.replace(target, changedTarget);
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
