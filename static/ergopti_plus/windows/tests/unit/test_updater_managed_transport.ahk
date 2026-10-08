; tests/unit/test_updater_managed_transport.ahk
; Actual generated staging orchestrator over owned native TLS/PAC/CONNECT.
; The only controlled production seams are trusted config/environment readers.

class _UpdaterNativeTransportOwner extends _ManagedRemoteFixtureOwner {
	__New() {
		super.__New()
		this.DownloadRuns := []
	}

	NewRun(Path, DeadlineMs := 30000, DenyFile := false) {
		Run := _UpdaterNativeDownloadRun(this, Path, DeadlineMs, DenyFile)
		this.DownloadRuns.Push(Run)
		Run.Start()
		return Run
	}

	RetireRequests() {
		Complete := true
		for Run in this.DownloadRuns {
			if !Run.Retire()
				Complete := false
		}
		return super.RetireRequests() && Complete
	}
}

class _UpdaterNativeDownloadRun {
	__New(Owner, Path, DeadlineMs, DenyFile) {
		this.Owner := Owner
		this.Path := Path
		this.DeadlineMs := DeadlineMs
		this.DenyFile := DenyFile
		this.Handle := 0
		this.NativeState := 0
		this.Results := []
		this.Directory := ""
		this.Closed := false
		this.Transport := 0
		this.OldBytes := "Independent existing-app bytes " . Owner.Identity
		; Receive the full production swap worker as UTF-8 data; never execute it.
		this.SwapBytes := _Updater_BuildSwapWorkerScript()
		this.Digest := "33bc8aab40703678c3ebe94d2dd8f2afff285dd901f9234e841e4679f8204fd5"
	}

	OnNativeAdopt(State, Native) => this.NativeState := State
	OnDone(Code, Out, Err) => this.Results.Push(Map("exit", Code, "stdout", Out, "stderr", Err))

