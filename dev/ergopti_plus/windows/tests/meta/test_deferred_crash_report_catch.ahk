; tests/meta/test_deferred_crash_report_catch.ahk

; ==============================================================================
; MODULE: Deferred Crash Report Bare-Try Meta Test (Pattern 3)
; DESCRIPTION:
; Regression guard for the documented "bare try with no catch" anti-pattern
; (docs/PROJECT_MEMORY.md's project-ahk-invariant-incomplete-application), as
; it applies to the crash-reporting pipeline's own safety net.
; _ErgoptiDeferredCrashReport wrapped CrashReport_Build/CrashReport_PromptUser
; in a bare try with no catch, so a failure inside the safety net itself was
; completely silent — no trace of either the original crash or this one.
;
; SCOPE: source introspection of infra/error_net.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================================
; ============================================================
; ======= 1/ _ErgoptiDeferredCrashReport has a catch ==========
; ============================================================
; ============================================================

_DCRC_CheckCatchPresent() {
	Body := _DriverFuncBody("_ErgoptiDeferredCrashReport")
	Assert(Body != "", "_ErgoptiDeferredCrashReport must exist in infra/error_net.ahk")

	TryPos := InStr(Body, "CrashReport_Build(")
	Assert(TryPos > 0, "_ErgoptiDeferredCrashReport must still call CrashReport_Build")

	CatchPos := InStr(Body, "} catch", , TryPos)
	Assert(CatchPos > 0,
		"_ErgoptiDeferredCrashReport must have a catch clause -- this IS the safety net, so a bare try with no catch means a failure inside the crash-reporting pipeline itself is completely silent (project-ahk-invariant-incomplete-application)")

	CatchBody := SubStr(Body, CatchPos, 250)
	Assert(InStr(CatchBody, "Logger") > 0,
		"_ErgoptiDeferredCrashReport's catch must log the failure so it is diagnosable instead of silently invisible")
}
Test("error-net: _ErgoptiDeferredCrashReport has a logging catch around the crash pipeline (bare-try-anti-pattern)",
	_DCRC_CheckCatchPresent)
