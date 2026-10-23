; tests/unit/modules/keylogger/metrics/test_metrics_message_owner.ahk

; ==============================================================================
; MODULE: Metrics Bridge Message Owner Tests
; DESCRIPTION:
; Payload, Source and logger callouts replace a dashboard while its real worker
; remains admitted. Only process launch is passive; RequestBuild/CancelBuild,
; handler dispatch, diagnostic emission and paused range-file retirement are real.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MWMO_View {
	__New() {
		this.Messages := []
	}
	PostWebMessageAsString(Message) {
		this.Messages.Push(Message)
	}
}

class _MWMO_Args {
	__New(World) {
		this.World := World
	}
	Source {
		get {
			World := this.World
			World.SourceReads += 1
			if World.Mode == "source-replace"
				_MWMO_Replace(World)
			return World.Mode == "wrong-source" ? "https://foreign.invalid/" : World.Url
		}
	}
	TryGetWebMessageAsString() {
		World := this.World
		World.PayloadReads += 1
		if World.Mode == "payload-replace" || World.Mode == "same-epoch-entry" || World.Mode == "same-entry-view"
			_MWMO_Replace(World)
		return World.Message
	}
}

_MWMO_Start(Handle, *) {
	Handle.Starts += 1
	return true
}

_MWMO_Terminate(Handle, *) {
	Handle.Terminations += 1
	return true
}

_MWMO_Spawn(World, Exe, Args, Done) {
	FlagIndex := 0
	for Index, Arg in Args
		if Arg == "--keylogger-prefetch-worker"
			FlagIndex := Index
	AssertTrue(FlagIndex > 0, "the actual scheduler must launch its canonical worker mode")
	AssertEqual(World.Which, Args[FlagIndex + 1])
	AssertEqual("full", Args[FlagIndex + 3])
	AssertTrue(KLPFWorker.jobs.Has(World.Which), "the actual scheduler reserves its slot before external process launch")
	Handle := {Starts: 0, Terminations: 0, Root: Args[FlagIndex + 2], Done: Done}
	Handle.start := _MWMO_Start.Bind(Handle)
	Handle.terminate := _MWMO_Terminate.Bind(Handle)
	World.Handles.Push(Handle)
	return Handle
}

_MWMO_Terminal(World, Status, Stage := "") {
	World.Terminals.Push([Status, Stage])
}

_MWMO_Replace(World) {
	if World.Replaced
		return
	World.Replaced := true
	if World.Mode == "same-entry-view" {
		World.Entry["webview"] := World.NextView
		World.LiveEntry := World.Entry
		World.LiveEpoch := 82
		World.LiveRoot := World.OldRoot
	} else {
		World.LiveEpoch := World.Mode == "same-epoch-entry" ? 82 : 83
		World.LiveEntry := World.NextEntry
		World.LiveEntry["epoch"] := World.LiveEpoch
		if World.Mode == "same-epoch-entry" {
			World.LiveEntry["webview"] := World.View
			World.LiveEntry["navigation_url"] := World.Url
		}
		KLWV.windows[World.Which] := World.LiveEntry
		World.LiveRoot := World.NextRoot
	}
	AssertTrue(KLPF_RequestBuild(World.Which, World.LiveRoot, "full", World.LiveEpoch,
		_MWMO_Terminal.Bind(World)), "the successor must own a real admitted job before the old handler resumes")
	World.NextJob := KLPFWorker.jobs[World.Which]
	World.NextHandle := World.NextJob["handle"]
	World.NextGeneration := World.NextJob["generation"]
}

_MWMO_Log(World, Line) {
	if !InStr(Line, "KLWV_OnWebMessage: dashboard=", true)
		return
	World.BridgeLogs += 1
	if World.Mode != "logger-replace"
		return
	try _MWMO_Replace(World)
	catch as Failure {
		; The real logger contains sink exceptions. Keep the failure explicit so
		; a missing prerequisite cannot masquerade as successful retirement.
		World.Failure := Failure
	}
}

_MWMO_Check(World) {
	Current := KLPFWorker.jobs.Get(World.Which, 0)
	Terminations := 0
	for Handle in World.Handles
		Terminations += Handle.Terminations
	_TestPrint("# metrics-message-owner mode=" . World.Mode . " source_reads=" . World.SourceReads
		. " payload_reads=" . World.PayloadReads . " bridge_logs=" . World.BridgeLogs
		. " spawns=" . World.Handles.Length . " terminations=" . Terminations
		. " retained_job=" . (IsObject(World.NextJob) && Current == World.NextJob))
	if IsObject(World.Failure)
		throw World.Failure
	if World.Replaced {
		AssertTrue(Current == World.NextJob, "the resumed predecessor must retain the exact successor job")
		AssertEqual(World.NextGeneration, Current["generation"])
		AssertEqual(World.LiveEpoch, Current["epoch"])
		AssertEqual(KLPF_PrefetchPath(World.Which, World.LiveRoot), Current["destination"])
		AssertEqual(1, World.Handles.Length, "a stale message cannot spawn a second projection from its old root")
		AssertEqual(1, World.NextHandle.Starts)
		AssertEqual(0, World.NextHandle.Terminations, "the old handler cannot terminate its successor's real scheduler owner")
		AssertEqual(0, World.Terminals.Length)
		AssertTrue(KLWV.windows[World.Which] == World.LiveEntry)
		if World.Mode == "source-replace"
			AssertEqual(0, World.PayloadReads, "Source reentry must revoke the handler before its payload is read")
	} else if World.Mode == "current-refresh" {
		AssertEqual(1, World.Handles.Length, "a current page must still reach the actual scheduler")
		AssertEqual(1, World.Handles[1].Starts)
		AssertEqual(0, World.Handles[1].Terminations)
		AssertTrue(Current is Map)
		AssertEqual(82, Current["epoch"])
		AssertEqual(KLPF_PrefetchPath(World.Which, World.OldRoot), Current["destination"])
	} else {
		AssertEqual(0, World.Handles.Length, "rejected or paused messages cannot launch a projection")
		AssertEqual(0, KLPFWorker.jobs.Count)
		if World.Mode == "paused-range" {
			AssertTrue(World.Entry.Has("pending_range_terminal"), "pause must preserve the canceled range acknowledgement")
			Pending := World.Entry["pending_range_terminal"]
			AssertEqual(37, Pending["request_id"])
			AssertEqual("canceled", Pending["status"])
		} else if World.Mode == "paused-consumed" {
			AssertFalse(World.Entry.Has("range_stage"), "pause must still retire an acknowledged private stage")
			AssertFalse(FSStrictExists(World.Stage), "the actual owned range file must be removed")
		}
	}
	if World.Mode == "wrong-sender" || World.Mode == "wrong-epoch" {
		AssertEqual(0, World.SourceReads)
		AssertEqual(0, World.PayloadReads)
	} else if World.Mode == "wrong-source" {
		AssertEqual(1, World.SourceReads)
		AssertEqual(0, World.PayloadReads)
	}
}

