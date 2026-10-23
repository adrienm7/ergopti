; tests/unit/modules/keystats/metrics/test_metrics_apps_refresh_retry.ahk

; ==============================================================================
; MODULE: App Category Refresh Retry Regression
; DESCRIPTION:
; Qualifies the new apps editor after a confirmed durable edit on a painted page.
; A failed detached worker must retain the canonical retry and publish its result.
; ==============================================================================

#Requires AutoHotkey v2.0

_MAER_FailFirst(World, *) {
	World.Started += 1
	AssertTrue(KLPFWorker.jobs.Has("apps"), "the real scheduler must admit the failed worker too")
	World.Done.Call(17, "", "owned worker failure")
	return true
}

_MAER_Spawn(World, Exe, Args, Done) {
	Handle := _MAE_Spawn(World, Exe, Args, Done)
	if World.Spawns == 1
		Handle.start := _MAER_FailFirst.Bind(World)
	return Handle
}

; This replaces only OS timer registration. Executing its actual BoundFunc
; below qualifies the canonical retry path, not physical SetTimer latency.
_MAER_RetryTimer(World, Callback, Period) {
	World.Timers.Push([Callback, Period])
	return true
}

_MAER_CheckResult(World) {
	AssertEqual(1, World.Spawns)
	AssertEqual(1, World.Started)
	AssertFalse(KLPFWorker.jobs.Has("apps"), "the failed worker must release its real scheduler slot")
	AssertEqual("Révision 😀", KL_AppCat_Get("audit.exe"), "projection failure must not undo the durable edit")
	Disk := JsonParse(FSReadStrict(World.Path))
	AssertEqual("Révision 😀", Disk["apps"]["audit.exe"]["type"])
	AssertEqual(1.25, Disk["apps"]["audit.exe"]["score"])
	AssertFalse(World.Entry["full_build_done"], "the old painted result cannot acknowledge a newly committed category")
	AssertEqual(23, World.Entry["full_build_requested_revision"], "the new full build must own the current revision")
	AssertEqual(1, World.Timers.Length, "the failed new projection must arm exactly one canonical retry")
	AssertEqual(-KLWV.FULL_BUILD_RETRY_MS, World.Timers[1][2])
	AssertEqual(0, World.View.Messages.Length, "the failed worker must not announce an old projection as current")
	AssertTrue(HasMethod(World.Timers[1][1], "Call"))
	Retry := World.Timers[1][1]
	Retry.Call()
	if IsObject(World.WorkerError)
		throw World.WorkerError
	AssertEqual(2, World.Spawns, "the actual retry callback must launch a new projection transport")
	AssertEqual(2, World.Started)
	AssertFalse(KLPFWorker.jobs.Has("apps"))
	AssertTrue(World.Entry["full_build_done"], "the real successful terminal must acknowledge the recovered full projection")
	AssertEqual(2, World.Inputs.Length, "a durable category is not prompted or committed again during refresh recovery")
	AssertEqual(1, World.Timers.Length, "success must not schedule a further retry")
	AssertEqual("Révision 😀", World.Projection["user_categories"]["AUDIT.EXE"]["type"])
	AssertEqual(1.25, World.Projection["user_categories"]["AUDIT.EXE"]["score"])
	AssertEqual(1, World.View.Messages.Length, "the actual retry publication must reach its original page once")
	Delivered := World.View.Messages[1]["blob"]["user_categories"]["AUDIT.EXE"]
	AssertEqual("Révision 😀", Delivered["type"])
	AssertEqual(1.25, Delivered["score"])
	AssertTrue(KL_AppCat_Reload())
	AssertEqual("Révision 😀", KL_AppCat_Get("AUDIT.EXE"))
	Retry.Call()
	AssertEqual(2, World.Spawns, "the now-stale retry cannot replace its successful publication")
	AssertEqual(1, World.View.Messages.Length)
}

_MAER_Case() {
	PreviousCritical := Critical("On")
	try return _MAER_CaseOwned(PreviousCritical)
	finally Critical(PreviousCritical)
}

