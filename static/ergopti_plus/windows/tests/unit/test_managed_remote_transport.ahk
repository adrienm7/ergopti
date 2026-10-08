; static/ergopti_plus/windows/tests/unit/test_managed_remote_transport.ahk

; ==============================================================================
; MODULE: Managed Remote Transport Acceptance Tests
; DESCRIPTION:
; Real production curl generation and readiness through an owned CONNECT relay.
; One warm PowerShell fixture provides TLS, a signed CRL and per-destination PAC.
; Only the user-settings reader is substituted; no transport method is replaced.
; ==============================================================================

global _ManagedRemoteFixtureCleanupDebt := Map()
global _ManagedRemoteFixtureCleanupExitRegistered := false

_ManagedRemoteFixtureGuid() {
	Guid := Buffer(16, 0)
	if DllCall("Ole32\CoCreateGuid", "Ptr", Guid, "Int") != 0
		throw Error("Native managed-network fixture identity allocation failed.")
	Identity := ""
	Loop 16
		Identity .= Format("{:02x}", NumGet(Guid, A_Index - 1, "UChar"))
	return Identity
}

_ManagedRemoteFixtureRetryCleanup(*) {
	global _ManagedRemoteFixtureCleanupDebt
	for Identity, Fixture in _ManagedRemoteFixtureCleanupDebt.Clone() {
		if Fixture.Close()
			_ManagedRemoteFixtureCleanupDebt.Delete(Identity)
	}
	if _ManagedRemoteFixtureCleanupDebt.Count == 0
		SetTimer(_ManagedRemoteFixtureRetryCleanup, 0)
}

_ManagedRemoteFixtureExitCleanup(*) {
	_ManagedRemoteFixtureRetryCleanup()
}

; Diagnostics admit only a closed scalar projection, never raw state or exceptions.
_ManagedRemoteFixtureDiagnostic(State) {
	if !(State is Map) || Type(State.Get("version", "")) != "Integer" || State["version"] != 1
		return ""
	Stage := State.Get("service_failure_stage", "")
	Kind := State.Get("service_failure_kind", "")
	Code := State.Get("service_failure_hresult", "")
	if Type(Stage) != "String" || !RegExMatch(Stage, "\A(?:tls_authenticate|service_request|tunnel_pump|listener_accept|fixture_boundary|fixture_cleanup)\z")
		return ""
	if Type(Kind) != "String" || !RegExMatch(Kind, "\A(?:socket|win32|authentication|invalid_data|io|disposed|invalid_operation|other)\z")
		return ""
	if Type(Code) != "Integer" || Code < -2147483648 || Code > 2147483647
		return ""
	return "stage=" . Stage . " kind=" . Kind . " hresult=" . Format("{:d}", Code)
}

_ManagedRemoteFixtureEmitDiagnostic(State) {
	try {
		Fact := _ManagedRemoteFixtureDiagnostic(State)
		if Fact != ""
			_TestPrint("::notice title=Windows native service diagnostic::" . Fact)
	}
}

; Graceful receipt failures also occur without any native service exception.
; Project only gate outcomes; private state, streams and exception text stay owned.
_ManagedRemoteFixtureCleanupDiagnostic(Completions, State, ReadStatus) {
	Facts := Map("completion", "false", "exit", "unknown", "marker", "unknown", "stderr", "unknown",
		"receipt", "false", "state", "unknown", "root_removed", "unknown", "service_stopped", "unknown",
		"tls_streams", "unknown", "tls_modules", "unknown", "tls_fences", "unknown", "tls_sources", "unknown")
	if Completions is Array && Completions.Length == 1 && Completions[1] is Map {
		Facts["completion"] := "true"
		Completion := Completions[1]
		Code := Completion.Get("exit", "")
		if Type(Code) == "Integer"
			Facts["exit"] := Code == 0 ? "true" : "false"
		Out := Completion.Get("stdout", 0)
		if Out is String
			Facts["marker"] := Trim(Out, "`r`n ") == "OWNED_FIXTURE_STOPPED_ROOT_REMOVED" ? "true" : "false"
		Err := Completion.Get("stderr", 0)
		if Err is String
			Facts["stderr"] := Err == "" ? "true" : "false"
	}
	if !(ReadStatus is String) || !RegExMatch(ReadStatus, "\A(?:not_read|readable|unreadable|invalid)\z")
		ReadStatus := "unknown"
	if ReadStatus == "readable" && State is Map {
		Facts["receipt"] := "true"
		Phase := State.Get("state", 0)
		if Phase is String && RegExMatch(Phase, "\A(?:starting|ready|stopped|failed)\z")
			Facts["state"] := Phase == "stopped" ? "true" : "false"
		for Key in ["root_removed", "service_stopped"]
			Facts[Key] := _ManagedRemoteFixtureDiagnosticBoolean(State.Get(Key, ""))
		for Pair in [["tls_streams", "server_tls_owned_streams"], ["tls_modules", "server_tls_owned_modules"],
			["tls_fences", "server_tls_owned_source_fences"]] {
			Count := State.Get(Pair[2], "")
			if Type(Count) == "Integer" && Count >= 0 && Count <= 2147483647
				Facts[Pair[1]] := Count == 0 ? "true" : "false"
		}
		Facts["tls_sources"] := _ManagedRemoteFixtureDiagnosticBoolean(State.Get("server_tls_source_unchanged", ""))
	}
	Gate := "none"
	Fields := ""
	for Key in ["completion", "exit", "marker", "stderr", "receipt", "state", "root_removed", "service_stopped",
		"tls_streams", "tls_modules", "tls_fences", "tls_sources"] {
		Value := Facts[Key]
		if Gate == "none" && Value != "true"
			Gate := Key
		Fields .= " " . Key . "=" . Value
	}
	return "cleanup_gate=" . Gate . " receipt_read=" . ReadStatus . Fields
}

