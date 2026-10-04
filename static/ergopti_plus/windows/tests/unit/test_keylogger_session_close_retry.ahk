; tests/unit/test_keylogger_session_close_retry.ahk

; ==============================================================================
; MODULE: Partial Session Close Recovery Tests
; DESCRIPTION: Retry the remaining session close without repeating accepted idle records.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLSCR_RefuseAfterIdle(Entry) {
	global _Stub_AppendLogRejectSuspend
	if Entry["type"] = "idle_end"
		_Stub_AppendLogRejectSuspend := true
}

_KLSCR_RetryPartialClose(Mode) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	Saved := Map()
	for Name in ["is_idle", "idle_started_at", "is_session_active", "session_started_at",
		"session_generation", "idle_generation",
		"last_authorized_tick", "privacy_interrupted", "privacy_started_at", "system_events",
		"system_failure_reported", "wts_registered", "wts_failure_reported", "wts_retry_timer",
		"session_close", "session_close_draining", "idle_close"] {
		if KLWatch.HasOwnProp(Name)
			Saved[Name] := KLWatch.%Name%
	}
	SavedHookState := Map()
	for Name in ["last_tick", "app_entered_at", "title_entered_at"]
		SavedHookState[Name] := KLHook.%Name%
	SavedInitialized := Keylogger.initialized
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedHook := _Stub_AppendLogHook
	try {
		AssertFalse(KLWatch.HasOwnProp("idle_check_timer"), "the fixture must not stop a live timer")
		AssertFalse(KLWatch.HasOwnProp("session_msg_handler"), "the fixture must not detach live callbacks")
		AssertFalse(KLWatch.HasOwnProp("power_msg_handler"), "the fixture must not detach live callbacks")
		KLWatch.system_events := false
		KLWatch.wts_registered := false
		KLWatch.wts_retry_timer := false
		KLWatch.privacy_interrupted := false
		KLWatch.is_idle := false
		KLWatch.is_session_active := true
		KLHook.last_tick := 1000
		Observation := KLHook.last_tick + KLWatchConst.SESSION_TIMEOUT_MS + 10000
		KLHook.app_entered_at := 0
		KLHook.title_entered_at := 0
		KLWatch.last_authorized_tick := KLHook.last_tick
		KLWatch.session_started_at := KLHook.last_tick - 1000
		Keylogger.initialized := true
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := _KLSCR_RefuseAfterIdle
		KL_Watchers_IdleTick(Observation)
		AssertEqual(2, _Stub_AppendLogRows.Length)
		AssertEqual("idle_start", _Stub_AppendLogRows[1]["type"])
		AssertEqual("idle_end", _Stub_AppendLogRows[2]["type"])
		AssertTrue(KLWatch.is_session_active, "the refused session close must remain owned")
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		if Mode = "timer"
			KL_Watchers_IdleTick(Observation + 1000)
		else if Mode = "key"
			AssertTrue(KL_Watchers_OnKeystroke(0, Observation + 1000))
		else
			AssertTrue(KL_Watchers_Stop())
		AssertEqual(Mode = "key" ? 4 : 3, _Stub_AppendLogRows.Length,
			"retry must publish only the missing session close and any new session")
		AssertEqual("session_end", _Stub_AppendLogRows[3]["type"])
		AssertEqual(1000, _Stub_AppendLogRows[3]["duration_ms"], "retry must preserve the original closing boundary")
		if Mode = "key"
			AssertEqual("session_start", _Stub_AppendLogRows[4]["type"])
		else
			AssertFalse(KLWatch.is_session_active)
	} finally {
		for Name, Value in Saved
			KLWatch.%Name% := Value
		for Name, Value in SavedHookState
			KLHook.%Name% := Value
		Keylogger.initialized := SavedInitialized
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedHook
	}
}
for Mode in ["timer", "key", "stop"]
	Test("keylogger session: partial close recovers through " . Mode
		. " (keylogger-session-close-retry)", _KLSCR_RetryPartialClose.Bind(Mode))

_KLSCR_ClosePort(State, Kind, Duration, Commit) {
	if State["mode"] = "refuse"
		return false
	State["rows"].Push(Map("kind", Kind, "duration", Duration))
	Commit.Call()
	if State["mode"] = "throw-after"
		throw Error("synthetic failure after committed close")
	return true
}

_KLSCR_FrozenClose(Mode) {
	Saved := Map()
	for Name in ["is_idle", "idle_started_at", "is_session_active", "session_started_at",
		"session_generation", "idle_generation",
		"session_close", "session_close_draining", "idle_close"]
		Saved[Name] := KLWatch.%Name%
	try {
		KLWatch.session_close := false
		KLWatch.session_close_draining := false
		KLWatch.is_idle := true
		KLWatch.idle_started_at := 150
		KLWatch.is_session_active := true
		KLWatch.session_started_at := 100
		State := Map("mode", Mode, "rows", [])
		Port := _KLSCR_ClosePort.Bind(State)
		if Mode = "throw-after" {
			Caught := false
			try _KL_Watchers_CloseSession(200, 300, Port)
			catch Error
				Caught := true
			AssertTrue(Caught, "the injected post-commit failure must execute")
		} else
			AssertFalse(_KL_Watchers_CloseSession(200, 300, Port))
		AssertFalse(KLWatch.session_close_draining, "a failed attempt must release its drain guard")
		State["mode"] := "ok"
		AssertTrue(_KL_Watchers_CloseSession(9000, 9000, Port))
		AssertEqual(2, State["rows"].Length, "each closing record must be accepted once")
		AssertEqual("idle_end", State["rows"][1]["kind"])
		AssertEqual(150, State["rows"][1]["duration"], "retry cannot extend idle time")
		AssertEqual("session_end", State["rows"][2]["kind"])
		AssertEqual(100, State["rows"][2]["duration"], "retry cannot extend session time")
		AssertFalse(IsObject(KLWatch.session_close))
	} finally {
		for Name, Value in Saved
			KLWatch.%Name% := Value
	}
}
for Mode in ["refuse", "throw-after"]
	Test("keylogger session: closing boundaries survive " . Mode
		. " (keylogger-session-close-retry)", _KLSCR_FrozenClose.Bind(Mode))

