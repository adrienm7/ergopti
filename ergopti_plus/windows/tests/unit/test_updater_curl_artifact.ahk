; tests/unit/test_updater_curl_artifact.ahk
; Actual packaged artifact staging over Schannel and an owned SSPI NTLM relay.
; Literal factory controls remain distinct from genuine authenticated wire tests.

_ArtifactCurlFactoryControls() {
	global _DriverDir, _VendorDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\curl_attempt_controls.ps1", "-EnginePath",
				_VendorDir . "\ergopti_curl_attempt.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)))
		AssertTrue(Handle.start(), "actual factory helper model process starts")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 15000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length)
		AssertEqual(0, Observed[1]["exit"])
		AssertEqual("CURL_ATTEMPT_MODEL_CONTROLS:29", Trim(Observed[1]["stdout"], "`r`n "))
		AssertEqual("", Observed[1]["stderr"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "model helper's actual process Job retires")
	}
}
Test("artifact curl: independent factory namespace and causal fallback model controls", _ArtifactCurlFactoryControls)

class _ArtifactNtlmProxyOwner {
	__New(Tls, Mode, ServeRemotePac := false) {
		this.Directory := ""
		this.Event := 0
		this.Handle := 0
		this.NativeState := 0
		this.Results := []
		this.Tls := Tls
		this.Mode := Mode
		this.ServeRemotePac := ServeRemotePac
		this.Identity := _ManagedRemoteFixtureGuid()
		this.Name := "Local\ErgoptiPlus.ArtifactNtlm." . this.Identity
		this.State := Map()
	}
	OnAdopt(State, Native) => this.NativeState := State
	OnDone(Code, Out, Err) => this.Results.Push(Map("exit", Code, "stdout", Out, "stderr", Err))
	Start() {
		this.Directory := _SR_AcquireCaptureDirectory()
		this.Path := this.Directory . "sspi.json"
		this.Event := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true,
			"Int", false, "WStr", this.Name, "Ptr")
		AssertTrue(this.Event && A_LastError != 183, "unique owned SSPI stop event")
		Args := this.Arguments()
		this.Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(), Args,
			ObjBindMethod(this, "OnDone"), , ObjBindMethod(this, "OnAdopt"), 8192)
		AssertTrue(this.Handle.start(), "actual SSPI relay private Job starts")
		Started := A_TickCount
		while !TickExpired64(Started, 20000) {
			_SR_TreePoll()
			if this.Read() && this.State.Get("state", "") == "ready"
				return
			if this.Results.Length
				break
			Sleep(10)
		}
		throw Error("Actual SSPI relay did not become ready.")
	}
	Arguments() {
		global _DriverDir
		Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
			_DriverDir . "\tests\fixtures\artifact_ntlm_proxy.ps1", "-StatePath", this.Path,
			"-StopEvent", this.Name, "-TlsPort", Format("{:d}", this.Tls.State["tls_port"]), "-ChallengeMode", this.Mode]
		if this.ServeRemotePac
			Args.Push("-ServeRemotePac")
		return Args
	}
	Read() {
		try {
			State := JsonParse(FileRead(this.Path, "UTF-8"))
			if !(State is Map) || State.Get("schema_version", 0) != 1
				return false
			this.State := State
			return true
		}
		return false
	}
	Close() {
		try this.Tls.Signal("Observe")
		if this.Event
			DllCall("Kernel32\SetEvent", "Ptr", this.Event, "Int")
		Started := A_TickCount
		while this.Results.Length == 0 && IsObject(this.Handle) && !TickExpired64(Started, 8000) {
			_SR_TreePoll()
			Sleep(10)
		}
		if IsObject(this.Handle)
			AssertTrue(this.Handle.terminate(), "SSPI relay Job physically retires")
		if this.Event {
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", this.Event, "Int"), "owned SSPI stop event closes")
			this.Event := 0
		}
		if this.Directory != "" {
			try {
				if this.Read() {
					StartupFact := _ArtifactNtlmStartupDiagnostic(this.State)
					if StartupFact != ""
						_TestPrint("::notice title=Windows native SSPI startup diagnostic::" . StartupFact)
				}
			} catch Any {
				; Passive reporting cannot replace the original closure assertion.
			}
			AssertTrue(this.Read(), "closed SSPI state remains observable")
			if this.State.Get("failures", 0) > 0 {
				Stage := this.State.Get("failure_stage", "")
				Code := this.State.Get("security_status", "")
				if RegExMatch(Stage, "\A(?:none|acquire_credentials|accept_context|context_token|identity_match)\z")
					&& Type(Code) == "Integer" && Code >= -2147483648 && Code <= 2147483647
					_TestPrint("::notice title=Windows native SSPI fixture::stage=" . Stage . " status=" . Code)
			}
			try {
				ClosureFact := _ArtifactNtlmClosureDiagnostic(this.State)
				if ClosureFact != ""
					_TestPrint("::notice title=Windows native SSPI closure counters::" . ClosureFact)
			} catch Any {
				; Closed scalar observation cannot replace physical retirement assertions.
			}
			try {
				FirstFact := _ArtifactNtlmFirstFailureDiagnostic(this.State)
				TunnelFact := _ArtifactNtlmTunnelFailureDiagnostic(this.State)
				if TunnelFact != ""
					_TestPrint("::notice title=Windows native SSPI tunnel failure::" . TunnelFact)
				if FirstFact != ""
					_TestPrint("::notice title=Windows native SSPI first failure::" . FirstFact)
			} catch Any {
				; Passive provenance cannot change service/refusal/physical-close assertions.
			}
			try {
				Progress := _ArtifactNtlmProgressDiagnostic(this.State)
				try {
					if this.Tls.ReadState() {
						TlsClose := _ArtifactTlsCloseDiagnostic(this.Tls.State)
						if TlsClose != ""
							Progress .= (Progress == "" ? "" : " ") . TlsClose
					}
				}
				if Progress != ""
					_TestPrint("::notice title=Windows native SSPI closed stream observation::" . Progress)
			} catch Any {
				; Optional owned-stream receipt cannot replace original closure assertions.
			}
			AssertTrue(this.NativeState is Map && this.NativeState.Get("TreeQuiesced", false), "SSPI service process and Job handles close")
			AssertEqual(1, this.Results.Length)
			AssertEqual(0, this.Results[1]["exit"], "SSPI service closes with no retained thread or security-context debt")
			AssertEqual("OWNED_SSPI_PROXY_STOPPED", Trim(this.Results[1]["stdout"], "`r`n "))
			AssertEqual("", this.Results[1]["stderr"])
			AssertEqual(5, this.State.Get("handle_controls", 0), "literal SDK sentinel controls remain separate from actual native exchange")
			AssertEqual("stopped", this.State.Get("state", ""))
			AssertEqual(0, this.State.Get("active", -1))
			AssertEqual(0, this.State.Get("failures", -1))
			AssertEqual(0, _SR_CaptureRemove(Map("TmpFile", this.Path, "CaptureDir", this.Directory)), "SSPI private inputs retire")
			this.Directory := ""
		}
	}
}

