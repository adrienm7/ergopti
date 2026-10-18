; tests/meta/adapters/uia/test_uia_error_logged.ahk

; ==============================================================================
; MODULE: UIA Error-Logging Meta Test
; DESCRIPTION:
; Static source guard for finding "uia-error-swallowed-silently".
;
; The background UIA selection poll wraps its COM round-trip in a try block. The
; original code used a bare catch-less `catch { ; COM failure }` that discarded
; the exception and logged nothing - violating project rule 5.3 (no silent
; failures) and leaving a chronically failing automation provider undetectable
; from the logs.
;
; The fix converts it to `catch as e { try LoggerWarn(...) }`. This is a
; meta-static test because layout.ahk registers top-level hotkeys and cannot be
; #Included by the headless runner; it scans source text so a regression that
; re-introduces the silent catch fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_UEL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Logged-catch assertions ===============
; ==================================================
; ==================================================

_UEL_AssertPollTickLogsFailure() {
	Body := _DriverFuncBody("_UIA_OnSelectionWorkerTerminal")
	Assert(Body != "", "_UIA_OnSelectionWorkerTerminal() declaration must exist in layout.ahk")
	Assert(InStr(Body, 'Status = "failed"') > 0,
		"the detached UIA worker's failed terminal must be handled explicitly")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"the worker terminal must log UIA/COM failure via LoggerWarn instead of failing silently (uia-error-swallowed-silently)")
}
Test("layout: detached UIA failures reach the resident logger (uia-error-swallowed-silently)", _UEL_AssertPollTickLogsFailure)

; A worker past its deadline is the designed backoff, not a fault: as a WARNING
; it was 125 errors-sink lines over five days that named no application.
_UEL_AssertTimeoutIsInfoWithApplication() {
	Body := _DriverFuncBody("_UIA_OnSelectionWorkerTerminal")
	Assert(Body != "", "_UIA_OnSelectionWorkerTerminal() declaration must exist in layout.ahk")
	TimeoutPos := InStr(Body, 'if (LogKind = "timeout")')
	FailedPos := InStr(Body, 'else if (LogKind = "failed")', , TimeoutPos)
	Assert(TimeoutPos > 0 && FailedPos > TimeoutPos, "the timeout and failure log branches must stay distinct")
	Branch := SubStr(Body, TimeoutPos, FailedPos - TimeoutPos)
	Assert(InStr(Branch, "LoggerInfo(") > 0 && InStr(Branch, "LoggerWarn(") == 0,
		"a worker timeout is the designed backoff and logs at INFO (uia-timeout-info)")
	Assert(InStr(Branch, 'Context["ProcName"]') > 0,
		"the timeout line must name the application whose provider was backed off (uia-timeout-info)")
}
Test("layout: a UIA worker timeout is INFO and names the application (uia-timeout-info)",
	_UEL_AssertTimeoutIsInfoWithApplication)
