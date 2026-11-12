# tools/test/run-windows-receiving-scenarios.ps1
# Runs the Windows receiving scenarios of the recovery and flow audits for real,
# inside one fresh temp profile, and keeps their receipts.
#
# The scenarios are the AHK tests named "phys-w-receiving" (see
# static/ergopti_plus/windows/tests/support/receiving_profile.ahk). They are
# registered as interactive, so no unit shard selects them; this runner starts
# run_all.ahk with LOCALAPPDATA, APPDATA, USERPROFILE, TEMP and TMP inside the
# profile, checks the exact census of cases in the execution manifest, writes
# receipt.json and deletes the profile. Windows PowerShell 5.1 or pwsh.
#
# Exit 0 = every scenario passed; any refusal throws with the raw evidence kept.
param(
    [string] $Ahk = '',
    [string] $Evidence = ''
)
$ErrorActionPreference = 'Stop'

# The exact cases, in registration order. A case added to the tests is added
# here too, so a scenario can never silently drop out of the receiving run.
$ExpectedNames = @(
    'selection capture receiving: a real foreground change during the snapshot refuses before the clipboard (phys-w-receiving-selection-focus)',
    'selection capture receiving: an unchanged foreground delivers the copy and restores the clipboard (phys-w-receiving-selection-focus)',
    'widget position receiving: the pair reaches the real Registry, and a refused write keeps the previous one (phys-w-receiving-widget-position)',
    'updater swap receiving: the running image swap when the new image acknowledges boot-ready (phys-w-receiving-updater-swap)',
    'updater swap receiving: the running image swap when the parent dies before FinalExit (phys-w-receiving-updater-swap)',
    'updater swap receiving: the running image swap when the new image exits before boot-ready (phys-w-receiving-updater-swap)',
    'api token crypto receiving: a token round-trips through the real DPAPI and an independent reader (phys-w-receiving-dpapi)',
    'api token crypto receiving: tampered, foreign and marker-shaped envelopes are refused by the real DPAPI (phys-w-receiving-dpapi)',
    'api token crypto receiving: the metrics cipher seals marker-shaped typing with the real machine key (phys-w-receiving-dpapi)',
    'system actions receiving: a real Clear-RecycleBin failure after launch reaches the error channel (phys-w-receiving-recycle-bin)',
    'system actions receiving: a real worker exiting 0 is reported as done (phys-w-receiving-recycle-bin)',
    'legacy folder migration receiving: a real old tree moves byte for byte and boot selects it (phys-w-receiving-migration-tree)',
    'legacy folder migration receiving: a rename refused by an ACL keeps paths.toml naming the data (phys-w-receiving-migration-acl)',
    'legacy folder migration receiving: a transition interrupted at target:new:1 beside the old paths.toml settles to the old image before the move (phys-w-receiving-migration-journal)',
    'legacy folder migration receiving: a transition interrupted at phase:committed_new beside the old paths.toml settles to the new image before the move (phys-w-receiving-migration-journal)'
)

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $root 'static\ergopti_plus\windows\tests\run_all.ahk'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Test runner not found at $runner." }
if (-not $Ahk) { $Ahk = $env:ERGOPTI_AHK_EXE }
if (-not $Ahk -and (Test-Path -LiteralPath 'C:\AutoHotkey')) {
    $Ahk = Get-ChildItem 'C:\AutoHotkey' -Filter 'AutoHotkey64.exe' | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Ahk) { $Ahk = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe' }
if (-not (Test-Path -LiteralPath $Ahk -PathType Leaf)) { throw "AutoHotkey64.exe not found: $Ahk." }
if (-not $Evidence) {
    $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $Evidence = Join-Path $base 'windows-receiving-scenarios'
}
# A reused evidence folder cannot hold this invocation's receipts.
if (Test-Path -LiteralPath $Evidence) { throw "Receiving evidence folder already exists: $Evidence." }
$null = New-Item -ItemType Directory -Path $Evidence

$profileRoot = Join-Path ([IO.Path]::GetTempPath()) ('ergopti-receiving-' + [Guid]::NewGuid().ToString('N'))
$isolated = [ordered]@{
    ERGOPTI_RECEIVING_PROFILE = $profileRoot
    LOCALAPPDATA = Join-Path $profileRoot 'Local'
    APPDATA = Join-Path $profileRoot 'Roaming'
    USERPROFILE = Join-Path $profileRoot 'Home'
    TEMP = Join-Path $profileRoot 'Temp'
    TMP = Join-Path $profileRoot 'Temp'
    ERGOPTI_AHK_RESULTS_FILE = Join-Path $Evidence 'receiving.tap.txt'
}
$null = New-Item -ItemType Directory -Path $profileRoot
foreach ($name in 'Local', 'Roaming', 'Home', 'Temp') { $null = New-Item -ItemType Directory -Path (Join-Path $profileRoot $name) }
Write-Host "Receiving profile: $profileRoot"
Write-Host "Evidence root: $Evidence"

$sourceSha = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { (& git -C $root rev-parse HEAD).Trim() }
$receipt = [ordered]@{ schema = 1; source_sha = $sourceSha; status = 'pending'; expected = $ExpectedNames.Count;
    passed = 0; failed = 0; not_executed = 0; native_exit = $null; error = $null }
$receiptPath = Join-Path $Evidence 'receipt.json'
$stdoutPath = Join-Path $Evidence 'receiving.stdout.txt'
$stderrPath = Join-Path $Evidence 'receiving.stderr.txt'
$manifestPath = Join-Path $Evidence 'receiving.manifest.json'
$saved = @{}
try {
    if ($ExpectedNames.Count -eq 0 -or @($ExpectedNames | Select-Object -Unique).Count -ne $ExpectedNames.Count) {
        throw 'The receiving census must name each case exactly once.'
    }
    # The child inherits this process's environment: set the profile for the
    # launch only, then put every variable back.
    foreach ($name in $isolated.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $isolated[$name], 'Process')
    }
    try {
        $arguments = "/ErrorStdOut `"$runner`" --interactive --only phys-w-receiving"
        $proc = Start-Process -FilePath $Ahk -ArgumentList $arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $null = $proc.Handle
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
    $proc.WaitForExit()
    $receipt.native_exit = $proc.ExitCode
    $proc.Dispose()
    $stderr = [IO.File]::ReadAllText($stderrPath)
    if ($stderr) { Write-Host $stderr }
    $tap = $isolated.ERGOPTI_AHK_RESULTS_FILE
    if (-not (Test-Path -LiteralPath $tap -PathType Leaf)) { throw 'The receiving TAP receipt is missing.' }
    Get-Content -LiteralPath $tap -Encoding utf8 | Where-Object { $_ -notmatch '^(RUNNING |# duration_ms )' } | Write-Host
    & node (Join-Path $root 'tools\test\validate-ahk-suite-manifest.cjs') --input $tap --json $manifestPath
    if ($LASTEXITCODE -ne 0) { throw 'The receiving execution manifest is incomplete.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $receipt.passed = $manifest.passed
    $receipt.failed = $manifest.failed
    $receipt.not_executed = $manifest.not_executed
    if ($receipt.native_exit -ne 0 -or $stderr.Trim().Length -ne 0) { throw "The receiving runner exited with $($receipt.native_exit)." }
    $count = $ExpectedNames.Count
    if (-not $manifest.complete -or $manifest.planned -ne $count -or $manifest.passed -ne $count -or
        $manifest.failed -ne 0 -or $manifest.not_executed -ne 0 -or @($manifest.executed).Count -ne $count) {
        throw "Every receiving scenario must pass: $($manifest.passed) of $count passed, $($manifest.failed) failed, $($manifest.not_executed) not executed."
    }
    for ($index = 0; $index -lt $count; $index += 1) {
        $entry = $manifest.executed[$index]
        if ($entry.status -cne 'ok' -or $entry.name -cne $ExpectedNames[$index]) {
            throw "Receiving case $($index + 1) differs from the census: '$($entry.name)'."
        }
    }
    $receipt.status = 'passed'
} catch {
    $receipt.status = 'failed'
    $receipt.error = $_.Exception.Message
    throw
} finally {
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding utf8
    # The cases remove their own deny ACEs; a profile that cannot be deleted is a
    # failure, never left for the next run to inherit.
    if (Test-Path -LiteralPath $profileRoot) { Remove-Item -LiteralPath $profileRoot -Recurse -Force }
}
Write-Host "RESULT passed=$($receipt.passed) failed=0 not_executed=0"
