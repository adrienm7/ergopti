; tests/fixtures/worker_live_foreground_body.ahk
; Real owned native focus, context producer and detached projection worker.
#Requires AutoHotkey v2.0

global _MAD := {AssetHashes: Map()}
global _KLWF := {Calls: 0, Status: "", Worker: false}
OnError(_MAD_InitializationError)
if KLPF_IsWorkerInvocation() {
	_KLWF_Flag := KLPF_WorkerFlagIndex()
	_KLWF_Require(A_Args.Length >= _KLWF_Flag + 11 && _MAD_Root == _MAD_ExpectedRoot
		&& A_Args[_KLWF_Flag + 1] == "apps" && A_Args[_KLWF_Flag + 3] == "full"
		&& A_Args[_KLWF_Flag + 5] == _MAD_Root . "\config\",
		"Only the exact private apps/full worker ABI is admitted.")
	_KLWF.Worker := true
	OnExit(_KLWF_WorkerReceipt)
	KLPF_WorkerMain()
	throw Error("The actual worker unexpectedly returned.")
}

_KLWF_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_KLWF_WorkerReceipt(Reason, Code) {
	global _MAD_Root
	Receipt := Map("pid", ProcessExist(), "code", Code, "origin", KLHook.app_entered_at,
		"app", KLHook.prev_app, "script_sha256", _MVSP_Hash(A_ScriptFullPath))
	_KLWF_Require(FSWriteCreateDurable(_MAD_Root . "\worker-receipt.json", KL_JsonEncode(Receipt)),
		"The exact real worker exit must publish its independent receipt.")
}

_KLWF_Completed(Status, *) {
	global _KLWF
	_KLWF.Calls += 1
	_KLWF.Status := Status
}


_KLWF_CompanionDone(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}
_KLWF_StartCompanion() {
	global _MAD_Root, _KLWF
	Exe := _MAD_Root . "\owned_foreground_b.exe", Script := _MAD_Root . "\foreground_b.ahk"
	Gate := _MAD_Root . "\foreground_b.release"
	FileCopy(A_AhkPath, Exe, false)
	_KLWF_Require(_MVSP_Hash(Exe) == _MVSP_Hash(A_AhkPath), "The distinct native process image must be the exact private runtime copy.")
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n"
		. 'Window := Gui(, "Ergopti owned foreground B")`nWindow.AddEdit("w240 r2", "Owned receiver B")`n'
		. 'Window.Show("NoActivate")`nStarted := A_TickCount`n'
		. 'while !FileExist(A_Args[1]) && A_TickCount - Started < 15000`n Sleep(10)`nExitApp(0)`n'
	_KLWF_Require(FSWriteCreateDurable(Script, Source), "The private receiver script must be created exclusively.")
	State := {Calls: 0, Code: -1, Output: "", ErrorText: "", Gate: Gate, Hwnd: 0, Pid: 0, Handle: 0}
	_KLWF.Companion := State
	State.Handle := ShellRunner_SpawnTreeOwned(Exe, ["/ErrorStdOut=UTF-8", Script, Gate], _KLWF_CompanionDone.Bind(State))
	_KLWF_Require(State.Handle.start(), "The exact real companion process must start.")
	State.Pid := State.Handle.processId()
	State.Hwnd := WinWait("Ergopti owned foreground B ahk_pid " . State.Pid, , 3)
	_KLWF_Require(State.Pid > 0 && State.Hwnd && WinGetPID("ahk_id " . State.Hwnd) == State.Pid
		&& WinGetProcessName("ahk_id " . State.Hwnd) == "owned_foreground_b.exe",
		"The actual distinct image must own the exact gated native receiver.")
	return State
}
_KLWF_RetireCompanion(State) {
	if !IsObject(State) || !IsObject(State.Handle)
		return true
	if !FileExist(State.Gate)
		_KLWF_Require(FSWriteCreateDurable(State.Gate, "release"), "Only the privately owned companion gate is opened.")
	Started := A_TickCount
	while !State.Calls && TickElapsed64(Started) < 3000 {
		_SR_TreePoll()
		Sleep(10)
	}
	Receipt := State.Handle.terminate()
	Retired := Receipt is Integer && Receipt == 1 && State.Calls == 1
		&& State.Code == 0 && State.ErrorText == ""
	if Retired
		State.Handle := 0
	return Retired
}

