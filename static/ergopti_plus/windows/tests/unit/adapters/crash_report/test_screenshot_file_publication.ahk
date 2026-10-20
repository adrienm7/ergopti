; tests/unit/adapters/crash_report/test_screenshot_file_publication.ahk

; Real disk publication and rollback under both real owner completion paths.
; No screen worker starts, no tray notification runs, and region clipboard
; settlement receives its genuine fail-closed invalid-snapshot sentinel.

_GSFP_Write(Path, Bytes) {
	Writer := FSOpenStrict(Path, "w", "UTF-8-RAW")
	try AssertEqual(Bytes.Size, Writer.RawWrite(Bytes), "the owned fixture bytes must be written completely")
	finally Writer.Close()
}

_GSFP_Snapshot(Path) {
	Reader := FSOpenStrict(Path, "r-wd", "UTF-8-RAW")
	try return FSHandleSnapshot(Reader.Handle)
	finally Reader.Close()
}

_GSFP_Cancel(Record) {
	Record["job"]["cancel_requested"] := true
	if Record["owner"] == "direct"
		GestureDirectCaptureFinish(1, false, "publication test cancellation")
	else
		GestureRegionCaptureFinish(1, "publication test cancellation")
}

_GSFP_Publish(Record, Stage, Destination) {
	Mode := Record["mode"]
	if Mode == "foreign-before" {
		_GSFP_Write(Destination, Record["foreign_bytes"])
		Record["foreign_snapshot"] := _GSFP_Snapshot(Destination)
	}
	; Keep the genuine publisher in the pipeline. On the unfixed driver a
	; collision fails its pre-Move existence check, then the caller deletes the foreign file.
	Receipt := _GestureScreenshotDefaultPublishFile(Stage, Destination)
	if Mode == "foreign-after" || Mode == "same-bytes-after" {
		FileMove(Destination, Record["retired"])
		_GSFP_Write(Destination, Mode == "same-bytes-after" ? Record["owned_bytes"] : Record["foreign_bytes"])
		Record["foreign_snapshot"] := _GSFP_Snapshot(Destination)
		_GSFP_Cancel(Record)
	} else if Mode == "owned-cancel"
		_GSFP_Cancel(Record)
	else if Mode == "owned-failure" {
		; A failed receipt after a real publication still owns that artifact.
		if Receipt is Map
			Receipt["published"] := false
		else
			Receipt := false
	}
	return Receipt
}

