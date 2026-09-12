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
		KLHook.last_tick := (A_TickCount - KLWatchConst.SESSION_TIMEOUT_MS - 10000) & 0xFFFFFFFF
		KLHook.app_entered_at := KLHook.last_tick
		KLHook.title_entered_at := KLHook.last_tick
		KLWatch.last_authorized_tick := KLHook.last_tick
		KLWatch.session_started_at := (KLHook.last_tick - 1000) & 0xFFFFFFFF
		Keylogger.initialized := true
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := _KLSCR_RefuseAfterIdle
		KL_Watchers_IdleTick()
		AssertEqual(2, _Stub_AppendLogRows.Length)
		AssertEqual("idle_start", _Stub_AppendLogRows[1]["type"])
		AssertEqual("idle_end", _Stub_AppendLogRows[2]["type"])
		AssertTrue(KLWatch.is_session_active, "the refused session close must remain owned")
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		if Mode = "timer"
			KL_Watchers_IdleTick()
		else if Mode = "key"
			AssertTrue(KL_Watchers_OnKeystroke())
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
		StartedAt := Mode = "wrap" ? 0xFFFFFFF0 : (A_TickCount - 1000) & 0xFFFFFFFF
		Boundary := (StartedAt + 100) & 0xFFFFFFFF
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
			KL_Watchers_IdleTick()
		else if Mode = "stop"
			AssertTrue(KL_Watchers_Stop())
		else if Mode = "timeout"
			AssertTrue(KL_Watchers_OnKeystroke(0,
				(Boundary + KLWatchConst.SESSION_TIMEOUT_MS + 10) & 0xFFFFFFFF))
		else if Mode = "private" {
			KL_Watchers_OnPrivateKeystroke((Boundary + 100) & 0xFFFFFFFF)
			AssertTrue(KL_Watchers_OnKeystroke(0, (Boundary + 800) & 0xFFFFFFFF))
		}
		else
			AssertTrue(KL_Watchers_OnKeystroke(0, (Boundary + 800) & 0xFFFFFFFF))
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
for Mode in ["key", "timer", "stop", "timeout", "private", "wrap"]
	Test("keylogger idle: refused resume recovers through " . Mode
		. " (keylogger-idle-resume-retry)", _KLSCR_ShortIdleRetry.Bind(Mode))
