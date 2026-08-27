; tests/meta/test_keylogger_prefetch_worker.ahk

; ============================================================================== 
; MODULE: Keylogger Prefetch Worker Regression Test
; DESCRIPTION:
; The metrics projection contains SQLite reconstruction and JSON encoding that
; can take seconds.  These guards keep that work in a detached /force worker
; and prove that a superseded completion cannot publish stale dashboard data.
; ============================================================================== 

#Requires AutoHotkey v2.0

_KLPFW_ReadWorkerContract() {
	Request := _DriverFuncBody("KLPF_RequestBuild")
	RangeRequest := _DriverFuncBody("KLPF_RequestRange")
	Done := _DriverFuncBody("KLPF_OnWorkerDone")
	Complete := _DriverFuncBody("KLPF_CompleteJob")
	Worker := _DriverFuncBody("KLPF_WorkerMain")
	First := _DriverFuncBody("KLWV_DelayedFirstPush")
	FirstTerminal := _DriverFuncBody("KLWV_OnFirstBuildTerminal")
	Full := _DriverFuncBody("KLWV_DelayedFullBuild")
	FullTerminal := _DriverFuncBody("KLWV_OnFullBuildTerminal")
	BuildTerminal := _DriverFuncBody("KLWV_OnBuildTerminal")
	FullRetry := _DriverFuncBody("KLWV_ScheduleFullBuildRetry")
	NotifyBody := _DriverFuncBody("KLWV_NotifyIngest")
	Drain := _DriverFuncBody("KLWV_DrainPendingIngest")
	WebviewResume := _DriverFuncBody("KLWV_OnSuspendResume")
	Bridge := _DriverFuncBody("KLWV_OnWebMessage")
	Edge := _DriverFuncBody("KLUI_LaunchWindow")
	SuspendBody := _DriverFuncBody("Ergopti_OnSuspendEnter")
	ResumeBody := _DriverFuncBody("Ergopti_OnSuspendResume")

	Assert(Request != "" && RangeRequest != "" && Done != "" && Complete != "" && Worker != "",
		"keylogger prefetch worker lifecycle functions must exist")
	Assert(InStr(Request, "ShellRunner_Spawn") > 0 && InStr(Request, '"/force"') > 0,
		"KLPF_RequestBuild must start a detached /force worker instead of projecting on the AHK hook thread")
	Assert(InStr(Request, "++KLPFWorker.generation") > 0
			&& InStr(Request, '"stage"') > 0,
		"each worker request must allocate a monotonic generation and private staging path")
	Assert(InStr(Done, 'job["generation"] != generation') > 0
			&& InStr(Done, "KLPF_CompleteJob(") > 0
			&& InStr(Complete, "KLPF_MoveAtomic") > 0,
		"only the current generation may atomically publish and terminally retire its staged JSON")
	Assert(InStr(Request, '"on_terminal"') > 0 && InStr(RangeRequest, '"on_terminal"') > 0
			&& InStr(Complete, "KLPF_InvokeTerminal") > 0,
		"range and prefetch workers must share one typed exact-once terminal protocol")
	Assert(InStr(Worker, "KLPF_BuildAndWriteToPath") > 0
			&& InStr(Worker, "ExitApp(0)") > 0,
		"the worker must produce its own staged file then exit before normal driver boot")
	Assert(InStr(Worker, "KLR_ReadRangeSplitToday") > 0,
		"selected-range SQL projection must run inside the detached worker")

	for _, body in [First, Full, Bridge, Edge] {
		Assert(InStr(body, "KLPF_BuildAndWrite(") = 0,
			"WebView/Edge entry points must never synchronously run KLPF_BuildAndWrite")
		Assert(InStr(body, "KLPF_RequestBuild(") > 0,
			"WebView/Edge entry points must use the worker protocol")
	}
	Assert(InStr(NotifyBody, "KLPF_BuildAndWrite(") = 0
			&& InStr(Drain, "KLPF_BuildAndWrite(") = 0,
		"ingest scheduling and draining must never project synchronously on the hook thread")
	Assert(InStr(SuspendBody, 'KLPF_CancelBuild("typing")') > 0
			&& InStr(SuspendBody, 'KLPF_CancelBuild("apps")') > 0
			&& InStr(SuspendBody, 'KLPF_CancelBuild("range:typing")') > 0,
		"Suspend must terminally cancel every in-flight metrics worker instead of letting SQLite continue while paused")
	Assert(InStr(FirstTerminal, "KLWV_ScheduleFirstPaintRetry") > 0,
		"first-paint failure/cancel terminals must enter bounded recovery rather than disappearing")
	Assert(InStr(Full, "KLWV_OnFullBuildTerminal.Bind") > 0
			&& InStr(FullTerminal, "KLWV_ScheduleFullBuildRetry") > 0
			&& InStr(FullRetry, "FULL_BUILD_MAX_RETRIES") > 0,
		"the deferred historical phase must have an independent bounded terminal-recovery path")
	Assert(InStr(NotifyBody, "KLWV_MarkIngestDirty") > 0
			&& InStr(NotifyBody, "KLWV_DrainPendingIngest") > 0
			&& InStr(Drain, "KLPFWorker.jobs.Has(which)") > 0
			&& InStr(Drain, 'full_build_done') > 0
			&& InStr(Drain, "terminal, false") > 0,
		"ingest must coalesce behind the active owner and force missing history without replacement")
	for _, terminal_body in [FirstTerminal, FullTerminal, BuildTerminal] {
		Assert(InStr(terminal_body, "KLWV_ScheduleIngestDrain") > 0,
			"every prefetch terminal must schedule the one coalesced ingest successor")
	}
	Assert(InStr(WebviewResume, "KLWV_ScheduleIngestDrain") > 0,
		"resume must replay a dirty ingest that could not drain while suspended")
	Assert(InStr(ResumeBody, "KLWV_OnSuspendResume") > 0,
		"resume must flush range, first-paint, and full-build recovery deferred by Suspend")
}

