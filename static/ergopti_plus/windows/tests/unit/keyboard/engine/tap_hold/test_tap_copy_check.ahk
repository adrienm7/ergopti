; tests/unit/keyboard/engine/tap_hold/test_tap_copy_check.ahk

; ==============================================================================
; MODULE: Tap-hold copy check
; DESCRIPTION:
; A tap's Ctrl+C is proved by the clipboard's sequence number, read before the
; keystroke, re-read on a timer, sent once more when it did not move, and the
; user is warned when it never did (tap-copy-verified). The counter, the timer
; and the notice are fakes: the sequence number moves only when the fake
; application copies, even when it copies the same text again.
; ==============================================================================

#Requires AutoHotkey v2.0

global _TCC_Counter := 0
global _TCC_Sends := 0
global _TCC_Warnings := 0
global _TCC_Timers := []
global _TCC_CopiesOnSend := Map()
global _TCC_Focus := 42
global _TCC_PhysicalTick := 100

; Installs the fakes and returns a restore function.
_TCC_Install(CopiesOnSend) {
	global _TapCopyCounterFn, _TapCopyTimerFn, _TapCopyWarnFn, _TapCopyFocusFn, _TapCopyPhysicalTickFn, TAP_COPY_VERIFY_MS
	global _TCC_Counter, _TCC_Sends, _TCC_Warnings, _TCC_Timers, _TCC_CopiesOnSend
	Saved := [_TapCopyCounterFn, _TapCopyTimerFn, _TapCopyWarnFn, TAP_COPY_VERIFY_MS, _TapCopyFocusFn, _TapCopyPhysicalTickFn]
	global _TCC_Focus, _TCC_PhysicalTick
	_TCC_Focus := 42, _TCC_PhysicalTick := 100
	_TapCopyFocusFn := () => _TCC_Focus
	_TapCopyPhysicalTickFn := () => _TCC_PhysicalTick
	_TCC_Counter := 41, _TCC_Sends := 0, _TCC_Warnings := 0, _TCC_Timers := []
	_TCC_CopiesOnSend := CopiesOnSend
	_TapCopyCounterFn := () => _TCC_Counter
	_TapCopyTimerFn := (Callback, DelayMs) => _TCC_Timers.Push(Callback)
	_TapCopyWarnFn := _TCC_Warn
	TAP_COPY_VERIFY_MS := 300
	return () => _TCC_Restore(Saved)
}

_TCC_Restore(Saved) {
	global _TapCopyCounterFn, _TapCopyTimerFn, _TapCopyWarnFn, _TapCopyFocusFn, _TapCopyPhysicalTickFn, TAP_COPY_VERIFY_MS
	_TapCopyCounterFn := Saved[1], _TapCopyTimerFn := Saved[2]
	_TapCopyWarnFn := Saved[3], TAP_COPY_VERIFY_MS := Saved[4]
	_TapCopyFocusFn := Saved[5], _TapCopyPhysicalTickFn := Saved[6]
	TapCopyCheckStop()
}

_TCC_Warn() {
	global _TCC_Warnings
	_TCC_Warnings += 1
	return true
}

; The copy keystroke: the fake application copies on the sends listed.
_TCC_Send() {
	global _TCC_Sends, _TCC_Counter, _TCC_CopiesOnSend
	_TCC_Sends += 1
	if _TCC_CopiesOnSend.Has(_TCC_Sends)
		_TCC_Counter += 1
	return true
}

; Fires the pending timers, as the elapsed wait would.
_TCC_Fire() {
	global _TCC_Timers
	Pending := _TCC_Timers
	_TCC_Timers := []
	for _, Callback in Pending
		Callback.Call()
}

_TCC_CopyVerified() {
	global _TCC_Sends, _TCC_Warnings, _TCC_Timers
	Restore := _TCC_Install(Map(1, true))
	try {
		TapCopySend("left_shift", _TCC_Send)
		AssertEqual(1, _TCC_Sends, "the copy is sent once")
		AssertEqual(1, _TCC_Timers.Length, "the check waits on a timer, not a Sleep")
		_TCC_Fire()
		AssertEqual(1, _TCC_Sends, "a copy that landed is never sent again")
		AssertEqual(0, _TCC_Warnings)
		AssertEqual(0, _TCC_Timers.Length, "the check is over")
	} finally {
		Restore()
	}
}
Test("tap-hold copy: a copy that moved the sequence number is verified (tap-copy-verified)", _TCC_CopyVerified)

