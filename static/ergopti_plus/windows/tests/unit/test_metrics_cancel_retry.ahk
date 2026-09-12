; tests/unit/test_metrics_cancel_retry.ahk

; ==============================================================================
; MODULE: Metrics Cancellation Retry Tests
; DESCRIPTION: Unconfirmed termination retains ownership without blocking recovery.
; ==============================================================================

#Requires AutoHotkey v2.0

_MCTR_RetryTermination(Mode) {
	SavedJobs := KLPFWorker.jobs
	Stage := _FSWL_Path()
	Calls := 0
	Terminals := []
	Nested := []
	Terminate(*) {
		Calls += 1
		Nested.Push(KLPF_CancelBuild("typing"))
		; A terminate port may deliver its completion before returning.
		KLPF_OnWorkerDone("typing", 71, 0, "", "")
		if Calls = 1 {
			if Mode = "throw"
				throw Error("synthetic termination refusal")
			return Mode = "invalid" ? "true" : false
		}
		return true
	}
	try {
		AssertFalse(FSExists(Stage))
		FileAppend("synthetic stage", Stage, "UTF-8-RAW")
		Job := Map("generation", 71, "stage", Stage, "kind", "prefetch",
			"destination", Stage . ".destination", "handle", {terminate: Terminate},
			"on_terminal", (Status, *) => Terminals.Push(Status))
		KLPFWorker.jobs := Map("typing", Job)
		AssertFalse(KLPF_CancelBuild("typing"), "unconfirmed termination must retain cleanup ownership")
		AssertEqual(1, Calls)
		AssertTrue(KLPFWorker.jobs.Has("typing") && KLPFWorker.jobs["typing"] == Job)
		AssertTrue(FSExists(Stage), "a possibly live producer must retain its private file")
		AssertFalse(FSExists(Stage . ".destination"), "reentrant completion must not publish a canceled worker")
		AssertEqual(0, Terminals.Length, "no terminal may run before termination is confirmed")
		AssertTrue(KLPF_CancelAll(), "a later cancellation must retry the retained process owner")
		AssertEqual(2, Calls, "recovery must actually ask the process handle again")
		AssertEqual(0, KLPFWorker.jobs.Count)
		AssertFalse(FSExists(Stage))
		AssertEqual(1, Terminals.Length)
		AssertEqual("canceled", Terminals[1])
		AssertEqual(2, Nested.Length)
		for Result in Nested
			AssertFalse(Result, "reentrant cancellation must not steal an active termination call")
		KLPF_OnWorkerDone("typing", 71, 0, "", "")
		AssertTrue(KLPF_CancelAll())
		AssertEqual(1, Terminals.Length, "late completion and repeated cancellation must stay terminal")
	} finally {
		KLPFWorker.jobs := SavedJobs
		if FSExists(Stage)
			FileDelete(Stage)
		if FSExists(Stage . ".destination")
			FileDelete(Stage . ".destination")
	}
}
for Mode in ["false", "throw", "invalid"]
	Test("Metrics cancel: termination recovery after " . Mode . " (metrics-cancel-retry)",
		_MCTR_RetryTermination.Bind(Mode))
