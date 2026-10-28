; tests/unit/modules/keystats/metrics/test_metrics_apps_editor.ahk

; ==============================================================================
; MODULE: Apps Dashboard Native Editor Regressions
; DESCRIPTION:
; Routes real page JSON through the public Windows host and canonical store.
; Only dialogs, deferred UI scheduling and process launch cross passive ports.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MAE_View {
	__New(Url) {
		this.Url := Url, this.Messages := [], this.OnRead := 0
	}
	Source {
		get {
			if HasMethod(this.OnRead, "Call") {
				Callback := this.OnRead, this.OnRead := 0
				Callback.Call()
			}
			return this.Url
		}
	}
	PostWebMessageAsString(Message) {
		this.Messages.Push(JsonParse(Message))
	}
}

_MAE_FileSnapshot(Path) {
	Reader := FSOpenStrict(Path, "r-wd", "UTF-8-RAW")
	AssertTrue(IsObject(Reader), "the fixture must retain its actual published file identity")
	try return FSHandleSnapshot(Reader.Handle)
	finally Reader.Close()
}

_MAE_SameFile(Expected, Path) {
	Observed := _MAE_FileSnapshot(Path)
	if !(Observed is Map) || !Observed.Get("ok", false)
		return false
	for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
		if Expected[Key] != Observed[Key]
			return false
	return true
}

_MAE_Defer(World, Callback, Period) {
	if Period == -1
		World.Deferred.Push(Callback)
	else
		AssertEqual(0, Period, "the editor may only queue once or retire its own callback")
}

_MAE_Message(World, Text, Title, Options) {
	World.Warnings += 1
}

_MAE_Input(World, Prompt, Title, Options, Default) {
	World.Inputs.Push(Default)
	Index := World.Inputs.Length
	if Index == 1 {
		if World.Mode == "close-during-input"
			KLWV.windows.Delete("apps")
		else if World.Mode == "navigate-during-input"
			World.View.Url := World.Url . "&foreign=1"
		else if World.Mode == "store-changed-during-input" {
			World.ExpectedDisk := '{"audit.exe":"foreign edit","legacy.exe":"neutral"}' . "`n"
			AssertTrue(FSWriteDurable(World.Path, World.ExpectedDisk))
		}
	}
	if World.Mode == "category-cancel" || (World.Mode == "pick-many-cancel" && Index == 3)
		return {Result: "Cancel", Value: "must never persist"}
	if Mod(Index, 2) == 1
		return {Result: "OK", Value: "Révision 😀"}
	if World.Mode == "locked-write" {
		World.Lock := FileOpen(World.Path, "r-wd")
		AssertTrue(IsObject(World.Lock), "the native destination lock must be acquired before testing refusal")
	}
	if World.Mode == "score-cancel"
		return {Result: "Cancel", Value: "2"}
	Score := World.Mode == "edit-lower" ? "-2" : (World.Mode == "edit-upper" ? "2"
		: (World.Mode == "score-invalid" ? "not-a-number" : (World.Mode == "score-range" ? "2.5"
		: (World.Mode == "score-low-range" ? "-2.5" : (World.Mode == "score-nonfinite" ? "1e309" : "1.25")))))
	return {Result: "OK", Value: Score}
}

_MAE_Picker(World, Options) {
	World.Pickers += 1
	World.Options := Options
	AssertEqual("metrics:app-categories", Options["owner"], "categorization must not reuse privacy exclusion ownership")
	if World.Mode == "picker-cancel"
		return false
	Receipt := AppPicker_IssueReceipt(Options["owner"], Options["initial"])
	World.Receipt := Receipt
	return Receipt
}

; The external process alone is replaced. Its captured native ticket still
; publishes a real SQLite-backed projection through the actual terminal owner.
_MAE_Spawn(World, Exe, Args, Done) {
	World.Spawns += 1
	World.WorkerArgs := Args
	World.Done := Done
	return {start: _MAE_Worker.Bind(World), terminate: (*) => true}
}

