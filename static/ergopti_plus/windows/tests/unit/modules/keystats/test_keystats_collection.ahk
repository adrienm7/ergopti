; tests/unit/modules/keystats/test_keystats_collection.ahk

; ==============================================================================
; MODULE: Keystats Collection Pause And Session Reset
; DESCRIPTION:
; Replays _shared/tests/corpus/metrics/collection_session_vectors.json through
; the REAL typing hook (KL_Hook_OnChar) and the real pause/reset functions, then
; pins what the shared sequences cannot say: the pause is a state of its own,
; closing lifecycle rows survive it, and a reset closes the session only after
; the pending text is stored, refusing rather than discarding on failure.
; The Linux and macOS suites replay the same vectors.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Test harness =======
; ===============================
; ===============================

; Runs Body on an initialised keystats with a clean typing buffer and a neutral
; focus, and restores every field it touched. The pause is cleared on the way in
; and out so no later test inherits it.
_KCT_WithKeystats(Body) {
	global _Stub_WpmPushCalls
	PrevInit    := Keystats.initialized
	PrevEvents  := Keystats.buffer_events
	PrevText    := Keystats.buffer_text
	PrevFocus   := MetricsFocusCache.state
	PrevDisabledApps := MetricsFilters.disabled_apps
	PrevPrivateBrowsing := MetricsFilters.private_browsing
	PrevSecureField := MetricsFilters.secure_field
	PrevSystemAuth := MetricsFilters.system_auth
	PrevPause := KLCollection.suspended
	PrevWpm := _Stub_WpmPushCalls
	Keystats.initialized   := true
	Keystats.buffer_events := []
	Keystats.buffer_text   := ""
	MetricsFocusCache.state := {
		valid: true,
		last_at: A_TickCount,
		hwnd: 1,
		process_name: "collection-pause-test.exe",
		title: "Collection pause test",
		class: "CollectionPauseTest",
		failure_reason: "",
		timed_out: false
	}
	MetricsFilters.disabled_apps := Map()
	MetricsFilters.private_browsing := false
	MetricsFilters.secure_field := false
	MetricsFilters.system_auth := false
	KLCollection.suspended := false
	_Stub_WpmPushCalls := []
	try {
		Body()
	} finally {
		Keystats.initialized   := PrevInit
		Keystats.buffer_events := PrevEvents
		Keystats.buffer_text   := PrevText
		MetricsFocusCache.state := PrevFocus
		MetricsFilters.disabled_apps := PrevDisabledApps
		MetricsFilters.private_browsing := PrevPrivateBrowsing
		MetricsFilters.secure_field := PrevSecureField
		MetricsFilters.system_auth := PrevSystemAuth
		KLCollection.suspended := PrevPause
		_Stub_WpmPushCalls := PrevWpm
	}
}

; Applies one corpus operation. State carries the secure-field flag, which the
; typing hook reads through the filter port exactly as the production flag does.
_KCT_Apply(Op, State, Label) {
	global _Stub_WpmPushCalls
	Kind := Op["op"]
	if (Kind = "type") {
		Before := Keystats.buffer_events.Length
		KL_Hook_OnChar(0, "x", () => State.secure)
		Counted := Keystats.buffer_events.Length > Before
		if Op.Has("recorded")
			AssertEqual(Op["recorded"], Counted, Label . ": type recorded")
	} else if (Kind = "suspend") {
		KL_SuspendCollection(() => 0)
	} else if (Kind = "resume") {
		KL_ResumeCollection()
	} else if (Kind = "secure_on") {
		State.secure := true
	} else if (Kind = "secure_off") {
		State.secure := false
	} else if (Kind = "reset") {
		Applied := KL_ResetSession(() => 0, (*) => true, () => _KCT_ClearWpm())
		AssertEqual(Op["reset_applied"], Applied ? true : false, Label . ": reset applied")
	} else {
		throw Error(Label . ": unknown operation " . Kind)
	}
	if Op.Has("suspended")
		AssertEqual(Op["suspended"], KL_IsCollectionSuspended(), Label . ": suspended")
	if Op.Has("session_keystrokes")
		AssertEqual(Op["session_keystrokes"], _Stub_WpmPushCalls.Length, Label . ": live session count")
}

; The typing-speed readout the reset restarts; the stub records each push.
_KCT_ClearWpm() {
	global _Stub_WpmPushCalls
	_Stub_WpmPushCalls := []
}





; ============================================
; ============================================
; ======= 2/ Shared sequences replayed =======
; ============================================
; ============================================

_KCT_SharedSequences() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\metrics\collection_session_vectors.json", "UTF-8"))
	Assert(Corpus["vectors"].Length >= 8, "the shared sequences must be present")
	Replayed := 0
	for Vector in Corpus["vectors"] {
		State := { secure: false }
		_KCT_WithKeystats(_KCT_ReplayOne.Bind(Vector, State))
		Replayed += 1
	}
	AssertEqual(Corpus["vectors"].Length, Replayed, "every shared sequence is replayed")
}

_KCT_ReplayOne(Vector, State) {
	for Op in Vector["ops"]
		_KCT_Apply(Op, State, Vector["id"])
}
Test("keystats collection: the shared pause and reset sequences hold on Windows", _KCT_SharedSequences)





; ==============================
; ==============================
; ======= 3/ Pause rules =======
; ==============================
; ==============================

