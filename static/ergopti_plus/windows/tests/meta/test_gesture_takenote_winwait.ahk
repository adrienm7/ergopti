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
	Assert(InStr(RequestBody, "FileName, Pattern") > 0,
		"the shared job must retain the exact filename separately from diagnostics")
	Assert(InStr(PollBody, 'Ops.FindWindow(Job["file_name"])') > 0,
		"every deferred window probe must resolve the exact requested basename")
}
Test("TakeNote: the non-blocking shared job targets only the qualified Notepad window",
	_GTN_WinWaitIsQualified)
