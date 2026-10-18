; static/ergopti_plus/windows/tests/unit/platform/network/test_managed_remote_transport.ahk

; ==============================================================================
; MODULE: Managed Remote Transport Acceptance Tests
; DESCRIPTION:
; Real production curl generation and readiness through an owned CONNECT relay.
; One warm PowerShell fixture provides TLS, a signed CRL and per-destination PAC.
; Only the user-settings reader is substituted; no transport method is replaced.
; ==============================================================================

global _ManagedRemoteFixtureCleanupDebt := Map()
global _ManagedRemoteFixtureCleanupExitRegistered := false


; Filtered native tests skip the timing-loader test that a complete suite runs.
; Use the canonical boot owner for each asynchronous acceptance operation, then
; restore the caller's exact timing state even when dispatch or assertions fail.
_ManagedRemoteFixtureWithLlmTimings(Callback) {
	global LLM_OLLAMA_POLL_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_POLL_MS
	global LLM_INSTALLED_CACHE_TTL_MS, LLM_DEPS_POLL_TIMEOUT_MS, LLM_REMOTE_READY_PING_DEADLINE_MS
	Previous := [IsSet(LLM_OLLAMA_POLL_MS) ? LLM_OLLAMA_POLL_MS : unset,
		IsSet(LLM_REMOTE_TIMEOUT_MS) ? LLM_REMOTE_TIMEOUT_MS : unset,
		IsSet(LLM_REMOTE_POLL_MS) ? LLM_REMOTE_POLL_MS : unset,
		IsSet(LLM_INSTALLED_CACHE_TTL_MS) ? LLM_INSTALLED_CACHE_TTL_MS : unset,
		IsSet(LLM_DEPS_POLL_TIMEOUT_MS) ? LLM_DEPS_POLL_TIMEOUT_MS : unset,
		IsSet(LLM_REMOTE_READY_PING_DEADLINE_MS) ? LLM_REMOTE_READY_PING_DEADLINE_MS : unset]
	try {
		LLMApiLoadTimings()
		return Callback.Call()
	} finally {
		LLM_OLLAMA_POLL_MS := Previous.Has(1) ? Previous[1] : unset
		LLM_REMOTE_TIMEOUT_MS := Previous.Has(2) ? Previous[2] : unset
		LLM_REMOTE_POLL_MS := Previous.Has(3) ? Previous[3] : unset
		LLM_INSTALLED_CACHE_TTL_MS := Previous.Has(4) ? Previous[4] : unset
		LLM_DEPS_POLL_TIMEOUT_MS := Previous.Has(5) ? Previous[5] : unset
		LLM_REMOTE_READY_PING_DEADLINE_MS := Previous.Has(6) ? Previous[6] : unset
	}
}

_ManagedRemoteFixtureDiagnosticEnum(Value, Pattern) {
	return Value is String && RegExMatch(Value, "\A(?:" . Pattern . ")\z") ? Value : "unknown"
}

_ManagedRemoteFixtureStateWaitDiagnostic(Role, ExpectedState, ExpectedPhase, PreviousSequence, State, ReadStatus, ReadError) {
	Observed := State is Map ? State : Map()
	Sequence := Observed.Get("sequence", "")
	Relation := "unknown"
	if Type(Sequence) == "Integer" && Sequence >= 0 && Sequence <= 2147483647
		&& Type(PreviousSequence) == "Integer" && PreviousSequence >= -1 && PreviousSequence <= 2147483647
		Relation := Sequence > PreviousSequence ? "newer" : Sequence == PreviousSequence ? "same" : "older"
	ReadStatus := _ManagedRemoteFixtureDiagnosticEnum(ReadStatus, "not_read|readable|unreadable")
	ReadError := ReadStatus == "unreadable"
		? _ManagedRemoteFixtureDiagnosticEnum(ReadError, "Error|OSError|ValueError|TypeError") : "none"
	return "wait_role=" . _ManagedRemoteFixtureDiagnosticEnum(Role, "startup|trust_install|trust_remove|observe")
		. " expected_state=" . _ManagedRemoteFixtureDiagnosticEnum(ExpectedState, "starting|ready|stopped|failed")
		. " expected_phase=" . _ManagedRemoteFixtureDiagnosticEnum(ExpectedPhase, "untrusted|trusted|removed")
		. " observed_state=" . _ManagedRemoteFixtureDiagnosticEnum(Observed.Get("state", ""), "starting|ready|stopped|failed")
		. " observed_phase=" . _ManagedRemoteFixtureDiagnosticEnum(Observed.Get("phase", ""), "untrusted|trusted|removed")
		. " sequence_relation=" . Relation . " last_read=" . ReadStatus . " read_error=" . ReadError
		. " trust_step=" . _ManagedRemoteFixtureDiagnosticEnum(Observed.Get("trust_step", ""),
			"event_received|before_open|before_enumeration|before_export|before_add|after_add|before_postcheck|before_close")
		. " critical=" . (A_IsCritical != 0 ? "true" : "false") . " suspended=" . (A_IsSuspended ? "true" : "false")
}

