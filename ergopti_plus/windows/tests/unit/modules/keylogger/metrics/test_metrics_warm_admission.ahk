; tests/unit/modules/keylogger/metrics/test_metrics_warm_admission.ahk

; ==============================================================================
; MODULE: Metrics Warm Admission Tests
; DESCRIPTION:
; The real warm-start diagnostic reenters the scheduler or opens a dashboard.
; Only external process launch and WebView delivery are passive. A stale-store
; completion must not certify a different store's historical projection.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MWA_View {
	__New() {
		this.Messages := []
	}
	PostWebMessageAsString(Message) {
		this.Messages.Push(Message)
	}
}

_MWA_Start(Handle, *) {
	Handle.Starts += 1
	return true
}

_MWA_Terminate(Handle, *) {
	Handle.Terminations += 1
	return true
}

_MWA_Spawn(World, Exe, Args, Done) {
	Flag := 0
	for Index, Arg in Args
		if Arg == "--keylogger-prefetch-worker"
			Flag := Index
	AssertTrue(Flag > 0, "the real scheduler must supply its worker invocation")
	AssertEqual(World.Which, Args[Flag + 1])
	AssertEqual("full", Args[Flag + 3])
	AssertTrue(KLPFWorker.jobs.Has(World.Which), "launch must follow the real reservation")
	Handle := {Starts: 0, Terminations: 0, Root: Args[Flag + 2], Stage: Args[Flag + 4], Done: Done}
	Handle.start := _MWA_Start.Bind(Handle)
	Handle.terminate := _MWA_Terminate.Bind(Handle)
	World.Handles.Push(Handle)
	return Handle
}

_MWA_Log(World, Line) {
	if World.Fired || !InStr(Line, "Metrics sidecar warm-up started for", true)
		return
	World.Fired := true
	try {
		switch World.Mode {
			case "job":
				AssertTrue(KLPF_RequestBuild(World.Which, World.NextRoot, "full", 83))
				World.Job := KLPFWorker.jobs[World.Which]
			case "window":
				KLWV.windows[World.Which] := World.Entry
			case "store-switch":
				AssertTrue(KLWV_WarmSchedule(World.NextRoot, KLWV.WARM_START_DELAY_MS))
				KLWV.windows[World.Which] := World.Entry
		}
	} catch as Failure {
		; Logger contains observer failures, so preserve the actual prerequisite.
		World.Failure := Failure
	}
}

_MWA_Complete(Handle) {
	AssertTrue(FSWriteCreateDurable(Handle.Stage, '{"metrics_manifest":{"warm_owner":"old"}}'))
	Handle.Done.Call(0, "", "")
}

_MWA_Check(World, Started) {
	if IsObject(World.Failure)
		throw World.Failure
	AssertTrue(World.Fired, "the genuine warm-start logger callout must be reached")
	if (World.Mode == "store-switch" || World.Mode == "terminal-store-switch"
			|| World.Mode == "terminal-current") && World.Handles.Length == 1
		_MWA_Complete(World.Handles[1])
	_TestPrint("# metrics-warm-admission mode=" . World.Mode . " spawns=" . World.Handles.Length
		. " full_done=" . World.Entry["full_build_done"] . " pushes=" . World.View.Messages.Length
		. " jobs=" . KLPFWorker.jobs.Count . " started=" . Started)
	switch World.Mode {
		case "window":
			AssertEqual(0, World.Handles.Length, "a dashboard admitted during logging owns its first/full-build lifecycle")
			AssertFalse(Started)
			AssertFalse(World.Entry["full_build_done"])
		case "store-switch":
			AssertFalse(World.Entry["full_build_done"],
				"a completed projection of the old store cannot certify the current store's historical build")
			AssertEqual(0, World.View.Messages.Length, "old-store completion cannot repaint the new store's stale sidecar")
			AssertEqual(0, World.Handles.Length, "the rearmed warm owner must supersede the captured old store")
			AssertFalse(Started)
		case "terminal-store-switch":
			AssertEqual(1, World.Handles.Length, "this warm owner was legitimately admitted before the store changed")
			AssertTrue(FSStrictExists(World.Paths[1]), "the old store still receives its own completed projection")
			AssertFalse(World.Entry["full_build_done"], "a current window of another store cannot inherit the old warm result")
			AssertEqual(0, World.View.Messages.Length)
		case "terminal-current":
			AssertEqual(1, World.Handles.Length)
			AssertTrue(World.Entry["full_build_done"], "a same-store window deferred to this admitted warm owner must still complete")
			AssertEqual(1, World.View.Messages.Length, "same-store completion must really push its published sidecar")
			AssertEqual(0, KLPFWorker.jobs.Count)
		case "job":
			AssertFalse(Started, "replace_active=false already refuses the reentrant job")
			AssertEqual(1, World.Handles.Length)
			AssertTrue(KLPFWorker.jobs[World.Which] == World.Job)
			AssertEqual(83, World.Job["epoch"])
			AssertEqual(World.NextRoot, World.Handles[1].Root)
			AssertEqual(1, World.Handles[1].Starts)
			AssertEqual(0, World.Handles[1].Terminations)
		case "current":
			AssertTrue(Started)
			AssertEqual(1, World.Handles.Length)
			AssertEqual(World.OldRoot, World.Handles[1].Root)
			AssertEqual(1, World.Handles[1].Starts)
			_MWA_Complete(World.Handles[1])
			AssertEqual(0, KLPFWorker.jobs.Count)
			AssertTrue(FSStrictExists(World.Paths[1]), "a current warm-up must publish through the genuine worker terminal")
	}
}