_ManagedRemoteFixtureDiagnosticBoolean(Value) {
	return Type(Value) == "Integer" && (Value == 0 || Value == 1) ? (Value ? "true" : "false") : "unknown"
}

_ManagedRemoteFixtureEmitCleanupDiagnostic(Completions, State, ReadStatus, PrintFn := unset) {
	if !IsSet(PrintFn)
		PrintFn := _TestPrint
	try {
		PrintFn.Call("::notice title=Windows native fixture cleanup diagnostic::"
			. _ManagedRemoteFixtureCleanupDiagnostic(Completions, State, ReadStatus))
		return "reported"
	} catch {
		; The owner retains refusal without recursively calling the unavailable sink.
		return "unavailable"
	}
}

_ManagedRemoteFixtureDiagnosticControls() {
	State := Map("version", 1, "service_failure_stage", "tls_authenticate",
		"service_failure_kind", "win32", "service_failure_hresult", -2146893042,
		"message", "private exception text", "root_subject", "private certificate identity")
	AssertEqual("stage=tls_authenticate kind=win32 hresult=-2146893042", _ManagedRemoteFixtureDiagnostic(State), "only closed scalar facts enter the native annotation")
	for Pair in [["service_failure_stage", "tls_authenticate`nprivate"], ["service_failure_kind", "CryptographicException"],
		["service_failure_hresult", "-2146893042"], ["service_failure_hresult", 2147483648], ["service_failure_hresult", -2147483649], ["version", "1"]] {
		Invalid := State.Clone()
		Invalid[Pair[1]] := Pair[2]
		AssertEqual("", _ManagedRemoteFixtureDiagnostic(Invalid), "unknown domains and noncanonical native integers cannot reach output")
	}
	State["service_failure_hresult"] := -2147483648
	AssertContains(_ManagedRemoteFixtureDiagnostic(State), "hresult=-2147483648")
	State["service_failure_hresult"] := 2147483647
	AssertContains(_ManagedRemoteFixtureDiagnostic(State), "hresult=2147483647")
}
Test("managed remote native: diagnostic annotation admits only closed scalar domains", _ManagedRemoteFixtureDiagnosticControls)

_ManagedRemoteFixtureCleanupDiagnosticRetained() {
	global TEST_RESULTS_FILE
	Fixture := _ManagedRemoteFixtureOwner()
	Directory := _SR_AcquireCaptureDirectory()
	Fixture.Capture := Map("TmpFile", Directory . "output.tmp", "CaptureDir", Directory)
	FileAppend('{"version":1,"state":"ready","private":"PRIVATE_FIXTURE_INPUT"}', Fixture.Capture["TmpFile"], "UTF-8-RAW")
	Fixture.Completions.Push(Map("exit", 1, "stdout", "PRIVATE_STDOUT", "stderr", "PRIVATE_STDERR"))
	Offset := FileGetSize(TEST_RESULTS_FILE)
	try {
		AssertTrue(Fixture.Close(), "controlled failed completion still retires only its owned capture")
		AssertFalse(Fixture.GracefulReceiptVerified, "diagnostics cannot grant graceful receipt success")
		_ManagedRemoteFixtureEmitDiagnostic(Map("version", 1, "service_failure_stage", "fixture_cleanup",
			"service_failure_kind", "other", "service_failure_hresult", -1, "private", "PRIVATE_EXCEPTION"))
		Transcript := FileOpen(TEST_RESULTS_FILE, "r", "UTF-8")
		try {
			Transcript.Seek(Offset, 0)
			Output := Transcript.Read()
		} finally Transcript.Close()
		AssertContains(Output, "cleanup_gate=exit", "failed completion without native service facts must reach the retained TAP receipt")
		AssertContains(Output, "stage=fixture_cleanup kind=other hresult=-1", "native service facts use the same retained TAP channel")
		AssertFalse(InStr(Output, "PRIVATE_"), "cleanup diagnostics never publish private fixture inputs or native streams")
	} finally {
		AssertTrue(Fixture.Close(), "controlled fixture cleanup remains idempotent")
	}
}
Test("managed remote native: failed fixture completion retains cleanup gate (managed-fixture-cleanup-diagnostic)",
	_ManagedRemoteFixtureCleanupDiagnosticRetained)

