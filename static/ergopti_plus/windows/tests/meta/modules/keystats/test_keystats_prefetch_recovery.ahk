; tests/meta/modules/keystats/test_keystats_prefetch_recovery.ahk

; ==============================================================================
; MODULE: Keystats Prefetch Recovery and Range Stage
; DESCRIPTION:
; First-paint and full historical builds retry their terminal failures
; finitely within one epoch, live ingest coalesces behind the full seed,
; and the private range stage keeps exact cleanup ownership.
; ==============================================================================

#Requires AutoHotkey v2.0





_KLPFW_FirstPaintPush(which) {
	global _KLPFW_FirstPaintPushes, _KLPFW_FirstPaintPushResult
	_KLPFW_FirstPaintPushes += 1
	; A successful fake delivery must carry the same provenance receipt as the
	; real bridge; a Boolean alone no longer certifies a complete history.
	if _KLPFW_FirstPaintPushResult && which = "typing" {
		Entry := KLWV.windows[which]
		Entry["last_delivery_seed"] := Map("version", 2,
			"store", ConfigTransitionNormalizeConfigDir(Entry["metrics_dir"]),
			"day", FormatTime(A_Now, "yyyy-MM-dd"), "ledgers", Map(),
			"walker_timings", KL_JsonEncode(KLW_TimingValues()),
			"projection_format", KLR_CACHE_FORMAT_VERSION)
	}
	return _KLPFW_FirstPaintPushResult
}

_KLPFW_FirstPaintTimer(callback, period) {
	global _KLPFW_FirstPaintTimers
	_KLPFW_FirstPaintTimers.Push(Map("callback", callback, "period", period))
	return true
}

_KLPFW_FullBuildTimer(callback, period) {
	global _KLPFW_FullBuildTimers
	_KLPFW_FullBuildTimers.Push(Map("callback", callback, "period", period))
	return true
}

_KLPFW_IngestDrainTimer(callback, period) {
	global _KLPFW_IngestDrainTimers
	_KLPFW_IngestDrainTimers.Push(Map("callback", callback, "period", period))
	return true
}

_KLPFW_PublishWithIngest(stage, destination) {
	global _KLPFW_PublishCount, _KLPFW_PublishSawOwner
	_KLPFW_PublishCount += 1
	if !KLPFWorker.jobs.Has("typing")
		_KLPFW_PublishSawOwner := false
	; Model a five-second ingest timer interrupting atomic publication. It must
	; observe the publishing generation and leave one dirty bit behind it.
	KLWV_NotifyIngest("live")
	try FileDelete(stage)
	return true
}

