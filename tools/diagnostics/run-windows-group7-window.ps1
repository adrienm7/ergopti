# tools/diagnostics/run-windows-group7-window.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
Captures an explicitly selected native tooltip rectangle, DPI and GDI resources.
.DESCRIPTION
The process handle and HWND/PID are checked before and after observation. Only
the selected rectangle is captured. Occlusion, visual correctness and physical
display quality remain manual observations; no UIA qualification is claimed.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[long]$WindowHandle,
	[Parameter(Mandatory = $true)]
	[int]$OwnerProcessId,
	[switch]$CaptureScreenshot,
	[string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('ergopti-group7-window-' + [Guid]::NewGuid().ToString('N')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or ![Environment]::UserInteractive) {
	throw 'The window observation requires an interactive native Windows desktop.'
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory.' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Group7WindowObservation {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr window, out Rect rectangle);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint GetGuiResources(IntPtr process, uint kind);
    [DllImport("kernel32.dll", EntryPoint="SetLastError")] private static extern void ClearNativeError(uint error);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public static uint ReadGuiResources(IntPtr process, uint kind, out int error) {
        // Zero can be a valid count. Clear stale error state before observing it.
        ClearNativeError(0);
        uint count = GetGuiResources(process, kind);
        error = count == 0 ? Marshal.GetLastWin32Error() : 0;
        return count;
    }
}
'@

function Read-GuiResources {
	param([IntPtr]$ProcessHandle, [uint32]$Kind)
	$NativeError = 0
	$Count = [Group7WindowObservation]::ReadGuiResources($ProcessHandle, $Kind, [ref]$NativeError)
	if ($NativeError -ne 0) {
		return [ordered]@{ status='unavailable'; count=$null; native_error=$NativeError }
	}
	return [ordered]@{ status='observed'; count=$Count; native_error=0 }
}

$Target = $null
$OldDpiContext = [IntPtr]::Zero
try {
	$Target = [Diagnostics.Process]::GetProcessById($OwnerProcessId)
	$TargetHandle = $Target.Handle
	$Created = $Target.StartTime.ToUniversalTime().ToString('o')
	$OldDpiContext = [Group7WindowObservation]::SetThreadDpiAwarenessContext([IntPtr](-4))
	if ($OldDpiContext -eq [IntPtr]::Zero) { throw 'Per-monitor DPI awareness could not be established.' }
	$ActualProcessId = [uint32]0
	[void][Group7WindowObservation]::GetWindowThreadProcessId([IntPtr]$WindowHandle, [ref]$ActualProcessId)
	if ($Target.HasExited -or $ActualProcessId -ne $OwnerProcessId -or ![Group7WindowObservation]::IsWindowVisible([IntPtr]$WindowHandle)) {
		throw 'The selected HWND is not a visible window of the retained process.'
	}
	$Rectangle = [Group7WindowObservation+Rect]::new()
	if (![Group7WindowObservation]::GetWindowRect([IntPtr]$WindowHandle, [ref]$Rectangle)) { throw 'Native window geometry read failed.' }
	$Width = $Rectangle.Right - $Rectangle.Left
	$Height = $Rectangle.Bottom - $Rectangle.Top
	if ($Width -le 0 -or $Height -le 0 -or $Width -gt 8192 -or $Height -gt 8192) { throw 'Selected screenshot geometry is outside its bound.' }
	$Dpi = [Group7WindowObservation]::GetDpiForWindow([IntPtr]$WindowHandle)
	if ($Dpi -eq 0) { throw 'Native window DPI is unavailable; completed observation refused.' }
	$Receipt = [ordered]@{
		schema_version = 1
		captured_utc = [DateTime]::UtcNow.ToString('o')
		os_version = [Environment]::OSVersion.VersionString
		owner_pid = $OwnerProcessId
		owner_created_utc = $Created
		window = [string]$WindowHandle
		dpi = $Dpi
		physical_pixels = [ordered]@{ left=$Rectangle.Left; top=$Rectangle.Top; width=$Width; height=$Height }
		gdi_resources = Read-GuiResources $TargetHandle 0
		user_resources = Read-GuiResources $TargetHandle 1
		visual_acceptance = 'unreviewed'
		uia_qualified = $false
		physical_display_qualified = $false
		screenshot_requested = [bool]$CaptureScreenshot
	}
	[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
	if ($CaptureScreenshot) {
		Add-Type -AssemblyName System.Drawing
		$Image = $null
		$Canvas = $null
		try {
			$Image = [Drawing.Bitmap]::new($Width, $Height)
			$Canvas = [Drawing.Graphics]::FromImage($Image)
			$Canvas.CopyFromScreen($Rectangle.Left, $Rectangle.Top, 0, 0, $Image.Size)
			$Image.Save((Join-Path $OutputDirectory 'window.png'), [Drawing.Imaging.ImageFormat]::Png)
		} finally {
			try { if ($Canvas) { $Canvas.Dispose() } }
			finally { if ($Image) { $Image.Dispose() } }
		}
	}
	[void][Group7WindowObservation]::GetWindowThreadProcessId([IntPtr]$WindowHandle, [ref]$ActualProcessId)
	$AfterRectangle = [Group7WindowObservation+Rect]::new()
	if ($Target.HasExited -or $ActualProcessId -ne $OwnerProcessId
		-or ![Group7WindowObservation]::IsWindowVisible([IntPtr]$WindowHandle)
		-or [Group7WindowObservation]::GetDpiForWindow([IntPtr]$WindowHandle) -ne $Dpi
		-or ![Group7WindowObservation]::GetWindowRect([IntPtr]$WindowHandle, [ref]$AfterRectangle)
		-or $AfterRectangle.Left -ne $Rectangle.Left -or $AfterRectangle.Top -ne $Rectangle.Top
		-or $AfterRectangle.Right -ne $Rectangle.Right -or $AfterRectangle.Bottom -ne $Rectangle.Bottom) {
		throw 'Window identity, visibility, DPI or geometry changed during capture; do not use the screenshot as acceptance evidence.'
	}
} finally {
	try {
		if ($OldDpiContext -ne [IntPtr]::Zero
			-and [Group7WindowObservation]::SetThreadDpiAwarenessContext($OldDpiContext) -eq [IntPtr]::Zero) {
			throw 'The native thread DPI context could not be restored.'
		}
	} finally { if ($Target) { $Target.Dispose() } }
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'window.json'),
	(($Receipt | ConvertTo-Json -Depth 4).Replace("`r`n", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
Write-Host ('Unreviewed native window evidence saved in ' + $OutputDirectory)
