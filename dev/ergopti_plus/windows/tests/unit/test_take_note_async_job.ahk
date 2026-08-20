; tests/unit/test_take_note_async_job.ahk

; ==============================================================================
; MODULE: Shared Take-Note Async Job Tests
; DESCRIPTION:
; Drives the production state machine with a fake clock, timer queue, filesystem,
; process, and window boundary. No test launches Notepad or sends real input.
; ==============================================================================

#Requires AutoHotkey v2.0+

class _TakeNoteFakeOps {
	static now_tick := 100
	static suspended := false
	static file_exists := false
	static window_exists := false
	static active := false
	static focus_after_activate := true
	static schedule_ok := true
	static timers := []
	static calls := []
	static launch_count := 0
	static maximize_count := 0
	static send_count := 0
	static warning_count := 0
	static errors := []
	static last_pattern := ""
	static last_send := ""

	static Reset(NowTick := 100) {
		_TakeNoteFakeOps.now_tick := NowTick
		_TakeNoteFakeOps.suspended := false
		_TakeNoteFakeOps.file_exists := false
		_TakeNoteFakeOps.window_exists := false
		_TakeNoteFakeOps.active := false
		_TakeNoteFakeOps.focus_after_activate := true
		_TakeNoteFakeOps.schedule_ok := true
		_TakeNoteFakeOps.timers := []
		_TakeNoteFakeOps.calls := []
		_TakeNoteFakeOps.launch_count := 0
		_TakeNoteFakeOps.maximize_count := 0
		_TakeNoteFakeOps.send_count := 0
		_TakeNoteFakeOps.warning_count := 0
		_TakeNoteFakeOps.errors := []
		_TakeNoteFakeOps.last_pattern := ""
		_TakeNoteFakeOps.last_send := ""
	}

	static NowTick() {
		return _TakeNoteFakeOps.now_tick
	}

	static IsSuspended() {
		return _TakeNoteFakeOps.suspended
	}

	static FileExists(Path) {
		_TakeNoteFakeOps.calls.Push("file-exists:" . Path)
		return _TakeNoteFakeOps.file_exists
	}

	static CreateEmptyFile(Path) {
		_TakeNoteFakeOps.calls.Push("create:" . Path)
		_TakeNoteFakeOps.file_exists := true
		return true
	}

	static Launch(Path) {
		_TakeNoteFakeOps.calls.Push("launch:" . Path)
		_TakeNoteFakeOps.launch_count += 1
		return true
	}

	static WindowExists(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.calls.Push("window-exists")
		return _TakeNoteFakeOps.window_exists
	}

	static Activate(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.calls.Push("activate")
		if _TakeNoteFakeOps.focus_after_activate
			_TakeNoteFakeOps.active := true
		return true
	}

	static IsActive(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.calls.Push("is-active")
		return _TakeNoteFakeOps.active
	}

	static Maximize(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.calls.Push("maximize")
		_TakeNoteFakeOps.maximize_count += 1
		return true
	}

	static SendFinal(Keys) {
		_TakeNoteFakeOps.last_send := Keys
		_TakeNoteFakeOps.calls.Push("send-final")
		_TakeNoteFakeOps.send_count += 1
		return true
	}

	static Schedule(Callback, DelayMs) {
		_TakeNoteFakeOps.calls.Push("schedule:" . DelayMs)
		if !_TakeNoteFakeOps.schedule_ok
			return false
		_TakeNoteFakeOps.timers.Push(Callback)
		return true
	}

	static WarnTimeout(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.warning_count += 1
	}

	static ReportError(Message) {
		_TakeNoteFakeOps.errors.Push(Message)
	}

	static RunNext() {
		Assert(_TakeNoteFakeOps.timers.Length > 0,
			"the fake timer queue must contain a deferred note callback")
		Callback := _TakeNoteFakeOps.timers.RemoveAt(1)
		Callback.Call()
	}
}

_TNAJ_Reset(NowTick := 100) {
	global _TakeNotePending, _TakeNoteNextId
	_TakeNotePending := Map()
	_TakeNoteNextId := 0
	_TakeNoteFakeOps.Reset(NowTick)
}

