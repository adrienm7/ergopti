# tools/test/run-windows-native-desktop.ps1
# Qualify the interpreted desktop cohorts with their canonical native receipts.
$ErrorActionPreference = 'Stop'

function Assert-DesktopNativeManifest {
    param(
        [Parameter(Mandatory = $true)] $Manifest,
        [Parameter(Mandatory = $true)] [string[]] $ExpectedNames,
        [Parameter(Mandatory = $true)] [AllowNull()] $NativeExit,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Transcript,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Stdout,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Stderr
    )
    if ($null -eq $NativeExit -or $NativeExit -isnot [int] -or $NativeExit -ne 0) {
        throw 'Native desktop runner must acknowledge exact process exit 0.'
    }
    if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
        throw 'Native desktop runner emitted stderr diagnostics.'
    }
    # The unchanged runner mirrors its file receipt to optional stdout. Any
    # additional stdout warning/load diagnostic must remain a refusal.
    $normalize = { param([string] $Text) ($Text -replace '^\uFEFF', '' -replace "`r`n", "`n").TrimEnd([char[]] "`r`n") }
    if ($Stdout.Length -gt 0 -and (& $normalize $Stdout) -cne (& $normalize $Transcript)) {
        throw 'Native desktop runner stdout differs from its canonical receipt.'
    }
    $count = $ExpectedNames.Count
    if ($Manifest.complete -isnot [bool] -or -not $Manifest.complete -or $Manifest.planned -ne $count -or
        $Manifest.executed_count -ne $count -or $Manifest.timed_count -ne $count -or
        $Manifest.passed -ne $count -or $Manifest.failed -ne 0 -or
        @($Manifest.errors).Count -ne 0 -or @($Manifest.executed).Count -ne $count) {
        throw 'Native desktop runner must complete every exact expected case without failures.'
    }
    if (@($ExpectedNames | Select-Object -Unique).Count -ne $count) {
        throw 'The authored desktop case census must be unique.'
    }
    for ($index = 0; $index -lt $count; $index += 1) {
        $entry = $Manifest.executed[$index]
        if ($entry.index -ne ($index + 1) -or $entry.status -cne 'ok' -or
            $entry.name -cne $ExpectedNames[$index] -or
            $entry.name -cnotmatch 'native-console-capture|todo91-altgr-suffix') {
            throw 'Native desktop runner case names, order and completions must match the authored census.'
        }
    }
}