; The only orchestration port still delegates the actual process owner. A real
; context switch and genuine SQL ingest happen before that actual worker starts.
_KLWF_RaceSpawn(Executable, Arguments, Done) {
	global _KLWF, _KLWF_Receiver
	Job := KLPFWorker.jobs.Get("apps", 0)
	_KLWF_Require(Job is Map && IsObject(Job.Get("foreground", 0)),
		"The race must occur after a genuine admitted foreground snapshot.")
	Handle := ShellRunner_SpawnTreeOwned(Executable, Arguments, Done)
	Origin := KLHook.app_entered_at
	if _KLWF.Race == "switch" {
		WinActivate("ahk_id " . _KLWF.Companion.Hwnd)
		_KLWF_Require(WinWaitActive("ahk_id " . _KLWF.Companion.Hwnd, , 2), "The owned distinct process must become the real foreground.")
		_KLWF_Require(MF_RefreshFocus(true), "The native OS acquisition must publish real receiver B.")
		B := MF_GetFocusSnapshot()
		_KLWF_Require(B.valid && B.hwnd == _KLWF.Companion.Hwnd && B.process_name == "owned_foreground_b.exe"
			&& KL_Hook_RefreshContext(true) && KLHook.prev_app == B.process_name,
			"The genuine context owner must acknowledge the actual app switch A to B.")
	} else {
		App := KLHook.prev_app, Title := KLHook.prev_title
		Row := Map("type", "typing", "text", "x", "app", App, "title", Title,
			"app_category", "neutral", "wpm", 120, "events", [["x", 1, Map("kc", 88, "sk", 45)]])
		_KLWF_Require(KL_AppendLog(Row), "The real central writer must admit the independent typing row.")
	}
	Before := Keystats.today_log_offset
	Outcome := KL_IngestOnce(true)
	_KLWF_Require(Outcome is Map && Outcome.Get("ok", false) && Keystats.today_log_offset > Before,
		"The real journal/SQL/state transaction must acknowledge and advance its original ingest offset.")
	if _KLWF.Race == "switch" {
		Reader := FSOpenStrict(Keystats.data_sql_path, "r", "UTF-8")
		try Sql := Reader.Read()
		finally Reader.Close()
		_KLWF_Require(InStr(Sql, "INSERT OR IGNORE INTO events_app_switch", true),
			"The actual closing app interval must exist in the durable authoritative SQL before the worker reads it.")
		WinActivate("ahk_id " . _KLWF_Receiver.Hwnd)
		_KLWF_Require(WinWaitActive("ahk_id " . _KLWF_Receiver.Hwnd, , 2) && MF_RefreshFocus(true)
			&& KL_Hook_RefreshContext(true), "The actual canonical foreground must return to receiver A.")
		_KLWF_Require(KLHook.prev_app == Job["foreground"].Wire["app"] && KLHook.app_entered_at != Origin,
			"The same app name must not borrow its preceding interval's origin after a real round trip.")
	} else
		_KLWF_Require(KLHook.app_entered_at == Origin, "An actual typing ingest must preserve the open foreground origin.")
	_KLWF.RaceDone := true
	return Handle
}

