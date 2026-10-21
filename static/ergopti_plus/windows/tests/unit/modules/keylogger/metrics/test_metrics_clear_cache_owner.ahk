; tests/unit/modules/keylogger/metrics/test_metrics_clear_cache_owner.ahk

; ==============================================================================
; MODULE: Metrics Cache Reset Message Owner Tests
; DESCRIPTION:
; A real purge diagnostic may replace its dashboard or pause the driver. The
; resumed message must preserve the successor's actual scheduler job. An
; admitted paused reset retains its recovery debt. Only the external worker
; process is passive; cache reset, files, logger and dispatch run.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MWCP_Args {
	__New(World) {
		this.World := World
	}
	Source {
		get {
			this.World.SourceReads += 1
			return this.World.Mode == "wrong-source" ? "https://foreign.invalid/" : this.World.Url
		}
	}
	TryGetWebMessageAsString() {
		this.World.PayloadReads += 1
		return '{"action":"clear_cache"}'
	}
}

_MWCP_Start(Handle, *) {
	Handle.Starts += 1
	return true
}

_MWCP_Terminate(Handle, *) {
	Handle.Terminations += 1
	return true
}

_MWCP_Spawn(World, Exe, Args, Done) {
	FlagIndex := 0
	for Index, Arg in Args
		if Arg == "--keylogger-prefetch-worker"
			FlagIndex := Index
	AssertTrue(FlagIndex > 0, "the actual scheduler must reach its canonical worker transport")
	AssertEqual("typing", Args[FlagIndex + 1])
	AssertEqual("full", Args[FlagIndex + 3])
	AssertTrue(KLPFWorker.jobs.Has("typing"), "the actual scheduler reserves the job before spawn")
	Handle := {Starts: 0, Terminations: 0, Root: Args[FlagIndex + 2], Done: Done}
	Handle.start := _MWCP_Start.Bind(Handle)
	Handle.terminate := _MWCP_Terminate.Bind(Handle)
	World.Handles.Push(Handle)
	return Handle
}

_MWCP_Terminal(World, Status, Stage := "") {
	World.Terminals.Push([Status, Stage])
}

_MWCP_PurgeLog(World, Line) {
	global KLPF_LAST_JSON
	if !InStr(Line, "KLWV_OnWebMessage: dashboard caches purged.", true)
		return
	World.PurgeLogs += 1
	try {
		AssertFalse(FSStrictExists(World.Path), "the real old-store file deletion must precede this diagnostic")
		AssertFalse(KLPF_LAST_JSON.Has(World.Path), "the real purge must remove its RAM snapshot before reentry")
		if World.Mode == "purge-pause" {
			Suspend(true)
			return
		}
		if !InStr(World.Mode, "-replace", true) || World.Replaced
			return
		World.Replaced := true
		if World.Mode == "view-replace" {
			World.Entry["webview"] := World.NextView
			World.LiveEntry := World.Entry
			World.LiveEpoch := 82
			World.LiveRoot := World.OldRoot
		} else {
			World.LiveEpoch := World.Mode == "entry-replace" ? 82 : 83
			World.LiveEntry := World.NextEntry
			World.LiveEntry["epoch"] := World.LiveEpoch
			if World.Mode == "entry-replace" {
				World.LiveEntry["webview"] := World.View
				World.LiveEntry["navigation_url"] := World.Url
			}
			KLWV.windows["typing"] := World.LiveEntry
			World.LiveRoot := World.NextRoot
		}
		AssertTrue(KLPF_RequestBuild("typing", World.LiveRoot, "full", World.LiveEpoch,
			_MWCP_Terminal.Bind(World)), "the purge sink must admit a genuine successor before resuming the old message")
		World.NextJob := KLPFWorker.jobs["typing"]
		World.NextHandle := World.NextJob["handle"]
		World.NextGeneration := World.NextJob["generation"]
	} catch as Failure {
		; Logger sinks contain callback exceptions. Do not turn an unmet fixture
		; prerequisite into a silent message refusal.
		World.Failure := Failure
	}
}

