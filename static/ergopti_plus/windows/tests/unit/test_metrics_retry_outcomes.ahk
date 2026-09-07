; tests/unit/test_metrics_retry_outcomes.ahk

; ==============================================================================
; MODULE: Metrics Retry Outcome Tests
; DESCRIPTION:
; Cancellation and deferred success preserve the failure budget across pause.
; Captured timer callbacks are replayed while suspended without opening a GUI.
; ==============================================================================

#Requires AutoHotkey v2.0

_MRO_AssertPending(Entry, Full, Attempt) {
	Key := Full ? "pending_full_build_retry" : "pending_first_paint_retry"
	AssertTrue(Entry.Has(Key), "a non-failure must retain a resumable operation")
	AssertEqual(Attempt, Entry[Key]["attempt"], "only actual failures may consume retry budget")
	AssertEqual(51, Entry[Key]["epoch"])
	if !Full {
		AssertFalse(Entry[Key]["fallback"], "a pause must not force degraded first paint")
		AssertFalse(Entry["first_paint_done"])
	}
	AssertFalse(Entry.Get("full_build_retry_exhausted", false))
	AssertFalse(Entry["full_build_done"])
}

_MRO_Outcome(Full, Status, AtLimit, Paused) {
	OldWindows := KLWV.windows
	OldFirstTimer := KLWV.first_paint_timer_fn
	OldFullTimer := KLWV.full_build_timer_fn
	OldPush := KLWV.first_paint_push_fn
	OldSuspended := A_IsSuspended
	Timers := []
	Attempt := AtLimit ? (Full ? KLWV.FULL_BUILD_MAX_RETRIES : KLWV.FIRST_PAINT_MAX_RETRIES) : 0
	Entry := Map("epoch", 51, "first_paint_done", Full, "full_build_done", false)
	try {
		KLWV.windows := Map("typing", Entry)
		KLWV.first_paint_timer_fn := (Callback, Period) => Timers.Push(Callback)
		KLWV.full_build_timer_fn := (Callback, Period) => Timers.Push(Callback)
		KLWV.first_paint_push_fn := (*) => false
		Suspend(Paused)
		if Full
			KLWV_OnFullBuildTerminal("typing", 51, Attempt, Status)
		else
			KLWV_OnFirstBuildTerminal("typing", 51, Attempt, Status)
		if Status == "failed" {
			AssertTrue(AtLimit && Paused, "failure controls exercise the paused budget boundary")
			AssertEqual(0, Timers.Length)
			if Full {
				AssertTrue(Entry["full_build_retry_exhausted"])
				AssertFalse(Entry.Has("pending_full_build_retry"))
				Suspend(false)
				KLWV_FlushPendingFullBuildRetries()
				AssertEqual(0, Timers.Length, "a genuine exhausted failure remains bounded")
			} else {
				AssertTrue(Entry["pending_first_paint_retry"]["fallback"])
				AssertFalse(Entry["first_paint_done"])
				Suspend(false)
				KLWV_FlushPendingFirstPaintRetries()
				AssertTrue(Entry["first_paint_done"], "resume must retain the already-due live fallback")
				AssertFalse(Entry.Has("pending_first_paint_retry"))
				AssertEqual(0, Timers.Length)
			}
			return
		}
		if Paused {
			AssertEqual(0, Timers.Length, "pause must defer rather than arm work")
			_MRO_AssertPending(Entry, Full, Attempt)
			Suspend(false)
			if Full
				KLWV_FlushPendingFullBuildRetries()
			else
				KLWV_FlushPendingFirstPaintRetries()
		}
		AssertEqual(1, Timers.Length, "resume or late cancellation must schedule one retry")
		; Replay the actual bound callback across repeated pauses. Its captured
		; attempt must remain unchanged even at the final permitted retry.
		Loop 3 {
			Suspend(true)
			Timers[A_Index].Call()
			_MRO_AssertPending(Entry, Full, Attempt)
			Suspend(false)
			if Full
				KLWV_FlushPendingFullBuildRetries()
			else
				KLWV_FlushPendingFirstPaintRetries()
			AssertEqual(A_Index + 1, Timers.Length)
		}
	} finally {
		Suspend(OldSuspended)
		KLWV.windows := OldWindows
		KLWV.first_paint_timer_fn := OldFirstTimer
		KLWV.full_build_timer_fn := OldFullTimer
		KLWV.first_paint_push_fn := OldPush
	}
}
for Full in [false, true] {
	Test("Metrics: genuine paused " . (Full ? "full" : "first")
		. " failure retains its limit (metrics-retry-outcome)",
		_MRO_Outcome.Bind(Full, "failed", true, true))
	for AtLimit in [false, true] {
		for Status in ["canceled", "ok"]
			Test("Metrics: paused " . (Full ? "full" : "first") . " " . Status
				. " at " . (AtLimit ? "limit" : "start") . " (metrics-retry-outcome)",
				_MRO_Outcome.Bind(Full, Status, AtLimit, true))
		Test("Metrics: resumed " . (Full ? "full" : "first") . " cancellation at "
			. (AtLimit ? "limit" : "start") . " (metrics-retry-outcome)",
			_MRO_Outcome.Bind(Full, "canceled", AtLimit, false))
	}
}
