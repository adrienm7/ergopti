; tests/unit/modules/keystats/metrics/test_metrics_warm_terminal_budget.ahk
; TEST-only: a public committed notification models the durable append signal;
; no SQL producer is executed here. Genuine scheduler completions and filesystem
; publication remain real, with passive process, COM, and timer delivery ports.
#Requires AutoHotkey v2.0

_MWTB_Fail(World) {
	Handle := World.Handles[World.Handles.Length]
	AssertTrue(KLPFWorker.jobs.Has(World.Which))
	AssertEqual(Handle.Stage, KLPFWorker.jobs[World.Which]["stage"])
	AssertFalse(FSStrictExists(Handle.Stage))
	; This is the exact Done supplied by real RequestBuild: it enters
	; KLPF_OnWorkerDone with a failed exit, not a forged terminal status.
	Handle.Done.Call(1, "", "controlled detached projection failure")
	AssertEqual(0, KLPFWorker.jobs.Count)
}

_MWTB_AdmitLastAttempt(World) {
	AssertEqual(2, KLWV.FULL_BUILD_MAX_RETRIES, "the bounded replay covers both configured retry attempts")
	AssertTrue(KLWV_WarmRun(KLWV.WARM_ORDER.Length))
	AssertTrue(KLWV_WarmSchedule(World.NextRoot, KLWV.WARM_START_DELAY_MS))
	World.Timers := []
	KLWV.windows[World.Which] := World.Entry
	World.ScriptPending := true
	KLWV_DelayedFirstPush(World.Which, World.Epoch)
	_MWR_DrainScript(World)
	AssertFalse(World.Entry["first_paint_done"])
	AssertEqual(1, World.Handles.Length)
	_MWR_Complete(World.Handles[1], "A")
	AssertEqual(1, World.Timers.Length)
	World.Timers[1].Call()
	loop KLWV.FULL_BUILD_MAX_RETRIES {
		Owner := World.Entry["full_build_retry_owner"]
		AssertEqual(A_Index - 1, Owner["attempt"])
		AssertEqual(0, Owner["revision"])
		_MWTB_Fail(World)
		AssertEqual(A_Index, World.Entry["full_build_retry_owner"]["attempt"])
		AssertEqual(A_Index + 1, World.Timers.Length)
		World.Timers[World.Timers.Length].Call()
	}
	AssertEqual(4, World.Handles.Length, "A and three actual B reservations must have been admitted")
	World.Owner := World.Entry["full_build_retry_owner"]
	AssertEqual(2, World.Owner["attempt"])
	AssertEqual(0, World.Owner["revision"])
	AssertEqual(0, World.Entry["full_build_requested_revision"])
	AssertEqual(World.NextRoot, World.Handles[4].Root)
	AssertEqual(1, World.Handles[4].Starts)
	AssertFalse(World.Entry["first_paint_done"])
	AssertFalse(World.Entry["full_build_done"])
	AssertFalse(FSStrictExists(World.Paths[2]))
	AssertEqual(0, World.View.Messages.Length)
}

_MWTB_FinishCommitted(World, FullIndex) {
	AssertTrue(World.Entry["first_paint_done"])
	AssertTrue(World.Entry["full_build_done"])
	AssertFalse(World.Entry.Has("full_build_retry_owner"))
	AssertEqual(1, World.View.Messages.Length)
	AssertTrue(InStr(World.View.Messages[1], '"store":"B"', true) > 0)
	AssertTrue(InStr(FSReadStrict(World.Paths[2]), '"store":"B"', true) > 0)
	AssertEqual(1, World.IngestTimers.Length)
	World.IngestTimers[1].Call()
	AssertEqual(FullIndex + 1, World.Handles.Length)
	AssertEqual("live", World.Handles[FullIndex + 1].Mode)
	AssertEqual(World.NextRoot, World.Handles[FullIndex + 1].Root)
	AssertEqual("", World.Entry["pending_ingest_mode"])
	_MWR_Complete(World.Handles[FullIndex + 1], "B-live")
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertEqual(2, World.View.Messages.Length)
	AssertTrue(InStr(World.View.Messages[2], '"store":"B-live"', true) > 0)
	AssertTrue(InStr(FSReadStrict(World.Paths[2]), '"store":"B-live"', true) > 0)
	AssertFalse(World.Entry.Get("ingest_drain_armed", false))
	AssertTrue(World.Entry["full_build_done"])
}

