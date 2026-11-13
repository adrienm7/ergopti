# tests/fixtures/core/managed_redirect_controls.ps1
# The genuine worker owns redirects, admission and WinHTTP retirement. Only owned
# loopback peers are contacted; request bodies are checked by length and digest.
param(
    [Parameter(Mandatory = $true)][string]$WorkerPath,
    [Parameter(Mandatory = $true)][string]$SharedPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$VendorPath = [IO.Path]::GetDirectoryName($WorkerPath)
. (Join-Path $VendorPath 'ergopti_winhttp_transport.ps1')
. (Join-Path $PSScriptRoot 'winhttp_test_services.ps1')
$Work = Join-Path ([IO.Path]::GetTempPath()) ('ergopti_redirect_controls_' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($Work) | Out-Null
$Servers = New-Object Collections.Generic.List[object]
$Serial = 0
$Passed = 0
$Payload = 'owned-GET-body-canary-' + [char]0xE9
$Hash = [Security.Cryptography.SHA256]::Create()
try { $PayloadDigest = [BitConverter]::ToString($Hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Payload))).Replace('-', '') }
finally { $Hash.Dispose() }
$Ok200 = "HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok"
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('REDIRECT CONTROL FAILED: ' + $Message) }
}
function New-Server([string[]]$Responses) {
    $Server = New-Object ErgoptiWinHttpTestServer
    $Server.Responses = $Responses
    $Server.Start()
    $Servers.Add($Server)
    return $Server
}
function Invoke-Worker([string]$Url, [string]$Method, [string]$Body) {
    $script:Serial += 1
    $Id = '4242_' + $script:Serial
    $Directory = Join-Path $Work ([string]$script:Serial)
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $InputFile = Join-Path $Directory 'input.json'
    $InputObject = @{
        schema_version = 1; request_id = $Id; method = $Method; url = $Url; body = ''; headers = @()
        budget_ms = 30000; deadline_ms = 30000; started_tick = [ErgoptiWinHttpTransport]::CurrentTick()
        max_response_bytes = 1048576; max_header_bytes = 65536; connect_timeout_ms = 2000
        revocation_best_effort = $true; fixed_proxy = ''; user_agent = 'ErgoptiPlus-Redirect-Controls/1.0'
        policy_path = (Join-Path $SharedPath 'core/network/data/proxy_policy.json')
        defaults_path = (Join-Path $SharedPath 'updater/data/defaults.json')
        route_path = (Join-Path $VendorPath 'ergopti_network_routes.ps1')
        response_path = (Join-Path $Directory 'response.bin'); header_path = (Join-Path $Directory 'headers.txt')
    }
    [IO.File]::WriteAllText($InputFile, ($InputObject | ConvertTo-Json -Compress -Depth 8), [Text.UTF8Encoding]::new($false))
    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $Info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $WorkerPath + '" -InputPath "' + $InputFile + '"'
    $Info.UseShellExecute = $false; $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true; $Info.RedirectStandardError = $true
    $Process = New-Object Diagnostics.Process
    $Process.StartInfo = $Info
    $Started = $false
    try {
        $Started = $Process.Start()
        Require ($Started) 'The exact worker process did not start.'
        $Clock = [Diagnostics.Stopwatch]::StartNew()
        $Admission = Join-Path $Directory 'admission.json'
        while (-not [IO.File]::Exists($Admission) -and -not $Process.HasExited -and $Clock.ElapsedMilliseconds -lt 15000) {
            Start-Sleep -Milliseconds 10
        }
        Require ([IO.File]::Exists($Admission)) 'The real worker did not publish native transport admission.'
        $Ready = [IO.File]::ReadAllText($Admission) | ConvertFrom-Json
        Require ($Ready.schema_version -eq 1 -and $Ready.request_id -ceq $Id -and $Ready.state -ceq 'ready' -and $Ready.child_quiesced) 'Native admission did not belong to this exact request.'
        $Transport = @{ schema_version = 1; request_id = $Id; body = $Body
            headers = @(@{ name = 'Authorization'; value = 'Bearer owned-redirect-fixture' }) }
        $TransportPending = Join-Path $Directory 'transport.pending'
        [IO.File]::WriteAllText($TransportPending, ($Transport | ConvertTo-Json -Compress -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($TransportPending, (Join-Path $Directory 'transport.json'))
        Require ($Process.WaitForExit(30000)) 'The actual worker exceeded its terminal bound.'
        $Output = $Process.StandardOutput.ReadToEnd()
        Require ($Process.StandardError.ReadToEnd() -eq '') 'The worker emitted an unexpected native diagnostic.'
        $Answer = $Output | ConvertFrom-Json
        Require ($Answer.schema_version -eq 1 -and $Answer.child_quiesced -eq $true) 'The terminal worker must acknowledge native handle retirement.'
        return @{ Answer = $Answer; ExitCode = $Process.ExitCode }
    } finally {
        if ($Started -and -not $Process.HasExited) {
            $Process.Kill()
            Require ($Process.WaitForExit(5000)) 'The exact worker process did not retire after cancellation.'
        }
        $Process.Dispose()
    }
}
function Check-Redirect([string]$Name, [int]$Status, [string]$Method, [string]$Body, [bool]$CrossOrigin, [bool]$Refused, [bool]$KeepsBody) {
    $Target = New-Server @($Ok200)
    $Source = New-Server @($Ok200)
    $Location = $(if ($CrossOrigin) { 'http://127.0.0.1:' + $Target.Port + '/after' } else { '/after' })
    $Redirect = "HTTP/1.1 $Status Redirect`r`nLocation: $Location`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
    $Source.Responses = @($Redirect, $Ok200)
    $Result = Invoke-Worker ('http://127.0.0.1:' + $Source.Port + '/start') $Method $Body
    Require ($Source.Requests.Count -ge 1 -and $Source.Requests[0].StartsWith($Method + ' /start HTTP/1.1')) 'The original method must reach the genuine source peer.'
    Require ($Source.BodyLengths[0] -eq [Text.Encoding]::UTF8.GetByteCount($Body)) 'The source must receive the exact staged UTF-8 body length.'
    if ($Body -ne '') { Require ($Source.BodyDigests[0] -ceq $PayloadDigest) 'The source must receive the exact staged canary bytes.' }
    if ($Refused) {
        Require (-not $Result.Answer.ok -and $Result.ExitCode -eq 1) 'A method-preserving cross-origin payload redirect must be refused.'
        Require ($Source.Requests.Count -eq 1 -and $Target.Connections -eq 0 -and $Target.Requests.Count -eq 0) 'A refused redirect must not contact the second origin.'
    } else {
        Require ($Result.Answer.ok -and $Result.Answer.status -eq 200 -and $Result.ExitCode -eq 0) 'An allowed redirect must really finish through WinHTTP.'
        $Receiver = $(if ($CrossOrigin) { $Target } else { $Source })
        $Index = $(if ($CrossOrigin) { 0 } else { 1 })
        Require ($Receiver.Requests.Count -eq $Index + 1 -and $Receiver.Requests[$Index].StartsWith('GET /after HTTP/1.1')) 'The target must receive the admitted redirected method.'
        Require ($Receiver.BodyLengths[$Index] -eq $(if ($KeepsBody) { [Text.Encoding]::UTF8.GetByteCount($Body) } else { 0 })) 'The redirected body policy changed.'
        if ($KeepsBody) { Require ($Receiver.BodyDigests[$Index] -ceq $PayloadDigest) 'A same-origin preserved body must retain every canary byte.' }
        if ($CrossOrigin) { Require ($Receiver.OriginAuthorizations -eq 0) 'A caller credential must never reach the other origin.' }
    }
    $script:Passed += 1
    [Console]::Out.WriteLine('CONTROL ' + $Name)
}
try {
    foreach ($Status in @(301, 302, 307, 308)) {
        Check-Redirect ('get_body_cross_origin_' + $Status) $Status 'GET' $Payload $true $true $false
    }
    foreach ($Status in @(307, 308)) {
        Check-Redirect ('empty_get_cross_origin_' + $Status) $Status 'GET' '' $true $false $false
    }
    Check-Redirect 'get_body_cross_origin_303' 303 'GET' $Payload $true $false $false
    Check-Redirect 'post_body_cross_origin_303' 303 'POST' $Payload $true $false $false
    foreach ($Status in @(307, 308)) {
        Check-Redirect ('get_body_same_origin_' + $Status) $Status 'GET' $Payload $false $false $true
        Check-Redirect ('post_body_cross_origin_' + $Status) $Status 'POST' $Payload $true $true $false
    }
    [Console]::Out.WriteLine('MANAGED_REDIRECT_CONTROLS:' + $Passed)
} finally {
    foreach ($Server in $Servers) { $Server.Dispose() }
    [IO.Directory]::Delete($Work, $true)
}