Test("keylogger: prefetch projection is staged by a generation-fenced detached worker",
	_KLPFW_ReadWorkerContract)


_KLPFW_TerminateJoined(*) {
	return true
}

_KLPFW_TerminateUnconfirmed(*) {
	return false
}

_KLPFW_ShutdownOwnsEveryProcessAndStage() {
	FirstOwner := KLPF_NewOwnerId()
	SecondOwner := KLPF_NewOwnerId()
	Assert(FirstOwner != SecondOwner && RegExMatch(FirstOwner, "^[0-9A-Fa-f-]+$"),
		"each parent process must mint an unforgeable stage namespace")
	BuildBody := _DriverFuncBody("KLPF_RequestBuild")
	RangeBody := _DriverFuncBody("KLPF_RequestRange")
	Assert(InStr(BuildBody, "KLPFWorker.owner_id") > 0
		&& InStr(RangeBody, "KLPFWorker.owner_id") > 0,
		"both stage families must include the immutable parent owner id")

	SavedJobs := KLPFWorker.jobs
	try {
		KLPFWorker.jobs := Map()
		for JobKey, TerminateFn in Map(
			"typing", _KLPFW_TerminateJoined,
			"range:typing", _KLPFW_TerminateJoined) {
			Handle := {}
			Handle.terminate := TerminateFn
			KLPFWorker.jobs[JobKey] := Map(
				"generation", KLPFWorker.jobs.Count + 1,
				"stage", A_Temp . "\\missing-stage",
				"handle", Handle,
				"kind", InStr(JobKey, "range:") = 1 ? "range" : "prefetch",
				"on_terminal", 0)
		}
		AssertTrue(KLPF_CancelAll(),
			"shutdown must synchronously confirm every worker tree is gone")
		AssertEqual(KLPFWorker.jobs.Count, 0)

		Handle := {}
		Handle.terminate := _KLPFW_TerminateUnconfirmed
		KLPFWorker.jobs["apps"] := Map(
			"generation", 9, "stage", A_Temp . "\\missing-stage",
			"handle", Handle, "kind", "prefetch", "on_terminal", 0)
		AssertFalse(KLPF_CancelAll(),
			"an unconfirmed process-tree termination must fail closed")
	} finally {
		KLPFWorker.jobs := SavedJobs
	}

	Lifecycle := _DriverFuncBody("Ergopti_OnShutdown")
	CancelPos := InStr(Lifecycle, "KLPF_CancelAll()")
	TerminalPos := InStr(Lifecycle, "ShutdownTerminal := true")
	Assert(CancelPos > 0 && CancelPos < TerminalPos,
		"OnExit must join prefetch workers before terminal ownership transfer")
}
Test("keylogger prefetch: shutdown joins unique process owners (prefetch-shutdown-owner)",
	_KLPFW_ShutdownOwnsEveryProcessAndStage)

global _KLPFW_FakeTerminated := 0
global _KLPFW_FakeArgs := []

