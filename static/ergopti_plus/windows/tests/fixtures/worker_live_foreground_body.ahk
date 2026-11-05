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

_KLWF_Main() {
	global _MAD_Root, _KLWF
	_KLWF_Require(A_Args.Length == 2 && _MAD_Root == _MAD_ExpectedRoot && (A_Args[2] == "parent-control" || A_Args[2] == "worker"),
		"The owned child requires its exact private root and known mode.")
	_KLWF_Require(!FSStrictExists(_MAD_Root), "The child may not adopt an existing private store.")
	_KLWF_Require(FSCreateDirectoryExclusiveStrict(_MAD_Root) == 1, "The private store must be acquired exclusively.")
	_MAD_CopyShared()
	TimingsLoadShared()
	KeystatsWalkerLoadTimings()
	ReceiverGui := Gui(, "Ergopti owned live foreground worker receiver")
	Receiver := ReceiverGui.AddEdit("w320 r3", "owned receiver")
	SnapshotPath := KLPF_PrefetchPath("apps", _MAD_Root)
	PublishedReceipt := 0
	try {
		ReceiverGui.Show()
		_KLWF_Require(WinGetPID("ahk_id " . ReceiverGui.Hwnd) == ProcessExist(),
			"Only this exact process may own the private focus receiver.")
		WinActivate("ahk_id " . ReceiverGui.Hwnd)
		_KLWF_Require(WinWaitActive("ahk_id " . ReceiverGui.Hwnd, , 2), "The owned native receiver must become active.")
		Receiver.Focus()
		Keystats.initialized := true
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
		if A_Args[2] == "worker" {
			_KLWF_Require(!FSStrictExists(SnapshotPath) && KLPFWorker.spawn_fn == 0,
				"The genuine worker must create a fresh snapshot without substituting process launch.")
			_KLWF_Require(KLPF_RequestBuild("apps", _MAD_Root, "full", 61, _KLWF_Completed),
				"The actual public worker scheduler must admit the independent process.")
			Started := A_TickCount
			while _KLWF.Calls == 0 && TickElapsed64(Started) < 15000 {
				_SR_TreePoll()
				Sleep(10)
			}
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
	} finally {
		_KLWF_Require(KLPF_CancelAll(), "Every actual worker must physically retire before its store or snapshot is deleted.")
		Keystats.initialized := false
		KLR_ResetCache()
		if PublishedReceipt is Map
			_KLWF_Require(FSDeleteVerified(SnapshotPath, _MAD_SameSnapshot.Bind(PublishedReceipt)),
				"Only the exact successful native snapshot may retire.")
		ReceiverGui.Destroy()
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
