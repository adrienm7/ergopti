; tests/unit/modules/updater/test_updater_curl_capture.ahk
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
			["-NoProfile", "-NonInteractive", "-EncodedCommand", _UpdaterTestEncodedCommand(Script)],
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
		this.Transport := _Updater_BuildStagingTransport(_Updater_StagingWorkerPath(), _Updater_SwapWorkerPath(),
			Url, this.Digest, this.NewExe, this.SwapPath, this.CurrentExe, UPDATER_MIN_EXE_SIZE_BYTES, 5000,
			_VendorDir . "\ergopti_updater_download.ps1", this.DeadlineMs, this.StartedTick,
			_SharedDir . "\modules\network\proxy_policy.json", _SharedDir . "\modules\updater\defaults.json", 524288)
		try {
			_Updater_BindCurlCaptureTransport(this.Transport, this.Capture)
			Proxy := "127.0.0.1:" . this.Owner.State["proxy_port"]
			Admission := '$reader={param($MaxBytes)[pscustomobject]@{Ok=$true;AutoDetect=$false;Absent=$false;PacUrl="";Proxy="' . Proxy . '";Bypass="";NativeError=0;FailureOrigin=""}};$environment={param($Name)return ""};'
			this.StagingBootstrapPath := this.Directory . "staging-bootstrap.ps1"
			this.Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
				_UpdaterNativeStagingBootstrapArgs(this.Transport, this.StagingBootstrapPath, Admission),
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
	global _UpdaterInstallObserverEpoch
	AssertFalse(_UpdaterDownloadInProgress, "native receiving cannot borrow a foreign updater transaction")
	SavedObserverEpoch := _UpdaterInstallObserverEpoch
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
			; Match the receipt retained by the real reservation before worker publication.
			_UpdaterDownloadArtifacts.InstallObservation := {
				Observer: _UpdaterInstallObserver, Epoch: _UpdaterInstallObserverEpoch}
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
			_UpdaterInstallObserverEpoch := SavedObserverEpoch
			_UpdaterManagedFailureOwner := Saved[11]
			UPDATER_HTTP_DOWNLOAD_DEADLINE_MS := Saved[12]
		}
	}
}
Test("updater curl capture: actual progressing native body retires after cancellation and original deadline",
	(*) => _UpdaterNative_WithContract(_CurlCaptureNativeCancellation))

; Windows cannot rename a directory containing open descendant files. Stage
; those exact originals outside it first; retained metadata identities never
; close, and every mutation uses a proved DELETE-capable handle without replace.
global _CurlCaptureDirectoryMoveFixtureDebt := Map()

