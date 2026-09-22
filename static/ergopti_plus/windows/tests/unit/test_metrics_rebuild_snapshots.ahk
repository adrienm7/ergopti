; tests/unit/test_metrics_rebuild_snapshots.ahk

; ==============================================================================
; MODULE: Partial Rebuild Snapshot Tests
; DESCRIPTION: A running rebuild reaches the dashboard newest days first.
; ==============================================================================

#Requires AutoHotkey v2.0

_MRS_RetireFiles(Root) {
	for Which in ["typing", "apps"]
		try FileDelete(KLPF_PartialSnapshotPath(Which, Root))
}

; The worker's observer must turn the first rolled-up day into a dashboard
; snapshot for both pages, marked partial, before the rebuild finishes.
_MRS_WorkerPublishesNewestDays() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Root := _KLRDC_Root()
	try {
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger())
		Publisher := KLPFRebuildPublisher(Root)
		Seen := []
		Observe(Info) {
			Publisher.Call(Info)
			if !Info.Has("db") || Info["final"] || Seen.Length
				return
			Path := KLPF_PartialSnapshotPath("typing", Root)
			if FileExist(Path)
				Seen.Push(FileRead(Path, "UTF-8"), FileRead(KLPF_PartialSnapshotPath("apps", Root), "UTF-8"))
		}
		_KLRNF_Build(true, Observe)
		AssertEqual(2, Seen.Length, "a partial snapshot must exist while the rebuild still runs (metrics-rebuild-partial)")
		for Body in Seen {
			Snapshot := JsonParse(Body)
			AssertEqual("2026-03-03", Snapshot["_partial"]["oldest"],
				"the snapshot must say how far back it is rebuilt (metrics-rebuild-partial)")
			AssertTrue(Snapshot["metrics_manifest"].Has("2026-03-03"), "the newest day must be visible first")
			AssertFalse(Snapshot["metrics_manifest"].Has("2026-03-01"),
				"a day not yet rebuilt must not be shown as empty history")
		}
		AssertContains(Seen[1], '"_prefetch_data"', "the typing page needs its range data from the first snapshot")
		AssertTrue(Publisher.Retire())
		AssertFalse(FileExist(KLPF_PartialSnapshotPath("typing", Root)), "a complete snapshot retires the partial ones")
		AssertFalse(FileExist(KLPF_PartialSnapshotPath("apps", Root)))
	} finally {
		_MRS_RetireFiles(Root)
		_KLRDC_Cleanup()
	}
}
Test("metrics rebuild: the worker publishes the newest days first (metrics-rebuild-partial)",
	_KLRDC_CheckTeardown.Bind(_MRS_WorkerPublishesNewestDays))

; The resident forwards each new partial snapshot of its own running job once,
; and never a leftover from a worker that died before this job started.
_MRS_ResidentForwardsPartials() {
	Root := A_Temp . "\ergopti_rebuild_watch_" . A_TickCount . "\"
	DirCreate(Root)
	OldWindows := KLWV.windows
	OldJobs := KLPFWorker.jobs
	Sent := []
	Fake := {}
	Fake.DefineProp("PostWebMessageAsString", {Call: (Self, Message) => Sent.Push(Message)})
	try {
		KLWV.windows := Map("typing", Map("which", "typing", "epoch", 71, "metrics_dir", Root, "webview", Fake))
		KLPFWorker.jobs := Map("typing", Map("generation", 1, "started_at", DateAdd(A_Now, -5, "Seconds")))
		Path := KLPF_PartialSnapshotPath("typing", Root)
		AssertFalse(KLWV_RebuildWatchTick("typing", 71), "nothing to forward before the worker publishes")
		FileAppend('{"_partial":{"oldest":"2026-03-03"}}', Path, "UTF-8-RAW")
		AssertTrue(KLWV_RebuildWatchTick("typing", 71), "a new partial snapshot must reach the page (metrics-rebuild-partial)")
		AssertEqual('{"type":"prefetch","blob":{"_partial":{"oldest":"2026-03-03"}}}', Sent[1])
		AssertFalse(KLWV_RebuildWatchTick("typing", 71), "an unchanged snapshot must not be pushed again")
		KLPFWorker.jobs["typing"]["started_at"] := DateAdd(A_Now, 60, "Seconds")
		KLWV.windows["typing"].Delete("partial_stamp")
		AssertFalse(KLWV_RebuildWatchTick("typing", 71),
			"a snapshot older than the running job belongs to a dead worker")
		KLPFWorker.jobs := Map()
		AssertFalse(KLWV_RebuildWatchTick("typing", 71), "no running projection, nothing to forward")
		AssertEqual(1, Sent.Length)
	} finally {
		KLWV.windows := OldWindows
		KLPFWorker.jobs := OldJobs
		DirDelete(RTrim(Root, "\"), true)
	}
}
Test("metrics rebuild: the resident forwards partial snapshots (metrics-rebuild-partial)",
	_MRS_ResidentForwardsPartials)
