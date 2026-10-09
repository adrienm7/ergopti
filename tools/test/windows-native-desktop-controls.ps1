# tools/test/windows-native-desktop-controls.ps1
# Portable checks of the actual authored manifest guard, not native evidence.
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'run-windows-native-desktop.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref] $tokens, [ref] $parseErrors)
if (@($parseErrors).Count -ne 0) { throw 'Native desktop qualification PowerShell does not parse.' }
$functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-DesktopNativeManifest' }, $true))
if ($functions.Count -ne 1) { throw 'Expected one actual desktop manifest guard.' }
$actualGuard = $functions[0].Extent.Text
Invoke-Expression $actualGuard
$names = @('first portable case (native-console-capture)', 'second portable case (native-console-capture)')
# This is a handwritten portable model. It is never a Windows result artifact.
function New-PortableManifest {
    return [pscustomobject]@{
        complete = $true; planned = 2; executed_count = 2; timed_count = 2; passed = 2; failed = 0
        errors = @(); executed = @(
            [pscustomobject]@{ index = 1; name = 'first portable case (native-console-capture)'; status = 'ok' },
            [pscustomobject]@{ index = 2; name = 'second portable case (native-console-capture)'; status = 'ok' }
        )
    }
}
$positive = @{ Manifest = (New-PortableManifest); ExpectedNames = $names; NativeExit = [int] 0; Transcript = "portable receipt`n"; Stdout = "portable receipt`r`n"; Stderr = '' }
Assert-DesktopNativeManifest @positive
$cases = @(
    @{ name = 'missing native exit'; mutate = { param($Control) $Control.NativeExit = $null }; reason = 'exact process exit' },
    @{ name = 'string native exit'; mutate = { param($Control) $Control.NativeExit = '0' }; reason = 'exact process exit' },
    @{ name = 'boolean native exit'; mutate = { param($Control) $Control.NativeExit = $false }; reason = 'exact process exit' },
    @{ name = 'failed native exit'; mutate = { param($Control) $Control.NativeExit = [int] 1 }; reason = 'exact process exit' },
    @{ name = 'stderr diagnostic'; mutate = { param($Control) $Control.Stderr = 'load error' }; reason = 'stderr diagnostics' },
    @{ name = 'stdout warning'; mutate = { param($Control) $Control.Stdout += 'Warning: test' }; reason = 'stdout differs' },
    @{ name = 'missing plan'; mutate = { param($Control) $Control.Manifest.planned = 0 }; reason = 'every exact expected case' },
    @{ name = 'missing completion'; mutate = { param($Control) $Control.Manifest.executed_count = 1 }; reason = 'every exact expected case' },
    @{ name = 'missing timing'; mutate = { param($Control) $Control.Manifest.timed_count = 1 }; reason = 'every exact expected case' },
    @{ name = 'failed case'; mutate = { param($Control) $Control.Manifest.passed = 1; $Control.Manifest.failed = 1 }; reason = 'every exact expected case' },
    @{ name = 'incomplete manifest'; mutate = { param($Control) $Control.Manifest.complete = $false }; reason = 'every exact expected case' },
    @{ name = 'string completion'; mutate = { param($Control) $Control.Manifest.complete = 'true' }; reason = 'every exact expected case' },
    @{ name = 'manifest error'; mutate = { param($Control) $Control.Manifest.errors = @('duplicate') }; reason = 'every exact expected case' },
    @{ name = 'duplicate authored name'; mutate = { param($Control) $Control.ExpectedNames = @($names[0], $names[0]) }; reason = 'census must be unique' },
    @{ name = 'foreign case name'; mutate = { param($Control) $Control.Manifest.executed[1].name = 'foreign' }; reason = 'match the authored census' },
    @{ name = 'duplicate ordinal'; mutate = { param($Control) $Control.Manifest.executed[1].index = 1 }; reason = 'match the authored census' },
    @{ name = 'failed terminal'; mutate = { param($Control) $Control.Manifest.executed[1].status = 'not ok' }; reason = 'match the authored census' }
)
foreach ($case in $cases) {
    $arguments = $positive.Clone()
    $arguments.Manifest = New-PortableManifest
    & $case.mutate $arguments
    $refused = $false
    try { Assert-DesktopNativeManifest @arguments }
    catch {
        if ($_.Exception.Message -notmatch $case.reason) { throw }
        $refused = $true
    }
    if (-not $refused) { throw ('Portable refusal control escaped: ' + $case.name) }
}
# A genuine mutation of the actual native-exit guard must break the independent
# handwritten refusal expectation; restore the authored function afterward.
$old = 'if ($null -eq $NativeExit -or $NativeExit -isnot [int] -or $NativeExit -ne 0)'
if ($actualGuard.Split($old).Count -ne 2) { throw 'Native-exit causal site must be unique.' }
try {
    Invoke-Expression ($actualGuard.Replace($old, 'if ($false)'))
    $negative = $positive.Clone()
    $negative.Manifest = New-PortableManifest
    $negative.NativeExit = '0'
    Assert-DesktopNativeManifest @negative
} finally {
    Invoke-Expression $actualGuard
}
$restored = $false
try { Assert-DesktopNativeManifest @negative } catch { $restored = $_.Exception.Message -match 'exact process exit' }
if (-not $restored) { throw 'Actual guard restoration must restore the refusal.' }
Write-Output ('Portable actual-guard controls PASS: one handwritten positive, ' + $cases.Count + ' refusals, causal native-exit mutation exposed and restored. No native API executed.')