_KLPFW_FirstPaintTerminalRecoveryIsBoundedAndEpochFenced() {
	global _KLPFW_FirstPaintTimers, _KLPFW_FullBuildTimers
	global _KLPFW_FirstPaintPushes, _KLPFW_FirstPaintPushResult
	old_windows := KLWV.windows
	old_push := KLWV.first_paint_push_fn
	old_timer := KLWV.first_paint_timer_fn
	old_full_timer := KLWV.full_build_timer_fn
	KLWV.windows := Map("typing", Map("epoch", 41, "metrics_dir", A_Temp . "\ergopti_metrics"))
	KLWV.first_paint_push_fn := _KLPFW_FirstPaintPush
	KLWV.first_paint_timer_fn := _KLPFW_FirstPaintTimer
	KLWV.full_build_timer_fn := _KLPFW_FullBuildTimer
	_KLPFW_FirstPaintTimers := []
	_KLPFW_FullBuildTimers := []
	_KLPFW_FirstPaintPushes := 0
	_KLPFW_FirstPaintPushResult := false
	try {
		Assert(KLWV_OnFirstBuildTerminal("typing", 41, 0, "failed"),
			"a first-paint worker failure must schedule recovery")
		Assert(_KLPFW_FirstPaintTimers.Length = 1
				&& _KLPFW_FirstPaintTimers[1]["period"] = -KLWV.FIRST_PAINT_RETRY_MS,
			"first-paint failure must arm the named bounded retry delay")
		Assert(!KLWV.windows["typing"].Has("first_paint_done"),
			"a scheduled retry must not falsely declare first paint complete")

		_KLPFW_FirstPaintTimers := []
		Assert(!KLWV_OnFirstBuildTerminal("typing", 40, 0, "failed")
				&& _KLPFW_FirstPaintTimers.Length = 0,
			"a terminal from an older WebView epoch must not schedule work in its replacement")

		Assert(!KLWV_OnFirstBuildTerminal("typing", 41, KLWV.FIRST_PAINT_MAX_RETRIES, "failed"),
			"an exhausted first-paint failure with no sidecar must choose live-tick fallback")
		Assert(_KLPFW_FirstPaintPushes = 1 && KLWV.windows["typing"]["first_paint_done"],
			"retry exhaustion must make exactly one fallback attempt then admit live-tick recovery")

		KLWV.windows["typing"] := Map("epoch", 41, "metrics_dir", A_Temp . "\ergopti_metrics")
		_KLPFW_FirstPaintTimers := []
		_KLPFW_FullBuildTimers := []
		_KLPFW_FirstPaintPushResult := true
		Assert(KLWV_OnFirstBuildTerminal("typing", 41, 0, "canceled"),
			"an old canceled first-paint worker must queue its bounded retry")
		stale_retry := _KLPFW_FirstPaintTimers[1]["callback"]
		Assert(KLWV_OnFirstBuildTerminal("typing", 41, 0, "ok"),
			"a replacement first-paint terminal must publish the payload")
		Assert(KLWV.windows["typing"]["first_paint_done"]
				&& _KLPFW_FullBuildTimers.Length = 1
				&& _KLPFW_FullBuildTimers[1]["period"] = -KLWV.FULL_BUILD_DELAY_MS,
			"successful first paint must mark the epoch and arm its full historical phase")
		pushes_after_success := _KLPFW_FirstPaintPushes
		first_timers_after_success := _KLPFW_FirstPaintTimers.Length
		full_timers_after_success := _KLPFW_FullBuildTimers.Length
		stale_retry.Call()
		Assert(_KLPFW_FirstPaintPushes = pushes_after_success
				&& _KLPFW_FirstPaintTimers.Length = first_timers_after_success
				&& _KLPFW_FullBuildTimers.Length = full_timers_after_success,
			"an old cancel retry firing after replacement success must be a complete no-op")
	} finally {
		KLWV.windows := old_windows
		KLWV.first_paint_push_fn := old_push
		KLWV.first_paint_timer_fn := old_timer
		KLWV.full_build_timer_fn := old_full_timer
	}
}

Test("keystats WebView: first-paint terminal failures retry finitely and cannot cross epochs",
	_KLPFW_FirstPaintTerminalRecoveryIsBoundedAndEpochFenced)

