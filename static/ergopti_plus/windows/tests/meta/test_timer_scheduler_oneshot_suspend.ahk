; tests/meta/test_timer_scheduler_oneshot_suspend.ahk

; ==============================================================================
; MODULE: Timer Scheduler One-Shot Suspend Meta Test
; DESCRIPTION:
; Static source guard for the "timer-scheduler-oneshot-suspend" audit finding
; in adapters/timer_scheduler.ahk.
;
; ROOT CAUSE ENCODED:
; _TimerAdapterMakeOneShot used a one-shot SetTimer (negative delay). Its inner
; _OneShot callback checked A_IsSuspended and returned early, but did not
; reschedule itself. Since one-shot timers never re-fire automatically, the
; deferred callback was permanently lost when the script happened to be
; suspended at the moment the timer fired. The handle also remained in
; _TIMER_ADAPTER_REGISTRY indefinitely, leaking memory.
;
; The fix: when A_IsSuspended is true, the callback re-queues itself with a
; 500ms one-shot SetTimer so it eventually fires after suspension ends.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================================
; ===============================================================
; ======= 1/ One-shot timer reschedules on A_IsSuspended ========
; ===============================================================
; ===============================================================

_TSO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_TSO_OneShotReschedules() {
	Src := _TSO_ReadSource("adapters/timer_scheduler.ahk")
	; Use the definition pattern (with trailing " {") to avoid matching the call site at TimerAfter.
	Body := _DriverFuncBody("_TimerAdapterMakeOneShot")

	Assert(Body != "", "_TimerAdapterMakeOneShot must exist in timer_scheduler.ahk")

	; The suspension guard must now reschedule instead of silently returning
	Assert(RegExMatch(Body, "A_IsSuspended") > 0,
		"_TimerAdapterMakeOneShot must still check A_IsSuspended (timer-scheduler-oneshot-suspend)")

	; Re-queue with a negative-delay (one-shot) SetTimer
	Assert(RegExMatch(Body, "SetTimer\([^,]+,\s*-\d+\)") > 0,
		"_OneShot must reschedule itself with SetTimer(..., -N) when suspended (timer-scheduler-oneshot-suspend)")

	; The bare `return` without reschedule must not appear immediately after the
	; A_IsSuspended check (the reschedule + return replaces the bare return)
	; We check that SetTimer appears before any plain `return` in the suspend block
	SuspendIdx := InStr(Body, "A_IsSuspended")
	SetTimerIdx := InStr(Body, "SetTimer(")
	Assert(SetTimerIdx > SuspendIdx,
		"SetTimer reschedule must follow the A_IsSuspended check in _OneShot (timer-scheduler-oneshot-suspend)")
}
Test("timer_scheduler: _OneShot reschedules itself when A_IsSuspended (timer-scheduler-oneshot-suspend)", _TSO_OneShotReschedules)