_KLSCR_ShortIdleRetry(Mode) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	Saved := Map()
	for Name in ["is_idle", "idle_started_at", "is_session_active", "session_started_at",
		"session_generation", "idle_generation",
		"last_authorized_tick", "privacy_interrupted", "privacy_started_at", "system_events",
		"system_failure_reported", "wts_registered", "wts_failure_reported", "wts_retry_timer",
		"session_close", "session_close_draining", "idle_close"] {
		if KLWatch.HasOwnProp(Name)
			Saved[Name] := KLWatch.%Name%
	}
	SavedHookState := Map()
	for Name in ["last_tick", "app_entered_at", "title_entered_at"]
		SavedHookState[Name] := KLHook.%Name%
	SavedInitialized := Keylogger.initialized
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedHook := _Stub_AppendLogHook
	try {
		AssertFalse(KLWatch.HasOwnProp("idle_check_timer"), "the fixture must not stop a live timer")
		AssertFalse(KLWatch.HasOwnProp("session_msg_handler"), "the fixture must not detach live callbacks")
		AssertFalse(KLWatch.HasOwnProp("power_msg_handler"), "the fixture must not detach live callbacks")
		KLWatch.system_events := false
		KLWatch.wts_registered := false
		KLWatch.wts_retry_timer := false
		KLWatch.privacy_interrupted := false
		KLWatch.session_close := false
		KLWatch.session_close_draining := false
		StartedAt := Mode = "native32-boundary" ? 0xFFFFFFF0 : 0
		Boundary := StartedAt + 100
		KLWatch.is_idle := true
		KLWatch.idle_started_at := StartedAt
		KLWatch.is_session_active := true
		KLWatch.session_started_at := StartedAt
		KLWatch.last_authorized_tick := StartedAt
		KLHook.last_tick := Boundary
		KLHook.app_entered_at := StartedAt
		KLHook.title_entered_at := StartedAt
		Keylogger.initialized := true
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := false
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		AssertFalse(KL_Watchers_OnKeystroke(0, Boundary))
		AssertEqual(0, _Stub_AppendLogRows.Length)
		_Stub_AppendLogAccept := true
		if Mode = "timer"
			KL_Watchers_IdleTick(Boundary + 800)
		else if Mode = "stop" {
			; Keep the injected resume boundary authoritative even on a fresh host.
			KL_Watchers_OnPrivateKeystroke(Boundary)
			AssertTrue(KL_Watchers_Stop())
		}
		else if Mode = "timeout"
			AssertTrue(KL_Watchers_OnKeystroke(0,
				Boundary + KLWatchConst.SESSION_TIMEOUT_MS + 10))
		else if Mode = "private" {
			KL_Watchers_OnPrivateKeystroke(Boundary + 100)
			AssertTrue(KL_Watchers_OnKeystroke(0, Boundary + 800))
		}
		else
			AssertTrue(KL_Watchers_OnKeystroke(0, Boundary + 800))
		ExpectedCount := Mode = "stop" ? 2 : Mode = "timeout" || Mode = "private" ? 3 : 1
		AssertEqual(ExpectedCount, _Stub_AppendLogRows.Length)
		AssertEqual("idle_end", _Stub_AppendLogRows[1]["type"])
		AssertEqual(100, _Stub_AppendLogRows[1]["duration_ms"], "short idle retry must retain the first resume")
		if Mode = "stop" || Mode = "timeout" || Mode = "private" {
			AssertEqual("session_end", _Stub_AppendLogRows[2]["type"])
			if Mode = "timeout" || Mode = "private" {
				AssertEqual(Mode = "private" ? 200 : 100, _Stub_AppendLogRows[2]["duration_ms"],
					"session closing must respect authorized activity and privacy boundaries")
				AssertEqual("session_start", _Stub_AppendLogRows[3]["type"])
			} else
				AssertFalse(KLWatch.is_session_active, "Stop must also close the still-active session")
		} else
			AssertTrue(KLWatch.is_session_active, "short idle completion must not split the session")
	} finally {
		for Name, Value in Saved
			KLWatch.%Name% := Value
		for Name, Value in SavedHookState
			KLHook.%Name% := Value
		Keylogger.initialized := SavedInitialized
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedHook
	}
}
for Mode in ["key", "timer", "stop", "timeout", "private", "native32-boundary"]
	Test("keylogger idle: refused resume recovers through " . Mode
		. " (keylogger-idle-resume-retry)", _KLSCR_ShortIdleRetry.Bind(Mode))


; Native A_TickCount is GetTickCount64. A legal long silence must not become
; recent activity, and accepted close records must retain their full duration.
_KLSCR_Native64Scope(Run) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	Saved := Map()
	for Name in ["is_idle", "idle_started_at", "is_session_active", "session_started_at",
		"session_generation", "idle_generation",
		"last_authorized_tick", "privacy_interrupted", "privacy_started_at", "system_events",
		"session_close", "session_close_draining", "idle_close"]
		Saved[Name] := KLWatch.%Name%
	SavedHook := Map()
	for Name in ["last_tick", "app_entered_at", "title_entered_at"]
		SavedHook[Name] := KLHook.%Name%
	SavedInitialized := Keylogger.initialized
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedAppendHook := _Stub_AppendLogHook
	try {
		AssertFalse(KLWatch.HasOwnProp("idle_check_timer"), "the fixture cannot own a live timer")
		AssertFalse(KLWatch.HasOwnProp("session_msg_handler"), "the fixture cannot own native messages")
		AssertFalse(KLWatch.HasOwnProp("power_msg_handler"), "the fixture cannot own native messages")
		for Name in ["is_idle", "is_session_active", "privacy_interrupted", "system_events",
			"session_close", "session_close_draining", "idle_close"]
			KLWatch.%Name% := false
		for Name in ["idle_started_at", "session_started_at", "last_authorized_tick", "privacy_started_at"]
			KLWatch.%Name% := 0
		; Session fixtures own no foreground interval to compensate.
		for Name in ["last_tick", "app_entered_at", "title_entered_at"]
			KLHook.%Name% := 0
		Keylogger.initialized := true
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		Run.Call()
	} finally {
		for Name, Value in Saved
			KLWatch.%Name% := Value
		for Name, Value in SavedHook
			KLHook.%Name% := Value
		Keylogger.initialized := SavedInitialized
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedAppendHook
	}
}

_KLSCR_Native64Key(Origin, LongGap, Offset) {
	global _Stub_AppendLogRows
	Gap := (LongGap ? 0x100000000 : 0) + KLWatchConst.SESSION_TIMEOUT_MS + Offset
	_KL_Watchers_CommitSessionStart(Origin - 1000)
	KLWatch.last_authorized_tick := Origin
	AssertTrue(KL_Watchers_OnKeystroke(0, Origin + Gap))
	Expired := LongGap || Offset >= 0
	AssertEqual(Expired ? 2 : 0, _Stub_AppendLogRows.Length,
		"a long native silence cannot leave the old session active")
	if Expired {
		AssertEqual("session_end", _Stub_AppendLogRows[1]["type"])
		AssertEqual(1000, _Stub_AppendLogRows[1]["duration_ms"], "silence cannot count as authorized time")
		AssertEqual("session_start", _Stub_AppendLogRows[2]["type"])
		AssertEqual(Origin + Gap, KLWatch.session_started_at)
	} else
		AssertEqual(Origin - 1000, KLWatch.session_started_at)
	AssertEqual(Origin + Gap, KLWatch.last_authorized_tick)
}
for _KLSCR_Native64Origin in [100000000, 0xFFFFFFF0] {
	for _KLSCR_Native64Long in [false, true] {
		for _KLSCR_Native64Offset in [-1, 0, 1]
			Test("Keylogger native64: accepted origin=" . _KLSCR_Native64Origin
				. " long=" . _KLSCR_Native64Long . " expiry=" . _KLSCR_Native64Offset
				. " (keylogger-watcher-native64)", _KLSCR_Native64Scope.Bind(
					_KLSCR_Native64Key.Bind(_KLSCR_Native64Origin, _KLSCR_Native64Long, _KLSCR_Native64Offset)))
	}
}