_KLPFW_FakeStart(*) {
	return true
}

_KLPFW_FakeTerminate(*) {
	global _KLPFW_FakeTerminated
	_KLPFW_FakeTerminated += 1
	return true
}

_KLPFW_FakeSpawn(executable, args, done) {
	global _KLPFW_FakeArgs
	_KLPFW_FakeArgs.Push(Map("executable", executable, "args", args, "done", done))
	handle := {}
	handle.start := _KLPFW_FakeStart
	handle.terminate := _KLPFW_FakeTerminate
	return handle
}

_KLPFW_GenerationFenceRunsWithoutProjection() {
	global _KLPFW_FakeTerminated, _KLPFW_FakeArgs
	old_jobs := KLPFWorker.jobs
	old_generation := KLPFWorker.generation
	old_spawn := KLPFWorker.spawn_fn
	_KLPFW_FakeTerminated := 0
	_KLPFW_FakeArgs := []
	KLPFWorker.jobs := Map()
	KLPFWorker.generation := 0
	KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
	try {
		started := A_TickCount
		Assert(KLPF_RequestBuild("typing", A_Temp . "\\metrics", "live"),
			"a projection request must publish an async worker job immediately")
		first_generation := KLPFWorker.jobs["typing"]["generation"]
		Assert(KLPF_RequestBuild("typing", A_Temp . "\\metrics", "live"),
			"a newer projection request must replace the prior worker job")
		Assert((A_TickCount - started) < 100,
			"requesting a projection must only spawn work; it must not execute SQLite/JSON on the caller thread")
		Assert(_KLPFW_FakeTerminated = 1,
			"a newer request must terminate the prior worker process tree")
		Assert(KLPFWorker.jobs["typing"]["generation"] > first_generation,
			"a replacement worker must receive a strictly newer generation")
		KLPF_OnWorkerDone("typing", first_generation, 0, "", "")
		Assert(KLPFWorker.jobs["typing"]["generation"] > first_generation,
			"a late completion must not remove or mutate the newer live job")
	} finally {
		KLPF_CancelBuild("typing")
		KLPFWorker.jobs := old_jobs
		KLPFWorker.generation := old_generation
		KLPFWorker.spawn_fn := old_spawn
	}
}

Test("keylogger: stale prefetch-worker completion cannot evict a newer job",
	_KLPFW_GenerationFenceRunsWithoutProjection)

global _KLPFW_Terminals := []
global _KLPFW_FirstPaintTimers := []
global _KLPFW_FullBuildTimers := []
global _KLPFW_IngestDrainTimers := []
global _KLPFW_FirstPaintPushes := 0
global _KLPFW_FirstPaintPushResult := false
global _KLPFW_PublishCount := 0
global _KLPFW_PublishSawOwner := true

_KLPFW_RecordTerminal(status, stage := "") {
	global _KLPFW_Terminals
	_KLPFW_Terminals.Push(Map("status", status, "stage", stage))
}

_KLPFW_TestJobKey(args) {
	mode_index := A_IsCompiled ? 5 : 6
	which_index := A_IsCompiled ? 3 : 4
	return (args[mode_index] = "range") ? "range:" . args[which_index] : args[which_index]
}

_KLPFW_SyncDoneStart(done, job_key, *) {
	if !KLPFWorker.jobs.Has(job_key)
		return false
	stage := KLPFWorker.jobs[job_key]["stage"]
	try FileDelete(stage)
	FileAppend("{}", stage, "UTF-8")
	done.Call(0, "", "")
	; Deliberately false: the already-delivered terminal owns the result, so the
	; caller must inspect the registry before interpreting this stale return.
	return false
}

_KLPFW_SyncDoneSpawn(executable, args, done) {
	handle := {}
	handle.start := _KLPFW_SyncDoneStart.Bind(done, _KLPFW_TestJobKey(args))
	handle.terminate := _KLPFW_FakeTerminate
	return handle
}

_KLPFW_DoneOnTerminate(done, *) {
	done.Call(1, "", "terminated synchronously")
	return true
}

_KLPFW_DoneOnTerminateSpawn(executable, args, done) {
	handle := {}
	handle.start := _KLPFW_FakeStart
	handle.terminate := _KLPFW_DoneOnTerminate.Bind(done)
	return handle
}

_KLPFW_FalseStart(*) {
	return false
}

_KLPFW_FalseStartSpawn(executable, args, done) {
	handle := {}
	handle.start := _KLPFW_FalseStart
	handle.terminate := _KLPFW_FakeTerminate
	return handle
}

