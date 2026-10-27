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

# Keep the original JSON root kind before PowerShell unwraps single-item arrays.
function Read-DriverControlObject([string]$Path, [string]$Kind) {
	$text = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
	if ($null -eq $text -or -not $text.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) {
		throw "The driver $Kind is malformed."
	}
	try { $record = ConvertFrom-Json -InputObject $text }
	catch { throw [IO.InvalidDataException]::new("The driver $Kind is malformed.", $_.Exception) }
	if ($record -isnot [pscustomobject]) { throw "The driver $Kind is malformed." }
	return $record
}

function Test-DriverControlMembers($Record, [string[]]$Required) {
	$names = @($Record.PSObject.Properties | ForEach-Object { $_.Name })
	foreach ($name in $Required) {
		if ($names -cnotcontains $name) { return $false }
	}
	return $true
}

# Preserve integral JSON floating spellings without coercing strings or Booleans.
function Test-DriverControlInteger($Value) {
	if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) {
		return $false
	}
	try { $integer = [long]$Value } catch { return $false }
	# The parsed value stays on the left: integer-first equality would round it.
	return $Value -eq $integer
}

function Assert-DriverControlSession($Session, $Spec) {
	if (-not (Test-DriverControlMembers $Session @('schema', 'driver', 'pid', 'token'))) {
		throw 'The driver session is malformed.'
	}
	if (-not (Test-DriverControlInteger $Session.schema) -or $Session.schema -ne $Spec.schema -or
		$Session.driver -isnot [string] -or $Session.driver -cne 'windows' -or
		$Session.token -isnot [string] -or $Session.token -cnotmatch ('^[0-9a-f]{' + $Spec.token_hex_length + '}\z') -or
		-not (Test-DriverControlInteger $Session.pid) -or $Session.pid -le 0 -or $Session.pid -gt [int]::MaxValue) {
		throw 'The driver session is malformed.'
	}
}

function Assert-DriverControlResult($Result, $Spec) {
	$malformed = 'The driver result is malformed.'
	if (-not (Test-DriverControlMembers $Result @('schema', 'request_id', 'state', 'driver_pid'))) {
		throw $malformed
	}
	$allowed = @('schema', 'request_id', 'state', 'driver_pid', 'successor_pid', 'reason', 'deadline')
	foreach ($property in $Result.PSObject.Properties) {
		if ($allowed -cnotcontains $property.Name) { throw $malformed }
	}
	if (-not (Test-DriverControlInteger $Result.schema) -or $Result.schema -ne $Spec.schema -or
		$Result.request_id -isnot [string] -or $Result.state -isnot [string] -or $Spec.states -cnotcontains $Result.state -or
		-not (Test-DriverControlInteger $Result.driver_pid) -or $Result.driver_pid -le 0) {
		throw $malformed
	}
	$idMatch = [regex]::Match($Result.request_id, $Spec.request_id_pattern)
	if (-not $idMatch.Success -or $idMatch.Index -ne 0 -or $idMatch.Length -ne $Result.request_id.Length) {
		throw $malformed
	}
	$hasSuccessor = Test-DriverControlMembers $Result @('successor_pid')
	$hasDeadline = Test-DriverControlMembers $Result @('deadline')
	$hasReason = Test-DriverControlMembers $Result @('reason')
	if ($hasSuccessor -and $null -ne $Result.successor_pid -and
		(-not (Test-DriverControlInteger $Result.successor_pid) -or $Result.successor_pid -le 0)) {
		throw $malformed
	}
	if ($hasDeadline -and (-not (Test-DriverControlInteger $Result.deadline) -or $Result.deadline -le 0)) {
		throw $malformed
	}
	if ($hasReason -and ($Result.reason -isnot [string] -or $Spec.reasons -cnotcontains $Result.reason)) {
		throw $malformed
	}
	switch -CaseSensitive ($Result.state) {
		'requested' {
			if (-not $hasSuccessor -or $hasReason) { throw $malformed }
			if ($null -eq $Result.successor_pid) {
				if (-not $hasDeadline) { throw $malformed }
			} elseif ($hasDeadline) { throw $malformed }
		}
		'claimed' {
			if (-not $hasSuccessor -or $null -eq $Result.successor_pid -or -not $hasDeadline -or $hasReason) { throw $malformed }
		}
		'completed' {
			if (-not $hasSuccessor -or $null -eq $Result.successor_pid -or $hasDeadline -or $hasReason) { throw $malformed }
		}
		'refused' {
			if (-not $hasReason -or $Result.reason -ceq $Spec.timeout_reason -or $hasSuccessor -or $hasDeadline) { throw $malformed }
		}
		'timeout' {
			if (-not $hasReason -or $Result.reason -cne $Spec.timeout_reason -or $hasSuccessor -or $hasDeadline) { throw $malformed }
		}
		default { throw $malformed }
	}
}

$sessionPath = Join-Path $folder $spec.files.session
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
	Write-Outcome ([ordered]@{ state = 'unreachable'; detail = 'no driver session is published' })
	exit 3
}
$session = Read-DriverControlObject $sessionPath 'session'
Assert-DriverControlSession $session $spec

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
		$result = Read-DriverControlObject $resultPath 'result'
		Assert-DriverControlResult $result $spec
		if ($result.request_id -ceq $requestId) {
			$last = $result
			if ($result.state -ceq 'completed') { Write-Outcome $result; exit 0 }
			if ($result.state -ceq 'refused') { Write-Outcome $result; exit 1 }
			if ($result.state -ceq 'timeout') { Write-Outcome $result; exit 2 }
			# A restart that cannot name its successor leaves a pending record with a
			# deadline: past it, the answer is a timeout and never a completion.
			if ($result.state -ceq 'requested' -and $null -eq $result.successor_pid -and $null -ne $result.deadline -and
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