_KLSCR_Native64Idle(LongGap, Threshold, Offset) {
	global _Stub_AppendLogRows
	Origin := 0xFFFFFFF0
	Gap := (LongGap ? 0x100000000 : 0) + Threshold + Offset
	KLHook.last_tick := Origin
	_KL_Watchers_CommitSessionStart(Origin - 1000)
	KL_Watchers_IdleTick(Origin + Gap)
	Expired := LongGap || Gap >= KLWatchConst.SESSION_TIMEOUT_MS
	Started := Expired || Gap >= KLWatchConst.MICRO_IDLE_TIMEOUT_MS
	AssertEqual(Expired ? 3 : Started ? 1 : 0, _Stub_AppendLogRows.Length,
		"the periodic owner must classify the full physical silence")
	if Started {
		AssertEqual("idle_start", _Stub_AppendLogRows[1]["type"])
		AssertEqual(Origin, KLWatch.idle_started_at)
	}
	if Expired {
		AssertEqual("idle_end", _Stub_AppendLogRows[2]["type"])
		AssertEqual(Gap, _Stub_AppendLogRows[2]["duration_ms"])
		AssertEqual("session_end", _Stub_AppendLogRows[3]["type"])
		AssertEqual(1000, _Stub_AppendLogRows[3]["duration_ms"])
		AssertFalse(KLWatch.is_session_active)
		AssertFalse(KLWatch.is_idle)
	}
}
for _KLSCR_Native64Long in [false, true] {
	for _KLSCR_Native64Threshold in [KLWatchConst.MICRO_IDLE_TIMEOUT_MS, KLWatchConst.SESSION_TIMEOUT_MS] {
		for _KLSCR_Native64Offset in [-1, 0, 1]
			Test("Keylogger native64: periodic long=" . _KLSCR_Native64Long
				. " threshold=" . _KLSCR_Native64Threshold . " offset=" . _KLSCR_Native64Offset
				. " (keylogger-watcher-native64)", _KLSCR_Native64Scope.Bind(
					_KLSCR_Native64Idle.Bind(_KLSCR_Native64Long, _KLSCR_Native64Threshold, _KLSCR_Native64Offset)))
	}
}

_KLSCR_Native64EndIdle(LongGap, Refuse) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept
	Origin := 100000000
	Duration := (LongGap ? 0x100000000 : 0) + 17
	_KL_Watchers_CommitIdleStart(Origin)
	_Stub_AppendLogAccept := !Refuse
	AssertEqual(!Refuse, _KL_Watchers_EndIdle(Origin + Duration))
	if Refuse {
		AssertEqual(Duration, KLWatch.idle_close["duration"], "the first refused boundary remains owned")
		AssertFalse(KLWatch.session_close_draining)
		_Stub_AppendLogAccept := true
		AssertTrue(_KL_Watchers_EndIdle(0), "retry consumes the retained record, not a new zero boundary")
	}
	AssertEqual(1, _Stub_AppendLogRows.Length)
	AssertEqual(Duration, _Stub_AppendLogRows[1]["duration_ms"])
	AssertFalse(KLWatch.is_idle)
	AssertFalse(IsObject(KLWatch.idle_close))
}
for _KLSCR_Native64Long in [false, true] {
	for _KLSCR_Native64Refuse in [false, true]
		Test("Keylogger native64: idle record long=" . _KLSCR_Native64Long
			. " refusal=" . _KLSCR_Native64Refuse . " (keylogger-watcher-native64)",
			_KLSCR_Native64Scope.Bind(_KLSCR_Native64EndIdle.Bind(_KLSCR_Native64Long, _KLSCR_Native64Refuse)))
}

_KLSCR_Native64AfterIdle(Mode, Entry) {
	global _Stub_AppendLogRejectSuspend
	if Entry["type"] != "idle_end"
		return
	if Mode = "partial"
		_Stub_AppendLogRejectSuspend := true
	else
		throw Error("owned failure after idle acceptance")
}

_KLSCR_Native64Close(LongGap, Mode) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	Origin := 100000000
	Span := LongGap ? 0x100000000 : 0
	_KL_Watchers_CommitSessionStart(Origin)
	_KL_Watchers_CommitIdleStart(Origin + 50)
	_Stub_AppendLogAccept := Mode != "refuse"
	if Mode = "partial" || Mode = "throw"
		_Stub_AppendLogHook := _KLSCR_Native64AfterIdle.Bind(Mode)
	if Mode = "throw" {
		Caught := false
		try _KL_Watchers_CloseSession(Origin + Span + 100, Origin + Span + 200)
		catch Error
			Caught := true
		AssertTrue(Caught, "the post-acceptance failure must execute")
	} else
		AssertEqual(Mode = "ok", _KL_Watchers_CloseSession(Origin + Span + 100, Origin + Span + 200))
	AssertFalse(KLWatch.session_close_draining)
	if Mode != "ok" {
		AssertTrue(IsObject(KLWatch.session_close))
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		AssertTrue(_KL_Watchers_CloseSession(0, 0), "retry cannot replace frozen first boundaries")
	}
	AssertEqual(2, _Stub_AppendLogRows.Length, "partial acceptance cannot duplicate records")
	AssertEqual("idle_end", _Stub_AppendLogRows[1]["type"])
	AssertEqual(Span + 150, _Stub_AppendLogRows[1]["duration_ms"])
	AssertEqual("session_end", _Stub_AppendLogRows[2]["type"])
	AssertEqual(Span + 100, _Stub_AppendLogRows[2]["duration_ms"])
	AssertFalse(IsObject(KLWatch.session_close))
	AssertFalse(KLWatch.is_session_active)
	AssertFalse(KLWatch.is_idle)
}
for _KLSCR_Native64Long in [false, true] {
	for _KLSCR_Native64Mode in ["ok", "refuse", "partial", "throw"]
		Test("Keylogger native64: close records long=" . _KLSCR_Native64Long
			. " mode=" . _KLSCR_Native64Mode . " (keylogger-watcher-native64)",
			_KLSCR_Native64Scope.Bind(_KLSCR_Native64Close.Bind(_KLSCR_Native64Long, _KLSCR_Native64Mode)))
}

_KLSCR_Native64Sql() {
	global _Stub_AppendLogRows
	Origin := 100000000
	_KL_Watchers_CommitSessionStart(Origin)
	_KL_Watchers_CommitIdleStart(Origin + 50)
	AssertTrue(_KL_Watchers_CloseSession(Origin + 0x100000000 + 100,
		Origin + 0x100000000 + 200))
	Db := _KLRManifest_OpenFixture()
	SavedDevice := Keylogger._device_id_lit
	try {
		Keylogger._device_id_lit := SQLite_Q("owned-watcher-native64")
		for Index, Entry in _Stub_AppendLogRows {
			Entry["timestamp"] := "2026-10-04T12:00:00.000"
			AssertTrue(SQLite_Exec(Db, KL_BuildInsertSession(Entry, Index, Entry["type"])))
		}
		Rows := SQLite_Query(Db, "SELECT kind,duration_ms FROM events_session ORDER BY id")
		AssertEqual(2, Rows.Length)
		AssertEqual("idle_end", Rows[1]["kind"])
		AssertEqual(4294967446, Rows[1]["duration_ms"], "the canonical SQL receipt cannot truncate idle time")
		AssertEqual("session_end", Rows[2]["kind"])
		AssertEqual(4294967396, Rows[2]["duration_ms"], "the canonical SQL receipt cannot truncate session time")
	} finally {
		Keylogger._device_id_lit := SavedDevice
		SQLite_Close(Db)
	}
}
Test("Keylogger native64: accepted close records survive real SQLite serialization (keylogger-watcher-native64)",
	_KLSCR_Native64Scope.Bind(_KLSCR_Native64Sql))

