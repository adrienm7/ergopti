; tests/meta/modules/gestures/test_open_downloads_catch.ahk

; ==============================================================================
; MODULE: OpenDownloads Bare-Try Meta Test (Pattern 3)
; DESCRIPTION:
; Regression guard for the documented Explorer-COM hotkey stall. OpenDownloads
; used to enumerate Shell.Application windows synchronously in Win+D. That
; COM boundary could block the keyboard hook and its old tests only checked
; catches around the scan. The hotkey now resolves the known Downloads folder
; and lets Explorer reuse/open it asynchronously, while failures are logged.
;
; SCOPE: source introspection of modules/shortcuts/win.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================================
; ============================================================
; ======= 1/ Hotkey has no Explorer COM boundary ==============
; ============================================================
; ============================================================

_ODC_CheckHotkeyAvoidsExplorerCom() {
	Body := _DriverFuncBody("OpenDownloads")
	Assert(Body != "", "OpenDownloads must exist in modules/shortcuts/win.ahk")

	LaunchBody := _DriverFuncBody("_OpenDownloadsWith")
	Assert(LaunchBody != "", "the resolved-folder launcher must exist")
	Assert(InStr(Body, "_OpenDownloadsWith(GetKnownFolderDownloads, Run)") > 0
		&& InStr(LaunchBody, "DownloadsPath := ResolveFn.Call()") > 0,
		"the hotkey must delegate to the real known-folder resolver and native launcher")
	Combined := Body . LaunchBody
	Assert(InStr(Combined, 'ComObject("Shell.Application")') = 0,
		"OpenDownloads must not enumerate Shell.Application on the keyboard hotkey thread")
	Assert(InStr(Combined, "WinWait") = 0,
		"OpenDownloads must not wait for Explorer on the keyboard hotkey thread")
}
Test("shortcuts: OpenDownloads avoids synchronous Explorer COM and waits on the keyboard hotkey (open-downloads-delegation-guard)",
	_ODC_CheckHotkeyAvoidsExplorerCom)




 
; ==============================================================
; ==============================================================
; ======= 2/ Explorer launch is contained and observable =======
; ==============================================================
; ==============================================================

_ODC_CheckExplorerLaunchContained() {
	Body := _DriverFuncBody("OpenDownloads")
	LaunchBody := _DriverFuncBody("_OpenDownloadsWith")
	Assert(Body != "" && LaunchBody != "", "the hotkey and resolved-folder launcher must exist")
	Assert(InStr(LaunchBody, "LaunchFn.Call('explorer.exe ") > 0
		&& RegExMatch(LaunchBody, "LaunchFn\.Call\([^\r\n]*DownloadsPath"),
		"the native launcher must pass the resolved Downloads path to Explorer")
	TryPos := InStr(Body, "try {")
	DelegatePos := InStr(Body, "_OpenDownloadsWith(GetKnownFolderDownloads, Run)")
	CatchPos := InStr(Body, "catch as Err")
	LogPos := InStr(Body, "LoggerError", false, Max(1, CatchPos))
	Assert(TryPos > 0 && DelegatePos > TryPos && CatchPos > DelegatePos && LogPos > CatchPos,
		"the actual resolver and launcher must remain inside the logged hotkey failure boundary")
}
Test("shortcuts: OpenDownloads contains and logs Explorer launch failures (open-downloads-delegation-guard)",
	_ODC_CheckExplorerLaunchContained)
