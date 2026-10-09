; tests/unit/test_metrics_native_worker_exit.ahk

; ==============================================================================
; MODULE: Metrics Native Worker Exit Tests
; DESCRIPTION: Abrupt worker exit must preserve published snapshots and permit retry.
; ==============================================================================

#Requires AutoHotkey v2.0

_MNWE_AbruptExit(Which) {
	global KLPF_LAST_JSON
	Saved := [KLPFWorker.jobs, KLPFWorker.spawn_fn, KLPFWorker.generation, KLPFWorker.publish_fn]
	HadJson := IsSet(KLPF_LAST_JSON)
	SavedJson := HadJson ? KLPF_LAST_JSON : 0
	_KLRDC_Reset()
	Root := _KLRDC_Root()
	Script := Root . "abrupt_worker.ahk"
	Path := KLPF_PrefetchPath(Which, Root)
	Handles := []
	Stages := []
	Receipts := []
	Terminals := []
	OldJson := '{"revision":"last-good"}'
	NewJson := '{"revision":"recovered"}'
	Attempt := 0
	Created := false
	Spawn(Executable, Args, Done) {
		Attempt += 1
		Stage := KLPFWorker.jobs[Which]["stage"]
		Stages.Push(Stage)
		NativeDone(Code, Out, Err) {
			Receipts.Push([Code, FileRead(Stage, "UTF-8")])
			Done.Call(Code, Out, Err)
		}
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut", Script, Stage, Attempt = 1 ? '{"partial":' : NewJson,
				Attempt = 1 ? "abrupt" : "normal"], NativeDone)
		Handles.Push(Handle)
		return Handle
	}
	try {
		AssertFalse(FSExists(Path), "the fixture must not replace a foreign snapshot")
		Created := FSWriteCreateDurable(Path, OldJson) != 0
		AssertTrue(Created)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . "#Requires AutoHotkey v2.0`n"
			. 'OnError((*) => ExitApp(91))' . "`n"
			. 'FileAppend(A_Args[2], A_Args[1], "UTF-8-RAW")' . "`n"
			. 'if A_Args[3] = "abrupt"' . "`n"
			. '`tDllCall("TerminateProcess", "Ptr", -1, "UInt", 23, "Int")' . "`n"
			. 'ExitApp(0)' . "`n") != 0)
		KLPFWorker.jobs := Map()
		KLPFWorker.spawn_fn := Spawn
		KLPFWorker.publish_fn := 0
		KLPF_LAST_JSON := Map(Path, OldJson)
		loop 2 {
			Expected := A_Index
			AssertTrue(KLPF_RequestBuild(Which, Root, "full", 91, (Status, *) => Terminals.Push(Status)))
			Started := A_TickCount
			while Terminals.Length < Expected && TickElapsed(Started) < 5000 {
				_SR_TreePoll()
				Sleep(10)
			}
			AssertEqual(Expected, Terminals.Length, "the real process completion must deliver exactly once")
			AssertEqual(Expected, Receipts.Length)
			AssertEqual(Expected = 1 ? 23 : 0, Receipts[Expected][1])
			AssertEqual(Expected = 1 ? '{"partial":' : NewJson, Receipts[Expected][2],
				"the native worker must actually write its stage before completion reaches publication")
			AssertEqual(Expected = 1 ? "failed" : "ok", Terminals[Expected])
			AssertFalse(KLPFWorker.jobs.Has(Which), "a dead worker must release the scheduler slot")
			AssertFalse(FSExists(Stages[Expected]))
			AssertEqual(Expected = 1 ? OldJson : NewJson, FileRead(Path, "UTF-8"))
			if Expected = 1
				AssertEqual(OldJson, KLPF_LAST_JSON[Path], "abrupt exit must retain the last-good RAM snapshot")
			else
				AssertFalse(KLPF_LAST_JSON.Has(Path), "successful retry must invalidate the older RAM snapshot")
		}
	} finally {
		for Handle in Handles
			AssertTrue(Handle.terminate(), "the fixture must confirm teardown before deleting native worker files")
		KLPFWorker.jobs := Saved[1]
		KLPFWorker.spawn_fn := Saved[2]
		KLPFWorker.generation := Saved[3]
		KLPFWorker.publish_fn := Saved[4]
		KLPF_LAST_JSON := HadJson ? SavedJson : unset
		for Stage in Stages
			if FSExists(Stage)
				AssertTrue(FSDelete(Stage))
		if Created
			AssertTrue(FSDelete(Path))
		_KLRDC_Cleanup()
	}
}
for Which in ["typing", "apps"]
	Test("Metrics native worker: abrupt " . Which . " exit preserves publication (metrics-native-worker-exit)",
		_KLRDC_CheckTeardown.Bind(_MNWE_AbruptExit.Bind(Which)))
