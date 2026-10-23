; static/ergopti_plus/windows/tests/unit/modules/keystats/metrics/test_metrics_delta_lifecycle.ahk

; ==============================================================================
; MODULE: Metrics Delta Lifecycle Tests
; DESCRIPTION: Private deltas never publish over reusable snapshots or leak stages.
; ==============================================================================

#Requires AutoHotkey v2.0

_MDL_Terminal(Receipt, Outcome, Status, Stage) {
	Receipt["calls"] += 1
	Receipt["status"] := Status
	Receipt["stage"] := Stage
	Receipt["busy"] := KLPFWorker.jobs.Has("typing")
	if Status = "ok" {
		Receipt["bytes"] := FileRead(Stage, "UTF-8")
		if Outcome = "throw"
			throw Error("fixture terminal refused delta")
		if Outcome = "refuse"
			return false
	}
	return KLWV_OnBuildTerminal("typing", 71, Status, Stage)
}

_MDL_RetiresStage(Mode, Outcome) {
	global KLPF_LAST_JSON
	SavedJobs := KLPFWorker.jobs
	SavedSpawn := KLPFWorker.spawn_fn
	SavedWindows := KLWV.windows
	SavedPush := KLWV.first_paint_push_fn
	SavedDrain := KLWV.ingest_drain_timer_fn
	SavedSuspended := A_IsSuspended
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	Path := ""
	Stage := ""
	Request := ""
	OwnsPath := false
	_KLRDC_Reset()
	try {
		Root := _KLRDC_Root()
		Path := KLPF_PrefetchPath("typing", Root)
		AssertFalse(FSExists(Path), "fixture must exclusively own the canonical snapshot")
		OwnsPath := true
		Full := '{"revision":"full"}'
		Delta := '{"revision":"delta"}'
		AssertTrue(FSWriteDurable(Path, Full))
		KLPF_LAST_JSON := Map(Path, Full)
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := (*) => {start: (*) => true, terminate: (*) => true}
		KLWV.first_paint_push_fn := 0
		KLWV.ingest_drain_timer_fn := (*) => true
		View := _MCR_View(() => 0)
		Entry := Map("epoch", 71, "webview", View, "metrics_dir", Root,
			"first_paint_done", true, "full_build_done", true)
		KLWV.windows := Map("typing", Entry)
		Receipt := Map("calls", 0)
		AssertTrue(KLPF_RequestBuild("typing", Root, Mode, 71,
			_MDL_Terminal.Bind(Receipt, Outcome), true, Map("checkpoint", "owned")))
		Job := KLPFWorker.jobs["typing"]
		Stage := Job["stage"]
		Request := Job["request"]
		AssertEqual("owned", JsonParse(FileRead(Request, "UTF-8"))["checkpoint"],
			"worker request must retain its captured checkpoint until completion")
		AssertTrue(FSWriteDurable(Stage, Delta))
		if Outcome = "stale"
			Entry["epoch"] := 72
		if Outcome = "canceled"
			AssertTrue(KLPF_CancelBuild("typing"))
		NeedsFull := Outcome = "full_required" || Outcome = "paused_full_required"
		if Outcome = "paused_full_required"
			Suspend(true)
		ExitCode := NeedsFull ? KLPFWorker.FULL_REQUIRED_EXIT_CODE : 0
		KLPF_OnWorkerDone("typing", Job["generation"], ExitCode, "", "")
		AssertEqual(1, Receipt["calls"], "late completion must not repeat a canceled terminal")
		AssertTrue(Receipt["busy"], "job ownership must span synchronous delivery")
		ExpectedStatus := NeedsFull ? "full_required" : (Outcome = "canceled" ? "canceled" : "ok")
		AssertEqual(ExpectedStatus, Receipt["status"])
		if NeedsFull {
			AssertFalse(Entry["full_build_done"])
			AssertEqual("full", Entry["pending_ingest_mode"], "historical recovery must survive suspension")
			if Outcome = "paused_full_required" {
				AssertFalse(KLWV_DrainPendingIngest("typing", 71), "pause must not start a replacement worker")
				Suspend(false)
				AssertEqual("full", Entry["pending_ingest_mode"], "resume must retain the pending full rebuild")
			}
		}
		if ExpectedStatus = "ok" {
			AssertEqual(Stage, Receipt["stage"])
			AssertEqual(Delta, Receipt["bytes"], "private bytes must exist throughout the callback")
		}
		AssertEqual(0, View.Messages.Length, "rejected or stale work must not reach the window")
		AssertFalse(FSExists(Stage), "all terminal outcomes must retire the private file")
		AssertFalse(FSExists(Request), "all terminal outcomes must retire their checkpoint request")
		AssertEqual(0, KLPFWorker.jobs.Count)
		AssertEqual(Full, FileRead(Path, "UTF-8"))
		AssertEqual(Full, KLPF_LAST_JSON[Path], "delta failure cannot invalidate the complete RAM snapshot")
	} finally {
		Suspend(SavedSuspended)
		if Stage != "" && FSExists(Stage)
			AssertTrue(FSDelete(Stage))
		if Request != "" && FSExists(Request)
			AssertTrue(FSDelete(Request))
		if OwnsPath && FSExists(Path)
			AssertTrue(FSDelete(Path))
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.spawn_fn := SavedSpawn
		KLWV.windows := SavedWindows
		KLWV.first_paint_push_fn := SavedPush
		KLWV.ingest_drain_timer_fn := SavedDrain
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		_KLRDC_Cleanup()
	}
}

