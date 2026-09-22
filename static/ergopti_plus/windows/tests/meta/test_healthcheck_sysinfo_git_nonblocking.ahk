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
; The first fix bounded the wait with a non-blocking Run + 500 ms poll. The
; commit now comes from DiagSnapshot_ResolveCommit — the compiled build's
; BUNDLE_COMMIT stamp, else the checkout's HEAD read straight from .git — so
; there is no subprocess left to stall, and a compiled release (which has no
; checkout) no longer reports an empty commit. These tests assert both.
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
	for _, Name in ["_HealthCheck_SysInfo", "_CrashReport_SysInfo"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist in the driver")
		Assert(InStr(Body, "RunWait(") == 0,
			Name . " must not use blocking RunWait — can freeze the crash handler path")
		Assert(InStr(Body, "rev-parse") == 0,
			Name . " must not spawn git: the commit is read from the build stamp or .git, "
			. "and a compiled release has no checkout for git to answer from")
		Assert(InStr(Body, "DiagSnapshot_ResolveCommit(") > 0,
			Name . " must take the commit from the shared resolver the boot snapshot uses")
	}
}
Test("healthcheck: _HealthCheck_SysInfo reads the commit without a git subprocess (healthcheck-sysinfo-git-runwait-freeze)", _HCSNB_SysInfoIsNonBlocking)
