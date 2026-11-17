; tests/unit/diagnostics/adapters/crash_report/test_screenshot_stage_cleanup.ahk

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
		; This fixture created these bytes itself rather than running Capture.
		; Give cleanup that exact receipt; production may not adopt a pathname.
		Job["stage_snapshot"] := OriginalSnapshot
		Job["stage_captured"] := true
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

; A capture can fail before it writes any pixels (for example GetDC/GDI+
; startup refusal). Keep the real deferred worker, public owner, file identity
; capture and cleanup, while replacing only that failing pixel I/O boundary.
_GSAC_RefuseCapture(*) {
	throw Error("owned fixture capture refused before any stage write")
}

_GSAC_SpawnRefusal(Capture, Done) {
	return _GestureScreenshotSpawnNative(_GSAC_RefuseCapture, Done)
}

_GSAC_Run(Preexisting) {
	global DriverPid, _GestureDirectCaptureEpoch, _GSWO_Terminals
	WasCritical := Critical("On"), WasSuspended := A_IsSuspended
	Old := _GSWO_Install()
	Root := A_Temp . "\ergopti_stage_admission_probe_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Stage := "", Original := 0, Writer := -1, Primary := 0
	try {
		AssertEqual(0, Old["jobs"].Count, "the admission fixture cannot borrow a live worker or cleanup debt")
		if A_IsSuspended
			Suspend(false)
		Created := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(Created, "the fixture must acquire its private destination directory exclusively")
		; A high fresh epoch avoids interacting with another run's stage. Seed
		; exactly the public production owner's next deterministic path.
		_GestureDirectCaptureEpoch := Random(1000000, 999999999)
		Epoch := _GestureDirectCaptureEpoch + 1
		Stage := A_Temp . "\ergopti_screenshot_direct_" . DriverPid . "_" . Epoch . ".png"
		AssertFalse(FSStrictExists(Stage), "the fixture must never reuse an unowned real stage")
		Witness := Root . "\foreign-stage.bin"
		Bytes := Buffer(37, 0xA7)
		_GSFP_Write(Witness, Bytes)
		if Preexisting {
			; CREATE_NEW, not FileOpen('w'), owns this fixture's foreign file.
			Writer := DllCall("Kernel32\CreateFileW", "Str", Stage, "UInt", 0x40000000,
				"UInt", 0, "Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
			AssertTrue(Writer != -1, "the foreign-stage fixture must acquire the exact path with CREATE_NEW")
			Written := 0
			try AssertTrue(_FSNativeWrite(Writer, Bytes, Bytes.Size, &Written) && Written == Bytes.Size)
			finally {
				DllCall("Kernel32\CloseHandle", "Ptr", Writer)
				Writer := -1
			}
			Original := _GSFP_Snapshot(Stage)
			AssertTrue(FSSameBytes(Stage, Witness), "the independently owned stage must exist before capture admission")
		}
		GestureScreenshotWorkerState.spawn_fn := _GSAC_SpawnRefusal
		GestureScreenshotWorkerState.file_exists_fn := 0
		GestureScreenshotWorkerState.publish_file_fn := 0
		GestureScreenshotWorkerState.cleanup_stage_fn := 0
		GestureScreenshotWorkerState.rollback_file_fn := 0
		Accepted := GestureCaptureRegion(0, 0, 1, 1, "save", Root . "\published.png", _GSWO_RecordTerminal)
		; Real SetTimer-driven _NativeRun catches the pixel I/O refusal, then
		; delivers through the actual worker registry and direct owner.
		Critical("Off")
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while (_GSWO_Terminals.Length == 0 || GestureScreenshotWorkerState.jobs.Count)
				&& DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 2500
			Sleep(5)
		Sleep(150)
		Critical("On")
		FileAppend("OBSERVATION screenshot-stage-admission preexisting=" . Preexisting
			. " accepted=" . Accepted . " terminals=" . _GSWO_Terminals.Length
			. " jobs=" . GestureScreenshotWorkerState.jobs.Count . " stage_exists=" . FSStrictExists(Stage)
			. " destination_exists=" . FSStrictExists(Root . "\published.png") . "`n", "*")
		AssertEqual(1, _GSWO_Terminals.Length, "capture admission or its real worker must finish exactly once")
		AssertFalse(_GSWO_Terminals[1]["ok"], "a pre-write capture failure cannot report success")
		AssertEqual(0, GestureScreenshotWorkerState.jobs.Count, "the failed owner must retire all of its own cleanup debt")
		AssertFalse(FSStrictExists(Root . "\published.png"), "no failed capture may publish a destination")
		if Preexisting {
			AssertTrue(FSStrictExists(Stage), "a capture that never wrote its stage must preserve the pre-existing foreign file")
			Observed := _GSFP_Snapshot(Stage)
			for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
				AssertEqual(Original[Key], Observed[Key], "capture cleanup cannot adopt a pre-existing native file identity")
			AssertTrue(FSSameBytes(Stage, Witness), "capture cleanup must preserve the original foreign bytes")
		} else
			AssertFalse(FSStrictExists(Stage), "the no-stage control must leave no stage behind")
	} catch as Err {
		Primary := Err
	} finally {
		Critical("On")
		if Writer != -1
			DllCall("Kernel32\CloseHandle", "Ptr", Writer)
		try {
			GestureScreenshotCancelAll("admission fixture cleanup")
			_GestureScreenshotRetryCleanup()
			AssertEqual(0, GestureScreenshotWorkerState.jobs.Count, "the fixture must retire its workers before restoring the incoming registry")
			if Old["jobs"].Count == 0
				TimerSetCallback(_GestureScreenshotRetryCleanup, 0)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		try {
			; Only the identity created with CREATE_NEW above is ours to remove.
			if Original is Map && FSStrictExists(Stage)
				AssertTrue(FSDeleteVerified(Stage, _GestureScreenshotSnapshotMatches.Bind(Original)))
			if Created
				DirDelete(Root, true)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		_GSWO_Restore(Old)
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		Critical(WasCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _GSAC_Preexisting in [false, true]
	Test("screenshot stage admission: pre-write failure " . (_GSAC_Preexisting ? "preserves foreign stage" : "without a stage") . " (screenshot-stage-admission)",
		_GSAC_Run.Bind(_GSAC_Preexisting))

; Qualify real GDI+ encoding against native sharing. A zero-access handle
; demonstrably does not deny deletion; it is an explicit negative control.
; The GENERIC_READ candidate must both deny DELETE and allow native encoding.
_GSGL_WritePixel(Stage) {
	global GESTURE_SCREENSHOT_PIXEL_FORMAT_32BPP_ARGB, GESTURE_SCREENSHOT_PNG_ENCODER
	Pixels := Buffer(4, 0)
	NumPut("UInt", 0xFF00FF00, Pixels)
	Image := 0
	_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipCreateBitmapFromScan0",
		"Int", 1, "Int", 1, "Int", 4, "Int", GESTURE_SCREENSHOT_PIXEL_FORMAT_32BPP_ARGB,
		"Ptr", Pixels, "Ptr*", &Image, "Int"), "GdipCreateBitmapFromScan0")
	try _GestureScreenshotGdipWrite(&Image, Stage, GESTURE_SCREENSHOT_PNG_ENCODER, 0)
	finally _GestureScreenshotGdipDispose(Image)
}

_GSGL_Run(Mode) {
	HoldLease := Mode != "unleased"
	global DriverPid
	Root := A_Temp . "\ergopti_stage_gdi_lease_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Handle := -1
	try {
		Created := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(Created)
		Stage := Root . "\pixel.png"
		; GENERIC_READ participates in native sharing; access zero does not.
		; Keep CREATE_NEW and FILE_SHARE_READ|WRITE for every case.
		Access := Mode == "read" ? 0x80000000 : 0
		Handle := DllCall("Kernel32\CreateFileW", "Str", Stage, "UInt", Access,
			"UInt", 3, "Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(Handle != -1, "CREATE_NEW must acquire this fixture stage without adopting an existing path")
		Original := FSHandleSnapshot(Handle)
		AssertTrue(Original.Get("ok", false) && Original["size"] == 0)
		if HoldLease {
			Deleted := DllCall("Kernel32\DeleteFileW", "Str", Stage, "Int")
			DeleteError := A_LastError
			if Mode == "zero-negative" {
				FileAppend("OBSERVATION screenshot-stage-gdi-lease mode=zero-negative delete_result=" . Deleted
					. " delete_error=" . DeleteError . "`n", "*")
				AssertEqual(1, Deleted, "zero access is a negative control: it does not participate in DELETE sharing")
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int") != 0)
				Handle := -1
				AssertFalse(FSStrictExists(Stage), "the unprotected zero-access stage must be gone after delete completes")
				return
			}
			AssertEqual(0, Deleted, "the GENERIC_READ lease must prohibit replacement or deletion")
			AssertEqual(32, DeleteError, "the lease must establish a real native DELETE sharing refusal")
		} else {
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int") != 0)
			Handle := -1
		}
		_GestureScreenshotWithGdiplus(_GSGL_WritePixel.Bind(Stage))
		Observed := HoldLease ? FSHandleSnapshot(Handle) : _GSFP_Snapshot(Stage)
		FileAppend("OBSERVATION screenshot-stage-gdi-lease mode=" . Mode . " png_bytes=" . Observed["size"]
			. " same_identity=" . (Original["volume"] == Observed["volume"]
				&& Original["index_high"] == Observed["index_high"] && Original["index_low"] == Observed["index_low"]) . "`n", "*")
		AssertTrue(Observed.Get("ok", false) && Observed["size"] > 8, "the native PNG encoder must produce real bytes")
		if HoldLease
			for Key in ["volume", "index_high", "index_low"]
				AssertEqual(Original[Key], Observed[Key], "native encoding must retain the exclusively acquired file identity")
		Reader := FSOpenStrict(Stage, "r-wd", "UTF-8-RAW")
		try {
			Header := Buffer(8, 0)
			AssertEqual(8, Reader.RawRead(Header, 8))
			AssertEqual(0x474E5089, NumGet(Header, 0, "UInt"), "the encoder must emit the actual PNG signature")
			AssertEqual(0x0A1A0A0D, NumGet(Header, 4, "UInt"))
		} finally Reader.Close()
	} finally {
		if Handle != -1
			DllCall("Kernel32\CloseHandle", "Ptr", Handle)
		if Created
			DirDelete(Root, true)
	}
}

for _GSGL_Mode in ["unleased", "zero-negative", "read"]
	Test("screenshot stage GDI lease: " . Map("unleased", "unleased existing-file control",
		"zero-negative", "zero-access negative control permits deletion", "read", "GENERIC_READ excludes replacement and permits encoding")[_GSGL_Mode]
		. " (screenshot-stage-lease-compat)", _GSGL_Run.Bind(_GSGL_Mode))


; Genuine deferred worker -> exclusive stage -> synthetic GDI+ pixels ->
; actual direct publication -> retained-handle cleanup. No screen is read.
_GSOC_Capture(Record) {
	Record["capture_calls"] += 1
	Record["capture_critical"] := !!A_IsCritical
	Job := Record["job"]
	Lease := Job.Get("stage_lease", 0)
	AssertTrue(Job.Get("stage_acquired", false) && Lease != 0,
		"the real wrapper must acquire the exact native stage before any pixels")
	Record["lease"] := Lease
	Record["initial"] := FSHandleSnapshot(Lease)
	AssertTrue(Record["initial"].Get("ok", false) && Record["initial"]["size"] == 0)
	Deleted := DllCall("Kernel32\DeleteFileW", "Str", Job["stage"], "Int")
	DeleteError := A_LastError
	AssertEqual(0, Deleted, "the actual capture wrapper must pin its acquired stage pathname")
	AssertEqual(32, DeleteError)
	if Record["mode"] == "cancel" {
		GestureDirectCaptureFinish(1, false, "fixture cancellation after acquisition", true)
		return
	}
	_GestureScreenshotWithGdiplus(_GSGL_WritePixel.Bind(Job["stage"]))
	Record["pixel_calls"] += 1
	Final := FSHandleSnapshot(Lease)
	AssertTrue(Final.Get("ok", false) && Final["size"] > 8)
	for Key in ["volume", "index_high", "index_low"]
		AssertEqual(Record["initial"][Key], Final[Key], "GDI+ must write the originally acquired stage identity")
	if Record["mode"] == "close-debt" {
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Lease, "UInt", 2, "UInt", 2, "Int") != 0,
			"the fixture must protect the actual retained lease against CloseHandle")
		Record["protected"] := true
	}
}

_GSOC_Run(Mode) {
	global DriverPid, _GestureDirectCaptures, _GSWO_Terminals
	WasCritical := Critical("On"), WasSuspended := A_IsSuspended
	Old := _GSWO_Install()
	Root := A_Temp . "\ergopti_owned_stage_composition_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Primary := 0, Job := 0
	Record := Map("mode", Mode, "capture_calls", 0, "pixel_calls", 0, "capture_critical", true,
		"lease", 0, "protected", false)
	try {
		AssertEqual(0, Old["jobs"].Count, "the native composition cannot borrow a live worker or cleanup debt")
		if A_IsSuspended
			Suspend(false)
		Created := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(Created)
		Stage := Root . "\stage.png", Destination := Root . "\published.png"
		GestureScreenshotWorkerState.spawn_fn := 0
		GestureScreenshotWorkerState.file_exists_fn := 0
		GestureScreenshotWorkerState.publish_file_fn := 0
		GestureScreenshotWorkerState.cleanup_stage_fn := 0
		GestureScreenshotWorkerState.rollback_file_fn := 0
		WorkerId := _GestureScreenshotCreateWorker("direct_save", 1, Stage,
			_GSOC_Capture.Bind(Record), GestureDirectCaptureWorkerDone.Bind(1))
		AssertTrue(WorkerId > 0)
		Job := GestureScreenshotWorkerState.jobs[WorkerId]
		Record["job"] := Job
		_GestureDirectCaptures[1] := Map("worker_id", WorkerId, "mode", "save", "path", Destination,
			"started_tick", A_TickCount, "timeout_ms", 60000, "callback", _GSWO_RecordTerminal)
		AssertTrue(_GestureScreenshotStartWorker(WorkerId))
		Critical("Off")
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while (_GSWO_Terminals.Length == 0 || (Mode != "close-debt" && GestureScreenshotWorkerState.jobs.Count))
				&& DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 2500
			Sleep(5)
		Critical("On")
		FileAppend("OBSERVATION screenshot-owned-stage mode=" . Mode . " capture_calls=" . Record["capture_calls"]
			. " pixel_calls=" . Record["pixel_calls"] . " capture_critical=" . Record["capture_critical"]
			. " terminals=" . _GSWO_Terminals.Length . " jobs=" . GestureScreenshotWorkerState.jobs.Count
			. " lease=" . Job.Get("stage_lease", 0) . " stage_exists=" . FSStrictExists(Stage)
			. " destination_exists=" . FSStrictExists(Destination) . "`n", "*")
		AssertEqual(1, Record["capture_calls"], "the actual native wrapper must call its pixel boundary exactly once")
		AssertFalse(Record["capture_critical"], "native stage acquisition and capture must execute in the deferred noncritical worker")
		AssertEqual(1, _GSWO_Terminals.Length)
		AssertEqual(Mode != "cancel", _GSWO_Terminals[1]["ok"])
		AssertEqual(Mode == "cancel" ? 0 : 1, Record["pixel_calls"])
		AssertEqual(Mode != "cancel", FSStrictExists(Destination), "only a successful current owner may publish the synthetic PNG")
		if Mode == "close-debt" {
			AssertTrue(Record["protected"] && GestureScreenshotWorkerState.jobs.Has(WorkerId),
				"a real protected-handle close refusal must retain cleanup debt")
			AssertEqual(Record["lease"], Job["stage_lease"], "a failed close must retain the exact native reference")
			AssertTrue(Job.Get("cleanup_attempts", 0) >= 1 && FSStrictExists(Stage))
			AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Record["lease"], "UInt", 2, "UInt", 0, "Int") != 0)
			Record["protected"] := false
			Critical("Off")
			_GestureScreenshotRetryCleanup()
			Critical("On")
		}
		AssertFalse(GestureScreenshotWorkerState.jobs.Has(WorkerId), "successful close/delete must retire the exact worker")
		AssertEqual(0, Job["stage_lease"], "the closed lease must be retired exactly once")
		AssertFalse(FSStrictExists(Stage), "cleanup must remove only the stage this worker exclusively acquired")
		if Mode != "cancel" {
			Reader := FSOpenStrict(Destination, "r-wd", "UTF-8-RAW")
			try {
				Header := Buffer(8, 0)
				AssertEqual(8, Reader.RawRead(Header, 8))
				AssertEqual(0x474E5089, NumGet(Header, 0, "UInt"))
				AssertEqual(0x0A1A0A0D, NumGet(Header, 4, "UInt"))
			} finally Reader.Close()
		}
	} catch as Err {
		Primary := Err
	} finally {
		Critical("On")
		try {
			if Record["protected"] && Job is Map && Job.Get("stage_lease", 0) {
				AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Job["stage_lease"], "UInt", 2, "UInt", 0, "Int") != 0)
				Record["protected"] := false
			}
			GestureScreenshotCancelAll("owned stage fixture cleanup")
			_GestureScreenshotRetryCleanup()
			AssertEqual(0, GestureScreenshotWorkerState.jobs.Count, "fixture debt must retire before restoring the incoming registry")
			if Old["jobs"].Count == 0
				TimerSetCallback(_GestureScreenshotRetryCleanup, 0)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		_GSWO_Restore(Old)
		try {
			if Created
				DirDelete(Root, true)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		Critical(WasCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _GSOC_Mode in ["publish", "cancel", "close-debt"]
	Test("screenshot owned stage composition: " . _GSOC_Mode . " (screenshot-owned-stage-composition)", _GSOC_Run.Bind(_GSOC_Mode))


; AHK counts references. This real destruction witness proves that the exact
; worker cycle is released even when its native timer has never been armed.
class _GSOC_UnstartedLifetime {
	__New(Record) {
		this.Record := Record
	}
	Call(*) {
		this.Record["calls"] += 1
		throw Error("an unstarted native capture must never execute")
	}
	__Delete() {
		this.Record["disposed"] += 1
	}
}

_GSOC_Unstarted(Mode) {
	global DriverPid
	WasCritical := Critical("On")
	Old := _GSWO_Install()
	Root := A_Temp . "\ergopti_unstarted_stage_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Job := 0, Capture := 0, Primary := 0
	Record := Map("calls", 0, "disposed", 0)
	try {
		AssertEqual(0, Old["jobs"].Count, "the unstarted lifetime fixture cannot borrow a live worker or cleanup debt")
		Created := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(Created)
		Stage := Root . "\stage.png"
		GestureScreenshotWorkerState.spawn_fn := 0
		GestureScreenshotWorkerState.cleanup_stage_fn := 0
		Capture := _GSOC_UnstartedLifetime(Record)
		WorkerId := _GestureScreenshotCreateWorker("direct_save", 1, Stage, Capture, 0)
		AssertTrue(WorkerId > 0)
		Job := GestureScreenshotWorkerState.jobs[WorkerId]
		Capture := 0
		AssertFalse(Job["start_attempted"])
		AssertEqual(0, Record["disposed"], "the live native handle must retain its unstarted capture closure")
		if Mode == "discard"
			AssertTrue(_GestureScreenshotDiscardUnstartedWorker(WorkerId))
		else
			AssertTrue(GestureScreenshotCancelWorker(WorkerId, "shutdown"))
		FileAppend("OBSERVATION screenshot-unstarted-lifetime mode=" . Mode . " capture_calls=" . Record["calls"]
			. " disposed=" . Record["disposed"] . " jobs=" . GestureScreenshotWorkerState.jobs.Count
			. " stage_exists=" . FSStrictExists(Stage) . "`n", "*")
		AssertEqual(0, Record["calls"], "neither cleanup path may execute or arm the capture")
		AssertEqual(1, Record["disposed"], "unstarted cleanup must actually destroy the capture closure without waiting for NativeRun")
		AssertEqual(0, Job["handle"], "quiescent retirement must release its reverse task reference")
		AssertFalse(GestureScreenshotWorkerState.jobs.Has(WorkerId))
		AssertFalse(FSStrictExists(Stage), "discarding an unstarted task cannot acquire a stage file")
	} catch as Err {
		Primary := Err
	} finally {
		Capture := 0
		try {
			GestureScreenshotCancelAll("shutdown")
			_GestureScreenshotRetryCleanup()
			AssertEqual(0, GestureScreenshotWorkerState.jobs.Count)
			if Old["jobs"].Count == 0
				TimerSetCallback(_GestureScreenshotRetryCleanup, 0)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		; If the regression fails, release only this fixture's known reverse
		; reference after recording its failed lifetime oracle.
		if Job is Map
			Job["handle"] := 0
		_GSWO_Restore(Old)
		try {
			if Created
				DirDelete(Root, true)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		Critical(WasCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _GSOC_UnstartedMode in ["discard", "shutdown"]
	Test("screenshot unstarted native lifetime: " . _GSOC_UnstartedMode . " (screenshot-unstarted-lifetime)",
		_GSOC_Unstarted.Bind(_GSOC_UnstartedMode))

_GSDC_UnexpectedCapture(Record) {
	Record["calls"] += 1
	throw Error("the native stage collision must be refused before Capture")
}

_GSDC_Run() {
	global DriverPid, _GestureDirectCaptures, _GSWO_Terminals
	WasCritical := Critical("On"), WasSuspended := A_IsSuspended
	Old := _GSWO_Install()
	Root := A_Temp . "\ergopti_default_stage_collision_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Job := 0, Primary := 0, Record := Map("calls", 0)
	try {
		AssertEqual(0, Old["jobs"].Count, "the collision fixture cannot borrow a live worker or cleanup debt")
		if A_IsSuspended
			Suspend(false)
		Created := FSCreateDirectoryExclusiveStrict(Root)
		AssertTrue(Created)
		Stage := Root . "\stage.png", Destination := Root . "\published.png", Witness := Root . "\foreign.bin"
		Bytes := Buffer(37, 0xA7)
		_GSFP_Write(Stage, Bytes)
		_GSFP_Write(Witness, Bytes)
		Original := _GSFP_Snapshot(Stage)
		AssertTrue(Original.Get("ok", false) && FSSameBytes(Stage, Witness))
		GestureScreenshotWorkerState.spawn_fn := 0
		GestureScreenshotWorkerState.file_exists_fn := 0
		GestureScreenshotWorkerState.publish_file_fn := 0
		GestureScreenshotWorkerState.cleanup_stage_fn := 0
		GestureScreenshotWorkerState.rollback_file_fn := 0
		WorkerId := _GestureScreenshotCreateWorker("direct_save", 1, Stage,
			_GSDC_UnexpectedCapture.Bind(Record), GestureDirectCaptureWorkerDone.Bind(1))
		AssertTrue(WorkerId > 0)
		Job := GestureScreenshotWorkerState.jobs[WorkerId]
		_GestureDirectCaptures[1] := Map("worker_id", WorkerId, "mode", "save", "path", Destination,
			"started_tick", A_TickCount, "timeout_ms", 60000, "callback", _GSWO_RecordTerminal)
		AssertTrue(_GestureScreenshotStartWorker(WorkerId), "the genuine native worker must start before rejecting its stage collision")
		Critical("Off")
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while (_GSWO_Terminals.Length == 0 || GestureScreenshotWorkerState.jobs.Count)
				&& DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 2500
			Sleep(5)
		Critical("On")
		FileAppend("OBSERVATION screenshot-default-stage-collision capture_calls=" . Record["calls"]
			. " terminals=" . _GSWO_Terminals.Length . " jobs=" . GestureScreenshotWorkerState.jobs.Count
			. " stage_exists=" . FSStrictExists(Stage) . " destination_exists=" . FSStrictExists(Destination) . "`n", "*")
		AssertEqual(0, Record["calls"], "CREATE_NEW must refuse an existing native stage before invoking the capture callback")
		AssertEqual(1, _GSWO_Terminals.Length, "the default native worker must finish through the actual direct owner exactly once")
		AssertFalse(_GSWO_Terminals[1]["ok"], "a native stage collision cannot report a successful capture")
		AssertFalse(GestureScreenshotWorkerState.jobs.Has(WorkerId), "a refused acquisition must retire its exact native worker")
		AssertFalse(Job["stage_acquired"], "an existing file cannot become an acquired stage")
		AssertEqual(0, Job["stage_lease"])
		AssertTrue(FSStrictExists(Stage), "a refused CREATE_NEW cannot delete the foreign stage")
		Observed := _GSFP_Snapshot(Stage)
		for Key in ["volume", "index_high", "index_low", "size", "write_high", "write_low"]
			AssertEqual(Original[Key], Observed[Key], "a refused native acquisition must preserve the complete foreign identity")
		AssertTrue(FSSameBytes(Stage, Witness), "a refused native acquisition must preserve every foreign byte")
		AssertFalse(FSStrictExists(Destination), "a refused native acquisition cannot publish a destination")
	} catch as Err {
		Primary := Err
	} finally {
		Critical("On")
		try {
			GestureScreenshotCancelAll("default collision fixture cleanup")
			_GestureScreenshotRetryCleanup()
			AssertEqual(0, GestureScreenshotWorkerState.jobs.Count, "fixture cleanup must retire before restoring the incoming registry")
			if Old["jobs"].Count == 0
				TimerSetCallback(_GestureScreenshotRetryCleanup, 0)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		_GSWO_Restore(Old)
		try {
			if Created
				DirDelete(Root, true)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		Critical(WasCritical)
	}
	if IsObject(Primary)
		throw Primary
}

Test("screenshot default native stage collision preserves foreign identity before capture (screenshot-default-stage-collision)", _GSDC_Run)


; Exercise the real GDI+ scaling and PNG encoder on a private generated bitmap;
; this does not capture, inspect or modify the user's desktop or clipboard.
_GSRZ_Encode(Stage, Width, Height, MaxEdge) {
	global GESTURE_SCREENSHOT_PIXEL_FORMAT_32BPP_ARGB, GESTURE_SCREENSHOT_PNG_ENCODER
	Image := 0
	_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipCreateBitmapFromScan0",
		"Int", Width, "Int", Height, "Int", 0, "Int", GESTURE_SCREENSHOT_PIXEL_FORMAT_32BPP_ARGB,
		"Ptr", 0, "Ptr*", &Image, "Int"), "create private resize bitmap")
	try _GestureScreenshotGdipWrite(&Image, Stage, GESTURE_SCREENSHOT_PNG_ENCODER, MaxEdge)
	finally _GestureScreenshotGdipDispose(Image)
}
_GSRZ_ReadBE32(Bytes, Offset) {
	return (NumGet(Bytes, Offset, "UChar") << 24) | (NumGet(Bytes, Offset + 1, "UChar") << 16)
		| (NumGet(Bytes, Offset + 2, "UChar") << 8) | NumGet(Bytes, Offset + 3, "UChar")
}
_GSRZ_RealPng(Width, Height, MaxEdge, ExpectedWidth, ExpectedHeight) {
	global DriverPid
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "an unretired stage lease prevents another fixture")
	Root := A_Temp . "\ergopti_resize_png_" . DriverPid . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := false, Lease := -1
	try {
		Receipt := FSCreateDirectoryExclusiveStrict(Root)
		Created := Receipt is Integer && Receipt == 1
		AssertTrue(Created, "the native image fixture must own its private directory")
		Stage := Root . "\resize.png"
		Lease := _GestureScreenshotAcquireStageLease(Stage)
		_GestureScreenshotWithGdiplus(_GSRZ_Encode.Bind(Stage, Width, Height, MaxEdge))
		AssertTrue(_GestureScreenshotCloseStageLease(Lease))
		Lease := -1
		Bytes := FSReadBytesStrict(Stage)
		AssertTrue(Bytes.Size >= 24, "the real PNG must include its complete IHDR dimensions")
		AssertEqual(0x474E5089, NumGet(Bytes, 0, "UInt"))
		AssertEqual(0x0A1A0A0D, NumGet(Bytes, 4, "UInt"))
		AssertEqual(0x52444849, NumGet(Bytes, 12, "UInt"), "dimensions must come from the real PNG IHDR")
		ActualWidth := _GSRZ_ReadBE32(Bytes, 16), ActualHeight := _GSRZ_ReadBE32(Bytes, 20)
		_TestPrint("# screenshot resize source=" . Width . "x" . Height . " max_edge=" . MaxEdge
			. " png=" . ActualWidth . "x" . ActualHeight . " bytes=" . Bytes.Size)
		AssertEqual(ExpectedWidth, ActualWidth)
		AssertEqual(ExpectedHeight, ActualHeight)
	} finally {
		if Lease != -1 {
			try {
				_GestureScreenshotCloseStageLease(Lease)
				Lease := -1
			} catch as Failure {
				RetirementDebt := {Root: Root, Lease: Lease}
				throw Failure
			}
		}
		if Created {
			try DirDelete(Root, true)
			catch as Failure {
				RetirementDebt := {Root: Root, Lease: -1}
				throw Failure
			}
		}
	}
}
for _GSRZ_Case in [[12, 6, 4, 4, 2], [6, 12, 4, 2, 4], [12, 6, 0, 12, 6],
	[6, 3, 20, 6, 3], [1, 12, 4, 1, 4]]
	Test("screenshot: real PNG preserves bounded geometry " . _GSRZ_Case[1] . "x" . _GSRZ_Case[2]
		. " max=" . _GSRZ_Case[3] . " (screenshot-native-resize)", _GSRZ_RealPng.Bind(_GSRZ_Case*))