_KLPFW_ThrowStart(*) {
	throw Error("synthetic start failure")
}

_KLPFW_ThrowStartSpawn(executable, args, done) {
	handle := {}
	handle.start := _KLPFW_ThrowStart
	handle.terminate := _KLPFW_FakeTerminate
	return handle
}

_KLPFW_PublishOk(stage, destination) {
	try FileDelete(stage)
	return true
}

_KLPFW_PublishFailed(*) {
	return false
}

_KLPFW_Query() {
	return Map("start_date", "2026-08-01", "end_date", "2026-08-08", "apps", ["editor.exe"])
}

_KLPFW_SynchronousStartTerminalOwnsBothJobKinds() {
	global _KLPFW_Terminals
	old_jobs := KLPFWorker.jobs
	old_generation := KLPFWorker.generation
	old_spawn := KLPFWorker.spawn_fn
	old_publish := KLPFWorker.publish_fn
	KLPFWorker.jobs := Map()
	KLPFWorker.generation := 0
	KLPFWorker.spawn_fn := _KLPFW_SyncDoneSpawn
	KLPFWorker.publish_fn := _KLPFW_PublishOk
	_KLPFW_Terminals := []
	try {
		Assert(KLPF_RequestBuild("apps", A_Temp . "\\metrics", "full", 17, _KLPFW_RecordTerminal),
			"a synchronous successful full-prefetch completion must own the terminal even when start() later returns false")
		Assert(_KLPFW_Terminals.Length = 1 && _KLPFW_Terminals[1]["status"] = "ok",
			"full-prefetch synchronous completion must emit exactly one ok terminal")
		Assert(_KLPFW_Terminals[1]["stage"] = "" && !KLPFWorker.jobs.Has("apps"),
			"published prefetch terminal must not expose a private stage or leave a live job")

		_KLPFW_Terminals := []
		Assert(KLPF_RequestRange("typing", A_Temp . "\\metrics", _KLPFW_Query(), 18, _KLPFW_RecordTerminal),
			"a synchronous successful range completion must own the terminal even when start() later returns false")
		Assert(_KLPFW_Terminals.Length = 1 && _KLPFW_Terminals[1]["status"] = "ok",
			"range synchronous completion must emit exactly one ok terminal")
		stage := _KLPFW_Terminals[1]["stage"]
		Assert(stage != "" && FileExist(stage) && !KLPFWorker.jobs.Has("range:typing"),
			"range success must hand the private stage to its one terminal consumer")
		try FileDelete(stage)
	} finally {
		KLPF_CancelBuild("apps")
		KLPF_CancelBuild("range:typing")
		KLPFWorker.jobs := old_jobs
		KLPFWorker.generation := old_generation
		KLPFWorker.spawn_fn := old_spawn
		KLPFWorker.publish_fn := old_publish
	}
}

Test("keylogger: synchronous start completion wins exactly once for range and full-prefetch jobs",
	_KLPFW_SynchronousStartTerminalOwnsBothJobKinds)

_KLPFW_CancelClaimsBeforeSynchronousTerminateCallback() {
	global _KLPFW_Terminals
	old_jobs := KLPFWorker.jobs
	old_generation := KLPFWorker.generation
	old_spawn := KLPFWorker.spawn_fn
	KLPFWorker.jobs := Map()
	KLPFWorker.generation := 0
	KLPFWorker.spawn_fn := _KLPFW_DoneOnTerminateSpawn
	_KLPFW_Terminals := []
	try {
		Assert(KLPF_RequestBuild("apps", A_Temp . "\\metrics", "full", 21, _KLPFW_RecordTerminal),
			"full-prefetch cancel test must arm a live worker")
		KLPF_CancelBuild("apps")
		Assert(_KLPFW_Terminals.Length = 1 && _KLPFW_Terminals[1]["status"] = "canceled",
			"full-prefetch cancel must win before terminate synchronously reports worker failure")
		KLPF_CancelBuild("apps")
		Assert(_KLPFW_Terminals.Length = 1,
			"duplicate full-prefetch cancel/done callbacks must not emit a second terminal")

		Assert(KLPF_RequestRange("typing", A_Temp . "\\metrics", _KLPFW_Query(), 22, _KLPFW_RecordTerminal),
			"range cancel test must arm a live worker")
		KLPF_CancelBuild("range:typing")
		Assert(_KLPFW_Terminals.Length = 2 && _KLPFW_Terminals[2]["status"] = "canceled",
			"range cancel must win before terminate synchronously reports worker failure")
		KLPF_CancelBuild("range:typing")
		Assert(_KLPFW_Terminals.Length = 2,
			"duplicate range cancel/done callbacks must not emit a second terminal")
	} finally {
		KLPF_CancelBuild("apps")
		KLPF_CancelBuild("range:typing")
		KLPFWorker.jobs := old_jobs
		KLPFWorker.generation := old_generation
		KLPFWorker.spawn_fn := old_spawn
	}
}