_KLPFW_FullBuildRecoveryOwnsEveryWorkerFailure() {
	global _KLPFW_FakeArgs, _KLPFW_FakeTerminated, _KLPFW_FullBuildTimers
	global _KLPFW_IngestDrainTimers
	global _KLPFW_FirstPaintPushes, _KLPFW_FirstPaintPushResult
	old_windows := KLWV.windows
	old_metrics_dir := KLWV.metrics_dir
	old_push := KLWV.first_paint_push_fn
	old_timer := KLWV.full_build_timer_fn
	old_ingest_timer := KLWV.ingest_drain_timer_fn
	old_jobs := KLPFWorker.jobs
	old_generation := KLPFWorker.generation
	old_spawn := KLPFWorker.spawn_fn
	old_publish := KLPFWorker.publish_fn
	KLWV.windows := Map("typing", Map("epoch", 51, "first_paint_done", true,
		"metrics_dir", A_Temp . "\ergopti_metrics"))
	KLWV.metrics_dir := A_Temp . "\ergopti_metrics"
	KLWV.first_paint_push_fn := _KLPFW_FirstPaintPush
	KLWV.full_build_timer_fn := _KLPFW_FullBuildTimer
	KLWV.ingest_drain_timer_fn := _KLPFW_IngestDrainTimer
	KLPFWorker.jobs := Map()
	KLPFWorker.generation := 0
	_KLPFW_FirstPaintPushResult := true
	_KLPFW_FirstPaintPushes := 0
	_KLPFW_FullBuildTimers := []
	_KLPFW_IngestDrainTimers := []
	_KLPFW_FakeArgs := []
	_KLPFW_FakeTerminated := 0
	try {
		KLPFWorker.spawn_fn := _KLPFW_FalseStartSpawn
		Assert(!KLWV_DelayedFullBuild("typing", 51, 0),
			"a false-start historical worker must reject the attempt")
		Assert(_KLPFW_FullBuildTimers.Length = 1
				&& _KLPFW_FullBuildTimers[1]["period"] = -KLWV.FULL_BUILD_RETRY_MS
				&& !KLPFWorker.jobs.Has("typing"),
			"false start must retire ownership and arm one bounded full-build retry")

		_KLPFW_FullBuildTimers := []
		KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
		; Each independent failure scenario receives fresh committed input; a
		; direct attempt-zero call must not bypass the preceding retry owner.
		KLWV_RecordCommittedIngest()
		Assert(KLWV_DelayedFullBuild("typing", 51, 0),
			"the nonzero-exit historical worker must start asynchronously")
		generation := KLPFWorker.jobs["typing"]["generation"]
		KLPF_OnWorkerDone("typing", generation, 1, "", "synthetic failure")
		Assert(_KLPFW_FullBuildTimers.Length = 1 && !KLPFWorker.jobs.Has("typing"),
			"a nonzero worker exit must arm recovery and retire the failed full job")

		_KLPFW_FullBuildTimers := []
		KLPFWorker.publish_fn := _KLPFW_PublishFailed
		KLWV_RecordCommittedIngest()
		Assert(KLWV_DelayedFullBuild("typing", 51, 0),
			"the publication-failure historical worker must start asynchronously")
		generation := KLPFWorker.jobs["typing"]["generation"]
		stage := KLPFWorker.jobs["typing"]["stage"]
		try FileDelete(stage)
		FileAppend("{}", stage, "UTF-8")
		KLPF_OnWorkerDone("typing", generation, 0, "", "")
		Assert(_KLPFW_FullBuildTimers.Length = 1 && !FileExist(stage)
				&& !KLPFWorker.jobs.Has("typing"),
			"atomic publication failure must arm recovery and remove its private stage")
		stale_retry := _KLPFW_FullBuildTimers[1]["callback"]

		_KLPFW_FullBuildTimers := []
		Assert(!KLWV_OnFullBuildTerminal("typing", 50, 0, "failed")
				&& _KLPFW_FullBuildTimers.Length = 0,
			"a historical terminal from an older WebView epoch must be inert")
		Assert(!KLWV_OnFullBuildTerminal("typing", 51, KLWV.FULL_BUILD_MAX_RETRIES, "failed")
				&& KLWV.windows["typing"]["full_build_retry_exhausted"],
			"exhausted immediate retries must leave history pending for the ingest fallback")

		KLPFWorker.publish_fn := _KLPFW_PublishOk
		_KLPFW_FakeArgs := []
		_KLPFW_FakeTerminated := 0
		KLWV_NotifyIngest("live")
		Assert(KLPFWorker.jobs.Has("typing") && _KLPFW_FakeArgs.Length = 1
				&& _KLPFW_TestJobKey(_KLPFW_FakeArgs[1]["args"]) = "typing",
			"the next ingest must launch the missing historical projection asynchronously")
		Assert(_KLPFW_TestModeArg(_KLPFW_FakeArgs[1]["args"]) = "full",
			"the ingest fallback must force full mode instead of publishing live-only data")
		fallback_generation := KLPFWorker.jobs["typing"]["generation"]
		KLWV_NotifyIngest("live")
		Assert(KLPFWorker.jobs["typing"]["generation"] = fallback_generation
				&& _KLPFW_FakeArgs.Length = 1 && _KLPFW_FakeTerminated = 0,
			"a newer live tick must not cancel or replace a full fallback still running")

		stage := KLPFWorker.jobs["typing"]["stage"]
		try FileDelete(stage)
		FileAppend("{}", stage, "UTF-8")
		; Earlier independent revisions can have queued drains. Count the new
		; successor owned by this terminal, not the whole fixture's timer history.
		drains_before_success := _KLPFW_IngestDrainTimers.Length
		KLPF_OnWorkerDone("typing", fallback_generation, 0, "", "")
		Assert(KLWV.windows["typing"]["full_build_done"], "the successful full terminal must close historical recovery")
		AssertEqual(1, _KLPFW_FirstPaintPushes, "the successful full terminal must push once")
		Assert(!KLPFWorker.jobs.Has("typing"), "the successful full terminal must retire its worker")
		AssertEqual(drains_before_success + 1, _KLPFW_IngestDrainTimers.Length,
			"success must defer exactly one new dirty live successor")
		stale_retry.Call()
		Assert(_KLPFW_FakeArgs.Length = 1 && !KLPFWorker.jobs.Has("typing")
				&& _KLPFW_FirstPaintPushes = 1,
			"a retry queued by an older full job must no-op after replacement success")
	} finally {
		KLWV.windows := Map()
		KLPF_CancelBuild("typing")
		KLWV.windows := old_windows
		KLWV.metrics_dir := old_metrics_dir
		KLWV.first_paint_push_fn := old_push
		KLWV.full_build_timer_fn := old_timer
		KLWV.ingest_drain_timer_fn := old_ingest_timer
		KLPFWorker.jobs := old_jobs
		KLPFWorker.generation := old_generation
		KLPFWorker.spawn_fn := old_spawn
		KLPFWorker.publish_fn := old_publish
	}
}

