// tools/test/test-windows-uninstall.cjs

/**
 * ==============================================================================
 * MODULE: Portable Windows Uninstall Transaction Tests
 * DESCRIPTION:
 * Executes the production removal function against temporary files. Authorization,
 * process exit and recycling are injected, so no installed program is removed.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const worker = path.resolve(
	__dirname,
	'../../static/ergopti_plus/windows/vendor/ergopti_uninstall.ps1'
);
assert.ok(fs.existsSync(worker), 'the compiled application must ship its removal worker');
if (process.platform !== 'win32') {
	console.log('[SKIP] Windows portable uninstall execution requires PowerShell on Windows.');
	process.exit(0);
}
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-uninstall-test-'));
const ps = (value) => `'${value.replaceAll("'", "''")}'`;
try {
	const script = path.join(scratch, 'test.ps1');
	fs.writeFileSync(
		script,
		`$ErrorActionPreference = 'Stop'
. ${ps(worker)} -LibraryOnly
$target = ${ps(path.join(scratch, 'application.exe'))}
[IO.File]::WriteAllText($target, 'original')
$hash = Get-ErgoptiExecutableHash $target
$shortcutPath = Join-Path (Split-Path $target) 'startup-fixture.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.Arguments = '--foreign'
$shortcut.Save()
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
Remove-ErgoptiStartupShortcut $target $shortcutPath
if (-not (Test-Path -LiteralPath $shortcutPath)) { throw 'Foreign startup shortcut removed' }
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.Arguments = ''
$shortcut.Save()
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
Remove-ErgoptiStartupShortcut ((Split-Path $target) + '\\.\\application.exe') $shortcutPath
if (Test-Path -LiteralPath $shortcutPath) { throw 'Shell-normalized startup shortcut survived removal' }
# The ordinary login owner accepts exact commands under arbitrary filenames.
# Execute the actual worker callback, redirecting only its native folder lookup.
$script:StartupCensusFolder = Join-Path (Split-Path $target) 'startup-census'
[void][IO.Directory]::CreateDirectory($script:StartupCensusFolder)
$manualPaths = @('My keyboard.lnk', 'ErgoptiPlus.exe.lnk') | ForEach-Object { Join-Path $script:StartupCensusFolder $_ }
$canonicalPath = Join-Path $script:StartupCensusFolder 'ErgoptiPlus.lnk'
$foreignPath = Join-Path $script:StartupCensusFolder 'Foreign arguments.lnk'
$unrelatedPath = Join-Path $script:StartupCensusFolder 'retained.txt'
[IO.File]::WriteAllText($unrelatedPath, 'unrelated startup content')
$shell = New-Object -ComObject WScript.Shell
try {
 foreach ($linkPath in @($manualPaths) + @($canonicalPath, $foreignPath)) {
  $link = $shell.CreateShortcut($linkPath)
  try {
   $link.TargetPath = $target
   $link.Arguments = $(if ($linkPath -eq $foreignPath) { '--foreign' } else { '' })
   $link.Save()
  } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
 }
} finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
$tokens = $null
$parseErrors = $null
$workerAst = [Management.Automation.Language.Parser]::ParseFile(${ps(worker)}, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The actual removal worker did not parse' }
$assignments = @($workerAst.FindAll({
 param($node)
 $node -is [Management.Automation.Language.AssignmentStatementAst] -and
  $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
  $node.Left.VariablePath.UserPath -eq 'unregister'
}, $true))
if ($assignments.Count -ne 1) { throw 'The actual unregister assignment is not unique' }
$blocks = @($assignments[0].Right.FindAll({
 param($node)
 $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
}, $true))
if ($blocks.Count -ne 1) { throw 'The actual unregister callback is not unique' }
$body = $blocks[0].ScriptBlock.Extent.Text
$nativeLookup = "([Environment]::GetFolderPath('Startup'))"
if (($body.Split(@($nativeLookup), [StringSplitOptions]::None)).Count -ne 2) {
 throw 'The native Startup-folder boundary is not unique'
}
$body = $body.Replace($nativeLookup, '$script:StartupCensusFolder')
if (-not $body.StartsWith('{') -or -not $body.EndsWith('}')) { throw 'Unexpected callback AST delimiters' }
$actualUnregister = [ScriptBlock]::Create($body.Substring(1, $body.Length - 2))
$script:censusRecycled = @()
$censusRecycle = { param($Path) $script:censusRecycled += $Path }
if (-not (Invoke-ErgoptiRemoval $target $hash { $true } { $true } $censusRecycle $actualUnregister)) {
 throw 'The actual removal transaction refused the confirmed census fixture'
}
if ($script:censusRecycled.Count -ne 1 -or $script:censusRecycled[0] -ne $target) {
 throw 'The startup cleanup exceeded the exact executable removal authority'
}
foreach ($ownedPath in @($manualPaths) + @($canonicalPath)) {
 if (Test-Path -LiteralPath $ownedPath) { throw 'An exact owned startup command survived executable removal' }
}
if (-not (Test-Path -LiteralPath $foreignPath) -or -not (Test-Path -LiteralPath $unrelatedPath)) {
 throw 'Startup cleanup removed foreign content'
}
$script:recycled = @()
$recycle = { param($Path) $script:recycled += $Path }
$failed = $false
[IO.File]::WriteAllText($target, 'replacement before worker startup')
try { Invoke-ErgoptiRemoval $target $hash { throw 'Changed image reached READY' } { $true } $recycle } catch {
 if ($_.Exception.Message -ne 'The executable changed after confirmation.') { throw }
 $failed = $true
}
if (-not $failed) { throw 'Changed image accepted before authorization' }
[IO.File]::WriteAllText($target, 'original')
if (Invoke-ErgoptiRemoval $target $hash { $false } { throw 'No wait after refusal' } $recycle) { throw 'Refusal accepted' }
if ($script:recycled.Count -ne 0) { throw 'Unconfirmed removal' }
$failed = $false
try { Invoke-ErgoptiRemoval $target $hash { $true } { $false } $recycle } catch { $failed = $true }
if (-not $failed -or $script:recycled.Count -ne 0) { throw 'Removal before parent exit' }
$failed = $false
try {
 Invoke-ErgoptiRemoval $target $hash { $true } { [IO.File]::WriteAllText($target, 'replacement'); $true } $recycle
} catch { $failed = $true }
if (-not $failed -or $script:recycled.Count -ne 0) { throw 'A replacement executable was removed' }
[IO.File]::WriteAllText($target, 'original')
if (-not (Invoke-ErgoptiRemoval $target $hash { $true } { $true } $recycle)) { throw 'Confirmed removal refused' }
if ($script:recycled.Count -ne 1 -or $script:recycled[0] -ne $target) { throw 'Removal authority exceeded its exact target' }
$checkout = Join-Path (Split-Path $target) '.git'
[IO.File]::WriteAllText($checkout, 'gitdir: another-worktree')
$failed = $false
try { Invoke-ErgoptiRemoval $target $hash { throw 'Checkout reached authorization' } { $true } $recycle } catch {
 if ($_.Exception.Message -ne 'Refusing an executable inside a source checkout.') { throw }
 $failed = $true
}
if (-not $failed -or $script:recycled.Count -ne 1) { throw 'Source checkout was not preserved' }
if ([IO.File]::ReadAllText($target) -ne 'original') { throw 'The test touched the recycle boundary' }
Write-Output '[OK] Windows uninstall requires confirmation, exact process exit and an unchanged owned executable.'
`
	);
	const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', script], {
		encoding: 'utf8',
		timeout: 30000,
		windowsHide: true
	});
	assert.equal(result.status, 0, result.stderr || result.error?.message || result.stdout);
	assert.match(result.stdout, /\[OK\]/);
	process.stdout.write(result.stdout);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
