; tests/meta/test_crash_build_offthread.ahk

; ==============================================================================
; MODULE: Crash Report Process Isolation Meta Test
; DESCRIPTION:
; Guards the parent-side boundary for AHK-005. A SetTimer is only another AHK
; logical thread, so the deferred callback must launch the retained mapping
; worker and must never reintroduce blocking diagnostic or payload work into the
; resident interpreter.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ Parent Process Boundary =============
; ================================================
; ================================================

_CBPI_AssertIsolatedWorkerBoundary() {
	Handler := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Handler != "", "ErgoptiGlobalErrorHandler must exist")
	Assert(InStr(Handler, "SetTimer(_ErgoptiDeferredCrashReport") > 0,
		"the input-path handler must schedule only the cheap parent snapshot")
	Assert(!InStr(Handler, "CrashReport_Build("),
		"the input-path handler must not build diagnostics inline")

	Deferred := _DriverFuncBody("_ErgoptiDeferredCrashReport")
	Assert(Deferred != "", "_ErgoptiDeferredCrashReport must exist")
	Assert(InStr(Deferred, "CrashReportWorker_Start(") > 0,
		"the deferred parent callback must transfer ownership to the isolated worker adapter")
	for Forbidden in [
		"CrashReport_Build(", "HealthCheck_Run(", "ComObject(", "RegRead(",
		"Sleep(", "FileOpen(", "CryptoBase64EncodeUtf8(", "ShellRunner_Spawn("
	]
		Assert(InStr(Deferred, Forbidden) = 0,
			"the deferred parent callback must not perform blocking or command-line payload work: " . Forbidden)

	StartBody := _DriverFuncBody("CrashReportWorker_Start")
	Assert(StartBody != "", "CrashReportWorker_Start must exist")
	Assert(InStr(StartBody, "_CrashReportWorkerCreateMapping(") > 0,
		"the worker adapter must stage the payload in its bounded pagefile mapping")
	Assert(InStr(StartBody, "_CrashReportWorkerFallbackArgs(") > 0,
		"the worker adapter must retain an isolated minimal fallback")
}

Test("error-net: crash diagnostics cross an owned process boundary (ahk-005-crash-build-process-isolation)",
	_CBPI_AssertIsolatedWorkerBoundary)