_KLSCR_Native64Default(Periodic) {
	global _Stub_AppendLogRows
	SavedSynthetic := Keylogger.synth_active
	try {
		Keylogger.synth_active := false
		BeforeStart := A_TickCount
		KL_Hook_NoteActivity()
		AfterStart := A_TickCount
		AssertEqual(1, _Stub_AppendLogRows.Length, "fresh accepted physical activity must initialize the session")
		AssertEqual("session_start", _Stub_AppendLogRows[1]["type"])
		Origin := KLWatch.session_started_at
		AssertTrue(BeforeStart <= Origin && Origin <= AfterStart,
			"the accepted owner must publish its fresh native sample")
		AssertEqual(Origin, KLWatch.last_authorized_tick)
		AssertEqual(Origin, KLHook.last_tick, "the physical and accepted owners share that native sample")
		_Stub_AppendLogRows := []
		Before := A_TickCount
		if Periodic
			KL_Watchers_IdleTick()
		else
			AssertTrue(KL_Watchers_OnKeystroke())
		After := A_TickCount
		if !Periodic {
			Observed := KLWatch.last_authorized_tick
			AssertTrue(Before <= Observed && Observed <= After,
				"omitting Now must observe a fresh native tick at any uptime")
			Expired := Observed - Origin >= KLWatchConst.SESSION_TIMEOUT_MS
			AssertEqual(Expired ? 2 : 0, _Stub_AppendLogRows.Length)
			if Expired {
				AssertEqual("session_end", _Stub_AppendLogRows[1]["type"])
				AssertEqual(0, _Stub_AppendLogRows[1]["duration_ms"])
				AssertEqual("session_start", _Stub_AppendLogRows[2]["type"])
			}
			return
		}
		; A physical zero is deliberately absent even when the accepted session
		; owns a genuine zero origin. Otherwise bracket the private final sample.
		if Origin = 0 {
			AssertEqual(0, _Stub_AppendLogRows.Length)
			return
		}
		Lower := Before - Origin
		Upper := After - Origin
		LowerCount := Lower >= KLWatchConst.SESSION_TIMEOUT_MS ? 3
			: Lower >= KLWatchConst.MICRO_IDLE_TIMEOUT_MS ? 1 : 0
		UpperCount := Upper >= KLWatchConst.SESSION_TIMEOUT_MS ? 3
			: Upper >= KLWatchConst.MICRO_IDLE_TIMEOUT_MS ? 1 : 0
		AssertTrue(_Stub_AppendLogRows.Length = 0 || _Stub_AppendLogRows.Length = 1 || _Stub_AppendLogRows.Length = 3,
			"only no transition, idle start or the complete ordered close is valid")
		AssertTrue(LowerCount <= _Stub_AppendLogRows.Length && _Stub_AppendLogRows.Length <= UpperCount,
			"native periodic classification must remain inside the observation bracket")
		if _Stub_AppendLogRows.Length {
			AssertEqual("idle_start", _Stub_AppendLogRows[1]["type"])
			AssertEqual(Origin, KLWatch.idle_started_at)
		}
		if _Stub_AppendLogRows.Length = 3 {
			AssertEqual("idle_end", _Stub_AppendLogRows[2]["type"])
			Duration := _Stub_AppendLogRows[2]["duration_ms"]
			AssertTrue(Lower <= Duration && Duration <= Upper)
			AssertEqual("session_end", _Stub_AppendLogRows[3]["type"])
			AssertEqual(0, _Stub_AppendLogRows[3]["duration_ms"])
			AssertFalse(KLWatch.is_session_active)
		}
	} finally Keylogger.synth_active := SavedSynthetic
}
for _KLSCR_Native64Periodic in [false, true]
	Test("Keylogger native64: omitted native clock periodic=" . _KLSCR_Native64Periodic
		. " (keylogger-watcher-native64)", _KLSCR_Native64Scope.Bind(_KLSCR_Native64Default.Bind(_KLSCR_Native64Periodic)))

_KLSCR_Native64Refusal(Mode) {
	global _Stub_AppendLogRows
	Origin := 100000000
	_KL_Watchers_CommitSessionStart(Origin)
	KLHook.last_tick := Mode = "synthetic-zero" ? 0 : Origin
	if Mode = "inactive"
		Keylogger.initialized := false
	else if Mode = "private"
		KL_Watchers_OnPrivateKeystroke(Origin + 17)
	else if Mode = "draining"
		KLWatch.session_close_draining := true
	KL_Watchers_IdleTick(Origin + 0x100000000 + 300001)
	AssertEqual(0, _Stub_AppendLogRows.Length)
	AssertTrue(KLWatch.is_session_active, "absence or privacy cannot acquire closing authority")
}
for _KLSCR_Native64Mode in ["synthetic-zero", "inactive", "private", "draining"]
	Test("Keylogger native64: periodic refusal=" . _KLSCR_Native64Mode . " (keylogger-watcher-native64)",
		_KLSCR_Native64Scope.Bind(_KLSCR_Native64Refusal.Bind(_KLSCR_Native64Mode)))

_KLSCR_Native64Invalid(Mode) {
	global _Stub_AppendLogRows
	_KL_Watchers_CommitSessionStart(100)
	_KL_Watchers_CommitIdleStart(150)
	Rejected := false
	try {
		if Mode = "idle"
			_KL_Watchers_EndIdle(149)
		else if Mode = "close"
			_KL_Watchers_CloseSession(99, 200)
		else {
			KLHook.last_tick := 100
			KL_Watchers_IdleTick(99)
		}
	} catch ValueError {
		Rejected := true
	}
	AssertTrue(Rejected, "the canonical clock owner must reject a backwards observation with ValueError")
	AssertEqual(0, _Stub_AppendLogRows.Length, "invalid clocks cannot publish a successful record")
	AssertFalse(KLWatch.session_close_draining, "invalid arithmetic must release the drain claim")
	AssertFalse(IsObject(KLWatch.session_close))
	AssertFalse(IsObject(KLWatch.idle_close))
	AssertTrue(KLWatch.is_session_active)
	AssertTrue(KLWatch.is_idle)
}
for _KLSCR_Native64Mode in ["idle", "close", "periodic"]
	Test("Keylogger native64: invalid backwards boundary=" . _KLSCR_Native64Mode
		. " (keylogger-watcher-native64-invalid)", _KLSCR_Native64Scope.Bind(_KLSCR_Native64Invalid.Bind(_KLSCR_Native64Mode)))

; Source order is a policy proof, not an atomic cross-field snapshot or timer race.
; Capture identities are derived from executable assignments so comments and
; quoted examples cannot replace the authority read before the final sample.
_KLSCR_Native64SourceMatch(Code, Pattern, Message) {
	AssertTrue(Code != "", "the watcher owner must be defined")
	Position := RegExMatch(Code, Pattern, &Found)
	AssertTrue(Position > 0, Message)
	AssertEqual(0, RegExMatch(Code, Pattern, , Position + StrLen(Found[0])),
		"each watcher authority assignment must be unique")
	return Found
}

; Count every write to a captured local, including compound assignments,
; increment/decrement and an output reference. A different RHS cannot hide it.
_KLSCR_Native64LocalWrites(Code, Name) {
	Pattern := "i)(?<![\w.])" . Name . "\h*(?::=|\+=|-=|\*=|/=|//=|\*\*=|<<=|>>=|>>>=|&=|\|=|\^=|\.=|\+\+|--)"
		. "|(?<![\w.])(?:\+\+|--)\h*" . Name . "\b|(?<!&)&\h*" . Name . "\b"
	Writes := []
	; A default parameter declaration is not a body rebinding.
	Position := InStr(Code, "{") + 1
	while RegExMatch(Code, Pattern, &Found, Position) {
		Writes.Push(Found)
		Position := Found.Pos + Found.Len
	}
	return Writes
}

_KLSCR_Native64PrivacyBody(Code) {
	Branch := _KLSCR_Native64SourceMatch(Code,
		"im)^\h*if\h+KLWatch\.privacy_interrupted\h*\{\h*$", "the privacy reset must have one owning branch")
	Open := InStr(Code, "{", , Branch.Pos)
	Depth := 1
	Loop StrLen(Code) - Open {
		Position := Open + A_Index
		Char := SubStr(Code, Position, 1)
		if Char = "{"
			Depth += 1
		else if Char = "}"
			Depth -= 1
		if Depth = 0
			return Map("body", SubStr(Code, Open + 1, Position - Open - 1), "offset", Open)
	}
	throw Error("the privacy reset branch must close")
}

