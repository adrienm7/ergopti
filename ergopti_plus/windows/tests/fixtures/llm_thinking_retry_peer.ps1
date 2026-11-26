# Owned loopback peer for the native Menu thinking-retry regressions.
param(
    [Parameter(Mandatory=$true)][string]$Directory,
    [Parameter(Mandatory=$true)][string]$ServicesPath,
    [Parameter(Mandatory=$true)][string]$Nonce,
    [Parameter(Mandatory=$true)][ValidateSet('positive','cancel','http400','http200','alias-complete','alias-cancel')][string]$Case
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($Nonce -cnotmatch '^[0-9]+_[0-9]+_[0-9]+$') { throw 'Invalid private nonce.' }
if (-not [IO.Directory]::Exists($Directory)) { throw 'Missing exclusively owned directory.' }
if ((Get-Item -LiteralPath $Directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked directory refused.' }
. $ServicesPath
$Encoding = [Text.UTF8Encoding]::new($false, $true)
$Server = $null
$Primary = $null
$Released = $false
$Stopped = $false
$ListenerRetired = $false
$Until = [DateTime]::UtcNow.AddSeconds(90)
function Write-PrivateJson([string]$Name, $Value) {
    $Bytes = $Encoding.GetBytes(($Value | ConvertTo-Json -Depth 5 -Compress))
    $Path = Join-Path $Directory $Name
    $Pending = $Path + '.pending'
    $Stream = [IO.File]::Open($Pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $Stream.Write($Bytes, 0, $Bytes.Length); $Stream.Flush() } finally { $Stream.Dispose() }
    [IO.File]::Move($Pending, $Path)
}
function Test-Control([string]$Name) {
    $Path = Join-Path $Directory $Name
    if (-not [IO.File]::Exists($Path)) { return $false }
    if ([IO.File]::ReadAllText($Path, $Encoding) -cne $Nonce) { throw 'Foreign control refused.' }
    return $true
}
try {
    $CrLf = ([string][char]13) + [char]10
    $Bad = if ($Case -ceq 'http400') { '{"error":{"message":"owned-classification-refusal"}}' } else { '{"error":{"message":"Unknown parameter: thinking.type"}}' }
    $Good = '{"choices":[{"message":{"content":"owned-thinking-retry-ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
    $BadResponse = 'HTTP/1.1 400 Bad Request' + $CrLf + 'Content-Type: application/json' + $CrLf +
        'Content-Length: ' + $Encoding.GetByteCount($Bad) + $CrLf + 'Connection: close' + $CrLf + $CrLf + $Bad
    $GoodResponse = 'HTTP/1.1 200 OK' + $CrLf + 'Content-Type: application/json' + $CrLf +
        'Content-Length: ' + $Encoding.GetByteCount($Good) + $CrLf + 'Connection: close' + $CrLf + $CrLf + $Good
    $Server = New-Object ErgoptiWinHttpTestServer
    $Server.Mode = 'static'
    $Server.Responses = if ($Case -ceq 'http200') { @($GoodResponse) }
        elseif ($Case -ceq 'http400') { @($BadResponse) }
        else { @($BadResponse, $GoodResponse) }
    if ($Case -ceq 'alias-complete' -or $Case -ceq 'alias-cancel') { $Server.HoldResponseAt = 2 }
    # Reserve the native listener, but do not start its accept thread until
    # the genuine Menu handler has returned and published its original id.
    # TcpListener.Start is idempotent; Server.Start starts the acceptor later.
    $Server.Listener.Start()
    Write-PrivateJson 'ready.json' @{schema_version=1; nonce=$Nonce; case=$Case; pid=$PID; port=$Server.Port}
    while (-not ($Released = Test-Control 'release')) {
        if (($Stopped = Test-Control 'stop')) { break }
        if ([DateTime]::UtcNow -ge $Until) { throw 'Release deadline exceeded.' }
        Start-Sleep -Milliseconds 10
    }
    if (-not $Stopped) {
        $Server.Start()
        $WaitingPublished = $false
        while (-not ($Stopped = Test-Control 'stop')) {
            if ($Server.HeldResponseObserved -and -not $WaitingPublished) {
                Write-PrivateJson 'retry_waiting.json' @{nonce=$Nonce; case=$Case; pid=$PID}
                $WaitingPublished = $true
            }
            if ($Case -ceq 'alias-complete' -and (Test-Control 'finish-retry')) { $Server.ReleaseHeldResponse = $true }
            if ([DateTime]::UtcNow -ge $Until) { throw 'Stop deadline exceeded.' }
            Start-Sleep -Milliseconds 10
        }
    }
} catch { $Primary = $_ }
finally {
    if ($null -ne $Server) {
        try {
            $Server.Dispose()
            # Dispose closes listeners/clients; this receipt claims no thread
            # join. The parent additionally requires exact process-tree ACK.
            try { $ListenerRetired = -not $Server.Listener.Server.IsBound }
            catch [ObjectDisposedException] { $ListenerRetired = $true }
            if (-not $ListenerRetired) { throw 'Listener retirement not observed.' }
            $Requests = @($Server.Requests.ToArray())
            $Lengths = @($Server.BodyLengths.ToArray())
            if ($Requests.Count -ne $Lengths.Count) { throw 'Request census changed.' }
            foreach ($Request in $Requests) {
                if (-not $Request.StartsWith('POST /v1/chat/completions HTTP/1.1', [StringComparison]::Ordinal)) {
                    throw 'Unexpected native request route.'
                }
            }
            foreach ($Length in $Lengths) {
                if ($Length -le 0 -or $Length -gt 16384) { throw 'Unexpected native body length.' }
            }
            if ($Server.Failure -ne '') { throw 'Owned native server failed.' }
            Write-PrivateJson 'receipt.json' @{
                schema_version=1; nonce=$Nonce; case=$Case; pid=$PID; released=$Released;
                stop_received=$Stopped; listener_retired=$ListenerRetired;
                http_requests=$Requests.Count; body_lengths=$Lengths;
                source='ErgoptiWinHttpTestServer'; ok=($null -eq $Primary)
            }
        } catch { if ($null -eq $Primary) { $Primary = $_ } }
    }
}
if ($null -ne $Primary) {
    [Console]::Error.WriteLine('THINKING_RETRY_PEER_FAILURE:' + $Primary.Exception.GetType().Name)
    exit 1
}
[Console]::Out.WriteLine('THINKING_RETRY_PEER case=' + $Case + ' requests=' + $Server.Requests.Count + ' listener_retired=true')
