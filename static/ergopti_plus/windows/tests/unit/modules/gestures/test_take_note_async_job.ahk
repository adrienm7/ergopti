; tests/unit/modules/gestures/test_take_note_async_job.ahk

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
	static last_waited := ""
	static last_file_name := ""
	static last_target := 0
	static last_send := ""
	static replacement_title_after_activate := ""
	; A modelled Windows 11 Notepad: a window whose Tabs map a tab id to its
	; file path. A launched file becomes (or reselects) one of its tabs, as the
	; real Notepad does, after launch_switch_delay deferred callbacks.
	static tabbed_window := 0
	static launch_switch_delay := 0
	static pending_switches := []
	static next_tab := 0
	static last_send_tab := ""

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
		_TakeNoteFakeOps.tabbed_window := 0
		_TakeNoteFakeOps.launch_switch_delay := 0
		_TakeNoteFakeOps.pending_switches := []
		_TakeNoteFakeOps.next_tab := 0
		_TakeNoteFakeOps.last_send_tab := ""
	}

	; Shows the tab TabId of a modelled tabbed window, titled as Notepad does.
	static ShowTab(Window, TabId) {
		SplitPath(Window.Tabs[TabId], &FileName)
		Window.Tab := TabId
		Window.Title := FileName . " " . Chr(0x2013) . " Bloc-notes"
	}

	; Notepad keeps one tab per path: a launched path reselects its open tab.
	static OpenTab(Path) {
		Window := _TakeNoteFakeOps.tabbed_window
		if !IsObject(_TakeNoteFakeOps.FindModelWindow(Window.Hwnd))
			_TakeNoteFakeOps.windows.Push(Window)
		for TabId, TabPath in Window.Tabs {
			if StrLower(TabPath) == StrLower(Path) {
				_TakeNoteFakeOps.ShowTab(Window, TabId)
				return
			}
		}
		TabId := "tab-" . ++_TakeNoteFakeOps.next_tab
		Window.Tabs[TabId] := Path
		_TakeNoteFakeOps.ShowTab(Window, TabId)
	}

	static AdvanceTabs() {
		Remaining := []
		for Pending in _TakeNoteFakeOps.pending_switches {
			if --Pending.Delay <= 0
				_TakeNoteFakeOps.OpenTab(Pending.Path)
			else
				Remaining.Push(Pending)
		}
		_TakeNoteFakeOps.pending_switches := Remaining
	}

	static FindModelWindow(Hwnd) {
		for Candidate in _TakeNoteFakeOps.windows {
			if Candidate.Hwnd == Hwnd
				return Candidate
		}
		return 0
	}

	static SelectedTab(Hwnd) {
		_TakeNoteFakeOps.calls.Push("selected-tab")
		Window := _TakeNoteFakeOps.FindModelWindow(Hwnd)
		return IsObject(Window) && Window.HasProp("Tabs") ? Window.Tab : ""
	}

	static SelectTab(Hwnd, TabId) {
		_TakeNoteFakeOps.calls.Push("select-tab:" . TabId)
		Window := _TakeNoteFakeOps.FindModelWindow(Hwnd)
		if !IsObject(Window) || !Window.HasProp("Tabs") || !Window.Tabs.Has(TabId)
			return false
		_TakeNoteFakeOps.ShowTab(Window, TabId)
		return true
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
		if IsObject(_TakeNoteFakeOps.tabbed_window) {
			if _TakeNoteFakeOps.launch_switch_delay > 0
				_TakeNoteFakeOps.pending_switches.Push(
					{ Path: Path, Delay: _TakeNoteFakeOps.launch_switch_delay })
			else
				_TakeNoteFakeOps.OpenTab(Path)
		}
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

	static FindWindow(FileName, Admits := 0) {
		_TakeNoteFakeOps.last_pattern := FileName
		_TakeNoteFakeOps.last_file_name := FileName
		_TakeNoteFakeOps.calls.Push("find-window")
		if _TakeNoteFakeOps.windows.Length == 0
			return _TakeNoteFakeOps.window_exists ? 4242 : 0
		; The same rule as the native lookup: title first, then the job's admission.
		for Candidate in _TakeNoteFakeOps.windows {
			if _TakeNoteTitleMatchesFile(Candidate.Title, FileName)
					&& (!HasMethod(Admits, "Call") || Admits.Call(Candidate.Hwnd))
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
		_TakeNoteFakeOps.last_send_tab := _TakeNoteFakeOps.SelectedTab(_TakeNoteFakeOps.last_target)
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

	static WarnTimeout(Pattern, Waited) {
		_TakeNoteFakeOps.last_pattern := Pattern
		_TakeNoteFakeOps.last_waited := Waited
		_TakeNoteFakeOps.warning_count += 1
	}

	static ReportError(Message) {
		_TakeNoteFakeOps.errors.Push(Message)
	}

	static RunNext() {
		Assert(_TakeNoteFakeOps.timers.Length > 0,
			"the fake timer queue must contain a deferred note callback")
		Callback := _TakeNoteFakeOps.timers.RemoveAt(1)
		_TakeNoteFakeOps.AdvanceTabs()
		Callback.Call()
	}
}

_TNAJ_Reset(NowTick := 100) {
	global _TakeNotePending, _TakeNoteNextId, _TakeNoteDocumentWindows
	_TakeNotePending := Map()
	_TakeNoteNextId := 0
	_TakeNoteDocumentWindows := Map()
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

; Two folders' Notes.txt share their Notepad title: the window opened for one
; folder never answers a request for the other (takenote-native-document-owner).
_TNAJ_SameNameInAnotherFolderLaunchesItsOwnWindow() {
	global _TakeNotePending
	_TNAJ_Reset()
	_TakeNoteFakeOps.file_exists := true
	_TakeNoteFakeOps.windows := [{ Hwnd: 505, Title: "Notes.txt - Notepad" }]
	First := TakeNoteRequest(false, "C:\A", false, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertFalse(_TakeNotePending.Has(First))
	AssertEqual(505, _TakeNoteFakeOps.last_target, "the first folder's note owns its window")
	AssertEqual(0, _TakeNoteFakeOps.launch_count)

	Second := TakeNoteRequest(false, "C:\B", false, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertEqual(1, _TakeNoteFakeOps.launch_count, "another folder's same-named note gets its own Notepad")
	AssertTrue(_TakeNotePending.Has(Second), "the window bound to C:\A cannot stand for C:\B")
	_TakeNoteFakeOps.windows.Push({ Hwnd: 606, Title: "Notes.txt - Notepad" })
	_TakeNoteFakeOps.RunNext()
	AssertFalse(_TakeNotePending.Has(Second))
	AssertEqual(606, _TakeNoteFakeOps.last_target, "the second folder's note is the window launched for it")

	Again := TakeNoteRequest(false, "C:\A", false, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertFalse(_TakeNotePending.Has(Again))
	AssertEqual(505, _TakeNoteFakeOps.last_target, "the first folder's note keeps its own window")
	AssertEqual(1, _TakeNoteFakeOps.launch_count, "reusing a bound window launches nothing")
}
Test("take note async: a same-named note in another folder gets its own window "
	. "(takenote-native-document-owner)",
	_TNAJ_SameNameInAnotherFolderLaunchesItsOwnWindow)

; A modelled Windows 11 Notepad window, already showing a restored tab of a
; same-named note from a folder this module never opened.
_TNAJ_TabbedNotepad(Tabs, Selected) {
	Window := { Hwnd: 707, Title: "", Tabs: Tabs, Tab: "" }
	_TakeNoteFakeOps.ShowTab(Window, Selected)
	_TakeNoteFakeOps.windows := [Window]
	_TakeNoteFakeOps.tabbed_window := Window
	return Window
}

; The Windows 11 Notepad opens a second Notes.txt as a tab of its one window.
; The window-only binding waited for a new window that never came, then typed
; into whichever same-named tab was selected (takenote-notepad-tabs).
_TNAJ_TabbedNotepadSelectsTheRequestedTab() {
	global _TakeNotePending
	_TNAJ_Reset()
	_TakeNoteFakeOps.file_exists := true
	_TakeNoteFakeOps.launch_switch_delay := 1
	Window := _TNAJ_TabbedNotepad(Map("tab-0", "C:\Old\Notes.txt"), "tab-0")

	First := TakeNoteRequest(false, "C:\A", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertEqual(1, _TakeNoteFakeOps.launch_count,
		"a restored same-named tab cannot stand for the note: Notepad must open it")
	AssertEqual(0, _TakeNoteFakeOps.send_count,
		"the restored tab still selected before Notepad switches receives nothing")
	AssertTrue(_TakeNotePending.Has(First))
	_TakeNoteFakeOps.RunNext()
	AssertFalse(_TakeNotePending.Has(First))
	AssertEqual("C:\A\Notes.txt", Window.Tabs[_TakeNoteFakeOps.last_send_tab],
		"the launch newline goes to the tab Notepad opened for C:\A")

	Second := TakeNoteRequest(false, "C:\B", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertEqual(2, _TakeNoteFakeOps.launch_count, "the tab bound to C:\A cannot stand for C:\B")
	_TakeNoteFakeOps.RunNext()
	AssertFalse(_TakeNotePending.Has(Second),
		"the C:\B note opened as a tab of the same window completes without a new window")
	AssertEqual(0, _TakeNoteFakeOps.warning_count)
	AssertEqual(2, _TakeNoteFakeOps.send_count)
	AssertEqual("C:\B\Notes.txt", Window.Tabs[_TakeNoteFakeOps.last_send_tab])

	Again := TakeNoteRequest(false, "C:\A", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	AssertFalse(_TakeNotePending.Has(Again))
	AssertEqual(2, _TakeNoteFakeOps.launch_count, "the note's open tab is selected again, not relaunched")
	AssertEqual("C:\A\Notes.txt", Window.Tabs[Window.Tab],
		"the focused window shows the C:\A tab, not the C:\B one selected before")
	AssertEqual(707, _TakeNoteFakeOps.last_target)
	AssertEqual(2, _TakeNoteFakeOps.send_count, "an already-open note gets no launch newline")
}
Test("take note async: a tabbed Notepad selects the tab of the exact note path "
	. "(takenote-notepad-tabs)",
	_TNAJ_TabbedNotepadSelectsTheRequestedTab)

; After a restart the bindings are gone while the note may already be the
; selected tab: Notepad then keeps that tab, which is accepted once it settled.
_TNAJ_TabbedNotepadKeepsAnAlreadySelectedNote() {
	global _TakeNotePending, TAKE_NOTE_TAB_SETTLE_MS, TAKE_NOTE_POLL_INTERVAL_MS
	_TNAJ_Reset()
	_TakeNoteFakeOps.file_exists := true
	Window := _TNAJ_TabbedNotepad(Map("tab-7", "C:\A\Notes.txt"), "tab-7")
	JobId := TakeNoteRequest(false, "C:\A", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	SettleStart := _TakeNoteFakeOps.now_tick
	while _TakeNotePending.Has(JobId) && _TakeNoteFakeOps.now_tick - SettleStart < 2 * TAKE_NOTE_TAB_SETTLE_MS {
		AssertEqual(0, _TakeNoteFakeOps.send_count, "an unchanged tab is not taken before it settled")
		_TakeNoteFakeOps.now_tick += TAKE_NOTE_POLL_INTERVAL_MS
		_TakeNoteFakeOps.RunNext()
	}
	AssertFalse(_TakeNotePending.Has(JobId), "the tab Notepad kept for the launched path is accepted")
	AssertTrue(_TakeNoteFakeOps.now_tick - SettleStart >= TAKE_NOTE_TAB_SETTLE_MS,
		"the unchanged tab was accepted only after the settle delay")
	AssertEqual(1, _TakeNoteFakeOps.launch_count)
	AssertEqual(1, Window.Tabs.Count, "Notepad reselects the open path instead of a duplicate tab")
	AssertEqual("tab-7", _TakeNoteFakeOps.last_send_tab)
}
Test("take note async: a tabbed Notepad keeps the note tab it already showed "
	. "(takenote-notepad-tabs)",
	_TNAJ_TabbedNotepadKeepsAnAlreadySelectedNote)

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
	; Native A_TickCount crosses the DWORD boundary without wrapping.
	_TakeNoteFakeOps.now_tick := StartTick + TAKE_NOTE_LAUNCH_TIMEOUT_MS
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

; Three field warnings said « did not appear or take focus »: two causes with two cures.
_TNAJ_TimeoutNamesWhatItWaitedFor() {
	global TAKE_NOTE_LAUNCH_TIMEOUT_MS
	_TNAJ_Reset()
	TakeNoteRequest(false, "C:\Notes", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.RunNext()
	_TakeNoteFakeOps.now_tick += TAKE_NOTE_LAUNCH_TIMEOUT_MS
	_TakeNoteFakeOps.RunNext()
	AssertEqual("window", _TakeNoteFakeOps.last_waited, "no window ever appeared")

	_TNAJ_Reset()
	TakeNoteRequest(false, "C:\Notes", true, _TakeNoteFakeOps)
	_TakeNoteFakeOps.window_exists := true
	_TakeNoteFakeOps.focus_after_activate := false
	_TakeNoteFakeOps.RunNext()
	_TakeNoteFakeOps.now_tick += TAKE_NOTE_LAUNCH_TIMEOUT_MS
	_TakeNoteFakeOps.RunNext()
	AssertEqual("focus", _TakeNoteFakeOps.last_waited, "the window appeared and never took focus")
}
Test("take note async: the deadline warning says what it waited for (takenote-timeout-cause)",
	_TNAJ_TimeoutNamesWhatItWaitedFor)

; The Windows 11 Store Notepad separates the product label with an en dash
; (« Notes.txt – Bloc-notes »): a hyphen-only matcher never found its window.
_TNAJ_TitleSeparatorsOfEveryNotepad() {
	EnDash := Chr(0x2013), EmDash := Chr(0x2014)
	AssertTrue(_TakeNoteTitleMatchesFile("Notes.txt - Notepad", "Notes.txt"), "classic Notepad hyphen")
	AssertTrue(_TakeNoteTitleMatchesFile("Notes.txt " . EnDash . " Bloc-notes", "Notes.txt"),
		"Windows 11 Notepad en dash, French label with its own hyphen")
	AssertTrue(_TakeNoteTitleMatchesFile("*Notes.txt " . EnDash . " Notepad", "Notes.txt"), "unsaved marker")
	AssertTrue(_TakeNoteTitleMatchesFile("Notes.txt " . EmDash . " Notepad", "Notes.txt"), "em dash")
	AssertFalse(_TakeNoteTitleMatchesFile("Notes.txt " . EnDash . " old.txt " . EnDash . " Notepad", "Notes.txt"),
		"the last separator names the product, so a longer document title stays foreign")
	AssertFalse(_TakeNoteTitleMatchesFile("Notes.txt.bak " . EnDash . " Bloc-notes", "Notes.txt"), "backup")
	AssertFalse(_TakeNoteTitleMatchesFile("Notes.txt " . EnDash . " Bloc-notes", "Other.txt"), "other file")
}
Test("take note async: the title matcher reads every Notepad separator (takenote-title-separator)",
	_TNAJ_TitleSeparatorsOfEveryNotepad)
