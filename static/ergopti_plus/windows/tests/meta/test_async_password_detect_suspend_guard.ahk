; tests/meta/test_async_password_detect_suspend_guard.ahk

; ==============================================================================
; MODULE: KL_AsyncPasswordDetect Suspend Guard Meta-Test
; DESCRIPTION:
; Structural regression for the suspend guard added to KL_AsyncPasswordDetect
; in keylogger.ahk.
;
; Before the fix, KL_AsyncPasswordDetect fired unconditionally from its
; SetTimer(-1) one-shot even while A_IsSuspended was true. This means UIA and
; Win32 round-trips ran during the intentional pause window, violating the
; invariant that "pause = tout éteint" enforced at the HookDispatcher level.
;
; The fix adds an early-return guard at the top of KL_AsyncPasswordDetect:
;   if A_IsSuspended
;       return
;
; This test inspects keylogger.ahk source and asserts:
;   1. A_IsSuspended is checked inside KL_AsyncPasswordDetect.
;   2. The check precedes the first substantive call (KL_DetectPasswordFor).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================================================
; ==============================================================
; ======= 1/ Source-inspection helpers =========================
; ==============================================================
; ==============================================================

_APDSG_ReadSource() {
	return FileRead(A_ScriptDir . "\..\modules\keylogger\keylogger.ahk", "UTF-8")
}


_APDSG_FindFunctionBlock(src) {
	mark := "KL_AsyncPasswordDetect(hwnd) {"
	pos := InStr(src, mark)
	if (!pos)
		return ""
	; Return the next 500 chars — covers the guard and first real call.
	return SubStr(src, pos, 500)
}




; ==============================================================
; ==============================================================
; ======= 2/ Assertions ========================================
; ==============================================================
; ==============================================================

_APDSG_SuspendCheckPresent() {
	block := _APDSG_FindFunctionBlock(_APDSG_ReadSource())
	Assert(InStr(block, "A_IsSuspended") > 0,
		"keylogger.ahk: KL_AsyncPasswordDetect must check A_IsSuspended before running UIA/Win32 detection")
}
Test("KL_AsyncPasswordDetect: A_IsSuspended guard present (async-password-detect-suspend)", _APDSG_SuspendCheckPresent)


_APDSG_SuspendCheckBeforeDetect() {
	block := _APDSG_FindFunctionBlock(_APDSG_ReadSource())
	posGuard  := InStr(block, "A_IsSuspended")
	posDetect := InStr(block, "KL_DetectPasswordFor")
	Assert(posGuard > 0 and posDetect > 0,
		"keylogger.ahk: both A_IsSuspended guard and KL_DetectPasswordFor call must be present")
	Assert(posGuard < posDetect,
		"keylogger.ahk: A_IsSuspended guard must precede KL_DetectPasswordFor in KL_AsyncPasswordDetect")
}
Test("KL_AsyncPasswordDetect: suspend guard precedes KL_DetectPasswordFor (async-password-detect-suspend)", _APDSG_SuspendCheckBeforeDetect)
