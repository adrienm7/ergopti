; tests/meta/test_open_downloads_catch.ahk

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

	Assert(InStr(Body, "GetKnownFolderDownloads()") > 0,
		"OpenDownloads must resolve the locale-independent Downloads known folder")
	Assert(InStr(Body, 'ComObject("Shell.Application")') = 0,
		"OpenDownloads must not enumerate Shell.Application on the keyboard hotkey thread")
	Assert(InStr(Body, "WinWait") = 0,
		"OpenDownloads must not wait for Explorer on the keyboard hotkey thread")
}
Test("shortcuts: OpenDownloads avoids synchronous Explorer COM and waits on the keyboard hotkey",
	_ODC_CheckHotkeyAvoidsExplorerCom)




 
; ============================================================
; ==============================================================
; ======= 2/ Explorer launch is contained and observable =======
; ==============================================================
; ============================================================

_ODC_CheckExplorerLaunchContained() {
	Body := _DriverFuncBody("OpenDownloads")

	Assert(InStr(Body, "Run('explorer.exe ") > 0,
		"OpenDownloads must launch Explorer with the resolved Downloads path")
	Assert(InStr(Body, "catch as Err") > 0 && InStr(Body, "LoggerError") > 0,
		"OpenDownloads must contain and log Explorer launch failures instead of escaping the hotkey")
}
Test("shortcuts: OpenDownloads contains and logs Explorer launch failures",
	_ODC_CheckExplorerLaunchContained)
