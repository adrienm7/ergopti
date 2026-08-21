; tests/meta/test_crash_build_offthread.ahk

; ==============================================================================
; MODULE: Crash-Report Build Off-Thread Meta Test
; DESCRIPTION:
; Static source guard for finding crash-build-offthread (F-H06).
;
; ErgoptiGlobalErrorHandler ran CrashReport_Build + CrashReport_PromptUser inline.
; CrashReport_Build does a WMI ConnectServer + RegRead + a git subprocess Sleep-poll
; + a full healthcheck adapter re-validation — ~100-500 ms of blocking work. The
; handler can fire mid-keystroke (OnError, or HookDispatcher's per-subscriber catch
; on the keyboard thread), so this froze the keyboard on the first error per
; signature. The already-fixed HIGH-02 crash MsgBox was the documented sibling; the
; sysinfo collection was the missed one. The fix keeps the cheap modifier-release +
; LoggerError synchronous and defers the build/prompt via a one-shot SetTimer.
;
; Meta-static: asserts the handler defers via SetTimer and no longer calls
; CrashReport_Build inline.
; ==============================================================================

#Requires AutoHotkey v2.0


_CBOT_AssertDeferred() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Body != "", "ErgoptiGlobalErrorHandler must exist")
	Assert(InStr(Body, "SetTimer") > 0,
		"ErgoptiGlobalErrorHandler must defer the crash-report build via SetTimer so it never blocks the input/dispatch thread (crash-build-offthread)")
	Assert(!InStr(Body, "CrashReport_Build("),
		"ErgoptiGlobalErrorHandler must not call CrashReport_Build inline — defer it off the input thread (crash-build-offthread)")
	Helper := _DriverFuncBody("_ErgoptiDeferredCrashReport")
	Assert(Helper != "", "_ErgoptiDeferredCrashReport (the deferred worker) must exist")
	Assert(InStr(Helper, "ShellRunner_Spawn(") > 0,
		"_ErgoptiDeferredCrashReport must launch a real child-process worker")
	for Forbidden in ["CrashReport_Build(", "HealthCheck_Run(", "ComObject(", "RegRead(", "Sleep(", "FileOpen("]
		Assert(InStr(Helper, Forbidden) = 0,
			"the deferred AHK timer must not perform blocking diagnostic work: " . Forbidden)
}
Test("error-net: crash-report build is deferred off the input thread (crash-build-offthread)", _CBOT_AssertDeferred)
