# tests/fixtures/ollama_live_identity_listener.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
Owns a bounded loopback listener for native process-identity regression tests.
.DESCRIPTION
Uses no Ollama, model, user configuration or external server. The receipt binds
the real listener PID and process creation FILETIME; the stop marker retires it.
Only .NET calls are used: a cmdlet such as New-Object, ConvertTo-Json or Move-Item makes a
cold Windows PowerShell autoload its module, which took more than 5 s on a
loaded hosted runner before the receipt was published.
#>
param([Parameter(Mandatory=$true)][string]$Directory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$taskServer = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
try {
	$taskServer.Start()
	$taskProcess = [Diagnostics.Process]::GetCurrentProcess()
	$taskCreated = $taskProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
	$taskPort = $taskServer.LocalEndpoint.Port
	$taskReceipt = '{"pid":' + $PID + ',"created_filetime":' + $taskCreated + ',"port":' + $taskPort + '}'
	$taskReady = [IO.Path]::Combine($Directory, 'ready.json')
	$taskStop = [IO.Path]::Combine($Directory, 'stop')
	[IO.File]::WriteAllText(($taskReady + '.tmp'), $taskReceipt, [Text.UTF8Encoding]::new($false))
	[IO.File]::Move(($taskReady + '.tmp'), $taskReady)
	$taskWatch = [Diagnostics.Stopwatch]::StartNew()
	while (![IO.File]::Exists($taskStop) -and $taskWatch.ElapsedMilliseconds -lt 10000) {
		[Threading.Thread]::Sleep(10)
	}
} finally { $taskServer.Stop() }
