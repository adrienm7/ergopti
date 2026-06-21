; tests/meta/test_oneshotshift_suspend_guard.ahk

; ==============================================================================
; MODULE: OneShotShift Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the "oneshotshift-suspend-guard" finding (T-W03).
;
; Two related invariants are verified:
;
; 1. OneShotShift() (one_shot_shift.ahk) must check A_IsSuspended at entry.
;    OneShotShift opens an InputHook that intercepts the next keystroke. If the
;    driver is suspended when the function fires, the InputHook would swallow a
;    real keystroke belonging to another application and apply an erroneous
;    capitalisation — a data-corruption class bug. The guard returns immediately
;    when A_IsSuspended is true, so the InputHook is never started.
;
; 2. Ergopti_OnSuspendEnter() (ErgoptiPlus.ahk) must reset OneShotShiftEnabled
;    to False. A shift may have been armed (OneShotShiftEnabled := True) in the
;    same event-loop tick that triggers the suspend transition. Without the
;    explicit reset, the enabled flag lingers across the pause and applies an
;    unwanted capitalisation to the first keystroke after resume.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Resolves a windows/-relative source path from the tests/ runner directory.
_OSSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ===================================================
; ===================================================
; ======= 2/ OneShotShift suspend-entry guard =======
; ===================================================
; ===================================================

_OSSG_OneShotShiftHasSuspendGuard() {
	Src := _OSSG_ReadSource("modules/tap_holds/one_shot_shift.ahk")
	Body := _DriverFuncBody("OneShotShift")
	Assert(Body != "", "OneShotShift must exist in modules/tap_holds/one_shot_shift.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"OneShotShift must check A_IsSuspended — starting an InputHook while suspended would intercept keystrokes belonging to other applications and apply an erroneous capitalisation")
}
Test("one_shot_shift: OneShotShift() has A_IsSuspended guard", _OSSG_OneShotShiftHasSuspendGuard)





; ==================================================
; ==================================================
; ======= 3/ SuspendEnter resets shift state =======
; ==================================================
; ==================================================

_OSSG_SuspendEnterResetsOneShotShift() {
	Src := _DriverSourceConcat()
	; Isolate the Ergopti_OnSuspendEnter body by slicing from its declaration to
	; the start of the next top-level function so inner braces do not confuse the
	; simple text scan.
	FuncPos := InStr(Src, "Ergopti_OnSuspendEnter() {")
	Assert(FuncPos > 0, "Ergopti_OnSuspendEnter must exist in ErgoptiPlus.ahk")
	Tail := SubStr(Src, FuncPos)
	NextFunc := InStr(Tail, "`nErgopti_On")
	Segment := (NextFunc > 0) ? SubStr(Tail, 1, NextFunc) : Tail
	Assert(InStr(Segment, "OneShotShiftEnabled") > 0,
		"Ergopti_OnSuspendEnter must reference OneShotShiftEnabled — a shift armed just before suspension must be cleared so it is not applied to the first keystroke after resume")
	Assert(InStr(Segment, "False") > 0,
		"Ergopti_OnSuspendEnter must set OneShotShiftEnabled to False — leaving it True across a suspend/resume boundary causes an unwanted capitalisation")
	Assert(InStr(Segment, "OneShotShiftEnabled := False") > 0,
		"Ergopti_OnSuspendEnter must contain an explicit `OneShotShiftEnabled := False` assignment to clear any in-flight shift state on pause")
}
Test("ErgoptiPlus: Ergopti_OnSuspendEnter resets OneShotShiftEnabled", _OSSG_SuspendEnterResetsOneShotShift)
