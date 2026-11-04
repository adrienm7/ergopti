; tests/unit/modules/keystats/metrics/test_metrics_warm_terminal_claim_reentry.ahk
; AFTER-only controlled terminal timing: delegate the genuine admitted callback,
; then certify a committed signal while its real claimed reservation remains.
; No SQL producer, native worker, COM or elapsed timer delivery is asserted.
#Requires AutoHotkey v2.0

_MWTCR_ObserveTerminal(World, Original, Status, Stage) {
	if !World.ObserverArmed
		return Original.Call(Status, Stage)
	try {
		World.ObserverCalls += 1
		AssertEqual(1, World.ObserverCalls, "the original admitted terminal must be delegated exactly once")
		AssertEqual("failed", Status, "the real Done must produce failure, never a synthetic cancellation")
		AssertEqual("", Stage)
		AssertTrue(KLPFWorker.jobs[World.Which] == World.ClaimedJob)
		AssertTrue(World.ClaimedJob["terminal_claimed"], "CompleteJob must still own its genuine retiring reservation")
		AssertEqual(World.Owner["generation"], World.ClaimedJob["generation"])
		Result := Original.Call(Status, Stage)
		AssertFalse(Result, "the unchanged original terminal legitimately exhausts revision zero")
		AssertEqual(0, World.Entry.Get("ingest_revision", 0))
		AssertTrue(World.Entry["full_build_retry_exhausted"])
		AssertEqual(0, World.Entry["full_build_retry_revision"])
		AssertFalse(World.Entry.Has("full_build_retry_owner"))
		AssertFalse(World.Entry.Has("pending_full_build_retry"))
		AssertFalse(World.Entry["first_paint_done"])
		AssertEqual(3, World.Timers.Length, "the old exhausted revision has no additional retry")

		; This models the actual busy committed-signal edge, not a SQL append.
		KLWV_RecordCommittedIngest()
		AssertEqual(1, World.Entry["ingest_revision"])
		AssertEqual("live", World.Entry["pending_ingest_mode"])
		Next := World.Entry.Get("full_build_retry_owner", 0)
		AssertTrue(Next is Map, "fresh committed work must survive the claimed but not retired job")
		World.FreshOwner := Next
		AssertEqual(1, Next["revision"])
		AssertEqual(0, Next["attempt"])
		AssertEqual(World.NextRoot, Next["warm_store"])
		AssertEqual(0, World.Entry["full_build_requested_revision"], "new debt must not relabel the old admitted request")
		AssertFalse(World.Entry.Get("full_build_retry_exhausted", false))
		AssertEqual(4, World.Timers.Length)
		AssertTrue(World.Timers[4].Call(), "the canonical early callback must retain and rearm its debt")
		AssertTrue(KLPFWorker.jobs[World.Which] == World.ClaimedJob,
			"the early callback must not replace the still-retiring reservation")
		AssertTrue(World.ClaimedJob["terminal_claimed"])
		AssertTrue(World.Entry["full_build_retry_owner"] == Next,
			"same destination and epoch must not turn a retiring generation into a takeover")
		AssertEqual(1, Next["revision"])
		AssertEqual(0, Next["attempt"], "waiting for actual registry retirement consumes no failure budget")
		AssertEqual(0, Next.Get("generation", 0), "the new debt must not adopt the old generation")
		AssertEqual(0, World.Entry["full_build_requested_revision"])
		AssertEqual(5, World.Timers.Length, "the early callback leaves exactly one deferred retry")
		AssertEqual(4, World.Handles.Length)
		AssertEqual(0, World.Handles[4].Terminations)
		AssertFalse(FSStrictExists(World.Paths[2]))
		AssertEqual(0, World.View.Messages.Length)
		World.EarlyDone := true
		return Result
	} catch Any as Failure {
		; InvokeTerminal intentionally contains errors. Preserve the exact cause
		; so the outer case rethrows it once CompleteJob has retired its slot.
		World.ObserverFailed := true
		World.ObserverError := Failure
		return false
	}
}

