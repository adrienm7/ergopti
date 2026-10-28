# tests/fixtures/winhttp_proxy_service.ps1
# An owned loopback proxy for the production request chain (AHK request, route lookup,
# worker, WinHTTP): an NTLM or Negotiate proxy that authenticates the current user through
# the actual security package, or a Basic-only proxy. With -OrderedPac it also serves a
# proxy auto-configuration file that names a closed port first, this proxy second and
# DIRECT last. Publishes its port in the private state file, then serves until the named
# stop event is signalled and writes its final counters.
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$StopEvent,
    [ValidateSet('Ntlm', 'Negotiate', 'Basic')][string]$Mode = 'Ntlm',
    [switch]$OrderedPac
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'winhttp_test_services.ps1')
if ($StopEvent -cnotmatch '^Local\\ErgoptiPlus\.WinHttpProxy\.[0-9a-f]{32}$') { throw 'Invalid owned proxy identity.' }

function Write-State([hashtable]$State) {
    $Temporary = $StatePath + '.pending'
    [IO.File]::WriteAllText($Temporary, ($State | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::Delete($StatePath)
    [IO.File]::Move($Temporary, $StatePath)
}

$Stop = [Threading.EventWaitHandle]::OpenExisting($StopEvent)
$Server = New-Object ErgoptiWinHttpTestServer
$Refused = $null
try {
    $Server.Mode = $(if ($Mode -ceq 'Basic') { 'proxy_basic' } else { 'proxy_sspi' })
    if ($Mode -ceq 'Negotiate') { $Server.Package = 'Negotiate' } else { $Server.Package = 'NTLM' }
    $Server.AdvertiseNegotiate = ($Mode -ceq 'Negotiate')
    $ClosedPort = 0
    if ($OrderedPac) {
        # Bound without Listen: the first PAC route actually refuses TCP.
        $Refused = New-Object Net.Sockets.Socket([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
        $Refused.ExclusiveAddressUse = $true
        $Refused.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Loopback, 0)))
        $ClosedPort = ([Net.IPEndPoint]$Refused.LocalEndPoint).Port
    }
    $Server.Start()
    if ($OrderedPac) {
        $Server.PacScript = 'function FindProxyForURL(url, host) { if (host === ''origin.invalid'') return ''PROXY 127.0.0.1:' +
            $ClosedPort + '; PROXY 127.0.0.1:' + $Server.Port + '; DIRECT''; return ''DIRECT''; }'
    }
    Write-State @{ schema_version = 1; state = 'ready'; port = $Server.Port; closed_port = $ClosedPort }
    $null = $Stop.WaitOne(120000)
} finally {
    $Final = @{ schema_version = 1; state = 'stopped'; port = $Server.Port; type_one = $Server.Type1; type_three = $Server.Type3;
        spnego_legs = $Server.SpnegoLegs; authenticated = $Server.Authenticated; identity_matched = [bool]$Server.IdentityMatched;
        proxy_authorizations = $Server.ProxyAuthorizations; basic_attempts = $Server.BasicAttempts;
        origin_authorizations = $Server.OriginAuthorizations; requests = $Server.Requests.Count; failure = [string]$Server.Failure }
    $Server.Dispose()
    if ($null -ne $Refused) { $Refused.Dispose() }
    Write-State $Final
    $Stop.Dispose()
}
[Console]::Out.WriteLine('OWNED_WINHTTP_PROXY_STOPPED')