Test("keylogger: cancel owns the typed terminal before a synchronous terminate callback",
	_KLPFW_CancelClaimsBeforeSynchronousTerminateCallback)

_KLPFW_StartAndPublishFailuresAreTerminal() {
	global _KLPFW_Terminals, _KLPFW_FakeArgs
	old_jobs := KLPFWorker.jobs
	old_generation := KLPFWorker.generation
	old_spawn := KLPFWorker.spawn_fn
	old_publish := KLPFWorker.publish_fn
	KLPFWorker.jobs := Map()
	KLPFWorker.generation := 0
	_KLPFW_Terminals := []
	try {
		KLPFWorker.spawn_fn := _KLPFW_FalseStartSpawn
		Assert(!KLPF_RequestBuild("apps", A_Temp . "\\metrics", "full", 31, _KLPFW_RecordTerminal),
			"a false full-prefetch start must reject the request")
		Assert(_KLPFW_Terminals.Length = 1 && _KLPFW_Terminals[1]["status"] = "failed"
				&& !KLPFWorker.jobs.Has("apps"),
			"a false full-prefetch start must emit one failed terminal and retire ownership")
		Assert(!KLPF_RequestRange("typing", A_Temp . "\\metrics", _KLPFW_Query(), 32, _KLPFW_RecordTerminal),
			"a false range start must reject the request")
		Assert(_KLPFW_Terminals.Length = 2 && _KLPFW_Terminals[2]["status"] = "failed"
				&& !KLPFWorker.jobs.Has("range:typing"),
			"a false range start must emit one failed terminal and retire ownership")

		_KLPFW_Terminals := []
		KLPFWorker.spawn_fn := _KLPFW_ThrowStartSpawn
		Assert(!KLPF_RequestBuild("apps", A_Temp . "\\metrics", "full", 34, _KLPFW_RecordTerminal)
				&& !KLPF_RequestRange("typing", A_Temp . "\\metrics", _KLPFW_Query(), 35, _KLPFW_RecordTerminal),
			"a throwing start must reject both projection kinds without escaping the callback boundary")
		Assert(_KLPFW_Terminals.Length = 2
				&& _KLPFW_Terminals[1]["status"] = "failed"
				&& _KLPFW_Terminals[2]["status"] = "failed",
			"throwing starts must emit one failed terminal for each job kind")

		_KLPFW_Terminals := []
		_KLPFW_FakeArgs := []
		KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
		KLPFWorker.publish_fn := _KLPFW_PublishFailed
		Assert(KLPF_RequestRange("typing", A_Temp . "\\metrics", _KLPFW_Query(), 36, _KLPFW_RecordTerminal),
			"nonzero-exit test must arm a range worker")
		_KLPFW_FakeArgs[1]["done"].Call(7, "", "worker failed")
		Assert(KLPF_RequestRange("typing", A_Temp . "\\metrics", _KLPFW_Query(), 37, _KLPFW_RecordTerminal),
			"missing-stage test must arm a replacement range worker")
		_KLPFW_FakeArgs[2]["done"].Call(0, "", "")
		Assert(KLPF_RequestBuild("apps", A_Temp . "\\metrics", "full", 33, _KLPFW_RecordTerminal),
			"publish-failure test must arm a full-prefetch worker")
		stage := KLPFWorker.jobs["apps"]["stage"]
		FileAppend("{}", stage, "UTF-8")
		_KLPFW_FakeArgs[3]["done"].Call(0, "", "")
		Assert(_KLPFW_Terminals.Length = 3
				&& _KLPFW_Terminals[1]["status"] = "failed"
				&& _KLPFW_Terminals[2]["status"] = "failed"
				&& _KLPFW_Terminals[3]["status"] = "failed",
			"nonzero exit, missing stage, and atomic publish failure must each emit a failed terminal")
		Assert(_KLPFW_Terminals.Length = 3 && _KLPFW_Terminals[3]["status"] = "failed",
			"atomic prefetch publish failure must be a failed terminal, not a success-only silent return")
		Assert(!KLPFWorker.jobs.Has("apps") && !FileExist(stage),
			"publish failure must retire the job and remove its private stage")
	} finally {
		KLPF_CancelBuild("apps")
		KLPF_CancelBuild("range:typing")
		KLPFWorker.jobs := old_jobs
		KLPFWorker.generation := old_generation
		KLPFWorker.spawn_fn := old_spawn
		KLPFWorker.publish_fn := old_publish
	}
}

