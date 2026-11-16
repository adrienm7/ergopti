// tools/test/test-windows-keyboard-layout-builder.cjs

/**
 * ==============================================================================
 * MODULE: Windows Keyboard Layout Builder MSVC Runner
 * DESCRIPTION:
 * Runs Invoke-InMsvc, the step of tools/build/build_windows_keyboard_layout.ps1
 * that calls vcvarsall.bat and the MSVC tools, under Windows PowerShell 5.1
 * with a fake vcvarsall.bat, so no compiler is needed.
 *
 * ROOT CAUSE ENCODED (keyboard-layout-builder-stderr):
 * The runner captured cmd's stderr in PowerShell (2>&1). Windows PowerShell 5.1
 * turns each captured stderr line into an error record, and the builder's
 * $ErrorActionPreference = "Stop" throws on the first one: on the maintainer's
 * PC (2026-11-16, MSVC 14.29) vcvarsall.bat printed one warning line on stderr
 * and a build whose every step succeeded stopped there. CI runs the builder
 * under pwsh 7, which does not do this, so only a 5.1 run catches it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const builder = path.resolve(__dirname, '../build/build_windows_keyboard_layout.ps1');
assert.match(
	fs.readFileSync(builder, 'utf8'),
	/^function Invoke-InMsvc \{$/m,
	'the builder must keep its MSVC runner as one function'
);
if (process.platform !== 'win32') {
	console.log('[SKIP] the MSVC runner of the keyboard layout builder needs Windows PowerShell.');
	process.exit(0);
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-kbd-builder-'));
try {
	// vcvarsall.bat's stdout is the environment banner the builder drops; its
	// stderr line stands for the warning that stopped the PC build.
	const vcvars = path.join(scratch, 'vcvarsall.bat');
	fs.writeFileSync(
		vcvars,
		'@echo off\r\necho vcvars banner\r\necho vcvars warning 1>&2\r\nif "%1"=="refuse" exit /b 5\r\nexit /b 0\r\n'
	);
	const harness = path.join(scratch, 'harness.ps1');
	fs.writeFileSync(
		harness,
		[
			'param([string]$Builder, [string]$VcVars, [string]$Work)',
			'$ErrorActionPreference = "Stop"',
			'$tokens = $null; $errors = $null',
			'$ast = [System.Management.Automation.Language.Parser]::ParseFile($Builder, [ref]$tokens, [ref]$errors)',
			'$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-InMsvc" }, $true)',
			'. ([scriptblock]::Create($function.Extent.Text))',
			'$result = [ordered]@{}',
			'try {',
			'	$output = Invoke-InMsvc -VcVars $VcVars -Target "x64" -WorkDirectory $Work -Commands @("echo compiled", "cmd /d /c `"echo tool warning 1>&2`"")',
			'	$result.success = "ok:" + ($output -join "|")',
			'} catch { $result.success = "threw:" + $_.Exception.Message }',
			'try {',
			'	Invoke-InMsvc -VcVars $VcVars -Target "x64" -WorkDirectory $Work -Commands @("cmd /d /c `"echo tool failure 1>&2 & exit /b 3`"") | Out-Null',
			'	$result.tool = "ok"',
			'} catch { $result.tool = "threw:" + $_.Exception.Message }',
			'try {',
			'	Invoke-InMsvc -VcVars $VcVars -Target "refuse" -WorkDirectory $Work -Commands @("echo never") | Out-Null',
			'	$result.vcvars = "ok"',
			'} catch { $result.vcvars = "threw:" + $_.Exception.Message }',
			'$result | ConvertTo-Json -Compress'
		].join('\r\n')
	);
	const run = spawnSync(
		'powershell.exe',
		[
			'-NoProfile',
			'-NonInteractive',
			'-ExecutionPolicy',
			'Bypass',
			'-File',
			harness,
			builder,
			vcvars,
			scratch
		],
		{ encoding: 'utf8', timeout: 60000 }
	);
	assert.equal(run.error, undefined, String(run.error));
	assert.equal(run.status, 0, `${run.stdout}\n${run.stderr}`);
	const result = JSON.parse(run.stdout.trim().split(/\r?\n/).pop());

	// keyboard-layout-builder-stderr: stderr lines of a step that succeeds are
	// kept as output, never thrown, and the banner stays dropped.
	assert.match(result.success, /^ok:/, result.success);
	assert.match(result.success, /vcvars warning/);
	assert.match(result.success, /compiled/);
	assert.match(result.success, /tool warning/);
	assert.doesNotMatch(result.success, /vcvars banner/);

	// A failing tool or vcvarsall still stops the build, naming its exit and
	// carrying its stderr.
	assert.match(result.tool, /^threw:MSVC x64 build failed \(exit 91\)/, result.tool);
	assert.match(result.tool, /tool failure/);
	assert.match(result.vcvars, /^threw:MSVC refuse build failed \(exit 90\)/, result.vcvars);
	assert.match(result.vcvars, /vcvars warning/);
	assert.doesNotMatch(result.vcvars, /never/);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(
	'[OK] The keyboard layout builder keeps MSVC stderr as output under Windows PowerShell 5.1 and still fails on a failing step.'
);
