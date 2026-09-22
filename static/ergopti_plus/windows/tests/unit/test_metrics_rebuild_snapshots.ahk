; tests/unit/test_metrics_rebuild_snapshots.ahk

; ==============================================================================
; MODULE: Partial Rebuild Snapshot Tests
; DESCRIPTION: A running rebuild reaches the dashboard newest days first.
; ==============================================================================

#Requires AutoHotkey v2.0

_MRS_RetireFiles(Root) {
	for Which in ["typing", "apps"]
		try FileDelete(KLPF_PartialSnapshotPath(Which, Root))
	try FileDelete(KLPF_RebuildProgressPath(Root))
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
		; Snapshot and progress files live in %TEMP%, outside the fixture root.
		_MRS_RetireFiles(Root)
		DirDelete(RTrim(Root, "\"), true)
	}
}
Test("metrics rebuild: the resident forwards partial snapshots (metrics-rebuild-partial)",
	_MRS_ResidentForwardsPartials)

; The percentage is exact consumed work; the remaining time is the measured
; throughput of this worker, never a timer and never inflated by resumed bytes.
_MRS_ProgressFromThroughput() {
	Info := Map("final", false, "total_bytes", 100000000, "done_bytes", 60000000,
		"run_bytes", 20000000, "elapsed_ms", 40000, "oldest_complete", "2026-03-01")
	Progress := KLPF_RebuildProgress(Info)
	AssertEqual("running", Progress["state"])
	AssertEqual(60, Progress["percent"], "the percentage is consumed bytes over total bytes (metrics-rebuild-progress)")
	AssertEqual(80, Progress["eta_s"],
		"40 MB left at 20 MB per 40 s this run is 80 s, resumed bytes excluded (metrics-rebuild-progress)")
	Info["run_bytes"] := KLPFRebuildPublisher.MIN_ETA_BYTES - 1
	AssertEqual(-1, KLPF_RebuildProgress(Info)["eta_s"], "too little measured work gives no estimate yet")
	Info["final"] := true
	Info["done_bytes"] := Info["total_bytes"]
	Final := KLPF_RebuildProgress(Info)
	AssertEqual("finalizing", Final["state"])
	AssertEqual(100, Final["percent"])
}
Test("metrics rebuild: progress and ETA come from measured work (metrics-rebuild-progress)",
	_MRS_ProgressFromThroughput)

; The worker writes the store's progress while it rebuilds, and retires it with
; the partial snapshots once the complete one is published.
_MRS_WorkerWritesProgress() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Root := _KLRDC_Root()
	try {
		_KLRDC_WriteLedger(_KLRNF_ThreeDayLedger())
		Publisher := KLPFRebuildPublisher(Root)
		States := []
		Observe(Info) {
			Publisher.last_progress := 0
			Publisher.Call(Info)
			States.Push(JsonParse(FileRead(KLPF_RebuildProgressPath(Root), "UTF-8")))
		}
		_KLRNF_Build(true, Observe)
		AssertTrue(States.Length > 2, "every report must reach the progress file")
		AssertEqual("running", States[1]["state"])
		AssertTrue(States[1]["percent"] < 100, "the first report must show unfinished work (metrics-rebuild-progress)")
		AssertEqual("finalizing", States[States.Length]["state"])
		AssertEqual(100, States[States.Length]["percent"])
		AssertTrue(Publisher.Retire())
		AssertFalse(FileExist(KLPF_RebuildProgressPath(Root)), "a complete snapshot retires the progress file")
	} finally {
		_MRS_RetireFiles(Root)
		_KLRDC_Cleanup()
	}
}
Test("metrics rebuild: the worker publishes its progress (metrics-rebuild-progress)",
	_KLRDC_CheckTeardown.Bind(_MRS_WorkerWritesProgress))

; A worker that dies must turn the bar into an error at once; a finished one
; must remove it. A replaced (canceled) job leaves the display to its successor.
_MRS_ResidentSettlesProgress(Status, Expected) {
	Root := A_Temp . "\ergopti_rebuild_settle_" . A_TickCount . "\"
	DirCreate(Root)
	OldWindows := KLWV.windows
	OldJobs := KLPFWorker.jobs
	OldSeams := [KLWV.first_paint_push_fn, KLWV.first_paint_timer_fn, KLWV.full_build_timer_fn,
		KLWV.ingest_drain_timer_fn]
	Sent := []
	Fake := {}
	Fake.DefineProp("PostWebMessageAsString", {Call: (Self, Message) => Sent.Push(Message)})
	try {
		; The real terminal runs; only its push and timers are seams.
		KLWV.first_paint_push_fn := (*) => true
		KLWV.first_paint_timer_fn := (*) => true
		KLWV.full_build_timer_fn := (*) => true
		KLWV.ingest_drain_timer_fn := (*) => true
		KLWV.windows := Map("typing", Map("which", "typing", "epoch", 72, "metrics_dir", Root, "webview", Fake))
		KLPFWorker.jobs := Map("typing", Map("generation", 1, "started_at", DateAdd(A_Now, -5, "Seconds")))
		FileAppend('{"state":"running","percent":12,"eta_s":300}', KLPF_RebuildProgressPath(Root), "UTF-8-RAW")
		AssertTrue(KLWV_RebuildWatchTick("typing", 72))
		AssertEqual('{"type":"rebuild_progress","progress":{"state":"running","percent":12,"eta_s":300}}', Sent[1],
			"the worker's progress must reach the page (metrics-rebuild-progress)")
		KLPFWorker.jobs := Map()
		KLWV_OnBuildTerminal("typing", 72, Status)
		if Expected = "" {
			AssertEqual(1, Sent.Length, "a canceled job leaves the display to its successor")
		} else {
			AssertEqual(2, Sent.Length, "the projection terminal must settle the display (metrics-rebuild-progress)")
			AssertEqual('{"type":"rebuild_progress","progress":{"state":"' . Expected . '"}}', Sent[2],
				"the terminal status must end the progress display (metrics-rebuild-progress)")
			AssertFalse(KLWV_SettleRebuildProgress("typing", 72, Status), "a settled display is not settled twice")
		}
	} finally {
		KLWV.windows := OldWindows
		KLPFWorker.jobs := OldJobs
		KLWV.first_paint_push_fn := OldSeams[1]
		KLWV.first_paint_timer_fn := OldSeams[2]
		KLWV.full_build_timer_fn := OldSeams[3]
		KLWV.ingest_drain_timer_fn := OldSeams[4]
		_MRS_RetireFiles(Root)
		DirDelete(RTrim(Root, "\"), true)
	}
}
for Outcome in [["failed", "failed"], ["ok", "done"], ["canceled", ""]]
	Test("metrics rebuild: a " . Outcome[1] . " worker settles the progress bar (metrics-rebuild-progress)",
		_MRS_ResidentSettlesProgress.Bind(Outcome[1], Outcome[2]))