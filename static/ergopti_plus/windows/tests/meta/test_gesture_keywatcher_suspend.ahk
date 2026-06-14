; tests/meta/test_gesture_keywatcher_suspend.ahk

; ==============================================================================
; MODULE: Gesture Keyboard Watcher Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the clickhold-inputhook-drops-keys finding.
;
; GestureOnKeyDown is the OnKeyDown callback for the InputHook installed by
; GestureStartKeyboardWatcher while a click-hold mode is active. InputHooks in
; AHK v2 bypass Suspend — they continue to suppress and re-deliver keystrokes
; even when A_IsSuspended is true and all hotkeys are disabled.
;
; Without this guard, a user who pauses the driver while holding a click-toggle
; would have every keystroke silently consumed by the hook and re-injected at
; Level 3 — Ergopti-level — contrary to the project's "pause = tout éteint"
; invariant (pause means no driver intervention on input).
;
; The fix: add an A_IsSuspended check at the top of GestureOnKeyDown. When
; true, release the held clicks and re-send the swallowed key at level 0
; (plain OS key, no Ergopti remapping) then return immediately.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_GKWS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_GKWS_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	Out := ""
	loop parse, Rest, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ===================================================
; ===================================================
; ======= 2/ GestureOnKeyDown suspend guard =========
; ===================================================
; ===================================================

_GKWS_SuspendGuardInOnKeyDown() {
	Src := _GKWS_ReadSource("modules/gestures.ahk")
	Body := _GKWS_FuncBodyStripped(Src, "GestureOnKeyDown(ih, vk, sc) {")
	Assert(Body != "", "GestureOnKeyDown must exist in modules/gestures.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"GestureOnKeyDown must check A_IsSuspended — InputHooks bypass Suspend and would otherwise suppress/re-inject keystrokes at Level 3 while the driver is paused (clickhold-inputhook-drops-keys)")
}
Test("gestures: GestureOnKeyDown has A_IsSuspended guard (clickhold-inputhook-drops-keys)", _GKWS_SuspendGuardInOnKeyDown)

_GKWS_SuspendGuardBeforeLevel3() {
	Src := _GKWS_ReadSource("modules/gestures.ahk")
	Body := _GKWS_FuncBodyStripped(Src, "GestureOnKeyDown(ih, vk, sc) {")
	Assert(Body != "", "GestureOnKeyDown must exist in modules/gestures.ahk")
	SuspendIdx := InStr(Body, "A_IsSuspended")
	Level3Idx  := InStr(Body, "SendLevel(3)")
	Assert(SuspendIdx > 0, "GestureOnKeyDown must check A_IsSuspended")
	Assert(Level3Idx > 0, "GestureOnKeyDown must call SendLevel(3) for the non-paused path")
	Assert(SuspendIdx < Level3Idx,
		"A_IsSuspended check must precede SendLevel(3) so a paused driver never re-injects keys at Ergopti level (clickhold-inputhook-drops-keys)")
}
Test("gestures: GestureOnKeyDown A_IsSuspended guard precedes SendLevel(3) (clickhold-inputhook-drops-keys)", _GKWS_SuspendGuardBeforeLevel3)
