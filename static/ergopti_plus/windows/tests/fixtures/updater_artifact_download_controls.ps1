# tests/fixtures/updater_artifact_download_controls.ps1
# The real artifact download function (vendor/ergopti_updater_download.ps1) over the real
# WinHTTP engine, against owned loopback services. Success over TLS needs a trusted root and
# belongs to the native CA fixtures; this file proves what the staging worker relies on when
# a transfer does NOT succeed: HTTPS only, closed receipts, no executable written, the private
# capture retired and no cleanup debt. Prints "CONTROL <name>" lines and the final
# "ARTIFACT_DOWNLOAD_CONTROLS:<count>".
param(
    [Parameter(Mandatory = $true)][string]$VendorDirectory,
    [Parameter(Mandatory = $true)][string]$SchemaPath,
    [Parameter(Mandatory = $true)][string]$PolicyPath,
    [Parameter(Mandatory = $true)][string]$DefaultsPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'winhttp_test_services.ps1')
. (Join-Path $VendorDirectory 'ergopti_updater_download.ps1')
. (Join-Path $VendorDirectory 'ergopti_network_routes.ps1')

$Passed = 0
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('CONTROL FAILED: ' + $Message) }
}
function Pass([string]$Name) { $script:Passed++; [Console]::Out.WriteLine('CONTROL ' + $Name) }

$Schema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Assert-ClosedReceipt([hashtable]$Receipt) {
    foreach ($Key in $Receipt.Keys) {
        $Field = $Schema.fields.PSObject.Properties[$Key]
        Require ($null -ne $Field) ('Receipt field is outside the closed inventory: ' + $Key)
        if ($Field.Value.type -ceq 'string' -and $null -ne $Field.Value.values) {
            Require ($Field.Value.values -ccontains [string]$Receipt[$Key]) ('Receipt value is outside the closed enum: ' + $Key)
        }
    }
}