_MWA_Case(Mode) {
	global KLPF_LAST_JSON, _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
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
			WarmTimer: KLWV.warm_timer, WarmFn: KLWV.warm_timer_fn, Push: KLWV.first_paint_push_fn,
			HadJson: IsSet(KLPF_LAST_JSON), Suspended: A_IsSuspended}
		Saved.Json := Saved.HadJson ? KLPF_LAST_JSON : 0
		Root := A_Temp . "\ergopti_warm_admission_" . A_ScriptHwnd . "_" . ++Serial
		World := {Mode: Mode, Which: KLWV.WARM_ORDER[KLWV.WARM_ORDER.Length], OldRoot: Root . "\old",
			NextRoot: Root . "\next", Handles: [], Fired: false, Failure: 0, Job: 0, View: _MWA_View()}
		AssertEqual("apps", World.Which, "the last warm key isolates this case from successor chaining")
		World.Entry := Map("epoch", 83, "webview", World.View, "metrics_dir",
			(Mode == "window" || Mode == "terminal-current") ? World.OldRoot : World.NextRoot, "first_paint_done", false, "full_build_done", false)
		World.Paths := [KLPF_PrefetchPath(World.Which, World.OldRoot), KLPF_PrefetchPath(World.Which, World.NextRoot)]
		Installed := false, Owned := false, SidecarsReady := false, Primary := 0, CleanupError := 0
		try {
			AssertFalse(A_IsSuspended)
			AssertFalse(KLPF_ReloadKeepsWorkersOut())
			FSCreateDirectoryExclusiveStrict(Root), Owned := true
			FSCreateDirectoryExclusiveStrict(World.OldRoot), FSCreateDirectoryExclusiveStrict(World.NextRoot)
			for Path in World.Paths
				AssertFalse(FSStrictExists(Path), "a private fixture must not adopt an existing sidecar")
			SidecarsReady := true
			AssertTrue(FSWriteCreateDurable(World.Paths[2], '{"metrics_manifest":{"stale_new_store":true}}'))
			_ResetLogger()
			LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
			_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
			KLWV.windows := Map(), KLPFWorker.jobs := Map(), KLPF_LAST_JSON := Map(), Installed := true
			KLPFWorker.spawn_fn := _MWA_Spawn.Bind(World), KLPFWorker.publish_fn := 0
			KLWV.warm_metrics_dir := World.OldRoot, KLWV.warm_timer := 0
			KLWV.warm_timer_fn := (*) => true
			KLWV.first_paint_push_fn := 0
			LoggerSetTestSink(_MWA_Log.Bind(World))
			Started := KLWV_WarmRun(KLWV.WARM_ORDER.Length)
			if Mode == "terminal-store-switch" {
				AssertTrue(KLWV_WarmSchedule(World.NextRoot, KLWV.WARM_START_DELAY_MS))
				KLWV.windows[World.Which] := World.Entry
			} else if Mode == "terminal-current"
				KLWV.windows[World.Which] := World.Entry
			_MWA_Check(World, Started)
		} catch as Failure {
			Primary := Failure
		} finally {
			try {
				if Installed {
					KLWV.windows := Map()
					AssertTrue(KLPF_CancelAll(), "all private process reservations must retire before restoration")
				}
				if SidecarsReady
					for Path in World.Paths
						if FSStrictExists(Path)
							AssertTrue(FSDelete(Path))
			} catch as Failure {
				CleanupError := Failure
			} finally {
				Suspend(Saved.Suspended)
				KLWV.windows := Saved.Windows, KLPFWorker.jobs := Saved.Jobs, KLPFWorker.generation := Saved.Generation
				KLPFWorker.spawn_fn := Saved.Spawn, KLPFWorker.publish_fn := Saved.Publish
				KLWV.warm_metrics_dir := Saved.WarmDir, KLWV.warm_timer := Saved.WarmTimer
				KLWV.warm_timer_fn := Saved.WarmFn, KLWV.first_paint_push_fn := Saved.Push
				KLPF_LAST_JSON := Saved.HadJson ? Saved.Json : unset
				_TLOG_RestoreLoggerState(SavedLogger)
				for Name, Value in Extra
					%Name% := Value
				for Handle in World.Handles
					Handle.start := 0, Handle.terminate := 0, Handle.Done := 0
				if World.Job is Map
					World.Job.Clear()
				World.Entry.Clear()
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

for _MWA_Mode in ["window", "store-switch", "terminal-store-switch", "terminal-current", "job", "current"]
	Test("Metrics warm admission: " . _MWA_Mode . " after the real start diagnostic (metrics-warm-callout-owner)",
		_MWA_Case.Bind(_MWA_Mode))