_TCC_CopiedOnRetry() {
	global _TCC_Sends, _TCC_Warnings, _TCC_Timers
	Restore := _TCC_Install(Map(2, true))
	try {
		TapCopySend("left_shift", _TCC_Send)
		_TCC_Fire()
		AssertEqual(2, _TCC_Sends, "an unchanged sequence number sends Ctrl+C once more")
		AssertEqual(1, _TCC_Timers.Length, "the retry is judged after its own wait")
		_TCC_Fire()
		AssertEqual(0, _TCC_Warnings, "a copy that landed on the retry is no failure")
		AssertEqual(0, _TCC_Timers.Length)
	} finally {
		Restore()
	}
}
Test("tap-hold copy: a copy that landed on the retry is not warned (tap-copy-verified)", _TCC_CopiedOnRetry)

_TCC_NeverCopied() {
	global _TCC_Sends, _TCC_Warnings, _TCC_Timers
	Restore := _TCC_Install(Map())
	try {
		TapCopySend("left_shift", _TCC_Send)
		_TCC_Fire()
		_TCC_Fire()
		AssertEqual(2, _TCC_Sends, "exactly one retry")
		AssertEqual(1, _TCC_Warnings, "the user is warned once")
		AssertEqual(0, _TCC_Timers.Length)
	} finally {
		Restore()
	}
}
Test("tap-hold copy: a copy that never landed warns the user (tap-copy-verified)", _TCC_NeverCopied)

_TCC_Superseded() {
	global _TCC_Sends, _TCC_Warnings, _TCC_Counter
	Restore := _TCC_Install(Map())
	try {
		TapCopySend("left_shift", _TCC_Send)
		TapCopySend("left_shift", _TCC_Send)
		_TCC_Counter += 1
		_TCC_Fire()
		AssertEqual(2, _TCC_Sends, "the first check's timer is stale and retries nothing")
		AssertEqual(0, _TCC_Warnings)
	} finally {
		Restore()
	}
}
Test("tap-hold copy: a newer copy supersedes the pending check (tap-copy-verified)", _TCC_Superseded)

_TCC_UnreadableCounter() {
	global _TCC_Counter, _TCC_Warnings, _TCC_Timers
	Restore := _TCC_Install(Map())
	try {
		_TCC_Counter := 0
		TapCopySend("left_shift", _TCC_Send)
		AssertEqual(0, _TCC_Timers.Length, "a session without clipboard access is not checked")
		AssertEqual(0, _TCC_Warnings)
	} finally {
		Restore()
	}
}
Test("tap-hold copy: a zero sequence number is unreadable, never a failure (tap-copy-verified)", _TCC_UnreadableCounter)

_TCC_PauseCancelsRetry() {
	global _TCC_Sends, _TCC_Warnings
	Restore := _TCC_Install(Map())
	try {
		TapCopySend("left_shift", _TCC_Send)
		TapCopyCheckStop()
		_TCC_Fire()
		AssertEqual(1, _TCC_Sends, "a retry from before pause must not run after resume")
		AssertEqual(0, _TCC_Warnings, "abandoning a stale check must not warn")
		Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
		Assert(Body != "", "the suspend lifecycle must be present")
		Assert(InStr(Body, "TapCopyCheckStop()") > 0, "suspend must stop copy verification")
	} finally {
		Restore()
	}
}
Test("tap-hold copy: suspend retires a pending retry (tap-copy-pause)", _TCC_PauseCancelsRetry)

_TCC_ContextChanged() {
	global _TCC_Focus, _TCC_PhysicalTick, _TCC_Sends, _TCC_Warnings
	for Scenario in ["focus", "activity", "unavailable"] {
		Restore := _TCC_Install(Map())
		try {
			if Scenario == "unavailable"
				_TCC_Focus := 0
			TapCopySend("left_shift", _TCC_Send)
			if Scenario == "focus"
				_TCC_Focus := 43
			if Scenario == "activity"
				_TCC_PhysicalTick += 1
			_TCC_Fire()
			AssertEqual(1, _TCC_Sends, "unproven context must not receive a retry")
			AssertEqual(0, _TCC_Warnings, "an abandoned check is not a proved failure")
		} finally {
			Restore()
		}
	}
}
Test("tap-hold copy: changed or unavailable context abandons retry (tap-copy-context)", _TCC_ContextChanged)

