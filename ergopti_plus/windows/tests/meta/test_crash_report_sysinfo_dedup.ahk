; tests/meta/test_crash_report_sysinfo_dedup.ahk

; ==============================================================================
; MODULE: CrashReport_Build SysInfo Dedup Meta Test
; DESCRIPTION:
; Regression guard: CrashReport_Build runs the healthcheck EXACTLY ONCE per
; crash and reuses its result for the system fields, rather than paying the
; slow processor query twice on the deferred-timer pseudo-thread that still
; shares the keyboard hook (Pattern: deferred crash-report still blocks the
; keyboard-hook thread).
;
; The diagnostics snapshot now reads the processor from the registry, so the
; report takes it from the snapshot's hardware section and asks WMI only when
; the snapshot has none (the healthcheck itself failed).
;
; SCOPE: source introspection of modules/diagnostics/crash_reporter.ahk and
; ui/healthcheck/helpers.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================================
; ====================================================================
; ======= 1/ Sys reuses the snapshot instead of a second probe =======
; ====================================================================
; ====================================================================

_CRSD_CheckSysReusesHealthcheck() {
	Body := _DriverFuncBody("CrashReport_Build")
	Assert(Body != "", "CrashReport_Build must exist in modules/diagnostics/crash_reporter.ahk")

	HcPos  := InStr(Body, "HealthCheck_Run()")
	SysPos := InStr(Body, "Sys := ")
	Assert(HcPos > 0, "CrashReport_Build must call HealthCheck_Run()")
	Assert(SysPos > HcPos,
		"CrashReport_Build must assign Sys AFTER HealthCheck_Run() so it can reuse the snapshot "
		. "(crash-report-sysinfo-dedup)")
	Assert(InStr(Body, '_CrashReport_SysInfo(Sections.Get("hardware", Map()))') > 0,
		"CrashReport_Build must hand the snapshot's hardware section to _CrashReport_SysInfo "
		. "(crash-report-sysinfo-dedup)")

	SysBody := _DriverFuncBody("_CrashReport_SysInfo")
	CpuPos := InStr(SysBody, 'Hardware.Has("cpu")')
	WmiPos := InStr(SysBody, "WbemScripting")
	Assert(CpuPos > 0 && WmiPos > CpuPos,
		"_CrashReport_SysInfo must reuse the snapshot's processor and ask WMI only without one "
		. "(crash-report-sysinfo-dedup)")
}
Test("crash_reporter: CrashReport_Build reuses the snapshot's processor instead of a second WMI query (crash-report-sysinfo-dedup)",
	_CRSD_CheckSysReusesHealthcheck)





; ===============================================================
; ===============================================================
; ======= 2/ The snapshot reads the processor without WMI =======
; ===============================================================
; ===============================================================

_CRSD_CheckHardwareIsInProcess() {
	Body := _DriverFuncBody("_HealthCheck_Hardware")
	Assert(Body != "", "_HealthCheck_Hardware must exist in ui/healthcheck/helpers.ahk")
	Assert(InStr(Body, "ProcessorNameString") > 0,
		"_HealthCheck_Hardware must read the processor from the registry")
	Assert(InStr(Body, "WbemScripting") = 0 && InStr(Body, "ComObject(") = 0,
		"_HealthCheck_Hardware must not query WMI on the thread that serves the keyboard hook")
}
Test("crash_reporter: the snapshot's processor comes from the registry, not WMI (crash-report-sysinfo-dedup)",
	_CRSD_CheckHardwareIsInProcess)
