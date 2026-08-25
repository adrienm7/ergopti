; tests/meta/test_takenote_hotpath_nonblocking.ahk

; ==============================================================================
; MODULE: Take Note Entry-Point Non-Blocking Tests
; DESCRIPTION:
; Win+N and the gesture action are sibling entry points for one logical action.
; Every sibling must only enqueue; a bounded, suspend-aware timer owns file,
; launch, focus, maximise, and final-send work away from the dispatch callback.
; ==============================================================================

#Requires AutoHotkey v2.0

_TNNB_EveryEntryPointOnlyQueues() {
	Banned := ["WinWait(", "WinWaitActive(", "Sleep(", "FileAppend(",
		"Run(", "WMActivate(", "WinMaximize(", "SendFinalResult("]
	for EntryName in ["TakeNote", "GestureTakeNote"] {
		Body := _DriverFuncBody(EntryName)
		Assert(Body != "", EntryName . " must remain a reachable action entry point")
		for Call in Banned {
			Assert(!InStr(Body, Call), EntryName . " must not execute " . Call
				. " on the keyboard/gesture dispatch thread (takenote-hotpath-nonblocking)")
		}
		Assert(InStr(Body, "_TakeNoteQueueFromFeatures(") > 0,
			EntryName . " must delegate to the one shared asynchronous note job")
	}
}
Test("take note: every action entry point only enqueues the shared job (takenote-hotpath-nonblocking)",
	_TNNB_EveryEntryPointOnlyQueues)

_TNNB_PollOwnsDeadlineAndSuspendGate() {
	Body := _DriverFuncBody("_TakeNotePoll")
	RescheduleBody := _DriverFuncBody("_TakeNoteReschedule")
	Q := Chr(34)
	Assert(Body != "", "_TakeNotePoll must own the deferred note-window work")
	Assert(InStr(Body, "Ops.IsSuspended()") > 0,
		"the deferred note-window finalizer must cancel when the driver is suspended")
	Assert(InStr(Body, "TickExpired(Job[" . Q . "started_tick" . Q . "], Job[" . Q . "timeout_ms" . Q . "], Ops.NowTick())") > 0,
		"the deferred note-window finalizer must stop at its finite wrap-safe launch deadline")
	Assert(InStr(RescheduleBody, "Ops.Schedule(Job[" . Q . "timer" . Q . "], TAKE_NOTE_POLL_INTERVAL_MS)") > 0,
		"the deferred note-window finalizer must use one-shot bounded polling rather than a blocking wait")
	Assert(InStr(Body, "Ops.Maximize(WindowHwnd)") > 0,
		"the deferred success path must retain the original maximize effect")
	Assert(InStr(Body, "Ops.FileExists(") > 0 and InStr(Body, "Ops.Launch(") > 0
		and InStr(Body, "Ops.SendFinal(") > 0,
		"the shared deferred job must own file, launch, and final input side effects")
}
Test("take note: shared poll owns every side effect, deadline, and suspend gate (takenote-hotpath-nonblocking)",
	_TNNB_PollOwnsDeadlineAndSuspendGate)