_MAE_Worker(World, *) {
	World.Started += 1
	Db := 0
	try {
		AssertTrue(KLPFWorker.jobs.Has("apps"), "the real scheduler must admit its job before starting the transport")
		Job := KLPFWorker.jobs["apps"]
		FlagIndex := 0
		for Index, Arg in World.WorkerArgs
			if Arg == "--keystats-prefetch-worker"
				FlagIndex := Index
		AssertTrue(FlagIndex > 0, "the actual refresh must launch the canonical worker mode")
		AssertEqual("apps", World.WorkerArgs[FlagIndex + 1])
		AssertEqual(World.Root, World.WorkerArgs[FlagIndex + 2], "the actual refresh command retains its trusted metrics root")
		AssertEqual("full", Job["mode"])
		Db := SQLite_Open(":memory:")
		AssertTrue(Db != 0 && KLR_LoadSchema(Db), "the refresh must use real SQLite and the canonical schema")
		for App in ["AUDIT.EXE", "legacy.exe"]
			AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_app_day(device_id,date,app,chars,category) VALUES ('owned','2026-10-20',"
				. SQLite_Q(App) . ",4,'native category');"))
		; The existing Func is retained, not copied or replaced. Its new trusted-
		; root argument is exercised only AFTER genuine page admission succeeds.
		Build := KLPF_BuildApps
		Resident := Map(), ResidentMetricsDir := Keystats.metrics_dir, ResidentDashboardDir := KLWV.metrics_dir
		for Key in ["categories", "file_path", "dirty", "store_model"]
			if KLAppCat.HasOwnProp(Key)
				Resident[Key] := KLAppCat.%Key%
		try {
			; A real projection child has not initialized the resident classifier.
			; The explicit root must resolve the durable record independently.
			KLAppCat.categories := Map(), KLAppCat.file_path := "", KLAppCat.dirty := false
			Keystats.metrics_dir := World.Root . "\not-the-store\", KLWV.metrics_dir := ""
			if KLAppCat.HasOwnProp("store_model")
				KLAppCat.DeleteProp("store_model")
			Blob := Build.Call(Db, true, World.Root)
		} finally {
			Keystats.metrics_dir := ResidentMetricsDir, KLWV.metrics_dir := ResidentDashboardDir
			for Key in ["categories", "file_path", "dirty", "store_model"] {
				if Resident.Has(Key)
					KLAppCat.%Key% := Resident[Key]
				else if KLAppCat.HasOwnProp(Key)
					KLAppCat.DeleteProp(Key)
			}
		}
		Encoded := KLPF_SerializeBlob(Blob)
		World.Projection := JsonParse(Encoded)
		AssertTrue(FSWriteDurable(Job["stage"], Encoded))
		World.PrefetchReceipt := _MAE_FileSnapshot(Job["stage"])
		AssertTrue(World.PrefetchReceipt.Get("ok", false))
		World.Done.Call(0, "", "")
	} catch as Failure {
		World.WorkerError := Failure
	} finally {
		if Db
			SQLite_Close(Db)
	}
	return true
}

