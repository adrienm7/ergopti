; tests/meta/test_takenote_winmaximize_guard.ahk

; ==============================================================================
; MODULE: Take-Note Explicit Maximize Target Guard
; DESCRIPTION:
; Win+N must only enqueue. The shared poll checks an explicit qualified target,
; reports timeout, and never lets a bare WinMaximize use AHK's last-found window.
; ==============================================================================

#Requires AutoHotkey v2.0+

_TTNWMG_CheckWinMaximizeGuard() {
	Body := _DriverFuncBody("TakeNote")
	PollBody := _DriverFuncBody("_TakeNotePoll")
	Assert(InStr(Body, "_TakeNoteQueueFromFeatures") > 0,
		"TakeNote must queue the shared transaction")
	Assert(InStr(Body, "WinWait") = 0 and InStr(Body, "WinMaximize") = 0,
		"TakeNote must not wait or maximise on the hotkey thread")
	Assert(InStr(PollBody, 'Ops.FindWindow(Job["file_name"])') > 0,
		"the poll must resolve the exact Notepad document before finalization")
	Assert(InStr(PollBody, "Ops.Maximize(WindowHwnd)") > 0,
		"the poll must maximise the enumerated HWND, never AHK's last-found window")
}
Test("shortcuts: TakeNote defers and targets maximize safely",
	_TTNWMG_CheckWinMaximizeGuard)

_TTNWMG_CheckTimeoutIsLogged() {
	ExpireBody := _DriverFuncBody("_TakeNoteExpire")
	Assert(InStr(ExpireBody, "WarnTimeout") > 0,
		"the bounded launch/focus expiry must remain diagnosable")
}
Test("shortcuts: TakeNote reports the bounded Notepad deadline",
	_TTNWMG_CheckTimeoutIsLogged)

_TTNWMG_CheckTitleMatchingIsNotAmbient() {
	EntryBody := _DriverFuncBody("TakeNote")
	Assert(!InStr(EntryBody, "SetTitleMatchMode"),
		"the hotkey callback must not mutate title-match state")
	Src := _DriverSourceNoComments()
	StartPos := InStr(Src, "class _TakeNoteNative")
	EndPos := InStr(Src, "_TakeNoteQueueFromFeatures(", , StartPos)
	Assert(StartPos > 0 and EndPos > StartPos,
		"the shared native note boundary must remain discoverable")
	NativeBody := SubStr(Src, StartPos, EndPos - StartPos)
	Assert(InStr(NativeBody, "_TakeNoteTitleMatchesFile") > 0,
		"the shared boundary must own an exact document-title matcher")
	Assert(InStr(NativeBody, "SetTitleMatchMode") = 0,
		"the native boundary must not depend on ambient substring matching")
}
Test("shortcuts: TakeNote title matching is independent of ambient match mode",
	_TTNWMG_CheckTitleMatchingIsNotAmbient)