_ManagedRemoteFixtureCleanupReceiptControls() {
	global TEST_RESULTS_FILE
	for Valid in [false, true] {
		Fixture := _ManagedRemoteFixtureOwner()
		Directory := _SR_AcquireCaptureDirectory()
		Fixture.Capture := Map("TmpFile", Directory . "output.tmp", "CaptureDir", Directory)
		State := Valid ? '{"state":"stopped","root_removed":true,"service_stopped":true,"server_tls_owned_streams":0,"server_tls_owned_modules":0,"server_tls_owned_source_fences":0,"server_tls_source_unchanged":true}' : "PRIVATE_INVALID_JSON"
		FileAppend(State, Fixture.Capture["TmpFile"], "UTF-8-RAW")
		Fixture.Completions.Push(Map("exit", 0, "stdout", "OWNED_FIXTURE_STOPPED_ROOT_REMOVED", "stderr", ""))
		Offset := FileGetSize(TEST_RESULTS_FILE)
		try {
			AssertTrue(Fixture.Close())
			AssertEqual(Valid, Fixture.GracefulReceiptVerified, "observation preserves original receipt admission")
			Transcript := FileOpen(TEST_RESULTS_FILE, "r", "UTF-8")
			try {
				Transcript.Seek(Offset, 0)
				Output := Transcript.Read()
			} finally Transcript.Close()
			if Valid
				AssertEqual("", Output, "successful graceful cleanup has no refusal diagnostic")
			else {
				AssertContains(Output, "cleanup_gate=receipt receipt_read=unreadable", "caught receipt parsing failure retains its failed gate")
				AssertFalse(InStr(Output, "PRIVATE_"))
			}
		} finally AssertTrue(Fixture.Close())
	}
}
Test("managed remote native: cleanup retains unreadable receipt and quiet success (managed-fixture-cleanup-diagnostic)",
	_ManagedRemoteFixtureCleanupReceiptControls)

_ManagedRemoteFixtureCleanupDiagnosticControls() {
	Complete := [Map("exit", 0, "stdout", "OWNED_FIXTURE_STOPPED_ROOT_REMOVED`n", "stderr", "")]
	State := Map("state", "stopped", "root_removed", true, "service_stopped", true,
		"server_tls_owned_streams", 0, "server_tls_owned_modules", 0, "server_tls_owned_source_fences", 0,
		"server_tls_source_unchanged", true, "private", "PRIVATE_STATE")
	AssertContains(_ManagedRemoteFixtureCleanupDiagnostic(Complete, State, "readable"), "cleanup_gate=none")
	for Pair in [["completion", []], ["completion", [Map(), Map()]],
		["exit", [Map("exit", 1)]], ["marker", [Map("exit", 0, "stdout", "PRIVATE_STDOUT")]],
		["stderr", [Map("exit", 0, "stdout", "OWNED_FIXTURE_STOPPED_ROOT_REMOVED", "stderr", "PRIVATE_STDERR")]]] {
		Output := _ManagedRemoteFixtureCleanupDiagnostic(Pair[2], State, "readable")
		AssertContains(Output, "cleanup_gate=" . Pair[1] . " ")
		AssertFalse(InStr(Output, "PRIVATE_"))
	}
	for Status in ["not_read", "unreadable", "invalid", "PRIVATE_READ_STATUS"] {
		Output := _ManagedRemoteFixtureCleanupDiagnostic(Complete, State, Status)
		AssertContains(Output, "cleanup_gate=receipt ")
		AssertFalse(InStr(Output, "PRIVATE_"))
	}
	for Pair in [["state", "state", "ready"], ["root_removed", "root_removed", false],
		["service_stopped", "service_stopped", false], ["tls_streams", "server_tls_owned_streams", 1],
		["tls_modules", "server_tls_owned_modules", 1], ["tls_fences", "server_tls_owned_source_fences", 1],
		["tls_sources", "server_tls_source_unchanged", false]] {
		Changed := State.Clone()
		Changed[Pair[2]] := Pair[3]
		AssertContains(_ManagedRemoteFixtureCleanupDiagnostic(Complete, Changed, "readable"), "cleanup_gate=" . Pair[1] . " ")
		Changed[Pair[2]] := "PRIVATE_FIELD"
		Output := _ManagedRemoteFixtureCleanupDiagnostic(Complete, Changed, "readable")
		AssertContains(Output, "cleanup_gate=" . Pair[1] . " ")
		AssertContains(Output, Pair[1] . "=unknown")
		AssertFalse(InStr(Output, "PRIVATE_"))
	}
	BothFailed := State.Clone()
	BothFailed["root_removed"] := false
	BothFailed["service_stopped"] := false
	AssertContains(_ManagedRemoteFixtureCleanupDiagnostic(Complete, BothFailed, "readable"), "cleanup_gate=root_removed ")
	BothFailed["state"] := "failed"
	AssertContains(_ManagedRemoteFixtureCleanupDiagnostic(Complete, BothFailed, "readable"), "cleanup_gate=state ")
}
Test("managed remote native: cleanup formatter covers every receipt gate (managed-fixture-cleanup-diagnostic)",
	_ManagedRemoteFixtureCleanupDiagnosticControls)