class _ArtifactCurlDownloadRun extends _UpdaterNativeDownloadRun {
	__New(Tls, Proxy, Path, Digest := "", Size := 524288) {
		super.__New(Tls, Path, 30000, false)
		this.Proxy := Proxy
		this.Size := Size
		if Digest != ""
			this.Digest := Digest
		this.ForeignBytes := ""
	}
	Start() {
		global _VendorDir, _SharedDir, UPDATER_MIN_EXE_SIZE_BYTES
		this.Directory := _SR_AcquireCaptureDirectory()
		this.CurrentExe := this.Directory . "existing.exe"
		this.NewExe := this.Directory . "staged.exe"
		this.SwapPath := this.Directory . "swap.ps1"
		FileAppend(this.OldBytes, this.CurrentExe, "UTF-8-RAW")
		if this.ForeignBytes != ""
			FileAppend(this.ForeignBytes, this.NewExe, "UTF-8-RAW")
		Url := "https://managed-fixture.invalid:" . this.Owner.State["tls_port"] . this.Path
		this.StartedTick := A_TickCount
		this.Transport := _Updater_BuildStagingTransport(_Updater_BuildStagingWorkerScript(), this.SwapBytes,
			Url, this.Digest, this.NewExe, this.SwapPath, this.CurrentExe,
			UPDATER_MIN_EXE_SIZE_BYTES, 5000, _VendorDir . "\ergopti_updater_download.ps1",
			this.DeadlineMs, this.StartedTick, _SharedDir . "\modules\network\proxy_policy.json",
			_SharedDir . "\modules\updater\defaults.json", this.Size)
		try {
			; Only substitute user settings and inherited proxy inventory. Native
			; routing, actual capability, curl, Schannel, SSPI and filesystem run.
			ProxyValue := "127.0.0.1:" . this.Proxy.State["port"]
			Admission := '$reader={param($MaxBytes)[pscustomobject]@{Ok=$true;AutoDetect=$false;Absent=$false;PacUrl="";Proxy="' . ProxyValue . '";Bypass="";NativeError=0;FailureOrigin=""}};'
				. '$environment={param($Name)return ""};'
			Bootstrap := Admission . this.Transport.Bootstrap . ' -ReadConfig $reader -ReadEnvironment $environment'
			Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
				_Updater_EncodePowerShellCommand(Bootstrap)]
			this.Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(), Args,
				ObjBindMethod(this, "OnDone"), , ObjBindMethod(this, "OnNativeAdopt"), 8192)
			AssertTrue(this.Handle.start(), "real authenticated artifact stage private Job starts")
		} finally _Updater_ClearStagingTransport(this.Transport)
	}
}

_ArtifactCurlActualSspiAndStaging() {
	Tls := _UpdaterNativeTransportOwner()
	Proxy := 0
	try {
		Tls.Start("ServeUpdater")
		Tls.ChangeTrust(true)
		for Mode in ["NtlmOnly", "NegotiatePresent"] {
			Proxy := _ArtifactNtlmProxyOwner(Tls, Mode)
			try {
				Proxy.Start()
				Run := _ArtifactCurlDownloadRun(Tls, Proxy, "/updater/good?marker=staging-fixture")
				Tls.DownloadRuns.Push(Run)
				Run.Start()
				if Mode == "NtlmOnly" {
					Run.Accepted()
					Foreign := _ArtifactCurlDownloadRun(Tls, Proxy, "/updater/good?marker=staging-fixture")
					Foreign.ForeignBytes := "Independent preexisting destination bytes must survive."
					Tls.DownloadRuns.Push(Foreign)
					Foreign.Start()
					Refused := Foreign.Wait()
					AssertTrue(Refused["exit"] != 0 && Refused["stdout"] != "READY", "CreateNew refuses a preexisting destination")
					Failure := _Updater_ParseStagingFailure(Refused["stdout"])
					AssertTrue(Failure["valid"], "exclusive-create failure returns actual typed filesystem receipt")
					AssertEqual("file_create", Failure["receipt"].Get("stage", ""))
					AssertEqual(Foreign.ForeignBytes, FileRead(Foreign.NewExe, "UTF-8"), "native create refusal and staging cleanup preserve all preexisting bytes")
					AssertTrue(!FileExist(Foreign.SwapPath), "exclusive-create refusal writes no swap worker")
				} else {
					Result := Run.Wait()
					AssertTrue(Result["exit"] != 0 && Result["stdout"] != "READY", "advertised Negotiate forbids automatic NTLM downgrade")
					Failure := _Updater_ParseStagingFailure(Result["stdout"])
					AssertTrue(Failure["valid"], "actual auth refusal remains a bounded typed receipt")
					AssertTrue(!FileExist(Run.NewExe) && !FileExist(Run.SwapPath), "auth refusal publishes no executable or swap")
				}
			} finally Proxy.Close()
			AssertTrue(Proxy.State.Get("bare", 0) >= 1, "actual first Negotiate-only curl received a bare CONNECT challenge")
			if Mode == "NtlmOnly" {
				AssertEqual(2, Proxy.State.Get("type_one", -1), "each operation has one causal NTLM successor with one native Type1")
				AssertEqual(2, Proxy.State.Get("type_three", -1), "each native Type2 causes one actual SSPI Type3")
				AssertEqual(2, Proxy.State.Get("authenticated", -1), "native security package accepts both independent current-user exchanges")
				AssertTrue(Proxy.State.Get("identity_matched", false), "native context token matches current user without publishing its identity")
				AssertEqual(0, Proxy.State.Get("negotiate", -1))
			} else {
				AssertEqual(0, Proxy.State.Get("type_one", -1), "Negotiate advertisement cannot authorize NTLM successor")
				AssertEqual(0, Proxy.State.Get("type_three", -1))
				AssertEqual(0, Proxy.State.Get("authenticated", -1))
			}
			Proxy := 0
		}
		Tls.Observe()
		AssertEqual(2, Tls.State["DownloadGood"], "both native authenticated tunnels reach actual artifact bytes; only exclusive-create acceptance publishes")
		AssertEqual(0, Tls.State["DownloadCredentials"], "default credentials stay on the proxy, never at origin")
	} finally {
		try {
			if IsObject(Proxy)
				Proxy.Close()
		} finally _UpdaterNative_Close(Tls)
	}
}
Test("artifact curl: actual Schannel staging and SSPI bare NTLM CONNECT with no Negotiate downgrade",
	(*) => _UpdaterNative_WithContract((*) => _ArtifactCurlActualSspiAndStaging()))

