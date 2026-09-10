; tests/unit/test_keylogger_session_privacy_transaction.ahk

#Requires AutoHotkey v2.0


class _KLSPT_Sink {
	static accept := true
	static events := []

	static Reset(accept := true) {
		this.accept := accept
		this.events := []
	}

	static Append(kind, duration_ms := unset, CommitFn := 0) {
		Event := Map("kind", kind)
		if IsSet(duration_ms)
			Event["duration_ms"] := duration_ms
		this.events.Push(Event)
		if this.accept && HasMethod(CommitFn, "Call")
			CommitFn.Call()
		return this.accept
	}
}


_KLSPT_Append(kind, duration_ms := unset, CommitFn := 0) {
	if IsSet(duration_ms)
		return _KLSPT_Sink.Append(kind, duration_ms, CommitFn)
	return _KLSPT_Sink.Append(kind, unset, CommitFn)
}


_KLSPT_ResetWatcher() {
	KLWatch.idle_close := false
	KLWatch.session_close := false
	KLWatch.session_close_draining := false
	KLWatch.is_idle := false
	KLWatch.idle_started_at := 0
	KLWatch.is_session_active := false
	KLWatch.session_started_at := 0
	KLWatch.last_authorized_tick := 0
	KLWatch.privacy_interrupted := false
	KLWatch.privacy_started_at := 0
	_KLSPT_Sink.Reset()
}


_KLSPT_PrivateFirstStartsOnlyAtSafeBoundary() {
	_KLSPT_ResetWatcher()
	KL_Watchers_OnPrivateKeystroke(100)
	AssertFalse(KLWatch.is_session_active,
		"a private first key must not publish session ownership")
	AssertTrue(KL_Watchers_OnKeystroke(_KLSPT_Append, 120))
	AssertEqual(_KLSPT_Sink.events.Length, 1)
	AssertEqual(_KLSPT_Sink.events[1]["kind"], "session_start")
	AssertEqual(KLWatch.session_started_at, 120,
		"the safe boundary, not the private key, must own session start")
}
Test("keylogger watcher: private first activity cannot orphan a session (keylogger-session-privacy-transaction)",
	_KLSPT_PrivateFirstStartsOnlyAtSafeBoundary)


_KLSPT_PrivacyGapClosesAtLastSafeTick() {
	_KLSPT_ResetWatcher()
	AssertTrue(KL_Watchers_OnKeystroke(_KLSPT_Append, 100))
	KL_Watchers_OnPrivateKeystroke(120)
	AssertTrue(KL_Watchers_OnKeystroke(_KLSPT_Append, 140))
	AssertEqual(_KLSPT_Sink.events.Length, 3)
	AssertEqual(_KLSPT_Sink.events[2]["kind"], "session_end")
	AssertEqual(_KLSPT_Sink.events[2]["duration_ms"], 20,
		"private time must not be included in the authorized session")
	AssertEqual(_KLSPT_Sink.events[3]["kind"], "session_start")
	AssertEqual(KLWatch.session_started_at, 140)
}
Test("keylogger watcher: a privacy gap creates paired safe boundaries (keylogger-session-privacy-transaction)",
	_KLSPT_PrivacyGapClosesAtLastSafeTick)


_KLSPT_FailedAppendCannotAdvanceState() {
	_KLSPT_ResetWatcher()
	_KLSPT_Sink.accept := false
	AssertFalse(KL_Watchers_OnKeystroke(_KLSPT_Append, 100))
	AssertFalse(KLWatch.is_session_active)
	AssertEqual(KLWatch.last_authorized_tick, 0)
	_KLSPT_Sink.accept := true
	AssertTrue(KL_Watchers_OnKeystroke(_KLSPT_Append, 110))
	AssertTrue(KLWatch.is_session_active)
	AssertEqual(KLWatch.session_started_at, 110)

	KL_Watchers_OnPrivateKeystroke(120)
	_KLSPT_Sink.accept := false
	AssertFalse(KL_Watchers_OnKeystroke(_KLSPT_Append, 140))
	AssertTrue(KLWatch.is_session_active,
		"a rejected end must retain the active owner for a retry")
	AssertTrue(KLWatch.privacy_interrupted)
	_KLSPT_Sink.accept := true
	AssertTrue(KL_Watchers_OnKeystroke(_KLSPT_Append, 150))
	AssertEqual(KLWatch.session_started_at, 150)
}
Test("keylogger watcher: append failure retains transition debt (keylogger-session-privacy-transaction)",
	_KLSPT_FailedAppendCannotAdvanceState)

