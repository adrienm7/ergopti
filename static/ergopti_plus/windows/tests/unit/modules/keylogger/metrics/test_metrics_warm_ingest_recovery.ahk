; tests/unit/modules/keylogger/metrics/test_metrics_warm_ingest_recovery.ahk
; TEST-only: the public notification certifies a committed ingest. This fixture
; does not execute the SQL append producer. Scheduler, publication, read, push,
; and paint are real; process, COM, and timer-delivery boundaries are passive.
#Requires AutoHotkey v2.0

_MWI_Spawn(World, Exe, Args, Done) {
	Flag := 0
	for Index, Arg in Args
		if Arg == "--keylogger-prefetch-worker"
			Flag := Index
	AssertTrue(Flag > 0, "the genuine worker invocation must be present")
	AssertEqual(World.Which, Args[Flag + 1])
	Mode := Args[Flag + 3]
	AssertTrue(Mode == "full" || Mode == "live")
	AssertTrue(KLPFWorker.jobs.Has(World.Which), "launch follows the genuine reservation")
	Handle := {Starts: 0, Terminations: 0, Root: Args[Flag + 2], Mode: Mode, Stage: Args[Flag + 4], Done: Done}
	Handle.start := _MWA_Start.Bind(Handle)
	Handle.terminate := _MWA_Terminate.Bind(Handle)
	World.Handles.Push(Handle)
	return Handle
}

_MWI_IngestTimer(World, Callback, Period) {
	AssertTrue(Period < 0)
	World.IngestTimers.Push(Callback)
	return true
}

_MWI_Notify(World) {
	Before := World.Entry.Get("ingest_revision", 0)
	KLWV_NotifyIngest("live")
	AssertEqual(Before + 1, World.Entry["ingest_revision"], "the actual public producer advances revision")
	AssertEqual("live", World.Entry["pending_ingest_mode"])
}

_MWI_Exercise(World) {
	AssertTrue(KLWV_WarmRun(KLWV.WARM_ORDER.Length))
	AssertEqual(1, World.Handles.Length)
	AssertTrue(KLWV_WarmSchedule(World.NextRoot, KLWV.WARM_START_DELAY_MS))
	World.Timers := []
	KLWV.windows[World.Which] := World.Entry
	World.ScriptPending := true
	KLWV_DelayedFirstPush(World.Which, World.Epoch)
	_MWR_DrainScript(World)
	AssertFalse(World.Entry["first_paint_done"])
	AssertFalse(FSStrictExists(World.Paths[2]))
	if World.Mode == "before-owner"
		_MWI_Notify(World)
	_MWR_Complete(World.Handles[1], "A")
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertEqual(1, World.Timers.Length)
	Owner := World.Entry["full_build_retry_owner"]
	AssertEqual(World.Mode == "before-owner" ? 1 : 0, Owner["revision"])
	AssertEqual(0, Owner["attempt"])
	AssertFalse(World.Entry["full_build_done"], "store A cannot certify B")
	AssertEqual(0, World.View.Messages.Length)
	if World.Mode == "waiting-commit" {
		_MWI_Notify(World)
		AssertEqual(0, Owner["revision"], "this retry was captured BEFORE the real ingest notification")
		AssertFalse(KLWV_DrainPendingIngest(World.Which, World.Epoch),
			"a cold dashboard cannot yet consume the ordinary live drain")
	}
	World.Timers[1].Call()
	_TestPrint("# metrics-warm-ingest mode=" . World.Mode . " revision="
		. World.Entry.Get("ingest_revision", 0) . " debt="
		. IsObject(World.Entry.Get("full_build_retry_owner", 0))
		. " spawns=" . World.Handles.Length . " retry_arms=" . World.Timers.Length)
	; A revision change may launch B immediately or transfer its debt to the
	; latest revision. It must not erase the only route to B's first paint.
	if World.Handles.Length == 1 {
		NextOwner := World.Entry.Get("full_build_retry_owner", 0)
		AssertTrue(NextOwner is Map,
			"a committed ingest must not strand the cold window by retiring its only recovery debt")
		AssertEqual(World.Entry["ingest_revision"], NextOwner["revision"])
		AssertEqual(0, NextOwner["attempt"], "new durable input consumes no failure budget")
		AssertEqual(2, World.Timers.Length)
		World.Timers[2].Call()
	}
	AssertEqual(2, World.Handles.Length)
	AssertEqual(World.NextRoot, World.Handles[2].Root)
	AssertEqual("full", World.Handles[2].Mode)
	AssertEqual(1, World.Handles[2].Starts)
	if World.Mode == "admitted-commit" {
		_MWI_Notify(World)
		AssertEqual(0, World.IngestTimers.Length, "ingest coalesces behind the admitted B owner")
		AssertEqual(2, World.Handles.Length)
	}
	_MWR_Complete(World.Handles[2], "B")
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertTrue(World.Entry["first_paint_done"])
	AssertTrue(World.Entry["full_build_done"])
	AssertFalse(World.Entry.Has("full_build_retry_owner"))
	AssertEqual(1, World.View.Messages.Length)
	AssertTrue(InStr(World.View.Messages[1], '"store":"B"', true) > 0)
	AssertTrue(InStr(FSReadStrict(World.Paths[2]), '"store":"B"', true) > 0)
	; All three orders retain the same committed live notification. Once the
	; first paint is real, the terminal's canonical drain can consume it.
	AssertEqual(1, World.IngestTimers.Length)
	World.IngestTimers[1].Call()
	AssertEqual(3, World.Handles.Length)
	AssertEqual("live", World.Handles[3].Mode)
	AssertEqual(World.NextRoot, World.Handles[3].Root)
	AssertEqual("", World.Entry["pending_ingest_mode"])
	_MWR_Complete(World.Handles[3], "B-live")
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertEqual(2, World.View.Messages.Length)
	AssertTrue(InStr(World.View.Messages[2], '"store":"B-live"', true) > 0)
	AssertTrue(InStr(FSReadStrict(World.Paths[2]), '"store":"B-live"', true) > 0)
	AssertFalse(World.Entry.Get("ingest_drain_armed", false))
	AssertTrue(World.Entry["full_build_done"])
}

_MWI_Case(Mode) {
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
		Root := A_Temp . "\ergopti_warm_ingest_" . A_ScriptHwnd . "_" . ++Serial
		World := {Mode: Mode, Which: "apps", OldRoot: Root . "\old",
			NextRoot: Root . "\next", Handles: [], Timers: [], Inline: false, EarlyRan: false,
			Failure: 0, Job: 0, IngestTimers: [], View: _MWR_View(), ScriptPending: false, Epoch: -(0x60000000 + Serial)}
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
			_MWI_Exercise(World)
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

for _MWI_Mode in ["waiting-commit", "before-owner", "admitted-commit"]
	Test("Metrics warm ingest recovery: " . _MWI_Mode . " (metrics-warm-ingest-recovery)", _MWI_Case.Bind(_MWI_Mode))
