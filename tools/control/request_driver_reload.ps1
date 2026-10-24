# tools/control/request_driver_reload.ps1
<#
.SYNOPSIS
Asks the running Windows driver to reload, and reports requested, refused and
completed separately.
.DESCRIPTION
Reads the session the driver published in its private control folder, writes
one request carrying the session token, then rings the driver's registered
window message (the Diagnostics control endpoint). The driver hands the request
to its own reload owner, which keeps the pause and the configuration hand-off.
This script never starts a driver, never ends one and never retries: a reload
that stays "requested" past the timeout has an unknown outcome. The declaration
is static/ergopti_plus/_shared/modules/control/driver_control.json.

Exit codes: 0 completed, 1 refused, 2 still requested at the timeout, 3 no
reachable driver.
#>
[CmdletBinding()]
param(
	[ValidateRange(1000, 600000)]
	[int]$TimeoutMs = 60000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw 'The driver control requires the Windows x64 host.' }

$shared = Join-Path $PSScriptRoot '..\..\static\ergopti_plus\_shared'
$spec = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $shared 'modules\control\driver_control.json') | ConvertFrom-Json
$appDirs = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $shared 'modules\paths\app_dirs.toml')
if ($appDirs -notmatch '(?m)^folder_name = "([^"]+)"') { throw 'The application folder name is not declared.' }
$appFolder = $Matches[1]
$base = [Environment]::GetEnvironmentVariable($spec.folders.windows.base)
if (-not $base) { throw "$($spec.folders.windows.base) is not set." }
$folder = $base.TrimEnd('\', '/')
foreach ($segment in $spec.folders.windows.segments) {
	$folder = Join-Path $folder ($(if ($segment -eq '{app}') { $appFolder } else { $segment }))
}

function Write-Outcome($outcome) {
	$outcome | ConvertTo-Json -Compress
}

$sessionPath = Join-Path $folder $spec.files.session
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
	Write-Outcome ([ordered]@{ state = 'unreachable'; detail = 'no driver session is published' })
	exit 3
}
$session = Get-Content -Raw -Encoding UTF8 -LiteralPath $sessionPath | ConvertFrom-Json
if ($session.schema -ne $spec.schema -or $session.driver -ne 'windows' -or $session.token -notmatch '^[0-9a-f]{64}$') {
	throw 'The driver session is malformed.'
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ErgoptiDriverControlV1 {
    public delegate bool EnumProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassNameW(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message,
        UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);

    public static IntPtr[] MainWindows(uint process) {
        var windows = new List<IntPtr>();
        bool enumerated = EnumWindows((window, parameter) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != process) return true;
            var name = new StringBuilder(256);
            if (GetClassNameW(window, name, name.Capacity) > 0 && name.ToString() == "AutoHotkey")
                windows.Add(window);
            return true;
        }, IntPtr.Zero);
        if (!enumerated) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return windows.ToArray();
    }
}
'@

$driverPid = [int]$session.pid
$driver = $null
try { $driver = [Diagnostics.Process]::GetProcessById($driverPid) } catch { $driver = $null }
if ($null -eq $driver) {
	Write-Outcome ([ordered]@{ state = 'unreachable'; detail = 'the published driver process is gone'; driver_pid = $driverPid })
	exit 3
}
try {
	$creation = $driver.StartTime.ToUniversalTime().ToFileTimeUtc()
	$windows = @([ErgoptiDriverControlV1]::MainWindows($driverPid))
	if ($windows.Count -ne 1) { throw 'The driver must own exactly one AutoHotkey main window.' }
	$message = [ErgoptiDriverControlV1]::RegisterWindowMessageW($spec.windows_message)
	if (-not $message) { throw 'The driver control message could not be registered.' }

	$bytes = New-Object byte[] 8
	[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
	$requestId = 'ps-' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
	$requestPath = Join-Path $folder $spec.files.request
	$stage = "$requestPath.tmp-$PID"
	$request = '{"schema":' + $spec.schema + ',"token":"' + $session.token + '","request_id":"' + $requestId + '"}'
	[IO.File]::WriteAllText($stage, $request, [Text.UTF8Encoding]::new($false))
	if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
	Move-Item -LiteralPath $stage -Destination $requestPath

	[UIntPtr]$ack = [UIntPtr]::Zero
	# SMTO_BLOCK | SMTO_ABORTIFHUNG. An unknown result is never retried here.
	$sent = [ErgoptiDriverControlV1]::SendMessageTimeoutW($windows[0], $message,
		[UIntPtr]::new([UInt64]$driverPid), [IntPtr]::new($creation), 3, 5000, [ref]$ack)
	if ($sent -eq [IntPtr]::Zero -or $ack.ToUInt64() -ne 1) {
		if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
		Write-Outcome ([ordered]@{ request_id = $requestId; state = 'refused'; reason = 'endpoint'; driver_pid = $driverPid })
		exit 1
	}
} finally { $driver.Dispose() }

$resultPath = Join-Path $folder $spec.files.result
$deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
$last = $null
while ([DateTime]::UtcNow -lt $deadline) {
	if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
		$result = $null
		try { $result = Get-Content -Raw -Encoding UTF8 -LiteralPath $resultPath | ConvertFrom-Json } catch { $result = $null }
		if ($null -ne $result -and $result.request_id -eq $requestId) {
			$last = $result
			if ($result.state -eq 'completed') { Write-Outcome $result; exit 0 }
			if ($result.state -eq 'refused') { Write-Outcome $result; exit 1 }
			if ($result.state -eq 'timeout') { Write-Outcome $result; exit 2 }
			# A restart that cannot name its successor leaves a pending record with a
			# deadline: past it, the answer is a timeout and never a completion.
			if ($result.state -eq 'requested' -and $null -eq $result.successor_pid -and $null -ne $result.deadline -and
				[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -gt [int64]$result.deadline) {
				Write-Outcome ([ordered]@{ request_id = $requestId; state = 'timeout'; reason = $spec.timeout_reason; driver_pid = $driverPid })
				exit 2
			}
		}
	}
	Start-Sleep -Milliseconds 200
}
if ($null -ne $last) { Write-Outcome $last } else {
	Write-Outcome ([ordered]@{ request_id = $requestId; state = 'unknown'; driver_pid = $driverPid })
}
exit 2
