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

_KLPFWF_RefusalPreservesPrivacy(Field) {
	_KLRDC_Reset()
	Root := _KLRDC_Root()
	Script := Root . "refused_worker.ahk"
	Stage := Root . "unexpected-stage.json"
	PrivateMarker := "synthetic-private-worker-argument"
	Handle := 0
	Receipt := 0
	try {
		; Minimal owners allow the production argument-validation branch to run
		; without initializing any reader, logger, hook or resident configuration.
		Source := Chr(0xFEFF) . "#Requires AutoHotkey v2.0`n#Warn All, StdOut`n"
			. 'global KLRCache := {disposable: false}' . "`n"
			. 'global KLWConst := {}' . "`n"
			. '#Include ' . A_ScriptDir . '\..\modules\keylogger\keylogger_prefetch.ahk' . "`n"
			. 'KLPF_WorkerMain()' . "`nExitApp(92)`n"
		AssertTrue(FSWriteCreateDurable(Script, Source) != 0)
		Done(Code, Out, Err) {
			Receipt := [Code, KLPF_WorkerDiagnostic(Out, Err), Out . Err]
		}
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut", Script, "--keylogger-prefetch-worker",
				Field = "dashboard" ? PrivateMarker : "typing", Root,
				Field = "mode" ? PrivateMarker : "full", Stage, Root,
				"500", "1000", "2000", "3000", "30", "100"], Done)
		AssertTrue(Handle.start())
		Started := A_TickCount
		while !IsObject(Receipt) && TickElapsed(Started) < 5000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertTrue(IsObject(Receipt), "the real worker must deliver its refusal")
		AssertEqual(2, Receipt[1], "invalid arguments must reach the production refusal branch")
		AssertContains(Receipt[2], "unsupported dashboard/mode pair",
			"the parent must retain the structural reason for rejection")
		AssertFalse(InStr(Receipt[2], PrivateMarker),
			"the parent diagnostic must not copy arbitrary worker argument values")
		AssertFalse(InStr(Receipt[3], PrivateMarker),
			"bounded parent formatting must not merely hide a leak in the raw worker output")
		AssertFalse(FSExists(Stage), "argument refusal must precede projection publication")
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate())
		_KLRDC_Cleanup()
	}
}
for Field in ["dashboard", "mode"]
	Test("keylogger prefetch worker: private " . Field . " refusal (klpf-worker-refusal-privacy)",
		_KLRDC_CheckTeardown.Bind(_KLPFWF_RefusalPreservesPrivacy.Bind(Field)))