; The source runner cannot call the compiled application's install dispatcher
; without taking its real installation reservation. Guard that single join,
; then call the real parser and transport builder with independent metadata.
_ArtifactCurlProductionDispatchJoin() {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO, _VendorDir, _SharedDir
	Dispatch := _DriverFuncBody("Updater_DownloadAndInstall")
	Start := _DriverFuncBody("_Updater_StartStagingWorker")
	Assert(Dispatch != "" && Start != "", "both actual production dispatch owners exist")
	Dispatch := RegExReplace(Dispatch, "m)^[ \t]*;.*$")
	Start := RegExReplace(Start, "m)^[ \t]*;.*$")
	AssertContains(Dispatch,
		"CurrentExe, Release.Tag, StagingEpoch, Release, Request, InstallObserver, Asset.Size)",
		"the compiled install path passes its parsed authenticated size into staging")
	AssertContains(Start,
		'_SharedDir . "\modules\updater\defaults.json", AuthenticatedSize)',
		"the staging owner passes the same size into the real transport builder")
	Tag := "v9.8.7"
	Url := "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO
		. "/releases/download/" . Tag . "/ErgoptiPlus.exe"
	Digest := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	ReleaseJson := '{"assets":[{"name":"ErgoptiPlus.exe","browser_download_url":"'
		. Url . '","digest":"sha256:' . Digest . '","size":524288}]}'
	Asset := _Updater_FindAsset(ReleaseJson, "ErgoptiPlus.exe", Tag)
	Assert(IsObject(Asset), "the actual parser accepts independently supplied release metadata")
	AssertEqual(524288, Asset.Size, "the parser retains the independent byte bound")
	Script := _Updater_BuildStagingWorkerScript()
	AssertContains(Script, 'if ($AuthenticatedSize -gt 0) {$ExpectedSize=Invoke-ErgoptiUpdaterCurlDownload',
		"the real produced worker selects curl for authenticated release assets")
	AssertContains(Script, '$DeadlineMs $StartedTick $AuthenticatedSize $ProxyPolicyPath $UpdaterDefaultsPath $ReadEnvironment}',
		"curl receives the original clock, independent size and canonical policy paths")
	AssertContains(Script, 'if ($AuthenticatedSize -le 0 -or $State.StagedExecutableOwned)',
		"authenticated staging cleanup cannot delete an unowned executable")
	AssertContains(Script, 'if ($AuthenticatedSize -le 0 -or $State.SwapWorkerOwned)',
		"authenticated staging cleanup cannot delete an unowned swap worker")
	DigestCheck := InStr(Script, '$ActualDigest -cne $ExpectedSha256')
	Ready := InStr(Script, 'Write-Output "READY"')
	Assert(DigestCheck > 0 && Ready > DigestCheck,
		"the actual produced worker authenticates persisted bytes before readiness")
	Transport := _Updater_BuildStagingTransport(Script, "exit 0", Asset.Url, Asset.Digest,
		"C:\Temp\review-staged.exe", "C:\Temp\review-swap.ps1", "C:\Temp\review-current.exe",
		1024, 5000, _VendorDir . "\ergopti_updater_download.ps1", 30000, 123456,
		_SharedDir . "\modules\network\proxy_policy.json",
		_SharedDir . "\modules\updater\defaults.json", Asset.Size)
	SizeName := ""
	try {
		for Pair in Transport.Environment {
			if RegExMatch(Pair.Name, "_AUTHENTICATED_SIZE$") {
				AssertEqual("", SizeName, "the real transport publishes exactly one size owner")
				SizeName := Pair.Name
				AssertEqual(524288, Pair.Value, "the inherited size retains independent metadata")
				AssertEqual("524288", EnvGet(Pair.Name), "the actual private environment carries the byte bound")
			}
		}
		Assert(SizeName != "", "the actual inherited size member exists")
		AssertContains(Transport.Bootstrap, '-AuthenticatedSize ([int64]$env:' . SizeName . ')',
			"the real bootstrap reads the same private size with an explicit integer type")
	} finally _Updater_ClearStagingTransport(Transport)
	AssertEqual("", EnvGet(SizeName), "the temporary transport retires its inherited size")
}
Test("artifact curl: production authenticated metadata joins the real private staging transport", _ArtifactCurlProductionDispatchJoin)

