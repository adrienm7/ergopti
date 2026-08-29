; tests/meta/test_keylogger_shutdown_timer_durability.ahk

; ==============================================================================
; MODULE: Keylogger Shutdown Timer Durability Guard
; DESCRIPTION:
; AHK-120 protects the terminal boundary where resident timer teardown precedes
; the final RAM-to-journal drain. Native cancellation failure must be converted
; into an aggregate verdict so KL_Stop still reaches both durability calls.
; ==============================================================================

#Requires AutoHotkey v2.0


_KLSTD_TimerFailureCannotSkipDurability() {
	Body := _DriverFuncBody("KL_Stop")
	Assert(Body != "", "KL_Stop() must exist in the driver source")

	CancelPos := InStr(Body, "TimersStopped := KL_StopOwnedTimers(", true)
	FlushPos := InStr(Body, "FlushComplete := KL_FlushBuffer()", true)
	JournalPos := InStr(Body, "JournalResult := _KL_JournalPendingEntries()", true)
	Assert(CancelPos > 0 && FlushPos > CancelPos && JournalPos > FlushPos,
		"AHK-120: owned timers must be cancelled without bypassing flush or journal")
	Assert(InStr(SubStr(Body, CancelPos, JournalPos - CancelPos), "return false", true) = 0,
		"AHK-120: timer teardown failure must not return before the durability drain")
	Assert(InStr(Body, "SetTimer(", true) = 0,
		"AHK-120: KL_Stop must not perform an unguarded native timer cancellation")
	Assert(InStr(Body, "!TimersStopped", true) > JournalPos,
		"AHK-120: KL_Stop must report timer teardown debt after durability work")
}
Test("keylogger shutdown: timer failure cannot skip durability (AHK-120)",
	_KLSTD_TimerFailureCannotSkipDurability)
