; tests/unit/test_updater_curl_capture.ahk
; Native file identities, actual private Jobs and progressing authenticated curl.

_CurlCaptureNativeIdentityControls() {
	global _UpdaterCurlCaptureDebt
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Failed := false
	Primary := 0
	Foreign := 0
	Moved := ""
	try {
		Capture.Acquire(Parent)
		AssertTrue(Capture.ValidatePaths(), "all five retained native identities match their exact allocated paths")
		AssertEqual(4, Capture.Files.Count, "the parent owns only the four declared curl captures")
		Body := Capture.Files["artifact.bin"]
		Exclusive := DllCall("kernel32\CreateFileW", "Str", Body["path"], "UInt", 0x80000000,
			"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(Exclusive != -1, "access-zero metadata ownership preserves the original FileShare.None completed reader")
		AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Exclusive, "Int"), "the actual exclusive reader closes")
		AssertEqual(0, Capture.ObserveBody(0, 32), "an allocated empty capture is not a live native body")
		Moved := Parent . "\original-body.bin"
		FileMove(Body["path"], Moved)
		ForeignHandle := Capture.Open(Body["path"], 0, 1, false)
		AssertTrue(ForeignHandle != 0, "the independent foreign body owns its own native identity")
		Foreign := Map("path", Body["path"], "handle", ForeignHandle, "directory", false)
		FileAppend("Independent foreign bytes.", Body["path"], "UTF-8-RAW")
		AssertFalse(Capture.ValidatePaths(), "a replacement at an identical path cannot borrow the original capture")
		AssertFalse(_Updater_RetireCurlCapture(Capture), "a replaced body retains its exact original identity as debt")
		AssertTrue(_UpdaterCurlCaptureDebt.Has(ObjPtr(Capture)), "replacement debt blocks a successor transaction")
		AssertEqual("Independent foreign bytes.", FileRead(Body["path"], "UTF-8"), "cleanup preserves every foreign byte")
		AssertTrue(Body["handle"] != 0, "the moved original remains allocated and inspectable")
		AssertTrue(Capture.RetireEntry(Foreign), "only the independent foreign owner can retire its own exact file")
		FileMove(Moved, Body["path"])
		Moved := ""
		AssertTrue(_Updater_RetireCurlCapture(Capture), "restoring the exact original permits acknowledged retirement")
		AssertFalse(DirExist(Capture.Path), "all exact captures retire without recursive deletion")
		AssertEqual(0, Capture.ProbeCloseDebt.Length)
		for Name, Entry in Capture.Files
			AssertEqual(0, Entry["handle"], "each original native file handle closes")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureFinishNativeFixture(Capture, Parent, Failed, Primary, Foreign, Moved)
}
Test("updater curl capture: native identity and replacement debt preserve foreign bytes", _CurlCaptureNativeIdentityControls)

