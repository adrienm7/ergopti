; tests/unit/test_promise_timeout_budget.ahk

; ==============================================================================
; MODULE: Promise Timeout Budget Tests
; DESCRIPTION:
; Proves that repeated message-pump wakeups consume only their own elapsed slice
; instead of repeatedly subtracting the whole lifetime from the remaining wait.
; ==============================================================================

#Requires AutoHotkey v2.0

global _PATB_WAKE_COUNT := 0

_PATB_Wake() {
	global _PATB_WAKE_COUNT
	_PATB_WAKE_COUNT += 1
}

_PATB_UnresolvedPromiseKeepsItsWholeTimeout() {
	global _PATB_WAKE_COUNT
	_PATB_WAKE_COUNT := 0
	WakeFn := _PATB_Wake
	Pending := Promise((*) => 0)
	Started := A_TickCount
	TimedOut := false
	SetTimer(WakeFn, 1)
	try Pending.await(120)
	catch as Err {
		TimedOut := Err is TimeoutError
	} finally {
		SetTimer(WakeFn, 0)
	}
	Elapsed := TickElapsed(Started)
	Assert(TimedOut, "an unresolved promise must finish through TimeoutError")
	Assert(_PATB_WAKE_COUNT >= 3,
		"the fixture must wake the message pump repeatedly or it proves no budget bug")
	Assert(Elapsed >= 90,
		"message wakeups must not repeatedly subtract already-consumed elapsed time")
	Assert(Elapsed < 1000, "the finite timeout must remain bounded")
}
Test("Promise.await: message wakeups consume the timeout budget once "
	. "(promise-timeout-double-subtract)",
	_PATB_UnresolvedPromiseKeepsItsWholeTimeout)