_MAER_CaseOwned(PreviousCritical) {
	Mode := "edit-fraction"
	global _AppPickerOwnerEpochs, _AppPickerActiveReceipts, KLPF_LAST_JSON, _SharedDir
	static Serial := 0
	SavedCategory := Map()
	for Key in ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"]
		if KLAppCat.HasOwnProp(Key)
			SavedCategory[Key] := KLAppCat.%Key%
	HadResidentDir := Keystats.HasOwnProp("metrics_dir")
	Saved := { Windows: KLWV.windows, MetricsDir: KLWV.metrics_dir, Jobs: KLPFWorker.jobs,
		Generation: KLPFWorker.generation, Spawn: KLPFWorker.spawn_fn, Publish: KLPFWorker.publish_fn,
		Push: KLWV.first_paint_push_fn, FullTimer: KLWV.full_build_timer_fn,
		PickerEpochs: _AppPickerOwnerEpochs, PickerReceipts: _AppPickerActiveReceipts,
		HadDir: HadResidentDir, Dir: HadResidentDir ? Keystats.metrics_dir : 0,
		App: KLHook.prev_app, Suspended: A_IsSuspended,
		Shared: IsSet(_SharedDir) ? _SharedDir : 0, HadShared: IsSet(_SharedDir),
		Json: IsSet(KLPF_LAST_JSON) ? KLPF_LAST_JSON : 0, HadJson: IsSet(KLPF_LAST_JSON) }
	Root := A_Temp . "\ergopti_apps_editor_" . A_ScriptHwnd . "_" . ++Serial
	World := {Mode: Mode, Root: Root, Path: Root . "\" . KLAppCatConst.FILE_NAME,
		Url: "https://ergopti.metrics/ui/metrics_apps/index.html?owned=71", Deferred: [],
		Inputs: [], Pickers: 0, Warnings: 0, Options: 0, Receipt: 0, Spawns: 0, Started: 0,
		WorkerError: 0, Lock: 0, ExpectedDisk: "", Projection: 0, PrefetchReceipt: 0, Timers: [],
		Prefetch: KLPF_PrefetchPath("apps", Root) }
	World.Original := '{"audit.exe":"productive","legacy.exe":"neutral"}' . "`n"
	World.ExpectedDisk := World.Original
	World.View := _MAE_View(World.Url)
	World.Entry := Map("epoch", 71, "webview", World.View, "navigation_url", World.Url,
		"metrics_dir", Root, "first_paint_done", true, "full_build_done", true,
		"ingest_revision", 23, "full_build_requested_revision", 17, "full_build_retry_exhausted", true,
		"apps_editor_ports", Map("defer", _MAE_Defer.Bind(World), "input", _MAE_Input.Bind(World),
			"picker", _MAE_Picker.Bind(World), "message", _MAE_Message.Bind(World)))
	Owned := false, Primary := 0, CleanupError := 0
	Timer := (*) => 0
	try {
		AssertFalse(A_IsSuspended, "the fixture must not borrow a paused driver's state")
		AssertTrue(SavedCategory.Get("write_owner", 0) is Integer && SavedCategory.Get("write_owner", 0) == 0,
			"an active foreign category writer cannot be replaced by this fixture")
		FSCreateDirectoryExclusiveStrict(Root), Owned := true
		AssertFalse(FSStrictExists(World.Prefetch), "a new private root must not adopt an existing projection")
		AssertTrue(FSWriteCreateDurable(World.Path, World.Original))
		KLAppCat.categories := Map(), KLAppCat.file_path := "", KLAppCat.dirty := false
		KLAppCat.save_fn := Timer
		if KLAppCat.HasOwnProp("write_owner")
			KLAppCat.write_owner := 0
		AssertTrue(KL_AppCat_Init(Root), "the existing public loader must admit the private legacy image")
		KLWV.windows := Map("apps", World.Entry), KLWV.metrics_dir := Root
		KLPFWorker.jobs := Map(), KLPFWorker.spawn_fn := _MAER_Spawn.Bind(World), KLPFWorker.publish_fn := 0
		KLWV.first_paint_push_fn := 0
		KLWV.full_build_timer_fn := _MAER_RetryTimer.Bind(World)
		KLPF_LAST_JSON := Map(), KLHook.prev_app := "", Keystats.metrics_dir := Root . "\"
		_AppPickerOwnerEpochs := Map(), _AppPickerActiveReceipts := Map()
		_KLRDC_EnsureSharedDir()
		if Mode == "wrong-root" || Mode == "pick-wrong-root"
			World.Entry["metrics_dir"] := Root . "\foreign"
		_MAE_QueueAndRun(World)
		_MAER_CheckResult(World)
	} catch as Failure {
		Primary := Failure
	} finally {
		Suspend(Saved.Suspended)
		try {
			if IsObject(World.Lock)
				World.Lock.Close()
			; Detach the private host before canceling its worker, so no teardown
			; terminal can arm a retry against an unrelated restored dashboard.
			KLWV.windows := Map()
			AssertTrue(KLPF_CancelBuild("apps"))
			if World.PrefetchReceipt is Map && FSStrictExists(World.Prefetch)
				AssertTrue(FSDeleteVerified(World.Prefetch, _MAE_SameFile.Bind(World.PrefetchReceipt)),
					"cleanup must delete only the exact private image published by this worker")
		} catch as Failure {
			CleanupError := Failure
		} finally {
			try SetTimer(Timer, 0)
			finally {
				for Key in ["categories", "file_path", "dirty", "save_fn", "write_owner", "store_model"] {
					if SavedCategory.Has(Key)
						KLAppCat.%Key% := SavedCategory[Key]
					else if KLAppCat.HasOwnProp(Key)
						KLAppCat.DeleteProp(Key)
				}
				KLWV.windows := Saved.Windows, KLWV.metrics_dir := Saved.MetricsDir
				KLWV.first_paint_push_fn := Saved.Push, KLWV.full_build_timer_fn := Saved.FullTimer
				KLPFWorker.jobs := Saved.Jobs, KLPFWorker.generation := Saved.Generation
				KLPFWorker.spawn_fn := Saved.Spawn, KLPFWorker.publish_fn := Saved.Publish
				if Saved.HadDir
					Keystats.metrics_dir := Saved.Dir
				else if Keystats.HasOwnProp("metrics_dir")
					Keystats.DeleteProp("metrics_dir")
				KLHook.prev_app := Saved.App, KLPF_LAST_JSON := Saved.HadJson ? Saved.Json : unset
				_SharedDir := Saved.HadShared ? Saved.Shared : unset
				_AppPickerOwnerEpochs := Saved.PickerEpochs, _AppPickerActiveReceipts := Saved.PickerReceipts
				World.Entry.Clear(), World.Deferred.Length := 0, World.Timers.Length := 0
				if World.Options is Map
					World.Options.Clear()
				Critical(PreviousCritical)
			}
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
}

Test("Apps category refresh: failed projection retries after durable edit on an already painted page (metrics-app-category-refresh-retry)",
	_MAER_Case)