_TCC_ReenterFocus() {
	global _TapCopyFocusFn, _TCC_Focus
	_TapCopyFocusFn := () => _TCC_Focus
	TapCopySend("newer", _TCC_Send)
	return _TCC_Focus
}

_TCC_ContextReentry() {
	global _TapCopyFocusFn, _TCC_Sends, _TCC_Warnings
	Restore := _TCC_Install(Map())
	try {
		TapCopySend("older", _TCC_Send)
		_TapCopyFocusFn := _TCC_ReenterFocus
		_TCC_Fire()
		AssertEqual(2, _TCC_Sends, "the superseded check cannot retry")
		_TCC_Fire()
		AssertEqual(3, _TCC_Sends, "the newer check retains its retry")
		AssertEqual(0, _TCC_Warnings)
	} finally {
		Restore()
	}
}
Test("tap-hold copy: reentrant context lookup preserves the newer check (tap-copy-context)", _TCC_ContextReentry)

; Invoke the same genuine remap teardown that the suspend lifecycle owns, with
; private empty modifier ledgers so this copy test never releases another key.
_TCC_PauseAndResume() {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	Saved := [_TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys]
	WasSuspended := A_IsSuspended
	_TH_SyntheticHeldKeys := Map(), _TH_SyntheticReleasePendingKeys := Map(), _TH_SyntheticUserHeldKeys := Map()
	try {
		Suspend(true)
		AssertTrue(A_IsSuspended)
		AssertTrue(TapHoldReleaseSyntheticKeys(), "The actual suspend-owned remap drain must acknowledge empty key ownership")
	} finally {
		_TH_SyntheticHeldKeys := Saved[1], _TH_SyntheticReleasePendingKeys := Saved[2], _TH_SyntheticUserHeldKeys := Saved[3]
		Suspend(WasSuspended)
	}
}

_TCC_PauseRetiresDeferred() {
	global _TCC_Sends, _TCC_Warnings, _TCC_Timers, _TCC_Counter, _TapCopyPending
	Restore := _TCC_Install(Map())
	try {
		TapCopySend("A", _TCC_Send)
		AssertEqual(1, _TCC_Timers.Length)
		_TCC_PauseAndResume()
		AssertFalse(IsObject(_TapCopyPending), "The real remap teardown must revoke the pending check before resume")
		_TCC_Fire()
		AssertEqual(1, _TCC_Sends, "An old timer delivered after resume must send no retry")
		AssertEqual(0, _TCC_Warnings)
		AssertEqual(0, _TCC_Timers.Length)
		TapCopySend("B", _TCC_Send)
		_TCC_Counter += 1
		_TCC_Fire()
		AssertEqual(2, _TCC_Sends, "A newly requested copy after resume must still be admitted")
		AssertEqual(0, _TCC_Warnings)
		AssertFalse(IsObject(_TapCopyPending))
	} finally Restore()
}
Test("tap-hold copy: suspend teardown retires a callback delivered after resume (tap-copy-owner)", _TCC_PauseRetiresDeferred)

_TCC_PauseDuringProducer(Phase) {
	global _TapCopyCounterFn, _TCC_Counter, _TCC_Sends, _TCC_Warnings, _TCC_Timers, _TapCopyPending
	Restore := _TCC_Install(Map())
	Counter() {
		_TCC_PauseAndResume()
		return _TCC_Counter
	}
	Send() {
		_TCC_Send()
		_TCC_PauseAndResume()
		return true
	}
	try {
		if Phase == "counter"
			_TapCopyCounterFn := Counter
		TapCopySend("A", Phase == "send" ? Send : _TCC_Send)
		AssertEqual(Phase == "counter" ? 0 : 1, _TCC_Sends,
			"Revocation during the initial observation must not admit an old send")
		AssertFalse(IsObject(_TapCopyPending), "A producer revoked by teardown must not publish a new check after resume")
		AssertEqual(0, _TCC_Timers.Length)
		AssertEqual(0, _TCC_Warnings)
	} finally Restore()
}
for _TCC_ProducerPhase in ["counter", "send"]
	Test("tap-hold copy: revocation in initial " . _TCC_ProducerPhase . " cannot publish a check (tap-copy-owner)",
		_TCC_PauseDuringProducer.Bind(_TCC_ProducerPhase))