Test("keylogger: false/throwing start, worker, and publish failures reach typed terminals",
	_KLPFW_StartAndPublishFailuresAreTerminal)

_KLPFW_FirstPaintPush(which) {
	global _KLPFW_FirstPaintPushes, _KLPFW_FirstPaintPushResult
	_KLPFW_FirstPaintPushes += 1
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
	KLWV.windows := Map("typing", Map("epoch", 41))
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

		KLWV.windows["typing"] := Map("epoch", 41)
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

Test("keylogger WebView: first-paint terminal failures retry finitely and cannot cross epochs",
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
	KLWV.windows := Map("typing", Map("epoch", 51, "first_paint_done", true))
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
		Assert(KLWV_DelayedFullBuild("typing", 51, 0),
			"the nonzero-exit historical worker must start asynchronously")
		generation := KLPFWorker.jobs["typing"]["generation"]
		KLPF_OnWorkerDone("typing", generation, 1, "", "synthetic failure")
		Assert(_KLPFW_FullBuildTimers.Length = 1 && !KLPFWorker.jobs.Has("typing"),
			"a nonzero worker exit must arm recovery and retire the failed full job")

		_KLPFW_FullBuildTimers := []
		KLPFWorker.publish_fn := _KLPFW_PublishFailed
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
		mode_index := A_IsCompiled ? 5 : 6
		Assert(_KLPFW_FakeArgs[1]["args"][mode_index] = "full",
			"the ingest fallback must force full mode instead of publishing live-only data")
		fallback_generation := KLPFWorker.jobs["typing"]["generation"]
		KLWV_NotifyIngest("live")
		Assert(KLPFWorker.jobs["typing"]["generation"] = fallback_generation
				&& _KLPFW_FakeArgs.Length = 1 && _KLPFW_FakeTerminated = 0,
			"a newer live tick must not cancel or replace a full fallback still running")

		stage := KLPFWorker.jobs["typing"]["stage"]
		try FileDelete(stage)
		FileAppend("{}", stage, "UTF-8")
		KLPF_OnWorkerDone("typing", fallback_generation, 0, "", "")
		Assert(KLWV.windows["typing"]["full_build_done"]
				&& _KLPFW_FirstPaintPushes = 1 && !KLPFWorker.jobs.Has("typing")
				&& _KLPFW_IngestDrainTimers.Length = 1,
			"the first successful full terminal must close historical recovery and defer one dirty live successor")
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

Test("keylogger WebView: full historical build retries every terminal failure and falls back through ingest",
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
		mode_index := A_IsCompiled ? 5 : 6
		Assert(_KLPFW_FakeArgs.Length = 1 && _KLPFW_FakeTerminated = 0
				&& KLPFWorker.jobs.Has("typing"),
			"five-second live ingest must never cancel or replace the in-flight full seed")
		full_generation := KLPFWorker.jobs["typing"]["generation"]
		Assert(_KLPFW_FakeArgs[1]["args"][mode_index] = "full"
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
				&& _KLPFW_FakeArgs[2]["args"][mode_index] = "live"
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
				&& !KLPFWorker.jobs.Has("typing") && _KLPFW_PublishCount = 2,
			"a dirty live owner must terminally publish once and schedule one successor")
		_KLPFW_IngestDrainTimers[2]["callback"].Call()
		newest_generation := KLPFWorker.jobs["typing"]["generation"]
		Assert(_KLPFW_FakeArgs.Length = 3 && newest_generation > live_generation,
			"three intervening live ticks must create exactly one newer generation")

		; A duplicate completion from the long-finished seed is stale against the
		; current live owner and may neither publish nor evict it.
		_KLPFW_FakeArgs[1]["done"].Call(0, "", "")
		Assert(_KLPFW_PublishCount = 2
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

Test("keylogger prefetch: live ingest coalesces behind full seed and publishes only the current generation",
	_KLPFW_LiveIngestCoalescesBehindFullSeed)