_ManagedRemoteFixtureSelectRootScope(Scope, Actions, Runner) {
	if Scope == "" {
		if StrCompare(Actions, "true", true) == 0
			throw Error("CI native fixture requires an explicit root-store scope.")
		return "CurrentUser"
	}
	if StrCompare(Scope, "CurrentUser", true) == 0 {
		if StrCompare(Actions, "true", true) == 0
			throw Error("CI native fixture requires the explicit machine root-store scope.")
		return "CurrentUser"
	}
	if StrCompare(Scope, "LocalMachine", true) != 0
		throw Error("Native fixture root-store scope is invalid.")
	if StrCompare(Actions, "true", true) != 0 || StrCompare(Runner, "github-hosted", true) != 0
		throw Error("Machine root-store scope requires the explicit hosted ephemeral CI context.")
	return "LocalMachine"
}

_ManagedRemoteFixtureTokenOpen() {
	Token := 0
	if !DllCall("Advapi32\OpenProcessToken", "Ptr", DllCall("Kernel32\GetCurrentProcess", "Ptr"),
		"UInt", 0x0008, "Ptr*", &Token, "Int")
		throw Error("Native fixture token acquisition was refused.")
	return Token
}

_ManagedRemoteFixtureTokenQuery(Token) {
	Elevation := Buffer(4, 0)
	Returned := 0
	if !DllCall("Advapi32\GetTokenInformation", "Ptr", Token, "Int", 20, "Ptr", Elevation,
		"UInt", Elevation.Size, "UInt*", &Returned, "Int") || Returned != Elevation.Size
		throw Error("Native fixture token elevation query was refused.")
	return NumGet(Elevation, 0, "UInt") != 0
}

_ManagedRemoteFixtureTokenClose(Token) {
	return DllCall("Kernel32\CloseHandle", "Ptr", Token, "Int") != 0
}

global _ManagedRemoteFixtureTokenDebt := Map()
global _ManagedRemoteFixtureTokenExitRegistered := false

_ManagedRemoteFixtureRetryTokenRetirement(*) {
	global _ManagedRemoteFixtureTokenDebt
	for Identity, Owner in _ManagedRemoteFixtureTokenDebt.Clone()
		Owner.Retire()
}

class _ManagedRemoteFixtureTokenOwner {
	__New(Port) {
		this.Port := Port
		this.Token := 0
		this.Attempted := false
		this.ObservationComplete := false
		this.RetirementStatus := "not_requested"
		this.QueryFailed := false
		this.QueryFailure := 0
		this.RetirementFailed := false
		this.RetirementFailure := 0
	}

	Observe() {
		global _ManagedRemoteFixtureTokenDebt
		if this.Attempted || _ManagedRemoteFixtureTokenDebt.Count != 0
			throw Error("Unretired token ownership prevents a new permission observation.")
		this.Attempted := true
		this.Token := this.Port["open"].Call()
		if Type(this.Token) != "Integer" || this.Token == 0
			throw Error("Native fixture token acquisition was refused.")
		Elevated := false
		try {
			Elevated := this.Port["query"].Call(this.Token)
			if Type(Elevated) != "Integer" || (Elevated != 0 && Elevated != 1)
				throw Error("Native fixture token observation was invalid.")
		} catch Any as Failure {
			this.QueryFailed := true
			this.QueryFailure := Failure
		}
		Retired := this.Retire()
		if this.QueryFailed
			throw this.QueryFailure
		if !Retired
			if this.RetirementFailed
				throw this.RetirementFailure
		if !Retired
			throw Error("Native fixture token retirement was refused.")
		this.ObservationComplete := true
		return Elevated
	}

