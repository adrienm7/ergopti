# Qualification-only preparation; the feature branch keeps the standard CI workflow.
param([Parameter(Mandatory=$true)][ValidatePattern("^[0-9a-f]{40}$")][string]$SourceCandidate)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. ./tools/build/build_windows_nav_owner.ps1 -UpdateTracked

$group7Preimage = Join-Path $repoRoot "tools\test\group7_nav_owner_preimage.c"
$group7Exe = Join-Path $buildDir "group7_nav_owner_preimage.exe"
$group7Arguments = $commonCompilerFlags + @(
    "/DERGOPTI_NAV_TESTING=1", $testSourcePath, $group7Preimage,
    "/Fe:$group7Exe", "/link"
) + $commonLinkerFlags
Push-Location $buildDir
try {
    Invoke-CheckedNative -Label "Compiling the production preimage with observer-only test instrumentation" -Executable "cl.exe" -Arguments $group7Arguments
} finally { Pop-Location }

$group7ReceiptDir = Join-Path $repoRoot "tools\test\group7-native-generation-results"
New-Item -ItemType Directory -Force -Path $group7ReceiptDir | Out-Null
$group7PreimageHash = (Get-FileHash -LiteralPath $group7Preimage -Algorithm SHA256).Hash.ToLowerInvariant()
if ($group7PreimageHash -cne "d6542e0a9c18e4286ccf1c0e63b7e2386672d4c0149708343730d39f1200cb40") {
    throw "The production preimage does not match its independently reviewed identity."
}
$group7Identity = "CHECKOUT: $(git rev-parse HEAD)`nSOURCE_CANDIDATE: $SourceCandidate`nPRODUCTION_PREIMAGE_COMMIT: 45d5c2db602ee74711da965ba17207c69b6dcba5`nPREIMAGE_SHA256: $group7PreimageHash`n"
foreach ($group7Path in @(
    "static/ergopti_plus/windows/native/nav_event_owner/nav_event_owner.c",
    "static/ergopti_plus/windows/native/nav_event_owner/nav_event_owner.h",
    "static/ergopti_plus/windows/native/nav_event_owner/nav_event_owner_test.c",
    "tools/build/build_windows_nav_owner.ps1",
    "tools/test/group7_native_generation.ps1",
    "static/ergopti_plus/windows/vendor/ergopti_nav_owner.manifest.json"
)) {
    $group7Hash = (Get-FileHash -LiteralPath (Join-Path $repoRoot $group7Path) -Algorithm SHA256).Hash.ToLowerInvariant()
    $group7Identity += "$group7Path SHA256: $group7Hash`n"
}
[System.IO.File]::WriteAllText((Join-Path $group7ReceiptDir "source-identities.log"), $group7Identity, [System.Text.UTF8Encoding]::new($false))
Write-Host $group7Identity
foreach ($group7Case in @("terminal release has one owner", "terminal release preserves concurrent overflow")) {
    $group7Start = [System.Diagnostics.ProcessStartInfo]::new()
    $group7Start.FileName = $group7Exe
    $group7Start.ArgumentList.Add($group7Case)
    $group7Start.UseShellExecute = $false
    $group7Start.RedirectStandardOutput = $true
    $group7Start.RedirectStandardError = $true
    $group7Process = [System.Diagnostics.Process]::new()
    $group7Process.StartInfo = $group7Start
    if (-not $group7Process.Start()) { throw "Production-preimage process admission failed." }
    try {
        if (-not $group7Process.WaitForExit(15000)) {
            $group7Process.Kill($true)
            $group7Process.WaitForExit()
            throw "Production-preimage probe exceeded its owned deadline."
        }
        $group7Out = $group7Process.StandardOutput.ReadToEnd()
        $group7Err = $group7Process.StandardError.ReadToEnd()
        $group7Code = $group7Process.ExitCode
    } finally { $group7Process.Dispose() }
    $group7Out = $group7Out.Replace("`r`n", "`n").Replace("`r", "`n")
    $group7Err = $group7Err.Replace("`r`n", "`n").Replace("`r", "`n")
    $group7Receipt = "CASE: $group7Case`nEXIT: $group7Code`nSTDOUT:`n$group7Out`nSTDERR:`n$group7Err"
    [System.IO.File]::WriteAllText((Join-Path $group7ReceiptDir ($group7Case.Replace(" ", "_") + ".log")), $group7Receipt, [System.Text.UTF8Encoding]::new($false))
    Write-Host $group7Receipt
    $group7Expected = if ($group7Case -eq "terminal release has one owner") {
        "ErgoptiNav_TestReleaseTerminalCapture(observation->token,observation->release_kind,UINT32_MAX,nested_events,8,&nested_count)==ERGOPTI_NAV_STATUS_BUSY"
    } else { "snapshot.phase==ERGOPTI_NAV_TERMINAL_FAULTED" }
    $group7Failures = @($group7Err.Split("`n") | Where-Object { $_.StartsWith("FAIL ") })
    $group7FirstCause = if ($group7Failures.Count -gt 0) {
        [regex]::Replace(($group7Failures[0] -replace '^FAIL [^:]+:[0-9]+: ', ''), '\s', '')
    } else { "" }
    $group7OtherFailures = @($group7Failures | Where-Object { -not $_.StartsWith("FAIL ${group7Case}:") })
    if ($group7Code -ne 1 -or $group7FirstCause -cne $group7Expected -or $group7OtherFailures.Count -ne 0 -or
        -not $group7Err.Contains("Native navigation-owner tests stopped after 0/1 passes.")) {
        throw "The exact independent regression did not fail against the production preimage."
    }
}