	Start() {
		global _VendorDir, _SharedDir, UPDATER_MIN_EXE_SIZE_BYTES
		this.Directory := _SR_AcquireCaptureDirectory()
		this.CurrentExe := this.Directory . "existing.exe"
		this.NewExe := this.Directory . "staged.exe"
		this.SwapPath := this.Directory . "swap.ps1"
		FileAppend(this.OldBytes, this.CurrentExe, "UTF-8-RAW")
		if this.DenyFile
			DirCreate(this.NewExe)
		AssertEqual(524288, UPDATER_MIN_EXE_SIZE_BYTES,
			"fixture bytes have an independent fixed size; a changed minimum requires explicit fixture review")
		Url := "https://managed-fixture.invalid:" . this.Owner.State["tls_port"] . this.Path
		this.StartedTick := A_TickCount
		this.Transport := _Updater_BuildStagingTransport(
			_Updater_BuildStagingWorkerScript(), this.SwapBytes, Url, this.Digest,
			this.NewExe, this.SwapPath, this.CurrentExe, UPDATER_MIN_EXE_SIZE_BYTES, 5000,
			_VendorDir . "\ergopti_updater_download.ps1", this.DeadlineMs, this.StartedTick,
			_SharedDir . "\modules\network\proxy_policy.json",
			_SharedDir . "\modules\updater\defaults.json")
		try {
			ScriptName := this.Transport.Environment[1].Name
			Prefix := SubStr(ScriptName, 1, StrLen(ScriptName) - StrLen("_SCRIPT"))
			Pair := {Name: Prefix . "_TEST_PAC", Value: "http://127.0.0.1:" . this.Owner.State["http_port"] . "/updater.pac"}
			this.Transport.Environment.Push(Pair)
			EnvSet(Pair.Name, Pair.Value)
			; Add declared trusted callbacks to the real transport invocation only.
			; No worker body, network method, native WinHTTP or integrity check is replaced.
			Admission := '$ownedPac=$env:' . Pair.Name . ';'
				. '$reader={param($MaxBytes)[pscustomobject]@{Ok=$true;AutoDetect=$false;Absent=$false;PacUrl=$ownedPac;Proxy="";Bypass="";NativeError=0;FailureOrigin=""}}.GetNewClosure();'
				. '$environment={param($Name)return ""};'
			Bootstrap := Admission . this.Transport.Bootstrap . ' -ReadConfig $reader -ReadEnvironment $environment'
			Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
				_Updater_EncodePowerShellCommand(Bootstrap)]
			this.Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(), Args,
				ObjBindMethod(this, "OnDone"), , ObjBindMethod(this, "OnNativeAdopt"), 8192)
			AssertTrue(this.Handle.start(), "actual staging private Job must start")
		} finally _Updater_ClearStagingTransport(this.Transport)
	}

	Wait(BudgetMs := 35000) {
		Started := A_TickCount
		while this.Results.Length == 0 && !TickExpired64(Started, BudgetMs) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, this.Results.Length, "actual private Job callback must settle once")
		AssertTrue(this.NativeState is Map && this.NativeState.Get("TreeQuiesced", false),
			"callback must acknowledge actual Job-empty, process exit and native handle retirement")
		AssertTrue(this.Handle.terminate(), "closed actual worker retirement is idempotent")
		AssertEqual("", this.Results[1]["stderr"], "actual staging receipt never diagnoses from stderr")
		AssertEqual(this.OldBytes, FileRead(this.CurrentExe, "UTF-8"), "all actual refusals preserve exact existing app bytes")
		return this.Results[1]
	}

	Accepted() {
		Result := this.Wait()
		AssertEqual(0, Result["exit"])
		AssertEqual("READY", Result["stdout"], "actual size/digest/persistence checks must produce exact READY")
		Bytes := FileRead(this.NewExe, "RAW")
		AssertEqual(524288, Bytes.Size, "independent native body length")
		AssertEqual(this.Digest, CryptoSha256Bytes(Bytes), "independent fixed expected digest matches actual staged bytes")
		AssertEqual(this.SwapBytes, FileRead(this.SwapPath, "UTF-8"), "actual swap placeholder was persisted as input, never run")
	}

	Refused(Reason, Stage := "", HttpStatus := 0) {
		Result := this.Wait()
		AssertTrue(Result["exit"] != 0, "actual refusal cannot return successful READY")
		Failure := _Updater_ParseStagingFailure(Result["stdout"])
		AssertTrue(Failure["valid"], "actual worker must publish a bounded native receipt")
		AssertEqual(Reason, Failure["reason"])
		if Stage != ""
			AssertEqual(Stage, Failure["receipt"].Get("stage", ""))
		if HttpStatus {
			AssertEqual(HttpStatus, Failure["receipt"].Get("http_status", 0), "typed actual response status")
			AssertEqual("unavailable", Failure["receipt"].Get("http_response_source", ""), "selected relay cannot fabricate response-source evidence")
			AssertTrue(!Failure["receipt"].Has("proxy_connect_status"), "origin/407 response cannot fabricate CONNECT provenance")
		}
		AssertTrue(!FileExist(this.SwapPath), "actual refusal cannot leave a runnable swap input")
		if !this.DenyFile
			AssertTrue(!FileExist(this.NewExe), "actual refused staged executable must be removed after native retirement")
		return Failure
	}

	AssertCancelled() {
		; terminate() deliberately suppresses OnDone. Qualification comes from
		; the exact actual native terminal owner, never an invented callback.
		AssertTrue(this.NativeState is Map && this.NativeState.Get("TreeQuiesced", false),
			"actual cancellation acknowledges Job-empty and native process/handle retirement")
		Claim := this.NativeState.Get("TerminalClaim", 0)
		AssertTrue(Claim is Map && Claim.Get("TreeQuiesced", false), "exact native terminal claim remains inspectable")
		AssertTrue(Claim.Get("NativeExitObserved", false), "exact native process exit was observed before handle closure")
		for Name in ["ProcessHandle", "ThreadHandle", "JobHandle"]
			AssertEqual(0, Claim.Get(Name, -1), "actual owned native handle closes: " . Name)
		AssertEqual(0, Claim.Get("NativeErrors", []).Length, "native retirement errors cannot borrow quiescence success")
		AssertTrue(Claim.Get("ExitCode", 0) != 0, "actual cancellation/deadline terminal cannot report successful staging")
		AssertTrue(this.Results.Length <= 1, "suppressed completion cannot dispatch twice")
		for Result in this.Results
			AssertTrue(Result["exit"] != 0 && Result["stdout"] != "READY", "a naturally completed refusal cannot become successful READY")
		AssertTrue(this.Handle.terminate(), "actual native retirement retry is idempotent")
		AssertEqual(this.OldBytes, FileRead(this.CurrentExe, "UTF-8"), "actual cancellation preserves exact existing app bytes")
	}

	Retire() {
		if this.Closed
			return true
		if IsObject(this.Handle) {
			if !this.Handle.terminate()
				return false
			if !(this.NativeState is Map) || !this.NativeState.Get("TreeQuiesced", false)
				return false
		}
		if this.Directory != "" {
			for Name in ["CurrentExe", "NewExe", "SwapPath"] {
				if !this.HasOwnProp(Name)
					continue
				Path := this.%Name%
				if DirExist(Path)
				DirDelete(Path, false)
				else if FileExist(Path)
					FileDelete(Path)
			}
			DirDelete(this.Directory, false)
			this.Directory := ""
		}
		this.Closed := true
		return true
	}
}