_ManagedRemoteFixtureCleanupReporterUnavailable() {
	global TEST_RESULTS_FILE
	Fixture := _ManagedRemoteFixtureOwner()
	Fixture.Completions.Push(Map("exit", 1, "stdout", "PRIVATE_STDOUT", "stderr", ""))
	Directory := _SR_AcquireCaptureDirectory()
	SavedPath := TEST_RESULTS_FILE
	try {
		; An owned directory refuses the real TAP file writer without replacing it.
		TEST_RESULTS_FILE := Directory
		Closed := Fixture.Close()
	} finally {
		TEST_RESULTS_FILE := SavedPath
		DirDelete(Directory, false)
	}
	AssertTrue(Closed, "a reporter refusal cannot replace the original cleanup result")
	AssertFalse(Fixture.Closing, "reporter failure cannot retain the closing fence")
	AssertFalse(Fixture.GracefulReceiptVerified, "reporter failure grants no graceful acknowledgment")
	AssertTrue(Fixture.HasOwnProp("CleanupDiagnosticStatus") && Fixture.CleanupDiagnosticStatus == "unavailable",
		"an actual failed TAP writer must retain a bounded diagnostic-unavailable outcome on its owner")
}
Test("managed remote native: failed TAP reporter retains unavailable outcome (managed-fixture-cleanup-diagnostic)",
	_ManagedRemoteFixtureCleanupReporterUnavailable)

class _ManagedRemoteFixturePrimaryFailureOwner extends _ManagedRemoteFixtureOwner {
	RetireRequests() {
		throw ValueError("PRIVATE_PRIMARY_FAILURE")
	}
}

_ManagedRemoteFixtureFailPrinter(State, Line) {
	State.Calls += 1
	throw Error("PRIVATE_REPORTER_FAILURE")
}

_ManagedRemoteFixtureCleanupReporterPreservesPrimary() {
	for PrimaryFailure in [false, true] {
		Fixture := PrimaryFailure ? _ManagedRemoteFixturePrimaryFailureOwner() : _ManagedRemoteFixtureOwner()
		State := {Calls: 0}
		Fixture.CleanupDiagnosticPrinter := _ManagedRemoteFixtureFailPrinter.Bind(State)
		Fixture.Completions.Push(Map("exit", 1, "stdout", "PRIVATE_STDOUT", "stderr", ""))
		Closed := Fixture.Close()
		AssertEqual(!PrimaryFailure, Closed, "diagnostic refusal preserves either original cleanup result")
		AssertFalse(Fixture.Closing, "the closing fence always resets after a reporter exception")
		AssertFalse(Fixture.GracefulReceiptVerified, "diagnostic refusal never grants graceful acknowledgment")
		AssertEqual("unavailable", Fixture.CleanupDiagnosticStatus, "the owner keeps only a bounded refusal outcome")
		AssertEqual(1, State.Calls, "diagnostic refusal never recurses through the same failed printer")
		if PrimaryFailure
			AssertEqual("ValueError", Fixture.LastCleanupError, "the reporter exception cannot overwrite the original cleanup failure")
		else {
			AssertFalse(Fixture.HasOwnProp("LastCleanupError"), "reporter refusal does not fabricate a cleanup failure")
			AssertTrue(Fixture.Close(), "an already retired fixture retains its original idempotent result")
			AssertEqual(1, State.Calls, "idempotent cleanup does not retry an unavailable diagnostic")
		}
	}
}
Test("managed remote native: failed printer preserves cleanup result and fence (managed-fixture-cleanup-diagnostic)",
	_ManagedRemoteFixtureCleanupReporterPreservesPrimary)

class _ManagedRemoteFixtureOwner {
	__New() {
		global _DriverDir, _ManagedRemoteFixtureCleanupExitRegistered
		this.Identity := _ManagedRemoteFixtureGuid()
		this.Prefix := "Local\ErgoptiPlus.ManagedNetworkFixture." . this.Identity
		this.Script := _DriverDir . "\tests\fixtures\managed_remote_transport.ps1"
		this.Events := Map()
		this.Handle := 0
		this.NativeState := 0
		this.Completions := []
		this.CleanupHandle := 0
		this.CleanupCompletions := []
		this.RootThumbprint := ""
		this.RootSubject := ""
		this.RootRemovalVerified := false
		this.GracefulReceiptVerified := false
		this.CleanupDiagnosticStatus := "not_requested"
		this.CleanupDiagnosticPrinter := _TestPrint
		this.Closing := false
		this.Closed := false
		this.Requests := Map()
		this.ReadyOwners := []
		this.ReadyCancels := []
		this.ProxyRuns := []
		this.Reader := ObjBindMethod(this, "ReadConfig")
		this.GenerationCount := 0
		this.Mode := "fixed"
		this.Capture := 0
		this.State := Map()
		if !_ManagedRemoteFixtureCleanupExitRegistered {
			OnExit(_ManagedRemoteFixtureExitCleanup)
			_ManagedRemoteFixtureCleanupExitRegistered := true
		}
	}