_KLSCR_Native64SourceOrder(Body, Periodic) {
	AssertTrue(Body != "", "the watcher timing owner must be readable")
	Body := _DriverMaskNonCode(&Body)
	Authority := Periodic ? "KLHook\.last_tick" : "KLWatch\.last_authorized_tick"
	Capture := _KLSCR_Native64SourceMatch(Body,
		"im)^\h*(\w+)\h*:=\h*" . Authority . "\h*$", "the actual origin must be captured")
	Clock := _KLSCR_Native64SourceMatch(Body,
		"im)^\h*(\w+)\h*:=\h*IsSet\(Now\)\h*\?\h*Now\h*:\h*A_TickCount\h*$",
		"the unchanged omitted clock must remain native")
	Gap := _KLSCR_Native64SourceMatch(Body,
		"im)^\h*(\w+)\h*:=\h*TickElapsed64\(" . Capture[1] . ",\h*" . Clock[1] . "\)\h*$",
		"elapsed time must consume the captured authority and final sample")
	AssertTrue(Capture.Pos < Clock.Pos && Clock.Pos < Gap.Pos,
		"the native sample must follow the authority lookup")
	Names := Map()
	for Assignment in [Capture, Clock, Gap] {
		Name := StrLower(Assignment[1])
		AssertFalse(Names.Has(Name), "origin, clock and elapsed require distinct locals")
		Names[Name] := true
		Writes := _KLSCR_Native64LocalWrites(Body, Name)
		AssertEqual(!Periodic && Assignment = Capture ? 2 : 1, Writes.Length,
			"captured locals cannot acquire another write, irrespective of case or RHS")
		AssertTrue(Assignment.Pos <= Writes[1].Pos && Writes[1].Pos < Assignment.Pos + Assignment.Len,
			"the first local write must be the captured assignment")
	}
	if !Periodic {
		Privacy := _KLSCR_Native64PrivacyBody(Body)
		Reset := _KLSCR_Native64SourceMatch(Privacy["body"],
			"im)^\h*" . Capture[1] . "\h*:=\h*0\h*$", "only the owned privacy branch may reset authorization")
		Writes := _KLSCR_Native64LocalWrites(Body, Capture[1])
		ResetPosition := Privacy["offset"] + Reset.Pos
		AssertTrue(ResetPosition <= Writes[2].Pos && Writes[2].Pos < ResetPosition + Reset.Len,
			"the second local write must be the actual privacy reset")
		AssertTrue(Clock.Pos < ResetPosition && ResetPosition < Gap.Pos,
			"the privacy reset must precede elapsed classification after sampling")
	}
	if Periodic {
		AssertEqual(0, RegExMatch(SubStr(Body, Clock.Pos), "i)KLHook\.last_tick"),
			"publication cannot retarget a new physical origin after sampling")
		_KLSCR_Native64SourceMatch(Body,
			"im)^\h*_KL_Watchers_CommitIdleStart\.Bind\(" . Capture[1] . "\)\)\h*$",
			"idle publication must use the same captured origin")
		_KLSCR_Native64SourceMatch(Body,
			"im)^\h*return\h+_KL_Watchers_CloseSession\(" . Capture[1] . ",\h*" . Clock[1] . "\)\h*$",
			"session close must use the same captured origin and sample")
	}
}

_KLSCR_Native64Order(Periodic) {
	_KLSCR_Native64SourceOrder(_DriverFuncBody(Periodic ? "KL_Watchers_IdleTick" : "KL_Watchers_OnKeystroke"), Periodic)
}
for _KLSCR_Native64Periodic in [false, true]
	Test("Keylogger native64: capture protocol periodic=" . _KLSCR_Native64Periodic
		. " (keylogger-watcher-native64-order)", _KLSCR_Native64Order.Bind(_KLSCR_Native64Periodic))

; Mutation controls must fail the source assertion, not an unset closure variable.
_KLSCR_Native64Rejected(Body, Periodic) {
	Rejected := false
	try _KLSCR_Native64SourceOrder(Body, Periodic)
	catch Error as Failure {
		AssertEqual("Error", Type(Failure), "the actual source assertion must reject the mutation")
		Rejected := true
	}
	AssertTrue(Rejected, "a source mutation cannot satisfy the capture protocol")
}

_KLSCR_Native64OrderMutations(Periodic) {
	Body := _DriverFuncBody(Periodic ? "KL_Watchers_IdleTick" : "KL_Watchers_OnKeystroke")
	_KLSCR_Native64SourceOrder(Body, Periodic)
	Code := _DriverMaskNonCode(&Body)
	Authority := Periodic ? "KLHook\.last_tick" : "KLWatch\.last_authorized_tick"
	Capture := _KLSCR_Native64SourceMatch(Code,
		"im)^\h*(\w+)\h*:=\h*" . Authority . "\h*$", "the capture mutation owner must exist")
	ClockAssignment := _KLSCR_Native64SourceMatch(Code,
		"im)^\h*(\w+)\h*:=\h*IsSet\(Now\)\h*\?\h*Now\h*:\h*A_TickCount\h*$",
		"the clock mutation owner must exist")
	Line := Trim(SubStr(Body, Capture.Pos, Capture.Len), " `t`r`n")
	Clock := Trim(SubStr(Body, ClockAssignment.Pos, ClockAssignment.Len), " `t`r`n")
	StrReplace(Body, Line, "", false, &LineCount)
	StrReplace(Body, Clock, "", false, &ClockCount)
	AssertEqual(1, LineCount)
	AssertEqual(1, ClockCount)
	Spoofs := ["Ignored := '" . Line . "'", "Ignored := 1 `; " . Line,
		"/*`n" . Line . "`n*/", Line . "`n" . Line]
	for Spoof in Spoofs {
		Changed := StrReplace(Body, Line, Spoof)
		_KLSCR_Native64Rejected(Changed, Periodic)
	}
	Changed := StrReplace(Body, Clock, "")
	Changed := Clock . "`n" . Changed
	_KLSCR_Native64Rejected(Changed, Periodic)
	Changed := StrReplace(Body, Clock, Clock . "`n" . Clock)
	_KLSCR_Native64Rejected(Changed, Periodic)
	for Name in [Capture[1], StrUpper(Capture[1]), ClockAssignment[1], StrUpper(ClockAssignment[1])] {
		for Operation in [" := 0", " += 1", "++"] {
			Changed := StrReplace(Body, Clock, Clock . "`n" . Name . Operation)
			_KLSCR_Native64Rejected(Changed, Periodic)
		}
	}
	Changed := StrReplace(Body, Clock, Clock . "`nIgnored(&" . Capture[1] . ")")
	_KLSCR_Native64Rejected(Changed, Periodic)
	if !Periodic {
		Reset := Capture[1] . " := 0"
		StrReplace(Body, Reset, "", false, &ResetCount)
		AssertEqual(1, ResetCount)
		for Replacement in [Capture[1] . " := 1", "Ignored := '" . Reset . "'", "Ignored := 1 `; " . Reset] {
			Changed := StrReplace(Body, Reset, Replacement)
			_KLSCR_Native64Rejected(Changed, Periodic)
		}
		Changed := StrReplace(Body, Reset, "")
		Changed := StrReplace(Changed, Clock, Clock . "`n" . Reset)
		_KLSCR_Native64Rejected(Changed, Periodic)
	}
	; Prose mentioning the same origin cannot make a valid capture ambiguous.
	_KLSCR_Native64SourceOrder("/*`n" . Line . "`n*/`n" . Body, Periodic)
}
for _KLSCR_Native64Periodic in [false, true]
	Test("Keylogger native64: capture guards reject decoys periodic=" . _KLSCR_Native64Periodic
		. " (keylogger-watcher-native64-order)", _KLSCR_Native64OrderMutations.Bind(_KLSCR_Native64Periodic))

