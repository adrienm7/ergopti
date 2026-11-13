; tests/meta/platform/input/dispatch/test_timer_scheduler_oneshot_suspend.ahk

; ==============================================================================
; MODULE: Timer Scheduler One-Shot Suspend Meta Test
; DESCRIPTION:
; Static source guard for the "timer-scheduler-oneshot-suspend" audit finding
; in core/events/timer_scheduler.ahk.
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
;
; The deferral itself is observed by a real suspended delivery in
; unit/infra/dispatch/test_timer_scheduler_suspend.ahk. What stays here is the
; atomicity of the re-queue: the native SetTimer call has no seam and a single
; test thread cannot interrupt it, so only its position inside the Critical
; section can be checked.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================================================
; ===============================================================
; ======= 1/ Suspended re-queue stays non-interruptible =========
; ===============================================================
; ===============================================================

_TSO_SuspendedRequeueOwnershipIsAtomic() {
	Body := _DriverFuncBody("_TimerAdapterMakeOneShot")
	Assert(Body != "", "_TimerAdapterMakeOneShot must exist for the atomic suspended-requeue guard")
	CriticalPos := InStr(Body, 'PreviousCritical := Critical("On")')
	FiredPos := InStr(Body, 'BoundHandle["Fired"]')
	RequeuePos := InStr(Body, "SetTimer(requeued, -500)")
	RestorePos := InStr(Body, "Critical(PreviousCritical)", false, RequeuePos)
	Assert(CriticalPos > 0 && FiredPos > CriticalPos && RequeuePos > CriticalPos,
		"the one-shot must enter Critical before any handle state can race a suspended re-queue (AHK-160)")
	Assert(RestorePos > RequeuePos,
		"the suspended re-queue must stay non-interruptible until the native callback is armed (AHK-160)")
}
Test("TimerScheduler: suspended re-queue ownership is atomic (AHK-160)", _TSO_SuspendedRequeueOwnershipIsAtomic)
