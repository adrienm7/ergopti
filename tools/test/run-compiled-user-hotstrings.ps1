# Qualify the packaged interpreter and its extracted worker dependencies together.
# The startup step supplies its admitted private bundle; this probe never substitutes
# the downloaded source interpreter or re-extracts a different package.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Executable,
    [Parameter(Mandatory)][string] $Checkout,
    [Parameter(Mandatory)][AllowEmptyString()][string] $BundleRoot,
    [Parameter(Mandatory)][AllowEmptyString()][string] $LocalAppData,
    [Parameter(Mandatory)][string] $StartupEvidence,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [ValidateRange(1, 240)][int] $TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
$evidenceFile = Join-Path $EvidenceDirectory 'evidence.json'
$tapFile = Join-Path $EvidenceDirectory 'results.tap'
$manifestFile = Join-Path $EvidenceDirectory 'manifest.json'
$receipt = [ordered]@{
    schema_version = 1
    scenario = 'compiled-programmable-hotstrings'
    sha = $env:GITHUB_SHA
    package_sha256 = $null
    dependency_sha256 = @{}
    native = $null
    timed_out = $false
    cleanup_acknowledged = $false
    complete = $false
    failure = 'not_started'
}
function Write-Evidence {
    [IO.File]::WriteAllText($evidenceFile, ($receipt | ConvertTo-Json -Depth 8) + "`n", $utf8)
}
function Get-AdmittedWorkerDependencies {
    param([string] $SourceRoot, [string] $RuntimeRoot, [string] $Identity, [string] $Sha)
    if ($Sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid package commit.' }
    # FileAppend(..., "UTF-8") writes a BOM; ReadAllText removes it like the
    # native UTF-8 reader. Match _Bundle_ReadMarker's explicit ASCII trimming.
    $marker = [IO.File]::ReadAllText((Join-Path $RuntimeRoot '.bundle-version')).Trim([char[]]" `t`r`n")
    if ($marker -cne $Identity -or $marker -cnotmatch ("^(?!__BUNDLE_VERSION__)[^\r\n]+\n" + $Sha + '$')) {
        throw 'The extracted runtime bundle differs from native startup.'
    }
    $digests = @{}
    # Bundle destinations are deliberately independent of repository paths.
    foreach ($pair in @(
        @{ bundle = 'static/ergopti_plus/_shared/modules/hotstrings/user_code.ahk';
           source = 'static/ergopti_plus/_shared/modules/hotstrings/user_code.ahk' },
        @{ bundle = 'vendor/ergopti_user_hotstrings.ahk';
           source = 'static/ergopti_plus/windows/vendor/ergopti_user_hotstrings.ahk' }
    )) {
        $runtimeDigest = (Get-FileHash -LiteralPath (Join-Path $RuntimeRoot $pair.bundle) -Algorithm SHA256).Hash.ToLowerInvariant()
        $sourceDigest = (Get-FileHash -LiteralPath (Join-Path $SourceRoot $pair.source) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($runtimeDigest -cne $sourceDigest) { throw 'A packaged worker dependency differs from this checkout.' }
        $digests[$pair.bundle] = $runtimeDigest
    }
    return $digests
}
Write-Evidence
[IO.File]::WriteAllText($tapFile, '', $utf8)

# A suspended process joins this owned Job before any script or child can run.
# All waiting and termination uses retained native handles, never a recycled PID.
. (Join-Path $PSScriptRoot 'lib/windows-compiled-process.ps1')

$probe = $null
$sandbox = Join-Path $env:RUNNER_TEMP ('ergopti-programmable-' + [guid]::NewGuid().ToString('N'))
$savedEnvironment = @{}
$failure = 'admission'
try {
    if (!$IsWindows) { throw 'The compiled package probe requires Windows.' }
    $Executable = [IO.Path]::GetFullPath($Executable)
    $Checkout = [IO.Path]::GetFullPath($Checkout)
    $BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
    $LocalAppData = [IO.Path]::GetFullPath($LocalAppData)
    if ($env:GITHUB_SHA -cnotmatch '^[0-9a-f]{40}$') { throw 'Missing exact CI commit.' }
    $checkoutSha = & git -C $Checkout rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $checkoutSha -cne $env:GITHUB_SHA) { throw 'The probe checkout is from another commit.' }
    $failure = 'package_admission_contract'
    & (Join-Path $Checkout 'tools/test/fixtures/test_compiled_user_hotstrings_package.ps1') -Probe $PSCommandPath -Checkout $Checkout
    $failure = 'admission'
    $startup = Get-Content -LiteralPath $StartupEvidence -Raw -Encoding utf8 | ConvertFrom-Json
    $digest = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt.package_sha256 = $digest
    if ($startup.sha -cne $env:GITHUB_SHA -or $startup.package_sha256 -cne $digest -or
        $startup.native_startup.exit_code -ne 0 -or @($startup.failures).Count -ne 0 -or
        $startup.native_startup.receipt.compiled -ne $true -or
        $startup.native_startup.receipt.build_commit -cne $env:GITHUB_SHA -or
        ![StringComparer]::OrdinalIgnoreCase.Equals($startup.native_startup.executable, $Executable)) {
        throw 'The packaged interpreter lacks same-commit admitted startup evidence.'
    }
    $expectedBundle = Join-Path $LocalAppData 'Ergopti/bundle'
    if (![StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($expectedBundle), $BundleRoot)) {
        throw 'The requested dependencies are not the admitted private runtime bundle.'
    }
    $receipt.dependency_sha256 = Get-AdmittedWorkerDependencies -SourceRoot $Checkout -RuntimeRoot $BundleRoot `
        -Identity $startup.native_startup.receipt.bundle_identity -Sha $env:GITHUB_SHA
    $privateTemp = Join-Path $sandbox 'temp'
    $null = New-Item -ItemType Directory -Path $privateTemp
    foreach ($name in @('TEMP', 'TMP', 'LOCALAPPDATA', 'ERGOPTI_USER_HOTSTRINGS_PACKAGE_ROOT',
        'ERGOPTI_AHK_RESULTS_FILE', 'ERGOPTI_STARTUP_SMOKE_DIR', 'ERGOPTI_STARTUP_SMOKE_NONCE')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $env:TEMP = $privateTemp
    $env:TMP = $privateTemp
    $env:LOCALAPPDATA = $LocalAppData
    $env:ERGOPTI_USER_HOTSTRINGS_PACKAGE_ROOT = $BundleRoot
    $env:ERGOPTI_AHK_RESULTS_FILE = [IO.Path]::GetFullPath($tapFile)
    $env:ERGOPTI_STARTUP_SMOKE_DIR = $null
    $env:ERGOPTI_STARTUP_SMOKE_NONCE = $null
    $runner = Join-Path $Checkout 'static/ergopti_plus/windows/tests/run_all.ahk'
    $failure = 'native_launch'
    $probe = [CompiledHotstringsProcess]::new($Executable, $runner, $Checkout,
        (Join-Path $sandbox 'stdout.txt'), (Join-Path $sandbox 'stderr.txt'))
    $receipt.native = [ordered]@{ pid = $probe.Pid; executable = $probe.Image; created_utc = $probe.CreatedUtc; exit_code = $null }
    $failure = 'native_execution'
    if (!$probe.Exited([uint32]($TimeoutSeconds * 1000))) {
        $receipt.timed_out = $true
        throw 'The compiled programmable suite exceeded its independent hang bound.'
    }
    $receipt.native.exit_code = $probe.ExitCode()
    if (!$probe.WaitForIdle(5000)) { throw 'The native suite left owned descendants alive.' }
    $receipt.cleanup_acknowledged = $true
    $failure = 'execution_manifest'
    & node (Join-Path $Checkout 'tools/test/validate-ahk-suite-manifest.cjs') --input $tapFile --json $manifestFile
    if ($LASTEXITCODE -ne 0) { throw 'The packaged runtime did not produce a complete exact TAP manifest.' }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding utf8 | ConvertFrom-Json
    if (!$manifest.complete -or $manifest.planned -le 0 -or $manifest.executed_count -ne $manifest.planned -or
        $manifest.failed -ne 0 -or $receipt.native.exit_code -ne 0) { throw 'The compiled suite did not pass every selected case.' }
    # Independent required behaviors: a zero-test or preview-only probe cannot pass.
    foreach ($required in @(
        'programmable hotstrings: metadata preview and admission never execute callbacks',
        'programmable hotstrings: source, destination and input receipts fence callbacks and output',
        'programmable hotstrings: typed results, cancellation debt and permanent shutdown',
        'programmable hotstrings: isolated result framing preserves exact UTF-8 and Boolean types',
        'programmable hotstrings: real Windows worker loads metadata and executes Unicode callback',
        'programmable hotstrings: real callbacks own actions and preserve true false zero and multiline text',
        'programmable hotstrings: real worker cancels descendants and withholds private source errors',
        'programmable hotstrings: canonical preview keeps builtin and declined-builtin priority',
        'programmable hotstrings: real live disable cancels a loading factory and its descendants',
        'programmable hotstrings: actual deferred terminal owner fences source control enable and late publication',
        'programmable hotstrings: actual native menu projects shared order and owns explicit create only',
        'programmable hotstrings: actual boot live persistence and cancellation refusal preserve source and preferences',
        'programmable hotstrings: real native ordinary password pause control and source receipts fence publication'
    )) {
        if (@($manifest.executed | Where-Object { $_.name -ceq $required -and $_.status -ceq 'ok' }).Count -ne 1) {
            throw 'The compiled manifest omitted a required native worker behavior.'
        }
    }
    $receipt.complete = $true
    $receipt.failure = $null
} catch {
    $receipt.failure = $failure
    # Errors may contain private factory/script text. Publish only the closed stage.
    Write-Host "Compiled programmable qualification failed at stage: $failure"
} finally {
    if ($null -ne $probe) {
        try {
            if (!$receipt.cleanup_acknowledged) { $receipt.cleanup_acknowledged = $probe.CancelAndAcknowledge() }
        } catch {
            $receipt.cleanup_acknowledged = $false
        } finally { $probe.Dispose() }
    } else {
        # A constructor failure must retain its measured exact-process cleanup ACK.
        $receipt.cleanup_acknowledged = [CompiledHotstringsProcess]::LastLaunchCleanupAcknowledged
    }
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    if ($receipt.cleanup_acknowledged -and (Test-Path -LiteralPath $sandbox)) {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force } catch { $receipt.cleanup_acknowledged = $false }
    }
    if (!$receipt.cleanup_acknowledged) { $receipt.complete = $false; $receipt.failure = 'cleanup_debt' }
    if (!(Test-Path -LiteralPath $manifestFile)) {
        try {
            & node (Join-Path $Checkout 'tools/test/validate-ahk-suite-manifest.cjs') --input $tapFile --json $manifestFile *> $null
        } catch { } # The negative native receipt must survive a missing validator.
    }
    Write-Evidence
}
if (!$receipt.complete) { throw 'Compiled programmable package qualification failed; inspect the mandatory evidence.' }
Write-Host "Compiled programmable package qualification passed: $($manifest.passed)/$($manifest.planned) tests, native exit 0 and owned process tree closed."
