; tests/unit/adapters/crash_report/test_screenshot_stage_cleanup.ahk

#Requires AutoHotkey v2.0

; Real shared-worker completion publishes a real file while a native reader
; refuses DELETE sharing on its stage. No capture process or input is injected.
_GSSC_Start(WorkerId, *) {
	GestureScreenshotWorkerDone(WorkerId, 0, "", "")
	return false
}

_GSSC_Replace(Record, Ok, Reason := "") {
	_GSWO_RecordTerminal(Ok, Reason)
	FileMove(Record["stage"], Record["retired"])
	_GSFP_Write(Record["stage"], Record["bytes"])
	Record["foreign"] := _GSFP_Snapshot(Record["stage"])
}

_GSSC_AssertForeign(Original, Foreign, Stage, Retired) {
	AssertTrue(Original["volume"] != Foreign["volume"]
		|| Original["index_high"] != Foreign["index_high"]
		|| Original["index_low"] != Foreign["index_low"],
		"an independently created same-byte file must have a distinct native identity")
	AssertTrue(FileExist(Stage) != "", "cleanup must preserve the same-byte foreign replacement")
	Observed := _GSFP_Snapshot(Stage)
	for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
		AssertEqual(Foreign[Key], Observed[Key], "the foreign identity must survive cleanup")
	AssertTrue(FSSameBytes(Stage, Retired), "equal bytes cannot authorize deleting a different native file")
}