	Retire() {
		global _ManagedRemoteFixtureTokenDebt
		if this.Token == 0
			return true
		Closed := false
		try Closed := this.Port["close"].Call(this.Token)
		catch Any as Failure {
			this.RetirementStatus := "unavailable"
			if !this.RetirementFailed {
				this.RetirementFailed := true
				this.RetirementFailure := Failure
			}
		}
		if Type(Closed) != "Integer" || Closed != 1 {
			this.RetirementStatus := "unavailable"
			_ManagedRemoteFixtureTokenDebt[ObjPtr(this)] := this
			return false
		}
		this.Token := 0
		this.RetirementStatus := "acknowledged"
		if _ManagedRemoteFixtureTokenDebt.Has(ObjPtr(this))
			_ManagedRemoteFixtureTokenDebt.Delete(ObjPtr(this))
		return true
	}
}

_ManagedRemoteFixtureTokenElevation(Port := 0) {
	global _ManagedRemoteFixtureTokenExitRegistered
	if !_ManagedRemoteFixtureTokenExitRegistered {
		OnExit(_ManagedRemoteFixtureRetryTokenRetirement)
		_ManagedRemoteFixtureTokenExitRegistered := true
	}
	if !(Port is Map)
		Port := Map("open", _ManagedRemoteFixtureTokenOpen, "query", _ManagedRemoteFixtureTokenQuery, "close", _ManagedRemoteFixtureTokenClose)
	Owner := _ManagedRemoteFixtureTokenOwner(Port)
	return Owner.Observe()
}

_ManagedRemoteFixtureRequireRootScope(Scope, ReadElevation := _ManagedRemoteFixtureTokenElevation) {
	if StrCompare(Scope, "CurrentUser", true) == 0
		return true
	if StrCompare(Scope, "LocalMachine", true) != 0
		throw Error("Native fixture root-store scope is invalid.")
	Elevated := ReadElevation.Call()
	if Type(Elevated) != "Integer" || Elevated != 1
		throw Error("Machine root-store scope requires verified native token elevation.")
	return true
}

_ManagedRemoteFixtureRootScopeMatches(State, Scope) {
	return State is Map && State.Get("root_store_scope", 0) is String
		&& StrCompare(State["root_store_scope"], Scope, true) == 0
}

_ManagedRemoteFixtureRootIdentityMatches(State, Scope, Thumbprint, Subject) {
	return _ManagedRemoteFixtureRootScopeMatches(State, Scope)
		&& State.Get("root_thumbprint", 0) is String && State.Get("root_subject", 0) is String
		&& StrCompare(State["root_thumbprint"], Thumbprint, true) == 0
		&& StrCompare(State["root_subject"], Subject, true) == 0
}

_ManagedRemoteFixtureRootCleanupMatches(State, Scope, Thumbprint, Subject) {
	return _ManagedRemoteFixtureRootIdentityMatches(State, Scope, Thumbprint, Subject)
		&& Type(State.Get("version", "")) == "Integer" && State["version"] == 1
		&& State.Get("operation", "") is String && StrCompare(State["operation"], "root_cleanup", true) == 0
		&& Type(State.Get("root_removed", "")) == "Integer" && State["root_removed"] == 1
}

