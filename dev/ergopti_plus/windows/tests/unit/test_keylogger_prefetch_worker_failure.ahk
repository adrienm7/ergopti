; tests/unit/test_keylogger_prefetch_worker_failure.ahk

; ==============================================================================
; MODULE: Keylogger Prefetch Worker Failure Diagnostics
; DESCRIPTION:
; A caught worker exception previously exited one with no transcript, so the
; resident process could report only "no output captured". The child must report
; a bounded structural diagnostic without exposing its error message or payload.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLPFWF_ReportPreservesPrivacy() {
	Captured := ""
	_KLPFWF_Write(Line) {
		Captured := Line
	}
	PrivateMarker := "do-not-log-worker-private-marker"
	Failure := Error(PrivateMarker)
	KLPF_WorkerReportFailure("timing decode", Failure, _KLPFWF_Write)
	AssertContains(Captured, "keylogger-prefetch-worker: timing decode failed (Error",
		"a caught worker exception must identify the safe failure phase and type")
	AssertContains(Captured, "`n", "the worker failure transcript must be line framed")
	Assert(InStr(Captured, PrivateMarker) = 0,
		"the worker transcript must not disclose an exception message that can carry typed data")
}
Test("keylogger prefetch worker: caught errors emit safe diagnostics (klpf-worker-failure)",
	_KLPFWF_ReportPreservesPrivacy)
