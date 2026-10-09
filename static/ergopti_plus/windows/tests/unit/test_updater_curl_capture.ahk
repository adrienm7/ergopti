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
		OriginalSource := _CurlCaptureRollbackDirectoryMove(Capture)
		if Directory && OriginalSource == Capture.Directory["path"] {
			Moved := ""
			Capture.FixtureCleanupContext["moved"] := ""
		}
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
			Restored := Directory ? _CurlCaptureMoveRetainedDirectory(Capture, Moved, Entry["path"], Parent)
				: DllCall("kernel32\MoveFileW", "Str", Moved, "Str", Entry["path"], "Int")
			if !Restored
				throw Error("Exact moved fixture restoration was refused.")
			Capture.FixtureCleanupContext["moved"] := ""
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
		AssertTrue(_CurlCaptureMoveRetainedDirectory(Capture, Capture.Path, Moved, Parent))
		AssertFalse(Capture.Running, "fixture setup leaves the genuine production retirement state unchanged")
		AssertEqual(0, Capture.FixtureDirectoryMove, "the complete native setup has no pending fixture transition")
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
		ChildIndex := 0
		for Name, Entry in Capture.Files {
			ChildIndex += 1
			Probe := Capture.Open(Entry["path"], 0, 3, false)
			ProbeError := Probe ? 0 : A_LastError
			if UseJunction && !Probe
				_CurlCaptureReportJunctionProbe(ReparseOwner, Moved, ChildIndex, ProbeError)
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

; A declared UTF-16 field must match all bytes, including any embedded NUL.
; This pure projection conveys no namespace, file or process authority.
_CurlCaptureJunctionTargetMatches(Data, Returned, Target) {
	if !(Data is Buffer) || !(Returned is Integer) || !(Target is String) || Target == ""
		|| Data.Size > 16384 || Returned < 16 || Returned > Data.Size
		|| NumGet(Data, 0, "UInt") != 0xA0000003
		return false
	Length := NumGet(Data, 4, "UShort")
	SubstituteOffset := NumGet(Data, 8, "UShort")
	SubstituteLength := NumGet(Data, 10, "UShort")
	PrintOffset := NumGet(Data, 12, "UShort")
	PrintLength := NumGet(Data, 14, "UShort")
	if Length < 8 || Length + 8 > Returned
		|| Mod(SubstituteOffset, 2) != 0 || Mod(SubstituteLength, 2) != 0
		|| Mod(PrintOffset, 2) != 0 || Mod(PrintLength, 2) != 0
		|| SubstituteOffset + SubstituteLength > Length - 8
		|| PrintOffset + PrintLength > Length - 8
		|| SubstituteLength != StrLen("\??\" . Target) * 2 || PrintLength != StrLen(Target) * 2
		return false
	return StrGet(Data.Ptr + 16 + SubstituteOffset, -(SubstituteLength // 2), "UTF-16") == ("\??\" . Target)
		&& StrGet(Data.Ptr + 16 + PrintOffset, -(PrintLength // 2), "UTF-16") == Target
}

; Failure-only native facts never lend reparse or path observation as capture
; authority. Read the exact retained reparse owner, keep the original child-open
; errno, emit only fixed scalars, and leave the original strict assertion intact.
_CurlCaptureReportJunctionProbe(Handle, Target, Child, OpenError) {
	if !Handle || !(Child is Integer) || Child < 1 || Child > 4
		|| !(OpenError is Integer) || OpenError < 0 || OpenError > 0xFFFFFFFF
		return false
	try {
		Data := Buffer(16384, 0)
		Returned := 0
		Read := DllCall("kernel32\DeviceIoControl", "Ptr", Handle, "UInt", 0x900A8,
			"Ptr", 0, "UInt", 0, "Ptr", Data, "UInt", Data.Size,
			"UInt*", &Returned, "Ptr", 0, "Int")
		ReadError := Read ? 0 : A_LastError
		Matches := Read && _CurlCaptureJunctionTargetMatches(Data, Returned, Target)
		_TestAppendProgress("# curl_junction_probe child=" . Child . " open_errno=" . OpenError
			. " target_exists=" . (DirExist(Target) ? 1 : 0) . " reparse_read=" . (Read ? 1 : 0)
			. " reparse_match=" . (Matches ? 1 : 0) . " reparse_errno=" . ReadError)
		return true
	} catch {
		; Diagnostics may be unavailable; never replace the primary assertion.
		return false
	}
}

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
		OriginalSource := _CurlCaptureRollbackDirectoryMove(Capture)
		if OriginalSource == Capture.Directory["path"] {
			Moved := ""
			Capture.FixtureCleanupContext["moved"] := ""
		}
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
					AlreadyMoved := Moved . "\" . Name
					if FileExist(AlreadyMoved) {
						Probe := Capture.Open(AlreadyMoved, 0, 3, false, 3)
						if !Probe
							throw Error("Partially transplanted original identity was unavailable.")
						try {
							if !Capture.Same(Capture.Snapshot(Entry["handle"]), Capture.Snapshot(Probe))
								throw Error("Partially transplanted original identity was refused.")
						} finally Capture.CloseProbe(Probe)
						if Capture.ProbeCloseDebt.Length
							throw Error("Partially transplanted probe closure was refused.")
						continue
					}
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


; Additive native receiving only: a denied setup does not qualify any of the
; original replacement/transplant/junction assertions. Every phase reports only
; fixed scalar facts, and the original eight controls remain unchanged.
global _CurlCaptureMoveProbeFixtureDebt := Map()

_CurlCaptureMoveProbeEmptyDirectory(HeldRoot := false) {
	global _CurlCaptureMoveProbeFixtureDebt
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Owner := _UpdaterCurlCaptureLedger()
	Source := Parent . "\empty-original"
	Target := Parent . "\empty-moved"
	Entry := 0
	Failed := false
	Primary := 0
	CleanupFailure := 0
	Context := Map("parent", Parent, "source", Source, "target", Target, "owner", Owner, "entry", 0)
	_CurlCaptureMoveProbeFixtureDebt[ObjPtr(Owner)] := Context
	try {
		AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Source, "Ptr", 0, "Int"))
		Entry := Map("path", Source, "handle", Owner.Open(Source, 0, 3, true), "directory", true)
		Context["entry"] := Entry
		AssertTrue(Entry["handle"] != 0)
		Original := Owner.Snapshot(Entry["handle"])
		Context["original"] := Original
		AssertTrue(Original.Get("ok", false) && Original["directory"] && !Original["delete_pending"])
		if !HeldRoot {
			AssertTrue(Owner.CloseProbe(Entry["handle"]), "the positive control has no retained handle during rename")
			Entry["handle"] := 0
		}
		BeforeSource := DirExist(Source) != ""
		BeforeTarget := DirExist(Target) != ""
		AssertTrue(BeforeSource && !BeforeTarget, "the independent same-parent positive control is exclusive")
		DllCall("kernel32\SetLastError", "UInt", 0)
		Moved := DllCall("kernel32\MoveFileW", "Str", Source, "Str", Target, "Int")
		MoveError := A_LastError
		AfterSource := DirExist(Source) != ""
		AfterTarget := DirExist(Target) != ""
		Phase := HeldRoot ? "root_only" : "empty"
		HeldSame := HeldRoot && Owner.Same(Original, Owner.Snapshot(Entry["handle"]))
		_TestAppendProgress("# curl_move_probe phase=" . Phase . " moved=" . (Moved ? 1 : 0)
			. " errno=" . MoveError . " errno_valid=" . (Moved ? 0 : 1)
			. " source_before=" . (BeforeSource ? 1 : 0) . " target_before=" . (BeforeTarget ? 1 : 0)
			. " source_after=" . (AfterSource ? 1 : 0) . " target_after=" . (AfterTarget ? 1 : 0)
			. " held_root=" . (HeldRoot ? 1 : 0) . " identity_checked=" . (HeldRoot ? 1 : 0)
			. " directory_same=" . (HeldSame ? 1 : 0))
		if Moved
			Entry["path"] := Target
		AssertTrue(MoveError is Integer && MoveError >= 0 && MoveError <= 0xFFFFFFFF)
		if HeldRoot
			AssertTrue(HeldSame, "the root-only probe preserves its exact held directory identity")
		if !HeldRoot
			AssertTrue(Moved, "the actual unheld empty-directory positive control must rename")
		if Moved
			AssertTrue(!AfterSource && AfterTarget, "a successful independent setup reaches its exact target")
		else {
			AssertTrue(MoveError != 0, "the diagnostic root-only refusal has an actual native error")
			AssertTrue(AfterSource && !AfterTarget, "a refused root-only setup preserves its exact namespace")
		}
		if !Entry["handle"]
			Entry["handle"] := Owner.Open(Entry["path"], 0, 3, true)
		AssertTrue(Entry["handle"] != 0 && Owner.Same(Original, Owner.Snapshot(Entry["handle"])),
			"the independent renamed positive control retains its original native identity")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally {
		try {
			if !(Entry is Map) || !IsSet(Original) || Owner.ProbeCloseDebt.Length
				throw Error("Native move positive-control authority was unavailable.")
			if !Entry["handle"]
				Entry["handle"] := Owner.Open(Entry["path"], 0, 3, true)
			if !Entry["handle"] || !Owner.Same(Original, Owner.Snapshot(Entry["handle"])) || !Owner.RetireEntry(Entry)
				throw Error("Native move positive-control retirement was refused.")
			AssertEqual(0, Owner.ProbeCloseDebt.Length)
			DirDelete(Parent, false)
			_CurlCaptureMoveProbeFixtureDebt.Delete(ObjPtr(Owner))
		} catch Any as Failure {
			CleanupFailure := Failure
		}
	}
	if Failed
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

_CurlCaptureMoveProbeAllocatedNamespace(Phase, LiveBody := false, HeldLease := false) {
	global _CurlCaptureMoveProbeFixtureDebt
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Lease := 0
	MovedPath := ""
	Failed := false
	Primary := 0
	Context := Map("capture", Capture, "parent", Parent, "lease", 0, "moved", "")
	_CurlCaptureMoveProbeFixtureDebt[ObjPtr(Capture)] := Context
	try {
		AssertTrue(Phase == "allocated" || Phase == "live_body" || Phase == "held_lease")
		Capture.Acquire(Parent)
		AssertEqual(4, Capture.Files.Count, "the probe uses the actual four-file production ledger")
		AssertTrue(Capture.ValidatePaths(), "all exact production references precede the native setup attempt")
		AssertEqual(0, Capture.ProbeCloseDebt.Length)
		if LiveBody {
			Path := StrReplace(Capture.Files["artifact.bin"]["path"], "'", "''")
			Script := "$ErrorActionPreference='Stop';[IO.File]::WriteAllBytes('" . Path
				. "',[byte[]](1,2,3,4));Start-Sleep -Milliseconds 30000"
			Worker := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
				["-NoProfile", "-NonInteractive", "-EncodedCommand", _Updater_EncodePowerShellCommand(Script)],
				, , ObjBindMethod(Capture, "OnNativeAdopt"))
			Capture.Attach(Worker)
			AssertTrue(Worker.start(), "the diagnostic body has a real independently owned native Job")
			Start := A_TickCount
			while !TickExpired64(Start, 10000) && Capture.ObserveBody(Worker, 16) != 4 {
				_SR_TreePoll()
				Sleep(10)
			}
			AssertEqual(4, Capture.ObserveBody(Worker, 16), "the exact real four-byte native body precedes the diagnostic move")
			AssertEqual(0, Capture.ProbeCloseDebt.Length, "all observation probes closed before the diagnostic move")
		}
		if HeldLease {
			Lease := Capture.AcquireDirectoryLease()
			Context["lease"] := Lease
			AssertTrue(Lease != 0, "the comparison phase holds the actual delete-excluding production lease")
		}
		DirectoryBefore := Capture.Snapshot(Capture.Directory["handle"])
		AssertTrue(DirectoryBefore.Get("ok", false) && DirectoryBefore["directory"] && !DirectoryBefore["delete_pending"])
		FilesBefore := Map()
		for Name, Entry in Capture.Files {
			FilesBefore[Name] := Capture.Snapshot(Entry["handle"])
			AssertTrue(FilesBefore[Name].Get("ok", false) && !FilesBefore[Name]["directory"]
				&& !FilesBefore[Name]["delete_pending"] && FilesBefore[Name]["links"] == 1)
		}
		Target := Parent . "\move-probe-target"
		BeforeSource := DirExist(Capture.Path) != ""
		BeforeTarget := DirExist(Target) != ""
		AssertTrue(BeforeSource && !BeforeTarget, "the target is absent in the exact same private parent")
		DllCall("kernel32\SetLastError", "UInt", 0)
		Moved := DllCall("kernel32\MoveFileW", "Str", Capture.Path, "Str", Target, "Int")
		MoveError := A_LastError
		if Moved {
			MovedPath := Target
			Context["moved"] := MovedPath
		}
		AfterSource := DirExist(Capture.Path) != ""
		AfterTarget := DirExist(Target) != ""
		DirectorySame := Capture.Same(DirectoryBefore, Capture.Snapshot(Capture.Directory["handle"]))
		FilesSame := true
		for Name, Entry in Capture.Files {
			Actual := Capture.Snapshot(Entry["handle"])
			FilesSame := Capture.Same(FilesBefore[Name], Actual) && FilesSame
		}
		_TestAppendProgress("# curl_move_probe phase=" . Phase . " moved=" . (Moved ? 1 : 0)
			. " errno=" . MoveError . " errno_valid=" . (Moved ? 0 : 1)
			. " source_before=" . (BeforeSource ? 1 : 0) . " target_before=" . (BeforeTarget ? 1 : 0)
			. " source_after=" . (AfterSource ? 1 : 0) . " target_after=" . (AfterTarget ? 1 : 0)
			. " directory_same=" . (DirectorySame ? 1 : 0) . " files_same=" . (FilesSame ? 1 : 0)
			. " held_lease=" . (Lease ? 1 : 0))
		AssertTrue(MoveError is Integer && MoveError >= 0 && MoveError <= 0xFFFFFFFF)
		AssertTrue(DirectorySame && FilesSame, "the observation never replaces or closes original authority")
		if HeldLease {
			AssertFalse(Moved, "the actual held admission must deny the native move")
			AssertTrue(MoveError == 5 || MoveError == 32, "held-lease denial has an actual access or sharing error")
		}
		if Moved {
			AssertTrue(!AfterSource && AfterTarget, "a successful native setup physically reaches its target")
			if LiveBody
				AssertEqual(0, Capture.ObserveBody(Capture.Worker, 16), "missing original namespace refuses body admission")
			Probe := Capture.Open(Target, 0, 3, true)
			AssertTrue(Probe != 0)
			try AssertTrue(Capture.Same(DirectoryBefore, Capture.Snapshot(Probe)))
			finally AssertTrue(Capture.CloseProbe(Probe))
			Restored := DllCall("kernel32\MoveFileW", "Str", Target, "Str", Capture.Path, "Int")
			RestoreError := A_LastError
			_TestAppendProgress("# curl_move_probe phase=restore source_phase=" . Phase
				. " moved=" . (Restored ? 1 : 0) . " errno=" . RestoreError . " errno_valid=" . (Restored ? 0 : 1))
			AssertTrue(Restored, "only the exact unchanged moved namespace is restored")
			MovedPath := ""
			Context["moved"] := MovedPath
		} else {
			AssertTrue(MoveError != 0, "a refused setup must report the actual native error")
			AssertTrue(AfterSource && !AfterTarget, "a denied move preserves the original named namespace")
		}
		AssertTrue(Capture.ValidatePaths(), "diagnostic receiving leaves all exact file and directory paths admitted")
		if LiveBody
			AssertEqual(4, Capture.ObserveBody(Capture.Worker, 16), "the real owned body remains observable in its restored namespace")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureMoveProbeFinishOwnedContext(Context, Failed, Primary)
}

; A restoration refusal can precede production debt registration. This exact
; external owner exists before Acquire and survives every cleanup exception.
; A retry uses this same context and already-acquired native references only.
_CurlCaptureMoveProbeFinishOwnedContext(Context, Failed := false, Primary := 0) {
	global _CurlCaptureMoveProbeFixtureDebt
	Capture := Context["capture"]
	Key := ObjPtr(Capture)
	if !_CurlCaptureMoveProbeFixtureDebt.Has(Key) || _CurlCaptureMoveProbeFixtureDebt[Key] != Context
		throw Error("Native move diagnostic fixture owner was replaced.")
	if Capture.ProbeCloseDebt.Length {
		if Failed
			throw Primary
		throw Error("Native move diagnostic retained unknown close debt.")
	}
	Lease := Context["lease"]
	if Lease {
		if Capture.CloseProbe(Lease)
			Context["lease"] := 0
		else if !Failed {
			Failed := true
			Primary := Error("Native move diagnostic lease closure was refused.")
		}
	}
	CleanupFailure := 0
	try {
		; Receive cleanup's physical completion separately from the original
		; assertion failure, which remains primary after this actual receipt.
		_CurlCaptureMoveProbeRestoreOwnedNamespace(Context)
		_CurlCaptureFinishNativeFixture(Capture, Context["parent"], false, 0, 0, Context["moved"], true)
		if !_CurlCaptureMoveProbeFixtureDebt.Has(Key) || _CurlCaptureMoveProbeFixtureDebt[Key] != Context
			throw Error("Native move diagnostic fixture owner changed during cleanup.")
		_CurlCaptureMoveProbeFixtureDebt.Delete(Key)
	} catch Any as Failure {
		CleanupFailure := Failure
	}
	if Failed
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

_CurlCaptureMoveProbeRestoreOwnedNamespace(Context) {
	Moved := Context["moved"]
	if Moved == ""
		return
	Capture := Context["capture"]
	Probe := Capture.Open(Moved, 0, 3, true)
	if !Probe
		throw Error("Native move diagnostic original restoration identity was unavailable.")
	try {
		Original := Capture.Snapshot(Capture.Directory["handle"])
		Actual := Capture.Snapshot(Probe)
		if !Capture.Same(Original, Actual) || !Actual["directory"] || Actual["delete_pending"]
			throw Error("Native move diagnostic original restoration identity was refused.")
	} finally Capture.CloseProbe(Probe)
	if Capture.ProbeCloseDebt.Length || FileExist(Capture.Directory["path"])
		throw Error("Native move diagnostic restoration cannot replace an unowned namespace.")
	Restored := DllCall("kernel32\MoveFileW", "Str", Moved, "Str", Capture.Directory["path"], "Int")
	RestoreError := A_LastError
	if Restored
		Context["moved"] := ""
	_TestAppendProgress("# curl_move_probe phase=cleanup_restore moved=" . (Restored ? 1 : 0)
		. " errno=" . RestoreError . " errno_valid=" . (Restored ? 0 : 1))
	if !Restored
		throw OSError(RestoreError, "Native move diagnostic exact original restoration was refused.")
}

_CurlCaptureNativeMovePreconditionProbe() {
	_CurlCaptureMoveProbeEmptyDirectory()
	_CurlCaptureMoveProbeEmptyDirectory(true)
	_CurlCaptureMoveProbeAllocatedNamespace("allocated")
	_CurlCaptureMoveProbeAllocatedNamespace("live_body", true)
	_CurlCaptureMoveProbeAllocatedNamespace("held_lease", false, true)
}
Test("updater curl capture: additive native move precondition facts preserve original attack requirements",
	_CurlCaptureNativeMovePreconditionProbe)


; Public SDK receiving only. POSIX flag2 does not promise that an absent-target
; source directory with retained descendants can move. The original attacks
; keep their strict assertions until a genuine setup is independently received.
_CurlCaptureHandleRenameBuffer(Path, Parent, InformationClass, Flags) {
	AssertTrue(A_PtrSize == 4 || A_PtrSize == 8)
	AssertTrue(InformationClass == 3 || InformationClass == 22)
	AssertTrue(Flags == 0 || (InformationClass == 22 && Flags == 2), "replacement is never authorized")
	; RootDirectory=NULL requires an absolute destination, independent of CWD.
	AssertTrue(StrLen(Path) <= 4096 && RegExMatch(Parent, "^[A-Za-z]:\\")
		&& !InStr(Parent, "/") && !RegExMatch(Parent, "(?:^|\\)\.{1,2}(?:\\|$)")
		&& !RegExMatch(Parent, "[\x00-\x1F]"), "the captured original parent is a bounded absolute Windows path")
	AssertTrue(SubStr(Path, 1, StrLen(Parent) + 1) == Parent . "\"
		&& RegExMatch(SubStr(Path, StrLen(Parent) + 2), "^[A-Za-z0-9.-]{1,80}$")
		&& SubStr(Path, StrLen(Parent) + 2) != "." && SubStr(Path, StrLen(Parent) + 2) != "..",
		"the absolute destination remains one bounded leaf in the exact original private parent")
	NameBytes := (StrPut(Path, "UTF-16") - 1) * 2
	; Public FILE_RENAME_INFO: union DWORD/BOOLEAN, aligned HANDLE root=NULL,
	; DWORD name byte length, then WCHAR name. Preserve full SDK structure size.
	Data := Buffer((A_PtrSize == 8 ? 24 : 16) + NameBytes, 0)
	NumPut("UInt", Flags, Data, 0)
	NumPut("UInt", NameBytes, Data, 2 * A_PtrSize)
	StrPut(Path, Data.Ptr + 2 * A_PtrSize + 4, NameBytes // 2 + 1, "UTF-16")
	return Data
}

_CurlCaptureHandleRenameFacts(Capture, DirectoryBefore, FilesBefore) {
	DirectorySame := Capture.Same(DirectoryBefore, Capture.Snapshot(Capture.Directory["handle"]))
	FilesSame := true
	for Name, Entry in Capture.Files {
		Actual := Capture.Snapshot(Entry["handle"])
		FilesSame := Capture.Same(FilesBefore[Name], Actual) && FilesSame
	}
	return Map("directory_same", DirectorySame, "files_same", FilesSame)
}

_CurlCaptureHandleRenameFinish(Context, Failed, Primary) {
	global _CurlCaptureMoveProbeFixtureDebt
	Capture := Context["capture"]
	Key := ObjPtr(Capture)
	if !_CurlCaptureMoveProbeFixtureDebt.Has(Key) || _CurlCaptureMoveProbeFixtureDebt[Key] != Context
		throw Error("Native handle-rename receiving fixture owner was replaced.")
	if Context["moved"] != "" {
		if Failed
			throw Primary
		throw Error("Native handle-rename receiving retained unpaid exact restoration.")
	}
	if Context["rename_handle"] {
		if Capture.ProbeCloseDebt.Length {
			if Failed
				throw Primary
			throw Error("Native handle-rename receiving retained unknown close debt.")
		}
		if Capture.CloseProbe(Context["rename_handle"])
			Context["rename_handle"] := 0
		else if !Failed {
			Failed := true
			Primary := Error("Native handle-rename receiving closure was refused.")
		}
	}
	_CurlCaptureMoveProbeFinishOwnedContext(Context, Failed, Primary)
}

_CurlCaptureHandleRenameCase(InformationClass, Flags, FourFiles) {
	global _CurlCaptureMoveProbeFixtureDebt
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Context := Map("capture", Capture, "parent", Parent, "lease", 0, "moved", "", "rename_handle", 0)
	_CurlCaptureMoveProbeFixtureDebt[ObjPtr(Capture)] := Context
	Failed := false
	Primary := 0
	Kind := FourFiles ? "four" : "empty"
	try {
		if FourFiles {
			Capture.Acquire(Parent)
			AssertEqual(4, Capture.Files.Count)
			AssertTrue(Capture.ValidatePaths(), "the exact original four-file ledger precedes handle-based receiving")
		} else {
			; Independent empty positive control; it never stands in for four files.
			Path := Parent . "\empty-handle-original"
			AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Path, "Ptr", 0, "Int"))
			Capture.Path := Path
			Capture.Directory := Map("path", Path, "handle", Capture.Open(Path, 0, 3, true), "directory", true)
			AssertTrue(Capture.Directory["handle"] != 0)
			AssertEqual(0, Capture.Files.Count)
		}
		DirectoryBefore := Capture.Snapshot(Capture.Directory["handle"])
		AssertTrue(DirectoryBefore.Get("ok", false) && DirectoryBefore["directory"] && !DirectoryBefore["delete_pending"])
		FilesBefore := Map()
		for Name, Entry in Capture.Files {
			FilesBefore[Name] := Capture.Snapshot(Entry["handle"])
			AssertTrue(FilesBefore[Name].Get("ok", false) && !FilesBefore[Name]["directory"]
				&& !FilesBefore[Name]["delete_pending"] && FilesBefore[Name]["links"] == 1)
		}
		TargetName := "handle-receiving-target"
		Target := Parent . "\" . TargetName
		AssertTrue(DirExist(Capture.Path) && !FileExist(Target), "no replacement or foreign destination is permitted")
		Data := _CurlCaptureHandleRenameBuffer(Target, Parent, InformationClass, Flags)
		DllCall("kernel32\SetLastError", "UInt", 0)
		Context["rename_handle"] := Capture.Open(Capture.Path, 0x10000, 3, true)
		OpenError := A_LastError
		Facts := _CurlCaptureHandleRenameFacts(Capture, DirectoryBefore, FilesBefore)
		_TestAppendProgress("# curl_handle_rename kind=" . Kind . " stage=open api=" . InformationClass
			. " flags=" . Flags . " acquired=" . (Context["rename_handle"] ? 1 : 0)
			. " errno=" . OpenError . " errno_valid=" . (Context["rename_handle"] ? 0 : 1)
			. " directory_same=" . (Facts["directory_same"] ? 1 : 0) . " files_same=" . (Facts["files_same"] ? 1 : 0))
		AssertTrue(Facts["directory_same"] && Facts["files_same"])
		if !Context["rename_handle"] {
			AssertTrue(FourFiles && OpenError != 0, "the empty-directory positive control must acquire DELETE access")
			return
		}
		AssertTrue(Capture.Same(DirectoryBefore, Capture.Snapshot(Context["rename_handle"])),
			"the DELETE handle is the exact original directory, never a new admission authority")
		DllCall("kernel32\SetLastError", "UInt", 0)
		Renamed := DllCall("kernel32\SetFileInformationByHandle", "Ptr", Context["rename_handle"],
			"Int", InformationClass, "Ptr", Data, "UInt", Data.Size, "Int")
		RenameError := A_LastError
		if Renamed
			Context["moved"] := Target
		Facts := _CurlCaptureHandleRenameFacts(Capture, DirectoryBefore, FilesBefore)
		SourceAfter := DirExist(Capture.Path) != ""
		TargetAfter := DirExist(Target) != ""
		_TestAppendProgress("# curl_handle_rename kind=" . Kind . " stage=rename api=" . InformationClass
			. " flags=" . Flags . " moved=" . (Renamed ? 1 : 0) . " errno=" . RenameError
			. " errno_valid=" . (Renamed ? 0 : 1) . " source_after=" . (SourceAfter ? 1 : 0)
			. " target_after=" . (TargetAfter ? 1 : 0) . " directory_same=" . (Facts["directory_same"] ? 1 : 0)
			. " files_same=" . (Facts["files_same"] ? 1 : 0))
		AssertTrue(Facts["directory_same"] && Facts["files_same"], "all original metadata handles remain held and identical")
		if !FourFiles
			AssertTrue(Renamed, "the actual same-parent empty-directory handle-rename positive control must succeed")
		if !Renamed {
			AssertTrue(RenameError != 0 && SourceAfter && !TargetAfter, "a reported denial preserves the original namespace")
			return
		}
		AssertTrue(!SourceAfter && TargetAfter, "a successful API must physically reach the target namespace")
		RestoreData := _CurlCaptureHandleRenameBuffer(Capture.Path, Parent, InformationClass, Flags)
		AssertTrue(Capture.Same(DirectoryBefore, Capture.Snapshot(Context["rename_handle"]))
			&& !FileExist(Capture.Path), "restoration retains exact identity and cannot replace a foreign path")
		DllCall("kernel32\SetLastError", "UInt", 0)
		Restored := DllCall("kernel32\SetFileInformationByHandle", "Ptr", Context["rename_handle"],
			"Int", InformationClass, "Ptr", RestoreData, "UInt", RestoreData.Size, "Int")
		RestoreError := A_LastError
		if Restored
			Context["moved"] := ""
		_TestAppendProgress("# curl_handle_rename kind=" . Kind . " stage=restore api=" . InformationClass
			. " flags=" . Flags . " moved=" . (Restored ? 1 : 0) . " errno=" . RestoreError . " errno_valid=" . (Restored ? 0 : 1))
		AssertTrue(Restored && DirExist(Capture.Path) && !DirExist(Target), "the same exact native API must restore before retirement")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureHandleRenameFinish(Context, Failed, Primary)
}

_CurlCaptureNativeHandleRenameReceiving() {
	for NativeAPI in [[3, 0], [22, 0], [22, 2]] {
		_CurlCaptureHandleRenameCase(NativeAPI[1], NativeAPI[2], false)
		_CurlCaptureHandleRenameCase(NativeAPI[1], NativeAPI[2], true)
	}
}
Test("updater curl capture: public handle-rename receiving distinguishes empty controls from held descendants",
	_CurlCaptureNativeHandleRenameReceiving)

; These graph ports receive the actual fixture owner above. They model the
; independent documented open-descendant denial, not native Windows success.
class _CurlCaptureDirectoryMoveGraphCapture extends _UpdaterCurlCaptureLedger {
	__New() {
		super.__New()
		this.Path := "C:\owned\original"
		this.Directory := Map("path", this.Path, "handle", 10, "directory", true)
		this.GraphHandles := Map(10, 10)
		this.GraphDirectories := Map(10, true)
		this.GraphPaths := Map(this.Path, 10)
		Id := 20
		for Name in ["artifact.bin", "headers.bin", "capability.json", "transport.conf"] {
			this.GraphHandles[Id] := Id
			this.GraphDirectories[Id] := false
			this.GraphPaths[this.Path . "\" . Name] := Id
			this.Files[Name] := Map("path", this.Path . "\" . Name, "handle", Id, "directory", false)
			Id += 1
		}
	}
	Snapshot(Handle) {
		if !this.GraphHandles.Has(Handle)
			return Map("ok", false)
		Id := this.GraphHandles[Handle]
		return Map("ok", true, "directory", this.GraphDirectories[Id], "volume", 1,
			"index_high", 0, "index_low", Id, "delete_pending", false, "links", 1)
	}
}
class _CurlCaptureDirectoryMoveGraph extends _CurlCaptureDirectoryMoveFixture {
	__New(Capture, FailurePoint := 0) {
		this.RenameCalls := 0
		this.FailurePoint := FailurePoint
		this.NextHandle := 100
		this.Denials := 0
		this.CloseRefused := false
		super.__New(Capture, Capture.Path, "C:\owned\moved", "C:\owned")
	}
	NewHoldingPath() => "C:\owned\holding.graph"
	Exists(Path) => this.Capture.GraphPaths.Has(Path)
	Create(Path) {
		if this.Exists(Path)
			return false
		this.Capture.GraphPaths[Path] := 40
		this.Capture.GraphDirectories[40] := true
		return true
	}
	Open(Path, Access, Directory, Sharing := 7) {
		if !this.Exists(Path)
			return 0
		Handle := this.NextHandle++
		this.Capture.GraphHandles[Handle] := this.Capture.GraphPaths[Path]
		return Handle
	}
	Close(Handle) {
		if this.CloseRefused {
			this.Capture.ProbeCloseDebt.Push(Handle)
			return false
		}
		AssertTrue(Handle >= 100, "no original metadata reference can close during fixture transition")
		AssertTrue(this.Capture.GraphHandles.Has(Handle))
		this.Capture.GraphHandles.Delete(Handle)
		return true
	}
	RemoveHolding(Entry) {
		for Path, Id in this.Capture.GraphPaths {
			if SubStr(Path, 1, StrLen(Entry["path"]) + 1) == Entry["path"] . "\"
				return false
		}
		if !this.Close(Entry["handle"])
			return false
		Entry["handle"] := 0
		Entry["retired"] := true
		this.Capture.GraphPaths.Delete(Entry["path"])
		return true
	}
	Rename(Handle, Destination) {
		if this.HasOwnProp("Reentry") && this.Reentry {
			this.Reentry := false
			AssertThrows(ObjBindMethod(this, "Rollback"), "a running mutation cannot borrow its own retained cleanup owner")
			AssertTrue(this.Running)
		}
		this.RenameCalls += 1
		if this.FailurePoint && this.RenameCalls == this.FailurePoint {
			this.FailurePoint := 0
			return false
		}
		if this.Exists(Destination) || !this.Capture.GraphHandles.Has(Handle)
			return false
		Id := this.Capture.GraphHandles[Handle]
		Source := ""
		for Path, PathId in this.Capture.GraphPaths {
			if PathId == Id
				Source := Path
		}
		if Source == ""
			return false
		if this.Capture.GraphDirectories[Id] {
			for Path, ChildId in this.Capture.GraphPaths {
				if SubStr(Path, 1, StrLen(Source) + 1) == Source . "\" {
					for ChildHandle, HeldId in this.Capture.GraphHandles {
						if HeldId == ChildId {
							this.Denials += 1
							return false
						}
					}
				}
			}
		}
		this.Capture.GraphPaths.Delete(Source)
		this.Capture.GraphPaths[Destination] := Id
		return true
	}
}

_CurlCaptureDirectoryMoveGraphCheck(Capture, Root) {
	AssertEqual(10, Capture.GraphPaths[Root], "the original directory identity reaches the exact graph namespace")
	AssertEqual(10, Capture.Directory["handle"], "original root metadata authority stays open")
	for Name, Entry in Capture.Files {
		AssertEqual(Entry["handle"], Capture.GraphPaths[Root . "\" . Name], "each held child identity reaches the requested namespace")
		AssertTrue(Capture.GraphHandles.Has(Entry["handle"]), "every original child metadata handle remains held")
	}
	AssertEqual(0, Capture.ProbeCloseDebt.Length)
}
_CurlCaptureDirectoryMoveGraphCase(Point := 0) {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture, Point)
	try {
		if Point {
			AssertThrows(ObjBindMethod(Owner, "Execute"), "an actual owner transition refusal cannot claim complete setup")
			AssertTrue(Capture.FixtureDirectoryMove == Owner, "the exact partial transition owner remains published")
			AssertFalse(Owner.Closed)
			AssertFalse(Capture.Running, "fixture debt never fabricates production retirement state")
			AssertTrue(_CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner,
				"the exact fixture owner retains incomplete transitions separately")
			AssertEqual(Capture.Path, Owner.Rollback(), "the same owner restores its exact original namespace")
			_CurlCaptureDirectoryMoveGraphCheck(Capture, Capture.Path)
			AssertFalse(Owner.Exists(Owner.Target))
		} else {
			Probe := Owner.Open(Owner.Source, 0x10000, true)
			AssertFalse(Owner.Rename(Probe, Owner.Target), "the original populated-directory graph setup is independently denied")
			AssertTrue(Owner.Close(Probe))
			AssertEqual(1, Owner.Denials)
			Owner.RenameCalls := 0
			AssertTrue(Owner.Execute())
			_CurlCaptureDirectoryMoveGraphCheck(Capture, Owner.Target)
			AssertEqual(9, Owner.RenameCalls, "four staging moves, one empty root move, and four placement moves actually commit")
			AssertFalse(Owner.Exists(Owner.Source))
		}
		AssertTrue(Owner.Closed)
		AssertFalse(Capture.Running)
		AssertEqual(0, Capture.FixtureDirectoryMove)
		AssertFalse(Owner.Exists(Owner.HoldingPath), "the exact empty holding namespace retires only after all children leave")
		AssertEqual(5, Capture.GraphHandles.Count, "only the five original metadata authorities remain")
	} finally {
		if _CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(Capture)) && _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner
			_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
	}
}
Test("updater curl capture: actual fixture owner stages retained children before the empty graph root move",
	_CurlCaptureDirectoryMoveGraphCase)
loop 9
	Test("updater curl capture: exact graph transition " . A_Index . " refusal restores every held identity",
		_CurlCaptureDirectoryMoveGraphCase.Bind(A_Index))

_CurlCaptureDirectoryMoveGraphForeignRollback() {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture, 6)
	try {
		AssertThrows(ObjBindMethod(Owner, "Execute"))
		Capture.GraphPaths[Owner.Source] := 999
		Capture.GraphPaths[Owner.Source . "\foreign.bytes"] := 998
		AssertThrows(ObjBindMethod(Owner, "Rollback"), "restoration cannot replace an independently owned foreign namespace")
		AssertEqual(999, Capture.GraphPaths[Owner.Source])
		AssertEqual(998, Capture.GraphPaths[Owner.Source . "\foreign.bytes"])
		AssertFalse(Owner.Closed)
		AssertTrue(Capture.FixtureDirectoryMove == Owner)
		; Only this graph's independent foreign owner removes its own entries.
		Capture.GraphPaths.Delete(Owner.Source . "\foreign.bytes")
		Capture.GraphPaths.Delete(Owner.Source)
		AssertEqual(Capture.Path, Owner.Rollback())
		_CurlCaptureDirectoryMoveGraphCheck(Capture, Capture.Path)
	} finally {
		if _CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(Capture)) && _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner
			_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
	}
}
Test("updater curl capture: a foreign graph rollback target retains every original transition debt",
	_CurlCaptureDirectoryMoveGraphForeignRollback)

_CurlCaptureDirectoryMoveGraphCloseDebt() {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture)
	try {
		Owner.CloseRefused := true
		AssertThrows(ObjBindMethod(Owner, "Execute"))
		AssertEqual(1, Capture.ProbeCloseDebt.Length, "the actual owner retains exact failed native closure")
		Calls := Owner.RenameCalls
		AssertThrows(ObjBindMethod(Owner, "Rollback"), "unknown physical closure cannot authorize another mutation")
		AssertEqual(Calls, Owner.RenameCalls)
		AssertFalse(Owner.Closed)
		AssertTrue(Capture.FixtureDirectoryMove == Owner)
		for Name, Entry in Capture.Files
			AssertTrue(Capture.GraphHandles.Has(Entry["handle"]), "original metadata references survive exact close refusal")
	} finally _CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
}
Test("updater curl capture: graph close refusal cannot acknowledge transition cleanup",
	_CurlCaptureDirectoryMoveGraphCloseDebt)

_CurlCaptureDirectoryMoveGraphForeignHolding() {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture)
	try {
		Capture.GraphPaths[Owner.NewHoldingPath()] := 999
		AssertThrows(ObjBindMethod(Owner, "Execute"))
		AssertFalse(Owner.HoldingCreated)
		AssertEqual(Capture.Path, Owner.Rollback())
		AssertEqual(999, Capture.GraphPaths[Owner.NewHoldingPath()], "failed exclusive allocation never retires foreign holding data")
		_CurlCaptureDirectoryMoveGraphCheck(Capture, Capture.Path)
		AssertTrue(Owner.Closed)
	} finally {
		if _CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(Capture)) && _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner
			_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
	}
}
Test("updater curl capture: foreign graph holding allocation preserves all foreign identities",
	_CurlCaptureDirectoryMoveGraphForeignHolding)

_CurlCaptureDirectoryMoveGraphReentry() {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture)
	try {
		Owner.Reentry := true
		AssertTrue(Owner.Execute())
		AssertFalse(Owner.Reentry)
		AssertFalse(Owner.Running)
		_CurlCaptureDirectoryMoveGraphCheck(Capture, Owner.Target)
	} finally {
		if _CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(Capture)) && _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner
			_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
	}
}
Test("updater curl capture: graph mutation reentry cannot resume the same running transition",
	_CurlCaptureDirectoryMoveGraphReentry)

; Real in-memory mount-point ABI vectors. No filesystem/handle port is faked.
_CurlCaptureJunctionTargetVector(Target, SubstituteSuffix := false, PrintSuffix := false) {
	Substitute := "\??\" . Target
	SubstitutePlainBytes := (StrPut(Substitute, "UTF-16") - 1) * 2
	PrintPlainBytes := (StrPut(Target, "UTF-16") - 1) * 2
	SuffixBytes := (StrPut("suffix", "UTF-16") - 1) * 2
	SubstituteBytes := SubstitutePlainBytes + (SubstituteSuffix ? 2 + SuffixBytes : 0)
	PrintBytes := PrintPlainBytes + (PrintSuffix ? 2 + SuffixBytes : 0)
	Paths := SubstituteBytes + 2 + PrintBytes + 2
	Data := Buffer(16 + Paths, 0)
	NumPut("UInt", 0xA0000003, "UShort", 8 + Paths, Data, 0)
	NumPut("UShort", 0, "UShort", SubstituteBytes, "UShort", SubstituteBytes + 2, "UShort", PrintBytes, Data, 8)
	StrPut(Substitute, Data.Ptr + 16, SubstitutePlainBytes // 2 + 1, "UTF-16")
	if SubstituteSuffix
		StrPut("suffix", Data.Ptr + 16 + SubstitutePlainBytes + 2, 7, "UTF-16")
	PrintAddress := Data.Ptr + 16 + SubstituteBytes + 2
	StrPut(Target, PrintAddress, PrintPlainBytes // 2 + 1, "UTF-16")
	if PrintSuffix
		StrPut("suffix", PrintAddress + PrintPlainBytes + 2, 7, "UTF-16")
	return Data
}
_CurlCaptureJunctionExactTargetControls() {
	Target := "C:\fixture\original"
	Normal := _CurlCaptureJunctionTargetVector(Target)
	AssertTrue(_CurlCaptureJunctionTargetMatches(Normal, Normal.Size, Target), "the real declared target bytes match")
	SubstituteSuffix := _CurlCaptureJunctionTargetVector(Target, true)
	AssertEqual("\??\" . Target, StrGet(SubstituteSuffix.Ptr + 16,
		NumGet(SubstituteSuffix, 10, "UShort") // 2, "UTF-16"), "positive-length StrGet exposes the old NUL-prefix ambiguity")
	AssertFalse(_CurlCaptureJunctionTargetMatches(SubstituteSuffix, SubstituteSuffix.Size, Target),
		"declared substitute bytes cannot hide a suffix after NUL")
	PrintSuffix := _CurlCaptureJunctionTargetVector(Target, false, true)
	AssertEqual(Target, StrGet(PrintSuffix.Ptr + 16 + NumGet(PrintSuffix, 12, "UShort"),
		NumGet(PrintSuffix, 14, "UShort") // 2, "UTF-16"), "the old print-name copy also loses declared trailing bytes")
	AssertFalse(_CurlCaptureJunctionTargetMatches(PrintSuffix, PrintSuffix.Size, Target),
		"declared print bytes cannot hide a suffix after NUL")
	AssertFalse(_CurlCaptureJunctionTargetMatches(Normal, 15, Target), "partial native header is not an exact target")
	AssertFalse(_CurlCaptureJunctionTargetMatches(Normal, Normal.Size, ""), "empty target cannot request implicit-length copies")
}
Test("updater curl capture: exact declared junction fields cannot lend a NUL-prefix target", _CurlCaptureJunctionExactTargetControls)