_MWTCR_Exercise(World) {
	_MWTB_AdmitLastAttempt(World)
	World.ClaimedJob := KLPFWorker.jobs[World.Which]
	Original := World.ClaimedJob["on_terminal"]
	AssertTrue(HasMethod(Original, "Call"))
	AssertEqual(World.Owner["generation"], World.ClaimedJob["generation"])
	AssertFalse(World.ClaimedJob.Get("terminal_claimed", false))
	; Install only AFTER Resume adopted the genuine callback's generation.
	; Before that point replacement would deliberately fail its identity fence.
	World.Observer := _MWTCR_ObserveTerminal.Bind(World, Original)
	World.ClaimedJob["on_terminal"] := World.Observer
	World.ObserverArmed := true
	OldHandle := World.Handles[4]
	AssertFalse(FSStrictExists(OldHandle.Stage))
	OldHandle.Done.Call(1, "", "controlled detached projection failure")
	if World.ObserverFailed
		throw World.ObserverError
	AssertEqual(1, World.ObserverCalls)
	AssertTrue(World.EarlyDone)
	AssertEqual(0, KLPFWorker.jobs.Count, "the genuine old completion must actually retire its reservation")
	AssertTrue(World.Entry["full_build_retry_owner"] == World.FreshOwner)
	AssertEqual(5, World.Timers.Length)
	AssertTrue(World.Timers[5].Call(), "the rearmed callback must now admit the new revision")
	AssertEqual(5, World.Handles.Length)
	AssertEqual(World.NextRoot, World.Handles[5].Root)
	AssertEqual("full", World.Handles[5].Mode)
	AssertEqual(1, World.Handles[5].Starts)
	AssertEqual(1, World.Entry["full_build_requested_revision"])
	_MWR_Complete(World.Handles[5], "B")
	_MWTB_FinishCommitted(World, 5)
	; A late real Done and a previously delivered retry cannot create more work.
	OldHandle.Done.Call(1, "", "late detached completion")
	World.Timers[4].Call()
	AssertEqual(1, World.ObserverCalls)
	AssertEqual(6, World.Handles.Length)
	AssertEqual(5, World.Timers.Length)
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertEqual(2, World.View.Messages.Length)
}