_MAE_QueueAndRun(World) {
	Mode := World.Mode
	Action := InStr(Mode, "pick") == 1 ? "pick" : "edit"
	Message := Action == "pick" ? '{"action":"pick"}'
		: '{"action":"edit","app":"AUDIT.EXE","cat":"unconfirmed payload","score":2}'
	if Mode == "malformed-json"
		Message := '{"action":"edit","app":"AUDIT.EXE",'
	Sender := Mode == "wrong-sender" ? {} : World.View
	Epoch := Mode == "stale-epoch" ? 70 : 71
	Source := Mode == "wrong-message-source" ? World.Url . "&foreign=1" : World.Url
	Which := Mode == "typing-page" ? "typing" : "apps"
	if Which == "typing"
		KLWV.windows[Which] := World.Entry
	if Mode == "suspended"
		Suspend(true)
	KLWV_OnWebMessage(Which, Epoch, Sender, {Source: Source, TryGetWebMessageAsString: (*) => Message})
	if Mode == "suspended"
		Suspend(false)
	RejectedBeforeQueue := Mode == "wrong-sender" || Mode == "stale-epoch" || Mode == "wrong-message-source"
		|| Mode == "typing-page" || Mode == "suspended" || Mode == "malformed-json"
	AssertEqual(RejectedBeforeQueue ? 0 : 1, World.Deferred.Length,
		"the actual host must defer a valid visible action and reject unauthenticated page messages")
	AssertEqual(0, World.Inputs.Length, "WebMessageReceived must not open a synchronous native prompt")
	AssertEqual(0, World.Pickers)
	AssertTrue(FSUtf8ExactMatches(World.Path, World.Original), "page data alone cannot rewrite any original UTF8 byte")
	if RejectedBeforeQueue
		return
	if Mode == "navigate-before-run"
		World.View.Url := World.Url . "&foreign=1"
	if Mode == "getter-superseded"
		World.View.OnRead := () => KLWV.windows["apps"] := Map("epoch", 72)
	World.Deferred[1].Call()
	if Mode == "pick" || Mode == "pick-stale-receipt" || Mode == "pick-many-cancel" {
		AssertEqual(1, World.Pickers, "the real deferred pick action must reach the generic picker boundary")
		if Mode == "pick-stale-receipt"
			AppPicker_AdvanceOwner(World.Options["owner"])
		Selected := Mode == "pick-many-cancel" ? ["audit.exe", "second.exe"] : ["audit.exe"]
		AppPicker_InvokeSave(World.Options["on_save"], Selected, World.Receipt)
	}
}

_MAE_CheckResult(World) {
	Mode := World.Mode
	Success := Mode == "edit-fraction" || Mode == "edit-lower" || Mode == "edit-upper"
		|| Mode == "pick" || Mode == "pick-many-cancel"
	if !Success {
		ExpectedInputs := Map("category-cancel", 1, "score-cancel", 2, "score-invalid", 2,
			"score-range", 2, "score-low-range", 2, "score-nonfinite", 2, "locked-write", 2,
			"close-during-input", 1, "navigate-during-input", 1, "store-changed-during-input", 2)
		AssertEqual(ExpectedInputs.Get(Mode, 0), World.Inputs.Length, "the expected native admission boundary must be reached exactly")
		if Mode == "score-invalid" || Mode == "score-range" || Mode == "score-low-range"
			AssertEqual(1, World.Warnings, "invalid finite input must reach the passive warning boundary")
		if Mode == "picker-cancel"
			AssertEqual(1, World.Pickers, "the cancel control must reach the actual generic picker boundary")
		if Mode == "pick-wrong-root"
			AssertEqual(0, World.Pickers, "an untrusted store must be refused before opening the picker")
		AssertFalse(DirExist(World.Root . "\foreign"), "read admission must not create an untrusted destination")
		AssertTrue(FSUtf8ExactMatches(World.Path, World.ExpectedDisk), "refused or unconfirmed work cannot rewrite any owned source byte")
		AssertEqual(0, World.Spawns, "refusal cannot announce a fresh projection")
		AssertEqual("productive", KL_AppCat_Get("audit.exe"), "refusal cannot publish an uncommitted category")
		return
	}
	if IsObject(World.WorkerError)
		throw World.WorkerError
	AssertEqual(1, World.Spawns, "one confirmed edit batch must launch one actual full refresh")
	AssertEqual(1, World.Started)
	AssertFalse(KLPFWorker.jobs.Has("apps"), "the real worker terminal must retire its scheduler ticket")
	AssertTrue(KL_AppCat_Reload(), "the complete accepted record must survive a real reload")
	App := "audit.exe"
	AssertEqual("Révision 😀", KL_AppCat_Get(App), "Get must retain its public String API")
	Document := JsonParse(FSReadStrict(World.Path))
	AssertEqual("ergopti.app_categories", Document["schema"])
	AssertEqual(1, Document["version"])
	AssertTrue(Document["apps"]["legacy.exe"] is String,
		"untouched legacy categories must not silently become historical overrides")
	AssertEqual("neutral", Document["apps"]["legacy.exe"])
	ExpectedScore := Mode == "edit-lower" ? -2 : (Mode == "edit-upper" ? 2 : 1.25)
	ProjectedName := App == "audit.exe" ? "AUDIT.EXE" : App
	AssertTrue(World.Projection["user_categories"].Has(ProjectedName), "the real manifest casing must receive its explicit override")
	AssertEqual("Révision 😀", World.Projection["user_categories"][ProjectedName]["type"])
	AssertEqual(ExpectedScore, World.Projection["user_categories"][ProjectedName]["score"])
	AssertFalse(World.Projection["user_categories"].Has("legacy.exe"), "legacy strings remain future typing categories only")
	AssertTrue(World.View.Messages.Length > 0, "the real full-build callback must post the freshly published projection")
	Delivered := World.View.Messages[World.View.Messages.Length]["blob"]["user_categories"]
	AssertEqual(ExpectedScore, Delivered[ProjectedName]["score"])
	AssertEqual("productive", World.Inputs[1], "native defaults come from the trusted store, never payload.cat")
	AssertEqual("0", World.Inputs[2], "an untouched legacy string supplies only a zero score prefill")
	if Mode == "pick-many-cancel" {
		AssertEqual(3, World.Inputs.Length, "canceling the next app must stop the batch without undoing the first durable edit")
		AssertFalse(Document["apps"].Has("second.exe"))
	}
}

