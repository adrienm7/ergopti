# tests/fixtures/winhttp_transport_controls.ps1
# Real WinHTTP against owned loopback services: nothing here touches the internet
# or the machine trust store. TLS success needs a trusted root and therefore
# belongs to the native CA fixtures; this file proves the TLS refusal path with an
# untrusted self-signed certificate. Prints one "CONTROL <name>" line per control
# that held and the final "WINHTTP_TRANSPORT_CONTROLS:<count>" line.
param(
    [Parameter(Mandatory = $true)][string]$TransportPath,
    [Parameter(Mandatory = $true)][string]$SchemaPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. $TransportPath

. (Join-Path $PSScriptRoot 'winhttp_test_services.ps1')

$Passed = 0
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('CONTROL FAILED: ' + $Message) }
}
function Pass([string]$Name) { $script:Passed++; [Console]::Out.WriteLine('CONTROL ' + $Name) }

$Schema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Work = Join-Path ([IO.Path]::GetTempPath()) ('ergopti_winhttp_controls_' + [Guid]::NewGuid().ToString('N'))
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

function New-Engine([int]$Budget = 6000, [long]$Max = 1048576, [int]$MaxHeader = 65536, $Headers = @(), [string]$Body = '') {
    $Answer = @{ child_quiesced = $true }
    $Input = [pscustomobject]@{
        started_tick = [ErgoptiWinHttpTransport]::CurrentTick(); deadline_ms = $Budget; connect_timeout_ms = 2000
        max_response_bytes = $Max; max_header_bytes = $MaxHeader
        response_path = (Join-Path $Work 'response.bin'); header_path = (Join-Path $Work 'headers.txt')
        revocation_best_effort = $true; headers = $Headers; body = $Body; user_agent = 'ErgoptiPlus-Controls/1.0'
    }
    return @{ Engine = (New-ErgoptiWinHttpAttemptEngine $Input $Answer); Answer = $Answer; Input = $Input }
}

function Get-Route([string]$Kind, $Server = $null) {
    if ($Kind -ceq 'direct') { return @{ Kind = 'direct'; Endpoint = ''; Authentication = 'none' } }
    return @{ Kind = 'proxy'; Endpoint = ('http://127.0.0.1:' + $Server.Port + '/'); Authentication = 'current_user_proxy_only' }
}

# Every receipt must stay inside the closed inventory of the shared schema.
function Assert-ClosedReceipt([hashtable]$Receipt) {
    foreach ($Key in $Receipt.Keys) {
        $Field = $Schema.fields.PSObject.Properties[$Key]
        Require ($null -ne $Field) ('Receipt field is outside the closed inventory: ' + $Key)
        if ($Field.Value.type -ceq 'string' -and $null -ne $Field.Value.values) {
            Require ($Field.Value.values -ccontains [string]$Receipt[$Key]) ('Receipt value is outside the closed enum: ' + $Key)
        }
        if ($Field.Value.type -ceq 'integer') { Require ($Receipt[$Key] -is [int]) ('Receipt integer expected: ' + $Key) }
    }
}

