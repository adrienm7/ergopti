; tests/meta/test_healthcheck_sysinfo_git_nonblocking.ahk

; ==============================================================================
; MODULE: HealthCheck SysInfo Git Non-blocking Meta Test
; DESCRIPTION:
; Static source guard for the "_HealthCheck_SysInfo blocking git" finding
; (healthcheck-sysinfo-git-runwait-freeze).
;
; _HealthCheck_SysInfo() previously called:
;   RunWait(A_ComSpec . " /c git ... rev-parse --short HEAD > ...")
; This synchronous call has no timeout. It is reached via the call chain
; CrashReport_Build -> HealthCheck_Run -> _HealthCheck_SysInfo, which fires
; from the global error handler with the keyboard already degraded. A stalled
; git (unavailable, network drive, credential prompt) freezes input for up to
; 30 seconds.
;
; The fix mirrors the pattern already used in modules/diagnostics/crash_reporter.ahk: replace
; RunWait with a non-blocking Run + 500 ms poll so the stall budget is bounded.
; These tests assert the blocking form is gone and the deadline pattern is in
; place.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================





; ====================================================
; ====================================================
; ======= 2/ Non-blocking git assertions =============
; ====================================================
; ====================================================

_HCSNB_SysInfoIsNonBlocking() {
	Body := _DriverFuncBody("_HealthCheck_SysInfo")
	Assert(Body != "", "_HealthCheck_SysInfo must exist in the ui/healthcheck module")
	Assert(InStr(Body, "RunWait(") == 0,
		"_HealthCheck_SysInfo must not use blocking RunWait for git — can freeze the crash handler path")
	Assert(InStr(Body, "Run(") > 0,
		"_HealthCheck_SysInfo must use non-blocking Run() for git")
	; A bounded poll can be written either as a deadline (`A_TickCount + budget`)
	; or as an elapsed check (`A_TickCount - StartTick < budget`); both cap the
	; stall budget. The implementation uses the elapsed form, so accept either.
	HasBound := (InStr(Body, "A_TickCount + ") > 0) || (InStr(Body, "A_TickCount - ") > 0)
	Assert(HasBound,
		"_HealthCheck_SysInfo must bound the git poll by elapsed time — either a deadline "
		. "(A_TickCount + budget) or an elapsed check (A_TickCount - start < budget)")
}
Test("healthcheck: _HealthCheck_SysInfo uses non-blocking Run + bounded deadline for git (healthcheck-sysinfo-git-runwait-freeze)", _HCSNB_SysInfoIsNonBlocking)
