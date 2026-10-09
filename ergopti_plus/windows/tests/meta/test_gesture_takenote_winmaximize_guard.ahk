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
	FindPos := InStr(Body, 'WindowHwnd := Ops.FindWindow(Job["file_name"])')
	ActivatePos := InStr(Body, "Ops.Activate(WindowHwnd)", , FindPos)
	ActivePos := InStr(Body, "Ops.IsActive(WindowHwnd)", , ActivatePos)
	ExactPos := InStr(Body, "Ops.IsExactWindow(WindowHwnd", , ActivePos)
	MaximizePos := InStr(Body, "Ops.Maximize(WindowHwnd)", , ExactPos)
	Assert(FindPos > 0 and ActivatePos > FindPos and ActivePos > ActivatePos
		and ExactPos > ActivePos and MaximizePos > ExactPos,
		"the shared job must resolve and retain one exact HWND before maximizing")
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

_GTNWMG_CheckExactHwndBoundary() {
	Src := _DriverSourceNoComments()
	StartPos := InStr(Src, "class _TakeNoteNative")
	EndPos := InStr(Src, "_TakeNoteQueueFromFeatures(", , StartPos)
	Assert(StartPos > 0 and EndPos > StartPos,
		"the shared native note boundary must remain discoverable")
	NativeBody := SubStr(Src, StartPos, EndPos - StartPos)
	Assert(InStr(NativeBody, 'WinGetList("ahk_exe notepad.exe")') > 0,
		"the native resolver must enumerate only Notepad windows")
	Assert(InStr(NativeBody, "SetTitleMatchMode") = 0,
		"exact HWND ownership must not depend on mutable title-match state")
	Assert(InStr(NativeBody, '"ahk_id " . Hwnd') > 0,
		"active observation and maximize must keep the enumerated HWND")
}
Test("TakeNote: native window ownership uses one exact HWND",
	_GTNWMG_CheckExactHwndBoundary)