_CurlCaptureNativeBodyControls() {
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Event := 0
	Worker := 0
	Failed := false
	Primary := 0
	Foreign := 0
	Moved := ""
	try {
		Capture.Acquire(Parent)
		Path := StrReplace(Capture.Files["artifact.bin"]["path"], "'", "''")
		EventName := "Local\ErgoptiPlus.CurlCapture.Progress." . SubStr(Capture.Path, -32)
		Event := DllCall("kernel32\CreateEventW", "Ptr", 0, "Int", true, "Int", false, "Str", EventName, "Ptr")
		AssertTrue(Event != 0 && A_LastError != 183, "the actual native progress event is exclusively allocated")
		; The actual Windows process writes two independent increments and remains
		; alive; file length alone cannot manufacture a native Job observation.
		Script := "$ErrorActionPreference='Stop';Start-Sleep -Milliseconds 200;"
			. "[IO.File]::WriteAllBytes('" . Path . "',[byte[]](1,2,3,4));$event=[Threading.EventWaitHandle]::OpenExisting('" . EventName . "');"
			. "try{if(!$event.WaitOne(30000)){throw 'Controlled progress acknowledgment expired.'}}finally{$event.Dispose()};"
			. "$f=[IO.File]::Open('" . Path . "',[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);"
			. "try{$b=[byte[]](5,6,7,8);$f.Write($b,0,4);$f.Flush($true)}finally{$f.Dispose()};"
			. "Start-Sleep -Milliseconds 30000"
		Worker := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-EncodedCommand", _Updater_EncodePowerShellCommand(Script)],
			, , ObjBindMethod(Capture, "OnNativeAdopt"))
		Capture.Attach(Worker)
		AssertEqual(0, Capture.ObserveBody(Worker, 16), "a not-started process cannot authorize a body")
		AssertTrue(Worker.start(), "the actual private Job writer starts")
		Start := A_TickCount
		First := 0
		Second := 0
		while !TickExpired64(Start, 10000) {
			_SR_TreePoll()
			Size := Capture.ObserveBody(Worker, 16)
			if Size > 0 && !First {
				First := Size
				AssertTrue(DllCall("kernel32\SetEvent", "Ptr", Event, "Int"), "native progress follows the actual first observation")
			}
			else if First && Size > First {
				Second := Size
				break
			}
			Sleep(10)
		}
		AssertEqual(4, First, "the first actual retained body contains the literal four-byte increment")
		AssertEqual(8, Second, "the same owned native body genuinely progresses")
		AssertEqual(0, Capture.ObserveBody({}, 16), "a foreign worker cannot borrow the owned native body")
		AssertEqual(0, Capture.ObserveBody(Worker, 8), "a completed-sized body is not incomplete")
		AssertTrue(Worker.terminate(), "the actual native Job retires before its captures")
		AssertEqual(0, Capture.ObserveBody(Worker, 16), "terminal state cannot authorize an incomplete body")
		AssertTrue(_Updater_RetireCurlCapture(Capture), "the physical native receipt authorizes exact capture retirement")
		AssertTrue(Capture.NativeState["TreeQuiesced"], "the real owner confirms native Job-empty and process exit")
		Claim := Capture.NativeState["TerminalClaim"]
		for Name in ["ProcessHandle", "ThreadHandle", "JobHandle"]
			AssertEqual(0, Claim[Name], "the exact native resource closes before file removal")
		AssertEqual(0, Claim["NativeErrors"].Length)
		AssertFalse(DirExist(Capture.Path))
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureFinishNativeFixture(Capture, Parent, Failed, Primary, 0, "", false, Event)
}
Test("updater curl capture: real native ownership admits only a progressing incomplete body", _CurlCaptureNativeBodyControls)

class _CurlCaptureNativeDownloadRun extends _UpdaterNativeDownloadRun {
	__New(Owner, Budget) {
		super.__New(Owner, "/updater/curl-slow", Budget, false)
		this.Capture := _UpdaterCurlCaptureLedger()
	}
	OnNativeAdopt(State, Native) {
		super.OnNativeAdopt(State, Native)
		this.Capture.OnNativeAdopt(State, Native)
	}
	Start() {
		global _VendorDir, _SharedDir, UPDATER_MIN_EXE_SIZE_BYTES
		this.Directory := _SR_AcquireCaptureDirectory()
		this.CurrentExe := this.Directory . "existing.exe"
		this.NewExe := this.Directory . "staged.exe"
		this.SwapPath := this.Directory . "swap.ps1"
		FileAppend(this.OldBytes, this.CurrentExe, "UTF-8-RAW")
		this.Capture.Acquire(this.Directory)
		Url := "https://managed-fixture.invalid:" . this.Owner.State["tls_port"] . this.Path
		this.StartedTick := A_TickCount
		this.Transport := _Updater_BuildStagingTransport(_Updater_BuildStagingWorkerScript(), this.SwapBytes,
			Url, this.Digest, this.NewExe, this.SwapPath, this.CurrentExe, UPDATER_MIN_EXE_SIZE_BYTES, 5000,
			_VendorDir . "\ergopti_updater_download.ps1", this.DeadlineMs, this.StartedTick,
			_SharedDir . "\modules\network\proxy_policy.json", _SharedDir . "\modules\updater\defaults.json", 524288)
		try {
			_Updater_BindCurlCaptureTransport(this.Transport, this.Capture)
			Proxy := "127.0.0.1:" . this.Owner.State["proxy_port"]
			Admission := '$reader={param($MaxBytes)[pscustomobject]@{Ok=$true;AutoDetect=$false;Absent=$false;PacUrl="";Proxy="' . Proxy . '";Bypass="";NativeError=0;FailureOrigin=""}};$environment={param($Name)return ""};'
			Bootstrap := Admission . this.Transport.Bootstrap . ' -ReadConfig $reader -ReadEnvironment $environment'
			this.Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
				["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", _Updater_EncodePowerShellCommand(Bootstrap)],
				ObjBindMethod(this, "OnDone"), , ObjBindMethod(this, "OnNativeAdopt"), 8192)
			this.Capture.Attach(this.Handle)
			AssertTrue(this.Handle.start(), "the actual authenticated curl Job starts with its parent-owned capture")
		} finally _Updater_ClearStagingTransport(this.Transport)
	}
	Retire() {
		if !_Updater_RetireCurlCapture(this.Capture)
			return false
		return super.Retire()
	}
}