_MWMO_Case(Mode) {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	static Serial := 0
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	Saved := {Windows: KLWV.windows, Jobs: KLPFWorker.jobs,
		Generation: KLPFWorker.generation, Spawn: KLPFWorker.spawn_fn, Suspended: A_IsSuspended}
	Root := A_Temp . "\ergopti_metrics_message_" . A_ScriptHwnd . "_" . ++Serial
	World := {Mode: Mode, Which: InStr(Mode, "paused-range") || Mode == "paused-consumed" ? "typing" : "apps",
		OldRoot: Root . "\old", NextRoot: Root . "\next", SourceReads: 0, PayloadReads: 0,
		BridgeLogs: 0, Replaced: false, Failure: 0, Handles: [], Terminals: [], NextJob: 0,
		Url: "https://ergopti.metrics/ui/index.html?owner=82", Stage: Root . "\owned-range.json"}
	World.View := _MWMO_View(), World.NextView := _MWMO_View()
	World.Entry := Map("epoch", 82, "webview", World.View, "navigation_url", World.Url, "metrics_dir", World.OldRoot)
	World.NextEntry := Map("epoch", 83, "webview", World.NextView,
		"navigation_url", World.Url . "&next=83", "metrics_dir", World.NextRoot)
	World.Message := Mode == "paused-range"
		? '{"action":"range","request_id":37,"start_date":"2026-10-01","end_date":"2026-10-02","apps":[]}'
		: (Mode == "paused-consumed" ? '{"action":"range_consumed","token":"owned-message-stage"}'
		: '{"action":"request_refresh"}')
	Args := _MWMO_Args(World), Owned := false, Installed := false, Primary := 0, CleanupError := 0
	try {
		AssertFalse(A_IsSuspended, "the fixture cannot borrow a paused driver's scheduler")
		AssertFalse(KLPF_ReloadKeepsWorkersOut(), "the fixture cannot replace an active reload owner")
		FSCreateDirectoryExclusiveStrict(Root), Owned := true
		FSCreateDirectoryExclusiveStrict(World.OldRoot), FSCreateDirectoryExclusiveStrict(World.NextRoot)
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		LoggerSetTestSink(_MWMO_Log.Bind(World))
		KLWV.windows := Map(World.Which, World.Entry)
		KLPFWorker.jobs := Map(), KLPFWorker.spawn_fn := _MWMO_Spawn.Bind(World), Installed := true
		if Mode == "paused-consumed" {
			AssertTrue(FSWriteCreateDurable(World.Stage, "{}"))
			World.Entry["range_stage"] := Map("stage", World.Stage, "token", "owned-message-stage", "mounted", false)
		}
		if InStr(Mode, "paused-") == 1
			Suspend(true)
		Sender := Mode == "wrong-sender" ? {} : World.View
		Epoch := Mode == "wrong-epoch" ? 81 : 82
		KLWV_OnWebMessage(World.Which, Epoch, Sender, Args)
		_MWMO_Check(World)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if Installed {
				KLWV.windows := Map()
				AssertTrue(KLPF_CancelAll(), "cleanup must settle every private scheduler owner")
			}
			if Owned && FSStrictExists(World.Stage)
				AssertTrue(FSDelete(World.Stage))
		} catch as Failure {
			CleanupError := Failure
		} finally {
			Suspend(Saved.Suspended)
			KLWV.windows := Saved.Windows, KLPFWorker.jobs := Saved.Jobs
			KLPFWorker.generation := Saved.Generation, KLPFWorker.spawn_fn := Saved.Spawn
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Value in SavedExtra
				%Name% := Value
			for Handle in World.Handles
				Handle.start := 0, Handle.terminate := 0, Handle.Done := 0
			if World.NextJob is Map
				World.NextJob.Clear()
			World.Entry.Clear(), World.NextEntry.Clear(), World.Terminals.Length := 0
			Args.World := 0
			Critical(PreviousCritical)
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

for _MWMO_Mode in ["source-replace", "payload-replace", "logger-replace", "same-epoch-entry", "same-entry-view",
	"current-refresh", "wrong-sender", "wrong-epoch", "wrong-source", "paused-refresh", "paused-range", "paused-consumed"]
	Test("Metrics message owner: " . _MWMO_Mode . " retains its admitted worker (metrics-message-callout-owner)",
		_MWMO_Case.Bind(_MWMO_Mode))
