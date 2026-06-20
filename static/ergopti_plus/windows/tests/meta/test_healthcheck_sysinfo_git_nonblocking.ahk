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
; The fix mirrors the pattern already used in lib/crash_reporter.ahk: replace
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

; Reads a windows/-relative source file. A_ScriptDir is the runner dir
; (tests/); its parent is the windows/ driver root.
_HCSNB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the full function body — from its declaration to the first closing
; brace at column 0 (AHK functions close with `}` flush-left). Returns "" when
; the declaration is absent.
_HCSNB_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}





; ====================================================
; ====================================================
; ======= 2/ Non-blocking git assertions =============
; ====================================================
; ====================================================

_HCSNB_SysInfoIsNonBlocking() {
	Src := _HCSNB_ReadSource("lib/healthcheck.ahk")
	Body := _DriverFuncBody("_HealthCheck_SysInfo")
	Assert(Body != "", "_HealthCheck_SysInfo must exist in healthcheck.ahk")
	Assert(InStr(Body, "RunWait(") == 0,
		"_HealthCheck_SysInfo must not use blocking RunWait for git — can freeze the crash handler path")
	Assert(InStr(Body, "Run(") > 0,
		"_HealthCheck_SysInfo must use non-blocking Run() for git")
	Assert(InStr(Body, "A_TickCount + ") > 0,
		"_HealthCheck_SysInfo must have a bounded poll deadline for the git subprocess")
}
Test("healthcheck: _HealthCheck_SysInfo uses non-blocking Run + bounded deadline for git (healthcheck-sysinfo-git-runwait-freeze)", _HCSNB_SysInfoIsNonBlocking)