Test("keystats WebView: full historical build retries every terminal failure and falls back through ingest",
	_KLPFW_FullBuildRecoveryOwnsEveryWorkerFailure)

_KLPFW_LiveIngestCoalescesBehindFullSeed() {
	global _KLPFW_FakeArgs, _KLPFW_FakeTerminated, _KLPFW_IngestDrainTimers
	global _KLPFW_FirstPaintPushes, _KLPFW_FirstPaintPushResult
	global _KLPFW_PublishCount, _KLPFW_PublishSawOwner
	old_windows := KLWV.windows
	old_metrics_dir := KLWV.metrics_dir
	old_push := KLWV.first_paint_push_fn
	old_ingest_timer := KLWV.ingest_drain_timer_fn
	old_jobs := KLPFWorker.jobs
	old_generation := KLPFWorker.generation
	old_spawn := KLPFWorker.spawn_fn
	old_publish := KLPFWorker.publish_fn
	KLWV.windows := Map("typing", Map(
		"epoch", 61,
		"metrics_dir", A_Temp . "\ergopti_metrics",
		"first_paint_done", true,
		"full_build_done", false,
		"pending_ingest_mode", "",
		"ingest_drain_armed", false
	))
	KLWV.metrics_dir := A_Temp . "\ergopti_metrics"
	KLWV.first_paint_push_fn := _KLPFW_FirstPaintPush
	KLWV.ingest_drain_timer_fn := _KLPFW_IngestDrainTimer
	KLPFWorker.jobs := Map()
	KLPFWorker.generation := 0
	KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
	KLPFWorker.publish_fn := _KLPFW_PublishWithIngest
	_KLPFW_FakeArgs := []
	_KLPFW_FakeTerminated := 0
	_KLPFW_IngestDrainTimers := []
	_KLPFW_FirstPaintPushes := 0
	_KLPFW_FirstPaintPushResult := true
	_KLPFW_PublishCount := 0
	_KLPFW_PublishSawOwner := true
	try {
		; Model live ingest at t=2, 5, 10, and 15 seconds. The first tick
		; starts the missing historical seed; all later ticks only mark it dirty.
		for _, tick in [2, 5, 10, 15]
			KLWV_NotifyIngest("live")
		Assert(_KLPFW_FakeArgs.Length = 1 && _KLPFW_FakeTerminated = 0
				&& KLPFWorker.jobs.Has("typing"),
			"five-second live ingest must never cancel or replace the in-flight full seed")
		full_generation := KLPFWorker.jobs["typing"]["generation"]
		Assert(_KLPFW_TestModeArg(_KLPFW_FakeArgs[1]["args"]) = "full"
				&& KLWV.windows["typing"]["pending_ingest_mode"] = "live",
			"the first tick must force full history while later ticks collapse into one dirty live mode")

		full_stage := KLPFWorker.jobs["typing"]["stage"]
		try FileDelete(full_stage)
		FileAppend("{}", full_stage, "UTF-8")
		_KLPFW_FakeArgs[1]["done"].Call(0, "", "")
		Assert(KLWV.windows["typing"]["full_build_done"]
				&& !KLPFWorker.jobs.Has("typing")
				&& _KLPFW_IngestDrainTimers.Length = 1,
			"full-seed success must retire its owner and schedule exactly one dirty successor")
		Assert(_KLPFW_PublishCount = 1 && _KLPFW_PublishSawOwner,
			"atomic publication must retain generation ownership against a re-entrant ingest tick")

		_KLPFW_IngestDrainTimers[1]["callback"].Call()
		Assert(_KLPFW_FakeArgs.Length = 2 && KLPFWorker.jobs.Has("typing")
				&& _KLPFW_TestModeArg(_KLPFW_FakeArgs[2]["args"]) = "live"
				&& KLWV.windows["typing"]["pending_ingest_mode"] = "",
			"the full terminal must drain at most one coalesced live rebuild")
		live_generation := KLPFWorker.jobs["typing"]["generation"]
		for _, tick in [20, 25, 30]
			KLWV_NotifyIngest("live")
		Assert(_KLPFW_FakeArgs.Length = 2 && _KLPFW_FakeTerminated = 0
				&& KLPFWorker.jobs["typing"]["generation"] = live_generation,
			"live ticks during a live rebuild must coalesce without replacing its generation")

		live_stage := KLPFWorker.jobs["typing"]["stage"]
		try FileDelete(live_stage)
		FileAppend("{}", live_stage, "UTF-8")
		_KLPFW_FakeArgs[2]["done"].Call(0, "", "")
		Assert(_KLPFW_IngestDrainTimers.Length = 2
				&& !KLPFWorker.jobs.Has("typing") && _KLPFW_PublishCount = 1
				&& _KLPFW_FirstPaintPushes = 2 && !FileExist(live_stage),
			"a dirty live owner must deliver once, retire its stage, preserve the full snapshot and schedule one successor")
		_KLPFW_IngestDrainTimers[2]["callback"].Call()
		newest_generation := KLPFWorker.jobs["typing"]["generation"]
		Assert(_KLPFW_FakeArgs.Length = 3 && newest_generation > live_generation,
			"three intervening live ticks must create exactly one newer generation")

		; A duplicate completion from the long-finished seed is stale against the
		; current live owner and may neither publish nor evict it.
		_KLPFW_FakeArgs[1]["done"].Call(0, "", "")
		Assert(_KLPFW_PublishCount = 1 && _KLPFW_FirstPaintPushes = 2
				&& KLPFWorker.jobs["typing"]["generation"] = newest_generation,
			"only the current generation may publish or retire dashboard state")
	} finally {
		KLWV.windows := Map()
		KLPF_CancelBuild("typing")
		KLWV.windows := old_windows
		KLWV.metrics_dir := old_metrics_dir
		KLWV.first_paint_push_fn := old_push
		KLWV.ingest_drain_timer_fn := old_ingest_timer
		KLPFWorker.jobs := old_jobs
		KLPFWorker.generation := old_generation
		KLPFWorker.spawn_fn := old_spawn
		KLPFWorker.publish_fn := old_publish
	}
}

