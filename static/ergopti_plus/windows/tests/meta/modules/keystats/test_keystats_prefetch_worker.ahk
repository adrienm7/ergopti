; tests/meta/modules/keystats/test_keystats_prefetch_worker.ahk

; ============================================================================== 
; MODULE: Keystats Prefetch Worker Regression Test
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
		"keystats prefetch worker lifecycle functions must exist")
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
	; A refused worker exits 2 in a detached process that owns no log file. Both
	; halves of its only diagnostic channel must stay wired: /ErrorStdOut so an
	; AutoHotkey load error is captured instead of raising an invisible modal
	; dialog, and the captured transcript in the parent's failure warning.
	Assert(InStr(Request, '"/ErrorStdOut"') > 0
			&& InStr(RangeRequest, '"/ErrorStdOut"') > 0,
		"both worker spawns must pass /ErrorStdOut so a load failure is captured, not shown in a dialog no one can see")
	Assert(InStr(Done, "KLPF_WorkerDiagnostic(stdout") > 0,
		"the projection failure warning must carry the worker's captured output; an exit code alone names a number and nothing else")
	; Which switches a host consumes differs between the .ahk and compiled entry
	; points, so the payload is addressed from the flag, never from A_Args[1].
	Assert(InStr(Worker, "KLPF_WorkerFlagIndex()") > 0
			&& InStr(Worker, "A_Args[flag + 1]") > 0
			&& InStr(Worker, "A_Args[1]") = 0
			&& InStr(Worker, "A_Args[2]") = 0,
		"KLPF_WorkerMain must read its payload relative to the worker flag: a fixed offset turns one extra host switch into a silent refusal")
	Assert(InStr(Worker, "KLPF_WorkerRefuse(") > 0
			&& InStr(Worker, "ExitApp(2)") = 0,
		"every argument-shape refusal must go through KLPF_WorkerRefuse so it explains itself before exiting 2")
	; The durable reader cache is only legitimate because this process owns its
	; projection alone and its image is reproducible from data.sql. The claim is
	; made here, once, and nothing else may make it: the resident driver's handle
	; carries live-walker deltas that no cold start could rebuild.
	Assert(InStr(Worker, "KLRCache.disposable := true") > 0,
		"KLPF_WorkerMain must declare that it owns a disposable projection, or the reader falls back to rebuilding the whole history on every dashboard open (klr-reader-durable-cache)")
	Assert(InStr(Worker, "KLR_BuildRangeSplitTodayJson(") > 0,
		"selected ranges must use the complete SQL JSON serializer inside the detached worker")
	Assert(InStr(Worker, "KLR_ReadRangeSplitToday(") == 0,
		"the worker must not rebuild every range cell as an AHK Map before encoding it again")

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