	Start(ServerMode := "Serve") {
		if ServerMode != "Serve" && ServerMode != "ServeUpdater"
			throw ValueError("Unsupported owned fixture mode")
		Directory := _SR_AcquireCaptureDirectory()
		this.Capture := Map("TmpFile", Directory . "output.tmp", "CaptureDir", Directory)
		for Name in ["InstallRoot", "RemoveRoot", "Observe", "Shutdown"] {
			Event := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", false,
				"Int", false, "WStr", this.Prefix . "." . Name, "Ptr")
			NativeError := A_LastError
			if !Event
				throw Error("Owned managed-network event allocation failed (Win32 " . NativeError . ").")
			this.Events[Name] := Event
			if NativeError == 183
				throw Error("Unique managed-network fixture event already exists.")
		}
		this.Handle := ShellRunner_SpawnTreeOwned("powershell.exe",
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				this.Script, "-StatePath", this.Capture["TmpFile"], "-EventPrefix", this.Prefix, "-Mode", ServerMode],
			ObjBindMethod(this, "OnServerDone"), , ObjBindMethod(this, "OnNativeAdopt"), 8192)
		if !this.Handle.start()
			throw Error("Actual managed-network native fixture did not start.")
		this.WaitState("ready", "untrusted", 20000)
		AssertTrue(this.State.Get("curl_schannel", false), "the actual shipped curl backend must be Schannel")
		AssertEqual("native_openssl3", this.State.Get("server_tls_backend", ""), "the independent fixture server must execute native TLS")
		AssertTrue(Type(this.State.Get("server_tls_version", "")) == "Integer"
			&& this.State["server_tls_version"] >= 0x30000000 && this.State["server_tls_version"] < 0x40000000, "actual server OpenSSL3 ABI")
		for Name in ["server_tls_ssl_image_sha256", "server_tls_crypto_image_sha256"]
			AssertTrue(RegExMatch(this.State.Get(Name, ""), "\A[0-9a-f]{64}\z") > 0, "actual source-fenced native TLS image hash")
		for Name in ["server_tls_key_ephemeral", "server_tls_private_der_cleared", "server_tls_source_unchanged"]
			AssertTrue(this.State.Get(Name, false), "actual in-memory TLS key and provider ownership")
		AssertEqual(2, this.State.Get("server_tls_owned_modules", -1), "only the two explicitly acquired native module references are owned")
		AssertTrue(this.State.Get("server_tls_owned_source_fences", -1) >= 2, "both exact provider images stay fenced during native use")
		AssertEqual(0, this.State.Get("server_tls_owned_streams", -1), "ready server has no borrowed TLS connection")
		this.RootThumbprint := this.State.Get("root_thumbprint", "")
		this.RootSubject := this.State.Get("root_subject", "")
		AssertTrue(RegExMatch(this.RootThumbprint, "^[0-9A-F]{40}$") > 0, "owned root thumbprint is required before any store change")
		AssertEqual("CN=ErgoptiPlus managed-network fixture " . this.Identity, this.RootSubject,
			"only the unique fixture root may enter CurrentUser/Root")
		for Key in ["tls_port", "proxy_port", "http_port"]
			AssertTrue(this.State.Get(Key, 0) > 0 && this.State.Get(Key, 0) <= 65535,
				"actual native listener port must be acknowledged")
		this.BaseUrl := "https://managed-fixture.invalid:" . this.State["tls_port"] . "/v1"
		this.Port := Map("managed_settings", this.Reader)
	}

	OnNativeAdopt(State, Native) {
		this.NativeState := State
	}

	OnServerDone(Code, Out, Err) {
		this.Completions.Push(Map("exit", Code, "stdout", Out, "stderr", Err))
	}

	OnCleanupDone(Code, Out, Err) {
		this.CleanupCompletions.Push(Map("exit", Code, "stdout", Out, "stderr", Err))
	}

	ReadState() {
		try {
			State := JsonParse(FileRead(this.Capture["TmpFile"], "UTF-8"))
		} catch as ReadError {
			; The owned producer updates one file; a partial write is retried within
			; the enclosing budget, while terminal failure is checked separately.
			this.LastStateReadError := Type(ReadError)
			return false
		}
		if !(State is Map) || State.Get("version", 0) != 1
			throw Error("Actual fixture published an unsupported state receipt.")
		if State.Get("state", "") == "failed" {
			_ManagedRemoteFixtureEmitDiagnostic(State)
			throw Error("Actual managed-network fixture reported native failure.")
		}
		this.State := State
		return true
	}

	WaitState(ExpectedState, ExpectedPhase, BudgetMs, PreviousSequence := -1) {
		Started := A_TickCount
		while !TickExpired64(Started, BudgetMs) {
			_SR_TreePoll()
			if this.ReadState() && this.State.Get("state", "") == ExpectedState
					&& this.State.Get("phase", "") == ExpectedPhase
					&& this.State.Get("sequence", -1) > PreviousSequence
				return true
			if this.Completions.Length > 0
				throw Error("Owned fixture settled before its required state acknowledgment.")
			Sleep(10)
		}
		throw Error("Owned managed-network fixture state budget expired.")
	}

	Signal(Name) {
		if !this.Events.Has(Name) || !DllCall("Kernel32\SetEvent", "Ptr", this.Events[Name], "Int")
			throw Error("Owned managed-network fixture event was not acknowledged.")
	}

	ChangeTrust(Installed) {
		Sequence := this.State["sequence"]
		this.Signal(Installed ? "InstallRoot" : "RemoveRoot")
		this.WaitState("ready", Installed ? "trusted" : "removed", 10000, Sequence)
		if !Installed
			AssertTrue(this.State.Get("root_removed", false), "exact current-user root removal must be acknowledged")
	}

	Observe() {
		Sequence := this.State["sequence"]
		Phase := this.State["phase"]
		this.Signal("Observe")
		this.WaitState("ready", Phase, 5000, Sequence)
		if this.State.Get("ServiceFailures", 0) > 0
			_ManagedRemoteFixtureEmitDiagnostic(this.State)
		AssertEqual(0, this.State.Get("ServiceFailures", -1), "owned fixture must expose unexpected native service failures")
	}

	ReadConfig() {
		return Map("auto_detect", false,
			"pac_url", this.Mode == "pac" ? "http://127.0.0.1:" . this.State["http_port"] . "/proxy.pac" : "",
			"proxy", this.Mode == "fixed" ? "127.0.0.1:" . this.State["proxy_port"] : "", "bypass", "")
	}

	ResolveProxy(Url, Callback) {
		; Only replace the native user-settings read. The actual resolver worker,
		; native PAC engine, native trust and inherited explicit env remain live.
		global _SYSTEM_PROXY_PAC_PENDING
		Accepted := SystemProxy_ResolveCurlAsync(Url, Callback, this.Reader, 0, EnvGet)
		if IsObject(_SYSTEM_PROXY_PAC_PENDING) && _SYSTEM_PROXY_PAC_PENDING.Reader == this.Reader
			this.ProxyRuns.Push(_SYSTEM_PROXY_PAC_PENDING)
		return Accepted
	}

	GenerationSucceeded(Result, Text, Usage) {
		Result["success"].Push(Map("text", Text, "usage", Usage))
	}

	GenerationFailed(Result, Info := "") {
		Result["failure"].Push(Info)
	}

	CheckGeneration(ExpectedSuccess) {
		global _LLM_Remote_Async
		this.GenerationCount += 1
		ReqId := "managed_network_" . this.Identity . "_" . this.GenerationCount
		Result := Map("success", [], "failure", [])
		Resolved := Map("Format", "openai", "Token", "managed-network-fixture-token", "Model", "fixture")
		SuccessFn := ObjBindMethod(this, "GenerationSucceeded", Result)
		FailureFn := ObjBindMethod(this, "GenerationFailed", Result)
		Reservation := _LLMRemote_ReserveRequest(ReqId, SuccessFn, FailureFn, 15000, A_TickCount, Resolved)
		this.Requests[ReqId] := Reservation
		AssertTrue(_LLMRemote_DispatchCurl(ReqId, Resolved,
			this.BaseUrl . "/chat/completions?marker=managed-network-fixture",
			'{"messages":[],"stream":false}',
			SuccessFn, FailureFn, 15000, this.Port, Reservation),
			"the actual production generation entrypoint must own its request")
		Started := A_TickCount
		while Result["success"].Length + Result["failure"].Length == 0 && !TickExpired64(Started, 18000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Result["success"].Length + Result["failure"].Length,
			"actual generation must settle once within the native acceptance budget")
		AssertEqual(ExpectedSuccess ? 1 : 0, Result["success"].Length,
			"generation must obey actual system-root admission")
		AssertEqual(ExpectedSuccess ? 0 : 1, Result["failure"].Length)
		if ExpectedSuccess
			AssertEqual("managed-network-ok", Result["success"][1]["text"], "actual production parser must consume the TLS response")
		else {
			AssertTrue(Result["failure"][1] is Map, "TLS refusal must expose a real failure receipt")
			AssertEqual("transport", Result["failure"][1].Get("reason", ""), "an untrusted root may not be disguised as proxy admission failure")
		}
		AssertFalse(_LLM_Remote_Async.Has(ReqId), "settled generation must retire its own registry entry")
	}

	ReadyCompleted(Result, Owner, Ready) {
		CancelFn := Owner.Get("cancel", 0)
		if HasMethod(CancelFn, "Call")
			this.ReadyCancels.Push(CancelFn)
		Result.Push(Ready)
	}

	CheckReadiness(ExpectedSuccess) {
		global LLM_API_PROVIDERS
		ProviderId := "managed_network_" . this.Identity
		AssertFalse(LLM_API_PROVIDERS.Has(ProviderId), "owned acceptance provider identity must be unique")
		Result := []
		Owner := LLM_AuxBegin(ProviderId, Map("backend", "api", "endpoint", this.BaseUrl, "identity", ProviderId))
		this.ReadyOwners.Push(Owner)
		LLM_API_PROVIDERS[ProviderId] := Map("Format", "openai", "BaseUrl", this.BaseUrl)
		try {
			LLM_RemoteIsReady_Async(Map("Provider", ProviderId, "Token", "managed-network-fixture-token"),
				ObjBindMethod(this, "ReadyCompleted", Result, Owner), Owner, this.Port)
			Started := A_TickCount
			while Result.Length == 0 && !TickExpired64(Started, 18000) {
				_SR_TreePoll()
				Sleep(10)
			}
			AssertEqual(1, Result.Length, "actual readiness must settle once within its native budget")
			AssertEqual(ExpectedSuccess, Result[1], "readiness must obey the actual system root and selected relay")
		} finally {
			CancelFn := Owner.Get("cancel", 0)
			if HasMethod(CancelFn, "Call")
				this.ReadyCancels.Push(CancelFn)
			_LLM_AuxRetireOwner(Owner)
			LLM_API_PROVIDERS.Delete(ProviderId)
		}
	}

	RetireRequests() {
		global _LLM_Remote_Async, _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS
		for ReqId, Entry in this.Requests {
			if _LLM_Remote_Async.Has(ReqId) && _LLM_Remote_Async[ReqId] == Entry {
				LLM_RemoteCancelAsync(ReqId)
				if !Entry.Has("tmp_status") {
					if Entry.Has("proxy_deadline")
						SetTimer(Entry["proxy_deadline"], 0)
					_LLMRemote_DeleteOwned(ReqId, Entry)
				}
			}
		}
		for Owner in this.ReadyOwners
			_LLM_AuxRetireOwner(Owner)
		Started := A_TickCount
		while !TickExpired64(Started, 5000) {
			Complete := true
			for CancelFn in this.ReadyCancels {
				if CancelFn.Call() != true
					Complete := false
			}
			for Debts in [_HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS] {
				for Id, Request in Debts.Clone() {
					if this.HasOwnProp("BaseUrl") && InStr(Request.Url, this.BaseUrl . "/") == 1 {
						Request.Abort()
						Request._Cleanup()
						Complete := false
					}
				}
			}
			for Run in this.ProxyRuns {
				if IsObject(Run.Handle) && !Run.Handle.terminate() {
					Complete := false
					continue
				}
				if !Run.Done
					_SystemProxy_FinishPac(Run, -1, "", "fixture cancellation")
				if Run.Capture is Map && _SR_CaptureRemove(Run.Capture) != 0
					Complete := false
			}
			for ReqId, Entry in this.Requests {
				if !_LLM_CurlReleaseEntryProcess(Entry, true)
					Complete := false
				for Key in ["tmp_payload", "tmp_stdout", "tmp_config", "tmp_status", "tmp_exit"] {
					if Entry.Has(Key) && FileExist(Entry[Key])
						Complete := false
				}
				if _LLM_Remote_Async.Has(ReqId) && _LLM_Remote_Async[ReqId] == Entry {
					_LLMRemote_PollCurl(ReqId)
					Complete := false
				}
			}
			if Complete
				return true
			Sleep(10)
		}
		return false
	}

	Close() {
		if this.Closed
			return true
		if this.Closing
			return false
		this.Closing := true
		FinalState := 0
		ReceiptRead := "not_read"
		try {
			if !this.RetireRequests()
				return false
			if IsObject(this.Handle) {
				if this.Completions.Length == 0 && this.Events.Has("Shutdown") {
					this.Signal("Shutdown")
					Started := A_TickCount
					while this.Completions.Length == 0 && !TickExpired64(Started, 8000) {
						_SR_TreePoll()
						Sleep(10)
					}
				}
				if !this.Handle.terminate()
					return false
				if this.NativeState is Map && !this.NativeState.Get("TreeQuiesced", false)
					return false
			}
			; Reuse the original owned state after native tree quiescence, before its removal.
			; Diagnostic I/O is bounded and cannot replace the original cleanup assertion.
			try {
				if this.Capture is Map && FileGetSize(this.Capture["TmpFile"]) <= 8192
					_ManagedRemoteFixtureEmitDiagnostic(JsonParse(FileRead(this.Capture["TmpFile"], "UTF-8")))
			}
			if this.Completions.Length == 1 && this.Completions[1]["exit"] == 0
					&& Trim(this.Completions[1]["stdout"], "`r`n ") == "OWNED_FIXTURE_STOPPED_ROOT_REMOVED"
					&& this.Completions[1]["stderr"] == "" {
				try {
					ReceiptRead := "unreadable"
					FinalState := JsonParse(FileRead(this.Capture["TmpFile"], "UTF-8"))
					ReceiptRead := FinalState is Map ? "readable" : "invalid"
					this.GracefulReceiptVerified := FinalState is Map && FinalState.Get("state", "") == "stopped"
						&& FinalState.Get("root_removed", false) && FinalState.Get("service_stopped", false)
					if this.GracefulReceiptVerified {
						this.GracefulReceiptVerified := false
						AssertEqual(0, FinalState.Get("server_tls_owned_streams", -1), "all actual native TLS connections retired before service acknowledgment")
						AssertEqual(0, FinalState.Get("server_tls_owned_modules", -1), "all exact acquired native provider references retired")
						AssertEqual(0, FinalState.Get("server_tls_owned_source_fences", -1), "native provider source fences close only after TLS retirement")
						AssertTrue(FinalState.Get("server_tls_source_unchanged", false), "native provider bytes remain unchanged through retirement")
						this.GracefulReceiptVerified := true
					}
				} catch as FinalReceiptError {
					this.LastFinalReceiptError := Type(FinalReceiptError)
				}
			}
			; A separate bounded cleanup process verifies exact-thumbprint absence
			; after every server descendant is gone, including failed shutdowns.
			if this.RootThumbprint != "" && !this.RootRemovalVerified {
				if !IsObject(this.CleanupHandle) {
					this.CleanupHandle := ShellRunner_SpawnTreeOwned("powershell.exe",
						["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
							this.Script, "-StatePath", this.Capture["TmpFile"], "-EventPrefix", this.Prefix,
							"-Mode", "Cleanup", "-OwnedRootThumbprint", this.RootThumbprint,
							"-OwnedRootSubject", this.RootSubject], ObjBindMethod(this, "OnCleanupDone"), , , 8192)
					if !this.CleanupHandle.start()
						return false
				}
				Started := A_TickCount
				while this.CleanupCompletions.Length == 0 && !TickExpired64(Started, 15000) {
					_SR_TreePoll()
					Sleep(10)
				}
				if !this.CleanupHandle.terminate()
					return false
				if this.CleanupCompletions.Length != 1 || this.CleanupCompletions[1]["exit"] != 0
						|| Trim(this.CleanupCompletions[1]["stdout"], "`r`n ") != "OWNED_ROOT_REMOVED"
						|| this.CleanupCompletions[1]["stderr"] != "" {
					this.CleanupHandle := 0
					this.CleanupCompletions := []
					return false
				}
				this.RootRemovalVerified := true
			}
			if this.Capture is Map && _SR_CaptureRemove(this.Capture) != 0
				return false
			for Name, Event in this.Events.Clone() {
				if !DllCall("Kernel32\CloseHandle", "Ptr", Event, "Int")
					return false
				this.Events.Delete(Name)
			}
			this.Closed := true
			return true
		} catch as CleanupError {
			this.LastCleanupError := Type(CleanupError)
			return false
		} finally {
			try {
				if !this.GracefulReceiptVerified
					this.CleanupDiagnosticStatus := _ManagedRemoteFixtureEmitCleanupDiagnostic(
						this.Completions, FinalState, ReceiptRead, this.CleanupDiagnosticPrinter)
			} finally this.Closing := false
		}
	}

	RetainCleanup() {
		global _ManagedRemoteFixtureCleanupDebt
		_ManagedRemoteFixtureCleanupDebt[this.Identity] := this
		SetTimer(_ManagedRemoteFixtureRetryCleanup, 250)
	}
}

