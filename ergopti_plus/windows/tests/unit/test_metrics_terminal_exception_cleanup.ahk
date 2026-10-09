; tests/unit/test_metrics_terminal_exception_cleanup.ahk

; ==============================================================================
; MODULE: Metrics Terminal Exception Cleanup Tests
; DESCRIPTION: Callback exceptions cannot strand jobs or their private stages.
; ==============================================================================

#Requires AutoHotkey v2.0

_MTEC_RejectTerminal(Cancel, NonError) {
	SavedJobs := KLPFWorker.jobs
	Root := A_Temp . "\metrics_terminal_" . A_ScriptHwnd . "_" . Cancel . "_" . NonError
	AssertTrue(DllCall("CreateDirectoryW", "Str", Root, "Ptr", 0, "Int"))
	Calls := 0
	_Reject(*) {
		Calls += 1
		throw NonError ? "synthetic private callback value" : Error("synthetic terminal failure")
	}
	try {
		Stage := Root . "\stage.json"
		Request := Root . "\request.json"
		FileAppend("{}", Stage, "UTF-8-RAW")
		FileAppend("{}", Request, "UTF-8-RAW")
		Handle := {terminate: (*) => true}
		KLPFWorker.jobs := Map("range:typing", Map("generation", 17,
			"kind", "range", "stage", Stage, "request", Request,
			"handle", Handle, "on_terminal", _Reject))
		Escaped := false
		Result := unset
		try Result := Cancel ? KLPF_CancelBuild("range:typing")
			: KLPF_CompleteJob("range:typing", 17, "ok", Stage)
		catch Any
			Escaped := true
		AssertFalse(Escaped, "a terminal exception must not escape the cleanup boundary")
		AssertEqual(Cancel, Result, "completion rejects delivery while cancellation confirms cleanup")
		AssertEqual(1, Calls)
		AssertEqual(0, KLPFWorker.jobs.Count, "a rejected callback cannot strand the active job")
		AssertFalse(FileExist(Stage), "an unaccepted range stage remains producer-owned")
		AssertFalse(FileExist(Request), "request metadata must be retired")
		AssertFalse(KLPF_CompleteJob("range:typing", 17, "ok", Stage))
		AssertEqual(1, Calls, "a duplicate completion cannot redeliver the callback")
	} finally {
		KLPFWorker.jobs := SavedJobs
		DirDelete(Root, true)
	}
}

for Cancel in [false, true]
	for NonError in [false, true]
		Test("metrics terminal: cancel=" . Cancel . " non-error=" . NonError
			. " (metrics-terminal-exception-cleanup)", _MTEC_RejectTerminal.Bind(Cancel, NonError))
