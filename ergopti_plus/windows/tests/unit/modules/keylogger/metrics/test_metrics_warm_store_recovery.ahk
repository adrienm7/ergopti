; tests/unit/modules/keylogger/metrics/test_metrics_warm_store_recovery.ahk
; AFTER-only: real publication and window delivery, with passive process/timer/COM
; boundaries. Calling a captured timer qualifies its callback, not elapsed time.
#Requires AutoHotkey v2.0

class _MWR_View extends _MWA_View {
	Scripts := 0
	SettledScripts := 0
	ExecuteScriptAsync(Script) {
		this.Scripts += 1
		; COM is passive here. Complete its promise observation synchronously
		; so only the REAL InjectI18n timer needs to be drained.
		return _MWR_ScriptPromise(this)
	}
}

class _MWR_ScriptPromise {
	__New(View) {
		this.View := View
	}
	onSettled(Success, Failure) {
		Success.Call("null")
		this.View.SettledScripts += 1
	}
}

_MWR_DrainScript(World) {
	if !World.ScriptPending
		return
	PreviousCritical := Critical("Off")
	try {
		Started := A_TickCount
		while World.View.SettledScripts == 0 && TickElapsed(Started) < 5000
			Sleep(5)
	} finally Critical(PreviousCritical)
	AssertEqual(1, World.View.Scripts, "the real queued locale callback must reach the private view")
	AssertEqual(1, World.View.SettledScripts, "its script observer must retire before restoring logger/window state")
	World.ScriptPending := false
}

_MWR_Timer(World, Callback, Period) {
	World.Timers.Push(Callback)
	AssertTrue(Period < 0, "recovery remains one-shot")
	if World.Inline {
		World.Inline := false
		try {
			AssertTrue(KLPFWorker.jobs[World.Which] == World.Job,
				"the first callback is deliberately delivered BEFORE the old terminal retires")
			if World.Mode == "pause"
				Suspend(true)
			Callback.Call()
			World.EarlyRan := true
		} catch as Failure {
			World.Failure := Failure
		}
	}
	return true
}

_MWR_Complete(Handle, Tag) {
	AssertTrue(FSWriteCreateDurable(Handle.Stage, '{"metrics_manifest":{"store":"' . Tag . '"}}'))
	Handle.Done.Call(0, "", "")
}

