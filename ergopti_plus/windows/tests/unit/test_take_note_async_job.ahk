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
	static suspend_after_launch := false
	static schedule_ok := true
	static timers := []
	static calls := []
	static launch_count := 0
	static maximize_count := 0
	static send_count := 0
	static warning_count := 0
	static errors := []
	static windows := []
	static last_pattern := ""
	static last_file_name := ""
	static last_target := 0
	static last_send := ""
	static replacement_title_after_activate := ""

	static Reset(NowTick := 100) {
		_TakeNoteFakeOps.now_tick := NowTick
		_TakeNoteFakeOps.suspended := false
		_TakeNoteFakeOps.file_exists := false
		_TakeNoteFakeOps.window_exists := false
		_TakeNoteFakeOps.active := false
		_TakeNoteFakeOps.focus_after_activate := true
		_TakeNoteFakeOps.suspend_after_launch := false
		_TakeNoteFakeOps.schedule_ok := true
		_TakeNoteFakeOps.timers := []
		_TakeNoteFakeOps.calls := []
		_TakeNoteFakeOps.launch_count := 0
		_TakeNoteFakeOps.maximize_count := 0
		_TakeNoteFakeOps.send_count := 0
		_TakeNoteFakeOps.warning_count := 0
		_TakeNoteFakeOps.errors := []
		_TakeNoteFakeOps.windows := []
		_TakeNoteFakeOps.last_pattern := ""
		_TakeNoteFakeOps.last_file_name := ""
		_TakeNoteFakeOps.last_target := 0
		_TakeNoteFakeOps.last_send := ""
		_TakeNoteFakeOps.replacement_title_after_activate := ""
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
		if _TakeNoteFakeOps.suspend_after_launch {
			_TakeNoteFakeOps.window_exists := true
			_TakeNoteFakeOps.suspended := true
		}
		return true
	}

	static WindowExists(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.calls.Push("window-exists")
		if _TakeNoteFakeOps.windows.Length > 0 {
			FileName := StrSplit(Pattern, " ahk_exe")[1]
			for Candidate in _TakeNoteFakeOps.windows {
				if InStr(Candidate.Title, FileName) > 0
					return true
			}
			return false
		}
		return _TakeNoteFakeOps.window_exists
	}

	static FindWindow(FileName) {
		_TakeNoteFakeOps.last_pattern := FileName
		_TakeNoteFakeOps.last_file_name := FileName
		_TakeNoteFakeOps.calls.Push("find-window")
		if _TakeNoteFakeOps.windows.Length == 0
			return _TakeNoteFakeOps.window_exists ? 4242 : 0
		for Candidate in _TakeNoteFakeOps.windows {
			if _TakeNoteTitleMatchesFile(Candidate.Title, FileName)
				return Candidate.Hwnd
		}
		return 0
	}

	static Activate(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.last_target := Pattern
		_TakeNoteFakeOps.calls.Push("activate")
		if _TakeNoteFakeOps.focus_after_activate
			_TakeNoteFakeOps.active := true
		if _TakeNoteFakeOps.replacement_title_after_activate != "" {
			for Candidate in _TakeNoteFakeOps.windows {
				if Candidate.Hwnd == Pattern {
					Candidate.Title := _TakeNoteFakeOps.replacement_title_after_activate
					break
				}
			}
			_TakeNoteFakeOps.replacement_title_after_activate := ""
		}
		return true
	}

	static IsActive(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.last_target := Pattern
		_TakeNoteFakeOps.calls.Push("is-active")
		return _TakeNoteFakeOps.active
	}

	static IsExactWindow(Hwnd, FileName) {
		_TakeNoteFakeOps.calls.Push("is-exact-window")
		if _TakeNoteFakeOps.windows.Length == 0
			return _TakeNoteFakeOps.window_exists
		for Candidate in _TakeNoteFakeOps.windows {
			if Candidate.Hwnd == Hwnd
				return _TakeNoteTitleMatchesFile(Candidate.Title, FileName)
		}
		return false
	}

	static Maximize(Pattern) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.last_target := Pattern
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
	AssertEqual("Notes.txt", _TakeNoteFakeOps.last_file_name,
		"every window lookup must retain the exact requested basename")
	AssertEqual(4242, _TakeNoteFakeOps.last_target,
		"focus and maximize must retain the exact enumerated HWND")
	Assert(!_TakeNotePending.Has(JobId),
		"successful publication must retire the completed job")
}
Test("take note async: entry returns before side effects and focused completion runs later (takenote-async-job)",
	_TNAJ_EntryReturnsBeforeSideEffectsAndCompletesLater)

