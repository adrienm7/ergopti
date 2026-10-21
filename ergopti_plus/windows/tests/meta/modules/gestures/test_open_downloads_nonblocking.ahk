; tests/meta/modules/gestures/test_open_downloads_nonblocking.ahk

; ==============================================================================
; MODULE: Open Downloads Hotkey Non-Blocking Test
; DESCRIPTION:
; Win+D is a keyboard hotkey. Explorer COM enumeration and WinWait can block the
; sole AHK thread for seconds, so this action must directly launch the known
; folder and contain a failed shell launch.
; ==============================================================================

#Requires AutoHotkey v2.0

_ODNB_KeyboardPathHasNoExplorerWait() {
	Body := _DriverFuncBody("OpenDownloads")
	Assert(Body != "", "OpenDownloads must exist in modules/shortcuts/win.ahk")
	LaunchBody := _DriverFuncBody("_OpenDownloadsWith")
	Assert(LaunchBody != "", "the resolved-folder launcher must exist")
	Assert(InStr(Body, "_OpenDownloadsWith(GetKnownFolderDownloads, Run)") > 0,
		"the hotkey must use the real known-folder resolver and native shell launcher")
	Combined := Body . LaunchBody
	Assert(!InStr(Combined, 'ComObject("Shell.Application")'),
		"OpenDownloads must not enumerate Shell.Application COM on the keyboard hotkey thread")
	Assert(!InStr(Combined, "WinWait("),
		"OpenDownloads must not synchronously wait for Explorer from the keyboard hotkey thread")
	Assert(InStr(LaunchBody, "DownloadsPath := ResolveFn.Call()") > 0
		and InStr(LaunchBody, "LaunchFn.Call('explorer.exe") > 0,
		"the hotkey's launcher must resolve Downloads and open that exact folder through Explorer")
	CatchPos := InStr(Body, "} catch as Err")
	Assert(CatchPos > 0 and InStr(SubStr(Body, CatchPos, 300), "LoggerError") > 0,
		"OpenDownloads must contain shell-launch failures with LoggerError instead of throwing from the hotkey")
}
Test("shortcuts: Win+D has no synchronous Explorer/COM boundary (open-downloads-hotpath-nonblocking)",
	_ODNB_KeyboardPathHasNoExplorerWait)
