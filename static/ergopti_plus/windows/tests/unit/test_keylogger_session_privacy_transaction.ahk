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
