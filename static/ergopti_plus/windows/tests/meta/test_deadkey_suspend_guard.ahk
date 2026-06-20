; tests/meta/test_deadkey_suspend_guard.ahk

; ==============================================================================
; MODULE: DeadKey Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for finding
; "deadkey-inputhook-no-timeout-no-suspend-guard".
;
; AHK Suspend disarms hotkeys/hotstrings but does NOT stop a live InputHook, so
; the dead-key state machine bypasses native pause. Without an A_IsSuspended
; guard at the top of DeadKey(), a dead-key keypress slipping through while the
; driver is paused would still arm the InputHook and capture/remap the user's
; next physical key - violating the "pause = tout eteint" invariant.
;
; The fix adds `if A_IsSuspended return` before InDeadKeySequence is set. This
; is a meta-static test because layout.ahk registers top-level hotkeys and
; cannot be #Included by the headless runner; it scans source text so a
; regression that removes the guard fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_DKSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_DKSG_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}


; ==================================================
; ==================================================
; ======= 2/ Suspend-guard assertion ===============
; ==================================================
; ==================================================

_DKSG_AssertDeadKeyHasSuspendGuard() {
	Src := _DKSG_ReadSource("modules/layout.ahk")
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey(Mapping) declaration must exist in layout.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"DeadKey must check A_IsSuspended and no-op while paused - a live InputHook bypasses native Suspend (deadkey-inputhook-no-timeout-no-suspend-guard)")
}
Test("layout: DeadKey has an A_IsSuspended pause guard (deadkey-inputhook-no-timeout-no-suspend-guard)", _DKSG_AssertDeadKeyHasSuspendGuard)