Test("keystats prefetch: live ingest coalesces behind full seed and publishes only the current generation",
	_KLPFW_LiveIngestCoalescesBehindFullSeed)


global _KLPFW_CleanupAttempts := 0
global _KLPFW_CleanupCallbacks := []

_KLPFW_DeleteAfterRetry(*) {
	global _KLPFW_CleanupAttempts
	_KLPFW_CleanupAttempts += 1
	return _KLPFW_CleanupAttempts >= 2
}

_KLPFW_CaptureCleanupRetry(Callback, Delay) {
	global _KLPFW_CleanupCallbacks
	_KLPFW_CleanupCallbacks.Push(Map("callback", Callback, "delay", Delay))
	return true
}

_KLPFW_PrivateStageCleanupRetainsOwnership() {
	global _KLPF_CLEANUP_DEBTS, _KLPF_CLEANUP_TIMER
	global _KLPFW_CleanupAttempts, _KLPFW_CleanupCallbacks
	SavedDebts := _KLPF_CLEANUP_DEBTS
	SavedTimer := _KLPF_CLEANUP_TIMER
	SavedSchedule := KLPFWorker.cleanup_schedule_fn
	_KLPF_CLEANUP_DEBTS := Map()
	_KLPF_CLEANUP_TIMER := 0
	KLPFWorker.cleanup_schedule_fn := _KLPFW_CaptureCleanupRetry
	_KLPFW_CleanupAttempts := 0
	_KLPFW_CleanupCallbacks := []
	Stage := A_Temp . "\ergopti_metrics_range_typing.stage.audit.1.json"
	try {
		AssertFalse(KLPF_DeletePrivateStage(Stage, _KLPFW_DeleteAfterRetry),
			"a locked private range stage must report that cleanup is still pending")
		AssertEqual(_KLPF_CLEANUP_DEBTS.Count, 1,
			"a failed deletion must retain the exact private stage as cleanup debt")
		AssertEqual(_KLPFW_CleanupCallbacks.Length, 1,
			"the first cleanup failure must arm one retry owner")
		Assert(_KLPFW_CleanupCallbacks[1]["delay"] < 0,
			"private-stage cleanup retries must be one-shot timers")

		_KLPFW_CleanupCallbacks[1]["callback"].Call()
		AssertEqual(_KLPFW_CleanupAttempts, 2,
			"the retained deletion must be retried until the filesystem accepts it")
		AssertEqual(_KLPF_CLEANUP_DEBTS.Count, 0,
			"only a successful deletion may retire cleanup ownership")
		AssertEqual(_KLPF_CLEANUP_TIMER, 0,
			"the retry timer owner must retire with the final cleanup debt")
		DeleteBody := _DriverFuncBody("KLWV_DeleteRangeStage")
		Assert(InStr(DeleteBody, "KLPF_DeletePrivateStage(stage)") > 0,
			"the delayed WebView cleanup must enter the owned retry protocol")
	} finally {
		_KLPF_CLEANUP_DEBTS := SavedDebts
		_KLPF_CLEANUP_TIMER := SavedTimer
		KLPFWorker.cleanup_schedule_fn := SavedSchedule
	}
}

