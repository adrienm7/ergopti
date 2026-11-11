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
# A private stand-in for the Recycle Bin: the fake recycle renames the quarantined
# file into it under a shell-like $R name, and the real identity search reads it.
$fakeBin = Join-Path (Split-Path $target) 'fake-bin'
[void][IO.Directory]::CreateDirectory($fakeBin)
$binRecycle = { param($Path) [IO.File]::Move($Path, (Join-Path $fakeBin ('$R' + [guid]::NewGuid().ToString('N') + '.exe'))) }
$binLocate = { param($Item, $Identity) Find-ErgoptiRecycledIdentity $fakeBin $Identity }
$quarantineName = '^' + [regex]::Escape((Split-Path $target)) + '\\\\\\.ergopti-uninstall-[0-9a-f]{32}\\.exe$'
$script:censusRecycled = @()
$censusRecycle = { param($Path) $script:censusRecycled += $Path; & $binRecycle $Path }
if (-not (Invoke-ErgoptiRemoval $target $hash { $true } { $true } $censusRecycle $actualUnregister $binLocate)) {
 throw 'The actual removal transaction refused the confirmed census fixture'
}
if ($script:censusRecycled.Count -ne 1 -or $script:censusRecycled[0] -notmatch $quarantineName -or (Test-Path -LiteralPath $target)) {
 throw 'The startup cleanup exceeded the exact executable removal authority'
}
[IO.File]::WriteAllText($target, 'original')
foreach ($ownedPath in @($manualPaths) + @($canonicalPath)) {
 if (Test-Path -LiteralPath $ownedPath) { throw 'An exact owned startup command survived executable removal' }
}
if (-not (Test-Path -LiteralPath $foreignPath) -or -not (Test-Path -LiteralPath $unrelatedPath)) {
 throw 'Startup cleanup removed foreign content'
}
$missingStartup = Join-Path (Split-Path $target) 'missing-startup'
$script:absentStartupRecycled = 0
$absentStartupUnregister = { param($Path) Remove-ErgoptiStartupShortcuts $Path $missingStartup }
$countedRecycle = { param($Path) $script:absentStartupRecycled++; & $binRecycle $Path }
if (-not (Invoke-ErgoptiRemoval $target $hash { $true } { $true } $countedRecycle $absentStartupUnregister $binLocate)) {
 throw 'A missing Startup folder must not refuse executable removal'
}
if ($script:absentStartupRecycled -ne 1 -or (Test-Path -LiteralPath $missingStartup)) {
 throw 'Missing Startup cleanup must recycle only the executable without creating the folder'
}
[IO.File]::WriteAllText($target, 'original')
Remove-ErgoptiStartupShortcuts $target ''
$script:recycled = @()
$recycle = { param($Path) $script:recycled += $Path; & $binRecycle $Path }
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
# The 28 October audit's proof: the unregister step moves the image away and
# installs a foreign file, and the recycle then selects that replacement.
$moved = "$target.moved"
$swap = {
 param($Path)
 try { [IO.File]::Move($Path, $moved) } catch { return }
 [IO.File]::WriteAllText($Path, 'foreign replacement')
}
$scriptRecycledText = $null
$readRecycle = { param($Path) $script:scriptRecycledText = [IO.File]::ReadAllText($Path); & $binRecycle $Path }
if (-not (Invoke-ErgoptiRemoval $target $hash { $true } { $true } $readRecycle $swap $binLocate)) { throw 'Pinned removal refused' }
if ($script:scriptRecycledText -ne 'original' -or (Test-Path -LiteralPath $moved)) {
 throw 'The unregister step could swap the confirmed image before its recycle'
}
[IO.File]::WriteAllText($target, 'original')
if (-not (Invoke-ErgoptiRemoval $target $hash { $true } { $true } $recycle {} $binLocate)) { throw 'Confirmed removal refused' }
if ($script:recycled.Count -ne 1 -or $script:recycled[0] -notmatch $quarantineName) { throw 'Removal authority exceeded its exact target' }
# Finding 3 of the 28 October audit: Windows cannot recycle a pinned file, so
# the pin ends before the recycle, and a program racing that window swapped the
# image the recycle selected; the removal returned success with the foreign
# file in the Recycle Bin. The race lands inside the recycle step itself: the
# removal must refuse, and the confirmed image must be left intact.
[IO.File]::WriteAllText($target, 'original')
$stolen = "$target.stolen"
$racingRecycle = {
 param($Path)
 [IO.File]::Move($Path, $stolen)
 [IO.File]::WriteAllText($Path, 'foreign replacement')
 & $binRecycle $Path
}
$failed = $false
try { Invoke-ErgoptiRemoval $target $hash { $true } { $true } $racingRecycle {} $binLocate } catch {
 if ($_.Exception.Message -ne 'The recycled file is not the confirmed executable; check the Recycle Bin.') { throw }
 $failed = $true
}
if (-not $failed) { throw 'A replacement recycled in the unpinned window was reported as the removal' }
if ([IO.File]::ReadAllText($stolen) -ne 'original') { throw 'The racing program lost the confirmed image' }
Remove-Item -LiteralPath $stolen
# The same race just after the pin ends, before the quarantine rename: the
# foreign file keeps its name and nothing reaches the Recycle Bin.
[IO.File]::WriteAllText($target, 'original')
$binBefore = @(Get-ChildItem -LiteralPath $fakeBin -Force).Count
$racingRelease = {
 param($Path)
 [IO.File]::Move($Path, $stolen)
 [IO.File]::WriteAllText($Path, 'foreign replacement')
}
$failed = $false
try { Invoke-ErgoptiRemoval $target $hash { $true } { $true } $recycle {} $binLocate $racingRelease } catch {
 if ($_.Exception.Message -ne 'The executable was replaced before its quarantine; nothing was recycled.') { throw }
 $failed = $true
}
if (-not $failed) { throw 'A replacement renamed in the unpinned window reached the recycle' }
if (@(Get-ChildItem -LiteralPath $fakeBin -Force).Count -ne $binBefore -or $script:recycled.Count -ne 1) {
 throw 'A replacement renamed in the unpinned window was recycled'
}
if ([IO.File]::ReadAllText($target) -ne 'foreign replacement' -or [IO.File]::ReadAllText($stolen) -ne 'original') {
 throw 'The refused quarantine did not hand both files their names back'
}
Remove-Item -LiteralPath $stolen
[IO.File]::WriteAllText($target, 'original')
# The actual recycle callback and the default Recycle Bin search, on the real
# Recycle Bin: it receives only this test's own temporary file, which the test
# then removes from the Bin by the identity the removal proved.
$recycleAssignments = @($workerAst.FindAll({
 param($node)
 $node -is [Management.Automation.Language.AssignmentStatementAst] -and
  $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
  $node.Left.VariablePath.UserPath -eq 'recycle'
}, $true))
if ($recycleAssignments.Count -ne 1) { throw 'The actual recycle assignment is not unique' }
$recycleBody = $recycleAssignments[0].Right.Extent.Text
if (-not $recycleBody.StartsWith('{') -or -not $recycleBody.EndsWith('}')) { throw 'Unexpected recycle AST delimiters' }
$actualRecycle = [ScriptBlock]::Create($recycleBody.Substring(1, $recycleBody.Length - 2))
Add-Type -AssemblyName Microsoft.VisualBasic
$realTarget = Join-Path (Split-Path $target) 'real-recycle-fixture.exe'
[IO.File]::WriteAllText($realTarget, 'ergopti uninstall test fixture ' + [guid]::NewGuid().ToString('N'))
$realHash = Get-ErgoptiExecutableHash $realTarget
$realAnchor = Open-ErgoptiFileAnchor $realTarget
try {
 $realIdentity = Get-ErgoptiFileIdentity $realAnchor
 if (-not (Invoke-ErgoptiRemoval $realTarget $realHash { $true } { $true } $actualRecycle)) { throw 'The real recycle was refused' }
 $realBin = Get-ErgoptiRecycleBinFolder $realTarget
 $recycledEntry = Find-ErgoptiRecycledIdentity $realBin $realIdentity
} finally { $realAnchor.Dispose() }
if ($null -eq $recycledEntry -or (Test-Path -LiteralPath $realTarget)) { throw 'The confirmed fixture is not in the Recycle Bin' }
$recordEntry = Join-Path $realBin ('$I' + (Split-Path $recycledEntry -Leaf).Substring(2))
$record = [IO.File]::ReadAllBytes($recordEntry)
if (-not [Text.Encoding]::Unicode.GetString($record, 28, $record.Length - 28).StartsWith((Split-Path $realTarget -Parent) + '\\.ergopti-uninstall-')) {
 throw 'The Recycle Bin record does not name the quarantined fixture'
}
Remove-Item -LiteralPath $recycledEntry, $recordEntry -Force
$checkout = Join-Path (Split-Path $target) '.git'
[IO.File]::WriteAllText($checkout, 'gitdir: another-worktree')
$failed = $false
try { Invoke-ErgoptiRemoval $target $hash { throw 'Checkout reached authorization' } { $true } $recycle } catch {
 if ($_.Exception.Message -ne 'Refusing an executable inside a source checkout.') { throw }
 $failed = $true
}
if (-not $failed -or $script:recycled.Count -ne 1) { throw 'Source checkout was not preserved' }
if ([IO.File]::ReadAllText($target) -ne 'original') { throw 'The test touched the recycle boundary' }
Write-Output '[OK] Windows uninstall requires confirmation, exact process exit and an unchanged owned executable, and recycles that exact file (the real Recycle Bin received only this test''s own temporary fixture, removed afterwards).'
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