$root = $env:GITHUB_WORKSPACE
if (-not $root) { throw 'GITHUB_WORKSPACE must identify the reviewed checkout.' }
$ahk = Get-ChildItem 'C:\AutoHotkey' -Filter 'AutoHotkey64.exe' |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $ahk) { throw 'AutoHotkey64.exe not found.' }
$runner = Join-Path $root 'static\ergopti_plus\windows\tests\run_all.ahk'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'Canonical test runner not found.' }
$evidence = Join-Path $env:RUNNER_TEMP 'windows-ahk-native-desktop'
# A reused evidence path cannot supply this invocation's receipts.
if (Test-Path -LiteralPath $evidence) { throw 'Native desktop evidence directory already exists.' }
$null = New-Item -ItemType Directory -Path $evidence
$summaryPath = Join-Path $evidence 'qualification.json'
$summary = [ordered]@{ schema_version = 1; status = 'pending'; expected_cases = 11; executed_cases = 0; runs = @(); error = $null }
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
$previousReceipt = $env:ERGOPTI_AHK_RESULTS_FILE
$cohorts = @(
    @{
        filter = 'native-console-capture'
        names = @(
            'Console capture: real hidden Edit reads remain stale (native-console-capture)',
            'Console capture: public refresh exposes the real runtime (native-console-capture)',
            'Console capture: final-state restoration retains native disruption (native-console-capture)',
            'Console capture: KeyHistory capacity is not fresh capture (native-console-capture)',
            'Console capture: three native causal controls break independent proofs (native-console-capture)'
        )
    },
    @{
        filter = 'todo91-altgr-suffix'
        names = @(
            'key combinations: standard AltGr suffix chooses its actual pair hold owner (todo91-altgr-suffix)',
            'key combinations: native AltGr prefix does not supply an admitted first key (todo91-altgr-suffix)',
            'key combinations: suppressed AltGr pair returns the fake Ctrl owner before action (todo91-altgr-suffix)',
            'key combinations: native AltGr pair retains and closes its Ctrl release debt (todo91-altgr-suffix)',
            'key combinations: custom AltGr variants are registered before the standalone owner (todo91-altgr-suffix)',
            'key combinations: interpreted native hook selects the earlier custom AltGr owner with bypass control (todo91-altgr-suffix)'
        )
    }
)
try {
    # The canonical --only flag is a substring filter. Separate serialized
    # invocations preserve that behavior; a pipe expression would select zero.
    foreach ($cohort in $cohorts) {
        $tap = Join-Path $evidence ($cohort.filter + '.txt')
        $stdoutPath = Join-Path $evidence ($cohort.filter + '.stdout.txt')
        $stderrPath = Join-Path $evidence ($cohort.filter + '.stderr.txt')
        $manifestPath = Join-Path $evidence ($cohort.filter + '.manifest.json')
        $env:ERGOPTI_AHK_RESULTS_FILE = $tap
        $proc = $null
        $record = [ordered]@{ filter = $cohort.filter; expected_cases = $cohort.names.Count; pid = $null; started_utc = $null; native_exit = $null; status = 'pending' }
        $summary.runs += $record
        $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
        try {
            # Copy the canonical asynchronous native-handle/exit receipt policy.
            # All test-owned children retain their unchanged native Job owners.
            $arguments = "/ErrorStdOut `"$runner`" --interactive --only $($cohort.filter)"
            $proc = Start-Process -FilePath $ahk -ArgumentList $arguments -NoNewWindow -PassThru `
                -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
            $null = $proc.Handle
            $record.pid = $proc.Id
            $record.started_utc = $proc.StartTime.ToUniversalTime().ToString('o')
            while (-not $proc.HasExited) { Start-Sleep -Milliseconds 100 }
            $proc.WaitForExit()
            $record.native_exit = $proc.ExitCode
            $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
            $stdout = Get-Content -LiteralPath $stdoutPath -Raw -Encoding utf8
            $stderr = Get-Content -LiteralPath $stderrPath -Raw -Encoding utf8
            if ($stdout) { Write-Host $stdout }
            if ($stderr) { Write-Host $stderr }
            if (-not (Test-Path -LiteralPath $tap -PathType Leaf)) { throw 'Canonical native desktop TAP receipt is unavailable.' }
            $transcript = Get-Content -LiteralPath $tap -Raw -Encoding utf8
            Write-Host $transcript
            & node (Join-Path $root 'tools\test\validate-ahk-suite-manifest.cjs') --input $tap --json $manifestPath
            if ($LASTEXITCODE -ne 0) { throw 'Canonical native desktop execution manifest is incomplete.' }
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
            Assert-DesktopNativeManifest -Manifest $manifest -ExpectedNames $cohort.names `
                -NativeExit $record.native_exit -Transcript ([string] $transcript) `
                -Stdout ([string] $stdout) -Stderr ([string] $stderr)
            $record.status = 'passed'
            $summary.executed_cases += $manifest.executed_count
        } finally {
            # Process exit precedes validation. Keep the existing canonical
            # process policy and the original test-internal retirement checks.
            if ($null -ne $proc) { $proc.Dispose() }
            $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
        }
    }
    if ($summary.executed_cases -ne 11 -or @($summary.runs).Count -ne 2 -or
        @($summary.runs | Where-Object { $_.status -cne 'passed' }).Count -ne 0) {
        throw 'Both native desktop cohorts must complete all eleven cases.'
    }
    $summary.status = 'passed'
} catch {
    $summary.status = 'failed'
    $summary.error = $_.Exception.Message
    throw
} finally {
    $env:ERGOPTI_AHK_RESULTS_FILE = $previousReceipt
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
}
