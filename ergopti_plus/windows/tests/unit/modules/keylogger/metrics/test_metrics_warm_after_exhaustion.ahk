; tests/unit/modules/keylogger/metrics/test_metrics_warm_after_exhaustion.ahk
; TEST-only: public NotifyIngest models a successful durable commit AFTER warm
; retries legitimately exhausted. No SQL producer/projection executes here.
; Process/COM/timer boundaries are passive; scheduler/FS/read/push/paint are real.
#Requires AutoHotkey v2.0

_MWTE_Spawn(World, Exe, Args, Done) {
	Flag := 0
	for Index, Arg in Args
		if Arg == "--keylogger-prefetch-worker"
			Flag := Index
	AssertTrue(Flag > 0)
	if Args[Flag + 1] == World.Which
		return _MWI_Spawn(World, Exe, Args, Done)
	AssertEqual("typing", Args[Flag + 1])
	AssertEqual(World.NextRoot, Args[Flag + 2])
	AssertEqual("full", Args[Flag + 3])
	AssertTrue(KLPFWorker.jobs.Has("typing"))
	Handle := {Starts: 0, Terminations: 0, Root: Args[Flag + 2], Stage: Args[Flag + 4], Done: Done}
	Handle.start := _MWA_Start.Bind(Handle)
	Handle.terminate := _MWA_Terminate.Bind(Handle)
	World.OtherHandles.Push(Handle)
	return Handle
}

_MWTE_DeliverDeferredPaths(World) {
	Before := World.Timers.Length
	; This is the other real post-commit endpoint called by KL_IngestOnce.
	AssertTrue(KLWV_WarmOnIngestCommitted())
	AssertEqual(Before + 1, World.Timers.Length)
	WarmIndex := Before + 1
	AssertTrue(World.Timers[WarmIndex].Call())
	AssertEqual(1, World.OtherHandles.Length)
	AssertEqual(1, World.OtherHandles[1].Starts)
	AssertTrue(KLPFWorker.jobs.Has("typing"))
	_MWR_Complete(World.OtherHandles[1], "idle-typing")
	AssertFalse(KLPFWorker.jobs.Has("typing"))
	AssertTrue(FSStrictExists(World.Paths[3]))
	AssertEqual(Before + 2, World.Timers.Length, "the real typing terminal must chain the next dashboard")
	ChainIndex := Before + 2
	AssertFalse(World.Timers[ChainIndex].Call(), "idle warm must leave the existing Apps window to its owner")
	AssertEqual(1, World.OtherHandles.Length)
	; Deliver the real metrics resume/drain callbacks while the private current
	; window is still installed, before concluding that fresh recovery is lost.
	KLWV_OnSuspendResume()
	AssertEqual(1, World.IngestTimers.Length)
	AssertFalse(World.IngestTimers[1].Call(), "ordinary ingest still cannot establish a cold first paint")
	World.IngestTimers := []
	return Map(1, true, 2, true, 3, true, WarmIndex, true, ChainIndex, true)
}