class _ManagedRemoteFixtureOwner {
	__New() {
		global _DriverDir, _ManagedRemoteFixtureCleanupExitRegistered
		Scope := _ManagedRemoteFixtureSelectRootScope(EnvGet("ERGOPTI_MANAGED_FIXTURE_ROOT_SCOPE"),
			EnvGet("GITHUB_ACTIONS"), EnvGet("RUNNER_ENVIRONMENT"))
		this.DefineProp("RootStoreScope", {Get: (*) => Scope})
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
		this.CleanupFailureCheckpointStatus := "not_requested"
		this.StateWaitDiagnosticStatus := "not_requested"
		this.StateWaitDiagnosticPrinter := _TestPrint
		this.Closing := false
		this.Closed := false
		this.Requests := Map()
		this.ReadyOwners := []
		this.ReadyCancels := []
		this.ProxyRuns := []
		this.Reader := ObjBindMethod(this, "ReadConfig")
		this.GenerationCount := 0
		this.GenerationDiagnosticPrinter := _TestPrint
		this.GenerationDiagnosticStatus := "not_requested"
		this.ReadinessCount := 0
		this.ReadinessRuns := Map()
		this.ReadinessDiagnosticPrinter := _TestPrint
		this.ReadinessDiagnosticStatus := "not_requested"
		this.Mode := "fixed"
		this.Capture := 0
		this.State := Map()
		if !_ManagedRemoteFixtureCleanupExitRegistered {
			OnExit(_ManagedRemoteFixtureExitCleanup)
			_ManagedRemoteFixtureCleanupExitRegistered := true
		}
	}