; Setup snapshots and private constructors can fail before the inner I/O
; transaction starts. Always return the caller's Critical mode on those paths.
_MAE_Case(Mode) {
	PreviousCritical := Critical("On")
	try return _MAE_CaseOwned(Mode, PreviousCritical)
	finally Critical(PreviousCritical)
}

_MAE_CaseOwned(Mode, PreviousCritical) {
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
		WorkerError: 0, Lock: 0, ExpectedDisk: "", Projection: 0, PrefetchReceipt: 0,
		Prefetch: KLPF_PrefetchPath("apps", Root) }
	World.Original := '{"audit.exe":"productive","legacy.exe":"neutral"}' . "`n"
	World.ExpectedDisk := World.Original
	World.View := _MAE_View(World.Url)
	World.Entry := Map("epoch", 71, "webview", World.View, "navigation_url", World.Url,
		"metrics_dir", Root, "first_paint_done", true, "full_build_done", false,
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
		KLPFWorker.jobs := Map(), KLPFWorker.spawn_fn := _MAE_Spawn.Bind(World), KLPFWorker.publish_fn := 0
		KLWV.first_paint_push_fn := 0
		KLWV.full_build_timer_fn := (*) => 0
		KLPF_LAST_JSON := Map(), KLHook.prev_app := "", Keystats.metrics_dir := Root . "\"
		_AppPickerOwnerEpochs := Map(), _AppPickerActiveReceipts := Map()
		_KLRDC_EnsureSharedDir()
		if Mode == "wrong-root" || Mode == "pick-wrong-root"
			World.Entry["metrics_dir"] := Root . "\foreign"
		_MAE_QueueAndRun(World)
		_MAE_CheckResult(World)
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
				World.Entry.Clear(), World.Deferred.Length := 0
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

for _MAE_Mode in ["edit-fraction", "edit-lower", "edit-upper", "pick", "pick-many-cancel",
	"category-cancel", "score-cancel", "score-invalid", "score-range", "score-low-range", "score-nonfinite", "locked-write",
	"stale-epoch", "wrong-sender", "wrong-message-source", "typing-page", "suspended", "malformed-json",
	"wrong-root", "pick-wrong-root", "navigate-before-run", "getter-superseded", "close-during-input",
	"navigate-during-input", "store-changed-during-input", "pick-stale-receipt", "picker-cancel"]
	Test("Apps category host: " . _MAE_Mode . " preserves document and durable ownership (metrics-app-category-host)",
		_MAE_Case.Bind(_MAE_Mode))