; Native physical timing retains high words; zero still means no physical key.
_KLA64_Activity(Start, Now, Expected, Synthetic := false) {
	SavedTick := KLHook.last_tick
	SavedSynth := Keylogger.synth_active
	SavedAccepted := KLWatch.last_authorized_tick
	SavedActive := KLWatch.is_session_active
	try {
		KLHook.last_tick := Start
		Keylogger.synth_active := Synthetic
		KLWatch.last_authorized_tick := 0
		KLWatch.is_session_active := true
		Delay := KL_Hook_NoteActivity(true, true, Now)
		AssertEqual(Expected, Delay, "the actual activity owner must retain the entire physical interval")
		AssertEqual(Now, KLHook.last_tick, "the accepted sample becomes the next physical origin")
		AssertEqual(0, KLWatch.last_authorized_tick, "already-noted physical input cannot acquire another accepted origin")
		AssertTrue(KLWatch.is_session_active, "accepted zero ownership survives independently of the absent physical sentinel")
	} finally {
		KLHook.last_tick := SavedTick
		Keylogger.synth_active := SavedSynth
		KLWatch.last_authorized_tick := SavedAccepted
		KLWatch.is_session_active := SavedActive
	}
}
for _KLA64_Row in [[100, 149, 49], [4294967280, 4294967330, 50],
	[100, 4294967396, 4294967296], [100, 4294967445, 4294967345],
	[100, 8589934692, 8589934592], [9007199254740992, 9007199254741023, 31],
	[0, 0, 0], [0, 4294967346, 0]]
	Test("keylogger activity native64: physical interval " . _KLA64_Row[1] . "/" . _KLA64_Row[2],
		_KLA64_Activity.Bind(_KLA64_Row*))
Test("keylogger activity native64: synthetic timing cannot truncate the physical sample",
	_KLA64_Activity.Bind(100, 4294967445, 4294967345, true))

_KLA64_Invalid(Start, Now) {
	SavedTick := KLHook.last_tick
	try {
		KLHook.last_tick := Start
		Refused := false
		try KL_Hook_NoteActivity(true, true, Now)
		catch ValueError
			Refused := true
		AssertTrue(Refused, "invalid physical clocks must fail with ValueError")
		AssertEqual(Start, KLHook.last_tick, "an invalid sample cannot publish a new physical watermark")
	} finally KLHook.last_tick := SavedTick
}
for _KLA64_Row in [[100, 99], [-1, 100], [0, -1]]
	Test("keylogger activity native64: rejects invalid origin/end " . _KLA64_Row[1] . "/" . _KLA64_Row[2],
		_KLA64_Invalid.Bind(_KLA64_Row*))

_KLA64_NativeDefaults() {
	SavedTick := KLHook.last_tick
	try {
		Start := A_TickCount
		KLHook.last_tick := Start
		Before := A_TickCount
		Delay := KL_Hook_NoteActivity(true)
		After := A_TickCount
		AssertTrue(KLHook.last_tick >= Before && KLHook.last_tick <= After,
			"ordinary omitted observations publish a fresh actual native clock")
		AssertEqual(Start = 0 ? 0 : KLHook.last_tick - Start, Delay,
			"the returned delay must consume exactly its captured origin and published sample")
	} finally KLHook.last_tick := SavedTick
}
Test("keylogger activity native64: omitted observation retains the actual native clock", _KLA64_NativeDefaults)


; The main runner uses a recording append stub. A tree-owned child instead loads
; the actual production append and teardown bodies, preserving their include
; isolation while exercising the privacy refusal that the recording stub hides.
_KLSCR_ShutdownCloseNativeChain() {
	_KLRDC_Reset()
	Script := _KLRDC_Root() . "shutdown_close_chain.ahk"
	Handle := 0
	Receipt := 0
	try {
		Source := Chr(0xFEFF) . "#Requires AutoHotkey v2.0`n#Warn All, StdOut`n"
		for Spec in [["keylogger_password.ahk", "KLPasswordCache"],
			["keylogger_watchers.ahk", "KLWatchConst"], ["keylogger_watchers.ahk", "KLWatch"]] {
			ClassSource := FileRead(A_ScriptDir . "\..\modules\keylogger\" . Spec[1], "UTF-8")
			AssertTrue(RegExMatch(ClassSource, "ms)^class " . Spec[2] . " \{.*?^\}", &NativeClass) > 0,
				"each native-chain class must come from actual production source")
			Source .= NativeClass[0] . "`n"
		}
		for Name in ["KL_AppendLog", "KL_BeginShutdown", "KL_CancelShutdown", "KL_Hook_Stop",
			"KL_CommitPwCache", "KL_TryGetPwCachedVerdict", "KL_PasswordFocusSnapshot",
			"KL_PasswordFocusTrackingStop", "KL_FreePasswordFocusCallback", "KL_IsFocusedFieldPassword",
			"MF_ShouldFilter", "MF_ShouldFilterFor", "KL_AssignStableEventId", "KL_AllocEventId",
			"KL_RecordPrivacyHit", "TickElapsed64", "_KL_Watchers_CommitSessionStart",
			"_KL_Watchers_CommitSessionEnd", "_KL_Watchers_CommitIdleStart", "_KL_Watchers_CommitIdleEnd",
			"_KL_Watchers_CommitIdleClose", "_KL_Watchers_EndIdle", "_KL_Watchers_Log",
			"_KL_Watchers_CommitClose", "_KL_Watchers_CloseSession", "KL_Watchers_OnKeystroke",
			"KL_Watchers_OnPrivateKeystroke"] {
			Body := _DriverFuncBody(Name)
			AssertTrue(Body != "", "each actual native-chain function must be present")
			Source .= Body . "`n"
		}
		Source .= '#Include ' . A_ScriptDir . '\..\modules\keylogger\keylogger_session_events.ahk' . "`n"
		Source .= '#Include ' . A_ScriptDir . '\fixtures\keylogger_shutdown_close_fixture.ahk' . "`n"
		AssertTrue(FSWriteCreateDurable(Script, Source) != 0)
		Done(Code, Out, Err) {
			Receipt := [Code, Out, Err]
		}
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script], Done)
		AssertTrue(Handle.start())
		Started := A_TickCount
		while !IsObject(Receipt) && TickElapsed(Started) < 5000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertTrue(IsObject(Receipt), "the native close fixture must complete within its owned deadline")
		AssertEqual(0, Receipt[1], Receipt[2] . Receipt[3])
		; The real ShellRunner callback removes terminal CR/LF from its capture.
		AssertEqual("frozen-close-chain: passed", Receipt[2], "the complete native receipt must match")
		AssertEqual("", Receipt[3], "the native close fixture must emit no errors or warnings")
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate())
		_KLRDC_Cleanup()
	}
}
Test("keylogger session: actual focus teardown retains only certified closes (keylogger-shutdown-close-chain)",
	_KLRDC_CheckTeardown.Bind(_KLSCR_ShutdownCloseNativeChain))

