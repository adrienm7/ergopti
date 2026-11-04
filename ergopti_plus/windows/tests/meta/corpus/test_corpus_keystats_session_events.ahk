; tests/meta/corpus/test_corpus_keystats_session_events.ahk

; ==============================================================================
; MODULE: Session Events Corpus Consumer (Windows)
; DESCRIPTION:
; Replays keystats/session_events_vectors.json through the real watchers.
;
; FEATURES & RATIONALE:
; 1. The first replay found four disagreements, all fixed in the watchers: the
;    two silences were reached at their exact limit instead of past it, an idle
;    span counted from the last input instead of from its own start, a click or a
;    scroll neither ended an idle span nor kept the session alive, and shutdown
;    counted the silence after the last input as typing time.
; 2. idle_end at a close is Windows' own pairing rule: its rows always close what
;    they opened (the corpus's differences entry). Only that row is set aside, and
;    only right before a session_end; the corpus decides everything else.
; ==============================================================================

#Requires AutoHotkey v2.0

_CTSE_Rows() {
	global _Stub_AppendLogRows
	Rows := []
	for Index, Row in _Stub_AppendLogRows {
		Next := Index < _Stub_AppendLogRows.Length ? _Stub_AppendLogRows[Index + 1] : 0
		if (Row["type"] == "idle_end") && IsObject(Next) && (Next["type"] == "session_end")
			continue
		Rows.Push(Row)
	}
	_Stub_AppendLogRows := []
	return Rows
}

_CTSE_Step(Step, Label) {
	switch Step["op"] {
		case "input":
			if Step["keystroke"] {
				KL_Watchers_OnKeystroke(0, Step["at"])
				KLHook.last_tick := Step["at"]
			} else
				KL_Watchers_OnPointer(0, Step["at"])
		case "tick":
			KL_Watchers_IdleTick(Step["at"])
		case "stop":
			KL_Watchers_CloseOnStop()
		default:
			throw ValueError("Unknown corpus operation " . Step["op"])
	}
	Rows := _CTSE_Rows()
	AssertEqual(Step["expected"].Length, Rows.Length, Label . " row count")
	for Index, Expected in Step["expected"] {
		AssertEqual(Expected["kind"], Rows[Index]["type"], Label)
		if Expected.Has("duration_ms")
			AssertEqual(Expected["duration_ms"], Rows[Index]["duration_ms"], Label)
	}
}

_CTSE_Case(Row) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	Saved := Map()
	for Name in ["is_idle", "idle_started_at", "is_session_active", "session_started_at",
		"last_authorized_tick", "privacy_interrupted", "privacy_started_at", "system_events",
		"session_close", "session_close_draining", "idle_close"]
		Saved[Name] := KLWatch.%Name%
	SavedTick := KLHook.last_tick
	SavedInitialized := Keystats.initialized
	SavedStub := [_Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook]
	try {
		for Name in ["is_idle", "is_session_active", "privacy_interrupted", "system_events",
			"session_close", "session_close_draining", "idle_close"]
			KLWatch.%Name% := false
		for Name in ["idle_started_at", "session_started_at", "last_authorized_tick", "privacy_started_at"]
			KLWatch.%Name% := 0
		KLHook.last_tick := 0
		Keystats.initialized := true
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		for Index, Step in Row["steps"]
			_CTSE_Step(Step, Row["id"] . " step " . Index)
	} finally {
		for Name, Value in Saved
			KLWatch.%Name% := Value
		KLHook.last_tick := SavedTick
		Keystats.initialized := SavedInitialized
		_Stub_AppendLogRows := SavedStub[1]
		_Stub_AppendLogAccept := SavedStub[2]
		_Stub_AppendLogRejectSuspend := SavedStub[3]
		_Stub_AppendLogHook := SavedStub[4]
	}
}

_CTSE_All() {
	Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\keystats\session_events_vectors.json", "UTF-8"))
	AssertEqual(KLWatchConst.MICRO_IDLE_TIMEOUT_MS, Corpus["timings"]["micro_idle_ms"], "the corpus timing moved")
	AssertEqual(KLWatchConst.SESSION_TIMEOUT_MS, Corpus["timings"]["session_timeout_ms"], "the corpus timing moved")
	AssertTrue(Corpus["cases"].Length >= 6, "the session cases must be read")
	for Row in Corpus["cases"]
		_CTSE_Case(Row)
}
Test("corpus: the watchers replay every session event case (corpus-session-events)", _CTSE_All)