_ManagedRemote_ActualSystemTrustAndSelectedTransport() {
	Fixture := _ManagedRemoteFixtureOwner()
	try {
		for Name in ["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY"]
			AssertEqual("", EnvGet(Name), "explicit inherited proxy/bypass overrides make this controlled native qualification unavailable")
		Fixture.Start()
		Fixture.CheckGeneration(false)
		Fixture.CheckReadiness(false)
		Fixture.Observe()
		AssertEqual(0, Fixture.State["Requests"], "an untrusted certificate must reach no authenticated HTTP handler")
		AssertTrue(Fixture.State["ProxyConnects"] >= 2, "untrusted attempts must still use the real selected relay")
		Fixture.ChangeTrust(true)
		Fixture.CheckGeneration(true)
		Fixture.CheckReadiness(true)
		Fixture.Mode := "pac"
		Fixture.CheckGeneration(true)
		Fixture.CheckReadiness(true)
		Fixture.Observe()
		AssertEqual(4, Fixture.State["Requests"], "both actual entrypoints must reach TLS through static and PAC admission")
		AssertEqual(2, Fixture.State["Generations"])
		AssertEqual(2, Fixture.State["ReadyRequests"])
		AssertTrue(Fixture.State["PacRequests"] >= 1, "the actual WinHTTP PAC engine must fetch the owned script")
		AssertTrue(Fixture.State["CrlRequests"] >= 1, "strict generation must retain actual native revocation verification")
		Fixture.ChangeTrust(false)
		Fixture.Mode := "fixed"
		Fixture.CheckGeneration(false)
		Fixture.CheckReadiness(false)
		Fixture.Observe()
		AssertEqual(4, Fixture.State["Requests"], "removing the exact root must restore authenticated transport refusal")
		AssertTrue(Fixture.State["ProxyConnects"] >= 8, "all eight production transports must pass through the owned relay")
		AssertTrue(Fixture.State["FailedTls"] >= 4, "actual untrusted handshakes must fail before and after system trust admission")
	} finally {
		Closed := Fixture.Close()
		if !Closed
			Fixture.RetainCleanup()
		AssertTrue(Closed, "owned fixture/curl trees, exact root thumbprint and private state must be fully retired")
		if Fixture.RootThumbprint != "" {
			AssertTrue(Fixture.RootRemovalVerified, "independent cleanup must acknowledge exact-thumbprint absence")
			AssertTrue(Fixture.GracefulReceiptVerified, "native service or graceful cleanup failures must remain red after independent root removal")
		}
		AssertEqual(0, Fixture.Events.Count, "every owned native event handle must close")
	}
}
Test("managed remote native: actual system CA and static/PAC transport preserve strict TLS and exact cleanup",
	_ManagedRemote_ActualSystemTrustAndSelectedTransport)
