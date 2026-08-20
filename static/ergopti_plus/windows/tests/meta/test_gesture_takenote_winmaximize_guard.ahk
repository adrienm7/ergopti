; tests/meta/test_gesture_takenote_winmaximize_guard.ahk

; ==============================================================================
; MODULE: Shared Take-Note Focus/Maximize Guard
; DESCRIPTION:
; A target that exists is not necessarily focused. The shared async transaction
; must observe both conditions before maximize/final input, and every partial
; title-mode mutation must restore the caller's thread state.
; ==============================================================================

#Requires AutoHotkey v2.0+

_GTNWMG_CheckWinMaximizeGuard() {
	Body := _DriverFuncBody("_TakeNotePoll")
	ExistsPos := InStr(Body, 'Ops.WindowExists(Job["pattern"])')
	ActivatePos := InStr(Body, 'Ops.Activate(Job["pattern"])', , ExistsPos)
	ActivePos := InStr(Body, 'Ops.IsActive(Job["pattern"])', , ActivatePos)
	MaximizePos := InStr(Body, 'Ops.Maximize(Job["pattern"])', , ActivePos)
	Assert(ExistsPos > 0 and ActivatePos > ExistsPos and ActivePos > ActivatePos
		and MaximizePos > ActivePos,
		"the shared job must observe existence and focus before maximizing the explicit target")
}
Test("TakeNote: shared job observes existence and focus before explicit maximize",
	_GTNWMG_CheckWinMaximizeGuard)

_GTNWMG_CheckTimeoutIsLogged() {
	Body := _DriverFuncBody("_TakeNoteExpire")
	Assert(InStr(Body, "WarnTimeout") > 0,
		"the shared job must report a bounded focus/launch timeout instead of silently vanishing")
}
Test("TakeNote: shared job reports a bounded focus/launch timeout",
	_GTNWMG_CheckTimeoutIsLogged)

_GTNWMG_CheckTitleMatchModeRestored() {
	Src := _DriverSourceNoComments()
	StartPos := InStr(Src, "class _TakeNoteNative")
	EndPos := InStr(Src, "_TakeNoteQueueFromFeatures(", , StartPos)
	Assert(StartPos > 0 and EndPos > StartPos,
		"the shared native note boundary must remain discoverable")
	NativeBody := SubStr(Src, StartPos, EndPos - StartPos)
	RestoreCount := 0
	SearchPos := 1
	while (Found := InStr(NativeBody, "SetTitleMatchMode(PreviousMode)", , SearchPos)) {
		RestoreCount += 1
		SearchPos := Found + 1
	}
	Assert(RestoreCount >= 4,
		"exists, activate, active-observation, and maximize must each restore title-match state")
}
Test("TakeNote: every native window probe restores A_TitleMatchMode",
	_GTNWMG_CheckTitleMatchModeRestored)