_GSFP_Case(Owner, Mode) {
	global _GestureDirectCaptures, _GestureRegionCapture, _GSWO_Terminals, DriverPid
	static Nonce := 0
	OldCritical := Critical("On"), OldSuspend := A_IsSuspended
	Old := _GSWO_Install()
	SourceCreated := false, DestinationCreated := false, PrimaryFailure := 0
	Stem := "ergopti_publication_" . DriverPid . "_" . A_TickCount . "_" . ++Nonce
	SourceDir := A_Temp . "\" . Stem . "_source"
	DestinationDir := A_ScriptDir . "\" . Stem . "_destination"
	try {
		if A_IsSuspended
			Suspend(false)
		SourceCreated := FSCreateDirectoryExclusiveStrict(SourceDir)
		DestinationCreated := FSCreateDirectoryExclusiveStrict(DestinationDir)
		Stage := SourceDir . "\stage.png", Destination := DestinationDir . "\capture.png"
		Owned := Buffer(131089, 0xA5), Foreign := Buffer(23, 0x6B)
		NumPut("UInt", 0x474E5089, Owned), NumPut("UInt", 0, Owned, 65535)
		_GSFP_Write(Stage, Owned)
		SourceSnapshot := _GSFP_Snapshot(Stage)
		Record := Map("owner", Owner, "mode", Mode, "owned_bytes", Owned, "foreign_bytes", Foreign,
			"retired", DestinationDir . "\retired.png")
		Job := Map("stage", Stage, "cancel_requested", false)
		Record["job"] := Job
		if Mode == "preexisting" {
			_GSFP_Write(Destination, Foreign)
			Record["foreign_snapshot"] := _GSFP_Snapshot(Destination)
		}
		GestureScreenshotWorkerState.file_exists_fn := 0
		GestureScreenshotWorkerState.publish_file_fn := _GSFP_Publish.Bind(Record)
		GestureScreenshotWorkerState.rollback_file_fn := 0
		if Owner == "direct" {
			_GestureDirectCaptures[1] := Map("worker_id", 1, "mode", "save", "path", Destination,
				"started_tick", A_TickCount, "timeout_ms", 60000, "callback", _GSWO_RecordTerminal)
			GestureDirectCaptureWorkerDone(1, 1, Job, 0, "", "")
		} else {
			_GSWO_SeedRegion(1)
			_GestureRegionCapture["worker_id"] := 1
			_GestureRegionCapture["path"] := Destination
			_GestureRegionCapture["save_started_tick"] := A_TickCount
			_GestureRegionCapture["save_timeout_ms"] := 60000
			_GestureRegionCapture["original_clipboard"] := "__CB_SAVE_ERROR__"
			_GestureRegionCapture["callback"] := _GSWO_RecordTerminal
			GestureRegionSaveWorkerDone(1, 1, Job, 0, "", "")
		}
		AssertEqual(1, _GSWO_Terminals.Length, "the real owner must settle exactly once")
		AssertEqual(Mode == "success", _GSWO_Terminals[1]["ok"], "only an admitted owned publication succeeds")
		if InStr(Mode, "foreign") || Mode == "same-bytes-after" || Mode == "preexisting" {
			AssertTrue(FileExist(Destination) != "", "rollback must retain the foreign destination")
			Observed := _GSFP_Snapshot(Destination), Expected := Record["foreign_snapshot"]
			for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
				AssertEqual(Expected[Key], Observed[Key], "the exact foreign file must survive: " . Key)
			Witness := SourceDir . "\expected.bin"
			_GSFP_Write(Witness, Mode == "same-bytes-after" ? Owned : Foreign)
			AssertTrue(FSSameBytes(Destination, Witness), "foreign bytes must remain intact")
		} else if Mode == "success" {
			Witness := SourceDir . "\expected.bin"
			_GSFP_Write(Witness, Owned)
			AssertTrue(FSSameBytes(Destination, Witness), "publication must preserve every raw byte across chunks")
			TargetSnapshot := _GSFP_Snapshot(Destination)
			FileAppend("# screenshot-file-publication-custody " . Owner . " source-volume=" . SourceSnapshot["volume"]
				. " destination-volume=" . TargetSnapshot["volume"] . "`n", "*")
		} else
			AssertEqual("", FileExist(Destination), "owned failed or cancelled publication must be removed")
		AssertTrue(FileExist(Stage) != "", "binary publication must retain the worker stage until its existing final cleanup")
	} catch as Err {
		PrimaryFailure := Err
	} finally {
		; Each teardown runs even when a leaked handle makes directory deletion
		; fail. Preserve the primary assertion instead of replacing its evidence.
		try {
			if _GestureDirectCaptures.Has(1)
				GestureDirectCaptureFinish(1, false, "publication fixture cleanup")
			if _GestureRegionCapture is Map
				GestureRegionCaptureFinish(1, "publication fixture cleanup")
		} catch as Err {
			if !IsObject(PrimaryFailure)
				PrimaryFailure := Err
		}
		try _GSWO_Restore(Old)
		catch as Err {
			if !IsObject(PrimaryFailure)
				PrimaryFailure := Err
		}
		try {
			if SourceCreated
				DirDelete(SourceDir, true)
		} catch as Err {
			if !IsObject(PrimaryFailure)
				PrimaryFailure := Err
		}
		try {
			if DestinationCreated
				DirDelete(DestinationDir, true)
		} catch as Err {
			if !IsObject(PrimaryFailure)
				PrimaryFailure := Err
		}
		try {
			if A_IsSuspended != OldSuspend
				Suspend(OldSuspend)
		} catch as Err {
			if !IsObject(PrimaryFailure)
				PrimaryFailure := Err
		}
		try Critical(OldCritical)
		catch as Err {
			if !IsObject(PrimaryFailure)
				PrimaryFailure := Err
		}
	}
	if IsObject(PrimaryFailure)
		throw PrimaryFailure
}

for _GSFP_Owner in ["direct", "region"]
	for _GSFP_Mode in ["foreign-before", "foreign-after", "same-bytes-after", "owned-failure", "owned-cancel", "success", "preexisting"]
		Test("screenshot disk publication: " . _GSFP_Owner . " " . _GSFP_Mode . " keeps exact file custody (screenshot-file-publication-custody)",
			_GSFP_Case.Bind(_GSFP_Owner, _GSFP_Mode))
