# tests/fixtures/updater_download_receipts.ps1
# Native Windows filesystem control plus independent typed receipt controls.
# Synthetic WebException controls do not claim real TLS/proxy qualification.
param([Parameter(Mandatory = $true)][string]$HelperPath)
$ErrorActionPreference = 'Stop'
. $HelperPath
Add-Type -TypeDefinition @'
using System;
using System.IO;
public sealed class ErgoptiUpdaterDisposeRefusal : IDisposable
{
    public void Dispose() { throw new IOException("private cleanup diagnostic"); }
}
'@

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Receipt([Exception]$Exception, [string]$Stage) {
    return Get-ErgoptiUpdaterFailureReceipt $Exception @{ Stage = $Stage; Receipt = @{} }
}

$Fixture = Join-Path ([IO.Path]::GetTempPath()) ('ErgoptiUpdaterReceipt.' + [Guid]::NewGuid().ToString('N'))
$Created = $false
$Passed = 0
try {
    [IO.Directory]::CreateDirectory($Fixture) | Out-Null
    $Created = $true
    $Native = $null
    try {
        # Opening our real directory as a writable file is denied by Windows.
        $Unexpected = [IO.File]::Open($Fixture, [IO.FileMode]::Create,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $Unexpected.Dispose()
    } catch {
        $Native = Get-ErgoptiUpdaterNativeException $_.Exception
    }
    Require ($Native -is [UnauthorizedAccessException]) 'Owned filesystem permission control did not fail natively.'
    $Result = Receipt $Native 'file_create'
    Require ($Result.stage -eq 'file_create' -and $Result.failure_provenance -eq 'verified' -and
        $Result.native_errno_domain -eq 'win32' -and $Result.native_errno -eq '5') 'Actual owned file denial was not preserved.'
    $Passed++

    $PolicyPath = Join-Path (Split-Path -Parent (Split-Path -Parent $HelperPath)) '../_shared/modules/network/managed_network.json'
    $Policy = Get-Content -LiteralPath $PolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $NativeNames = [Enum]::GetNames([System.Net.WebExceptionStatus])
    Require ($NativeNames.Count -eq $Policy.fields.dotnet_web_status.values.Count) 'Canonical .NET status inventory differs from the documented runtime enum.'
    foreach ($Name in $NativeNames) {
        Require ($Policy.fields.dotnet_web_status.values -ccontains $Name) 'A documented runtime status is missing from the canonical closed enum.'
    }
    foreach ($Status in [Enum]::GetValues([System.Net.WebExceptionStatus])) {
        $Typed = [System.Net.WebException]::new('private exception content', $Status)
        $Result = Receipt $Typed 'connect'
        Require ($Result.dotnet_web_status -ceq [string]$Status) 'Documented WebException status disappeared from the native receipt.'
        Require (-not $Result.ContainsKey('native_errno')) 'Managed WebException status invented an OS errno.'
        $Passed++
    }
    $UnknownStatus = [System.Net.WebException]::new('NameResolutionFailure', [Enum]::ToObject([System.Net.WebExceptionStatus], 999))
    $Result = Receipt $UnknownStatus 'connect'
    Require (-not $Result.ContainsKey('dotnet_web_status')) 'An undefined WebException status was admitted.'
    $Passed++
    $Result = Receipt ([Exception]::new('NameResolutionFailure')) 'connect'
    Require (-not $Result.ContainsKey('dotnet_web_status')) 'Exception text invented a typed WebException status.'
    $Passed++

    $NetworkRead = [IO.IOException]::new('disk full permission denied SHA-256 secret-url')
    $Result = Receipt $NetworkRead 'connect'
    Require (-not $Result.ContainsKey('native_errno') -and $Result.failure_provenance -eq 'unknown' -and
        $Result.stage -eq 'connect') 'Network-read IOException borrowed a file diagnosis.'
    $Passed++
    $Result = Receipt $NetworkRead 'file_write'
    Require (-not $Result.ContainsKey('native_errno') -and $Result.failure_provenance -eq 'unknown') 'Managed IOException low word was mistaken for Win32 provenance.'
    $Passed++

    $Trust = [System.Net.WebException]::new('private-path', [System.Net.WebExceptionStatus]::TrustFailure)
    $Result = Receipt $Trust 'connect'
    Require ($Result.stage -eq 'tls' -and $Result.tls_status -eq 'untrusted_certificate' -and
        $Result.tls_verification -eq 'enforced' -and $Result.failure_provenance -eq 'verified') 'Typed TrustFailure lost its actual verification status.'
    $Passed++
    $GenericTls = [System.Net.WebException]::new('certificate text', [System.Net.WebExceptionStatus]::SecureChannelFailure)
    $Result = Receipt $GenericTls 'connect'
    Require ($Result.stage -eq 'tls' -and -not $Result.ContainsKey('tls_status') -and
        $Result.failure_provenance -eq 'unknown') 'Generic secure-channel failure became certificate refusal.'
    $Passed++

    $Wrapped = [System.Management.Automation.MethodInvocationException]::new('wrapper secret', $Native)
    $Result = Receipt $Wrapped 'file_write'
    Require ($Result.native_errno -eq '5' -and $Result.stage -eq 'file_write') 'PowerShell native invocation wrapper lost filesystem provenance.'
    $Passed++
    foreach ($Pair in $Result.GetEnumerator()) {
        Require ([string]$Pair.Value -notmatch 'secret|private-path|secret-url') 'A raw native message escaped the receipt.'
    }
    $Passed++

    $State = @{ Stage = 'connect'; Receipt = @{
        backend = 'dotnet'; stage = 'http'; failure_provenance = 'verified';
        http_status = 407; http_response_source = 'unavailable' } }
    $Result = Get-ErgoptiUpdaterFailureReceipt ([Exception]::new('Proxy-Authenticate')) $State
    Require ($Result.http_status -eq 407 -and $Result.http_response_source -eq 'unavailable' -and
        -not $Result.ContainsKey('proxy_connect_status')) 'Observed HTTP407 became fabricated CONNECT/proxy evidence.'
    $Passed++

    # Controlled disposable failure tests the debt ledger, not actual OS close.
    $Primary = $State.Receipt
    Close-ErgoptiUpdaterResource ([ErgoptiUpdaterDisposeRefusal]::new()) 'output' 'file_write' $State
    Require ($State.CleanupDebt.Count -eq 1 -and $State.CleanupDebt[0].resource -eq 'output') 'Cleanup refusal disappeared instead of becoming bounded debt.'
    $Passed++
    Require ([Object]::ReferenceEquals($Primary, $State.Receipt) -and
        $State.Receipt.http_status -eq 407) 'Cleanup overwrote the primary native failure.'
    $Passed++
    Require ($State.CleanupDebt[0].receipt.failure_provenance -eq 'unknown' -and
        -not $State.CleanupDebt[0].receipt.ContainsKey('native_errno')) 'Managed cleanup IOException fabricated Win32 evidence.'
    $Passed++
    $OriginalTick = [int64][ErgoptiUpdaterMonotonicClock]::GetTickCount64()
    Require ($OriginalTick -gt 2) 'Native original monotonic tick is unavailable.'
    $Remaining = Get-ErgoptiUpdaterRemainingMilliseconds $OriginalTick 10000
    Require ($Remaining -gt 0 -and $Remaining -le 10000) 'Native clock must preserve the original nonexpired budget.'
    $Passed++
    $Expired = $null
    $DeadlineState = @{ Reason = 'download' }
    try { $null = Get-ErgoptiUpdaterRemainingMilliseconds ($OriginalTick - 2) 1 $DeadlineState }
    catch { $Expired = Get-ErgoptiUpdaterNativeException $_.Exception }
    Require ($Expired -is [TimeoutException] -and $DeadlineState.Reason -ceq 'deadline') 'An expired original clock was replaced by a fresh startup budget.'
    $Passed++
    # Controlled resolver retirement refusal exercises the actual downloader
    # refusal path. It does not prove native WinHTTP callback closure.
    $PrimaryResolverReceipt = @{ backend = 'dotnet'; stage = 'http';
        failure_provenance = 'verified'; http_status = 407; http_response_source = 'unavailable' }
    $Selection = @{ Ok = $false; Receipt = $PrimaryResolverReceipt; CleanupDebt = $true }
    $Resolver = { param($Destination, $Budget) return $Selection }.GetNewClosure()
    $ResolverState = @{ Stage = 'proxy_resolve'; Reason = 'download'; Receipt = @{} }
    $Refused = $false
    try {
        $Request = [Net.HttpWebRequest]::Create('https://owned-updater.invalid/private-download')
        $null = Invoke-ErgoptiUpdaterDownload $Request (Join-Path $Fixture 'staged.exe') 1000 $ResolverState $Resolver 10000 ([int64][ErgoptiUpdaterMonotonicClock]::GetTickCount64())
    } catch { $Refused = $true }
    Require ($Refused -and $ResolverState.NativeCleanupDebt -is [bool] -and
        $ResolverState.NativeCleanupDebt) 'Native resolver retirement debt disappeared at downloader refusal.'
    $Passed++
    Require ([Object]::ReferenceEquals($PrimaryResolverReceipt, $ResolverState.Receipt) -and
        $ResolverState.Receipt.http_status -eq 407 -and
        -not $ResolverState.Receipt.ContainsKey('proxy_connect_status')) 'Native retirement debt replaced the primary receipt or invented CONNECT provenance.'
    $Passed++
    # Actual transport credential construction; not an SSPI/wire acceptance claim.
    $ProxyUri = [Uri]'http://127.0.0.1:1'
    $Credentials = New-ErgoptiUpdaterProxyCredentials $ProxyUri
    Require ($Credentials -is [Net.CredentialCache]) 'Proxy credential construction lost its exact cache type.'
    $Passed++
    Require ($null -ne $Credentials.GetCredential($ProxyUri, 'Negotiate')) 'Actual proxy cache lost sole Negotiate admission.'
    $Passed++
    foreach ($Scheme in @('NTLM', 'Basic', 'Digest')) {
        Require ($null -eq $Credentials.GetCredential($ProxyUri, $Scheme)) ('Automatic proxy auth admitted forbidden scheme: ' + $Scheme)
        $Passed++
    }
    Write-Output ('UPDATER_RECEIPT_CONTROLS:' + $Passed)
} finally {
    if ($Created) {
        # No recursive removal: this fixture owns one empty directory only.
        [IO.Directory]::Delete($Fixture, $false)
    }
}