_GSSC_Run(Owner, Mode) {
	global DriverPid, _GestureDirectCaptures, _GestureRegionCapture, _GSWO_Terminals
	PreviousCritical := Critical("On"), WasSuspended := A_IsSuspended
	Old := _GSWO_Install()
	Root := A_Temp . "\ergopti_stage_cleanup_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Blocker := 0, WorkerId := 0, Job := 0, Primary := 0
	try {
		AssertEqual(0, Old["jobs"].Count, "the native fixture cannot borrow a pre-existing worker or cleanup debt")
		if A_IsSuspended
			Suspend(false)
		Created := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(Created)
		Stage := Root . "\stage.png", Destination := Root . "\published.png", Retired := Root . "\retired.png"
		Bytes := Buffer(131089, 0xA7)
		NumPut("UInt", 0, Bytes, 65535)
		_GSFP_Write(Stage, Bytes)
		Witness := Root . "\expected.bin"
		_GSFP_Write(Witness, Bytes)
		OriginalSnapshot := _GSFP_Snapshot(Stage)
		GestureScreenshotWorkerState.file_exists_fn := 0
		GestureScreenshotWorkerState.publish_file_fn := 0
		GestureScreenshotWorkerState.cleanup_stage_fn := 0
		GestureScreenshotWorkerState.rollback_file_fn := 0
		Completion := Owner == "direct" ? GestureDirectCaptureWorkerDone.Bind(1) : GestureRegionSaveWorkerDone.Bind(1)
		WorkerId := _GestureScreenshotCreateWorker(Owner . "_save", 1, Stage, [], Completion)
		AssertTrue(WorkerId > 0, "the real shared registry must admit the exact completed worker")
		Job := GestureScreenshotWorkerState.jobs[WorkerId]
		if Owner == "direct" {
			_GestureDirectCaptures[1] := Map("worker_id", WorkerId, "mode", "save", "path", Destination,
				"started_tick", A_TickCount, "timeout_ms", 60000, "callback", _GSWO_RecordTerminal)
		} else {
			_GSWO_SeedRegion(1)
			_GestureRegionCapture["worker_id"] := WorkerId
			_GestureRegionCapture["path"] := Destination
			_GestureRegionCapture["save_started_tick"] := A_TickCount
			_GestureRegionCapture["save_timeout_ms"] := 60000
			_GestureRegionCapture["original_clipboard"] := "__CB_SAVE_ERROR__"
			_GestureRegionCapture["callback"] := _GSWO_RecordTerminal
		}
		if Mode == "callback-replacement" {
			Replacement := Map("stage", Stage, "retired", Retired, "bytes", Bytes)
			Callback := _GSSC_Replace.Bind(Replacement)
			if Owner == "direct"
				_GestureDirectCaptures[1]["callback"] := Callback
			else
				_GestureRegionCapture["callback"] := Callback
		}
		if Mode == "retry" || Mode == "replacement" || Mode == "start-terminal" {
			Blocker := FSOpenStrict(Stage, "r-wd", "UTF-8-RAW")
			AssertTrue(IsObject(Blocker), "the real reader must hold the original stage without DELETE sharing")
			Deleted := DllCall("Kernel32\DeleteFileW", "Str", Stage, "Int")
			DeleteError := A_LastError
			AssertEqual(0, Deleted, "the fixture must establish an actual native deletion refusal")
			AssertEqual(32, DeleteError, "FILE_SHARE_DELETE refusal must be the real Win32 sharing violation")
		}
		if Mode == "start-terminal" {
			Job["handle"].start := _GSSC_Start.Bind(WorkerId)
			AssertTrue(_GestureScreenshotStartWorker(WorkerId),
				"real terminal delivery remains a successful start even while cleanup debt retains its registry entry")
		} else
			GestureScreenshotWorkerDone(WorkerId, 0, "", "")
		AssertEqual(1, _GSWO_Terminals.Length, "the actual owner completion must be delivered exactly once")
		AssertTrue(_GSWO_Terminals[1]["ok"], "the real file publication must succeed despite the read-only blocker")
		AssertTrue(FSSameBytes(Destination, Witness), "the actual publisher must copy every raw stage byte")
		if Mode == "ordinary" || Mode == "callback-replacement" {
			AssertFalse(GestureScreenshotWorkerState.jobs.Has(WorkerId), "an acknowledged cleanup releases its exact job")
			if Mode == "ordinary"
				AssertEqual("", FileExist(Stage), "ordinary completion must remove its private stage")
			else
				_GSSC_AssertForeign(OriginalSnapshot, Replacement["foreign"], Stage, Retired)
		} else {
			AssertTrue(FileExist(Stage) != "", "the real OS blocker must still retain the stage")
			AssertTrue(GestureScreenshotWorkerState.jobs.Has(WorkerId),
				"a false native cleanup receipt must retain the exact completed worker debt")
			AssertTrue(GestureScreenshotWorkerState.jobs[WorkerId] == Job, "cleanup debt cannot substitute another job")
			Blocker.Close()
			Blocker := 0
			if Mode == "replacement" {
				FileMove(Stage, Retired)
				_GSFP_Write(Stage, Bytes)
				ForeignSnapshot := _GSFP_Snapshot(Stage)
			}
			Critical("Off")
			Started := A_TickCount
			while GestureScreenshotWorkerState.jobs.Has(WorkerId) && TickElapsed(Started) < 2500
				Sleep(10)
			AssertFalse(GestureScreenshotWorkerState.jobs.Has(WorkerId), "native cleanup must settle after the blocker releases")
			if Mode == "replacement" {
				_GSSC_AssertForeign(OriginalSnapshot, ForeignSnapshot, Stage, Retired)
			} else
				AssertEqual("", FileExist(Stage), "the exact retained stage must be deleted after native release")
		}
		GestureScreenshotWorkerDone(WorkerId, 0, "", "")
		AssertEqual(1, _GSWO_Terminals.Length, "cleanup or a late terminal cannot replay business completion")
		AssertTrue(FSSameBytes(Destination, Witness), "cleanup must never touch the published user file")
	} catch as Err {
		Primary := Err
	} finally {
		Critical("On")
		try {
			if IsObject(Blocker)
				Blocker.Close()
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if WorkerId && GestureScreenshotWorkerState.jobs.Has(WorkerId) {
				GestureScreenshotWorkerDone(WorkerId, 0, "", "")
				Started := DllCall("Kernel32\GetTickCount64", "UInt64")
				while GestureScreenshotWorkerState.jobs.Has(WorkerId)
						&& DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 2500
					_GestureScreenshotRetryCleanup()
				AssertFalse(GestureScreenshotWorkerState.jobs.Has(WorkerId),
					"fixture cleanup debt must retire before restoring another worker registry")
			}
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		; The private timer must not wake against the restored incoming registry.
		if Old["jobs"].Count == 0
			TimerSetCallback(_GestureScreenshotRetryCleanup, 0)
		try _GSWO_Restore(Old)
		catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if Created
				DirDelete(Root, true)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			if A_IsSuspended != WasSuspended
				Suspend(WasSuspended)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		Critical(PreviousCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _GSSC_Owner in ["direct", "region"]
	for _GSSC_Mode in ["ordinary", "retry", "replacement", "start-terminal", "callback-replacement"]
		Test("screenshot stage cleanup: " . _GSSC_Owner . " " . _GSSC_Mode . " retains exact physical ownership (screenshot-stage-cleanup-debt)",
			_GSSC_Run.Bind(_GSSC_Owner, _GSSC_Mode))
