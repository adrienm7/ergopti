; tests/meta/test_error_handler_heavy_diagnostics.ahk

; ==============================================================================
; MODULE: Error-Handler Heavy-Diagnostics Guard Meta Test
; DESCRIPTION:
; Static source guard for the "error-handler-heavy-diagnostics" finding.
;
; The global error handler builds a crash report on an arbitrary point of
; execution (potentially mid-keystroke) with the keyboard already degraded.
; CrashReport_Build used to invoke HealthCheck_Run() TWICE — once for enriched
; system fields and again for the adapter/session block. HealthCheck_Run
; re-validates every port adapter and is non-trivial work, so the second
; redundant run only widens the input-dead window.
;
; The fix runs HealthCheck_Run() exactly once near the top of CrashReport_Build,
; caches it in a local, and reuses it for both consumers. This test asserts
; CrashReport_Build calls HealthCheck_Run() AT MOST ONCE — a regression that adds
; a second call fails CI. Meta-static because crash_reporter.ahk is not part of
; the headless run_all include graph (it depends on healthcheck + updater at call
; time), so it cannot be exercised behaviourally without hanging the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_EHHD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Counts non-overlapping occurrences of Needle in Hay.
_EHHD_CountOccurrences(Hay, Needle) {
	Count := 0
	Pos := 1
	while (Pos := InStr(Hay, Needle, , Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_EHHD_HealthCheckRunAtMostOnce() {
	Src := _EHHD_ReadSource("lib/crash_reporter.ahk")
	Seg := _DriverFuncBody("CrashReport_Build")
	Assert(Seg != "", "CrashReport_Build(ErrorObj) must exist in crash_reporter.ahk")
	Runs := _EHHD_CountOccurrences(Seg, "HealthCheck_Run()")
	Assert(Runs <= 1,
		"CrashReport_Build must invoke HealthCheck_Run() at most ONCE and reuse the cached result — a second re-validation of every adapter widens the input-dead window after an uncaught error (found " . Runs . " calls)")
}
Test("crash_reporter: CrashReport_Build calls HealthCheck_Run at most once (error-handler-heavy-diagnostics)", _EHHD_HealthCheckRunAtMostOnce)