Test("keystats range stage: deletion failure retains exact retry ownership",
	_KLPFW_PrivateStageCleanupRetainsOwnership)


_KLPFW_RefuseRangeStageDelete(*) {
	return false
}

_KLPFW_RangeDispatchRejectsUnclearedStage() {
	global _KLPFW_FakeArgs, _KLPFW_Terminals
	SavedJobs := KLPFWorker.jobs
	SavedGeneration := KLPFWorker.generation
	SavedSpawn := KLPFWorker.spawn_fn
	SavedDelete := KLPFWorker.range_delete_fn
	KLPFWorker.jobs := Map()
	KLPFWorker.generation := 0
	KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
	KLPFWorker.range_delete_fn := _KLPFW_RefuseRangeStageDelete
	_KLPFW_FakeArgs := []
	_KLPFW_Terminals := []
	try {
		AssertFalse(KLPF_RequestRange("typing", A_Temp . "\metrics",
			_KLPFW_Query(), 41, _KLPFW_RecordTerminal),
			"a private range stage that cannot be cleared must never reach a worker")
		AssertEqual(_KLPFW_FakeArgs.Length, 0,
			"dispatch must stop before spawning against a locked private destination")
		Assert(_KLPFW_Terminals.Length = 1
				&& _KLPFW_Terminals[1]["status"] = "failed",
			"stage cleanup refusal must emit one typed failed terminal")
		AssertFalse(KLPFWorker.jobs.Has("range:typing"),
			"the refused request must retire its scheduler reservation")
	} finally {
		KLPF_CancelBuild("range:typing")
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.generation := SavedGeneration
		KLPFWorker.spawn_fn := SavedSpawn
		KLPFWorker.range_delete_fn := SavedDelete
	}
}

Test("keystats range stage: dispatch rejects an uncleared private destination",
	_KLPFW_RangeDispatchRejectsUnclearedStage)


_KLPFW_DeadOwnerRangeStageIsReaped() {
	DeadPid := 2147483647
	Stage := A_Temp . "\ergopti_metrics_range_typing.stage." . DeadPid . "."
		. KLPF_NewOwnerId() . ".98431.json"
	try {
		FileAppend('{"private":true}', Stage, "UTF-8")
		AssertTrue(FileExist(Stage) != "", "the orphan-reaper fixture must exist")
		KLPF_ReapOrphanRangeStages()
		AssertFalse(FileExist(Stage) != "",
			"normal boot must remove a private range stage whose parent process is dead")
	} finally {
		try FileDelete(Stage)
	}
}

Test("keystats range stage: boot reaps dead-process private data",
	_KLPFW_DeadOwnerRangeStageIsReaped)