_CurlCaptureNativeCancellation(Contract) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterDownloadRequest
	global _UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterInstallObserver, _UpdaterManagedFailureOwner, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	AssertFalse(_UpdaterDownloadInProgress, "native receiving cannot borrow a foreign updater transaction")
	Saved := [_UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterDownloadRequest,
		_UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch,
		_UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation,
		_UpdaterInstallObserver, _UpdaterManagedFailureOwner, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS]
	Fixture := _UpdaterNativeTransportOwner()
	Primary := 0
	Failed := false
	try {
		Fixture.Start("ServeUpdater")
		Fixture.ChangeTrust(true)
		for Kind in ["cancel", "deadline"] {
			Budget := Kind == "deadline" ? 15000 : 30000
			UPDATER_HTTP_DOWNLOAD_DEADLINE_MS := Budget
			Run := _CurlCaptureNativeDownloadRun(Fixture, Budget)
			Fixture.DownloadRuns.Push(Run)
			Run.Start()
			Phases := []
			Notice := {Count: 0}
			_UpdaterDownloadInProgress := true
			_UpdaterDownloadWorker := Run.Handle
			_UpdaterDownloadRequest := 0
			_UpdaterDownloadArtifacts := {NewExe: Run.NewExe, SwapScript: Run.SwapPath, CurlCapture: Run.Capture}
			_UpdaterDownloadStartedTick := Run.StartedTick
			Epoch := ++_UpdaterSelfUpdateEpoch
			_UpdaterSwapOwner := 0
			_UpdaterExitIntent := 0
			_UpdaterExitInvocation := 0
			_UpdaterManagedFailureOwner := 0
			_UpdaterInstallObserver := (Phase, Reason) => Phases.Push(Phase)
			Start := A_TickCount
			First := 0
			Second := 0
			while !TickExpired64(Start, 10000) && Run.Results.Length == 0 {
				_SR_TreePoll()
				Size := Run.Capture.ObserveBody(Run.Handle, 524288)
				if Size > 0 && !First
					First := Size
				else if First && Size > First {
					Second := Size
					break
				}
				Sleep(10)
			}
			AssertTrue(First > 0 && Second > First && Second < 524288 && Run.Results.Length == 0,
				"the exact retained curl body must actually progress while its native Job is live")
			AssertFalse(FileExist(Run.NewExe), "incomplete authenticated bytes are never published as NewExe")
			AssertEqual(Run.StartedTick, _UpdaterDownloadStartedTick, "all hops and parent retirement retain the original native clock")
			if Kind == "cancel"
				AssertTrue(_Updater_CancelSelfUpdateTransaction("Native curl capture cancellation.", false, false, Epoch))
			else {
				while !TickExpired64(Run.StartedTick, Budget) {
					_SR_TreePoll()
					Sleep(10)
				}
				AssertTrue(_Updater_EnforceDownloadDeadline(A_TickCount, false,
					(Message, Options) => Notice.Count += 1, _Updater_CancelSelfUpdateTransaction, Epoch))
				AssertEqual(1, Notice.Count, "the exact original deadline publishes one primary terminal")
			}
			Run.AssertCancelled()
			AssertTrue(Run.Capture.Retired, "parent capture retirement waits for the actual Job receipt")
			AssertFalse(DirExist(Run.Capture.Path), "hard termination leaves no exact parent-owned curl capture")
			AssertFalse(FileExist(Run.NewExe) || FileExist(Run.SwapPath), "no incomplete release or swap worker is published")
			for Name, Entry in Run.Capture.Files
				AssertEqual(0, Entry["handle"], "all four original capture handles physically close")
			AssertEqual(0, Run.Capture.Directory["handle"])
			AssertEqual(0, Run.Capture.ProbeCloseDebt.Length)
			AssertEqual(1, Phases.Length)
			AssertEqual("failed", Phases[1], "retirement cannot dispatch installing or restarting")
		}
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally {
		try _ManagedRemoteFixtureFinalize(Fixture, Failed, Primary, _UpdaterNative_Close.Bind(Fixture))
		finally {
			_UpdaterDownloadInProgress := Saved[1]
			_UpdaterDownloadWorker := Saved[2]
			_UpdaterDownloadRequest := Saved[3]
			_UpdaterDownloadArtifacts := Saved[4]
			_UpdaterDownloadStartedTick := Saved[5]
			_UpdaterSelfUpdateEpoch := Saved[6]
			_UpdaterSwapOwner := Saved[7]
			_UpdaterExitIntent := Saved[8]
			_UpdaterExitInvocation := Saved[9]
			_UpdaterInstallObserver := Saved[10]
			_UpdaterManagedFailureOwner := Saved[11]
			UPDATER_HTTP_DOWNLOAD_DEADLINE_MS := Saved[12]
		}
	}
}
Test("updater curl capture: actual progressing native body retires after cancellation and original deadline",
	(*) => _UpdaterNative_WithContract(_CurlCaptureNativeCancellation))

