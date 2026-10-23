# vendor/ergopti_updater_staging.ps1

# ==============================================================================
# MODULE: Ergopti Updater Staging Worker
# DESCRIPTION:
# Downloads one release executable, checks its size and trusted SHA-256 digest,
# then publishes the bundled swap worker next to it. The driver starts this
# file with -File and passes only the name of its private inherited
# environment: release data (URL, digest, paths) stays data and never becomes
# PowerShell source. Environment values, unlike arguments, are not expanded by
# the cmd.exe wrapper that owns the process tree.
#
# Success prints READY and exits 0. Failure prints one JSON receipt and exits 1;
# an input refused before the transaction starts throws and exits 1.
# ==============================================================================

param([string]$TransportPrefix, [scriptblock]$ReadConfig=$null, [scriptblock]$ReadEnvironment=$null)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
if ($TransportPrefix -cnotmatch "\AERGOPTI_UPDATER_[0-9]+_[0-9]+_[0-9]+\z") { throw "Staging transport prefix was refused" }
function Read-ErgoptiStagingInput([string]$Name, [bool]$Required) {
	$Value = [Environment]::GetEnvironmentVariable($TransportPrefix + "_" + $Name)
	if ($Required -and [string]::IsNullOrEmpty($Value)) { throw ("Staging input " + $Name + " was refused") }
	if ($null -eq $Value) { return "" }
	return $Value
}
$Url = Read-ErgoptiStagingInput "URL" $true
$ExpectedSha256 = Read-ErgoptiStagingInput "DIGEST" $false
$NewExe = Read-ErgoptiStagingInput "NEW_EXE" $true
$SwapScriptPath = Read-ErgoptiStagingInput "SWAP_PATH" $true
$SwapSourcePath = Read-ErgoptiStagingInput "SWAP_SOURCE" $true
$CurrentExe = Read-ErgoptiStagingInput "CURRENT" $true
[int64]$MinimumSize = Read-ErgoptiStagingInput "MINIMUM" $true
[int]$TimeoutMs = Read-ErgoptiStagingInput "TIMEOUT" $true
$DownloadModulePath = Read-ErgoptiStagingInput "DOWNLOAD_MODULE" $true
[int]$DeadlineMs = Read-ErgoptiStagingInput "DEADLINE" $false
[int64]$StartedTick = Read-ErgoptiStagingInput "STARTED_TICK" $false
$ProxyPolicyPath = Read-ErgoptiStagingInput "PROXY_POLICY" $false
$UpdaterDefaultsPath = Read-ErgoptiStagingInput "UPDATER_DEFAULTS" $false
[int64]$AuthenticatedSize = Read-ErgoptiStagingInput "AUTHENTICATED_SIZE" $false
$OwnedCaptureDirectory = Read-ErgoptiStagingInput "CURL_CAPTURE" $false
$State=@{Stage="proxy_resolve";Reason="download";Receipt=@{};CleanupDebt=@()};if ($OwnedCaptureDirectory -ne "") {$State.OwnedCaptureDirectory=$OwnedCaptureDirectory}
function CleanWorker($Path,$Name){try{[IO.File]::Delete($Path)}catch{if(Get-Command Add-ErgoptiUpdaterCleanupDebt -ErrorAction SilentlyContinue){Add-ErgoptiUpdaterCleanupDebt $State $Name "file_remove" $_.Exception}else{$State.CleanupDebt+=@{resource=$Name;receipt=@{backend="dotnet";stage="file_remove";failure_provenance="unknown"}}}}}
try {
  . $DownloadModulePath
  . (Join-Path (Split-Path -Parent $DownloadModulePath) "ergopti_network_routes.ps1")
  $Resolver={param($Destination,$Budget) Resolve-ErgoptiNativeNetworkRoutes $Destination $Budget $ReadConfig $ReadEnvironment $ProxyPolicyPath $UpdaterDefaultsPath}
  $Request=[System.Net.HttpWebRequest]::Create($Url)
  $Request.ReadWriteTimeout = $TimeoutMs
  if ($AuthenticatedSize -gt 0) {$ExpectedSize=Invoke-ErgoptiUpdaterArtifactDownload ([Uri]$Url) $NewExe $TimeoutMs $State $Resolver $DeadlineMs $StartedTick $AuthenticatedSize $ProxyPolicyPath $UpdaterDefaultsPath $ReadEnvironment} else {$ExpectedSize=Invoke-ErgoptiUpdaterDownload $Request $NewExe $TimeoutMs $State $Resolver $DeadlineMs $StartedTick}
  $State.Stage="file_read"
  $ActualSize=(Get-Item -LiteralPath $NewExe).Length
  if ($ExpectedSize -gt 0 -and $ActualSize -ne $ExpectedSize) { throw "Content-Length mismatch" }
  if ($ActualSize -lt $MinimumSize) { $State.Reason="verify";throw "Downloaded file is too small" }
  if ($ExpectedSha256 -cnotmatch "^[0-9a-f]{64}$") { $State.Reason="verify";throw "Missing or invalid trusted SHA-256 digest" }
  $ActualDigest=& { $HashStream=$null; $Hasher=[Security.Cryptography.SHA256]::Create(); try { $HashStream=[IO.File]::Open($NewExe,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); [BitConverter]::ToString($Hasher.ComputeHash($HashStream)).Replace("-","").ToLowerInvariant() } finally { try { if ($null -ne $HashStream) { $HashStream.Dispose() } } finally { $Hasher.Dispose() } } }
  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
  if ($ActualDigest -cne $ExpectedSha256) { $State.Reason="verify";throw "SHA-256 digest mismatch" }
  $SwapSource=[IO.File]::ReadAllText($SwapSourcePath,[Text.UTF8Encoding]::new($false))
  if ($AuthenticatedSize -le 0) {$State.Stage="file_remove";[IO.File]::Delete($SwapScriptPath)}
  $State.Stage="file_write"
  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
  if ($AuthenticatedSize -le 0) {[IO.File]::WriteAllText($SwapScriptPath,$SwapSource,[Text.UTF8Encoding]::new($false))} else {$SwapOutput=$null;try{$State.Stage="file_create";$SwapOutput=[IO.File]::Open($SwapScriptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$State.SwapWorkerOwned=$true;$State.Stage="file_write";$SwapBytes=[Text.Encoding]::UTF8.GetBytes($SwapSource);$SwapOutput.Write($SwapBytes,0,$SwapBytes.Length);$SwapOutput.Flush($true)}finally{Close-ErgoptiUpdaterResource $SwapOutput "swap_worker" "file_write" $State}}
  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
  if ($State.NativeCleanupDebt -or $State.CleanupDebt.Count -ne 0) {throw "Staging resources have unacknowledged retirement"}
  Write-Output "READY"
  exit 0
} catch {
  $Receipt=@{}
  if (Get-Command Get-ErgoptiUpdaterFailureReceipt -ErrorAction SilentlyContinue) { $Receipt=Get-ErgoptiUpdaterFailureReceipt $_.Exception $State }
  if ($AuthenticatedSize -le 0 -or $State.StagedExecutableOwned) {CleanWorker $NewExe "staged_executable"}
  if ($AuthenticatedSize -le 0 -or $State.SwapWorkerOwned) {CleanWorker $SwapScriptPath "swap_worker"}
  @{schema_version=1;state="failed";operation="download";reason=$State.Reason;receipt=$Receipt;cleanup_debt=$State.CleanupDebt;native_cleanup_debt=[bool]$State.NativeCleanupDebt}|ConvertTo-Json -Depth 4 -Compress
  exit 1
}