_UpdaterNative_Close(Fixture) {
	Closed := Fixture.Close()
	if !Closed
		Fixture.RetainCleanup()
	AssertTrue(Closed, "actual staging, fixture services, exact root and private inputs must retire")
	if Fixture.RootThumbprint != "" {
		AssertTrue(Fixture.RootRemovalVerified, "independent exact-thumbprint store removal acknowledgement")
		AssertTrue(Fixture.GracefulReceiptVerified, "service cleanup failures cannot borrow independent root removal success")
	}
	AssertEqual(0, Fixture.Events.Count, "actual owned native event handles close")
}

_UpdaterNative_ActualDownloadTrustIntegrityAndRefusal(Contract, Fixture := unset) {
	if !IsSet(Fixture)
		Fixture := _UpdaterNativeTransportOwner()
	PrimaryFailure := 0
	BodyFailed := false
	try {
		Fixture.Start("ServeUpdater")
		for Port in ["second_proxy_port", "refusal_proxy_port"]
			AssertTrue(Fixture.State.Get(Port, 0) > 0 && Fixture.State[Port] <= 65535)
		Untrusted := Fixture.NewRun("/updater/good?marker=staging-fixture")
		Failure := Untrusted.Refused("download", "tls")
		AssertEqual("certificate", Contract.Classify(Failure["receipt"], Map())["cause"], "actual untrusted system-store refusal is typed")
		Fixture.Observe()
		AssertEqual(0, Fixture.State["DownloadRequests"], "untrusted TLS reaches no HTTP download handler")
		Fixture.ChangeTrust(true)
		BeforeSecond := Fixture.State["SecondProxyConnects"]
		BeforeProxy := Fixture.State["ProxyConnects"]
		Trusted := Fixture.NewRun("/updater/start")
		Trusted.Accepted()
		Fixture.Observe()
		AssertEqual(1, Fixture.State["DownloadRedirects"], "actual initial route delivered one redirect")
		AssertEqual(1, Fixture.State["DownloadGood"], "actual full redirected path/query reached owned origin")
		AssertEqual(BeforeSecond + 1, Fixture.State["SecondProxyConnects"], "only the final redirected hop selects the second actual PAC relay")
		AssertEqual(BeforeProxy + 2, Fixture.State["ProxyConnects"], "both exact redirect hops acquire actual owned CONNECT transports")
		AssertTrue(Fixture.State["PacRequests"] >= 1, "actual WinHTTP PAC engine fetched owned script")
		Fixture.NewRun("/updater/wrong-digest").Refused("verify")
		Fixture.NewRun("/updater/small").Refused("verify")
		Fixture.NewRun("/updater/truncated").Refused("download")
		Origin401 := Fixture.NewRun("/updater/401").Refused("download", "http", 401)
		Origin403 := Fixture.NewRun("/updater/403").Refused("download", "http", 403)
		Relay407 := Fixture.NewRun("/updater/407").Refused("download", "http", 407)
		for Failure in [Origin401, Origin403, Relay407]
			AssertEqual("unknown", Contract.Classify(Failure["receipt"], Map())["cause"], "actual HTTP status alone cannot diagnose proxy authentication/blocking")
		FileDenial := Fixture.NewRun("/updater/good?marker=staging-fixture", 30000, true).Refused("download", "file_remove")
		AssertEqual("permission", Contract.Classify(FileDenial["receipt"], Map())["cause"], "actual owned directory-as-file denial is typed Win32 permission")
		Fixture.Observe()
		AssertEqual(1, Fixture.State["DownloadWrongDigest"])
		AssertEqual(1, Fixture.State["DownloadSmall"])
		AssertEqual(1, Fixture.State["DownloadTruncated"])
		AssertEqual(1, Fixture.State["DownloadOrigin401"])
		AssertEqual(1, Fixture.State["DownloadOrigin403"])
		AssertTrue(Fixture.State["ProxyRefusals"] >= 1, "owned actual relay issued Basic-only HTTP407")
		AssertEqual(0, Fixture.State["BasicCredentials"], "current-user credentials cannot downgrade to Basic")
		AssertEqual(0, Fixture.State["DownloadCredentials"], "origin receives no default/proxy credentials, including challenge retries")
		Fixture.ChangeTrust(false)
		Removed := Fixture.NewRun("/updater/good?marker=staging-fixture")
		Failure := Removed.Refused("download", "tls")
		AssertEqual("certificate", Contract.Classify(Failure["receipt"], Map())["cause"])
		Fixture.Observe()
		AssertEqual(7, Fixture.State["DownloadRequests"], "removal and filesystem refusal reach no additional HTTPS handlers")
	} catch Any as Failure {
		PrimaryFailure := Failure
		BodyFailed := true
	} finally _ManagedRemoteFixtureFinalize(Fixture, BodyFailed, PrimaryFailure, _UpdaterNative_Close.Bind(Fixture))
}