_ArtifactNtlmStartupDiagnostic(State) {
	if !(State is Map)
		return ""
	Stage := State.Get("startup_stage", "")
	Code := State.Get("compiler_code", "")
	if !(Stage is String) || !RegExMatch(Stage, "\A(?:identity|compile|sentinel|service)\z")
		|| !(Code is String) || (Code != "" && !RegExMatch(Code, "\ACS[0-9]{4}\z"))
		return ""
	return "stage=" . Stage . " compiler=" . (Code == "" ? "unknown" : Code)
}

_ArtifactNtlmStartupDiagnosticControls() {
	AssertEqual("stage=compile compiler=CS0246", _ArtifactNtlmStartupDiagnostic(
		Map("startup_stage", "compile", "compiler_code", "CS0246", "private", "PRIVATE_CERTIFICATE_PATH")))
	AssertEqual("stage=identity compiler=unknown", _ArtifactNtlmStartupDiagnostic(
		Map("startup_stage", "identity", "compiler_code", "")))
	for Pair in [["Compile", "CS0246"], ["PRIVATE_STAGE", ""], ["compile", "CS0246 PRIVATE_PATH"],
		["compile", "cs0246"], ["compile", 1], [1, ""], ["compile`n", "CS0246"]]
		AssertEqual("", _ArtifactNtlmStartupDiagnostic(Map("startup_stage", Pair[1], "compiler_code", Pair[2])))
	AssertEqual("", _ArtifactNtlmStartupDiagnostic(Map()))
	AssertEqual("", _ArtifactNtlmStartupDiagnostic(0))
}
Test("artifact curl: startup facts preserve strict closure assertions without private compiler text", _ArtifactNtlmStartupDiagnosticControls)

_ArtifactNtlmProxySpawnArgumentControls() {
	for Pair in [[1, "1"], [43210, "43210"], [65535, "65535"]] {
		Port := Pair[1]
		for OrderedPac in [false, true] {
			Tls := {State: Map("tls_port", Port)}
			Proxy := _ArtifactNtlmProxyOwner(Tls, "NtlmOnly", OrderedPac)
			Proxy.Path := "C:\owned-sspi-control\state.json"
			Args := Proxy.Arguments()
			AssertEqual("-TlsPort", Args[11], "the real caller argv retains the TLS port argument")
			AssertEqual("String", Type(Args[12]), "native spawn owns only string argv")
			AssertEqual(Pair[2], Args[12], "literal boundary ports survive caller serialization")
			Admission := ShellRunner_ValidateSpawnArgs(_Updater_PowerShellPath(), Args)
			AssertEqual("", Admission["error"], "the actual SSPI caller reaches the real spawn admission")
			AssertEqual(0, Admission["bad_arg_index"])
			AssertEqual(OrderedPac ? 15 : 14, Args.Length)
			if OrderedPac
				AssertEqual("-ServeRemotePac", Args[15])
			Args[12] := Port
			Refused := ShellRunner_ValidateSpawnArgs(_Updater_PowerShellPath(), Args)
			AssertEqual("Argument 12 must be a string.", Refused["error"],
				"the exact old native caller must fail before any owned process is created")
		}
	}
}
Test("artifact curl: actual SSPI caller serializes its native TLS port before strict spawn admission", _ArtifactNtlmProxySpawnArgumentControls)

_ArtifactNtlmClosureDiagnostic(State) {
	if !(State is Map)
		return ""
	Fact := ""
	for Name in ["active", "failures", "bare", "type_one", "type_three", "authenticated", "negotiate", "pac_requests"] {
		Value := State.Get(Name, "")
		if Type(Value) != "Integer" || Value < 0 || Value > 65535
			return ""
		Fact .= (Fact == "" ? "" : " ") . Name . "=" . Format("{:d}", Value)
	}
	Identity := State.Get("identity_matched", "")
	if Type(Identity) != "Integer" || (Identity != 0 && Identity != 1)
		return ""
	return Fact . " identity_matched=" . (Identity ? "true" : "false")
}

_ArtifactNtlmClosureDiagnosticControls() {
	State := Map("active", 0, "failures", 1, "bare", 2, "type_one", 1, "type_three", 1,
		"authenticated", 1, "negotiate", 0, "pac_requests", 1, "identity_matched", true, "private", "PRIVATE_URL")
	AssertEqual("active=0 failures=1 bare=2 type_one=1 type_three=1 authenticated=1 negotiate=0 pac_requests=1 identity_matched=true", _ArtifactNtlmClosureDiagnostic(State))
	for Name in ["active", "failures", "bare", "type_one", "type_three", "authenticated", "negotiate", "pac_requests", "identity_matched"] {
		Saved := State[Name]
		for Value in ["1", "PRIVATE", -1, 65536, 1.5] {
			State[Name] := Value
			AssertEqual("", _ArtifactNtlmClosureDiagnostic(State))
		}
		State[Name] := Saved
	}
	State["identity_matched"] := 2
	AssertEqual("", _ArtifactNtlmClosureDiagnostic(State))
	AssertEqual("", _ArtifactNtlmClosureDiagnostic(0))
}
Test("artifact curl: closure counters remain bounded and exclude private state", _ArtifactNtlmClosureDiagnosticControls)