	Start(ServerMode := "Serve") {
		_ManagedRemoteFixtureRequireRootScope(this.RootStoreScope)
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
				this.Script, "-StatePath", this.Capture["TmpFile"], "-EventPrefix", this.Prefix, "-Mode", ServerMode,
				"-OwnedRootStoreScope", this.RootStoreScope],
			ObjBindMethod(this, "OnServerDone"), , ObjBindMethod(this, "OnNativeAdopt"), 8192)
		if !this.Handle.start()
			throw Error("Actual managed-network native fixture did not start.")
		this.WaitState("ready", "untrusted", 20000, -1, "startup")
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
		if !_ManagedRemoteFixtureRootScopeMatches(State, this.RootStoreScope)
			throw Error("Owned fixture root-store scope was not acknowledged.")
		if this.RootThumbprint != "" && !_ManagedRemoteFixtureRootIdentityMatches(State,
			this.RootStoreScope, this.RootThumbprint, this.RootSubject)
			throw Error("Owned fixture certificate identity was not acknowledged.")
		if State.Get("state", "") == "failed" {
			_ManagedRemoteFixtureEmitDiagnostic(State)
			throw Error("Actual managed-network fixture reported native failure.")
		}
		this.State := State
		return true
	}

	WaitState(ExpectedState, ExpectedPhase, BudgetMs, PreviousSequence := -1, Role := "unknown") {
		Started := A_TickCount
		ReadStatus := "not_read"
		while !TickExpired64(Started, BudgetMs) {
			_SR_TreePoll()
			Readable := this.ReadState()
			ReadStatus := Readable ? "readable" : "unreadable"
			if Readable && this.State.Get("state", "") == ExpectedState
					&& this.State.Get("phase", "") == ExpectedPhase
					&& this.State.Get("sequence", -1) > PreviousSequence
				return true
			if this.Completions.Length > 0
				throw Error("Owned fixture settled before its required state acknowledgment.")
			Sleep(10)
		}
		this.StateWaitDiagnosticStatus := "unavailable"
		try {
			Fact := _ManagedRemoteFixtureStateWaitDiagnostic(Role, ExpectedState, ExpectedPhase, PreviousSequence,
				this.State, ReadStatus, this.HasOwnProp("LastStateReadError") ? this.LastStateReadError : "")
			this.StateWaitDiagnosticPrinter.Call("::notice title=Windows native state wait diagnostic::" . Fact)
			this.StateWaitDiagnosticStatus := "reported"
		} catch Any {
			; Reporting refusal cannot replace the original acknowledgment timeout.
			this.StateWaitDiagnosticStatus := "unavailable"
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
		this.WaitState("ready", Installed ? "trusted" : "removed", 10000, Sequence,
			Installed ? "trust_install" : "trust_remove")
		if !Installed
			AssertTrue(this.State.Get("root_removed", false), "exact declared-scope root removal must be acknowledged")
	}

	Observe() {
		Sequence := this.State["sequence"]
		Phase := this.State["phase"]
		this.Signal("Observe")
		this.WaitState("ready", Phase, 5000, Sequence, "observe")
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
		return _ManagedRemoteFixtureWithLlmTimings(ObjBindMethod(this, "_CheckGeneration", ExpectedSuccess))
	}

	_CheckGeneration(ExpectedSuccess) {
		global _LLM_Remote_Async
		this.GenerationCount += 1
		DispatchMode := this.Mode
		DispatchOrdinal := this.GenerationCount
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
		if Result["success"].Length + Result["failure"].Length != 1
			|| Result["success"].Length != (ExpectedSuccess ? 1 : 0)
			|| Result["failure"].Length != (ExpectedSuccess ? 0 : 1)
			_ManagedRemoteFixtureEmitGenerationDiagnostic(this, ReqId, Reservation, Result, ExpectedSuccess, DispatchMode, DispatchOrdinal)
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

	ReadyCompleted(Result, Owner, Run, Ready) {
		CancelFn := Owner.Get("cancel", 0)
		if HasMethod(CancelFn, "Call")
			this.ReadyCancels.Push(CancelFn)
		_ManagedRemoteFixtureCaptureReadinessCallback(this, Run, Owner)
		Result.Push(Ready)
	}

	CheckReadiness(ExpectedSuccess) {
		return _ManagedRemoteFixtureWithLlmTimings(ObjBindMethod(this, "_CheckReadiness", ExpectedSuccess))
	}

	_CheckReadiness(ExpectedSuccess) {
		global LLM_API_PROVIDERS, LLM_REMOTE_READY_PING_DEADLINE_MS
		this.ReadinessCount += 1
		Run := Map("mode", this.Mode, "ordinal", this.ReadinessCount, "http", [], "capture", "retained")
		Run["deadline_ms"] := LLM_REMOTE_READY_PING_DEADLINE_MS
		this.ReadinessRuns[this.ReadinessCount] := Run
		ReadyPort := this.Port.Clone()
		ProviderId := "managed_network_" . this.Identity
		AssertFalse(LLM_API_PROVIDERS.Has(ProviderId), "owned acceptance provider identity must be unique")
		Result := []
		Observation := Map("http", 0)
		ObservedPort := this.Port.Clone()
		Factory := _LLM_CurlArtifactPortFn(this.Port, "create_http", () => CurlAsyncRequest())
		ObservedPort["create_http"] := _ManagedRemoteCaptureReadinessHttp.Bind(Observation, Factory)
		ReadyPort["create_http"] := _ManagedRemoteFixtureCaptureReadinessHttp.Bind(Run, ObservedPort["create_http"])
		Owner := LLM_AuxBegin(ProviderId, Map("backend", "api", "endpoint", this.BaseUrl, "identity", ProviderId))
		Run["owner"] := Owner
		this.ReadyOwners.Push(Owner)
		LLM_API_PROVIDERS[ProviderId] := Map("Format", "openai", "BaseUrl", this.BaseUrl)
		try {
			LLM_RemoteIsReady_Async(Map("Provider", ProviderId, "Token", "managed-network-fixture-token"),
				ObjBindMethod(this, "ReadyCompleted", Result, Owner, Run), Owner, ReadyPort)
			Started := A_TickCount
			while Result.Length == 0 && !TickExpired64(Started, 18000) {
				_SR_TreePoll()
				Sleep(10)
			}
			if Result.Length != 1 || Result[1] != ExpectedSuccess {
				_ManagedRemoteFixtureEmitReadinessDiagnostic(this, Run, Result, ExpectedSuccess)
				_ManagedRemoteEmitReadinessDiagnostic(this, ExpectedSuccess, Result, Observation, Owner, LLM_REMOTE_READY_PING_DEADLINE_MS)
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
		FinalObservation := 0
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
				if this.Completions.Length == 0
					try _ManagedRemoteFixtureGroup6ObserveDialog(this.Handle)
				if !this.Handle.terminate()
					return false
				if this.NativeState is Map && !this.NativeState.Get("TreeQuiesced", false)
					return false
			}
			; Reuse the original owned state after native tree quiescence, before its removal.
			; Diagnostic I/O is bounded and cannot replace the original cleanup assertion.
			try {
				if this.Capture is Map && FileGetSize(this.Capture["TmpFile"]) <= 8192 {
					FinalObservation := JsonParse(FileRead(this.Capture["TmpFile"], "UTF-8"))
					_ManagedRemoteFixtureEmitDiagnostic(FinalObservation)
				}
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
						&& _ManagedRemoteFixtureRootScopeMatches(FinalState, this.RootStoreScope)
						&& (this.RootThumbprint == "" || _ManagedRemoteFixtureRootIdentityMatches(FinalState,
							this.RootStoreScope, this.RootThumbprint, this.RootSubject))
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
					_ManagedRemoteFixtureRequireRootScope(this.RootStoreScope)
					this.CleanupHandle := ShellRunner_SpawnTreeOwned("powershell.exe",
						["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
							this.Script, "-StatePath", this.Capture["TmpFile"], "-EventPrefix", this.Prefix,
							"-Mode", "Cleanup", "-OwnedRootThumbprint", this.RootThumbprint,
							"-OwnedRootSubject", this.RootSubject, "-OwnedRootStoreScope", this.RootStoreScope],
						ObjBindMethod(this, "OnCleanupDone"), , , 8192)
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
				CleanupState := JsonParse(FileRead(this.Capture["TmpFile"], "UTF-8"))
				if !_ManagedRemoteFixtureRootCleanupMatches(CleanupState, this.RootStoreScope, this.RootThumbprint, this.RootSubject)
					return false
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
				if !this.GracefulReceiptVerified {
					_ManagedRemoteFixtureGroup6CleanupDiagnostic(FinalObservation, this.Completions)
					this.CleanupDiagnosticStatus := _ManagedRemoteFixtureEmitCleanupDiagnostic(
						this.Completions, FinalState, ReceiptRead, this.CleanupDiagnosticPrinter, this.RootStoreScope)
				}
			} finally this.Closing := false
		}
	}

	RetainCleanup() {
		global _ManagedRemoteFixtureCleanupDebt
		_ManagedRemoteFixtureCleanupDebt[this.Identity] := this
		SetTimer(_ManagedRemoteFixtureRetryCleanup, 250)
	}
}

; Secondary cleanup evidence must survive without replacing the body's exception.
_ManagedRemoteFixtureFinalize(Fixture, BodyFailed, PrimaryFailure, CleanupFn, PrintFn := unset) {
	if !IsSet(PrintFn)
		PrintFn := _TestPrint
	try CleanupFn.Call()
	catch Any as CleanupFailure {
		Kind := "other"
		switch Type(CleanupFailure) {
			case "Error": Kind := "error"
			case "ValueError": Kind := "value_error"
			case "TypeError": Kind := "type_error"
		}
		Fixture.CleanupFailureCheckpointStatus := "unavailable"
		try {
			PrintFn.Call("::notice title=Windows native fixture cleanup failure::body_failed="
				. (BodyFailed ? "true" : "false") . " cleanup_failed=true cleanup_exception=" . Kind)
			Fixture.CleanupFailureCheckpointStatus := "reported"
		} catch Any {
			; Retain reporting refusal locally; retrying the same sink would mask priority.
			Fixture.CleanupFailureCheckpointStatus := "unavailable"
		}
		if BodyFailed
			throw PrimaryFailure
		throw CleanupFailure
	}
	if BodyFailed
		throw PrimaryFailure
}

_ManagedRemote_Close(Fixture) {
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

_ManagedRemote_ActualSystemTrustAndSelectedTransport(Fixture := unset) {
	if !IsSet(Fixture)
		Fixture := _ManagedRemoteFixtureOwner()
	PrimaryFailure := 0
	BodyFailed := false
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
	} catch Any as Failure {
		PrimaryFailure := Failure
		BodyFailed := true
	} finally _ManagedRemoteFixtureFinalize(Fixture, BodyFailed, PrimaryFailure, _ManagedRemote_Close.Bind(Fixture))
}
Test("managed remote native: actual system CA and static/PAC transport preserve strict TLS and exact cleanup",
	_ManagedRemote_ActualSystemTrustAndSelectedTransport)