$Work = Join-Path ([IO.Path]::GetTempPath()) ('ergopti_artifact_controls_' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($Work) | Out-Null
$Servers = New-Object Collections.Generic.List[object]
function New-Server([string]$Mode, [string[]]$Responses = @(), [hashtable]$Properties = @{}) {
    $Server = New-Object ErgoptiWinHttpTestServer
    $Server.Mode = $Mode
    $Server.Responses = $Responses
    foreach ($Name in $Properties.Keys) { $Server.$Name = $Properties[$Name] }
    $Server.Start()
    $Servers.Add($Server)
    return $Server
}

function Invoke-Download([string]$Url, $Route, [string]$Name) {
    $Target = Join-Path $Work ($Name + '.exe')
    $State = @{ Stage = 'proxy_resolve'; Reason = 'download'; Receipt = @{}; CleanupDebt = @() }
    $Resolver = { param($Destination, $Budget)
        @{ Ok = $true; Routes = @($Route); MaxRoutes = 4; MaxRedirects = 3; CleanupDebt = $false }
    }.GetNewClosure()
    $Failure = $null
    try {
        $null = Invoke-ErgoptiUpdaterArtifactDownload ([Uri]$Url) $Target 3000 $State $Resolver 8000 `
            ([ErgoptiUpdaterMonotonicClock]::GetTickCount64()) 4096 $PolicyPath $DefaultsPath { param($Variable) '' }
    } catch { $Failure = $_ }
    return @{ State = $State; Failure = $Failure; Target = $Target }
}

function Get-CaptureDirectories { return @(Get-ChildItem -LiteralPath $Work -Directory -Filter 'curl.*' -ErrorAction SilentlyContinue) }

try {
    $Direct = @{ Kind = 'direct'; Endpoint = ''; Authentication = 'none' }

    # HTTPS only: an http artifact URL is refused before any request.
    $Origin = New-Server 'static' @("HTTP/1.1 200 OK`r`nContent-Length: 4`r`nConnection: close`r`n`r`nabcd")
    $Result = Invoke-Download ('http://127.0.0.1:' + $Origin.Port + '/a.exe') $Direct 'plain-http'
    Require ($null -ne $Result.Failure) 'A plain HTTP artifact URL was accepted.'
    Require ($Origin.Requests.Count -eq 0) 'A plain HTTP artifact URL reached the network.'
    Require (-not [IO.File]::Exists($Result.Target)) 'A refused artifact URL created a file.'
    Pass 'plain_http_artifact_url_is_refused_before_any_request'

    # An untrusted certificate: closed TLS receipt, nothing written, capture retired.
    $Certificate = [ErgoptiWinHttpTestServer]::NewUntrustedCertificate()
    $Tls = New-Server 'tls' @("HTTP/1.1 200 OK`r`nContent-Length: 4`r`nConnection: close`r`n`r`nabcd") @{ Certificate = $Certificate }
    $Result = Invoke-Download ('https://127.0.0.1:' + $Tls.Port + '/a.exe') $Direct 'untrusted'
    Require ($null -ne $Result.Failure) 'An untrusted certificate was accepted.'
    Assert-ClosedReceipt $Result.State.Receipt
    Require ($Result.State.Receipt.backend -ceq 'winhttp' -and $Result.State.Receipt.stage -ceq 'tls' -and
        $Result.State.Receipt.tls_status -ceq 'untrusted_certificate' -and $Result.State.Receipt.tls_verification -ceq 'enforced') 'The artifact TLS receipt changed.'
    Require ($Tls.Requests.Count -eq 0) 'An untrusted certificate reached the artifact handler.'
    Require (-not [IO.File]::Exists($Result.Target)) 'A refused transfer left a staged executable.'
    Require ($Result.State.CleanupDebt.Count -eq 0 -and -not $Result.State.NativeCleanupDebt) 'A refused transfer left cleanup debt.'
    Pass 'untrusted_certificate_is_a_closed_tls_receipt_and_writes_nothing'

    # A refused connection on the only route.
    $Listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $Listener.Start(); $ClosedPort = $Listener.LocalEndpoint.Port; $Listener.Stop()
    $Result = Invoke-Download ('https://127.0.0.1:' + $ClosedPort + '/a.exe') $Direct 'refused'
    Require ($null -ne $Result.Failure) 'A refused connection was accepted.'
    Assert-ClosedReceipt $Result.State.Receipt
    Require ($Result.State.Receipt.backend -ceq 'winhttp' -and $Result.State.Receipt.stage -ceq 'connect' -and
        $Result.State.Receipt.native_errno_domain -ceq 'win32') 'The refused-connection receipt changed.'
    Pass 'refused_connection_is_a_closed_connect_receipt'

    # A proxy that refuses the tunnel: the receipt names the proxy, not the origin.
    $Deny = New-Server 'connect_deny'
    $DenyRoute = @{ Kind = 'proxy'; Endpoint = ('http://127.0.0.1:' + $Deny.Port + '/'); Authentication = 'current_user_proxy_only' }
    $Result = Invoke-Download 'https://release-origin.invalid/a.exe' $DenyRoute 'tunnel-denied'
    Require ($null -ne $Result.Failure) 'A refused tunnel was accepted.'
    Assert-ClosedReceipt $Result.State.Receipt
    Require ($Result.State.Receipt.stage -ceq 'proxy_connect' -and $Result.State.Receipt.proxy_connect_status -eq 403 -and
        $Result.State.Receipt.http_response_source -ceq 'proxy') 'The refused-tunnel receipt changed.'
    Pass 'refused_tunnel_names_the_proxy_in_a_closed_receipt'

    # A Basic-only proxy is never answered with the user's credentials.
    $Basic = New-Server 'proxy_basic'
    $BasicRoute = @{ Kind = 'proxy'; Endpoint = ('http://127.0.0.1:' + $Basic.Port + '/'); Authentication = 'current_user_proxy_only' }
    $Result = Invoke-Download 'https://release-origin.invalid/a.exe' $BasicRoute 'basic-proxy'
    Require ($null -ne $Result.Failure) 'A Basic-only proxy was accepted.'
    Require ($Basic.ProxyAuthorizations -eq 0 -and $Basic.BasicAttempts -eq 0) 'Credentials were sent to a Basic-only proxy.'
    Assert-ClosedReceipt $Result.State.Receipt
    Require ($Result.State.Receipt.stage -ceq 'proxy_connect' -and $Result.State.Receipt.proxy_connect_status -eq 407) 'The proxy-407 receipt changed.'
    Pass 'basic_only_proxy_is_refused_without_credentials'

    # Every capture directory the function created was removed again.
    Require ((Get-CaptureDirectories).Count -eq 0) 'A private capture directory outlived its transfer.'
    Pass 'private_capture_directories_are_retired'

    [Console]::Out.WriteLine('ARTIFACT_DOWNLOAD_CONTROLS:' + $Passed)
} finally {
    foreach ($Server in $Servers) { $Server.Dispose() }
    try { [IO.Directory]::Delete($Work, $true) } catch { }
}