_ArtifactNtlmFirstFailureDiagnostic(State) {
	if !(State is Map)
		return ""
	Site := State.Get("first_failure_site", "")
	Family := State.Get("first_failure_family", "")
	Code := State.Get("first_failure_code", "")
	if !(Site is String) || !RegExMatch(Site, "\A(?:none|accept|configure_client|get_client_stream|read_header|parse_header|write_pac|write_challenge|acquire_credentials|accept_context|context_token|identity_match|connect_target|register_target|write_tunnel|get_target_stream|start_receiver|forward_request|forward_response|half_close_request|join_receiver|delete_replaced_context|free_context_buffer|close_context_token|delete_context|free_credentials)\z")
		|| !(Family is String) || !RegExMatch(Family, "\A(?:none|winsock|io|invalid_operation|argument|other|sspi|win32)\z")
		|| Type(Code) != "Integer" || Code < -2147483648 || Code > 2147483647
		return ""
	if (Site == "none") != (Family == "none") || (Site == "none" && Code != 0)
		return ""
	return "site=" . Site . " family=" . Family . " code=" . Format("{:d}", Code)
}

_ArtifactNtlmFirstFailureDiagnosticControls() {
	AssertEqual("site=forward_response family=winsock code=10054", _ArtifactNtlmFirstFailureDiagnostic(
		Map("first_failure_site", "forward_response", "first_failure_family", "winsock", "first_failure_code", 10054, "private", "PRIVATE_URL")))
	AssertEqual("site=delete_context family=sspi code=-2146893054", _ArtifactNtlmFirstFailureDiagnostic(
		Map("first_failure_site", "delete_context", "first_failure_family", "sspi", "first_failure_code", -2146893054)))
	for Site in ["acquire_credentials", "accept_context", "context_token"]
		AssertEqual("site=" . Site . " family=sspi code=-2146893054", _ArtifactNtlmFirstFailureDiagnostic(
			Map("first_failure_site", Site, "first_failure_family", "sspi", "first_failure_code", -2146893054)))
	for Site in ["configure_client", "get_client_stream", "write_pac", "register_target", "write_tunnel", "get_target_stream", "start_receiver"]
		AssertEqual("site=" . Site . " family=io code=-2146232800", _ArtifactNtlmFirstFailureDiagnostic(
			Map("first_failure_site", Site, "first_failure_family", "io", "first_failure_code", -2146232800)))
	AssertEqual("site=none family=none code=0", _ArtifactNtlmFirstFailureDiagnostic(
		Map("first_failure_site", "none", "first_failure_family", "none", "first_failure_code", 0)))
	for Triple in [["PRIVATE_SITE", "winsock", 10054], ["forward_response", "PRIVATE_FAMILY", 10054],
		["forward_response", "winsock", "10054"], ["forward_response", "winsock", 1.5],
		["forward_response", "winsock", 2147483648], ["none", "io", 0], ["accept", "none", 0], ["none", "none", 1]]
		AssertEqual("", _ArtifactNtlmFirstFailureDiagnostic(Map("first_failure_site", Triple[1], "first_failure_family", Triple[2], "first_failure_code", Triple[3])))
	AssertEqual("", _ArtifactNtlmFirstFailureDiagnostic(Map()))
	AssertEqual("", _ArtifactNtlmFirstFailureDiagnostic(0))
}
Test("artifact curl: first failure projection excludes private text and preserves native numeric domains", _ArtifactNtlmFirstFailureDiagnosticControls)

; Join the operation and close snapshot from the same immutable first failure.
_ArtifactNtlmTunnelFailureDiagnostic(State) {
	if _ArtifactNtlmFirstFailureDiagnostic(State) == "" || State.Get("first_failure_site", "") != "forward_response"
		return ""
	Operation := State.Get("first_failure_operation", "")
	Stop := State.Get("first_failure_stop_requested", "")
	Close := State.Get("first_failure_target_close_state", "")
	if !(Operation is String) || !RegExMatch(Operation, "\A(?:read|write)\z")
		|| Type(Stop) != "Integer" || (Stop != 0 && Stop != 1)
		|| Type(Close) != "Integer" || Close < 0 || Close > 2
		return ""
	return "operation=" . Operation . " stop_requested=" . Format("{:d}", Stop) . " target_close_state=" . Format("{:d}", Close)
}

_ArtifactNtlmTunnelFailureProjectionControls() {
	for Operation in ["read", "write"] {
		for Close in [0, 1, 2] {
			State := Map("first_failure_site", "forward_response", "first_failure_family", "winsock", "first_failure_code", 10004,
				"first_failure_operation", Operation, "first_failure_stop_requested", 0, "first_failure_target_close_state", Close)
			Expected := "operation=" . Operation . " stop_requested=0 target_close_state=" . Close
			AssertEqual(Expected, _ArtifactNtlmTunnelFailureDiagnostic(State))
		}
	}
	State := Map("first_failure_site", "forward_response", "first_failure_family", "invalid_operation", "first_failure_code", -2146232798,
		"first_failure_operation", "read", "first_failure_stop_requested", 0, "first_failure_target_close_state", 2)
	AssertEqual("operation=read stop_requested=0 target_close_state=2", _ArtifactNtlmTunnelFailureDiagnostic(State))
	for Pair in [["first_failure_operation", "PRIVATE"], ["first_failure_operation", "none"],
		["first_failure_stop_requested", "0"], ["first_failure_stop_requested", 2],
		["first_failure_target_close_state", "2"], ["first_failure_target_close_state", -1],
		["first_failure_target_close_state", 3], ["first_failure_target_close_state", 1.5],
		["first_failure_site", "forward_request"], ["first_failure_family", "PRIVATE"], ["first_failure_code", "10004"]] {
		Foreign := State.Clone()
		Foreign[Pair[1]] := Pair[2]
		AssertEqual("", _ArtifactNtlmTunnelFailureDiagnostic(Foreign), "foreign or ill-typed close snapshots remain private")
	}
	AssertEqual("", _ArtifactNtlmTunnelFailureDiagnostic(Map()))
	AssertEqual("", _ArtifactNtlmTunnelFailureDiagnostic(0))
}
Test("artifact curl: immutable tunnel failure projection retains actual operation and bounded owner close states", _ArtifactNtlmTunnelFailureProjectionControls)