_TNAJ_RapidDuplicateRequestsShareOneJob() {
	global _TakeNotePending
	_TNAJ_Reset()
	FirstJobId := TakeNoteRequest(false, "C:\Notes", true,
		_TakeNoteFakeOps)
	SecondJobId := TakeNoteRequest(false, "C:\Notes", true,
		_TakeNoteFakeOps)
	AssertEqual(FirstJobId, SecondJobId,
		"two pending requests for the same note path must share one owner")
	AssertEqual(1, _TakeNotePending.Count,
		"duplicate requests must not publish two note state machines")
	AssertEqual(1, _TakeNoteFakeOps.timers.Length,
		"duplicate requests must arm only one launch callback")

	_TakeNoteFakeOps.RunNext()
	AssertEqual(1, _TakeNoteFakeOps.launch_count,
		"the shared note job must launch Notepad only once")
	_TakeNoteFakeOps.window_exists := true
	_TakeNoteFakeOps.RunNext()
	AssertEqual(1, _TakeNoteFakeOps.maximize_count,
		"the shared note job must publish one window effect")
	AssertEqual(1, _TakeNoteFakeOps.send_count,
		"the shared note job must inject the launch newline only once")
	AssertEqual(0, _TakeNotePending.Count,
		"the shared owner must retire after its one completion")
}
Test("take note async: rapid duplicate requests share one exact-path job "
	. "(takenote-duplicate-owner)",
	_TNAJ_RapidDuplicateRequestsShareOneJob)

_TNAJ_SubstringCollisionsNeverOwnTheRequestedDocument() {
	global _TakeNotePending
	_TNAJ_Reset()
	_TakeNoteFakeOps.file_exists := true
	_TakeNoteFakeOps.windows := [
		{ Hwnd: 101, Title: "Old Notes.txt - Notepad" },
		{ Hwnd: 202, Title: "Notes.txt.bak - Notepad" },
		{ Hwnd: 212, Title: "Notes.txt - archive - Notepad" }
	]
	JobId := TakeNoteRequest(false, "C:\Notes", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertEqual(1, _TakeNoteFakeOps.launch_count,
		"substring collisions must not suppress launch of the exact requested document")
	AssertTrue(_TakeNotePending.Has(JobId),
		"the transaction must keep waiting while only colliding titles exist")
	AssertEqual(0, _TakeNoteFakeOps.maximize_count)
	AssertEqual(0, _TakeNoteFakeOps.send_count)

	_TakeNoteFakeOps.windows.Push(
		{ Hwnd: 303, Title: "*Notes.txt - Notepad" })
	_TakeNoteFakeOps.RunNext()
	AssertEqual(303, _TakeNoteFakeOps.last_target,
		"activation and maximize must retain the exact enumerated HWND")
	AssertEqual(1, _TakeNoteFakeOps.maximize_count)
	AssertEqual(1, _TakeNoteFakeOps.send_count)
	AssertFalse(_TakeNotePending.Has(JobId))
}
Test("take note async: substring title collisions never own the requested document "
	. "(ahk6-05-takenote-exact-title)",
	_TNAJ_SubstringCollisionsNeverOwnTheRequestedDocument)

_TNAJ_ExactTitleIsRevalidatedAfterActivation() {
	global _TakeNotePending
	_TNAJ_Reset()
	_TakeNoteFakeOps.file_exists := true
	_TakeNoteFakeOps.windows := [
		{ Hwnd: 404, Title: "Notes.txt - Notepad" }
	]
	_TakeNoteFakeOps.replacement_title_after_activate :=
		"Different.txt - Notepad"
	JobId := TakeNoteRequest(false, "C:\Notes", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertTrue(_TakeNotePending.Has(JobId),
		"a tab switch after enumeration must keep the exact-document job pending")
	AssertEqual(0, _TakeNoteFakeOps.maximize_count)
	AssertEqual(0, _TakeNoteFakeOps.send_count,
		"a title that changed after activation must receive no final input")

	_TakeNoteFakeOps.windows[1].Title := "Notes.txt - Notepad"
	_TakeNoteFakeOps.RunNext()
	AssertFalse(_TakeNotePending.Has(JobId))
	AssertEqual(1, _TakeNoteFakeOps.maximize_count)
	AssertEqual(0, _TakeNoteFakeOps.send_count,
		"an already-open exact note must not receive the launch-only newline")
}
Test("take note async: exact title is revalidated after activation "
	. "(ahk6-05-takenote-exact-title)",
	_TNAJ_ExactTitleIsRevalidatedAfterActivation)

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

_TNAJ_SuspendDuringLaunchStopsBeforeWindowEffects() {
	global _TakeNotePending
	_TNAJ_Reset()
	_TakeNoteFakeOps.suspend_after_launch := true
	JobId := TakeNoteRequest(false, "C:\Notes", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertFalse(_TakeNotePending.Has(JobId),
		"a suspension that arrives during launch must retire the deferred job")
	AssertEqual(1, _TakeNoteFakeOps.launch_count,
		"the already-started launch cannot be rolled back")
	AssertEqual(0, _TakeNoteFakeOps.maximize_count,
		"suspend during launch must prevent later window mutation")
	AssertEqual(0, _TakeNoteFakeOps.send_count,
		"suspend during launch must prevent final synthetic input")
	AssertEqual(0, _TakeNoteFakeOps.timers.Length,
		"a suspended job must not retry after the launch boundary")
}
Test("take note async: suspend during launch prevents later window effects "
	. "(takenote-suspend-effect-time)",
	_TNAJ_SuspendDuringLaunchStopsBeforeWindowEffects)

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
