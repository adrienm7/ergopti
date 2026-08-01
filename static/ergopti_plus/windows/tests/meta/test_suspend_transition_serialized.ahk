; tests/meta/test_suspend_transition_serialized.ahk

; ==============================================================================
; MODULE: Suspend enter/resume reactors are serialized
; DESCRIPTION:
; _SuspendStateWatchdog runs both from a 500 ms repeating timer and directly on
; each toggle. AHK pseudo-threads are interruptible, so a rapid double-toggle (two
; suspend toggles within a few hundred ms) could interrupt Ergopti_OnSuspendEnter's
; long teardown with Ergopti_OnSuspendResume, leaving a resumed driver half torn
; down (dead pointer watch, stale deps timer, orphaned process kills). The reactor
; dispatch must be serialized behind a transition-busy guard so the opposite edge is
; deferred to the next watchdog tick. (F21, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_STS_TransitionSerialized() {
	Body := _DriverFuncBody("_SuspendStateWatchdog")
	Assert(Body != "", "_SuspendStateWatchdog must exist in infra/lifecycle.ahk")

	BusyPos := InStr(Body, "_TransitionBusy")
	EnterPos := InStr(Body, "Ergopti_OnSuspendEnter()")
	ResumePos := InStr(Body, "Ergopti_OnSuspendResume()")
	Assert(BusyPos > 0,
		"_SuspendStateWatchdog must guard against interleaved transitions with a _TransitionBusy flag (or Critical)")
	Assert(EnterPos > BusyPos && ResumePos > BusyPos,
		"the Enter/Resume reactor dispatch must run behind the transition-busy guard so a rapid double-toggle cannot interleave them")
	Assert(InStr(Body, "finally") > 0 && InStr(Body, "_TransitionBusy := false") > 0,
		"the transition-busy guard must be reset in a finally so a throwing reactor never latches it")
}
Test("lifecycle: suspend enter/resume reactors are serialized against a rapid double-toggle",
	_STS_TransitionSerialized)