_ArtifactNtlmTunnelCopyControls() {
	global _DriverDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\artifact_relay_controls.ps1", "-ProxyPath",
				_DriverDir . "\tests\fixtures\artifact_ntlm_proxy.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)))
		AssertTrue(Handle.start(), "actual relay source TCP component process starts")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 15000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length)
		AssertEqual(0, Observed[1]["exit"])
		AssertEqual("ARTIFACT_RELAY_TCP_CONTROLS:4", Trim(Observed[1]["stdout"], "`r`n "))
		AssertEqual("", Observed[1]["stderr"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "actual relay source TCP component Job retires")
	}
}
Test("artifact curl: actual relay copier distinguishes owned interrupted reads from foreign writes and retains failures", _ArtifactNtlmTunnelCopyControls)

_ArtifactNtlmFullDuplexRetirementControls() {
	global _DriverDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\artifact_tunnel_retirement_controls.ps1", "-ProxyPath",
				_DriverDir . "\tests\fixtures\artifact_ntlm_proxy.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)))
		AssertTrue(Handle.start(), "actual full-duplex relay source process starts")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 15000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length)
		AssertEqual(0, Observed[1]["exit"])
		AssertEqual("ARTIFACT_TUNNEL_RETIREMENT_CONTROLS:6", Trim(Observed[1]["stdout"], "`r`n "))
		AssertEqual("", Observed[1]["stderr"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "actual full-duplex relay component Job retires")
	}
}
Test("artifact curl: full-duplex response survives request EOF and bounded retirement still refuses unfinished or foreign work", _ArtifactNtlmFullDuplexRetirementControls)

; Closed scalar observations do not qualify transport, TLS or physical source identity.
_ArtifactNtlmProgressDiagnostic(State) {
	if _ArtifactNtlmTunnelFailureDiagnostic(State) == ""
		return ""
	Fact := ""
	for Name in ["first_failure_response_read", "first_failure_response_written"] {
		Value := State.Get(Name, "")
		if Type(Value) != "Integer" || Value < 0 || Value > 2147483647
			return ""
		Fact .= (Fact == "" ? "" : " ") . Name . "=" . Format("{:d}", Value)
	}
	if State["first_failure_response_written"] > State["first_failure_response_read"]
		return ""
	return Fact
}

_ArtifactTlsCloseDiagnostic(State) {
	if !(State is Map)
		return ""
	Fact := ""
	for Row in [["sequence", 1, 65535], ["called", 0, 1], ["result", -1, 1], ["error", 0, 12],
		["received", 0, 2147483647], ["written", 0, 2147483647], ["close_written", -1, 1048576],
		["pending", -1, 1], ["network_closed", 1, 1]] {
		Name := "tls_close_" . Row[1]
		Value := State.Get(Name, "")
		if Type(Value) != "Integer" || Value < Row[2] || Value > Row[3]
			return ""
		Fact .= (Fact == "" ? "" : " ") . Name . "=" . Format("{:d}", Value)
	}
	if State["tls_close_close_written"] > State["tls_close_written"]
		|| (State["tls_close_called"] == 0 && (State["tls_close_result"] != 0 || State["tls_close_error"] != 0))
		|| (State["tls_close_result"] >= 0 && State["tls_close_error"] != 0)
		return ""
	return Fact
}

_ArtifactTlsCloseProjectionControls() {
	State := Map("tls_close_sequence", 1, "tls_close_called", 1, "tls_close_result", 0,
		"tls_close_error", 0, "tls_close_received", 203, "tls_close_written", 524901,
		"tls_close_close_written", 31, "tls_close_pending", -1, "tls_close_network_closed", 1,
		"private", "PRIVATE_HEADER_BODY_AUTH_URL")
	AssertEqual("tls_close_sequence=1 tls_close_called=1 tls_close_result=0 tls_close_error=0 tls_close_received=203 tls_close_written=524901 tls_close_close_written=31 tls_close_pending=-1 tls_close_network_closed=1", _ArtifactTlsCloseDiagnostic(State))
	for Pair in [["sequence", 0], ["called", 2], ["result", 2], ["error", 13], ["received", -1],
		["written", 2147483648], ["close_written", 1048577], ["close_written", -2], ["pending", 2], ["network_closed", 0],
		["sequence", "1"], ["received", "PRIVATE"], ["result", 0.5], ["error", 1]] {
		Foreign := State.Clone()
		Foreign["tls_close_" . Pair[1]] := Pair[2]
		AssertEqual("", _ArtifactTlsCloseDiagnostic(Foreign))
	}
	AssertEqual("", _ArtifactTlsCloseDiagnostic(Map()))
	AssertEqual("", _ArtifactTlsCloseDiagnostic(0))
	Relay := Map("first_failure_site", "forward_response", "first_failure_family", "winsock", "first_failure_code", 10054,
		"first_failure_operation", "read", "first_failure_stop_requested", 0, "first_failure_target_close_state", 0,
		"first_failure_response_read", 529601, "first_failure_response_written", 529601)
	AssertEqual("first_failure_response_read=529601 first_failure_response_written=529601", _ArtifactNtlmProgressDiagnostic(Relay))
	for Pair in [["first_failure_response_read", -1], ["first_failure_response_written", 529602],
		["first_failure_response_read", "PRIVATE"], ["first_failure_response_written", 2147483648]] {
		Foreign := Relay.Clone()
		Foreign[Pair[1]] := Pair[2]
		AssertEqual("", _ArtifactNtlmProgressDiagnostic(Foreign))
	}
}
Test("artifact curl: closed stream scalar receipt refuses private text and unacknowledged disposal", _ArtifactTlsCloseProjectionControls)

