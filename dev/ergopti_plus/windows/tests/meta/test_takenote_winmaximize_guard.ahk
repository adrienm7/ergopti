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
	Assert(InStr(PollBody, 'Ops.WindowExists(Job["pattern"])') > 0,
		"the poll must check the explicit Notepad target before finalization")
	Assert(InStr(PollBody, 'Ops.Maximize(Job["pattern"])') > 0,
		"the poll must maximise the explicit target, never AHK's last-found window")
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

_TTNWMG_CheckTitleMatchModeRestored() {
	EntryBody := _DriverFuncBody("TakeNote")
	Assert(!InStr(EntryBody, "SetTitleMatchMode"),
		"the hotkey callback must not mutate title-match state")
	Assert(InStr(_DriverSourceNoComments(), "SetTitleMatchMode(PreviousMode)") > 0,
		"the shared native boundary must restore title-match mode after target operations")
}
Test("shortcuts: TakeNote leaves title matching to the restoring shared native boundary",
	_TTNWMG_CheckTitleMatchModeRestored)
