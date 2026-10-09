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
	Watchdog := _StripFullLineComments(
		_DriverFuncBody("_SuspendStateWatchdog"))
	Dispatch := _StripFullLineComments(
		_DriverFuncBody("_LLM_NavEventOwnerApplyExternalSuspendTransition"))
	Assert(Watchdog != "" and Dispatch != "",
		"the suspend watchdog and its delegated edge dispatcher must remain discoverable")

	BusyCheck := InStr(Watchdog, "if _TransitionBusy")
	BusySet := InStr(Watchdog, "_TransitionBusy := true", true, BusyCheck)
	DispatchPos := InStr(Watchdog,
		"_LLM_NavEventOwnerApplyExternalSuspendTransition(", true, BusySet)
	EnterArg := InStr(Watchdog, "Ergopti_OnSuspendEnter", true, DispatchPos)
	ResumeArg := InStr(Watchdog, "Ergopti_OnSuspendResume", true, EnterArg)
	FinallyPos := InStr(Watchdog, "finally", true, ResumeArg)
	BusyClear := InStr(Watchdog, "_TransitionBusy := false", true, FinallyPos)
	Assert(BusyCheck > 0 and BusySet > BusyCheck,
		"_SuspendStateWatchdog must guard against interleaved transitions with a _TransitionBusy flag (or Critical)")
	Assert(DispatchPos > BusySet and EnterArg > DispatchPos
		and ResumeArg > EnterArg and FinallyPos > ResumeArg,
		"the delegated Enter/Resume reactor dispatch must remain inside the transition-busy transaction")
	Assert(BusyClear > FinallyPos,
		"the transition-busy guard must be reset in a finally so a throwing reactor never latches it")

	SuspendedBranch := InStr(Dispatch, "if Suspended")
	EnterCall := InStr(Dispatch, "EnterFn.Call()", true, SuspendedBranch)
	ResumeCall := InStr(Dispatch, "ResumeFn.Call()", true, EnterCall)
	Assert(SuspendedBranch > 0 and EnterCall > SuspendedBranch
		and ResumeCall > EnterCall,
		"the delegated edge dispatcher must still invoke exactly the selected enter or resume reactor")
}
Test("lifecycle: suspend enter/resume reactors are serialized against a rapid double-toggle",
	_STS_TransitionSerialized)