_ArtifactOwnedCloseProgressControls() {
	global _DriverDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\owned_close_progress_controls.ps1", "-FixturePath",
				_DriverDir . "\tests\fixtures\managed_remote_transport.ps1", "-ProxyPath",
				_DriverDir . "\tests\fixtures\artifact_ntlm_proxy.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)))
		AssertTrue(Handle.start(), "actual owned close methods component process starts")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 15000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length)
		AssertEqual(0, Observed[1]["exit"])
		AssertEqual("OWNED_CLOSE_PROGRESS_CONTROLLED_PORTS:11", Trim(Observed[1]["stdout"], "`r`n "))
		AssertEqual("", Observed[1]["stderr"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "owned close source component Job retires")
	}
}
Test("artifact curl: actual owned TLS-close/copy methods preserve failures with controlled native ports", _ArtifactOwnedCloseProgressControls)

_ArtifactQueuedTlsShutdownControls() {
	global _DriverDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\owned_close_progress_controls.ps1", "-FixturePath",
				_DriverDir . "\tests\fixtures\managed_remote_transport.ps1", "-QueuedShutdown", "-ProxyPath",
				_DriverDir . "\tests\fixtures\artifact_ntlm_proxy.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)))
		AssertTrue(Handle.start(), "actual owned close methods component process starts")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 15000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length)
		; The tree completion callback is downstream of exact process/Job HANDLE retirement.
		; Print only one strict closed frame; optional publication preserves the original failure.
		if Observed[1]["exit"] != 0 {
			try {
				Fact := _ArtifactQueuedTlsFailureFact(Observed[1]["stdout"])
				if Fact is Map
					FileAppend("# " . Fact["frame"] . "`n", "*", "UTF-8")
			} catch {
			}
		}
		AssertEqual(0, Observed[1]["exit"])
		AssertEqual("OWNED_QUEUED_TLS_SHUTDOWN_CONTROLLED_PORTS:7", Trim(Observed[1]["stdout"], "`r`n "))
		AssertEqual("", Observed[1]["stderr"])
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "owned close source component Job retires")
	}
}
Test("artifact curl: queued peer TLS close is processed without a peer wait or error waiver", _ArtifactQueuedTlsShutdownControls)


; The native scenario uses the existing shared receipt owner, just as the
; legacy updater scenarios do. An absent owner intentionally removes fields;
; it cannot qualify a typed native filesystem failure.
_ArtifactCurlReceiptContractReceive(Raw, Contract, RaiseAfter := false) {
	global _UpdaterManagedFailureContract
	AssertTrue(_UpdaterManagedFailureContract == Contract, "the callback owns the actual canonical receipt contract")
	Failure := _Updater_ParseStagingFailure(Raw)
	AssertTrue(Failure["valid"], "the independent filesystem envelope is admitted by the actual parser")
	AssertEqual("file_create", Failure["receipt"].Get("stage", ""), "the shared owner preserves the original filesystem operation")
	AssertEqual("dotnet", Failure["receipt"].Get("backend", ""))
	AssertEqual("80", Failure["receipt"].Get("native_errno", ""), "the literal native error survives without text-derived diagnosis")
	if RaiseAfter
		throw Error("ARTIFACT_RECEIPT_CONTROLLED_FAILURE")
}

_ArtifactCurlReceiptContractControls() {
	global _UpdaterManagedFailureContract
	Saved := _UpdaterManagedFailureContract
	Raw := '{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"file_create","failure_provenance":"verified","native_errno_domain":"win32","native_errno":"80"},"cleanup_debt":[],"native_cleanup_debt":false}'
	try {
		_UpdaterManagedFailureContract := 0
		Without := _Updater_ParseStagingFailure(Raw)
		AssertTrue(Without["valid"], "absent presentation policy does not falsify envelope syntax")
		AssertEqual(0, Without["receipt"].Count, "the unconfigured parser intentionally supplies no typed receipt")
		_UpdaterNative_WithContract((Contract) => _ArtifactCurlReceiptContractReceive(Raw, Contract))
		AssertEqual(0, _UpdaterManagedFailureContract, "the shared owner restores the exact absent predecessor after success")
		Caught := false
		try _UpdaterNative_WithContract((Contract) => _ArtifactCurlReceiptContractReceive(Raw, Contract, true))
		catch Error as Failure
			Caught := Failure.Message == "ARTIFACT_RECEIPT_CONTROLLED_FAILURE"
		AssertTrue(Caught, "the original callback failure survives canonical owner retirement")
		AssertEqual(0, _UpdaterManagedFailureContract, "the shared owner restores the exact absent predecessor after failure")
	} finally _UpdaterManagedFailureContract := Saved
}
Test("artifact curl: canonical receipt ownership preserves filesystem stage and restores predecessor (artifact-receipt-contract-owner)", _ArtifactCurlReceiptContractControls)