_UpdaterNative_WithContract(Callback) {
	global _UpdaterManagedFailureContract, _SharedDir
	Saved := _UpdaterManagedFailureContract
	try {
		_UpdaterManagedFailureContract := ManagedNetworkFailureContract(
			JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8")))
		Callback.Call(_UpdaterManagedFailureContract)
	} finally _UpdaterManagedFailureContract := Saved
}
Test("updater native: actual generated staging CA/PAC integrity and refusals preserve old app",
	(*) => _UpdaterNative_WithContract(_UpdaterNative_ActualDownloadTrustIntegrityAndRefusal))

_UpdaterNative_ActualDeadlineAndCancellation(Contract, Fixture := unset) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterDownloadRequest
	global _UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterInstallObserver, _UpdaterManagedFailureOwner, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	AssertTrue(!_UpdaterDownloadInProgress && !IsObject(_UpdaterDownloadWorker)
		&& !(_UpdaterSwapOwner is Map), "native qualification cannot borrow a foreign live updater transaction")
	Saved := [_UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterDownloadRequest,
		_UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch,
		_UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation,
		_UpdaterInstallObserver, _UpdaterManagedFailureOwner, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS]
	if !IsSet(Fixture)
		Fixture := _UpdaterNativeTransportOwner()
	PrimaryFailure := 0
	BodyFailed := false
	try {
		Fixture.Start("ServeUpdater")
		Fixture.ChangeTrust(true)
		for Kind in ["cancel", "deadline"] {
			State := {Notices: 0}
			Phases := []
			; A controlled shorter budget is passed to BOTH the real parent and
			; the real generated helper, with one original native start tick.
			Budget := Kind == "deadline" ? 15000 : 30000
			UPDATER_HTTP_DOWNLOAD_DEADLINE_MS := Budget
			Run := Fixture.NewRun("/updater/slow", Budget)
			PreviousCritical := Critical("On")
			try {
				_UpdaterDownloadInProgress := true
				_UpdaterDownloadWorker := Run.Handle
				_UpdaterDownloadRequest := 0
				_UpdaterDownloadArtifacts := {NewExe: Run.NewExe, SwapScript: Run.SwapPath}
				_UpdaterDownloadStartedTick := Run.StartedTick
				Epoch := ++_UpdaterSelfUpdateEpoch
				_UpdaterSwapOwner := 0
				_UpdaterExitIntent := 0
				_UpdaterExitInvocation := 0
				_UpdaterManagedFailureOwner := 0
				_UpdaterInstallObserver := (Phase, Reason) => Phases.Push(Phase)
			} finally Critical(PreviousCritical)
			WaitStart := A_TickCount
			while !FileExist(Run.NewExe) && Run.Results.Length == 0 && !TickExpired64(WaitStart, 10000) {
				_SR_TreePoll()
				Sleep(10)
			}
			AssertTrue(FileExist(Run.NewExe) && Run.Results.Length == 0,
				"actual child must own a live partial stage before cancellation/deadline admission")
			Fixture.Observe()
			AssertTrue(Fixture.State["DownloadSlow"] >= (Kind == "cancel" ? 1 : 2),
				"actual owned TLS body handler must be live before retirement")
			AssertEqual(Run.StartedTick, _UpdaterDownloadStartedTick, "parent retains exact original worker clock")
			if Kind == "cancel" {
				AssertTrue(_Updater_CancelSelfUpdateTransaction("Owned native acceptance cancellation.", false, false, Epoch),
					"actual parent cancellation must consume the exact live transaction")
			} else {
				while !TickExpired64(Run.StartedTick, Budget) {
					_SR_TreePoll()
					Sleep(10)
				}
				AssertTrue(_Updater_EnforceDownloadDeadline(A_TickCount, false,
					(Message, Options) => State.Notices += 1,
					_Updater_CancelSelfUpdateTransaction, Epoch),
					"actual monotonic parent budget must consume the exact transaction")
				AssertEqual(1, State.Notices, "actual deadline has one visible primary terminal")
			}
			Run.AssertCancelled()
			AssertTrue(Run.NativeState.Get("TreeQuiesced", false), "native Job/process/handle closure cannot be supplied by a stub")
			AssertTrue(!FileExist(Run.NewExe) && !FileExist(Run.SwapPath),
				"actual parent cancellation must remove its partial owned staging inputs")
			AssertEqual(false, _UpdaterDownloadInProgress)
			AssertEqual(0, _UpdaterDownloadWorker)
			AssertEqual(0, _UpdaterSwapOwner, "actual deadline/cancellation cannot dispatch a swap")
			AssertEqual(1, Phases.Length, "one actual failed terminal, no installing/restarting phase")
			AssertEqual("failed", Phases[1])
			AssertEqual(0, _UpdaterManagedFailureOwner, "cancelled or expired input cannot create retry consent")
			AssertEqual(false, _Updater_CancelSelfUpdateTransaction("Duplicate native cancellation.", false, false),
				"idempotent cancellation cannot publish another terminal")
			AssertEqual(1, Phases.Length)
		}
	} catch Any as Failure {
		PrimaryFailure := Failure
		BodyFailed := true
	} finally {
		; The fixture ledger independently retains every actual worker even if
		; the production cancellation path refuses or an assertion throws.
		try _ManagedRemoteFixtureFinalize(Fixture, BodyFailed, PrimaryFailure, _UpdaterNative_Close.Bind(Fixture))
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
Test("updater native: actual original deadline/cancellation retire owned Job and partial stage",
	(*) => _UpdaterNative_WithContract(_UpdaterNative_ActualDeadlineAndCancellation))

_UpdaterNativePrimaryActualEntryControl(Entry) {
	Fixture := _ManagedRemotePrimaryControlFixture()
	Observed := 0
	try Entry.Call(Map(), Fixture)
	catch as Failure
		Observed := Failure
	AssertEqual(1, Fixture.StartCalls, "the real updater entry must execute the controlled failing body")
	AssertEqual(1, Fixture.CloseCalls, "the original updater cleanup assertions must execute once")
	AssertTrue(Observed == Fixture.Primary, "the real updater entry must retain the exact body exception through failed graceful cleanup")
}
Test("updater native: trust entry preserves primary through graceful refusal (managed-fixture-primary-cleanup)",
	_UpdaterNativePrimaryActualEntryControl.Bind(_UpdaterNative_ActualDownloadTrustIntegrityAndRefusal))
Test("updater native: cancellation entry preserves primary through graceful refusal (managed-fixture-primary-cleanup)",
	_UpdaterNativePrimaryActualEntryControl.Bind(_UpdaterNative_ActualDeadlineAndCancellation))