_CurlCaptureNativeDirectoryControls() {
	global _UpdaterCurlCaptureDebt, UPDATER_REQUEST_ORIGIN_MANUAL
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Failed := false
	Primary := 0
	Foreign := 0
	Moved := ""
	try {
		Capture.Acquire(Parent)
		Moved := Parent . "\moved-owned-directory"
		AssertTrue(DllCall("kernel32\MoveFileW", "Str", Capture.Path, "Str", Moved, "Int"),
			"the real retained owned directory can be moved without destroying its identities")
		AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Capture.Path, "Ptr", 0, "Int"))
		ForeignHandle := Capture.Open(Capture.Path, 0, 3, true)
		AssertTrue(ForeignHandle != 0)
		Foreign := Map("path", Capture.Path, "handle", ForeignHandle, "directory", true)
		AssertFalse(Capture.ValidatePaths(), "a foreign directory at the old path is not the retained capture")
		AssertFalse(_Updater_RetireCurlCapture(Capture), "missing paths with live unlinked originals retain ownership debt")
		AssertTrue(DirExist(Capture.Path) && DirExist(Moved), "both foreign and moved originals survive cleanup refusal")
		for Name, Entry in Capture.Files
			AssertTrue(Entry["handle"] != 0, "moved original native references remain inspectable")
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
		Outcome := _Updater_TryReserveDownloadTransaction(Request, false)
		AssertFalse(Outcome.Reserved, "an actual successor cannot reserve while capture debt survives")
		AssertTrue(Outcome.RecoveryBusy, "the actual production policy consumes retained capture debt")
		AssertTrue(Capture.RetireEntry(Foreign), "only its independent native owner can retire the foreign directory")
		AssertTrue(DllCall("kernel32\MoveFileW", "Str", Moved, "Str", Capture.Path, "Int"))
		Moved := ""
		AssertTrue(_Updater_RetireCurlCapture(Capture), "restored exact native directory identity permits retirement")
		AssertFalse(_UpdaterCurlCaptureDebt.Has(ObjPtr(Capture)))
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureFinishNativeFixture(Capture, Parent, Failed, Primary, Foreign, Moved, true)
}
Test("updater curl capture: moved and foreign native directories block a successor until exact restoration",
	_CurlCaptureNativeDirectoryControls)