; Failure facts contain only the exact controlled Case identity and bounded scalars.
; Original native errors, the seven-case census and the 15000ms caller stay authoritative.
_ArtifactQueuedTlsFailureFact(Out) {
	if !(Out is String) || StrLen(Out) > 131072
		return 0
	; InStr searches a NUL-terminated needle even when Chr(0) has length one.
	; Inspect each declared UTF-16 unit so both literal and appended NULs refuse.
	Loop StrLen(Out)
		if Ord(SubStr(Out, A_Index, 1)) == 0
			return 0
	Candidate := 0
	Number := "(-?(?:0|[1-9][0-9]{0,9}))"
	Pattern := "^OWNED_QUEUED_TLS_SHUTDOWN_FAILURE case=([0-6])"
		. " phase=(assert_(?:queued|tls|calls|fact|input|bytes|retired|duplicate|output)|closed|unavailable)"
		. " family=(socket|io|invalid_data|invalid_operation|other)"
	for Field in ["code", "hresult", "fact", "sequence", "called", "result", "error", "received", "written", "close_written", "pending", "network_closed", "calls", "errors", "input"]
		Pattern .= " " . Field . "=" . Number
	Pattern .= "$"
	for Row in StrSplit(Out, "`n", "`r") {
		if !InStr(Row, "OWNED_QUEUED_TLS_SHUTDOWN_FAILURE")
			continue
		if Candidate is Map || StrLen(Row) > 512 || !RegExMatch(Row, Pattern, &Match)
			return 0
		Fact := Map("case", Integer(Match[1]), "phase", Match[2], "family", Match[3], "frame", Row)
		for Index, Field in ["code", "hresult", "fact", "sequence", "called", "result", "error", "received", "written", "close_written", "pending", "network_closed", "calls", "errors", "input"] {
			Value := Integer(Match[Index + 3])
			if Value < -2147483648 || Value > 2147483647 || StrCompare(Match[Index + 3], "-0", true) == 0
				return 0
			Fact[Field] := Value
		}
		if (Fact["family"] == "socket" && Fact["code"] < 0)
			|| (Fact["family"] != "socket" && Fact["code"] != -1)
			|| (Fact["fact"] != 0 && Fact["fact"] != 1)
			return 0
		if Fact["fact"] == 0 {
			if Fact["phase"] == "closed"
				return 0
			for Field in ["sequence", "called", "result", "error", "received", "written", "close_written", "pending", "network_closed", "calls", "errors", "input"]
				if Fact[Field] != -1
					return 0
		} else {
			if Fact["phase"] == "unavailable" || Fact["sequence"] != 1 || Fact["network_closed"] != 1
				|| Fact["called"] < 0 || Fact["called"] > 1 || Fact["result"] < -1 || Fact["result"] > 1
				|| !InStr("|0|1|2|3|6|", "|" . Fact["error"] . "|")
				|| Fact["received"] < 0 || Fact["written"] < 0 || Fact["close_written"] < -1
				|| Fact["pending"] < -1 || Fact["pending"] > 1
				|| Fact["calls"] < 0 || Fact["calls"] > 512 || Fact["errors"] < 0 || Fact["errors"] > Fact["calls"]
				|| Fact["input"] < 0 || Fact["input"] > 16384
				|| (Fact["result"] >= 0 && Fact["error"] != 0)
				|| (Fact["called"] == 0 && Fact["calls"] != 0)
				|| (Fact["close_written"] >= 0 && Fact["close_written"] > Fact["written"])
				return 0
		}
		Candidate := Fact
	}
	return Candidate
}

_ArtifactQueuedTlsFailureFactControls() {
	Raw := "OWNED_QUEUED_TLS_SHUTDOWN_FAILURE case=6 phase=closed family=socket code=10054 hresult=-2146232800 fact=1 sequence=1 called=1 result=-1 error=2 received=12 written=14 close_written=3 pending=1 network_closed=1 calls=3 errors=2 input=3"
	Fact := _ArtifactQueuedTlsFailureFact(Raw)
	AssertTrue(Fact is Map, "independent closed failure frame is admitted")
	AssertEqual(6, Fact["case"])
	AssertEqual(10054, Fact["code"])
	AssertEqual(12, Fact["received"])
	AssertEqual(1, Fact["pending"])
	AssertEqual(Raw, _ArtifactQueuedTlsFailureFact("Private unrelated exception text`r`n" . Raw . "`r`n")["frame"], "only the complete closed row can be published")
	AssertEqual(StrLen(Raw) + 1, StrLen(Raw . Chr(0)), "the negative fixture contains an actual terminal NUL")
	for Bad in [Raw . "`n" . Raw, Raw . " secret=x", "prefix " . Raw, Raw . Chr(0),
		Chr(0) . Raw, "private" . Chr(0) . "`n" . Raw, Raw . "`n" . Chr(0) . "private",
		StrReplace(Raw, "case=6", "case=7"), StrReplace(Raw, "phase=closed", "phase=private"),
		StrReplace(Raw, "code=10054", "code=010054"), StrReplace(Raw, "code=10054", "code=+10054"),
		StrReplace(Raw, "code=10054", "code=2147483648"), StrReplace(Raw, "hresult=-2146232800", "hresult=-2147483649"),
		StrReplace(Raw, "family=socket", "family=other"), StrReplace(Raw, "fact=1", "fact=0"),
		StrReplace(Raw, "sequence=1", "sequence=2"), StrReplace(Raw, "network_closed=1", "network_closed=0"),
		StrReplace(Raw, "received=12", "received=-1"), StrReplace(Raw, "close_written=3", "close_written=-2"),
		StrReplace(Raw, "pending=1", "pending=2"), StrReplace(Raw, "calls=3", "calls=513"),
		StrReplace(Raw, "errors=2", "errors=4"), StrReplace(Raw, "input=3", "input=16385"),
		StrReplace(Raw, "code=10054", "code=-0"), StrReplace(Raw, "phase=closed", "phase=unavailable"),
		StrReplace(Raw, "result=-1", "result=1"), StrReplace(Raw, "called=1", "called=0"),
		StrReplace(Raw, "close_written=3", "close_written=15")]
		AssertEqual(0, _ArtifactQueuedTlsFailureFact(Bad), "malformed/foreign/duplicate/unsettled failure frames cannot publish")
	Unknown := "OWNED_QUEUED_TLS_SHUTDOWN_FAILURE case=0 phase=unavailable family=io code=-1 hresult=-2146232800 fact=0 sequence=-1 called=-1 result=-1 error=-1 received=-1 written=-1 close_written=-1 pending=-1 network_closed=-1 calls=-1 errors=-1 input=-1"
	AssertTrue(_ArtifactQueuedTlsFailureFact(Unknown) is Map, "unknown owner facts remain explicitly unavailable")
	AssertEqual(0, _ArtifactQueuedTlsFailureFact("Private raw exception with no closed frame"))
}
Test("artifact curl: bounded queued TLS failure facts preserve native refusal (queued-tls-failure-facts)", _ArtifactQueuedTlsFailureFactControls)
