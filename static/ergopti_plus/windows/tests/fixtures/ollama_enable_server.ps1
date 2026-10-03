# tests/fixtures/ollama_enable_server.ps1

# ==============================================================================
# MODULE: Owned Ollama Enable Loopback Fixture
# DESCRIPTION:
# Holds an actual version response until the AHK owner proves its disabled state.
# Reports the exact GET path and detects a forbidden automatic redirect follow.
# ==============================================================================

param(
    [string]$ReadyPath,
    [string]$RequestPath,
    [string]$ReleasePath,
    [string]$BodyPath,
    [int]$Status
)

$ErrorActionPreference = 'Stop'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$client = $null
$stream = $null
$reader = $null
try {
    $listener.Start()
    [System.IO.File]::WriteAllText($ReadyPath, [string]$listener.LocalEndpoint.Port)
    $client = $listener.AcceptTcpClient()
    $stream = $client.GetStream()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII)
    $request = $reader.ReadLine()
    do { $header = $reader.ReadLine() } while ($header)
    [System.IO.File]::WriteAllText($RequestPath, $request)
    $deadline = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not [System.IO.File]::Exists($ReleasePath)) {
        if ($deadline.ElapsedMilliseconds -ge 5000) { throw 'Enable fixture release was not acknowledged.' }
        Start-Sleep -Milliseconds 5
    }
    $body = [System.IO.File]::ReadAllText($BodyPath, [System.Text.Encoding]::UTF8)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $separator = [char]13 + [char]10
    $headers = 'HTTP/1.1 ' + $Status + ' Fixture' + $separator
    $headers += 'Content-Type: application/json' + $separator
    $headers += 'Content-Length: ' + $bytes.Length + $separator
    $headers += 'Connection: close' + $separator
    if ($Status -eq 302) {
        $headers += 'Location: http://127.0.0.1:' + $listener.LocalEndpoint.Port + '/redirect-target' + $separator
    }
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers + $separator)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $reader.Dispose()
    $reader = $null
    $stream = $null
    $client.Dispose()
    $client = $null
    $followed = $false
    $deadline.Restart()
    while ($deadline.ElapsedMilliseconds -lt 250) {
        if ($listener.Pending()) { $followed = $true; break }
        Start-Sleep -Milliseconds 5
    }
    [System.IO.File]::AppendAllText($RequestPath, "`nfollowed=" + $followed.ToString().ToLowerInvariant())
} finally {
    if ($reader) { $reader.Dispose() }
    elseif ($stream) { $stream.Dispose() }
    if ($client) { $client.Dispose() }
    $listener.Stop()
}
