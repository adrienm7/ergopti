# tests/fixtures/ollama_live_identity_listener.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
Owns a bounded loopback listener for native process-identity regression tests.
.DESCRIPTION
Uses no Ollama, model, user configuration or external server. The receipt binds
the real listener PID and process creation FILETIME; the stop marker retires it.
#>
param([Parameter(Mandatory=$true)][string]$Directory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$taskServer = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
try {
	$taskServer.Start()
	$taskProcess = [Diagnostics.Process]::GetCurrentProcess()
	$taskReceipt = [ordered]@{pid=$PID; created_filetime=$taskProcess.StartTime.ToUniversalTime().ToFileTimeUtc(); port=$taskServer.LocalEndpoint.Port}
	$taskReady = Join-Path $Directory 'ready.json'
	[IO.File]::WriteAllText(($taskReady + '.tmp'), ($taskReceipt | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
	Move-Item -LiteralPath ($taskReady + '.tmp') -Destination $taskReady
	$taskWatch = [Diagnostics.Stopwatch]::StartNew()
	while (!(Test-Path -LiteralPath (Join-Path $Directory 'stop')) -and $taskWatch.ElapsedMilliseconds -lt 10000) {
		Start-Sleep -Milliseconds 10
	}
} finally { $taskServer.Stop() }