_CurlCaptureProductionJoinControls() {
	global _VendorDir, _SharedDir, UPDATER_MIN_EXE_SIZE_BYTES
	Start := _DriverFuncBody("_Updater_StartStagingWorker")
	Cancel := _DriverFuncBody("_Updater_CancelSelfUpdateTransaction")
	Complete := _DriverFuncBody("_Updater_PollDownloadAsync")
	Reserve := _DriverFuncBody("_Updater_TryReserveDownloadTransaction")
	AssertTrue(Start != "" && Cancel != "" && Complete != "" && Reserve != "",
		"all actual production lifecycle owners must be read nonvacuously")
	AssertContains(Start, "Capture.Acquire(CaptureParent)", "the parent allocates before a worker can start")
	AssertContains(Start, "_Updater_BindCurlCaptureTransport(Transport, Capture)")
	AssertContains(Start, "Capture.Attach(Worker)")
	AssertTrue(InStr(Start, "Capture.Attach(Worker)") < InStr(Start, "Worker.start()"),
		"the exact tree owner transfers before native launch")
	AssertContains(Cancel, "CaptureClosed := _Updater_RetireCurlCaptureArtifacts(Artifacts)")
	AssertContains(Complete, "_Updater_RetireCurlCaptureArtifacts(_UpdaterDownloadArtifacts)")
	AssertContains(Reserve, "_UpdaterCurlCaptureDebt.Count != 0", "successors cannot borrow capture cleanup debt")
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Transport := 0
	Failed := false
	Primary := 0
	Foreign := 0
	Moved := ""
	try {
		Capture.Acquire(Parent)
		Transport := _Updater_BuildStagingTransport(_Updater_BuildStagingWorkerScript(), "exit 0",
			"https://github.com/adrienm7/ergopti/releases/download/v9.8.7/ErgoptiPlus.exe",
			"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			Parent . "\staged.exe", Parent . "\swap.ps1", Parent . "\existing.exe", UPDATER_MIN_EXE_SIZE_BYTES,
			5000, _VendorDir . "\ergopti_updater_download.ps1", 30000, A_TickCount,
			_SharedDir . "\modules\network\proxy_policy.json", _SharedDir . "\modules\updater\defaults.json", 524288)
		_Updater_BindCurlCaptureTransport(Transport, Capture)
		Found := 0
		for Pair in Transport.Environment {
			if InStr(Pair.Name, "_CURL_CAPTURE") {
				Found += 1
				AssertEqual(Capture.Path, Pair.Value, "the retained native directory travels as exact private data")
				AssertEqual(Capture.Path, EnvGet(Pair.Name), "the actual worker environment inherits that same value")
			}
		}
		AssertEqual(1, Found, "the source binder transfers one original capture")
		AssertContains(Transport.Bootstrap, " -OwnedCaptureDirectory $env:")
		AssertFalse(InStr(Transport.Bootstrap, Capture.Path), "capture paths never become script interpolation")
		AssertThrows(() => _Updater_BindCurlCaptureTransport(Transport, Capture),
			"duplicate ownership transfer is refused")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally {
		_Updater_ClearStagingTransport(Transport)
		_CurlCaptureFinishNativeFixture(Capture, Parent, Failed, Primary)
	}
}
Test("updater curl capture: actual production lifecycle and private builder retain exact native ownership",
	_CurlCaptureProductionJoinControls)

_CurlCaptureFinishNativeFixture(Capture, Parent, Failed, Primary, Foreign := 0, Moved := "", Directory := false, Event := 0) {
	CleanupFailure := 0
	Capture.FixtureCleanupContext := Map("foreign", Foreign, "moved", Moved, "event", Event, "parent", Parent)
	try {
		if Foreign is Map && !Capture.RetireEntry(Foreign)
			throw Error("Independent native foreign fixture retirement was refused.")
		if Moved != "" {
			Entry := Directory ? Capture.Directory : Capture.Files["artifact.bin"]
			Probe := Capture.Open(Moved, 0, 3, Directory)
			if !Probe
				throw Error("Moved original fixture identity was unavailable.")
			try {
				if !Capture.Same(Capture.Snapshot(Entry["handle"]), Capture.Snapshot(Probe))
					throw Error("Moved original fixture identity was refused.")
			} finally Capture.CloseProbe(Probe)
			if Capture.ProbeCloseDebt.Length || FileExist(Entry["path"])
				throw Error("Original fixture path cannot replace an unowned entry.")
			if !DllCall("kernel32\MoveFileW", "Str", Moved, "Str", Entry["path"], "Int")
				throw Error("Exact moved fixture restoration was refused.")
		}
		if !_Updater_RetireCurlCapture(Capture)
			throw Error("Native capture fixture retained physical or identity debt.")
		if Event && !DllCall("kernel32\CloseHandle", "Ptr", Event, "Int")
			throw Error("Native progress event retirement was refused.")
		DirDelete(Parent, false)
		Capture.FixtureCleanupContext := 0
	} catch Any as Failure {
		CleanupFailure := Failure
	}
	if Failed
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

; The literal counterexample transplants original file identities into a foreign
; directory, or aliases them through a foreign junction. Neither may lend the
; original namespace to body observation or deletion.
_CurlCaptureNativeHybridNamespace(UseJunction := false) {
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Foreign := 0
	ReparseOwner := 0
	Moved := ""
	Worker := 0
	Failed := false
	Primary := 0
	try {
		Capture.Acquire(Parent)
		Path := StrReplace(Capture.Files["artifact.bin"]["path"], "'", "''")
		Script := "$ErrorActionPreference='Stop';[IO.File]::WriteAllBytes('" . Path
			. "',[byte[]](1,2,3,4));Start-Sleep -Milliseconds 30000"
		Worker := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-EncodedCommand", _Updater_EncodePowerShellCommand(Script)],
			, , ObjBindMethod(Capture, "OnNativeAdopt"))
		Capture.Attach(Worker)
		AssertTrue(Worker.start(), "the actual owned native writer starts")
		Start := A_TickCount
		while !TickExpired64(Start, 10000) && Capture.ObserveBody(Worker, 16) != 4 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(4, Capture.ObserveBody(Worker, 16), "the original namespace admits the actual four-byte body")
		Moved := Parent . "\moved-original-namespace"
		AssertTrue(DllCall("kernel32\MoveFileW", "Str", Capture.Path, "Str", Moved, "Int"))
		AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Capture.Path, "Ptr", 0, "Int"))
		Foreign := Map("path", Capture.Path, "handle", 0, "directory", true)
		ForeignHandle := Capture.Open(Capture.Path, 0, 3, true)
		Foreign["handle"] := ForeignHandle
		AssertTrue(ForeignHandle != 0, "the independently created foreign namespace owns a retained native handle")
		if UseJunction {
			ReparseOwner := Capture.Open(Capture.Path, 0x40000000, 3, true)
			AssertTrue(ReparseOwner != 0, "the actual reparse operation owns its exact writable directory handle")
			_CurlCaptureSetNativeJunction(ReparseOwner, Moved)
		} else {
			for Name, Entry in Capture.Files
				AssertTrue(DllCall("kernel32\MoveFileW", "Str", Moved . "\" . Name, "Str", Entry["path"], "Int"),
					"the real original file identity is transplanted into the foreign namespace")
		}
		; Every child still resolves to its original volume/file ID. This proves
		; the counterexample cannot be rejected by file-only identity checks.
		for Name, Entry in Capture.Files {
			Probe := Capture.Open(Entry["path"], 0, 3, false)
			AssertTrue(Probe != 0)
			try AssertTrue(Capture.Same(Capture.Snapshot(Entry["handle"]), Capture.Snapshot(Probe)),
				"the child file identity is genuine despite its foreign namespace")
			finally AssertTrue(Capture.CloseProbe(Probe))
		}
		Observed := Capture.ObserveBody(Worker, 16)
		Closed := _Updater_RetireCurlCapture(Capture)
		AssertEqual(0, Observed, "foreign namespace admission precedes the otherwise valid live-body observation")
		AssertFalse(Closed, "the foreign namespace refuses retirement before any original file is deleted")
		AssertTrue(Capture.NativeState["TreeQuiesced"], "the exact worker still retires physically before namespace refusal")
		for Name, Entry in Capture.Files {
			AssertTrue(Entry["handle"] != 0 && !Entry.Get("retired", false), "every original file handle survives refusal")
			AssertTrue(FileExist(Entry["path"]), "every original file survives the foreign-namespace refusal")
		}
		Body := FileRead(Capture.Files["artifact.bin"]["path"], "RAW")
		AssertEqual(4, Body.Size)
		AssertEqual(0x04030201, NumGet(Body, 0, "UInt"), "the original literal bytes survive namespace refusal")
		AssertTrue(DirExist(Moved) && DirExist(Capture.Path), "neither directory is deleted under the other's authority")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureFinishHybridNamespace(Capture, Parent, Failed, Primary, Foreign, Moved, UseJunction, ReparseOwner)
}
Test("updater curl capture: transplanted original file identities cannot borrow a foreign directory",
	_CurlCaptureNativeHybridNamespace)
Test("updater curl capture: a real foreign junction cannot lend the original namespace",
	_CurlCaptureNativeHybridNamespace.Bind(true))

_CurlCaptureNativeHeldNamespaceLease() {
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Lease := 0
	Failed := false
	Primary := 0
	try {
		Capture.Acquire(Parent)
		Lease := Capture.AcquireDirectoryLease()
		AssertTrue(Lease != 0, "the native admission retains the exact directory with FILE_SHARE_DELETE excluded")
		Moved := Parent . "\rename-refused-while-leased"
		AssertFalse(DllCall("kernel32\MoveFileW", "Str", Capture.Path, "Str", Moved, "Int"),
			"an actual directory rename is fenced throughout the held admission")
		AssertTrue(DirExist(Capture.Path) && !DirExist(Moved), "the lease preserves the named original namespace")
		; Receive a genuine partial retirement before retrying the remaining
		; entries. A missing already-retired file cannot invalidate the namespace.
		AssertTrue(Capture.RetireEntry(Capture.Files["headers.bin"]))
		AssertFalse(FileExist(Capture.Files["headers.bin"]["path"]))
		AssertFalse(Capture.ValidatePaths(), "initial all-file binding cannot masquerade as a partial retry")
		AssertTrue(Capture.CloseProbe(Lease))
		Lease := 0
		AssertTrue(_Updater_RetireCurlCapture(Capture), "a directory-only lease admits remaining deletion on partial retry")
		AssertFalse(DirExist(Capture.Path))
		for Name, Entry in Capture.Files
			AssertEqual(0, Entry["handle"], "every exact original handle closes once after the partial retry")
		AssertEqual(0, Capture.Directory["handle"])
		AssertEqual(0, Capture.ProbeCloseDebt.Length)
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally {
		if Lease && !Capture.CloseProbe(Lease) && !Failed {
			Failed := true
			Primary := Error("Native fixture directory lease closure was refused.")
		}
		_CurlCaptureFinishNativeFixture(Capture, Parent, Failed, Primary)
	}
}
Test("updater curl capture: held native namespace prevents rename and preserves partial retirement retry",
	_CurlCaptureNativeHeldNamespaceLease)

; Public SDK mount-point reparse ABI. The caller retains the exact directory
; it created; no global privilege, symlink setting or foreign path is modified.
_CurlCaptureSetNativeJunction(Handle, Target) {
	Substitute := "\??\" . Target
	SubstituteBytes := (StrPut(Substitute, "UTF-16") - 1) * 2
	PrintBytes := (StrPut(Target, "UTF-16") - 1) * 2
	Paths := SubstituteBytes + 2 + PrintBytes + 2
	Data := Buffer(16 + Paths, 0)
	NumPut("UInt", 0xA0000003, "UShort", 8 + Paths, Data, 0)
	NumPut("UShort", 0, "UShort", SubstituteBytes, "UShort", SubstituteBytes + 2, "UShort", PrintBytes, Data, 8)
	StrPut(Substitute, Data.Ptr + 16, SubstituteBytes // 2 + 1, "UTF-16")
	StrPut(Target, Data.Ptr + 16 + SubstituteBytes + 2, PrintBytes // 2 + 1, "UTF-16")
	Returned := 0
	if !DllCall("kernel32\DeviceIoControl", "Ptr", Handle, "UInt", 0x900A4, "Ptr", Data,
		"UInt", Data.Size, "Ptr", 0, "UInt", 0, "UInt*", &Returned, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Owned native junction creation was refused.")
}

_CurlCaptureRemoveNativeJunction(Handle) {
	Data := Buffer(8, 0)
	NumPut("UInt", 0xA0000003, Data, 0)
	Returned := 0
	if !DllCall("kernel32\DeviceIoControl", "Ptr", Handle, "UInt", 0x900AC, "Ptr", Data,
		"UInt", Data.Size, "Ptr", 0, "UInt", 0, "UInt*", &Returned, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Owned native junction restoration was refused.")
}

_CurlCaptureFinishHybridNamespace(Capture, Parent, Failed, Primary, Foreign, Moved, Junction, ReparseOwner) {
	global _UpdaterCurlCaptureDebt
	_UpdaterCurlCaptureDebt[ObjPtr(Capture)] := Capture
	CleanupFailure := 0
	Capture.FixtureCleanupContext := Map("foreign", Foreign, "moved", Moved, "junction", Junction,
		"reparse_owner", ReparseOwner, "parent", Parent)
	try {
		if IsObject(Capture.Worker) && !Capture.Worker.terminate()
			throw Error("Hybrid namespace fixture retained its actual native worker.")
		if Foreign is Map {
			if Junction && ReparseOwner {
				_CurlCaptureRemoveNativeJunction(ReparseOwner)
				if !Capture.CloseProbe(ReparseOwner)
					throw Error("Hybrid namespace reparse owner closure was refused.")
				ReparseOwner := 0
			} else if !Junction {
				for Name, Entry in Capture.Files {
					if Entry.Get("retired", false) && !Entry["handle"]
						continue
					Probe := Capture.Open(Entry["path"], 0, 3, false, 3)
					if !Probe
						throw Error("Transplanted original fixture identity was unavailable.")
					try {
						if !Capture.Same(Capture.Snapshot(Entry["handle"]), Capture.Snapshot(Probe))
							throw Error("Transplanted original fixture identity was refused.")
					} finally Capture.CloseProbe(Probe)
					if Capture.ProbeCloseDebt.Length || FileExist(Moved . "\" . Name)
						throw Error("Transplanted original fixture restoration was refused.")
					if !DllCall("kernel32\MoveFileW", "Str", Entry["path"], "Str", Moved . "\" . Name, "Int")
						throw Error("Exact transplanted fixture restoration was refused.")
				}
			}
		}
		_CurlCaptureFinishNativeFixture(Capture, Parent, false, 0, Foreign, Moved, true)
	} catch Any as Failure {
		CleanupFailure := Failure
	}
	if Failed
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}
