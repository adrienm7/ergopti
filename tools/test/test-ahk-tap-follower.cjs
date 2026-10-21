// tools/test/test-ahk-tap-follower.cjs
'use strict';

/** Requires live display routing while retaining the native TAP/exit authorities. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');
const root = path.resolve(__dirname, '../..');
const names = ['Run AHK test suite', 'Run E2E suite (Strategy A — pure engine injection)'];

function checkWorkflow(text) {
	const jobs = pipeline.jobsOfText(text, '.github/workflows/ci-windows.yml');
	for (const [index, name] of names.entries()) {
		const found = jobs
			.flatMap((job) => pipeline.steps(job.body))
			.filter((step) => step.name === name);
		assert.equal(found.length, 1);
		const body = found[0].body;
		const lines = pipeline.runOf(body);
		const script = lines.join('\n');
		assert.equal(pipeline.stepField(body, 'shell'), 'pwsh');
		assert.equal(pipeline.stepField(body, 'timeout-minutes'), index === 0 ? '125' : '5');
		assert.equal(pipeline.stepField(body, 'continue-on-error'), null);
		assert.equal(pipeline.stepField(body, 'if'), null);
		assert.equal(script.split('New-AhkTapFollower -Path $resultsFile').length, 2);
		assert.match(script, /\. "\$\{\{ github\.workspace \}\}\\tools\\ci\\ahk-tap-follower\.ps1"/);
		assert.match(script, /\$null = \$proc\.Handle/);
		const loop = pipeline.scriptBlock(lines, 'while (-not $proc.HasExited) {').join('\n');
		assert.match(loop, /if \(\$null -eq \$tapFailure\)/);
		assert.match(loop, /try \{ \$tapFollower\.Poll\(\) \| ForEach-Object \{ Write-Host \$_ \} \}/);
		assert.match(loop, /catch \{ \$tapFailure = \$_\.Exception\.GetType\(\)\.Name \}/);
		assert.match(loop, /Start-Sleep -Milliseconds 100/);
		assert.equal(script.split('$tapFollower.Finish()').length, 2);
		assert.match(
			script,
			/try \{ \$tapFollower\.Finish\(\) \| ForEach-Object \{ Write-Host \$_ \} \}\n    catch \{ \$tapFailure = \$_\.Exception\.GetType\(\)\.Name \}/
		);
		assert(script.indexOf('$proc.WaitForExit()') >= 0, 'the native child must retire');
		assert(script.indexOf('$proc.WaitForExit()') < script.indexOf('$tapFollower.Finish()'));
		assert.match(script, /\$exit = \$proc\.ExitCode/);
		assert.match(script, /Get-Content -LiteralPath \$stderrFile -Encoding utf8/);
		assert(pipeline.blockExits(pipeline.scriptBlock(lines, 'if ($null -eq $exit) {'), '2'));
		assert(
			pipeline.blockExits(pipeline.scriptBlock(lines, 'if (-not (Test-Path $resultsFile)) {'), '2')
		);
		assert(pipeline.blockExits(pipeline.scriptBlock(lines, 'if ($exit -ne 0) {'), '$exit'));
		assert(pipeline.blockExits(pipeline.scriptBlock(lines, 'if ($null -ne $tapFailure) {'), '2'));
		assert(script.indexOf('if ($exit -ne 0)') < script.indexOf('if ($null -ne $tapFailure)'));
		assert.doesNotMatch(script, /Get-Content[^\n]*\$resultsFile|Stop-Process|\.Kill\(/);
		if (index === 0) {
			assert.match(script, /\$env:ERGOPTI_AHK_RESULTS_FILE = \$resultsFile/);
			assert.match(
				script,
				/validate-ahk-suite-manifest\.cjs" `\n    --input \$resultsFile --json \$manifestFile/
			);
			assert(
				pipeline.blockExits(
					pipeline.scriptBlock(lines, 'if ($manifestExit -ne 0) {'),
					'$manifestExit'
				)
			);
			assert.match(script, /--scope windows-pac-full-url/);
			assert.match(script, /--ahk-tap \$resultsFile --execution-manifest \$manifestFile/);
			assert.match(script, /--qualification-profile=\$qualificationProfile/);
		}
	}
	const validators = jobs
		.flatMap((job) => pipeline.steps(job.body))
		.filter((step) => step.name === 'Validate complete native E2E corpus execution');
	assert.equal(validators.length, 1);
	assert.match(
		pipeline.runOf(validators[0].body).join('\n'),
		/validate-ahk-e2e-manifest\.cjs --input/
	);
}

function check(text) {
	checkWorkflow(text);
	let refused = 0;
	for (const name of names) {
		const job = pipeline
			.jobsOfText(text, 'windows')
			.find((job) => pipeline.steps(job.body).some((step) => step.name === name));
		const body = pipeline.step(job.body, name);
		for (const [before, after] of [
			['$tapFollower.Poll()', '$null'],
			['$tapFollower.Finish()', '$tapFollower.Poll()'],
			['$proc.WaitForExit()', '$null = $proc'],
			['$exit = $proc.ExitCode', '$exit = 0'],
			['if ($null -ne $tapFailure)', 'if ($false)'],
			['if ($exit -ne 0)', 'if ($false)'],
			['New-AhkTapFollower -Path $resultsFile', 'New-AhkTapFollower -Path $stdoutFile'],
			['catch { $tapFailure = $_.Exception.GetType().Name }', 'catch { $null = $_ }']
		]) {
			assert(body.includes(before));
			assert.throws(() => checkWorkflow(text.replace(body, body.replace(before, after))));
			refused++;
		}
	}
	return refused;
}

module.exports = { checkWorkflow, check };
if (require.main === module) {
	const refused = check(
		// The Windows lane, read inlined with its stage files.
		pipeline.file('.github/workflows/ci-windows.yml')
	);
	const pwsh = process.platform === 'win32' ? 'pwsh.exe' : 'pwsh';
	// The version probe only proves pwsh starts. A cold start on a loaded hosted runner can
	// exceed any short deadline (run 39538166684: ETIMEDOUT at 10 s), so a timeout alone is
	// retried, at most twice, with each retry logged. A missing executable (ENOENT) or a failing
	// probe is never retried.
	let discovered;
	for (let attempt = 1; attempt <= 3; attempt++) {
		discovered = spawnSync(
			pwsh,
			['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()'],
			{ encoding: 'utf8', timeout: 60000 }
		);
		if (!discovered.error || discovered.error.code !== 'ETIMEDOUT') break;
		console.warn(`${pwsh} version probe timed out (attempt ${attempt}/3); retrying.`);
	}
	assert.equal(discovered.error, undefined, `Required PowerShell executable unavailable: ${pwsh}`);
	assert.equal(discovered.status, 0, discovered.stdout + discovered.stderr);
	const result = spawnSync(
		pwsh,
		[
			'-NoProfile',
			'-NonInteractive',
			'-File',
			path.join(__dirname, 'fixtures/ahk-tap-follower-controls.ps1'),
			'-Helper',
			path.join(root, 'tools/ci/ahk-tap-follower.ps1')
		],
		{ encoding: 'utf8', timeout: 30000 }
	);
	assert.equal(result.error, undefined);
	assert.equal(result.status, 0, result.stdout + result.stderr);
	assert.match(result.stdout, /PASS: 9 actual file\/UTF-8 controls/);
	console.log(
		`AHK TAP follower PASS: ${refused} workflow refusals and actual file/decoder controls; no AHK cohort was executed.`
	);
}