_MWTE_Exercise(World) {
	_MWTB_AdmitLastAttempt(World)
	_MWTB_Fail(World)
	; All three captured retry callbacks were already delivered by the genuine
	; admission sequence. Exhaustion must have armed no additional callback.
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertFalse(World.Entry.Has("full_build_retry_owner"))
	AssertFalse(World.Entry.Has("pending_full_build_retry"))
	AssertEqual(3, World.Timers.Length)
	AssertEqual(0, World.IngestTimers.Length)
	AssertEqual(0, World.Entry.Get("ingest_revision", 0))
	AssertTrue(World.Entry["full_build_retry_exhausted"])
	AssertEqual(0, World.Entry["full_build_retry_revision"])
	AssertFalse(World.Entry["first_paint_done"])
	AssertFalse(World.Entry["full_build_done"])
	AssertFalse(FSStrictExists(World.Paths[2]))
	AssertEqual(0, World.View.Messages.Length)
	_TestPrint("# metrics-warm-after-exhaustion before_commit_revision=0 debt=0 jobs=0 cold=1 delivered_retry_callbacks=3")
	_MWI_Notify(World)
	AssertEqual(1, World.Entry["ingest_revision"])
	AssertEqual("live", World.Entry["pending_ingest_mode"])
	Delivered := _MWTE_DeliverDeferredPaths(World)
	Next := World.Entry.Get("full_build_retry_owner", 0)
	_TestPrint("# metrics-warm-after-exhaustion after_commit_revision=" . World.Entry["ingest_revision"]
		. " debt=" . IsObject(Next) . " exhausted=" . World.Entry.Get("full_build_retry_exhausted", false)
		. " spawns=" . World.Handles.Length . " retry_arms=" . World.Timers.Length)
	AssertTrue(Next is Map, "a fresh committed revision must recreate recovery after cold-window exhaustion")
	AssertEqual(1, Next["revision"])
	AssertEqual(0, Next["attempt"], "the prior revision's exhaustion cannot spend the new input's budget")
	AssertEqual(1, World.Entry["full_build_retry_revision"])
	AssertFalse(World.Entry.Get("full_build_retry_exhausted", false))
	if World.Handles.Length == 4 {
		Pending := []
		for Index, Callback in World.Timers
			if !Delivered.Has(Index)
				Pending.Push(Callback)
		AssertEqual(1, Pending.Length, "exactly one fresh Apps retry must remain after the old deferred paths settled")
		Pending[1].Call()
	}
	AssertEqual(5, World.Handles.Length)
	AssertEqual(World.NextRoot, World.Handles[5].Root)
	AssertEqual("full", World.Handles[5].Mode)
	AssertEqual(1, World.Handles[5].Starts)
	AssertEqual(1, World.Entry["full_build_requested_revision"])
	_MWR_Complete(World.Handles[5], "B")
	_MWTB_FinishCommitted(World, 5)
}

_MWTE_Case() {
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
		Root := A_Temp . "\ergopti_warm_exhausted_" . A_ScriptHwnd . "_" . ++Serial
		World := {Mode: "fresh-commit-after-exhaustion", Which: "apps", OldRoot: Root . "\old",
			NextRoot: Root . "\next", Handles: [], Timers: [], Inline: false, EarlyRan: false,
			Failure: 0, Job: 0, OtherHandles: [], IngestTimers: [], View: _MWR_View(), ScriptPending: false, Epoch: -(0x71000000 + Serial)}
		World.Entry := Map("epoch", World.Epoch, "webview", World.View, "metrics_dir", World.NextRoot,
			"first_paint_done", false, "full_build_done", false)
		World.Paths := [KLPF_PrefetchPath(World.Which, World.OldRoot), KLPF_PrefetchPath(World.Which, World.NextRoot),
			KLPF_PrefetchPath("typing", World.NextRoot)]
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
			KLPFWorker.spawn_fn := _MWTE_Spawn.Bind(World), KLPFWorker.publish_fn := 0
			KLWV.warm_metrics_dir := World.OldRoot, KLWV.warm_timer := 0
			KLWV.warm_timer_fn := _MWR_Timer.Bind(World)
			KLWV.full_build_timer_fn := _MWR_Timer.Bind(World)
			KLWV.first_paint_timer_fn := (*) => true
			KLWV.first_paint_push_fn := 0
			KLWV.metrics_dir := World.NextRoot, KLWV.ingest_drain_timer_fn := _MWI_IngestTimer.Bind(World)
			_MWTE_Exercise(World)
		} catch as Failure {
			Primary := Failure
		} finally {
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
				for Handle in World.OtherHandles
					Handle.start := 0, Handle.terminate := 0, Handle.Done := 0
				World.Timers := [], World.IngestTimers := [], World.OtherHandles := [], World.Entry.Clear()
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

Test("Metrics warm terminal budget: fresh-commit-after-exhaustion (metrics-warm-terminal-budget)", _MWTE_Case)
