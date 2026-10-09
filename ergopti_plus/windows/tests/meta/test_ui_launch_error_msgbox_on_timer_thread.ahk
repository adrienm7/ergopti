; tests/meta/test_ui_launch_error_msgbox_on_timer_thread.ahk

; ==============================================================================
; MODULE: WebView2 Launch-Failure Logging Meta Test
; DESCRIPTION:
; Static source guard for finding "ui-launch-error-msgbox-on-timer-thread".
;
; KLWV_Open() embeds a Microsoft Edge WebView2 control to host the metrics
; dashboards. Its two failure paths — the controller-create catch and the
; navigate catch — originally wrote only to webview.log via FileAppend, a file
; the standard project diagnostics never read. A half-installed WebView2
; Runtime therefore failed silently: the user saw nothing happen and the only
; trace was buried in webview.log, violating rule 5.3 (never swallow without a
; LoggerError/LoggerWarn).
;
; The fix routes both catch blocks through the central logger in addition to
; the existing FileAppend: LoggerError for the controller-create failure (the
; dashboard cannot open at all) and LoggerWarn for the navigate failure (the
; window opens but stays blank).
;
; This is a meta-static test because keylogger_webview.ahk instantiates a
; WebView2/COM control and is not part of the headless run_all include graph;
; it scans source text so a regression that drops the central-logger call from
; either catch fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_ULEM_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Central-logger assertions =============
; ==================================================
; ==================================================

_ULEM_OpenLogsControllerFailure() {
	Src := _ULEM_ReadSource("modules/keylogger/keylogger_webview.ahk")
	Body := _DriverFuncBody("KLWV_Open")
	Assert(Body != "", "KLWV_Open(which, metrics_dir) declaration must exist in keylogger_webview.ahk")
	Assert(InStr(Body, "LoggerError") > 0,
		"KLWV_Open must route the WebView2 controller-create failure through LoggerError, not only FileAppend to webview.log (ui-launch-error-msgbox-on-timer-thread)")
}
Test("keylogger_webview: KLWV_Open logs controller-create failure via LoggerError (ui-launch-error-msgbox-on-timer-thread)", _ULEM_OpenLogsControllerFailure)

_ULEM_OpenLogsNavigateFailure() {
	Src := _ULEM_ReadSource("modules/keylogger/keylogger_webview.ahk")
	Body := _DriverFuncBody("KLWV_Open")
	Assert(Body != "", "KLWV_Open(which, metrics_dir) declaration must exist in keylogger_webview.ahk")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"KLWV_Open must route the WebView2 navigate failure through LoggerWarn, not only FileAppend to webview.log (ui-launch-error-msgbox-on-timer-thread)")
}
Test("keylogger_webview: KLWV_Open logs navigate failure via LoggerWarn (ui-launch-error-msgbox-on-timer-thread)", _ULEM_OpenLogsNavigateFailure)