; Arrival receipts are classified on the original callback thread, then committed
; in FIFO order. Every fixture owns all state and uses only recording ports.
_KLF_WithState(Body) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend
	global _Stub_AppendLogHook, _Stub_WpmPushCalls
	Owners := [Keylogger, KLHook, KLWatch, KLPasswordCache, MetricsFocusCache, MetricsFilters]
	Fields := [["initialized", "_shutting_down", "lifecycle_generation", "buffer_events", "buffer_text",
		"synth_active", "synth_type", "synth_private", "health_privacy_hits"],
		["last_tick", "last_vk", "last_sc", "capture_queue", "capture_owner", "capture_generation", "capture_stopping"],
		["is_session_active", "session_started_at", "last_authorized_tick", "is_idle", "idle_started_at",
		"privacy_interrupted", "privacy_started_at", "session_close", "session_close_draining", "idle_close", "system_events", "system_failure_reported"],
		["generation", "focus_generation"], ["generation", "state"],
		["disabled_apps", "private_browsing", "secure_field", "system_auth"]]
	Saved := []
	for Index, Owner in Owners {
		Values := Map()
		for Field in Fields[Index]
			Values[Field] := Owner.HasOwnProp(Field) ? {present: true, value: Owner.%Field%} : {present: false}
		Saved.Push(Values)
	}
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedHook := _Stub_AppendLogHook
	SavedWpm := _Stub_WpmPushCalls
	try {
		Keylogger.initialized := true
		Keylogger._shutting_down := false
		Keylogger.lifecycle_generation := 100
		Keylogger.buffer_events := []
		Keylogger.buffer_text := ""
		Keylogger.synth_active := 0
		Keylogger.synth_type := "none"
		Keylogger.synth_private := false
		Keylogger.health_privacy_hits := 0
		KLHook.last_tick := 100
		KLHook.last_vk := 0x41
		KLHook.last_sc := 0x1E
		if KLHook.HasOwnProp("capture_queue") {
			KLHook.capture_queue := []
			KLHook.capture_owner := false
			KLHook.capture_generation := 100
			KLHook.capture_stopping := false
		}
		KLWatch.is_session_active := true
		KLWatch.session_started_at := 100
		KLWatch.last_authorized_tick := 100
		KLWatch.is_idle := false
		KLWatch.idle_started_at := 0
		KLWatch.privacy_interrupted := false
		KLWatch.privacy_started_at := 0
		KLWatch.session_close := false
		KLWatch.session_close_draining := false
		KLWatch.idle_close := false
		KLWatch.system_events := false
		KLWatch.system_failure_reported := false
		KLPasswordCache.generation := 100
		KLPasswordCache.focus_generation := 100
		MetricsFocusCache.generation := 100
		MetricsFocusCache.state := {valid: true, process_name: "owned-fifo.exe", title: "Owned FIFO",
			class: "OwnedFifo", hwnd: 1, last_at: 100, failure_reason: "", timed_out: false}
		MetricsFilters.disabled_apps := Map()
		MetricsFilters.private_browsing := false
		MetricsFilters.secure_field := false
		MetricsFilters.system_auth := false
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		_Stub_WpmPushCalls := []
		Body.Call()
	} finally {
		for Index, Owner in Owners {
			for Field, Prior in Saved[Index] {
				if Prior.present
					Owner.%Field% := Prior.value
				else if Owner.HasOwnProp(Field)
					Owner.DeleteProp(Field)
			}
		}
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedHook
		_Stub_WpmPushCalls := SavedWpm
	}
}

_KLF_Allow() {
	return false
}

_KLF_NoShortcut(*) {
	return ""
}

_KLF_Shortcut(Label, *) {
	return Label
}

_KLF_Reenter() {
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1100)
	AssertEqual(0, Keylogger.buffer_events.Length,
		"a nested ready receipt must not publish ahead of the outer unready receipt")
	AssertEqual(100, KLHook.last_tick, "classification cannot publish timing out of order")
	return false
}

_KLF_Ordered(Kind) {
	global _Stub_AppendLogRows
	switch Kind {
		case "char": KL_Hook_OnChar(0, "a", _KLF_Reenter, 1000)
		case "special": KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_Reenter, 1000, _KLF_NoShortcut)
		case "shortcut": KL_Hook_OnKeyDown(0, 0x41, 0x1E, _KLF_Reenter, 1000, _KLF_Shortcut.Bind("Ctrl+A"))
		case "special_shortcut": KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_Reenter, 1000, _KLF_Shortcut.Bind("Ctrl+Enter"))
	}
	AssertEqual(1100, KLHook.last_tick, "both original arrival timestamps survive ordered processing")
	AssertEqual(1100, KLWatch.last_authorized_tick, "the actual watcher consumes both timestamps in order")
	Rows := Keylogger.buffer_events
	if Kind = "shortcut" {
		AssertEqual(1, Rows.Length)
		AssertEqual("b", Rows[1][1])
		AssertEqual(100, Rows[1][2], "shortcut activity owns the prior tick exactly once")
	} else {
		AssertEqual(2, Rows.Length, "both observed tokens must survive without clamp or drop")
		AssertEqual(Kind = "char" ? "a" : "[ENTER]", Rows[1][1])
		AssertEqual(900, Rows[1][2])
		AssertEqual("b", Rows[2][1])
		AssertEqual(100, Rows[2][2])
	}
	if InStr(Kind, "shortcut") {
		AssertEqual(1, _Stub_AppendLogRows.Length, "the actual shortcut publication owner must run")
		AssertEqual("shortcut", _Stub_AppendLogRows[1]["type"])
		AssertEqual(Kind = "shortcut" ? "Ctrl+A" : "Ctrl+Enter", _Stub_AppendLogRows[1]["key"])
	}
}
for _KLF_Kind in ["char", "special", "shortcut", "special_shortcut"]
	Test("keylogger arrival FIFO: interrupted " . _KLF_Kind,
		_KLF_WithState.Bind(_KLF_Ordered.Bind(_KLF_Kind)))

_KLF_NewMetadata() {
	KL_Hook_OnKeyDown(0, 0x42, 0x30, _KLF_Allow, 1050, _KLF_NoShortcut)
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1100)
	return false
}

_KLF_Metadata() {
	KL_Hook_OnChar(0, "a", _KLF_NewMetadata, 1000)
	Rows := Keylogger.buffer_events
	AssertEqual(2, Rows.Length)
	AssertEqual(0x41, Rows[1][3]["kc"], "outer receipt retains its entry keycode")
	AssertEqual(0x1E, Rows[1][3]["sk"])
	AssertEqual(0x42, Rows[2][3]["kc"], "nested Char pairs with the nested arrived keydown")
	AssertEqual(0x30, Rows[2][3]["sk"])
	AssertEqual(0x42, KLHook.last_vk, "public metadata remains the latest arrived keydown")
	AssertEqual(0x30, KLHook.last_sc)
}
Test("keylogger arrival FIFO: metadata belongs to its arrival", _KLF_WithState.Bind(_KLF_Metadata))

_KLF_ChangeSynthetic() {
	Keylogger.synth_active := 1
	Keylogger.synth_type := "owned-expansion"
	Keylogger.synth_private := true
	KL_Hook_OnChar(0, "z", _KLF_Allow, 1100)
	Keylogger.synth_active := 0
	Keylogger.synth_type := "none"
	Keylogger.synth_private := false
	return false
}

_KLF_Synthetic() {
	global PI_MASK_FALLBACK_CHAR
	KL_Hook_OnChar(0, "a", _KLF_ChangeSynthetic, 1000)
	Rows := Keylogger.buffer_events
	AssertEqual(2, Rows.Length)
	AssertEqual("a", Rows[1][1])
	AssertFalse(Rows[1][3].Has("s"), "outer manual receipt stays manual")
	AssertEqual(PI_MASK_FALLBACK_CHAR, Rows[2][1])
	AssertEqual(1, Rows[2][3]["s"])
	AssertEqual("owned-expansion", Rows[2][3]["st"])
	AssertEqual(1000, KLWatch.last_authorized_tick, "queued synthetic activity cannot mutate accepted timing")
	AssertEqual(0, KLHook.last_tick, "the final synthetic receipt preserves the original physical-clock reset")
	KL_Hook_OnChar(0, "c", _KLF_Allow, 1200)
	AssertEqual("c", Keylogger.buffer_events[3][1])
	AssertEqual(0, Keylogger.buffer_events[3][2], "next physical row restarts timing after ordered synthesis")
	AssertEqual(1200, KLHook.last_tick)
}
Test("keylogger arrival FIFO: synthesis belongs to its arrival", _KLF_WithState.Bind(_KLF_Synthetic))