_KLWF_Main() {
	global _MAD_Root, _KLWF, _KLWF_Receiver
	_KLWF_Require(A_Args.Length == 2 && _MAD_Root == _MAD_ExpectedRoot && (A_Args[2] == "parent-control" || A_Args[2] == "worker"
		|| A_Args[2] == "worker-switch-ingest" || A_Args[2] == "worker-typing-ingest"),
		"The owned child requires its exact private root and known mode.")
	_KLWF_Require(!FSStrictExists(_MAD_Root), "The child may not adopt an existing private store.")
	_KLWF_Require(FSCreateDirectoryExclusiveStrict(_MAD_Root) == 1, "The private store must be acquired exclusively.")
	_MAD_CopyShared()
	TimingsLoadShared()
	KeystatsWalkerLoadTimings()
	ReceiverGui := Gui(, "Ergopti owned live foreground worker receiver")
	Receiver := ReceiverGui.AddEdit("w320 r3", "owned receiver")
	_KLWF_Receiver := ReceiverGui
	_KLWF.Companion := 0
	SnapshotPath := "", InitAttempted := false
	PublishedReceipt := 0
	try {
		; The shared staging helper created this exact empty synthetic-device
		; child. Real discovery must not adopt a directory without device.json.
		DirDelete(_MAD_Root . "\by_device\owned")
		_KLWF_Require(FSCreateDirectoryExclusiveStrict(_MAD_Root . "\private-temp") == 1,
			"The actual initializer's temporary files must stay in the private owned subtree.")
		EnvSet("TMP", _MAD_Root . "\private-temp")
		EnvSet("TEMP", _MAD_Root . "\private-temp")
		_KLWF_Require(!Keystats.initialized, "The native baseline must call real cold initialization, not borrow initialized RAM.")
		InitAttempted := true
		_KLWF_Require(KL_Init(_MAD_Root), "The real device, journal and state initialization must succeed for this exact store.")
		_KLWF_Require(ConfigTransitionNormalizeConfigDir(Keystats.metrics_dir) == ConfigTransitionNormalizeConfigDir(_MAD_Root)
			&& Keystats.data_sql_path == Keystats.by_device_dir . "data.sql"
			&& Keystats.by_device_dir == Keystats.metrics_dir . "by_device\" . Keystats.device_id . "\",
			"The actual canonical initializer must bind the foreground source to the store passed to the worker.")
		_KLWF_Require(KL_TimerGroupStop(Keystats, ["_initial_ingest_timer", "_ingest_timer", "_midnight_timer"], SetTimer, "core"),
			"The three actual initializer-owned core timers must retire before the controlled foreground observation.")
		KL_Mig_Cancel()
		_KLWF_Require(!KL_Mig_IsActive() && !KLMigration.syncPending,
			"The actual initializer-owned deferred migration must be cancelled before projection.")
		_KLWF_Require(FSCreateDirectoryExclusiveStrict(_MAD_Root . "\by_device\owned") == 1,
			"The separate independently authored source device must be recreated exclusively.")
		SnapshotPath := KLPF_PrefetchPath("apps", _MAD_Root)
		FileAppend("OBS live-worker-init actual_init=1 store_match=1 device_path_match=1 core_timers_retired=1 migration_retired=1`n", "*", "UTF-8-RAW")
		ReceiverGui.Show()
		_KLWF_Require(WinGetPID("ahk_id " . ReceiverGui.Hwnd) == ProcessExist(),
			"Only this exact process may own the private focus receiver.")
		WinActivate("ahk_id " . ReceiverGui.Hwnd)
		_KLWF_Require(WinWaitActive("ahk_id " . ReceiverGui.Hwnd, , 2), "The owned native receiver must become active.")
		Receiver.Focus()
		_KLWF_Require(Keystats.initialized, "The admitted real initialization must still own the context producer.")
		MetricsFilters.secure_field := false
		_KLWF_Require(MF_RefreshFocus(true), "The real bounded OS focus acquisition must publish successfully.")
		Focus := MF_GetFocusSnapshot()
		_KLWF_Require(Focus.valid && Focus.hwnd == ReceiverGui.Hwnd
			&& Focus.process_name == WinGetProcessName("ahk_id " . ReceiverGui.Hwnd),
			"The actual canonical focus must belong to this native child.")
		_KLWF_Require(KL_Hook_RefreshContext(true), "The genuine context producer must establish the native foreground origin.")
		Origin := KLHook.app_entered_at
		_KLWF_Require(Origin > 0 && KLHook.prev_app == Focus.process_name,
			"The context origin and identity must come from the actual publisher.")
		_MAD_SeedLedger(Focus.process_name)
		Sleep(50)
		Db := KLR_BuildDatabase(_MAD_Root)
		_KLWF_Require(Db != 0, "The actual canonical ledger must rebuild.")
		Day := FormatTime(A_Now, "yyyy-MM-dd")
		Parent := JsonParse(KLR_BuildManifestJson(Db, Day, Day))[Day][Focus.process_name]["app_time_ms"]
		Raw := SQLite_Query(Db, "SELECT COALESCE(SUM(app_time_ms),0) AS ms FROM agg_app_day;")[1]["ms"]
		FileAppend("OBS live-worker parent_ms=" . Parent . " raw_ms=" . Raw . " origin=" . Origin . "`n", "*", "UTF-8-RAW")
		_KLWF_Require(Parent >= 40 && Raw == 0, "The genuine in-process overlay must be positive before any closing interval exists.")
		_KLWF_Require(Keystats._pending_entries.Length == 0 && KLHook.app_entered_at == Origin,
			"The public producer must leave the actual foreground interval open and unpersisted.")
		KLR_ResetCache()
		if A_Args[2] != "parent-control" {
			_KLWF_Require(!FSStrictExists(SnapshotPath) && KLPFWorker.spawn_fn == 0,
				"The genuine worker must create a fresh snapshot without substituting process launch.")
			Race := A_Args[2] != "worker"
			if Race {
				_KLWF.Race := A_Args[2] == "worker-switch-ingest" ? "switch" : "typing"
				_KLWF.RaceDone := false
				if _KLWF.Race == "switch"
					_KLWF.Companion := _KLWF_StartCompanion()
				KLPFWorker.spawn_fn := _KLWF_RaceSpawn
			}
			_KLWF_Require(KLPF_RequestBuild("apps", _MAD_Root, "full", 61, _KLWF_Completed),
				"The actual public worker scheduler must admit the independent process.")
			Started := A_TickCount
			while _KLWF.Calls == 0 && TickElapsed64(Started) < 15000 {
				_SR_TreePoll()
				Sleep(10)
			}
			if Race {
				Rejected := _KLWF.Race == "switch"
				ExpectedStatus := Rejected ? "canceled" : "ok"
				_KLWF_Require(_KLWF.RaceDone && _KLWF.Calls == 1 && _KLWF.Status == ExpectedStatus
					&& !KLPFWorker.jobs.Has("apps"), "Only a revoked foreground interval may cancel the genuine worker result.")
				Receipt := JsonParse(FSReadStrict(_MAD_Root . "\worker-receipt.json"))
				_KLWF_Require(Receipt["pid"] != ProcessExist() && Receipt["code"] == 0
					&& Receipt["script_sha256"] == _MVSP_Hash(A_ScriptFullPath),
					"Both races must still execute and retire the actual independent worker successfully.")
				if Rejected
					_KLWF_Require(!FSStrictExists(SnapshotPath), "A genuinely closed and already-ingested origin cannot publish its old live overlay.")
				else {
					PublishedReceipt := _MAD_FileSnapshot(SnapshotPath)
					Worker := JsonParse(FSReadStrict(SnapshotPath))["metrics_manifest"][Day][Focus.process_name]["app_time_ms"]
					_KLWF_Require(Worker >= 40 && KLHook.app_entered_at == Origin,
						"An actual typing ingest must retain both publication and the unchanged open foreground interval.")
				}
				FileAppend("OBS live-worker race=" . _KLWF.Race . " actual_worker=1 status=" . _KLWF.Status . "`n", "*", "UTF-8-RAW")
			} else {
				_KLWF_Require(_KLWF.Calls == 1 && _KLWF.Status == "ok" && !KLPFWorker.jobs.Has("apps"),
					"The real worker must successfully finish and publish exactly once.")
				PublishedReceipt := _MAD_FileSnapshot(SnapshotPath)
				Receipt := JsonParse(FSReadStrict(_MAD_Root . "\worker-receipt.json"))
				_KLWF_Require(Receipt["pid"] != ProcessExist() && Receipt["code"] == 0
					&& Receipt["script_sha256"] == _MVSP_Hash(A_ScriptFullPath),
					"A distinct process must execute this actual worker source.")
				Worker := JsonParse(FSReadStrict(SnapshotPath))["metrics_manifest"][Day][Focus.process_name]["app_time_ms"]
				FileAppend("OBS live-worker worker_ms=" . Worker . " parent_ms=" . Parent
					. " worker_origin=" . Receipt["origin"] . " worker_app=" . Receipt["app"] . "`n", "*", "UTF-8-RAW")
				_KLWF_Require(KLHook.app_entered_at == Origin && KLHook.prev_app == Focus.process_name,
					"No context switch or stop may replace the foreground interval while the worker runs.")
				_KLWF_Require(Worker >= 40, "The actual detached snapshot must retain the ongoing foreground interval visible in the parent.")
			}
		}
	} finally {
		_KLWF_Require(KLPF_CancelAll(), "Every actual worker must physically retire before its store or snapshot is deleted.")
		_KLWF_Require(_KLWF_RetireCompanion(_KLWF.Companion), "The exact privately owned native companion must physically retire.")
		KLPFWorker.spawn_fn := 0
		if InitAttempted {
			_KLWF_Require(KL_TimerGroupStop(Keystats, ["_initial_ingest_timer", "_ingest_timer", "_midnight_timer"], SetTimer, "core"),
				"Every exact initializer core callback must retire before child cleanup.")
			KL_Mig_Cancel()
			_KLWF_Require(KL_CloseTodayFh(), "The actual initialized journal handle must retire before process cleanup.")
		}
		Keystats.initialized := false
		KLR_ResetCache()
		if PublishedReceipt is Map
			_KLWF_Require(FSDeleteVerified(SnapshotPath, _MAD_SameSnapshot.Bind(PublishedReceipt)),
				"Only the exact successful native snapshot may retire.")
		ReceiverGui.Destroy()
		_KLWF_Receiver := 0
	}
	FileAppend("PASS live-worker-foreground " . A_Args[2] . "`n", "*", "UTF-8-RAW")
}

try {
	_KLWF_Main()
	ExitApp(0)
} catch as KLWFEntryFailure {
	FileAppend("FAIL live-worker-foreground " . KLWFEntryFailure.Message
		. " line=" . KLWFEntryFailure.Line . "`n" . KLWFEntryFailure.Stack . "`n", "**", "UTF-8-RAW")
	ExitApp(1)
}
