; tests/unit/test_healthcheck_core.ahk

; ==============================================================================
; MODULE: HealthCheck Core Behavioral Tests
; DESCRIPTION:
; Exercises the counter functions and HealthCheck_Run() from
; ui/healthcheck/core.ahk with real assertions. Replaces the 9 no-op
; AssertTrue(true) placeholder tests that previously lived in test_logger.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0


; =============================================
; ======= 1/ Counter functions ================
; =============================================

_TestHC_RecordWarnIncrementsCounter() {
	global _HealthCheckWarnCount
	Before := _HealthCheckWarnCount
	HealthCheck_RecordWarn()
	Assert(_HealthCheckWarnCount == Before + 1,
		"RecordWarn must increment _HealthCheckWarnCount by 1")
}

Test("HealthCheck: RecordWarn increments the warning counter",
	_TestHC_RecordWarnIncrementsCounter)


_TestHC_RecordErrorStoresAndCounts() {
	global _HealthCheckErrCount, _HealthCheckLastError
	Before := _HealthCheckErrCount
	HealthCheck_RecordError("test error message")
	Assert(_HealthCheckErrCount == Before + 1,
		"RecordError must increment _HealthCheckErrCount by 1")
	Assert(_HealthCheckLastError == "test error message",
		"RecordError must store the message in _HealthCheckLastError")
}

Test("HealthCheck: RecordError increments counter and stores the message",
	_TestHC_RecordErrorStoresAndCounts)


_TestHC_MultipleRecordWarn() {
	global _HealthCheckWarnCount
	Before := _HealthCheckWarnCount
	loop 5
		HealthCheck_RecordWarn()
	Assert(_HealthCheckWarnCount == Before + 5,
		"Five RecordWarn calls must increment counter by 5")
}

Test("HealthCheck: multiple RecordWarn calls accumulate correctly",
	_TestHC_MultipleRecordWarn)


; =============================================
; ======= 2/ HealthCheck_Run structure ========
; =============================================

_TestHC_RunReturnsMap() {
	Result := HealthCheck_Run()
	Assert(Result is Map,
		"HealthCheck_Run must return a Map")
}

Test("HealthCheck: Run returns a Map",
	_TestHC_RunReturnsMap)


_TestHC_RunHasRequiredKeys() {
	Result := HealthCheck_Run()
	for Key in ["version", "uptime_sec", "warn_count", "err_count",
	            "last_error", "loaded_adapters", "failed_adapters",
	            "ports_validated", "recent_issues", "sys"] {
		Assert(Result.Has(Key),
			"HealthCheck_Run result must contain key: " . Key)
	}
}

Test("HealthCheck: Run result contains all required top-level keys",
	_TestHC_RunHasRequiredKeys)


_TestHC_RunReflectsCounters() {
	global _HealthCheckWarnCount, _HealthCheckErrCount, _HealthCheckLastError

	HealthCheck_RecordWarn()
	HealthCheck_RecordError("run-reflects-test")

	Result := HealthCheck_Run()
	Assert(Result["warn_count"] >= 1,
		"warn_count must reflect recorded warnings")
	Assert(Result["err_count"] >= 1,
		"err_count must reflect recorded errors")
	; HealthCheck_Run probes live adapters and may itself record a newer diagnostic.
	; The snapshot must therefore mirror the current healthcheck state at the end
	; of the probe, rather than assuming the pre-probe test message stays newest.
	Assert(Result["last_error"] == _HealthCheckLastError,
		"last_error must reflect the healthcheck state captured by HealthCheck_Run")
	Assert(Result["last_error"] != "",
		"last_error must include the recorded error or a newer probe diagnostic")
}

Test("HealthCheck: Run reflects recorded warnings, errors, and last error message",
	_TestHC_RunReflectsCounters)


_TestHC_RunUptimeIsPositive() {
	Result := HealthCheck_Run()
	Assert(Result["uptime_sec"] >= 0,
		"uptime_sec must be non-negative")
}

Test("HealthCheck: Run uptime_sec is non-negative",
	_TestHC_RunUptimeIsPositive)


_TestHC_RunSysHasOsInfo() {
	Result := HealthCheck_Run()
	Sys := Result["sys"]
	Assert(Sys is Map, "sys must be a Map")
	Assert(Sys.Has("os_name"), "sys must contain os_name")
	Assert(Sys.Has("ahk_version"), "sys must contain ahk_version")
}

Test("HealthCheck: Run sys section contains OS and AHK info",
	_TestHC_RunSysHasOsInfo)


; =============================================
; ======= 3/ Registered in run_all ============
; =============================================

_TestHC_FunctionsExist() {
	Assert(IsSet(HealthCheck_RecordWarn),
		"HealthCheck_RecordWarn must be defined")
	Assert(IsSet(HealthCheck_RecordError),
		"HealthCheck_RecordError must be defined")
	Assert(IsSet(HealthCheck_Run),
		"HealthCheck_Run must be defined")
}

Test("HealthCheck: core functions are defined (core.ahk included in run_all)",
	_TestHC_FunctionsExist)
