; tests/meta/test_crash_report_sysinfo_dedup.ahk

; ==============================================================================
; MODULE: CrashReport_Build SysInfo Dedup Meta Test
; DESCRIPTION:
; Regression guard: CrashReport_Build's own comment already promised running
; "the healthcheck EXACTLY ONCE per crash and reuse its result for both the
; enriched system fields and the adapter / session block below" — but the code
; computed Sys via an independent _CrashReport_SysInfo() call BEFORE HealthCheck_Run
; ever ran, silently breaking that stated invariant for the "enriched system
; fields" half. _HealthCheck_SysInfo() (reached via HealthCheck_Run()["sys"]) does
; the EXACT same WMI ConnectServer + 3x RegRead + git subprocess Sleep-poll as
; _CrashReport_SysInfo(), so every crash paid that blocking cost TWICE on the
; deferred-timer pseudo-thread that still shares the keyboard hook (Pattern:
; deferred crash-report still blocks the keyboard-hook thread).
;
; The fix reuses HC["sys"] when HealthCheck_Run succeeded, only falling back to
; a fresh _CrashReport_SysInfo() probe if it did not.
;
; SCOPE: source introspection of lib/crash_reporter.ahk's CrashReport_Build.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================================
; ======================================================================
; ======= 1/ Sys reuses HC["sys"] instead of a second full probe =======
; ======================================================================
; ======================================================================

_CRSD_CheckSysReusesHealthcheck() {
	Body := _DriverFuncBody("CrashReport_Build")
	Assert(Body != "", "CrashReport_Build must exist in lib/crash_reporter.ahk")

	HcPos  := InStr(Body, "HealthCheck_Run()")
	SysPos := InStr(Body, "Sys := ")
	Assert(HcPos > 0, "CrashReport_Build must call HealthCheck_Run()")
	Assert(SysPos > 0, "CrashReport_Build must assign Sys")

	; Sys must be assigned AFTER HealthCheck_Run() has run, not before — otherwise
	; it cannot reuse HC's own sys block and pays the WMI/RegRead/git cost twice.
	Assert(SysPos > HcPos,
		'CrashReport_Build must assign Sys AFTER HealthCheck_Run() so it can reuse '
		. 'HC["sys"] instead of independently re-probing WMI/RegRead/git '
		. '(crash-report-sysinfo-dedup)')

	Assert(InStr(Body, 'HC["sys"]') > 0,
		'CrashReport_Build must reuse HC["sys"] for its system-info block instead '
		. 'of unconditionally calling _CrashReport_SysInfo() a second time '
		. '(crash-report-sysinfo-dedup)')
}
Test("crash_reporter: CrashReport_Build reuses HC[sys] instead of double-probing WMI/RegRead/git (crash-report-sysinfo-dedup)",
	_CRSD_CheckSysReusesHealthcheck)





; ========================================================================
; ========================================================================
; ======= 2/ Every field CrashReport_Build reads from Sys is still =======
; ========================================================================
; ========================================================================
; =======    produced by _HealthCheck_SysInfo ==========================
; ======================================================================
; ======================================================================

_CRSD_CheckHealthcheckSysHasAllFields() {
	HcSysBody := _DriverFuncBody("_HealthCheck_SysInfo")
	Assert(HcSysBody != "", "_HealthCheck_SysInfo must exist in ui/healthcheck/helpers.ahk")

	for _, Key in ["os_name", "os_build", "os_arch", "ahk_version", "ahk_bitness",
		"cpu_name", "cpu_cores", "ram_total_gb", "ram_free_gb",
		"screen_res", "dpi", "dpi_scale", "locale", "git_hash"]
		Assert(InStr(HcSysBody, 'Info["' . Key . '"]') > 0,
			'_HealthCheck_SysInfo must still set Info["' . Key . '"] — CrashReport_Build reads it '
			. 'from the reused HC["sys"] block (crash-report-sysinfo-dedup)')
}
Test("crash_reporter: _HealthCheck_SysInfo still produces every field CrashReport_Build's Report reads (crash-report-sysinfo-dedup)",
	_CRSD_CheckHealthcheckSysHasAllFields)