$Ok200 = "HTTP/1.1 200 OK`r`nContent-Length: 5`r`nX-Test: yes`r`nConnection: close`r`n`r`nhello"
try {
    # --- direct requests ---------------------------------------------------
    $Server = New-Server 'static' @($Ok200)
    $Context = New-Engine -Headers @([pscustomobject]@{ name = 'X-Empty'; value = '' }, [pscustomobject]@{ name = 'Authorization'; value = 'Bearer owned-secret' },
        [pscustomobject]@{ name = 'X-Full'; value = 'v' })
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/a/b?c=d%20e'), (Get-Route 'direct'), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 200 -and $Metrics.delivered -eq 5 -and $Metrics.child_quiesced) 'Direct GET did not complete with a retired native state.'
    Require ([IO.File]::ReadAllText((Join-Path $Work 'response.bin')) -ceq 'hello') 'Direct GET body bytes changed.'
    Require ($Metrics.headers.headers['x-test'] -ceq 'yes') 'Response headers were not parsed.'
    $Wire = $Server.Requests[0]
    Require ($Wire.StartsWith('GET /a/b?c=d%20e HTTP/1.1')) 'The exact request target was not preserved.'
    Require ($Wire -match '(?m)^X-Empty: ?\r?$') 'An empty header was not sent.'
    Require ($Wire -match '(?m)^Authorization: Bearer') 'The caller header was not sent.'
    Require ($Wire -match '(?m)^User-Agent: ErgoptiPlus-Controls/1.0') 'The caller user agent was not sent.'
    Require ($Context.Engine.ChildQuiesced()) 'The engine did not report quiescence.'
    Pass 'direct_get_exact_target_headers_and_body'

    $Server = New-Server 'static' @($Ok200)
    $Context = New-Engine
    $NonAscii = [Uri]('http://127.0.0.1:' + $Server.Port + '/caf' + [char]0xE9 + '/' + [char]0xFC + '?q=' + [char]0x20AC)
    $Metrics = $Context.Engine.InvokeRoute($NonAscii, (Get-Route 'direct'), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 200) 'A non-ASCII target did not complete.'
    Require ($Server.Requests[0].StartsWith('GET /caf%C3%A9/%C3%BC?q=%E2%82%AC HTTP/1.1')) 'A non-ASCII target was not sent as percent-encoded UTF-8.'
    Pass 'non_ascii_target_is_sent_as_percent_encoded_utf8'

    $Server = New-Server 'static' @("HTTP/1.1 201 Created`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok")
    $Payload = '{"text":"caf' + [char]0xE9 + ' ' + [char]0x20AC + '"}'
    $Context = New-Engine -Headers @([pscustomobject]@{ name = 'Content-Type'; value = 'application/json' }) -Body $Payload
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/post'), (Get-Route 'direct'), 'POST', $true, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 201) 'POST did not complete.'
    Require ($Server.Requests[0] -match "Content-Length: $([Text.Encoding]::UTF8.GetByteCount($Payload))") 'POST did not send the exact UTF-8 byte length.'
    Pass 'post_sends_exact_utf8_body_length'

    # Bytes that are not valid UTF-8 and contain NUL and CRLF: a checksummed
    # download is only trustworthy if the file is the wire, byte for byte.
    $Binary = [byte[]]@(0xFF, 0xFE, 0x00, 0x0D, 0x0A, 0xC3, 0x28, 0x80, 0x00, 0x7F)
    $Server = New-Server 'binary' @() @{ BinaryBody = $Binary }
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/artifact.bin'), (Get-Route 'direct'), 'GET', $false, $false)
    Require ($Metrics.completed -and $Metrics.delivered -eq $Binary.Length) 'The binary body was not delivered whole.'
    $Written = [IO.File]::ReadAllBytes((Join-Path $Work 'response.bin'))
    Require ([Convert]::ToBase64String($Written) -ceq [Convert]::ToBase64String($Binary)) 'The response file is not the wire, byte for byte.'
    Pass 'response_file_is_the_wire_byte_for_byte'

    $Server = New-Server 'static' @("HTTP/1.1 302 Found`r`nLocation: https://elsewhere.invalid/next`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/r'), (Get-Route 'direct'), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 302 -and $Metrics.headers.headers['location'] -ceq 'https://elsewhere.invalid/next') 'A redirect was not surfaced untouched.'
    Require ($Server.Requests.Count -eq 1 -and $Server.Connections -eq 1) 'The transport followed a redirect on its own.'
    Pass 'redirects_are_surfaced_never_followed'

    # --- bounds ------------------------------------------------------------
    $Server = New-Server 'static' @("HTTP/1.1 200 OK`r`nContent-Length: 20`r`nConnection: close`r`n`r`n01234567890123456789")
    $Context = New-Engine -Max 10
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'oversize') 'A declared oversize body was accepted.'
    Pass 'declared_oversize_refused_before_reading'

    $Server = New-Server 'hugebody'
    $Context = New-Engine -Max 100000
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'oversize' -and $Metrics.child_quiesced) 'An undeclared oversize body was accepted.'
    Require (([IO.FileInfo]::new((Join-Path $Work 'response.bin'))).Length -le 100000) 'Bytes beyond the bound reached the file.'
    Pass 'undeclared_oversize_stops_the_stream_at_the_bound'

    $Server = New-Server 'static' @("HTTP/1.1 200 OK`r`nX-Pad: " + ('x' * 4000) + "`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
    $Context = New-Engine -MaxHeader 1024
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'oversize') 'Oversized response headers were accepted.'
    Pass 'oversized_headers_refused'

    # --- budget and cancellation -------------------------------------------
    $Server = New-Server 'hang'
    $Context = New-Engine -Budget 1800
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'deadline' -and $Metrics.child_quiesced) 'A silent server did not end at the deadline with retired handles.'
    Require ($Clock.ElapsedMilliseconds -lt 2600) 'The deadline was not enforced inside the original budget.'
    Pass 'silent_server_ends_at_the_deadline_with_retired_handles'

    $Server = New-Server 'slowbody'
    $Context = New-Engine -Budget 1800
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'deadline' -and $Metrics.child_quiesced) 'A slow body was not cancelled at the deadline.'
    Require ($Clock.ElapsedMilliseconds -lt 2600) 'A slow body outlived the original budget.'
    Pass 'slow_body_is_cancelled_at_the_deadline'

    # --- failure classification --------------------------------------------
    $Listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $Listener.Start(); $ClosedPort = $Listener.LocalEndpoint.Port; $Listener.Stop()
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $ClosedPort + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'connect' -and $Metrics.native_error -eq 12029) 'A refused direct connection was misclassified.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, [Uri]('http://127.0.0.1:' + $ClosedPort + '/'))
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.backend -ceq 'winhttp' -and $Receipt.stage -ceq 'connect' -and $Receipt.native_errno_domain -ceq 'win32' -and $Receipt.native_errno -ceq '12029') 'The direct connect receipt changed.'
    Require (-not $Context.Engine.TestFailover($Metrics, (Get-Route 'direct'))) 'A direct failure was offered as a proxy failover.'
    Pass 'refused_direct_connection_has_a_closed_receipt_and_no_failover'

    $DeadRoute = @{ Kind = 'proxy'; Endpoint = ('http://127.0.0.1:' + $ClosedPort + '/'); Authentication = 'current_user_proxy_only' }
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $DeadRoute, 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'proxy_connect' -and $Metrics.proxy_used) 'A refused proxy was misclassified.'
    Require ($Context.Engine.TestFailover($Metrics, $DeadRoute)) 'A refused proxy before any byte must allow the next route.'
    $Metrics.delivered = 3
    Require (-not $Context.Engine.TestFailover($Metrics, $DeadRoute)) 'Failover was allowed after bytes moved.'
    Pass 'refused_proxy_before_any_byte_allows_ordered_failover'

    $UnresolvedRoute = @{ Kind = 'proxy'; Endpoint = 'http://no-such-proxy.invalid:3128/'; Authentication = 'current_user_proxy_only' }
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $UnresolvedRoute, 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'proxy_name_resolution') 'An unresolvable proxy was misclassified.'
    Require ($Context.Engine.TestFailover($Metrics, $UnresolvedRoute)) 'An unresolvable proxy must allow the next route.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, [Uri]'http://origin.invalid/x')
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.stage -ceq 'proxy_resolve' -and $Receipt.proxy_resolution_status -ceq 'unavailable') 'The proxy resolution receipt changed.'
    Pass 'unresolvable_proxy_has_a_closed_receipt_and_allows_failover'

    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://no-such-origin.invalid/x', (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'connect' -and $Metrics.native_error -eq 12007 -and -not $Context.Engine.TestFailover($Metrics, (Get-Route 'direct'))) 'An unresolvable origin was misclassified.'
    Pass 'unresolvable_origin_is_a_connect_failure'

    # --- proxy authentication ----------------------------------------------
    $Basic = New-Server 'proxy_basic'
    $Context = New-Engine
    $Route = Get-Route 'proxy' $Basic
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $Route, 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 407 -and $Metrics.proxy_answered) 'A Basic-only proxy was not left unanswered.'
    Require ($Basic.ProxyAuthorizations -eq 0 -and $Basic.BasicAttempts -eq 0) 'Credentials were sent to a Basic-only proxy.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, [Uri]'http://origin.invalid/x')
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.stage -ceq 'http' -and $Receipt.http_status -eq 407 -and $Receipt.http_response_source -ceq 'proxy' -and $Receipt.proxy_mode -ceq 'selected') 'The proxy-407 receipt changed.'
    Pass 'basic_only_proxy_gets_no_credentials'

    $Origin = New-Server 'origin_sspi' @() @{ Package = 'NTLM'; OriginMode = $true; AdvertiseNegotiate = $true }
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Origin.Port + '/secret'), (Get-Route 'direct'), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 401) 'A direct origin 401 was not returned as is.'
    Require ($Origin.OriginAuthorizations -eq 0 -and $Origin.Requests.Count -eq 1 -and $Origin.Type1 -eq 0 -and $Origin.Authenticated -eq 0) `
        ('A direct origin challenge was answered. authorizations=' + $Origin.OriginAuthorizations + ' requests=' + $Origin.Requests.Count)
    Pass 'direct_origin_challenge_is_never_answered'

    $Behind = New-Server 'proxy_sspi' @() @{ Package = 'NTLM'; ChallengeOriginAfterProxy = $true }
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/secret', (Get-Route 'proxy' $Behind), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 401) 'The origin 401 behind an authenticated proxy was not returned as is.'
    Require ($Behind.Authenticated -eq 1 -and $Behind.OriginAuthorizations -eq 0) `
        ('The user identity reached the origin behind the proxy. authorizations=' + $Behind.OriginAuthorizations + ' wire=' + ($Behind.Requests -join '|'))
    Pass 'origin_challenge_behind_an_authenticated_proxy_is_never_answered'

    $Ntlm = New-Server 'proxy_sspi' @() @{ Package = 'NTLM' }
    $Context = New-Engine
    $Route = Get-Route 'proxy' $Ntlm
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $Route, 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 200) 'An NTLM-only proxy was not authenticated with the current user.'
    Require ([IO.File]::ReadAllText((Join-Path $Work 'response.bin')) -ceq 'proxied-authenticated') 'The authenticated NTLM response body changed.'
    Require ($Ntlm.Type1 -eq 1 -and $Ntlm.Type3 -eq 1 -and $Ntlm.Authenticated -eq 1 -and $Ntlm.IdentityMatched -and $Ntlm.Failure -ceq '') 'The NTLM exchange was not one Type1, one Type3 for the current user.'
    Pass 'ntlm_only_proxy_authenticates_the_current_user_over_winhttp'

    $Spnego = New-Server 'proxy_sspi' @() @{ Package = 'Negotiate'; AdvertiseNegotiate = $true }
    $Context = New-Engine
    $Route = Get-Route 'proxy' $Spnego
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $Route, 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 200) 'A Negotiate proxy was not authenticated with the current user.'
    Require ($Spnego.Authenticated -eq 1 -and $Spnego.IdentityMatched -and $Spnego.Failure -ceq '') 'The Negotiate exchange did not authenticate the current user.'
    Pass 'negotiate_proxy_authenticates_the_current_user_over_winhttp'

    # --- TLS through an authenticating proxy --------------------------------
    $Certificate = [ErgoptiWinHttpTestServer]::NewUntrustedCertificate()
    $Tls = New-Server 'tls' @($Ok200) @{ Certificate = $Certificate }
    $Context = New-Engine
    $TlsUrl = [Uri]('https://127.0.0.1:' + $Tls.Port + '/secure')
    $Metrics = $Context.Engine.InvokeRoute($TlsUrl, (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'tls' -and $Metrics.tls_status -ceq 'untrusted_certificate' -and $Metrics.child_quiesced) ('An untrusted certificate was not refused as untrusted. ' + ($Metrics | ConvertTo-Json -Compress -Depth 3) + ' flags=' + $Tls.Failure)
    Require ($Tls.Requests.Count -eq 0) 'An untrusted certificate reached the HTTP handler.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, $TlsUrl)
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.stage -ceq 'tls' -and $Receipt.tls_verification -ceq 'enforced' -and $Receipt.tls_status -ceq 'untrusted_certificate' -and $Receipt.failure_provenance -ceq 'verified') 'The certificate receipt changed.'
    Pass 'untrusted_certificate_is_refused_with_a_closed_receipt'

    # WinHTTP never proxies a loopback address, so the tunnel targets a name; the
    # owned proxy ignores it and tunnels every CONNECT to the owned TLS service.
    $NamedTlsUrl = [Uri]('https://tls-origin.invalid:' + $Tls.Port + '/secure')
    $Tunnel = New-Server 'proxy_sspi' @() @{ Package = 'NTLM'; TunnelPort = $Tls.Port }
    $Route = Get-Route 'proxy' $Tunnel
    $Metrics = $Context.Engine.InvokeRoute($NamedTlsUrl, $Route, 'GET', $false, $true)
    Require ($Tunnel.Authenticated -eq 1 -and $Tunnel.IdentityMatched -and $Tunnel.Type1 -eq 1 -and $Tunnel.Type3 -eq 1) 'The CONNECT tunnel was not authenticated with the current user.'
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'tls' -and $Metrics.tls_status -ceq 'untrusted_certificate') 'The certificate was not verified inside the authenticated tunnel.'
    Require ($Tls.Requests.Count -eq 0) 'An untrusted certificate reached the HTTP handler through the tunnel.'
    Pass 'connect_tunnel_authenticates_then_still_verifies_the_certificate'

    $Deny = New-Server 'connect_deny'
    $Route = Get-Route 'proxy' $Deny
    $Metrics = $Context.Engine.InvokeRoute($NamedTlsUrl, $Route, 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 403 -and $Metrics.proxy_answered) 'A refused CONNECT was not attributed to the proxy.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, $NamedTlsUrl)
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.stage -ceq 'proxy_connect' -and $Receipt.proxy_connect_status -eq 403 -and $Receipt.http_response_source -ceq 'proxy') 'The CONNECT refusal receipt changed.'
    Pass 'connect_refusal_is_attributed_to_the_proxy'

    # --- capability --------------------------------------------------------
    $Capability = (New-Engine).Engine.ObserveCapability()
    Require ($Capability.tls_backend -ceq 'schannel' -and $Capability.sspi -and $Capability.spnego -and $Capability.ntlm) 'The observed capability does not list the integrated schemes.'
    Pass 'capability_is_observed_from_the_installed_providers'

    [Console]::Out.WriteLine('WINHTTP_TRANSPORT_CONTROLS:' + $Passed)
} finally {
    foreach ($Server in $Servers) { $Server.Dispose() }
    try { [IO.Directory]::Delete($Work, $true) } catch { }
}