_KLSPT_StopAtPrivacyBoundary(Wrap) {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	Saved := Map()
	for Name in ["is_idle", "idle_started_at", "is_session_active", "session_started_at",
		"last_authorized_tick", "privacy_interrupted", "privacy_started_at", "system_events",
		"system_failure_reported", "wts_registered", "wts_failure_reported", "wts_retry_timer",
		"session_close", "session_close_draining", "idle_close"]
		Saved[Name] := KLWatch.%Name%
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedHook := _Stub_AppendLogHook
	try {
		AssertFalse(KLWatch.HasOwnProp("idle_check_timer"), "the fixture must not stop a live idle timer")
		AssertFalse(KLWatch.HasOwnProp("session_msg_handler"), "the fixture must not detach a live watcher")
		AssertFalse(KLWatch.HasOwnProp("power_msg_handler"), "the fixture must not detach a live watcher")
		KLWatch.wts_registered := false
		KLWatch.wts_retry_timer := false
		KLWatch.system_events := false
		KLWatch.is_session_active := true
		KLWatch.session_started_at := Wrap ? 0xFFFFFFF0 : 100
		KLWatch.is_idle := true
		KLWatch.idle_started_at := (KLWatch.session_started_at + 10) & 0xFFFFFFFF
		KLWatch.privacy_interrupted := false
		KL_Watchers_OnPrivateKeystroke((KLWatch.session_started_at + 30) & 0xFFFFFFFF)
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := false
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		AssertFalse(KL_Watchers_Stop(), "refused closing records must retain their boundary")
		AssertTrue(KLWatch.privacy_interrupted)
		AssertTrue(KLWatch.is_idle)
		AssertTrue(KLWatch.is_session_active)
		_Stub_AppendLogAccept := true
		AssertTrue(KL_Watchers_Stop())
		AssertEqual(2, _Stub_AppendLogRows.Length)
		AssertEqual("idle_end", _Stub_AppendLogRows[1]["type"])
		AssertEqual(20, _Stub_AppendLogRows[1]["duration_ms"], "shutdown must exclude private idle time")
		AssertEqual("session_end", _Stub_AppendLogRows[2]["type"])
		AssertEqual(30, _Stub_AppendLogRows[2]["duration_ms"], "shutdown must exclude private session time")
		AssertFalse(KLWatch.privacy_interrupted)
		AssertTrue(KL_Watchers_Stop())
		AssertEqual(2, _Stub_AppendLogRows.Length, "repeated stop must not duplicate accepted closing records")
	} finally {
		for Name, Value in Saved
			KLWatch.%Name% := Value
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedHook
	}
}
for Wrap in [false, true]
	Test("keylogger watcher: shutdown respects private boundary wrap=" . Wrap
		. " (keylogger-private-stop-boundary)", _KLSPT_StopAtPrivacyBoundary.Bind(Wrap))

_KLSPT_PauseClosesAuthorizedSession(Callback) {
	Saved := Map()
	for Name in ["is_idle", "idle_started_at", "is_session_active", "session_started_at",
		"last_authorized_tick", "privacy_interrupted", "privacy_started_at", "system_events",
		"session_close", "session_close_draining", "idle_close"]
		Saved[Name] := KLWatch.%Name%
	SavedEvents := _KLSPT_Sink.events
	SavedAccept := _KLSPT_Sink.accept
	WasSuspended := A_IsSuspended
	try {
		_KLSPT_ResetWatcher()
		KLWatch.system_events := false
		StartedAt := (A_TickCount - 1000) & 0xFFFFFFFF
		AssertTrue(KL_Watchers_OnKeystroke(_KLSPT_Append, StartedAt))
		Suspend(1)
		try Callback.Call()
		finally Suspend(WasSuspended)
		AssertTrue(KLWatch.privacy_interrupted, "pause must retain the authorized session boundary")
		Boundary := KLWatch.privacy_started_at
		AssertEqual(1, _KLSPT_Sink.events.Length, "pause must not publish session records")
		AssertTrue(KL_Watchers_OnKeystroke(_KLSPT_Append, (Boundary + 100000) & 0xFFFFFFFF))
		AssertEqual(3, _KLSPT_Sink.events.Length)
		AssertEqual("session_end", _KLSPT_Sink.events[2]["kind"])
		AssertEqual((Boundary - StartedAt) & 0xFFFFFFFF, _KLSPT_Sink.events[2]["duration_ms"],
			"the next authorized key must exclude the complete paused interval")
		AssertEqual("session_start", _KLSPT_Sink.events[3]["kind"])
	} finally {
		Suspend(WasSuspended)
		for Name, Value in Saved
			KLWatch.%Name% := Value
		_KLSPT_Sink.events := SavedEvents
		_KLSPT_Sink.accept := SavedAccept
	}
}
Test("keylogger watcher: paused idle callback owns session boundary (keylogger-pause-session-boundary)",
	_KLSPT_PauseClosesAuthorizedSession.Bind(KL_Watchers_IdleTick))
Test("keylogger watcher: paused session callback owns session boundary (keylogger-pause-session-boundary)",
	_KLSPT_PauseClosesAuthorizedSession.Bind(KL_Watchers_OnSessionChange.Bind(KLWatchConst.WTS_SESSION_LOCK, 0, 0, 0)))
Test("keylogger watcher: paused power callback owns session boundary (keylogger-pause-session-boundary)",
	_KLSPT_PauseClosesAuthorizedSession.Bind(KL_Watchers_OnPowerBroadcast.Bind(KLWatchConst.PBT_APMSUSPEND, 0, 0, 0)))