_MWCP_Check(World) {
	global KLPF_LAST_JSON, KLPF_MANIFEST_CACHE
	Current := KLPFWorker.jobs.Get("typing", 0)
	Terminations := 0
	for Handle in World.Handles
		Terminations += Handle.Terminations
	_TestPrint("# metrics-cache-message mode=" . World.Mode . " purge_logs=" . World.PurgeLogs
		. " source_reads=" . World.SourceReads . " payload_reads=" . World.PayloadReads
		. " spawns=" . World.Handles.Length . " terminations=" . Terminations
		. " retained_job=" . (IsObject(World.NextJob) && Current == World.NextJob)
		. " queued_retry=" . World.Entry.Has("pending_full_build_retry"))
	if IsObject(World.Failure)
		throw World.Failure
	Rejected := World.Mode == "wrong-sender" || World.Mode == "wrong-source" || World.Mode == "paused"
	AssertEqual(Rejected ? 0 : 1, World.PurgeLogs, "the test must distinguish admission from actual purge reentry")
	AssertEqual("foreign-disk", FSReadStrict(World.ForeignPath), "cache clearing cannot remove another store")
	AssertEqual("foreign-memory", KLPF_LAST_JSON[World.ForeignPath])
	if Rejected {
		AssertEqual("old-disk", FSReadStrict(World.Path))
		AssertEqual("old-memory", KLPF_LAST_JSON[World.Path])
		AssertTrue(IsSet(KLPF_MANIFEST_CACHE))
		AssertTrue(KLPF_MANIFEST_CACHE == World.Manifest)
		AssertTrue(KLRCache.last_sizes == World.ReaderSizes)
		AssertEqual(0, World.Handles.Length)
		AssertEqual(0, KLPFWorker.jobs.Count)
		AssertFalse(World.Entry.Has("pending_full_build_retry"),
			"a message refused before cache deletion cannot create a recovery debt")
		AssertEqual(World.Mode == "wrong-sender" ? 0 : 1, World.SourceReads)
		AssertEqual(World.Mode == "paused" ? 1 : 0, World.PayloadReads)
		return
	}
	AssertFalse(FSStrictExists(World.Path))
	AssertFalse(KLPF_LAST_JSON.Has(World.Path))
	AssertFalse(IsSet(KLPF_MANIFEST_CACHE))
	AssertEqual(0, KLRCache.last_sizes.Count)
	AssertEqual(1, World.SourceReads)
	AssertEqual(1, World.PayloadReads)
	if World.Replaced {
		AssertTrue(World.NextJob is Map, "the sink must have retained its genuine admitted scheduler job")
		AssertTrue(Current == World.NextJob, "a resumed clear-cache message cannot replace its successor job")
		AssertTrue(Current["handle"] == World.NextHandle)
		AssertEqual(World.NextGeneration, Current["generation"])
		AssertEqual(World.LiveEpoch, Current["epoch"])
		AssertEqual(KLPF_PrefetchPath("typing", World.LiveRoot), Current["destination"])
		AssertTrue(KLWV.windows["typing"] == World.LiveEntry)
		AssertEqual(1, World.Handles.Length, "a stale cache reset cannot launch another job from its old store")
		AssertEqual(1, World.NextHandle.Starts)
		AssertEqual(0, World.NextHandle.Terminations, "the predecessor cannot terminate its successor")
		AssertEqual(0, World.Terminals.Length, "the successor must remain live rather than receive a canceled terminal")
	} else if World.Mode == "current" {
		AssertTrue(Current is Map)
		AssertEqual(82, Current["epoch"])
		AssertEqual(KLPF_PrefetchPath("typing", World.OldRoot), Current["destination"])
		AssertEqual(1, World.Handles.Length)
		AssertEqual(1, World.Handles[1].Starts)
		AssertEqual(0, World.Handles[1].Terminations)
	} else {
		AssertTrue(A_IsSuspended, "the real purge sink must have paused the driver")
		AssertTrue(KLWV.windows["typing"] == World.Entry)
		AssertTrue(World.Entry["webview"] == World.View)
		AssertEqual(0, World.Handles.Length, "the admitted reset must not spawn while paused")
		AssertEqual(0, KLPFWorker.jobs.Count)
		AssertTrue(World.Entry.Has("pending_full_build_retry"),
			"a paused reset that already removed its caches must retain a resumable operation")
		Pending := World.Entry["pending_full_build_retry"]
		AssertTrue(Pending is Map)
		AssertEqual(82, Pending["epoch"])
		AssertEqual(0, Pending["attempt"], "pause must not consume the reset's retry budget")
		RetryOwner := Pending["owner"]
		AssertTrue(RetryOwner is Map)
		AssertTrue(World.Entry["full_build_retry_owner"] == RetryOwner)
		AssertEqual(0, RetryOwner["revision"])
		AssertEqual(0, RetryOwner["attempt"])
		AssertEqual(RetryOwner["revision"], World.Entry["full_build_retry_revision"])
		AssertFalse(World.Entry.Get("full_build_retry_exhausted", false))
	}
}

_MWCP_Case(Mode) {
	PreviousCritical := Critical("On")
	try _MWCP_OwnedCase(Mode)
	finally Critical(PreviousCritical)
}

