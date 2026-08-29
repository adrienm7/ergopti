; modules/keylogger/keylogger_shutdown.ahk

; ==============================================================================
; MODULE: Keylogger Shutdown Helpers
; DESCRIPTION:
; Contains testable terminal-teardown boundaries that must convert native
; cleanup exceptions into aggregate debt without skipping durable drains.
; ==============================================================================


KL_StopOwnedTimers(Timers, CancelFn := SetTimer) {
	if !(Timers is Map)
		throw TypeError("keylogger shutdown timers must be a Map")
	if !HasMethod(CancelFn, "Call")
		throw TypeError("keylogger timer cancellation port must be callable")

	AllStopped := true
	for TimerName, TimerOwner in Timers {
		try CancelFn.Call(TimerOwner, 0)
		catch as Err {
			AllStopped := false
			try LoggerError("Keylogger",
				"Cannot stop {1} timer during shutdown: {2}.",
				TimerName, Err.Message)
		}
	}
	return AllStopped
}