for Mode in ["live", "manifest"]
	for Outcome in ["throw", "refuse", "stale", "canceled", "full_required", "paused_full_required"]
		Test("metrics delta: " . Mode . " " . Outcome . " retires its stage (metrics-delta-lifecycle)",
			_KLRDC_CheckTeardown.Bind(_MDL_RetiresStage.Bind(Mode, Outcome)))

; An incomplete full read is delivered to its window from the private stage,
; never published over the reusable snapshot nor kept in RAM; the window keeps
; no complete history from it and arms a bounded retry. The warning and the
; recovery of that read kind are each logged once (windows-metrics-incomplete-read).
_MDL_IncompleteFullIsShownNotPublished() {
	global KLPF_LAST_JSON, _LOGGER_TEST_SINK, _LOGGER_WARN_ENABLED, _LOGGER_INFO_ENABLED
	SavedJobs := KLPFWorker.jobs
	SavedSpawn := KLPFWorker.spawn_fn
	SavedReads := KLPFWorker.incomplete_reads
	SavedWindows := KLWV.windows
	SavedPush := KLWV.first_paint_push_fn
	SavedDrain := KLWV.ingest_drain_timer_fn
	SavedFullTimer := KLWV.full_build_timer_fn
	SavedSink := _LOGGER_TEST_SINK
	SavedWarn := _LOGGER_WARN_ENABLED
	SavedInfo := _LOGGER_INFO_ENABLED
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	Path := ""
	OwnsPath := false
	Stages := []
	Lines := []
	_KLRDC_Reset()
	try {
		_LOGGER_WARN_ENABLED := true
		_LOGGER_INFO_ENABLED := true
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Root := _KLRDC_Root()
		Path := KLPF_PrefetchPath("typing", Root)
		AssertFalse(FSExists(Path), "fixture must exclusively own the canonical snapshot")
		OwnsPath := true
		Full := '{"revision":"complete"}'
		Partial := '{"revision":"partial","metrics_manifest_incomplete":true,"_prefetch_data":{"historical":{},"today":{},"incomplete":true}}'
		AssertTrue(FSWriteDurable(Path, Full))
		KLPF_LAST_JSON := Map(Path, Full)
		KLPFWorker.jobs := Map()
		KLPFWorker.incomplete_reads := Map()
		KLPFWorker.spawn_fn := (*) => {start: (*) => true, terminate: (*) => true}
		KLWV.first_paint_push_fn := 0
		KLWV.ingest_drain_timer_fn := (*) => true
		Armed := []
		KLWV.full_build_timer_fn := (Callback, Period) => (Armed.Push(Period), true)
		View := _MCR_View(() => 0)
		Entry := Map("epoch", 71, "webview", View, "metrics_dir", Root,
			"first_paint_done", true, "full_build_done", true)
		KLWV.windows := Map("typing", Entry)
		for Round in ["incomplete", "incomplete", "ok"] {
			Messages := View.Messages.Length
			AssertTrue(KLPF_RequestBuild("typing", Root, "full", 71,
				KLWV_OnFullBuildTerminal.Bind("typing", 71, 0)))
			Job := KLPFWorker.jobs["typing"]
			Stages.Push(Job["stage"])
			AssertTrue(FSWriteDurable(Job["stage"], Round = "ok" ? Full : Partial))
			KLPF_OnWorkerDone("typing", Job["generation"],
				Round = "ok" ? 0 : KLPFWorker.INCOMPLETE_EXIT_CODE,
				"keystats-prefetch-worker: incomplete read (manifest/titles rc=1).", "")
			AssertEqual(0, KLPFWorker.jobs.Count)
			AssertFalse(FSExists(Job["stage"]), Round . ": the private stage must be retired")
			if Round = "incomplete" {
				AssertEqual(Messages + 1, View.Messages.Length, "the partial read must reach its window")
				AssertContains(View.Messages[-1], '"revision":"partial"')
				AssertEqual(Full, FileRead(Path, "UTF-8"), "a partial read must not replace the published snapshot")
				AssertEqual(Full, KLPF_LAST_JSON[Path], "a partial read must not replace the RAM snapshot")
				AssertFalse(Entry["full_build_done"], "the window must not keep a partial history as complete")
				AssertTrue(Entry.Has("full_build_retry_owner"), "the window must read the history again")
			}
		}
		AssertEqual(2, Armed.Length, "each incomplete read arms one bounded retry")
		Warnings := 0, Recoveries := 0
		for Line in Lines {
			if InStr(Line, "Metrics history read 'typing:full' was incomplete")
				Warnings += 1
			if InStr(Line, "Metrics history read 'typing:full' is complete again")
				Recoveries += 1
		}
		AssertEqual(1, Warnings, "the incomplete read is warned once, not on every retry")
		AssertEqual(1, Recoveries, "its recovery is logged once")
		AssertEqual(0, KLPFWorker.incomplete_reads.Count)
	} finally {
		LoggerSetTestSink(SavedSink)
		_LOGGER_WARN_ENABLED := SavedWarn
		_LOGGER_INFO_ENABLED := SavedInfo
		for Stage in Stages
			if FSExists(Stage)
				AssertTrue(FSDelete(Stage))
		if OwnsPath && FSExists(Path)
			AssertTrue(FSDelete(Path))
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.spawn_fn := SavedSpawn
		KLPFWorker.incomplete_reads := SavedReads
		KLWV.windows := SavedWindows
		KLWV.first_paint_push_fn := SavedPush
		KLWV.ingest_drain_timer_fn := SavedDrain
		KLWV.full_build_timer_fn := SavedFullTimer
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		_KLRDC_Cleanup()
	}
}
Test("metrics delta: an incomplete full read is shown, never published, retried (windows-metrics-incomplete-read)",
	_KLRDC_CheckTeardown.Bind(_MDL_IncompleteFullIsShownNotPublished))
