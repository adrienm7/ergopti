; tests/unit/test_keylogger_shutdown_timers.ahk

; ==============================================================================
; MODULE: Keylogger Shutdown Timer Teardown Tests
; DESCRIPTION:
; AHK-120 regression coverage for terminal timer cancellation. One rejected
; native cancellation must not prevent sibling timers from being attempted or
; escape the helper that protects the final durability drain.
; ==============================================================================

#Requires AutoHotkey v2.0


_KLST_CancelFirstFails(Calls, TimerOwner, Period) {
	Calls.Push(Map("owner", TimerOwner, "period", Period))
	if (Calls.Length = 1)
		throw Error("injected timer cancellation failure")
}

_KLST_CancellationFailureIsAggregated() {
	Calls := []
	Timers := Map(
		"ingest", "ingest-owner",
		"midnight", "midnight-owner")

	Result := KL_StopOwnedTimers(Timers, _KLST_CancelFirstFails.Bind(Calls))

	AssertFalse(Result,
		"AHK-120: one rejected cancellation must make aggregate teardown fail")
	AssertEqual(Calls.Length, 2,
		"AHK-120: one rejected cancellation must not skip sibling timer cleanup")
	AssertEqual(Calls[1]["owner"], "ingest-owner",
		"AHK-120: the first exact timer owner must be attempted")
	AssertEqual(Calls[2]["owner"], "midnight-owner",
		"AHK-120: the second exact timer owner must still be attempted")
	AssertEqual(Calls[1]["period"], 0,
		"AHK-120: timer teardown must use the native cancellation period")
}
Test("keylogger shutdown timers: cancellation debt is aggregated (AHK-120)",
	_KLST_CancellationFailureIsAggregated)