_KCT_PauseIsNotTheDriverPause() {
	_KCT_WithKeystats(Body)
	Body() {
		KL_SuspendCollection(() => 0)
		Assert(KL_IsCollectionSuspended(), "the user's pause is on")
		Assert(!A_IsSuspended, "and the driver is not suspended: hotkeys and hotstrings keep working")
	}
}
Test("keystats collection: the pause is a state of its own, apart from the driver pause", _KCT_PauseIsNotTheDriverPause)

_KCT_PausedChokepointKeepsClosingRows() {
	KLCollection.suspended := true
	try {
		Assert(KLCollection.Rejects("typing"), "typing rows are refused while paused")
		Assert(KLCollection.Rejects("shortcut"), "shortcut rows are refused while paused")
		Assert(KLCollection.Rejects("mouse_click"), "mouse rows are refused while paused")
		Assert(!KLCollection.Rejects("session_end"),
			"a session_end still closes a session opened before the pause")
		Assert(!KLCollection.Rejects("idle_end"), "an idle_end still closes its idle")
		Assert(!KLCollection.Rejects("system_event"), "lifecycle markers stay diagnosable")
	} finally {
		KLCollection.suspended := false
	}
}
Test("keystats collection: a pause refuses content rows but not the rows that close an interval",
	_KCT_PausedChokepointKeepsClosingRows)

_KCT_PauseStoresPendingTextFirst() {
	_KCT_WithKeystats(Body)
	Body() {
		Flushed := []
		KL_SuspendCollection(() => Flushed.Push(KLCollection.suspended))
		AssertEqual(1, Flushed.Length, "the pending text is flushed once")
		AssertEqual(false, Flushed[1], "and before the pause takes hold")
		KL_SuspendCollection(() => Flushed.Push("again"))
		AssertEqual(1, Flushed.Length, "a second pause is a no-op")
	}
}
Test("keystats collection: pausing stores the text already typed before it takes hold", _KCT_PauseStoresPendingTextFirst)

_KCT_CaptureSourcesStaySilentWhilePaused() {
	_KCT_WithKeystats(Body)
	Body() {
		KLCollection.suspended := true
		Assert(KL_CaptureHeld(), "capture sources are held while paused")
		KLCollection.suspended := false
		AssertEqual(A_IsSuspended ? true : false, KL_CaptureHeld(), "and released when the pause ends")
		Before := Keystats.buffer_events.Length
		KLCollection.suspended := true
		KL_Hook_OnKeyDown(0, 0x41, 0x1E)
		AssertEqual(Before, Keystats.buffer_events.Length, "a key press is not captured while paused")
	}
}
Test("keystats collection: the typing hook captures nothing while paused", _KCT_CaptureSourcesStaySilentWhilePaused)





; ================================
; ================================
; ======= 4/ Session reset =======
; ================================
; ================================

_KCT_ResetClosesAnActiveSessionAfterFlushing() {
	_KCT_WithKeystats(Body)
	Body() {
		PrevActive := KLWatch.is_session_active
		PrevTick := KLHook.last_tick
		Order := []
		Seen := []
		try {
			KLWatch.is_session_active := true
			KLHook.last_tick := 1234
			Applied := KL_ResetSession(() => Order.Push("flush"),
				(Last, Now) => (Order.Push("close"), Seen.Push(Last), true),
				() => Order.Push("wpm"))
		} finally {
			KLWatch.is_session_active := PrevActive
			KLHook.last_tick := PrevTick
		}
		Assert(Applied, "the reset is applied")
		AssertEqual("flush,close,wpm", _KCT_Join(Order), "the text is stored, then the session closes, then the figures restart")
		AssertEqual(1234, Seen[1], "the session ends at the last keystroke, as the idle timeout would end it")
	}
}
Test("keystats collection: a reset stores the text, closes the session, then restarts the figures",
	_KCT_ResetClosesAnActiveSessionAfterFlushing)

_KCT_ResetWithoutASessionClosesNothing() {
	_KCT_WithKeystats(Body)
	Body() {
		PrevActive := KLWatch.is_session_active
		Closed := []
		try {
			KLWatch.is_session_active := false
			Applied := KL_ResetSession(() => 0, (*) => Closed.Push(1), () => 0)
		} finally KLWatch.is_session_active := PrevActive
		Assert(Applied, "a reset with no open session still restarts the figures")
		AssertEqual(0, Closed.Length, "and writes no session_end for a session that never started")
	}
}
Test("keystats collection: a reset with no open session writes no session_end", _KCT_ResetWithoutASessionClosesNothing)

_KCT_ResetRefusesRatherThanDiscards() {
	_KCT_WithKeystats(Body)
	Body() {
		PrevActive := KLWatch.is_session_active
		Restarted := []
		try {
			KLWatch.is_session_active := true
			Refused := !KL_ResetSession(() => 0, (*) => false, () => Restarted.Push(1))
		} finally KLWatch.is_session_active := PrevActive
		Assert(Refused, "a refused session close refuses the reset")
		AssertEqual(0, Restarted.Length, "and leaves the live figures alone, so nothing is lost")
		Keystats.initialized := false
		Assert(!KL_ResetSession(() => 0, (*) => true, () => 0), "a reset with metrics not running is refused")
	}
}
Test("keystats collection: a reset that cannot close the session is refused, not forced", _KCT_ResetRefusesRatherThanDiscards)

_KCT_Join(Items) {
	Out := ""
	for Item in Items
		Out .= (Out = "" ? "" : ",") . Item
	return Out
}