Test("keystats: prefetch projection is staged by a generation-fenced detached worker",
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
Test("keystats prefetch: shutdown joins unique process owners (prefetch-shutdown-owner)",
	_KLPFW_ShutdownOwnsEveryProcessAndStage)


_KLPFW_ReenterRange() {
	return KLPF_RequestRange("typing", A_Temp . "\metrics",
		_KLPFW_Query(), 902)
}

_KLPFW_ReenterFromDelete(*) {
	KLPFWorker.range_delete_fn := 0
	_KLPFW_ReenterRange()
	return true
}

_KLPFW_ReenterFromEncode(*) {
	KLPFWorker.range_encode_fn := 0
	_KLPFW_ReenterRange()
	return "[]"
}

_KLPFW_ReenterFromSpawn(*) {
	KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
	_KLPFW_ReenterRange()
	Handle := {}
	Handle.start := _KLPFW_FakeStart
	Handle.terminate := _KLPFW_FakeTerminate
	return Handle
}

_KLPFW_RangeReservationSurvivesEveryReentrantSeam() {
	SavedJobs := KLPFWorker.jobs
	SavedGeneration := KLPFWorker.generation
	SavedSpawn := KLPFWorker.spawn_fn
	SavedDelete := KLPFWorker.range_delete_fn
	SavedEncode := KLPFWorker.range_encode_fn
	try {
		for SeamName in ["delete", "encode", "spawn"] {
			KLPFWorker.jobs := Map()
			KLPFWorker.generation := 0
			KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
			KLPFWorker.range_delete_fn := 0
			KLPFWorker.range_encode_fn := 0
			switch SeamName {
			case "delete":
				KLPFWorker.range_delete_fn := _KLPFW_ReenterFromDelete
			case "encode":
				KLPFWorker.range_encode_fn := _KLPFW_ReenterFromEncode
			case "spawn":
				KLPFWorker.spawn_fn := _KLPFW_ReenterFromSpawn
			}
			AssertFalse(KLPF_RequestRange("typing", A_Temp . "\metrics",
				_KLPFW_Query(), 901),
				"the superseded outer " . SeamName . " request must stop")
			Assert(KLPFWorker.jobs.Has("range:typing")
				&& KLPFWorker.jobs["range:typing"]["generation"] = 2
				&& KLPFWorker.jobs["range:typing"]["epoch"] = 902,
				"the reentrant " . SeamName . " request must remain the sole owner")
			AssertTrue(KLPF_CancelBuild("range:typing"))
		}
	} finally {
		KLPFWorker.jobs := SavedJobs
		KLPFWorker.generation := SavedGeneration
		KLPFWorker.spawn_fn := SavedSpawn
		KLPFWorker.range_delete_fn := SavedDelete
		KLPFWorker.range_encode_fn := SavedEncode
	}
}
Test("keystats prefetch: range reserves before every reentrant effect (range-prefetch-reservation)",
	_KLPFW_RangeReservationSurvivesEveryReentrantSeam)


_KLPFW_BuildHandlePublicationIsAtomic() {
	Body := _DriverFuncBody("KLPF_RequestBuild")
	Assert(Body != "", "KLPF_RequestBuild must exist")
	CriticalPos := InStr(Body, 'Critical("On")')
	Assert(CriticalPos > 0,
		"build handle publication must enter a Critical ownership transaction")
	ValidationPos := InStr(Body, "KLPFWorker.jobs.Has(which)", true, CriticalPos)
	PublishPos := InStr(Body, 'job["handle"] := handle', true, ValidationPos)
	ReleasePos := InStr(Body, "Critical(PreviousCritical)", true, PublishPos)
	Assert(ValidationPos > CriticalPos
		&& PublishPos > ValidationPos && ReleasePos > PublishPos,
		"build reservation validation and handle publication must share one Critical transaction so cancellation cannot remove an owner between them")
}
Test("keystats prefetch: build handle publication is cancellation-atomic (AHK-058)",
	_KLPFW_BuildHandlePublicationIsAtomic)

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
		Assert(KLPF_RequestBuild("typing", A_Temp . "\metrics", "live"),
			"a projection request must publish an async worker job immediately")
		first_generation := KLPFWorker.jobs["typing"]["generation"]
		Assert(KLPF_RequestBuild("typing", A_Temp . "\metrics", "live"),
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

Test("keystats: stale prefetch-worker completion cannot evict a newer job",
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

; Address the payload the way KLPF_WorkerMain does — relative to the worker
; flag. Counting from the start of the vector instead re-encodes how many host
; switches the spawn happens to pass today, and silently mis-reads every job key
; the day one is added.
_KLPFW_TestFlagIndex(args) {
	for Index, Arg in args {
		if (Arg = "--keystats-prefetch-worker")
			return Index
	}
	Assert(false, "a spawned worker vector must carry --keystats-prefetch-worker")
	return 0
}

_KLPFW_TestJobKey(args) {
	flag_index := _KLPFW_TestFlagIndex(args)
	which := args[flag_index + 1]
	return (args[flag_index + 3] = "range") ? "range:" . which : which
}

_KLPFW_TestModeArg(args) {
	return args[_KLPFW_TestFlagIndex(args) + 3]
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
		Assert(KLPF_RequestBuild("apps", A_Temp . "\metrics", "full", 17, _KLPFW_RecordTerminal),
			"a synchronous successful full-prefetch completion must own the terminal even when start() later returns false")
		Assert(_KLPFW_Terminals.Length = 1 && _KLPFW_Terminals[1]["status"] = "ok",
			"full-prefetch synchronous completion must emit exactly one ok terminal")
		Assert(_KLPFW_Terminals[1]["stage"] = "" && !KLPFWorker.jobs.Has("apps"),
			"published prefetch terminal must not expose a private stage or leave a live job")

		_KLPFW_Terminals := []
		Assert(KLPF_RequestRange("typing", A_Temp . "\metrics", _KLPFW_Query(), 18, _KLPFW_RecordTerminal),
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

Test("keystats: synchronous start completion wins exactly once for range and full-prefetch jobs",
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
		Assert(KLPF_RequestBuild("apps", A_Temp . "\metrics", "full", 21, _KLPFW_RecordTerminal),
			"full-prefetch cancel test must arm a live worker")
		KLPF_CancelBuild("apps")
		Assert(_KLPFW_Terminals.Length = 1 && _KLPFW_Terminals[1]["status"] = "canceled",
			"full-prefetch cancel must win before terminate synchronously reports worker failure")
		KLPF_CancelBuild("apps")
		Assert(_KLPFW_Terminals.Length = 1,
			"duplicate full-prefetch cancel/done callbacks must not emit a second terminal")

		Assert(KLPF_RequestRange("typing", A_Temp . "\metrics", _KLPFW_Query(), 22, _KLPFW_RecordTerminal),
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

Test("keystats: cancel owns the typed terminal before a synchronous terminate callback",
	_KLPFW_CancelClaimsBeforeSynchronousTerminateCallback)

global _KLPFW_TerminalTerminateCalls := 0

_KLPFW_TerminalTerminateReportsJoined(*) {
	global _KLPFW_TerminalTerminateCalls
	_KLPFW_TerminalTerminateCalls += 1
	return true
}

_KLPFW_TerminalPublicationCannotAcknowledgeCancellation() {
	global _KLPFW_TerminalTerminateCalls
	SavedJobs := KLPFWorker.jobs
	_KLPFW_TerminalTerminateCalls := 0
	Handle := {}
	Handle.terminate := _KLPFW_TerminalTerminateReportsJoined
	Job := Map(
		"generation", 87,
		"stage", A_Temp . "\\missing-terminal-stage",
		"handle", Handle,
		"kind", "prefetch",
		"on_terminal", 0,
		"terminal_claimed", true)
	try {
		KLPFWorker.jobs := Map("apps", Job)
		AssertFalse(KLPF_CancelBuild("apps"),
			"cancellation must remain unconfirmed while the terminal callback still owns publication (AHK-088)")
		Assert(Job["cancel_requested"] && KLPFWorker.jobs.Has("apps")
				&& KLPFWorker.jobs["apps"] = Job,
			"the publishing owner must remain registered until its terminal stack retires it")
		AssertEqual(_KLPFW_TerminalTerminateCalls, 0,
			"worker-tree quiescence must not be confused with terminal-callback quiescence")
	} finally {
		KLPFWorker.jobs := SavedJobs
	}
}

Test("keystats prefetch: terminal publication remains live until callback retirement (AHK-088)",
	_KLPFW_TerminalPublicationCannotAcknowledgeCancellation)

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
		Assert(!KLPF_RequestBuild("apps", A_Temp . "\metrics", "full", 31, _KLPFW_RecordTerminal),
			"a false full-prefetch start must reject the request")
		Assert(_KLPFW_Terminals.Length = 1 && _KLPFW_Terminals[1]["status"] = "failed"
				&& !KLPFWorker.jobs.Has("apps"),
			"a false full-prefetch start must emit one failed terminal and retire ownership")
		Assert(!KLPF_RequestRange("typing", A_Temp . "\metrics", _KLPFW_Query(), 32, _KLPFW_RecordTerminal),
			"a false range start must reject the request")
		Assert(_KLPFW_Terminals.Length = 2 && _KLPFW_Terminals[2]["status"] = "failed"
				&& !KLPFWorker.jobs.Has("range:typing"),
			"a false range start must emit one failed terminal and retire ownership")

		_KLPFW_Terminals := []
		KLPFWorker.spawn_fn := _KLPFW_ThrowStartSpawn
		Assert(!KLPF_RequestBuild("apps", A_Temp . "\metrics", "full", 34, _KLPFW_RecordTerminal)
				&& !KLPF_RequestRange("typing", A_Temp . "\metrics", _KLPFW_Query(), 35, _KLPFW_RecordTerminal),
			"a throwing start must reject both projection kinds without escaping the callback boundary")
		Assert(_KLPFW_Terminals.Length = 2
				&& _KLPFW_Terminals[1]["status"] = "failed"
				&& _KLPFW_Terminals[2]["status"] = "failed",
			"throwing starts must emit one failed terminal for each job kind")

		_KLPFW_Terminals := []
		_KLPFW_FakeArgs := []
		KLPFWorker.spawn_fn := _KLPFW_FakeSpawn
		KLPFWorker.publish_fn := _KLPFW_PublishFailed
		Assert(KLPF_RequestRange("typing", A_Temp . "\metrics", _KLPFW_Query(), 36, _KLPFW_RecordTerminal),
			"nonzero-exit test must arm a range worker")
		_KLPFW_FakeArgs[1]["done"].Call(7, "", "worker failed")
		Assert(KLPF_RequestRange("typing", A_Temp . "\metrics", _KLPFW_Query(), 37, _KLPFW_RecordTerminal),
			"missing-stage test must arm a replacement range worker")
		_KLPFW_FakeArgs[2]["done"].Call(0, "", "")
		Assert(KLPF_RequestBuild("apps", A_Temp . "\metrics", "full", 33, _KLPFW_RecordTerminal),
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

Test("keystats: false/throwing start, worker, and publish failures reach typed terminals",
	_KLPFW_StartAndPublishFailuresAreTerminal)
