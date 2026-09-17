; tests/unit/test_metrics_cancel_retry.ahk

; ==============================================================================
; MODULE: Metrics Cancellation Retry Tests
; DESCRIPTION: Unconfirmed termination retains ownership without blocking recovery.
; ==============================================================================

#Requires AutoHotkey v2.0

_MCTR_RetryTermination(Mode, Automatic := false) {
	global _KLPF_CLEANUP_TIMER, _KLPF_CLEANUP_DEBTS
	SavedJobs := KLPFWorker.jobs
	SavedTimer := _KLPF_CLEANUP_TIMER
	SavedDebts := _KLPF_CLEANUP_DEBTS
	SavedSchedule := KLPFWorker.cleanup_schedule_fn
	Timers := []
	Schedule(Callback, Delay) {
		Timers.Push(Map("callback", Callback, "delay", Delay))
		return true
	}
	Stage := _FSWL_Path()
	Calls := 0
	Terminals := []
	Nested := []
	Terminate(*) {
		Calls += 1
		Nested.Push(KLPF_CancelBuild("typing"))
		; A terminate port may deliver its completion before returning.
		KLPF_OnWorkerDone("typing", 71, 0, "", "")
		if Calls <= (Automatic ? 2 : 1) {
			if Mode = "throw"
				throw Error("synthetic termination refusal")
			return Mode = "invalid" ? "true" : false
		}
		return true
	}
	try {
		_KLPF_CLEANUP_TIMER := 0
		_KLPF_CLEANUP_DEBTS := Map()
		KLPFWorker.cleanup_schedule_fn := Schedule
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
		if Automatic {
			AssertEqual(1, Timers.Length, "unconfirmed termination needs an automatic cleanup owner")
			AssertEqual(-KLPF_CLEANUP_RETRY_MS, Timers[1]["delay"])
			Timers[1]["callback"].Call()
			AssertEqual(2, Calls)
			AssertEqual(0, Terminals.Length)
			AssertTrue(FSExists(Stage))
			AssertEqual(2, Timers.Length, "continued refusal must rearm one bounded retry")
			Timers[1]["callback"].Call()
			AssertEqual(2, Calls, "a stale cleanup token cannot consume the new retry")
			Timers[2]["callback"].Call()
			AssertEqual(0, _KLPF_CLEANUP_TIMER)
		} else
			AssertTrue(KLPF_CancelAll(), "a later cancellation must retry the retained process owner")
		AssertEqual(Automatic ? 3 : 2, Calls, "recovery must actually ask the process handle again")
		AssertEqual(0, KLPFWorker.jobs.Count)
		AssertFalse(FSExists(Stage))
		AssertEqual(1, Terminals.Length)
		AssertEqual("canceled", Terminals[1])
		AssertEqual(Automatic ? 3 : 2, Nested.Length)
		for Result in Nested
			AssertFalse(Result, "reentrant cancellation must not steal an active termination call")
		KLPF_OnWorkerDone("typing", 71, 0, "", "")
		AssertTrue(KLPF_CancelAll())
		AssertEqual(1, Terminals.Length, "late completion and repeated cancellation must stay terminal")
	} finally {
		KLPFWorker.jobs := SavedJobs
		_KLPF_CLEANUP_TIMER := SavedTimer
		_KLPF_CLEANUP_DEBTS := SavedDebts
		KLPFWorker.cleanup_schedule_fn := SavedSchedule
		if FSExists(Stage)
			FileDelete(Stage)
		if FSExists(Stage . ".destination")
			FileDelete(Stage . ".destination")
	}
}
for Mode in ["false", "throw", "invalid"]
	Test("Metrics cancel: termination recovery after " . Mode . " (metrics-cancel-retry)",
		_MCTR_RetryTermination.Bind(Mode))

for Mode in ["false", "throw", "invalid"]
	Test("Metrics cancel: automatic termination recovery after " . Mode . " (metrics-cancel-auto-retry)",
		_MCTR_RetryTermination.Bind(Mode, true))