_KLF_ChangeFocus() {
	MetricsFocusCache.generation += 1
	return false
}

_KLF_PrivacyDowngrade() {
	KL_Hook_OnChar(0, "a", _KLF_ChangeFocus, 1000)
	AssertEqual(0, Keylogger.buffer_events.Length, "a changed identity cannot borrow an ordinary verdict")
	AssertEqual(1000, KLHook.last_tick, "unknown privacy still accounts for physical activity")
	AssertEqual(100, KLWatch.last_authorized_tick, "unknown privacy cannot acquire authorized time")
	AssertTrue(KLWatch.privacy_interrupted)
	AssertEqual(1000, KLWatch.privacy_started_at)
}
Test("keylogger arrival FIFO: changed classification identity remains private physical activity",
	_KLF_WithState.Bind(_KLF_PrivacyDowngrade))

_KLF_ChangeLifecycle() {
	Keylogger.lifecycle_generation += 1
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1100)
	return false
}

_KLF_Lifecycle() {
	KL_Hook_OnChar(0, "a", _KLF_ChangeLifecycle, 1000)
	AssertEqual(1, Keylogger.buffer_events.Length, "revoked old lifecycle cannot publish into the successor")
	AssertEqual("b", Keylogger.buffer_events[1][1])
	AssertEqual(1100, KLHook.last_tick)
	AssertEqual(1100, KLWatch.last_authorized_tick)
	AssertFalse(KL_Hook_HasPendingInput(), "revocation cannot strand a drain owner")
}
Test("keylogger arrival FIFO: lifecycle revocation leaves successor work intact", _KLF_WithState.Bind(_KLF_Lifecycle))


_KLF_Ordinary(Kind) {
	global _Stub_AppendLogRows
	switch Kind {
		case "char": KL_Hook_OnChar(0, "a", _KLF_Allow, 1000)
		case "special": KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_Allow, 1000, _KLF_NoShortcut)
		case "shortcut": KL_Hook_OnKeyDown(0, 0x41, 0x1E, _KLF_Allow, 1000, _KLF_Shortcut.Bind("Ctrl+A"))
		case "special_shortcut": KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_Allow, 1000, _KLF_Shortcut.Bind("Ctrl+Enter"))
	}
	AssertEqual(1000, KLHook.last_tick)
	AssertEqual(1000, KLWatch.last_authorized_tick)
	AssertEqual(Kind = "shortcut" ? 0 : 1, Keylogger.buffer_events.Length)
	if Kind != "shortcut"
		AssertEqual(900, Keylogger.buffer_events[1][2])
	AssertEqual(InStr(Kind, "shortcut") ? 1 : 0, _Stub_AppendLogRows.Length)
	AssertFalse(KL_Hook_HasPendingInput(), "every completed ordinary receipt releases its lease")
}
for _KLF_Kind in ["char", "special", "shortcut", "special_shortcut"]
	Test("keylogger arrival FIFO: ordinary " . _KLF_Kind,
		_KLF_WithState.Bind(_KLF_Ordinary.Bind(_KLF_Kind)))

_KLF_IdleDuringClassification() {
	global _Stub_AppendLogRows
	KL_Watchers_IdleTick(35101)
	AssertFalse(KLWatch.is_idle, "a timer cannot classify inactivity while the just-arrived head is unready")
	AssertEqual(0, _Stub_AppendLogRows.Length, "pending classification cannot publish a premature idle_start")
	return false
}

_KLF_PendingIdle() {
	global _Stub_AppendLogRows
	KL_Hook_OnChar(0, "a", _KLF_IdleDuringClassification, 35100)
	AssertEqual(1, Keylogger.buffer_events.Length)
	AssertEqual(35000, Keylogger.buffer_events[1][2])
	AssertFalse(KL_Hook_HasPendingInput(), "completion makes later timer checks eligible")
	KL_Watchers_IdleTick(35102)
	AssertFalse(KLWatch.is_idle)
	AssertEqual(0, _Stub_AppendLogRows.Length)
}
Test("keylogger arrival FIFO: idle timer defers the pending classification",
	_KLF_WithState.Bind(_KLF_PendingIdle))


_KLF_RecordErgo(Rows, Arguments*) {
	Rows.Push(Arguments)
}

_KLF_BackspaceContract() {
	Rows := []
	Record := _KLF_RecordErgo.Bind(Rows)
	Keylogger.buffer_text := "ab"
	KL_Hook_OnChar(0, "c", _KLF_Allow, 1000, Record)
	KL_Hook_OnKeyDown(0, 0x08, 0, _KLF_Allow, 1050, _KLF_NoShortcut, Record)
	AssertEqual(2, Rows.Length, "both actual callback branches must notify ergonomics")
	AssertEqual(3, Rows[1].Length, "Char retains its original three-argument contract")
	AssertEqual(4, Rows[2].Length, "KeyDown retains its explicit Backspace argument")
	AssertEqual(50, Rows[2][1])
	AssertEqual(0x08, Rows[2][2])
	AssertEqual(0, Rows[2][3])
	AssertTrue(Rows[2][4], "the actual Backspace branch must retain deletion accounting")
	AssertEqual("ab", Keylogger.buffer_text)
	Meta := Keylogger.buffer_events[2][3]
	AssertTrue(Meta.Has("kc") && Meta.Has("sk"), "special-key metadata retains both original keys")
	AssertEqual(0x08, Meta["kc"])
	AssertEqual(0, Meta["sk"], "a zero scancode remains explicitly recorded for KeyDown")
}
Test("keylogger arrival FIFO: Backspace ergonomics and zero scancode retain their contracts",
	_KLF_WithState.Bind(_KLF_BackspaceContract))

_KLF_RejectReady(This, Value) {
	throw Error("Owned completion setter refusal.")
}

_KLF_BreakCompletion() {
	Intent := KLHook.capture_queue[1]
	KL_Hook_OnChar(0, "b", _KLF_Allow, 1100)
	Intent.DeleteProp("ready")
	Intent.DefineProp("ready", {Get: (*) => false, Set: _KLF_RejectReady})
	return false
}

_KLF_CompletionRefusal(Kind) {
	if Kind = "char"
		KL_Hook_OnChar(0, "a", _KLF_BreakCompletion, 1000)
	else
		KL_Hook_OnKeyDown(0, 0x0D, 0x1C, _KLF_BreakCompletion, 1000, _KLF_NoShortcut)
	AssertEqual(1, Keylogger.buffer_events.Length, "only the failed owned receipt is retired")
	AssertEqual("b", Keylogger.buffer_events[1][1], "the ready successor remains drainable")
	AssertEqual(1000, Keylogger.buffer_events[1][2])
	AssertEqual(1100, KLHook.last_tick)
	AssertEqual(1100, KLWatch.last_authorized_tick)
	AssertFalse(KL_Hook_HasPendingInput(), "a completion refusal must not wedge the lease")
	KL_Hook_OnChar(0, "c", _KLF_Allow, 1200)
	AssertEqual("c", Keylogger.buffer_events[2][1], "subsequent callbacks stay alive after the logged refusal")
	AssertEqual(100, Keylogger.buffer_events[2][2])
}
for _KLF_Kind in ["char", "key"]
	Test("keylogger arrival FIFO: completion refusal stays contained for " . _KLF_Kind,
		_KLF_WithState.Bind(_KLF_CompletionRefusal.Bind(_KLF_Kind)))
