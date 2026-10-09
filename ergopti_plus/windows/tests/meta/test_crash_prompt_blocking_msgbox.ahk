; tests/meta/test_crash_prompt_blocking_msgbox.ahk

; ==============================================================================
; MODULE: CrashReport_PromptUser Blocking MsgBox Meta Test
; DESCRIPTION:
; Regression guard for HIGH-02: CrashReport_PromptUser blocked the keyboard.
;
; CrashReport_PromptUser ran inside ErgoptiGlobalErrorHandler, on the input
; thread. It surfaced the saved-report path (and the save-failure message) with
; a modal MsgBox. A modal MsgBox spins its own message loop and blocks the
; calling thread until the user dismisses it, starving the low-level keyboard
; hook for the entire duration — the keyboard appears frozen right after a crash.
;
; The fix replaces both MsgBox calls with non-blocking NotifierSend toasts, so
; surfacing the crash path never stalls the input thread. This test asserts the
; function body contains no MsgBox( call and does use NotifierSend(, so a
; regression that reintroduces a modal dialog fails CI.
;
; SCOPE: source introspection of modules/diagnostics/crash_reporter.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_CPMB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_CPMB_NoBlockingMsgBox() {
	Src := _CPMB_ReadSource("modules/diagnostics/crash_reporter.ahk")
	Body := _DriverFuncBody("CrashReport_PromptUser")
	Assert(Body != "", "CrashReport_PromptUser(Report) must exist in modules/diagnostics/crash_reporter.ahk")
	Assert(InStr(Body, "MsgBox(") = 0,
		"CrashReport_PromptUser must NOT call a modal MsgBox — it runs on the input thread and starves the keyboard hook (HIGH-02)")
	Assert(InStr(Body, "NotifierSend(") > 0,
		"CrashReport_PromptUser must surface the crash path via the non-blocking NotifierSend toast (HIGH-02)")
}
Test("meta crash-prompt-blocking: CrashReport_PromptUser uses NotifierSend, not modal MsgBox", _CPMB_NoBlockingMsgBox)