_TNAJ_EntryReturnsBeforeSideEffectsAndCompletesLater() {
	global _TakeNotePending
	_TNAJ_Reset()
	JobId := TakeNoteRequest(false, "C:\Notes", true, _TakeNoteFakeOps)
	Assert(JobId > 0 and _TakeNotePending.Has(JobId),
		"the entry seam must publish one pending job")
	AssertEqual(1, _TakeNoteFakeOps.timers.Length,
		"the entry seam must enqueue exactly one deferred callback")
	AssertEqual(0, _TakeNoteFakeOps.launch_count,
		"the entry seam must return before process launch")
	Assert(!_TakeNoteFakeOps.file_exists,
		"the entry seam must return before filesystem mutation")

	_TakeNoteFakeOps.RunNext()
	Assert(_TakeNoteFakeOps.file_exists,
		"the first deferred phase must create the missing note file")
	AssertEqual(1, _TakeNoteFakeOps.launch_count,
		"the first deferred phase must launch Notepad exactly once")
	Assert(_TakeNotePending.Has(JobId),
		"the job must remain pending while its qualified window is absent")

	_TakeNoteFakeOps.window_exists := true
	_TakeNoteFakeOps.focus_after_activate := false
	_TakeNoteFakeOps.RunNext()
	AssertEqual(0, _TakeNoteFakeOps.maximize_count,
		"a window that did not take focus must not be maximized")
	AssertEqual(0, _TakeNoteFakeOps.send_count,
		"a window that did not take focus must not receive final input")

	_TakeNoteFakeOps.focus_after_activate := true
	_TakeNoteFakeOps.RunNext()
	AssertEqual(1, _TakeNoteFakeOps.maximize_count,
		"the observed focused Notepad target must be maximized once")
	AssertEqual(1, _TakeNoteFakeOps.send_count,
		"the newly launched note must receive its final input once")
	AssertEqual("^{End}{Enter}", _TakeNoteFakeOps.last_send,
		"the shared job must preserve the Win+N final-input behavior")
	Assert(InStr(_TakeNoteFakeOps.last_pattern, "ahk_exe notepad.exe") > 0,
		"every window operation must use the qualified Notepad pattern")
	Assert(!_TakeNotePending.Has(JobId),
		"successful publication must retire the completed job")
}
Test("take note async: entry returns before side effects and focused completion runs later (takenote-async-job)",
	_TNAJ_EntryReturnsBeforeSideEffectsAndCompletesLater)

_TNAJ_SuspendCancelsBeforeLaunch() {
	global _TakeNotePending
	_TNAJ_Reset()
	JobId := TakeNoteRequest(false, "C:\Notes", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.suspended := true
	_TakeNoteFakeOps.RunNext()
	Assert(!_TakeNotePending.Has(JobId),
		"suspend must retire the deferred job")
	AssertEqual(0, _TakeNoteFakeOps.launch_count,
		"suspend before the timer fires must prevent process launch")
	Assert(!_TakeNoteFakeOps.file_exists,
		"suspend before the timer fires must prevent file creation")
	AssertEqual(0, _TakeNoteFakeOps.timers.Length,
		"a suspended job must not re-arm itself")
}
Test("take note async: suspend cancels before file or process work (takenote-async-job)",
	_TNAJ_SuspendCancelsBeforeLaunch)

_TNAJ_WrapSafeTimeoutCancelsBeforeLaunch() {
	global _TakeNotePending, TAKE_NOTE_LAUNCH_TIMEOUT_MS
	StartTick := 0xFFFFFFF0
	_TNAJ_Reset(StartTick)
	JobId := TakeNoteRequest(false, "C:\Notes", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.now_tick := (StartTick + TAKE_NOTE_LAUNCH_TIMEOUT_MS) & 0xFFFFFFFF
	_TakeNoteFakeOps.RunNext()
	Assert(!_TakeNotePending.Has(JobId),
		"the exact wrap-safe deadline must retire the job")
	AssertEqual(1, _TakeNoteFakeOps.warning_count,
		"deadline cancellation must remain diagnosable")
	AssertEqual(0, _TakeNoteFakeOps.launch_count,
		"an already-expired deferred job must not launch a process")
	Assert(!_TakeNoteFakeOps.file_exists,
		"an already-expired deferred job must not touch the filesystem")
}
Test("take note async: fake clock expiry across rollover cancels before launch (takenote-async-job)",
	_TNAJ_WrapSafeTimeoutCancelsBeforeLaunch)