_MWTCR_Case() {
	global _SharedDir, KLPF_LAST_JSON, _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	static Serial := 0
	PreviousCritical := Critical("On")
	try {
		SavedLogger := _TLOG_CaptureLoggerState(), Extra := Map()
		for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
			"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
			Extra[Name] := %Name%
		Saved := {Windows: KLWV.windows, Jobs: KLPFWorker.jobs, Generation: KLPFWorker.generation,
			Spawn: KLPFWorker.spawn_fn, Publish: KLPFWorker.publish_fn, WarmDir: KLWV.warm_metrics_dir,
			WarmTimer: KLWV.warm_timer, WarmFn: KLWV.warm_timer_fn, First: KLWV.first_paint_timer_fn,
			Full: KLWV.full_build_timer_fn, Push: KLWV.first_paint_push_fn, MetricsDir: KLWV.metrics_dir,
			IngestFn: KLWV.ingest_drain_timer_fn,
			HadJson: IsSet(KLPF_LAST_JSON), HadShared: IsSet(_SharedDir), Suspended: A_IsSuspended}
		Saved.Json := Saved.HadJson ? KLPF_LAST_JSON : 0
		Saved.Shared := Saved.HadShared ? _SharedDir : 0
		Root := A_Temp . "\ergopti_warm_claim_" . A_ScriptHwnd . "_" . ++Serial
		World := {Mode: "terminal-claim-reentry", Which: "apps", OldRoot: Root . "\old",
			NextRoot: Root . "\next", Handles: [], Timers: [], Inline: false, EarlyRan: false,
			Failure: 0, Job: 0, ObserverArmed: false, ObserverCalls: 0, ObserverFailed: false,
			ObserverError: 0, ClaimedJob: 0, Observer: 0, FreshOwner: 0, EarlyDone: false, IngestTimers: [], View: _MWR_View(), ScriptPending: false, Epoch: -(0x72000000 + Serial)}
		World.Entry := Map("epoch", World.Epoch, "webview", World.View, "metrics_dir", World.NextRoot,
			"first_paint_done", false, "full_build_done", false)
		World.Paths := [KLPF_PrefetchPath(World.Which, World.OldRoot), KLPF_PrefetchPath(World.Which, World.NextRoot)]
		Owned := false, Installed := false, SidecarsReady := false, Primary := 0, CleanupError := 0
		try {
			AssertFalse(A_IsSuspended)
			; A failed drain must not leave a callback that can match an incumbent
			; or a later production epoch. Production epochs increase from zero.
			for SavedWhich, SavedEntry in Saved.Windows
				if SavedEntry is Map
					AssertTrue(SavedEntry.Get("epoch", 0) != World.Epoch)
			AssertFalse(KLPF_ReloadKeepsWorkersOut())
			_KLRDC_EnsureSharedDir()
			FSCreateDirectoryExclusiveStrict(Root), Owned := true
			FSCreateDirectoryExclusiveStrict(World.OldRoot), FSCreateDirectoryExclusiveStrict(World.NextRoot)
			for Path in World.Paths
				AssertFalse(FSStrictExists(Path), "never adopt another owner's hashed sidecar")
			SidecarsReady := true
			_ResetLogger()
			LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
			_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
			KLWV.windows := Map(), KLPFWorker.jobs := Map(), KLPF_LAST_JSON := Map(), Installed := true
			KLPFWorker.spawn_fn := _MWI_Spawn.Bind(World), KLPFWorker.publish_fn := 0
			KLWV.warm_metrics_dir := World.OldRoot, KLWV.warm_timer := 0
			KLWV.warm_timer_fn := _MWR_Timer.Bind(World)
			KLWV.full_build_timer_fn := _MWR_Timer.Bind(World)
			KLWV.first_paint_timer_fn := (*) => true
			KLWV.first_paint_push_fn := 0
			KLWV.metrics_dir := World.NextRoot, KLWV.ingest_drain_timer_fn := _MWI_IngestTimer.Bind(World)
			_MWTCR_Exercise(World)
		} catch as Failure {
			Primary := Failure
		} finally {
			; Teardown may deliver a real cancellation. Only delegate then; never
			; inject another committed notification from this fixture observer.
			World.ObserverArmed := false
			try {
				if Installed {
					try _MWR_DrainScript(World)
					catch as Failure {
						CleanupError := Failure
					}
					KLWV.windows := Map()
					AssertTrue(KLPF_CancelAll())
				}
				if SidecarsReady
					for Path in World.Paths
						if FSStrictExists(Path)
							AssertTrue(FSDelete(Path))
			} catch as Failure {
				if !IsObject(CleanupError)
					CleanupError := Failure
			} finally {
				Suspend(Saved.Suspended)
				KLWV.windows := Saved.Windows, KLPFWorker.jobs := Saved.Jobs, KLPFWorker.generation := Saved.Generation
				KLPFWorker.spawn_fn := Saved.Spawn, KLPFWorker.publish_fn := Saved.Publish
				KLWV.warm_metrics_dir := Saved.WarmDir, KLWV.warm_timer := Saved.WarmTimer
				KLWV.warm_timer_fn := Saved.WarmFn, KLWV.first_paint_timer_fn := Saved.First
				KLWV.full_build_timer_fn := Saved.Full, KLWV.first_paint_push_fn := Saved.Push
				KLWV.metrics_dir := Saved.MetricsDir, KLWV.ingest_drain_timer_fn := Saved.IngestFn
				KLPF_LAST_JSON := Saved.HadJson ? Saved.Json : unset
				_SharedDir := Saved.HadShared ? Saved.Shared : unset
				_TLOG_RestoreLoggerState(SavedLogger)
				for Name, Value in Extra
					%Name% := Value
				for Handle in World.Handles
					Handle.start := 0, Handle.terminate := 0, Handle.Done := 0
				if World.ClaimedJob is Map
					World.ClaimedJob["on_terminal"] := 0
				World.Observer := 0, World.ClaimedJob := 0, World.FreshOwner := 0
				World.Timers := [], World.IngestTimers := [], World.Entry.Clear()
			}
			if Owned {
				try DirDelete(Root, true)
				catch as Failure {
					if !IsObject(CleanupError)
						CleanupError := Failure
				}
			}
		}
		if IsObject(Primary)
			throw Primary
		if IsObject(CleanupError)
			throw CleanupError
	} finally Critical(PreviousCritical)
}


Test("Metrics warm terminal claim: early retry retains fresh debt until actual retirement (metrics-warm-terminal-claim-reentry)",
	_MWTCR_Case)