_MWTB_Exercise(World) {
	_MWTB_AdmitLastAttempt(World)
	if World.Mode == "same-revision-failure" {
		_MWTB_Fail(World)
		AssertEqual(0, World.Entry.Get("ingest_revision", 0))
		AssertTrue(World.Entry["full_build_retry_exhausted"], "the same input still has a bounded failure budget")
		AssertEqual(0, World.Entry["full_build_retry_revision"])
		AssertFalse(World.Entry.Has("full_build_retry_owner"))
		AssertEqual(3, World.Timers.Length)
		AssertEqual(0, World.IngestTimers.Length)
		KLWV_NotifyIngest("manifest")
		World.Timers[3].Call()
		AssertEqual(0, World.Entry.Get("ingest_revision", 0), "a manifest does not certify new committed input")
		AssertEqual(4, World.Handles.Length, "neither a manifest nor the old retry may bypass exhaustion")
		AssertEqual(0, KLPFWorker.jobs.Count)
		AssertFalse(World.Entry["first_paint_done"])
		AssertFalse(FSStrictExists(World.Paths[2]))
		AssertEqual(0, World.View.Messages.Length)
		return
	}
	_MWI_Notify(World)
	AssertTrue(World.Entry["full_build_retry_owner"] == World.Owner)
	AssertEqual(0, World.Owner["revision"], "the admitted request still belongs to old input")
	AssertEqual(2, World.Owner["attempt"])
	AssertEqual(0, World.Entry["full_build_requested_revision"])
	AssertEqual(1, World.Entry["ingest_revision"])
	AssertEqual(4, World.Handles.Length, "committed input coalesces behind the admitted worker")
	if World.Mode == "new-commit-success" {
		_MWR_Complete(World.Handles[4], "B")
		_MWTB_FinishCommitted(World, 4)
		return
	}
	_MWTB_Fail(World)
	AssertEqual(1, World.IngestTimers.Length, "the genuine failed terminal schedules its pending drain")
	AssertFalse(World.IngestTimers[1].Call(), "ordinary ingest cannot yet paint this cold window")
	World.IngestTimers := [] ; Its actual callback has now retired.
	Next := World.Entry.Get("full_build_retry_owner", 0)
	_TestPrint("# metrics-warm-terminal-budget revision=" . World.Entry["ingest_revision"]
		. " prior_attempt=" . World.Owner["attempt"] . " debt=" . IsObject(Next)
		. " exhausted=" . World.Entry.Get("full_build_retry_exhausted", false)
		. " spawns=" . World.Handles.Length . " retry_arms=" . World.Timers.Length)
	AssertTrue(Next is Map, "a failed old projection must not exhaust the new revision's first recovery budget")
	AssertEqual(1, Next["revision"])
	AssertEqual(0, Next["attempt"], "new committed work starts with an unspent failure budget")
	AssertEqual(1, World.Entry["full_build_retry_revision"])
	AssertFalse(World.Entry.Get("full_build_retry_exhausted", false))
	if World.Handles.Length == 4 {
		AssertEqual(4, World.Timers.Length)
		World.Timers[4].Call()
	}
	AssertEqual(5, World.Handles.Length)
	AssertEqual(World.NextRoot, World.Handles[5].Root)
	AssertEqual("full", World.Handles[5].Mode)
	AssertEqual(1, World.Handles[5].Starts)
	AssertEqual(1, World.Entry["full_build_requested_revision"])
	_MWR_Complete(World.Handles[5], "B")
	_MWTB_FinishCommitted(World, 5)
}

_MWTB_Case(Mode) {
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
		Root := A_Temp . "\ergopti_warm_terminal_" . A_ScriptHwnd . "_" . ++Serial
		World := {Mode: Mode, Which: "apps", OldRoot: Root . "\old",
			NextRoot: Root . "\next", Handles: [], Timers: [], Inline: false, EarlyRan: false,
			Failure: 0, Job: 0, IngestTimers: [], View: _MWR_View(), ScriptPending: false, Epoch: -(0x70000000 + Serial)}
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
			_MWTB_Exercise(World)
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

for _MWTB_Mode in ["new-commit-failure", "same-revision-failure", "new-commit-success"]
	Test("Metrics warm terminal budget: " . _MWTB_Mode . " (metrics-warm-terminal-budget)", _MWTB_Case.Bind(_MWTB_Mode))
