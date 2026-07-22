; tests/meta/test_takenote_hotpath_nonblocking.ahk

; ==============================================================================
; MODULE: Take Note Hotkey Non-Blocking Tests
; DESCRIPTION:
; Win+N used WinWait/WinWaitActive and Sleep on the keyboard thread. A delayed
; Notepad launch could freeze all remapping for ten seconds. The hotkey now only
; launches/queues; a bounded, suspend-aware timer owns later window work.
; ==============================================================================

#Requires AutoHotkey v2.0

_TNNB_TakeNoteQueuesInsteadOfWaiting() {
	Body := _DriverFuncBody("TakeNote")
	Assert(Body != "", "TakeNote must exist in modules/shortcuts/win.ahk")
	Assert(!InStr(Body, "WinWait(") and !InStr(Body, "WinWaitActive(") and !InStr(Body, "Sleep("),
		"TakeNote must not wait or sleep on the keyboard hotkey thread")
	QueuePos := InStr(Body, "_TakeNoteQueueFinalize(FileName, !WindowAlreadyOpen)")
	RunPos := InStr(Body, "Run('notepad.exe")
	Assert(QueuePos > 0 and RunPos > QueuePos,
		"TakeNote must queue the bounded finalizer before launching a new Notepad process")
	Assert(InStr(Body, "} catch as Err") > 0 and InStr(Body, "LoggerError") > 0,
		"TakeNote must contain file/shell failures rather than throwing from the hotkey")
}
Test("shortcuts: TakeNote queues Notepad finalization without hotkey waits (takenote-hotpath-nonblocking)",
	_TNNB_TakeNoteQueuesInsteadOfWaiting)

_TNNB_PollOwnsDeadlineAndSuspendGate() {
	Body := _DriverFuncBody("_TakeNotePoll")
	Q := Chr(34)
	Assert(Body != "", "_TakeNotePoll must own the deferred note-window work")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"the deferred note-window finalizer must cancel when the driver is suspended")
	Assert(InStr(Body, "A_TickCount >= Job[" . Q . "deadline" . Q . "]") > 0,
		"the deferred note-window finalizer must stop at its finite launch deadline")
	Assert(InStr(Body, "SetTimer(Job[" . Q . "timer" . Q . "], -TAKE_NOTE_POLL_INTERVAL_MS)") > 0,
		"the deferred note-window finalizer must use one-shot bounded polling rather than a blocking wait")
	Assert(InStr(Body, "WinMaximize(Job[" . Q . "pattern" . Q . "])") > 0,
		"the deferred success path must retain the original maximize effect")
}
Test("shortcuts: TakeNote poll is deadline-owned and suspend-aware (takenote-hotpath-nonblocking)",
	_TNNB_PollOwnsDeadlineAndSuspendGate)