class _CurlCaptureDirectoryMoveFixture {
	__New(Capture, Source, Target, Parent) {
		global _CurlCaptureDirectoryMoveFixtureDebt
		if Capture.HasOwnProp("FixtureDirectoryMove") && IsObject(Capture.FixtureDirectoryMove)
			throw Error("Exact directory move fixture already retains transition debt.")
		this.Capture := Capture
		this.Source := Source
		this.Target := Target
		this.Parent := Parent
		this.RootPath := Source
		this.Holding := 0
		this.HoldingPath := ""
		this.HoldingCreated := false
		this.HoldingLease := 0
		this.PlacementLease := 0
		this.StageLease := 0
		this.Extras := Map()
		this.Locations := Map()
		this.Identities := Map("root", Capture.Snapshot(Capture.Directory["handle"]))
		this.Closed := false
		this.Running := false
		_CurlCaptureHandleRenameBuffer(Source, Parent, 3, 0)
		_CurlCaptureHandleRenameBuffer(Target, Parent, 3, 0)
		for Name, Entry in Capture.Files {
			this.Identities[Name] := Capture.Snapshot(Entry["handle"])
			this.Locations[Name] := Source . "\" . Name
		}
		if Capture.Files.Count != 4 || Capture.ProbeCloseDebt.Length || Capture.Running || Capture.Retired
			throw Error("Exact directory move fixture admission was refused.")
		; Retain fixture transition debt separately from production process and
		; retirement state. Fixture finally must settle this exact owner first.
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			Capture.FixtureDirectoryMove := this
			_CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] := this
		} finally Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	Execute() {
		PreviousCritical := A_IsCritical
		Critical("On")
		Started := false
		try {
			this.Begin()
			Started := true
			if this.Exists(this.Target)
				throw Error("Exact directory move fixture target is unavailable.")
			this.OpenOriginals()
			this.AllocateHolding()
			this.StageChildren()
			this.MoveRoot(this.Target)
			this.PlaceChildren(this.Target)
			this.Finish()
			return true
		} finally {
			if Started
				this.Running := false
			Critical(PreviousCritical ? PreviousCritical : "Off")
		}
	}
	Rollback() {
		PreviousCritical := A_IsCritical
		Critical("On")
		Started := false
		try {
			this.Begin()
			Started := true
			this.ClosePlacementLease()
			this.OpenOriginals()
			if this.HoldingCreated {
				if !(this.Holding is Map) || !this.Holding.Get("handle", 0)
					throw Error("Exact holding-directory authority remains unproven.")
				this.StageChildren()
				if this.RootPath != this.Source
					this.MoveRoot(this.Source)
				this.PlaceChildren(this.Source)
			}
			this.Finish()
			return this.Source
		} finally {
			if Started
				this.Running := false
			Critical(PreviousCritical ? PreviousCritical : "Off")
		}
	}
	Begin() {
		this.EnsureOwner()
		if this.Running || this.Closed
			throw Error("Exact directory move fixture is already running or closed.")
		this.Running := true
	}
	OpenOriginals() {
		this.Prove("root", this.Capture.Directory["handle"])
		for Name, Path in this.Locations
			this.OpenOriginal(Name, Path, false)
	}
	OpenOriginal(Name, Path, Directory) {
		if !this.Extras.Has(Name) || !this.Extras[Name] {
			Handle := this.Open(Path, 0x10000, Directory)
			if !Handle
				throw Error("Exact directory move DELETE handle was refused.")
			this.Extras[Name] := Handle
		}
		this.Prove(Name, this.Extras[Name])
	}
	Prove(Name, Handle) {
		this.EnsureOwner()
		Capture := this.Capture
		Retained := Name == "root" ? Capture.Directory["handle"] : Capture.Files[Name]["handle"]
		Original := this.Identities[Name]
		Actual := Capture.Snapshot(Handle)
		if Capture.ProbeCloseDebt.Length || !Capture.Same(Original, Capture.Snapshot(Retained))
			|| !Capture.Same(Original, Actual) || Actual["delete_pending"]
			|| (Name != "root" && Actual["links"] != 1)
			throw Error("Exact directory move native identity was refused.")
	}
	AllocateHolding() {
		this.HoldingPath := this.NewHoldingPath()
		if !this.Create(this.HoldingPath)
			throw Error("Exact holding-directory allocation was refused.")
		this.HoldingCreated := true
		this.Holding := Map("path", this.HoldingPath, "handle", 0, "directory", true)
		this.Holding["handle"] := this.Open(this.HoldingPath, 0, true)
		if !this.Holding["handle"] || !this.Capture.Snapshot(this.Holding["handle"]).Get("ok", false)
			throw Error("Exact holding-directory identity was refused.")
		this.HoldingIdentity := this.Capture.Snapshot(this.Holding["handle"])
		this.HoldingLease := this.Open(this.HoldingPath, 0, true, 3)
		if !this.HoldingLease || !this.Capture.Same(this.HoldingIdentity, this.Capture.Snapshot(this.HoldingLease))
			throw Error("Exact holding-directory namespace lease was refused.")
	}
	StageChildren() {
		if this.Extras.Has("root") && this.Extras["root"] {
			if !this.Close(this.Extras["root"])
				throw Error("Exact directory DELETE-handle closure was refused.")
			this.Extras["root"] := 0
		}
		; A genuine sharing3 namespace lease, rather than a production-state
		; flag, excludes timer retirement during a partial staging refusal.
		if !this.StageLease
			this.StageLease := this.Open(this.RootPath, 0, true, 3)
		if !this.StageLease
			throw Error("Exact staging namespace lease was refused.")
		this.Prove("root", this.StageLease)
		if !this.Capture.Same(this.HoldingIdentity, this.Capture.Snapshot(this.Holding["handle"]))
			throw Error("Exact holding-directory identity changed.")
		for Name, Path in this.Locations {
			Destination := this.HoldingPath . "\" . Name
			if Path != Destination
				this.MoveChild(Name, Destination)
		}
		if !this.Close(this.StageLease)
			throw Error("Exact staging namespace lease closure was refused.")
		this.StageLease := 0
	}
	PlaceChildren(Directory) {
		if this.Extras.Has("root") && this.Extras["root"] {
			if !this.Close(this.Extras["root"])
				throw Error("Exact directory DELETE-handle closure was refused.")
			this.Extras["root"] := 0
		}
		; Access-zero sharing3 binds the destination namespace without a DELETE
		; request that could conflict with the filesystem's target-parent open.
		this.PlacementLease := this.Open(Directory, 0, true, 3)
		if !this.PlacementLease
			throw Error("Exact destination namespace lease was refused.")
		this.Prove("root", this.PlacementLease)
		for Name, Path in this.Locations {
			Destination := Directory . "\" . Name
			if Path != Destination
				this.MoveChild(Name, Destination)
		}
	}
	MoveChild(Name, Destination) => this.Commit("child", Name, Destination)
	MoveRoot(Destination) {
		this.OpenOriginal("root", this.RootPath, true)
		this.Commit("root", "root", Destination)
	}
	Commit(Kind, Name, Destination) {
		; Native return and its exact location publication are one fixture step.
		; Timer reentry cannot observe an unrecorded physical rename commitment.
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			this.Prove(Name, this.Extras[Name])
			if this.Exists(Destination) || !this.Rename(this.Extras[Name], Destination)
				throw Error("Exact retained " . Kind . " move was refused.")
			if Kind == "root"
				this.RootPath := Destination
			else
				this.Locations[Name] := Destination
			this.Prove(Name, this.Extras[Name])
		} finally Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	Finish() {
		global _CurlCaptureDirectoryMoveFixtureDebt
		this.ClosePlacementLease()
		for Name, Handle in this.Extras {
			if Handle {
				this.Prove(Name, Handle)
				if !this.Close(Handle)
					throw Error("Exact directory move handle closure was refused.")
				this.Extras[Name] := 0
			}
		}
		if this.HoldingLease {
			if !this.Close(this.HoldingLease)
				throw Error("Exact holding namespace lease closure was refused.")
			this.HoldingLease := 0
		}
		if this.Holding is Map && !this.RemoveHolding(this.Holding)
			throw Error("Exact empty holding-directory retirement was refused.")
		this.EnsureOwner()
		this.Closed := true
		this.Capture.FixtureDirectoryMove := 0
		_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(this.Capture))
	}
	ClosePlacementLease() {
		if this.PlacementLease {
			if !this.Close(this.PlacementLease)
				throw Error("Exact destination namespace lease closure was refused.")
			this.PlacementLease := 0
		}
	}
	EnsureOwner() {
		global _CurlCaptureDirectoryMoveFixtureDebt
		if !_CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(this.Capture))
			|| _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(this.Capture)] != this
			|| !this.Capture.HasOwnProp("FixtureDirectoryMove") || this.Capture.FixtureDirectoryMove != this
			|| this.Capture.ProbeCloseDebt.Length
			throw Error("Exact directory move fixture owner or physical closure was refused.")
	}
	NewHoldingPath() {
		Guid := Buffer(16, 0)
		if DllCall("ole32\CoCreateGuid", "Ptr", Guid, "Int") != 0
			throw Error("Exact holding-directory nonce allocation was refused.")
		Nonce := ""
		loop 16
			Nonce .= Format("{:02x}", NumGet(Guid, A_Index - 1, "UChar"))
		return this.Parent . "\holding." . Nonce
	}
	Open(Path, Access, Directory, Sharing := 7) => this.Capture.Open(Path, Access, 3, Directory, Sharing)
	Exists(Path) => FileExist(Path) != ""
	Create(Path) => DllCall("kernel32\CreateDirectoryW", "Str", Path, "Ptr", 0, "Int")
	Close(Handle) => this.Capture.CloseProbe(Handle)
	RemoveHolding(Entry) => this.Capture.RetireEntry(Entry)
	Rename(Handle, Destination) {
		SplitPath(Destination, , &Parent)
		Data := _CurlCaptureHandleRenameBuffer(Destination, Parent, 3, 0)
		return DllCall("kernel32\SetFileInformationByHandle", "Ptr", Handle,
			"Int", 3, "Ptr", Data, "UInt", Data.Size, "Int")
	}
}