_MWCP_OwnedCase(Mode) {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS, KLPF_LAST_JSON, KLPF_MANIFEST_CACHE
	static Serial := 0
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedReader := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Field in ["db", "readonly", "last_sizes", "ledger_snapshots", "pending_snapshots", "disposable", "saved_at"]
		SavedReader[Field] := KLRCache.%Field%
	Saved := {Windows: KLWV.windows, Jobs: KLPFWorker.jobs, Generation: KLPFWorker.generation,
		Spawn: KLPFWorker.spawn_fn, Suspended: A_IsSuspended, HadJson: IsSet(KLPF_LAST_JSON), HadManifest: IsSet(KLPF_MANIFEST_CACHE)}
	Saved.Json := Saved.HadJson ? KLPF_LAST_JSON : 0
	Saved.Manifest := Saved.HadManifest ? KLPF_MANIFEST_CACHE : 0
	Root := A_Temp . "\ergopti_metrics_cache_message_" . A_ScriptHwnd . "_" . ++Serial
	World := {Mode: Mode, OldRoot: Root . "\old", NextRoot: Root . "\next", Url: "https://ergopti.metrics/ui/index.html?cache=82",
		PurgeLogs: 0, SourceReads: 0, PayloadReads: 0, Replaced: false, Failure: 0, Handles: [], Terminals: [], NextJob: 0}
	World.Path := KLPF_PrefetchPath("typing", World.OldRoot)
	World.ForeignPath := KLPF_PrefetchPath("typing", World.NextRoot)
	World.View := {}, World.NextView := {}
	World.Entry := Map("epoch", 82, "webview", World.View, "navigation_url", World.Url,
		"metrics_dir", World.OldRoot, "full_build_done", true)
	World.NextEntry := Map("epoch", 83, "webview", World.NextView, "navigation_url", World.Url . "&next=83",
		"metrics_dir", World.NextRoot, "full_build_done", true)
	World.Manifest := Map("private-cache", true), World.ReaderSizes := Map("private-reader", 17)
	Args := _MWCP_Args(World), CreatedPaths := []
	Installed := false, Owned := false, Primary := 0, CleanupError := 0
	try {
		AssertFalse(A_IsSuspended, "the fixture cannot borrow a paused driver's scheduler")
		AssertFalse(KLPF_ReloadKeepsWorkersOut(), "the fixture cannot replace an active reload owner")
		FSCreateDirectoryExclusiveStrict(Root), Owned := true
		FSCreateDirectoryExclusiveStrict(World.OldRoot), FSCreateDirectoryExclusiveStrict(World.NextRoot)
		AssertTrue(FSWriteCreateDurable(World.Path, "old-disk"))
		CreatedPaths.Push(World.Path)
		AssertTrue(FSWriteCreateDurable(World.ForeignPath, "foreign-disk"))
		CreatedPaths.Push(World.ForeignPath)
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		LoggerSetTestSink(_MWCP_PurgeLog.Bind(World))
		KLRCache.db := 0, KLRCache.readonly := false, KLRCache.disposable := false, KLRCache.saved_at := ""
		KLRCache.last_sizes := World.ReaderSizes, KLRCache.ledger_snapshots := Map(), KLRCache.pending_snapshots := Map()
		KLPF_LAST_JSON := Map(World.Path, "old-memory", World.ForeignPath, "foreign-memory")
		KLPF_MANIFEST_CACHE := World.Manifest
		KLWV.windows := Map("typing", World.Entry)
		KLPFWorker.jobs := Map(), KLPFWorker.spawn_fn := _MWCP_Spawn.Bind(World), Installed := true
		if Mode == "paused"
			Suspend(true)
		KLWV_OnWebMessage("typing", 82, Mode == "wrong-sender" ? {} : World.View, Args)
		_MWCP_Check(World)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if Installed {
				KLWV.windows := Map()
				AssertTrue(KLPF_CancelAll(), "cleanup must retire every exact private job")
				AssertEqual(0, KLPFWorker.jobs.Count)
			}
			; Store sidecars are hashed files in A_Temp, outside the private
			; metrics-directory tree. Retire only confirmed fixture creations.
			for Path in CreatedPaths {
				if FSStrictExists(Path)
					AssertTrue(FSDelete(Path), "cleanup must remove its private store sidecar")
				AssertFalse(FSStrictExists(Path))
			}
		} catch as Failure {
			CleanupError := Failure
		} finally {
			Suspend(Saved.Suspended)
			KLWV.windows := Saved.Windows, KLPFWorker.jobs := Saved.Jobs
			KLPFWorker.generation := Saved.Generation, KLPFWorker.spawn_fn := Saved.Spawn
			KLPF_LAST_JSON := Saved.HadJson ? Saved.Json : unset
			KLPF_MANIFEST_CACHE := Saved.HadManifest ? Saved.Manifest : unset
			for Field, Value in SavedReader
				KLRCache.%Field% := Value
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Value in SavedExtra
				%Name% := Value
			for Handle in World.Handles
				Handle.start := 0, Handle.terminate := 0, Handle.Done := 0
			if World.NextJob is Map
				World.NextJob.Clear()
			World.Entry.Clear(), World.NextEntry.Clear(), World.Terminals.Length := 0
			Args.World := 0
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

for _MWCP_Mode in ["epoch-replace", "entry-replace", "view-replace", "purge-pause", "current", "wrong-sender", "wrong-source", "paused"]
	Test("Metrics cache reset owner: " . _MWCP_Mode . " preserves its live scheduler (metrics-clear-cache-message-owner)",
		_MWCP_Case.Bind(_MWCP_Mode))
