; tests/meta/test_gesture_takenote_winwait.ahk

; ==============================================================================
; MODULE: Shared Take-Note Window Qualification Guard
; DESCRIPTION:
; The old gesture waited on a partial filename and could select Explorer, a
; browser, or an editor. The final design has no WinWait: both entry points use
; one deferred job whose target is qualified with ahk_exe notepad.exe.
; ==============================================================================

#Requires AutoHotkey v2.0+

_GTN_WinWaitIsQualified() {
	EntryBody := _DriverFuncBody("GestureTakeNote")
	RequestBody := _DriverFuncBody("TakeNoteRequest")
	PollBody := _DriverFuncBody("_TakeNotePoll")
	Assert(InStr(EntryBody, "_TakeNoteQueueFromFeatures(false)") > 0,
		"GestureTakeNote must delegate to the shared note transaction")
	Assert(!InStr(EntryBody, "WinWait") and !InStr(PollBody, "WinWait"),
		"neither gesture dispatch nor its deferred worker may block in WinWait")
	Assert(InStr(RequestBody, 'Pattern := FileName . " ahk_exe notepad.exe"') > 0,
		"the one shared target must qualify the filename with notepad.exe")
	Assert(InStr(PollBody, 'Ops.WindowExists(Job["pattern"])') > 0,
		"every deferred window probe must consume the qualified shared pattern")
}
Test("TakeNote: the non-blocking shared job targets only the qualified Notepad window",
	_GTN_WinWaitIsQualified)