_CurlCaptureMoveRetainedDirectory(Capture, Source, Target, Parent) {
	Owner := _CurlCaptureDirectoryMoveFixture(Capture, Source, Target, Parent)
	return Owner.Execute()
}

_CurlCaptureRollbackDirectoryMove(Capture) {
	if Capture.HasOwnProp("FixtureDirectoryMove") && IsObject(Capture.FixtureDirectoryMove)
		return Capture.FixtureDirectoryMove.Rollback()
	return ""
}

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
		AssertTrue(_CurlCaptureMoveRetainedDirectory(Capture, Capture.Path, Moved, Parent),
			"the real retained owned directory can be moved without destroying its identities")
		AssertFalse(Capture.Running, "fixture setup leaves the genuine production retirement state unchanged")
		AssertEqual(0, Capture.FixtureDirectoryMove, "the complete native setup has no pending fixture transition")
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
		AssertTrue(_CurlCaptureMoveRetainedDirectory(Capture, Moved, Capture.Path, Parent))
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
		Transport := _Updater_BuildStagingTransport(_Updater_StagingWorkerPath(), _Updater_SwapWorkerPath(),
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
		AssertEqual(Transport.Prefix . "_CURL_CAPTURE", Transport.Environment[Transport.Environment.Length].Name,
			"the capture is published under the prefix the -File worker receives")
		for Arg in Transport.Args
			AssertFalse(InStr(Arg, Capture.Path), "capture paths never become worker arguments")
		AssertContains(FileRead(_Updater_StagingWorkerPath(), "UTF-8"),
			'$OwnedCaptureDirectory = Read-ErgoptiStagingInput "CURL_CAPTURE" $false',
			"the bundled worker reads the capture as private data")
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