_TCC_CounterReplacesOwner(PauseOnly) {
	global _TapCopyCounterFn, _TapCopyPending, _TCC_Counter, _TCC_Sends, _TCC_Warnings, _TCC_Timers
	Restore := _TCC_Install(Map())
	Counter() {
		global _TapCopyCounterFn
		_TapCopyCounterFn := () => _TCC_Counter
		if PauseOnly
			_TCC_PauseAndResume()
		else
			TapCopySend("B", _TCC_Send)
		return _TCC_Counter
	}
	try {
		TapCopySend("A", _TCC_Send)
		_TapCopyCounterFn := Counter
		_TCC_Fire()
		AssertEqual(PauseOnly ? 1 : 2, _TCC_Sends, "The retired timer must not retry after its counter callout")
		AssertEqual(0, _TCC_Warnings)
		AssertEqual(PauseOnly ? 0 : 1, _TCC_Timers.Length)
		if PauseOnly
			AssertFalse(IsObject(_TapCopyPending))
		else {
			AssertEqual("B", _TapCopyPending["source"], "A replacement must retain the exact current record")
			_TCC_Counter += 1
			_TCC_Fire()
			AssertFalse(IsObject(_TapCopyPending))
			AssertEqual(0, _TCC_Warnings)
		}
	} finally Restore()
}
for _TCC_CounterPause in [false, true]
	Test("tap-hold copy: timer counter revocation pause=" . _TCC_CounterPause . " preserves current ownership (tap-copy-owner)",
		_TCC_CounterReplacesOwner.Bind(_TCC_CounterPause))

_TCC_RetryReplacesOwner() {
	global _TapCopyPending, _TCC_Sends, _TCC_Counter, _TCC_Warnings, _TCC_Timers
	Restore := _TCC_Install(Map())
	Send() {
		_TCC_Send()
		if _TCC_Sends == 2 {
			TapCopySend("B", _TCC_Send)
			return false
		}
		return true
	}
	try {
		TapCopySend("A", Send)
		_TCC_Fire()
		AssertEqual(3, _TCC_Sends, "Only A's admitted initial/retry sends and B's new initial send may occur")
		AssertEqual("B", _TapCopyPending["source"], "The retired retry must not clear B on its refused return")
		AssertEqual(1, _TCC_Timers.Length, "Only B's actual timer must remain")
		AssertEqual(0, _TCC_Warnings, "A retired retry refusal must not notify the user")
		_TCC_Counter += 1
		_TCC_Fire()
		AssertFalse(IsObject(_TapCopyPending))
		AssertEqual(3, _TCC_Sends)
		AssertEqual(0, _TCC_Warnings)
	} finally Restore()
}
Test("tap-hold copy: a newer copy inside retry preserves its timer and receipt (tap-copy-owner)", _TCC_RetryReplacesOwner)

_TCC_ReportReplacesOwner() {
	global _LOGGER_TEST_SINK, _LOGGER_WARN_ENABLED, _TapCopyPending, _TCC_Sends, _TCC_Counter, _TCC_Warnings, _TCC_Timers
	Restore := _TCC_Install(Map()), SavedSink := _LOGGER_TEST_SINK, SavedWarn := _LOGGER_WARN_ENABLED, Replaced := false
	Observe(Line) {
		if !Replaced && InStr(Line, "not_copied after") {
			Replaced := true
			TapCopySend("B", _TCC_Send)
		}
	}
	try {
		_LOGGER_TEST_SINK := Observe, _LOGGER_WARN_ENABLED := true
		TapCopySend("A-report-" . A_TickCount, _TCC_Send)
		_TCC_Fire()
		_TCC_Fire()
		AssertTrue(Replaced, "The real failure logger must deliver the exact controlled callout")
		AssertEqual("B", _TapCopyPending["source"])
		AssertEqual(1, _TCC_Timers.Length)
		AssertEqual(0, _TCC_Warnings, "A failure notice revoked during logging must not be delivered afterward")
		_TCC_Counter += 1
		_TCC_Fire()
		AssertFalse(IsObject(_TapCopyPending))
	} finally {
		_LOGGER_TEST_SINK := SavedSink, _LOGGER_WARN_ENABLED := SavedWarn
		Restore()
	}
}
Test("tap-hold copy: a report callout cannot notify after owner replacement (tap-copy-owner)", _TCC_ReportReplacesOwner)
