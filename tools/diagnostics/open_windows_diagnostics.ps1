# tools/diagnostics/open_windows_diagnostics.ps1
<#
.SYNOPSIS
Requests Diagnostics from one existing, hash-verified Windows driver.
.DESCRIPTION
Uses the driver's registered Win32 control message, including its hidden main
window. Never starts a second driver, simulates input, collects data, or downloads
anything. A queued acknowledgement does not attest that the window opened.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[ValidateRange(1, 2147483647)]
	[int]$TargetProcessId,

	[Parameter(Mandatory = $true)]
	[ValidatePattern('^[0-9A-Fa-f]{64}$')]
	[string]$ExpectedExecutableSha256,

	[ValidateRange(1, 10000)]
	[int]$TimeoutMs = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw 'Diagnostics control requires the Windows x64 host.' }
# A non-PowerShell parent may inherit another host's module search path.
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1') -ErrorAction Stop

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ErgoptiDiagnosticsControlV1 {
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

$taskProcess = [Diagnostics.Process]::GetProcessById($TargetProcessId)
try {
	$taskHandle = $taskProcess.Handle
	$taskCreation = $taskProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
	$taskExecutable = $taskProcess.MainModule.FileName
	$taskHash = (Get-FileHash -LiteralPath $taskExecutable -Algorithm SHA256).Hash
	if ($taskHash -ine $ExpectedExecutableSha256) { throw 'The target executable hash does not match.' }
	$taskWindows = @([ErgoptiDiagnosticsControlV1]::MainWindows($TargetProcessId))
	if ($taskWindows.Count -ne 1) { throw 'The target must own exactly one AutoHotkey main window.' }
	$taskWindow = $taskWindows[0]
	[uint32]$taskWindowOwner = 0
	if (-not [ErgoptiDiagnosticsControlV1]::GetWindowThreadProcessId($taskWindow, [ref]$taskWindowOwner) -or $taskWindowOwner -ne $TargetProcessId) {
		throw 'The main window no longer belongs to the retained target process.'
	}
	$taskMessage = [ErgoptiDiagnosticsControlV1]::RegisterWindowMessageW('Ergopti.Diagnostics.Open.v1')
	if (-not $taskMessage) { throw 'The diagnostics control message could not be registered.' }
	if ($taskProcess.HasExited) { throw 'The retained target process exited before the request.' }
	$taskCheck = [Diagnostics.Process]::GetProcessById($TargetProcessId)
	try {
		if ($taskCheck.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $taskCreation) { throw 'The target PID was reused.' }
	} finally { $taskCheck.Dispose() }
	[UIntPtr]$taskAcknowledgement = [UIntPtr]::Zero
	# SMTO_BLOCK | SMTO_ABORTIFHUNG. An unknown result is never retried here.
	$taskSent = [ErgoptiDiagnosticsControlV1]::SendMessageTimeoutW($taskWindow, $taskMessage,
		[UIntPtr]::new([UInt64]$TargetProcessId), [IntPtr]::new($taskCreation), 3, $TimeoutMs, [ref]$taskAcknowledgement)
	if ($taskSent -eq [IntPtr]::Zero) { throw 'Diagnostics request outcome is unknown; inspect the target before retrying.' }
	if ($taskAcknowledgement.ToUInt64() -ne 1) { throw 'The target did not acknowledge the diagnostics request.' }
	[ordered]@{
		process_id = $TargetProcessId
		created_filetime = $taskCreation
		executable_sha256 = $taskHash.ToLowerInvariant()
		request_accepted = $true
		window_opened = 'UNVERIFIED'
		new_process_started = $false
		input_injected = $false
	} | ConvertTo-Json -Compress
} finally { $taskProcess.Dispose() }
