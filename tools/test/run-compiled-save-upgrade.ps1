# Boot the authenticated prior release, then the exact downloaded current package.
# All launches reuse the native suspended-process/Job owner; no source interpreter
# or extracted fixture script replaces the application's compiled auto-execute path.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Executable,
    [Parameter(Mandatory)][string] $Checkout,
    [Parameter(Mandatory)][string] $StartupEvidence,
    [Parameter(Mandatory)][string] $EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false)
$null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
$failureFile = Join-Path $EvidenceDirectory 'failure.json'
$state = [ordered]@{ schema_version = 1; complete = $false; failure = 'admission'; cleanup_acknowledged = $true }
$sandbox = Join-Path $env:RUNNER_TEMP ('ergopti-save-upgrade-' + [guid]::NewGuid().ToString('N'))
$savedEnvironment = @{}
$launches = @()
function Save-FailureEvidence {
    [IO.File]::WriteAllText($failureFile, ($state | ConvertTo-Json -Depth 6) + "`n", $utf8)
}
function Invoke-OwnedBoot([string] $Binary, [string] $Tag) {
    $process = $null
    $closed = $false
    try {
        $process = [CompiledHotstringsProcess]::LaunchBoot($Binary, $Checkout,
            (Join-Path $sandbox "$Tag.stdout.txt"), (Join-Path $sandbox "$Tag.stderr.txt"))
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (!$process.Exited(250)) {
            if ($process.HasDialog()) { throw 'The compiled application raised a native runtime dialog.' }
            if ($clock.Elapsed.TotalSeconds -ge 120) { throw 'The compiled application exceeded the existing startup hang bound.' }
        }
        $exit = $process.ExitCode()
        if ($exit -ne 0) { throw 'The compiled application did not exit successfully.' }
        if (!$process.WaitForIdle(5000)) { throw 'The compiled application left owned descendants alive.' }
        if ([IO.File]::ReadAllText((Join-Path $sandbox "$Tag.stderr.txt")).Trim().Length) {
            throw 'The compiled application emitted a native startup diagnostic.'
        }
        $closed = $true
        return [ordered]@{ pid = [int]$process.Pid; executable = $process.Image;
            created_utc = $process.CreatedUtc; exit_code = [int]$exit; tree_closed = $true }
    } finally {
        if ($null -ne $process) {
            try {
                if (!$closed) { $closed = $process.CancelAndAcknowledge() }
            } catch { $closed = $false }
            finally {
                try { $process.Dispose() } catch { $closed = $false }
            }
        } else { $closed = [CompiledHotstringsProcess]::LastLaunchCleanupAcknowledged }
        if (!$closed) {
            $state.cleanup_acknowledged = $false
            throw 'The compiled application process-tree owner did not acknowledge cleanup.'
        }
    }
}
function Read-StartupLogs {
    $logs = @(Get-ChildItem -LiteralPath $profileRoot -Recurse -File -Filter '*.log')
    if ($logs.Count -eq 0) { throw 'The installed application produced no startup logs.' }
    $errors = @($logs | Select-String -Pattern '\[(ERROR|FATAL)\]|the error window for')
    if ($errors.Count) { throw 'The installed application logged a startup error.' }
    return $logs
}
Save-FailureEvidence
try {
    if (!$IsWindows) { throw 'Compiled installed upgrade acceptance requires Windows.' }
    . (Join-Path $PSScriptRoot 'lib/windows-compiled-process.ps1')
    $Executable = [IO.Path]::GetFullPath($Executable)
    $Checkout = [IO.Path]::GetFullPath($Checkout)
    if ($env:GITHUB_SHA -cnotmatch '^[0-9a-f]{40}$') { throw 'Missing exact CI commit.' }
    $head = & git -C $Checkout rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -cne $env:GITHUB_SHA) { throw 'The upgrade checkout is from another commit.' }
    $contract = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/windows-upgrade-prior.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $currentDigest = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($currentDigest -ceq $contract.sha256) { throw 'The current package cannot stand in for the old release.' }
    $null = New-Item -ItemType Directory -Path $sandbox
    $priorDir = Join-Path $sandbox 'prior'
    $profileRoot = Join-Path $sandbox 'profile'
    $configDir = Join-Path $profileRoot 'config/autohotkey'
    $localAppData = Join-Path $sandbox 'local-app-data'
    $null = New-Item -ItemType Directory -Path $priorDir, $configDir, $localAppData
    $priorExe = Join-Path $priorDir 'ErgoptiPlus.exe'
    $state.failure = 'prior_download'
    Save-FailureEvidence
    Invoke-WebRequest -Uri $contract.url -OutFile $priorExe -UseBasicParsing
    $priorDigest = (Get-FileHash -LiteralPath $priorExe -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($priorDigest -cne $contract.sha256 -or (Get-Item -LiteralPath $priorExe).Length -ne $contract.bytes) {
        throw 'The published prior release failed its pinned checksum or size.'
    }
    $configFile = Join-Path $configDir 'config.toml'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/windows-upgrade-profile.toml') -Destination $configFile
    foreach ($name in @('LOCALAPPDATA', 'ERGOPTI_STARTUP_SMOKE_DIR', 'ERGOPTI_STARTUP_SMOKE_NONCE',
        'ERGOPTI_STARTUP_SMOKE_FULL_SAVE', 'ERGOPTI_STARTUP_SMOKE_ACK', 'ERGOPTI_STARTUP_SMOKE_EXPECT_SUSPENDED')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    $env:LOCALAPPDATA = $localAppData
    $env:ERGOPTI_STARTUP_SMOKE_DIR = $profileRoot
    $env:ERGOPTI_STARTUP_SMOKE_NONCE = $null
    $env:ERGOPTI_STARTUP_SMOKE_FULL_SAVE = $null
    $env:ERGOPTI_STARTUP_SMOKE_ACK = $null
    $env:ERGOPTI_STARTUP_SMOKE_EXPECT_SUSPENDED = $null
    $state.failure = 'prior_native_install'
    Save-FailureEvidence
    $priorNative = Invoke-OwnedBoot $priorExe 'prior'
    $priorLogs = @(Read-StartupLogs)
    if (@($priorLogs | Select-String -SimpleMatch 'Driver fully initialised').Count -eq 0) {
        throw 'The actual prior release did not complete its native boot.'
    }
    $bundleRoot = Join-Path $localAppData 'Ergopti/bundle'
    $marker = Join-Path $bundleRoot '.bundle-version'
    $priorMarker = [IO.File]::ReadAllText($marker).Trim([char[]]" `t`r`n")
    if ($priorMarker -cne $contract.version) { throw 'The genuine prior runtime was not installed.' }
    $assets = @()
    foreach ($asset in $contract.extracted_assets) {
        $file = Join-Path $bundleRoot $asset.path
        $digest = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($digest -cne $asset.sha256 -or (Get-Item -LiteralPath $file).Length -ne $asset.bytes) {
            throw 'An extracted prior asset differs from the pinned published payload.'
        }
        $assets += [ordered]@{ path = $asset.path; bytes = [int]$asset.bytes; sha256 = $digest }
    }
    # Observe the genuine old output first. Its historical serializer may strip
    # comments; an explicit offline user edit introduces the upgrade input only
    # after its real process tree, logs, bundle marker and assets were admitted.
    $state.failure = 'installed_user_edit'
    Save-FailureEvidence
    if (!$priorNative.tree_closed -or !$state.cleanup_acknowledged -or
        (Test-Path -LiteralPath (Join-Path $profileRoot 'paths.toml.config-transition.wal'))) {
        throw 'The old installed profile still has native ownership or WAL debt.'
    }
    $nativeProfileFile = Join-Path $EvidenceDirectory 'prior.native-profile.json'
    $editReceiptFile = Join-Path $EvidenceDirectory 'installed-user-edit.json'
    & node (Join-Path $PSScriptRoot 'compiled-upgrade-contract.cjs') prepare-installed-user-profile $configFile `
        (Join-Path $bundleRoot 'static/ergopti_plus/_shared/core/config_schema/migrations.toml') $nativeProfileFile $editReceiptFile
    if ($LASTEXITCODE -ne 0) { throw 'The explicit offline installed-user edit was refused.' }
    $priorProfileFile = Join-Path $sandbox 'prior.saved-profile.json'
    & node (Join-Path $PSScriptRoot 'compiled-upgrade-contract.cjs') inspect-profile $configFile `
        (Join-Path $bundleRoot 'static/ergopti_plus/_shared/core/config_schema/migrations.toml') $priorProfileFile
    if ($LASTEXITCODE -ne 0) { throw 'The edited installed upgrade input did not retain all five source records.' }
    $priorInstall = [ordered]@{ package_sha256 = $priorDigest; asset_id = [long]$contract.asset_id;
        version = $contract.version; commit = $contract.commit; bundle_identity = $priorMarker;
        pid = $priorNative.pid; executable = $priorNative.executable; created_utc = $priorNative.created_utc;
        exit_code = $priorNative.exit_code; tree_closed = $priorNative.tree_closed; extracted_assets = $assets;
        native_profile_before_edit = (Get-Content -LiteralPath $nativeProfileFile -Raw -Encoding utf8 | ConvertFrom-Json);
        installed_user_edit = (Get-Content -LiteralPath $editReceiptFile -Raw -Encoding utf8 | ConvertFrom-Json);
        saved_profile = (Get-Content -LiteralPath $priorProfileFile -Raw -Encoding utf8 | ConvertFrom-Json) }
    $env:ERGOPTI_STARTUP_SMOKE_FULL_SAVE = '1'
    foreach ($tag in @('upgrade', 'installed-warm')) {
        $state.failure = $tag
        Save-FailureEvidence
        foreach ($receiptName in @('ready.json', 'full-save.json')) {
            $oldReceipt = Join-Path $profileRoot $receiptName
            if (Test-Path -LiteralPath $oldReceipt) { Remove-Item -LiteralPath $oldReceipt }
        }
        $env:ERGOPTI_STARTUP_SMOKE_NONCE = [guid]::NewGuid().ToString('N')
        $launchDigest = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($launchDigest -cne $currentDigest) { throw 'The downloaded package changed between native launches.' }
        $native = Invoke-OwnedBoot $Executable $tag
        $logs = @(Read-StartupLogs)
        $ready = Get-Content -LiteralPath (Join-Path $profileRoot 'ready.json') -Raw -Encoding utf8 | ConvertFrom-Json
        $fullSave = Get-Content -LiteralPath (Join-Path $profileRoot 'full-save.json') -Raw -Encoding utf8 | ConvertFrom-Json
        $currentMarker = [IO.File]::ReadAllText($marker).Trim([char[]]" `t`r`n")
        if ($currentMarker -cne $ready.bundle_identity -or $currentMarker -ceq $priorMarker) {
            throw 'The current packaged application did not replace the old runtime.'
        }
        $walAbsent = !(Test-Path -LiteralPath (Join-Path $profileRoot 'paths.toml.config-transition.wal'))
        $bundleDebt = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($bundleRoot)) -Force |
            Where-Object Name -Match '^bundle\.(workspace|staging|rollback)-')
        if (!$walAbsent -or $bundleDebt.Count) { throw 'The compiled installed save retained WAL or bundle cleanup debt.' }
        $savedProfileFile = Join-Path $sandbox "$tag.saved-profile.json"
        & node (Join-Path $PSScriptRoot 'compiled-upgrade-contract.cjs') inspect-profile $configFile `
            (Join-Path $Checkout 'static/ergopti_plus/_shared/core/config_schema/migrations.toml') $savedProfileFile
        if ($LASTEXITCODE -ne 0) { throw 'The real compiled save did not preserve the installed unknown profile.' }
        $launches += [ordered]@{ native_startup = [ordered]@{ nonce = $env:ERGOPTI_STARTUP_SMOKE_NONCE;
            pid = $native.pid; executable = $native.executable; launched_sha256 = $launchDigest;
            exit_code = $native.exit_code; log_files = $logs.Count; logged_errors = @(); receipt = $ready };
            created_utc = $native.created_utc; full_save = $fullSave; tree_closed = $native.tree_closed;
            wal_absent = $walAbsent; bundle_workspace_absent = ($bundleDebt.Count -eq 0);
            saved_profile = (Get-Content -LiteralPath $savedProfileFile -Raw -Encoding utf8 | ConvertFrom-Json) }
    }
    $observation = Join-Path $sandbox 'upgrade-observation.json'
    if (!$state.cleanup_acknowledged) { throw 'The compiled upgrade still has unacknowledged process-tree cleanup.' }
    [IO.File]::WriteAllText($observation, (@{ schema_version = 1; prior_install = $priorInstall;
        launches = $launches } | ConvertTo-Json -Depth 12) + "`n", $utf8)
    & node (Join-Path $PSScriptRoot 'desktop-ci-evidence.cjs') record-windows-upgrade $observation $Executable $StartupEvidence
    if ($LASTEXITCODE -ne 0) { throw 'Compiled installed upgrade evidence was refused.' }
    $state.complete = $true
    $state.failure = $null
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    if ($state.cleanup_acknowledged -and (Test-Path -LiteralPath $sandbox)) {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force } catch { $state.cleanup_acknowledged = $false }
    }
    if (!$state.cleanup_acknowledged) { $state.complete = $false; $state.failure = 'cleanup_debt' }
    Save-FailureEvidence
}
if (!$state.complete) { throw 'Compiled installed upgrade acceptance is incomplete.' }
Write-Host 'Compiled prior-release upgrade and installed warm full-save acceptance passed.'
