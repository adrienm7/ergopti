; tests/unit/modules/keymap/test_layout_registry_late_poll.ahk

; ==============================================================================
; MODULE: Layout Registry Later Poll Ownership Tests
; DESCRIPTION:
; An admitted native-facade request must retain exact retirement after a later
; poll cannot schedule its successor. Terminal business observations are saved
; before explicit fixture cleanup, so cleanup cannot fabricate a successful test.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRLP_Case(RefuseLater) {
	global _HTTP_CURL_ABORT_TIMER, _HTTP_CURL_CLEANUP_TIMER
	PreviousCritical := Critical("On")
	SavedAbort := _HTTP_CURL_ABORT_TIMER, SavedCleanup := _HTTP_CURL_CLEANUP_TIMER
	Directory := _LCR_Directory(), State := _ManagedCurlControlState(), Queue := [], Results := []
	ScheduleCalls := 0, Job := 0, OriginalPoll := 0, Observed := 0
	State["retire"] := false
	Schedule(Callback, Delay) {
		ScheduleCalls += 1
		if RefuseLater && ScheduleCalls >= 2
			throw Error("Expected failure after the first accepted registry poll.")
		Queue.Push(Callback)
	}
	try {
		Transport := Map("managed", true, "request", _LRR_Factory.Bind(State), "schedule", Schedule)
		Job := LayoutRegistry_Request("https://example.invalid/index.json", Directory . "response.download",
			Map(), 30000, Transport, (Status, Etag, Detail, Owner) => Results.Push(Status))
		Request := State["request"]
		AssertEqual(1, State["spawns"])
		AssertEqual(1, Queue.Length, "the first poll schedule is really admitted")
		AssertFalse(Job.Settled)
		AssertFalse(Request.Completed)
		OriginalPoll := Queue.RemoveAt(1)
		ScheduleFailure := 0
		try OriginalPoll.Call()
		catch as Failure
			ScheduleFailure := Failure
		AssertTrue(ScheduleCalls >= 2, "the exact bound later poll must reach its next scheduling boundary")
		if IsObject(ScheduleFailure)
			AssertContains(ScheduleFailure.Message, "Expected failure after the first accepted registry poll.")
		AssertFalse(Request.Completed, "the process is still unretired at the refused boundary")
		_LRR_Terminal(State, false)
		AssertTrue(Request.Completed)
		if !RefuseLater
			_LRR_Poll(Queue)
		RetireReady := LayoutRegistry_RetireDownloads()
		Observed := {Callbacks: Results.Length, Settled: Job.Settled, Exists: !!FileExist(Request.OutputPath),
			Busy: FileReadActivityBusy(Request.OutputPath), Owners: _LayoutRegistryDownloadOwners().Count,
			Ready: RetireReady, ScheduleCalls: ScheduleCalls, Refused: IsObject(ScheduleFailure)}
		FileAppend("# layout-registry-late-poll " . (RefuseLater ? "late-refusal" : "healthy")
			. " callbacks=" . Observed.Callbacks . " settled=" . Observed.Settled . " exists=" . Observed.Exists
			. " busy=" . Observed.Busy . " owners=" . Observed.Owners . " retire_ready=" . Observed.Ready
			. " schedules=" . Observed.ScheduleCalls . " exception=" . Observed.Refused . "`n", "*")
	} finally {
		try {
			State["retire"] := true
			if State.Has("request")
				AssertTrue(State["request"].Abort())
			if IsObject(OriginalPoll)
				OriginalPoll.Call()
			for Callback in Queue
				Callback.Call()
			Queue.Length := 0
			AssertTrue(LayoutRegistry_RetireDownloads())
			_ManagedCurlControlRelease(State)
			DirDelete(Directory, true)
		} finally {
			if !IsObject(SavedAbort) && IsObject(_HTTP_CURL_ABORT_TIMER)
				SetTimer(_HTTP_CURL_ABORT_TIMER, 0)
			if !IsObject(SavedCleanup) && IsObject(_HTTP_CURL_CLEANUP_TIMER)
				SetTimer(_HTTP_CURL_CLEANUP_TIMER, 0)
			_HTTP_CURL_ABORT_TIMER := SavedAbort, _HTTP_CURL_CLEANUP_TIMER := SavedCleanup
			Critical(PreviousCritical)
		}
	}
	AssertEqual(1, Observed.Callbacks, "a failed later poll must retain business completion and cleanup recovery")
	AssertTrue(Observed.Settled)
	AssertFalse(Observed.Exists || Observed.Busy)
	AssertEqual(0, Observed.Owners)
	AssertTrue(Observed.Ready)
}
Test("layout registry custody: admitted later poll retains completion (layout-registry-late-poll)", _LRLP_Case.Bind(false))
Test("layout registry custody: refused later poll retains retirement (layout-registry-late-poll)", _LRLP_Case.Bind(true))