_MWR_Exercise(World) {
	Index := World.Mode == "chain" ? 1 : KLWV.WARM_ORDER.Length
	AssertTrue(KLWV_WarmRun(Index))
	AssertEqual(1, World.Handles.Length)
	World.Job := KLPFWorker.jobs[World.Which]
	if World.Mode == "chain" {
		_MWR_Complete(World.Handles[1], "A")
		AssertEqual(1, World.Timers.Length, "the old-store successor is genuinely armed")
		OldChain := World.Timers[1]
		AssertTrue(KLWV_WarmSchedule(World.NextRoot, KLWV.WARM_START_DELAY_MS))
		AssertFalse(OldChain.Call(), "an already-armed chain cannot start halfway through a different store")
		AssertEqual(1, World.Handles.Length)
		World.Timers[2].Call()
		AssertEqual(2, World.Handles.Length, "the separately scheduled new-store boot remains usable")
		AssertEqual(World.NextRoot, World.Handles[2].Root)
		_MWR_Complete(World.Handles[2], "B")
		return
	}
	AssertTrue(KLWV_WarmSchedule(World.NextRoot, KLWV.WARM_START_DELAY_MS))
	World.Timers := [] ; The warm-schedule timer is passive and is not this retry.
	KLWV.windows[World.Which] := World.Entry
	World.ScriptPending := true ; Mark BEFORE the call, including exceptions after SetTimer.
	KLWV_DelayedFirstPush(World.Which, World.Epoch)
	_MWR_DrainScript(World)
	AssertEqual(1, World.Handles.Length, "the actual first-paint path stands down behind store A")
	AssertFalse(World.Entry["first_paint_done"])
	AssertFalse(FSStrictExists(World.Paths[2]), "store B has no old snapshot to hide a lost recovery")
	World.Inline := true
	_MWR_Complete(World.Handles[1], "A")
	if IsObject(World.Failure)
		throw World.Failure
	AssertTrue(World.EarlyRan)
	AssertEqual(0, KLPFWorker.jobs.Count, "A must really retire before the deferred retry is resumed")
	AssertFalse(World.Entry["full_build_done"], "A cannot certify B")
	AssertEqual(0, World.View.Messages.Length)
	AssertTrue(World.Entry.Has("full_build_retry_owner"), "an early callback must retain B's debt")
	Owner := World.Entry["full_build_retry_owner"]
	AssertEqual(0, Owner["attempt"], "waiting for another store consumes no failure budget")
	if World.Mode == "pause" {
		AssertTrue(World.Entry.Has("pending_full_build_retry"))
		AssertTrue(World.Entry["pending_full_build_retry"]["owner"] == Owner)
		AssertEqual(1, World.Timers.Length, "pause does not arm a spinning timer")
		Suspend(false)
		KLWV_FlushPendingFullBuildRetries()
	}
	AssertEqual(2, World.Timers.Length, "the early callback rearms, or resume transfers the exact pending owner")
	Retry := World.Timers[2]
	if World.Mode == "retired" {
		Next := Map("epoch", World.Epoch, "webview", World.View, "metrics_dir", World.NextRoot,
			"first_paint_done", false, "full_build_done", false)
		KLWV.windows[World.Which] := Next
		Retry.Call()
		AssertEqual(1, World.Handles.Length, "equal epoch/root does not admit a retired Entry's callback")
		AssertFalse(Next.Has("full_build_retry_owner"))
		AssertFalse(Next["full_build_done"])
		return
	}
	if World.Mode == "takeover" {
		AssertTrue(KLPF_RequestBuild(World.Which, World.NextRoot, "full", World.Epoch,
			KLWV_OnFullBuildTerminal.Bind(World.Which, World.Epoch, 0), false))
		Replacement := KLPFWorker.jobs[World.Which]
		Retry.Call()
		AssertTrue(KLPFWorker.jobs[World.Which] == Replacement)
		AssertEqual(0, World.Handles[2].Terminations)
	} else {
		Retry.Call()
		AssertTrue(World.Entry["full_build_retry_owner"] == Owner)
		Retry.Call() ; A duplicate cannot revoke the recovery's own terminal.
		AssertTrue(World.Entry["full_build_retry_owner"] == Owner)
	}
	AssertEqual(2, World.Handles.Length, "B receives exactly one real scheduler reservation")
	AssertEqual(World.NextRoot, World.Handles[2].Root)
	AssertEqual(1, World.Handles[2].Starts)
	_MWR_Complete(World.Handles[2], "B")
	AssertEqual(0, KLPFWorker.jobs.Count)
	AssertTrue(World.Entry["first_paint_done"])
	AssertTrue(World.Entry["full_build_done"])
	AssertEqual(1, World.View.Messages.Length)
	AssertTrue(InStr(World.View.Messages[1], '"store":"B"', true) > 0,
		"the actual push must contain the new store's published projection")
	AssertTrue(InStr(FSReadStrict(World.Paths[2]), '"store":"B"', true) > 0)
	AssertFalse(World.Entry.Has("full_build_retry_owner"))
	AssertFalse(World.Entry.Has("pending_full_build_retry"))
	Retry.Call()
	AssertEqual(2, World.Handles.Length, "a completed recovery makes its old timer inert")
}

_MWR_Case(Mode) {
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
			Full: KLWV.full_build_timer_fn, Push: KLWV.first_paint_push_fn,
			HadJson: IsSet(KLPF_LAST_JSON), HadShared: IsSet(_SharedDir), Suspended: A_IsSuspended}
		Saved.Json := Saved.HadJson ? KLPF_LAST_JSON : 0
		Saved.Shared := Saved.HadShared ? _SharedDir : 0
		Root := A_Temp . "\ergopti_warm_recovery_" . A_ScriptHwnd . "_" . ++Serial
		World := {Mode: Mode, Which: Mode == "chain" ? "typing" : "apps", OldRoot: Root . "\old",
			NextRoot: Root . "\next", Handles: [], Timers: [], Inline: false, EarlyRan: false,
			Failure: 0, Job: 0, View: _MWR_View(), ScriptPending: false, Epoch: -(0x40000000 + Serial)}
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
			KLPFWorker.spawn_fn := _MWA_Spawn.Bind(World), KLPFWorker.publish_fn := 0
			KLWV.warm_metrics_dir := World.OldRoot, KLWV.warm_timer := 0
			KLWV.warm_timer_fn := _MWR_Timer.Bind(World)
			KLWV.full_build_timer_fn := _MWR_Timer.Bind(World)
			KLWV.first_paint_timer_fn := (*) => true
			KLWV.first_paint_push_fn := 0
			_MWR_Exercise(World)
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
				KLPF_LAST_JSON := Saved.HadJson ? Saved.Json : unset
				_SharedDir := Saved.HadShared ? Saved.Shared : unset
				_TLOG_RestoreLoggerState(SavedLogger)
				for Name, Value in Extra
					%Name% := Value
				for Handle in World.Handles
					Handle.start := 0, Handle.terminate := 0, Handle.Done := 0
				World.Timers := [], World.Entry.Clear()
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

for _MWR_Mode in ["early", "pause", "retired", "takeover", "chain"]
	Test("Metrics warm store recovery: " . _MWR_Mode . " (metrics-warm-store-recovery)", _MWR_Case.Bind(_MWR_Mode))
