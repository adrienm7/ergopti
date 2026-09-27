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

const worker = path.resolve(__dirname, '../../static/ergopti_plus/windows/vendor/ergopti_uninstall.ps1');
assert.ok(fs.existsSync(worker), 'the compiled application must ship its removal worker');
if (process.platform !== 'win32') {
	console.log('[SKIP] Windows portable uninstall execution requires PowerShell on Windows.');
	process.exit(0);
}
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-uninstall-test-'));
const ps = (value) => `'${value.replaceAll("'", "''")}'`;
try {
	const script = path.join(scratch, 'test.ps1');
	fs.writeFileSync(script, `$ErrorActionPreference = 'Stop'
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
Remove-ErgoptiStartupShortcut $target $shortcutPath
if (Test-Path -LiteralPath $shortcutPath) { throw 'Owned startup shortcut survived removal' }
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
`);
	const result = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', script], {
		encoding: 'utf8', timeout: 30000, windowsHide: true,
	});
	assert.equal(result.status, 0, result.stderr || result.error?.message || result.stdout);
	assert.match(result.stdout, /\[OK\]/);
	process.stdout.write(result.stdout);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
