; tests/unit/platform/network/test_managed_remote_fixture_scope.ahk

; ==============================================================================
; MODULE: Managed Remote Fixture Timing, Scope and Tokens
; DESCRIPTION:
; The fixture's canonical poll timing scope, bounded state-wait evidence,
; the independent trust publisher, the root certificate scope and its
; permission contracts, token debt and primary-failure preservation.
; ==============================================================================

#Requires AutoHotkey v2.0





class _ManagedRemoteTimingControlHttp {
	__New() {
		this.Polls := 0
		this.Aborts := 0
		this.Pending := false
		this.Status := 0
		this.ResponseText := ""
		this.ResponseEncodingValid := true
	}

	SetManagedRouting(Args*) {
	}

	SetDeadline(Args*) {
	}

	Open(Args*) {
	}

	SetRequestHeader(Args*) {
	}

	Send(Args*) {
		return true
	}

	WaitForResponse(Args*) {
		this.Polls += 1
		return !this.Pending && this.Polls > 1
	}

	Abort() {
		this.Aborts += 1
		return true
	}
}

_ManagedRemoteTimingFilteredGeneration() {
	global LLM_REMOTE_POLL_MS
	Previous := LLM_REMOTE_POLL_MS
	Fixture := _ManagedRemoteFixtureOwner()
	Http := _ManagedRemoteTimingControlHttp()
	Fixture.BaseUrl := "https://managed-fixture.invalid:443/v1"
	Fixture.Port := Map("managed_settings", (*) => Map(), "create_http", (*) => Http)
	try {
		LLM_REMOTE_POLL_MS := 0
		Fixture.CheckGeneration(false)
		AssertTrue(Http.Polls >= 2, "the actual remote poll must rearm after its first pending response")
		AssertEqual(0, LLM_REMOTE_POLL_MS, "the fixture restores the filtered caller's sentinel")
	} finally {
		Fixture.RetireRequests()
		LLM_REMOTE_POLL_MS := Previous
	}
}
Test("managed remote native: filtered generation owns canonical poll timing (managed-fixture-timing)",
	_ManagedRemoteTimingFilteredGeneration)

_ManagedRemoteTimingScopeBody(Control) {
	global LLM_OLLAMA_POLL_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_POLL_MS
	global LLM_INSTALLED_CACHE_TTL_MS, LLM_DEPS_POLL_TIMEOUT_MS, LLM_REMOTE_READY_PING_DEADLINE_MS
	Control["calls"] += 1
	AssertEqual(TimingsGet("llm", "poll_interval_ms"), LLM_OLLAMA_POLL_MS)
	AssertEqual(TimingsGet("llm", "request_timeout_ms"), LLM_REMOTE_TIMEOUT_MS)
	AssertEqual(TimingsGet("llm", "request_timeout_ms"), LLM_REMOTE_READY_PING_DEADLINE_MS)
	AssertEqual(TimingsGet("llm", "poll_interval_ms"), LLM_REMOTE_POLL_MS)
	AssertEqual(TimingsGet("llm", "installed_cache_ttl_ms"), LLM_INSTALLED_CACHE_TTL_MS)
	AssertEqual(TimingsGet("llm", "dependency_bootstrap_timeout_ms"), LLM_DEPS_POLL_TIMEOUT_MS)
	if Control["fail"]
		throw Control["failure"]
	return "completed"
}

_ManagedRemoteTimingScopeRestores() {
	global LLM_OLLAMA_POLL_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_POLL_MS
	global LLM_INSTALLED_CACHE_TTL_MS, LLM_DEPS_POLL_TIMEOUT_MS, LLM_REMOTE_READY_PING_DEADLINE_MS, _TimingsCache
	Previous := [IsSet(LLM_OLLAMA_POLL_MS) ? LLM_OLLAMA_POLL_MS : unset,
		IsSet(LLM_REMOTE_TIMEOUT_MS) ? LLM_REMOTE_TIMEOUT_MS : unset,
		IsSet(LLM_REMOTE_POLL_MS) ? LLM_REMOTE_POLL_MS : unset,
		IsSet(LLM_INSTALLED_CACHE_TTL_MS) ? LLM_INSTALLED_CACHE_TTL_MS : unset,
		IsSet(LLM_DEPS_POLL_TIMEOUT_MS) ? LLM_DEPS_POLL_TIMEOUT_MS : unset,
		IsSet(LLM_REMOTE_READY_PING_DEADLINE_MS) ? LLM_REMOTE_READY_PING_DEADLINE_MS : unset]
	Cache := _TimingsCache
	try {
		for Mode in ["success", "body_failure", "loader_failure", "unset"] {
			LLM_OLLAMA_POLL_MS := Mode == "unset" ? unset : 101
			LLM_REMOTE_TIMEOUT_MS := Mode == "unset" ? unset : 103
			LLM_REMOTE_POLL_MS := Mode == "unset" ? unset : 107
			LLM_INSTALLED_CACHE_TTL_MS := Mode == "unset" ? unset : 109
			LLM_DEPS_POLL_TIMEOUT_MS := Mode == "unset" ? unset : 113
			LLM_REMOTE_READY_PING_DEADLINE_MS := Mode == "unset" ? unset : 127
			_TimingsCache := Mode == "loader_failure" ? Map() : Cache
			Control := Map("calls", 0, "fail", Mode == "body_failure", "failure", ValueError("controlled timing body failure"))
			Caught := false
			try {
				AssertEqual("completed", _ManagedRemoteFixtureWithLlmTimings(_ManagedRemoteTimingScopeBody.Bind(Control)))
			} catch Any as Failure {
				Caught := true
				if Mode == "body_failure"
					AssertTrue(Failure == Control["failure"], "restoration preserves the exact body exception")
				else
					AssertEqual("loader_failure", Mode, "success and unset cases must not throw")
			}
			AssertEqual(Mode == "body_failure" || Mode == "loader_failure", Caught)
			AssertEqual(Mode == "loader_failure" ? 0 : 1, Control["calls"], "failed initialization never admits the operation")
			if Mode == "unset" {
				AssertFalse(IsSet(LLM_OLLAMA_POLL_MS) || IsSet(LLM_REMOTE_TIMEOUT_MS) || IsSet(LLM_REMOTE_POLL_MS)
					|| IsSet(LLM_INSTALLED_CACHE_TTL_MS) || IsSet(LLM_DEPS_POLL_TIMEOUT_MS)
					|| IsSet(LLM_REMOTE_READY_PING_DEADLINE_MS), "unset ownership is restored exactly")
			} else {
				AssertEqual(101, LLM_OLLAMA_POLL_MS)
				AssertEqual(103, LLM_REMOTE_TIMEOUT_MS)
				AssertEqual(107, LLM_REMOTE_POLL_MS)
				AssertEqual(109, LLM_INSTALLED_CACHE_TTL_MS)
				AssertEqual(113, LLM_DEPS_POLL_TIMEOUT_MS)
				AssertEqual(127, LLM_REMOTE_READY_PING_DEADLINE_MS)
			}
		}
	} finally {
		_TimingsCache := Cache
		LLM_OLLAMA_POLL_MS := Previous.Has(1) ? Previous[1] : unset
		LLM_REMOTE_TIMEOUT_MS := Previous.Has(2) ? Previous[2] : unset
		LLM_REMOTE_POLL_MS := Previous.Has(3) ? Previous[3] : unset
		LLM_INSTALLED_CACHE_TTL_MS := Previous.Has(4) ? Previous[4] : unset
		LLM_DEPS_POLL_TIMEOUT_MS := Previous.Has(5) ? Previous[5] : unset
		LLM_REMOTE_READY_PING_DEADLINE_MS := Previous.Has(6) ? Previous[6] : unset
	}
}
Test("managed remote native: canonical timing scope preserves assigned and unset owners (managed-fixture-timing)",
	_ManagedRemoteTimingScopeRestores)

_ManagedRemoteTimingStagePending(Fixture, Http, Control) {
	ReqId := "managed_timing_pending_" . Fixture.Identity
	Resolved := Map("Format", "openai", "Token", "controlled", "Model", "fixture")
	Callback := (*) => Control["callbacks"] += 1
	Reservation := _LLMRemote_ReserveRequest(ReqId, Callback, Callback, 15000, A_TickCount, Resolved)
	Fixture.Requests[ReqId] := Reservation
	Control["request"] := ReqId
	AssertTrue(_LLMRemote_DispatchCurl(ReqId, Resolved, "https://managed-fixture.invalid:443/v1",
		"{}", Callback, Callback, 15000,
		Map("managed_settings", (*) => Map(), "create_http", (*) => Http), Reservation))
	AssertEqual(1, Http.Polls, "the actual remote poll owns a pending continuation")
	throw Control["failure"]
}

_ManagedRemoteTimingPendingRetirement() {
	global LLM_REMOTE_POLL_MS, _LLM_Remote_Async
	Previous := LLM_REMOTE_POLL_MS
	Fixture := _ManagedRemoteFixtureOwner()
	Http := _ManagedRemoteTimingControlHttp()
	Http.Pending := true
	Control := Map("callbacks", 0, "failure", ValueError("controlled pending body failure"))
	try {
		LLM_REMOTE_POLL_MS := 0
		Caught := false
		try _ManagedRemoteFixtureWithLlmTimings(_ManagedRemoteTimingStagePending.Bind(Fixture, Http, Control))
		catch Any as Failure {
			Caught := true
			AssertTrue(Failure == Control["failure"], "a pending transport cannot replace the original body failure")
		}
		AssertTrue(Caught)
		AssertEqual(0, LLM_REMOTE_POLL_MS, "the caller's zero period is already restored before retirement")
		AssertTrue(Fixture.RetireRequests(), "the original fixture retirement path admits no remaining exact request")
		AssertFalse(_LLM_Remote_Async.Has(Control["request"]), "retirement removes the pending poll's exact registry owner")
		Started := A_TickCount
		while Http.Aborts == 0 && !TickExpired64(Started, 1000)
			Sleep(10)
		AssertEqual(1, Http.Aborts, "the independent cancellation timer delivers Abort despite a zero remote poll period")
		Sleep(TimingsGet("llm", "poll_interval_ms") * 2)
		_LLMRemote_PollRequest(Control["request"])
		AssertEqual(1, Http.Polls, "the armed continuation and an explicit stale poll cannot touch a retired transport")
		AssertEqual(0, Control["callbacks"], "a retired pending poll cannot publish either completion callback")
	} finally {
		Fixture.RetireRequests()
		LLM_REMOTE_POLL_MS := Previous
	}
}
Test("managed remote native: pending work retires after timing scope failure (managed-fixture-timing)",
	_ManagedRemoteTimingPendingRetirement)

_ManagedRemoteStateWaitTimeoutReports() {
	Fixture := _ManagedRemoteFixtureOwner()
	Observed := Map("calls", 0, "fact", "")
	Fixture.State := Map("state", "ready", "phase", "untrusted", "sequence", 3)
	Fixture.StateWaitDiagnosticPrinter := (Text) => (Observed["calls"] += 1, Observed["fact"] := Text)
	Caught := false
	try Fixture.WaitState("ready", "trusted", 0, 3)
	catch as Failure {
		Caught := true
		AssertEqual("Owned managed-network fixture state budget expired.", Failure.Message,
			"observability retains the original timeout failure")
	}
	AssertTrue(Caught)
	AssertEqual(1, Observed["calls"], "an acknowledgment timeout must report its closed state projection")
	AssertContains(Observed["fact"], "expected_phase=trusted")
	AssertContains(Observed["fact"], "observed_phase=untrusted")
}
Test("managed remote native: state timeout emits bounded evidence (managed-fixture-wait-diagnostic)",
	_ManagedRemoteStateWaitTimeoutReports)

_ManagedRemoteStateWaitProjectionAndRefusal() {
	State := Map("state", "ready", "phase", "untrusted", "sequence", 3)
	Fact := _ManagedRemoteFixtureStateWaitDiagnostic("observe", "ready", "untrusted", 3, State, "unreadable", "OSError")
	AssertContains(Fact, "wait_role=observe")
	AssertContains(Fact, "sequence_relation=same")
	AssertContains(Fact, "last_read=unreadable read_error=OSError")
	for Pair in [[2, "older"], [4, "newer"], ["4", "unknown"], [2147483648, "unknown"]] {
		State["sequence"] := Pair[1]
		AssertContains(_ManagedRemoteFixtureStateWaitDiagnostic("observe", "ready", "untrusted", 3, State,
			"readable", "PRIVATE_READ_ERROR"), "sequence_relation=" . Pair[2])
	}
	Private := "PRIVATE_STATE_CONTENT"
	Fact := _ManagedRemoteFixtureStateWaitDiagnostic(Private, Private, Private, Private,
		Map("state", Private, "phase", Private, "sequence", Private, "body", Private), Private, Private)
	AssertFalse(InStr(Fact, Private), "unknown state, phase, role and error values cannot expose content")
	AssertContains(Fact, "observed_state=unknown observed_phase=unknown")
	Fixture := _ManagedRemoteFixtureOwner()
	Control := Map("calls", 0)
	Fixture.StateWaitDiagnosticPrinter := _ManagedRemoteStateWaitPrinterRefused.Bind(Control)
	Caught := false
	try Fixture.WaitState("ready", "untrusted", 0)
	catch as Failure {
		Caught := true
		AssertEqual("Owned managed-network fixture state budget expired.", Failure.Message)
	}
	AssertTrue(Caught)
	AssertEqual(1, Control["calls"], "a refused diagnostic cannot recurse through the same sink")
	AssertEqual("unavailable", Fixture.StateWaitDiagnosticStatus, "the owner retains only bounded reporting refusal")
}

_ManagedRemoteStateWaitPrinterRefused(Control, Text) {
	Control["calls"] += 1
	throw ValueError("PRIVATE_REPORTER_FAILURE")
}
Test("managed remote native: state diagnostic refuses content and preserves timeout (managed-fixture-wait-diagnostic)",
	_ManagedRemoteStateWaitProjectionAndRefusal)

_ManagedRemoteTrustPublisherIndependent() {
	global _DriverDir
	Directory := _SR_AcquireCaptureDirectory()
	Capture := Map("Directory", Directory, "TmpFile", Directory . "output.tmp")
	Results := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned("powershell.exe", ["-NoProfile", "-NonInteractive", "-File",
			_DriverDir . "\tests\fixtures\managed_remote_trust_diagnostic.ps1", "-SourcePath",
			_DriverDir . "\tests\fixtures\managed_remote_transport.ps1", "-StatePath", Capture["TmpFile"]],
			(Code, Out, Err) => Results.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
		AssertTrue(Handle.start())
		Started := A_TickCount
		; A cold powershell.exe settles in about one second but has taken over
		; five on a loaded runner; the budget matches this file's other cold
		; PowerShell probes. Exit code, exact output and stderr stay asserted.
		while Results.Length == 0 && !TickExpired64(Started, 18000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Results.Length, "the real publisher behavior probe must settle once")
		AssertEqual(0, Results[1]["exit"], "the actual publisher preserves strict trust state and avoids native getters")
		AssertEqual("OWNED_TRUST_DIAGNOSTIC_PASS", Trim(Results[1]["stdout"], "`r`n "))
		AssertEqual("", Results[1]["stderr"])
		for Step in ["event_received", "before_open", "before_enumeration", "before_export", "before_add",
			"after_add", "before_postcheck", "before_close"] {
			Fact := _ManagedRemoteFixtureStateWaitDiagnostic("trust_install", "ready", "trusted", 0,
				Map("trust_step", Step), "readable", "")
			AssertContains(Fact, "trust_step=" . Step)
		}
		Fact := _ManagedRemoteFixtureStateWaitDiagnostic("trust_install", "ready", "trusted", 0,
			Map("trust_step", "PRIVATE_STEP"), "readable", "")
		AssertContains(Fact, "trust_step=unknown")
		AssertFalse(InStr(Fact, "PRIVATE_STEP"))
	} finally {
		if IsObject(Handle)
			AssertTrue(Handle.terminate(), "the exact behavior-probe Job retires even on failure")
		AssertEqual(0, _SR_CaptureRemove(Capture), "the exact owned receipt directory is retired")
	}
}
Test("managed remote native: trust publisher avoids native observation and preserves acceptance (managed-fixture-trust-diagnostic)",
	_ManagedRemoteTrustPublisherIndependent)

_ManagedRemoteScopeWithEnvironment(Scope, Actions, Runner, Callback) {
	Saved := Map()
	for Pair in [["ERGOPTI_MANAGED_FIXTURE_ROOT_SCOPE", Scope], ["GITHUB_ACTIONS", Actions], ["RUNNER_ENVIRONMENT", Runner]] {
		Saved[Pair[1]] := EnvGet(Pair[1])
		EnvSet(Pair[1], Pair[2])
	}
	try Callback.Call()
	finally {
		for Name, Value in Saved
			EnvSet(Name, Value)
	}
}

_ManagedRemoteScopeRejectsLowerCaseBody() {
	Caught := false
	try _ManagedRemoteFixtureOwner()
	catch as Failure
		Caught := true
	AssertTrue(Caught, "the actual fixture constructor must reject a case-insensitive root-store alias before acquisition")
}
Test("managed remote native: root scope rejects case aliases (managed-fixture-root-scope)",
	_ManagedRemoteScopeWithEnvironment.Bind("currentuser", "", "", _ManagedRemoteScopeRejectsLowerCaseBody))

_ManagedRemoteScopeRejectsReceiptBody() {
	Fixture := _ManagedRemoteFixtureOwner()
	Directory := _SR_AcquireCaptureDirectory()
	Capture := Map("Directory", Directory, "TmpFile", Directory . "output.tmp")
	Fixture.Capture := Capture
	try {
		FileAppend('{"version":1,"state":"ready","phase":"untrusted","sequence":1,"root_store_scope":"LocalMachine"}',
			Capture["TmpFile"], "UTF-8-RAW")
		Caught := false
		try Fixture.ReadState()
		catch as Failure
			Caught := true
		AssertTrue(Caught, "the actual receipt reader must reject a different declared root-store scope")
	} finally AssertEqual(0, _SR_CaptureRemove(Capture))
}
Test("managed remote native: receipt rejects wrong root scope (managed-fixture-root-scope)",
	_ManagedRemoteScopeWithEnvironment.Bind("", "", "", _ManagedRemoteScopeRejectsReceiptBody))

_ManagedRemoteScopePolicyControls() {
	AssertEqual("CurrentUser", _ManagedRemoteFixtureSelectRootScope("", "", ""))
	AssertEqual("CurrentUser", _ManagedRemoteFixtureSelectRootScope("CurrentUser", "", ""))
	AssertEqual("LocalMachine", _ManagedRemoteFixtureSelectRootScope("LocalMachine", "true", "github-hosted"))
	for ProbeCase in [["", "true", "github-hosted"], ["CurrentUser", "true", "github-hosted"],
		["localmachine", "true", "github-hosted"], ["LocalMachine", "", ""],
		["LocalMachine", "TRUE", "github-hosted"], ["LocalMachine", "true", "self-hosted"],
		["LocalMachine", "true", "GITHUB-HOSTED"], ["CurrentUser ", "", ""]] {
		Caught := false
		try _ManagedRemoteFixtureSelectRootScope(ProbeCase*)
		catch as Failure
			Caught := true
		AssertTrue(Caught, "unknown scope and unqualified machine context cannot become a local fallback")
	}
	Control := Map("calls", 0)
	Reader := (*) => (Control["calls"] += 1, false)
	AssertTrue(_ManagedRemoteFixtureRequireRootScope("CurrentUser", Reader))
	AssertEqual(0, Control["calls"], "local CurrentUser never requires an elevated token")
	for Value in [0, 2, "1", 1.0] {
		_ManagedRemoteScopeAssertInvalidPermission(Value, _ManagedRemoteScopePermissionValue.Bind(Value))
	}
	AssertTrue(_ManagedRemoteFixtureRequireRootScope("LocalMachine", (*) => true))
	Primary := ValueError("controlled native token query failure")
	Caught := false
	try _ManagedRemoteFixtureRequireRootScope("LocalMachine", _ManagedRemoteScopeQueryFailed.Bind(Primary))
	catch Any as Failure {
		Caught := true
		AssertTrue(Failure == Primary, "query failure cannot turn into permission or a fallback")
	}
	AssertTrue(Caught)
}

_ManagedRemoteScopePermissionValue(Value) => Value

_ManagedRemoteScopeObservePermission(Control, Reader) {
	Control["calls"] += 1
	Value := Reader.Call()
	Control["observed"].Push(Value)
	return Value
}

_ManagedRemoteScopeAssertInvalidPermission(Value, Reader) {
	Control := Map("calls", 0, "observed", [])
	Caught := false
	try _ManagedRemoteFixtureRequireRootScope("LocalMachine", _ManagedRemoteScopeObservePermission.Bind(Control, Reader))
	catch Any as Failure {
		Caught := true
		AssertEqual("Error", Type(Failure), "invalid permission must reach the guard instead of failing a captured-variable read")
		AssertEqual("Machine root-store scope requires verified native token elevation.", Failure.Message,
			"only the actual permission refusal satisfies this negative control")
	}
	AssertTrue(Caught, "machine permission needs the native reader's exact boolean contract")
	AssertEqual(1, Control["calls"], "each independent invalid permission invokes its reader once")
	AssertEqual(1, Control["observed"].Length, "the reader must return a real value to the guard")
	AssertEqual(Type(Value), Type(Control["observed"][1]), "the observed permission retains its original type")
	AssertEqual(Value, Control["observed"][1], "the actual invalid permission reaches the guard unchanged")
}

_ManagedRemoteScopeQueryFailed(Primary) {
	throw Primary
}
Test("managed remote native: closed scope and permission contracts fail fast (managed-fixture-root-scope)",
	_ManagedRemoteScopePolicyControls)

_ManagedRemoteScopeImmutableBody() {
	Fixture := _ManagedRemoteFixtureOwner()
	AssertEqual("LocalMachine", Fixture.RootStoreScope)
	EnvSet("ERGOPTI_MANAGED_FIXTURE_ROOT_SCOPE", "CurrentUser")
	EnvSet("GITHUB_ACTIONS", "")
	EnvSet("RUNNER_ENVIRONMENT", "")
	AssertEqual("LocalMachine", Fixture.RootStoreScope, "later environment changes cannot select a different cleanup scope")
	Caught := false
	try Fixture.RootStoreScope := "CurrentUser"
	catch as Failure
		Caught := true
	AssertTrue(Caught, "the captured root-store scope cannot be assigned by a caller")
}
Test("managed remote native: scope remains owned across environment changes (managed-fixture-root-scope)",
	_ManagedRemoteScopeWithEnvironment.Bind("LocalMachine", "true", "github-hosted", _ManagedRemoteScopeImmutableBody))

_ManagedRemoteScopeCleanupReceiptControls() {
	Thumbprint := "00112233445566778899AABBCCDDEEFF00112233"
	Subject := "CN=ErgoptiPlus managed-network fixture 00112233445566778899aabbccddeeff"
	State := Map("version", 1, "operation", "root_cleanup", "root_store_scope", "LocalMachine",
		"root_thumbprint", Thumbprint, "root_subject", Subject, "root_removed", true)
	AssertTrue(_ManagedRemoteFixtureRootCleanupMatches(State, "LocalMachine", Thumbprint, Subject))
	for Pair in [["root_store_scope", "CurrentUser"], ["root_store_scope", "localmachine"],
		["root_store_scope", 1], ["root_thumbprint", "different"], ["root_subject", "different"],
		["root_removed", "true"], ["operation", "ROOT_CLEANUP"], ["version", "1"]] {
		Invalid := State.Clone()
		Invalid[Pair[1]] := Pair[2]
		AssertFalse(_ManagedRemoteFixtureRootCleanupMatches(Invalid, "LocalMachine", Thumbprint, Subject),
			"a marker cannot prove absence for the wrong exact ownership tuple")
	}
	for Key in ["root_store_scope", "root_thumbprint", "root_subject", "root_removed"] {
		Invalid := State.Clone()
		Invalid.Delete(Key)
		AssertFalse(_ManagedRemoteFixtureRootCleanupMatches(Invalid, "LocalMachine", Thumbprint, Subject))
	}
}
Test("managed remote native: cleanup requires exact scope and certificate receipt (managed-fixture-root-scope)",
	_ManagedRemoteScopeCleanupReceiptControls)

_ManagedRemoteScopeNativeRefusalBody() {
	Elevated := _ManagedRemoteFixtureTokenElevation()
	AssertTrue(Type(Elevated) == "Integer" && (Elevated == 0 || Elevated == 1))
	Fixture := _ManagedRemoteFixtureOwner()
	if Elevated {
		AssertTrue(_ManagedRemoteFixtureRequireRootScope(Fixture.RootStoreScope),
			"an elevated process still proves permission through its native token")
		AssertEqual(0, Fixture.Capture)
		return
	}
	Caught := false
	try Fixture.Start()
	catch as Failure
		Caught := true
	AssertTrue(Caught, "intent strings alone cannot permit native machine-store acquisition")
	AssertEqual(0, Fixture.Capture)
	AssertEqual(0, Fixture.Handle)
	AssertEqual(0, Fixture.Events.Count)
	AssertEqual("", Fixture.RootThumbprint)
}
Test("managed remote native: native non-elevated machine guard precedes acquisition (managed-fixture-root-scope)",
	_ManagedRemoteScopeWithEnvironment.Bind("LocalMachine", "true", "github-hosted", _ManagedRemoteScopeNativeRefusalBody))

_ManagedRemoteScopeProducerControl() {
	global _DriverDir
	Results := []
	Handle := ShellRunner_SpawnTreeOwned("powershell.exe", ["-NoProfile", "-NonInteractive", "-File",
		_DriverDir . "\tests\fixtures\managed_remote_scope_control.ps1", "-SourcePath",
		_DriverDir . "\tests\fixtures\managed_remote_transport.ps1"],
		(Code, Out, Err) => Results.Push(Map("exit", Code, "stdout", Out, "stderr", Err)), , , 8192)
	try {
		AssertTrue(Handle.start())
		Started := A_TickCount
		; A cold powershell.exe settles in about one second but has taken over
		; five on a loaded runner; the budget matches this file's other cold
		; PowerShell probes. Exit code, exact output and stderr stay asserted.
		while Results.Length == 0 && !TickExpired64(Started, 18000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Results.Length)
		AssertEqual(0, Results[1]["exit"], "the actual producer and remover guards enforce native permission before store access")
		; The scope owner first runs the six native TLS directory controls.
		Expected := "PASS native TLS directory: legacy native owner`n"
			. "PASS native TLS directory: UCRT native owner`n"
			. "PASS native TLS directory: credential compatibility is not native Git`n"
			. "PASS native TLS directory: ambiguous owners refused`n"
			. "PASS native TLS directory: empty prefix refused`n"
			. "PASS native TLS directory: absent installation refused`n"
			. "NATIVE_TLS_DIRECTORY_CONTROL_OK 6/6`n"
			. "OWNED_ROOT_SCOPE_CONTROL_PASS"
		AssertEqual(Expected, StrReplace(Trim(Results[1]["stdout"], "`r`n "), "`r`n", "`n"))
		AssertEqual("", Results[1]["stderr"])
	} finally AssertTrue(Handle.terminate(), "the exact scope behavior-probe Job retires")
}
Test("managed remote native: producer and cleanup guard own token and scope (managed-fixture-root-scope)",
	_ManagedRemoteScopeProducerControl)

class _ManagedRemoteScopeClosedCleanupHandle {
	terminate() {
		return true
	}
}

_ManagedRemoteScopeCleanupActualBody() {
	for Valid in [false, true] {
		Fixture := _ManagedRemoteFixtureOwner()
		Fixture.RootThumbprint := "00112233445566778899AABBCCDDEEFF00112233"
		Fixture.RootSubject := "CN=ErgoptiPlus managed-network fixture " . Fixture.Identity
		Directory := _SR_AcquireCaptureDirectory()
		Capture := Map("CaptureDir", Directory, "TmpFile", Directory . "output.tmp")
		Fixture.Capture := Capture
		Fixture.CleanupHandle := _ManagedRemoteScopeClosedCleanupHandle()
		Fixture.CleanupCompletions.Push(Map("exit", 0, "stdout", "OWNED_ROOT_REMOVED", "stderr", ""))
		Scope := Valid ? "CurrentUser" : "LocalMachine"
		FileAppend('{"version":1,"operation":"root_cleanup","root_store_scope":"' . Scope
			. '","root_thumbprint":"' . Fixture.RootThumbprint . '","root_subject":"' . Fixture.RootSubject
			. '","root_removed":true}', Capture["TmpFile"], "UTF-8-RAW")
		try {
			AssertEqual(Valid, Fixture.Close(), "the actual cleanup path rejects a marker for the wrong captured scope")
			AssertEqual(Valid, Fixture.RootRemovalVerified, "wrong-scope absence cannot release root cleanup ownership")
			AssertFalse(Fixture.GracefulReceiptVerified, "scope acknowledgment cannot grant an absent graceful service receipt")
		} finally {
			if !Valid
				AssertEqual(0, _SR_CaptureRemove(Capture))
		}
	}
}
Test("managed remote native: actual cleanup marker requires scoped receipt (managed-fixture-root-scope)",
	_ManagedRemoteScopeWithEnvironment.Bind("", "", "", _ManagedRemoteScopeCleanupActualBody))

_ManagedRemoteTokenQueryControl(Control, Token) {
	Control["queries"] += 1
	AssertEqual(Control["token"], Token, "permission observes only the exact acquired token")
	if Control["query_failure"]
		throw Control["primary"]
	return true
}

_ManagedRemoteTokenCloseControl(Control, Token) {
	Control["closes"] += 1
	AssertEqual(Control["token"], Token, "every retry retains the same exact retirement capability")
	if Control["close_throw"] && !Control["ack"]
		throw Control["secondary"]
	return Control["ack"]
}

_ManagedRemoteTokenDebtControls() {
	global _ManagedRemoteFixtureTokenDebt
	AssertEqual(0, _ManagedRemoteFixtureTokenDebt.Count)
	for QueryFailure in [false, true] {
		for CloseThrow in [false, true] {
			Control := Map("token", 12345, "queries", 0, "closes", 0, "ack", false,
				"query_failure", QueryFailure, "close_throw", CloseThrow,
				"primary", ValueError("controlled query failure"), "secondary", TypeError("controlled close failure"))
			Port := Map("open", (*) => Control["token"], "query", _ManagedRemoteTokenQueryControl.Bind(Control),
				"close", _ManagedRemoteTokenCloseControl.Bind(Control))
			Owner := _ManagedRemoteFixtureTokenOwner(Port)
			try {
				Caught := false
				try Owner.Observe()
				catch Any as Failure {
					Caught := true
					if QueryFailure
						AssertTrue(Failure == Control["primary"], "close refusal cannot overwrite the original query exception")
					else if CloseThrow
						AssertTrue(Failure == Control["secondary"], "a close exception remains the first failure when query succeeded")
				}
				AssertTrue(Caught, "successful query plus incomplete retirement never grants permission")
				AssertEqual(12345, Owner.Token)
				AssertFalse(Owner.ObservationComplete)
				AssertEqual(1, _ManagedRemoteFixtureTokenDebt.Count)
				AssertTrue(_ManagedRemoteFixtureTokenDebt[ObjPtr(Owner)] == Owner)
				FirstCloseFailure := Owner.RetirementFailure
				Control["secondary"] := Error("controlled later close failure")
				AssertFalse(Owner.Retire(), "debt remains owned until the exact close acknowledgment")
				if CloseThrow
					AssertTrue(Owner.RetirementFailure == FirstCloseFailure, "retirement retry preserves its first exception")
				Blocked := false
				try _ManagedRemoteFixtureTokenElevation(Port)
				catch Any
					Blocked := true
				AssertTrue(Blocked, "incomplete debt cannot be retried as a permission observation")
				AssertEqual(1, Control["queries"], "retirement retries never query or reuse incomplete authorization")
				Control["ack"] := true
				_ManagedRemoteFixtureRetryTokenRetirement()
				AssertEqual(0, Owner.Token)
				AssertEqual(0, _ManagedRemoteFixtureTokenDebt.Count)
				AssertEqual("acknowledged", Owner.RetirementStatus)
				AssertFalse(Owner.ObservationComplete, "late close acknowledgment cannot authorize the failed observation")
				Blocked := false
				try Owner.Observe()
				catch Any
					Blocked := true
				AssertTrue(Blocked, "the completed retirement cannot reopen the same observation")
				AssertEqual(1, Control["queries"])
			} finally {
				Control["ack"] := true
				Owner.Retire()
			}
		}
	}
	for QueryFailure in [false, true] {
		Control := Map("token", 12345, "queries", 0, "closes", 0, "ack", true,
			"query_failure", QueryFailure, "close_throw", false, "primary", ValueError("controlled query failure"))
		Port := Map("open", (*) => Control["token"], "query", _ManagedRemoteTokenQueryControl.Bind(Control),
			"close", _ManagedRemoteTokenCloseControl.Bind(Control))
		Owner := _ManagedRemoteFixtureTokenOwner(Port)
		Caught := false
		try AssertTrue(Owner.Observe(), "complete query and close return the actual permission result")
		catch Any as Failure {
			Caught := true
			AssertTrue(Failure == Control["primary"], "acknowledged retirement preserves a failed query")
		}
		AssertEqual(QueryFailure, Caught)
		AssertEqual(!QueryFailure, Owner.ObservationComplete)
		AssertEqual(0, Owner.Token)
		AssertEqual(0, _ManagedRemoteFixtureTokenDebt.Count)
		AssertEqual(1, Control["queries"])
		AssertEqual(1, Control["closes"])
	}
}
Test("managed remote native: token query and close failures retain exact debt (managed-fixture-token-debt)",
	_ManagedRemoteTokenDebtControls)

class _ManagedRemotePrimaryControlFixture {
	__New() {
		this.Primary := ValueError("PRIVATE_BODY_FAILURE")
		this.RootThumbprint := "controlled"
		this.RootRemovalVerified := true
		this.GracefulReceiptVerified := false
		this.Events := Map()
		this.StartCalls := 0
		this.CloseCalls := 0
	}

	Start(*) {
		this.StartCalls += 1
		throw this.Primary
	}

	Close() {
		this.CloseCalls += 1
		return true
	}
}

_ManagedRemotePrimaryActualEntryControl() {
	Fixture := _ManagedRemotePrimaryControlFixture()
	SavedEnvironment := Map()
	for Name in ["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY"] {
		SavedEnvironment[Name] := EnvGet(Name)
		EnvSet(Name, "")
	}
	Observed := 0
	try {
		try _ManagedRemote_ActualSystemTrustAndSelectedTransport(Fixture)
		catch as Failure
			Observed := Failure
	} finally {
		for Name, Value in SavedEnvironment
			EnvSet(Name, Value)
	}
	AssertEqual(1, Fixture.StartCalls, "the real entry must execute the controlled failing body")
	AssertEqual(1, Fixture.CloseCalls, "the original cleanup assertions must still execute once")
	AssertTrue(Observed == Fixture.Primary, "the real entry must retain the exact body exception when its graceful cleanup assertion also fails")
}
Test("managed remote native: actual entry preserves primary through graceful refusal (managed-fixture-primary-cleanup)",
	_ManagedRemotePrimaryActualEntryControl)

_ManagedRemotePrimaryBodyControl(State, Refused) {
	State.BodyCalls += 1
	if Refused
		throw State.Primary
}

_ManagedRemotePrimaryCleanupControl(State, Refused) {
	State.CleanupCalls += 1
	if Refused
		throw State.Cleanup
}

_ManagedRemotePrimaryPrintControl(State, Refused, Line) {
	State.PrintCalls += 1
	State.Lines.Push(Line)
	if Refused
		throw Error("PRIVATE_REPORTER_FAILURE")
}

_ManagedRemotePrimaryCombinationControl(BodyRefused, CleanupRefused, ReporterRefused) {
	State := {BodyCalls: 0, CleanupCalls: 0, PrintCalls: 0, Lines: [],
		Primary: ValueError("PRIVATE_BODY_FAILURE"), Cleanup: TypeError("PRIVATE_CLEANUP_FAILURE")}
	Fixture := {CleanupFailureCheckpointStatus: "not_requested"}
	PrimaryFailure := 0
	BodyFailed := false
	Observed := 0
	Expected := BodyRefused ? State.Primary : (CleanupRefused ? State.Cleanup : 0)
	OriginalStack := IsObject(Expected) ? Expected.Stack : ""
	try {
		try _ManagedRemotePrimaryBodyControl(State, BodyRefused)
		catch Any as Failure
		{
			PrimaryFailure := Failure
			BodyFailed := true
		}
		finally _ManagedRemoteFixtureFinalize(Fixture, BodyFailed, PrimaryFailure,
			_ManagedRemotePrimaryCleanupControl.Bind(State, CleanupRefused),
			_ManagedRemotePrimaryPrintControl.Bind(State, ReporterRefused))
	} catch Any as Failure {
		Observed := Failure
	}
	AssertEqual(1, State.BodyCalls, "the body executes exactly once")
	AssertEqual(1, State.CleanupCalls, "cleanup executes exactly once for either body outcome")
	AssertTrue(Observed == Expected, "body failure takes priority; cleanup failure remains fatal after a successful body")
	if IsObject(Expected)
		AssertEqual(OriginalStack, Observed.Stack, "rethrow preserves the original exception's source stack")
	AssertEqual(CleanupRefused ? 1 : 0, State.PrintCalls, "reporter refusal cannot recurse or print a successful cleanup")
	AssertEqual(CleanupRefused ? (ReporterRefused ? "unavailable" : "reported") : "not_requested",
		Fixture.CleanupFailureCheckpointStatus, "reporting refusal remains inspectable without altering either exception")
	for Line in State.Lines {
		AssertEqual("::notice title=Windows native fixture cleanup failure::body_failed="
			. (BodyRefused ? "true" : "false") . " cleanup_failed=true cleanup_exception=type_error", Line)
		AssertFalse(InStr(Line, "PRIVATE_"), "no exception text enters the cleanup checkpoint")
	}
}
for Pair in [[false, false], [false, true], [true, false], [true, true]] {
	for ReporterRefused in [false, true]
		Test("managed remote native: body=" . Pair[1] . " cleanup=" . Pair[2] . " reporter=" . ReporterRefused
			. " preserves failure priority (managed-fixture-primary-cleanup)",
			_ManagedRemotePrimaryCombinationControl.Bind(Pair[1], Pair[2], ReporterRefused))
}

_ManagedRemotePrimaryPrimitiveControl(Value) {
	State := {CleanupCalls: 0, PrintCalls: 0, Lines: [], Cleanup: TypeError("PRIVATE_CLEANUP_FAILURE")}
	Fixture := {CleanupFailureCheckpointStatus: "not_requested"}
	Observed := 0
	Caught := false
	try _ManagedRemoteFixtureFinalize(Fixture, true, Value,
		_ManagedRemotePrimaryCleanupControl.Bind(State, true), _ManagedRemotePrimaryPrintControl.Bind(State, false))
	catch Any as Failure {
		Observed := Failure
		Caught := true
	}
	AssertTrue(Caught, "even a zero or empty-string primary exception must be rethrown")
	AssertEqual(Value, Observed, "exception priority does not depend on truthiness or object type")
	AssertEqual(1, State.CleanupCalls)
	AssertEqual(1, State.PrintCalls)
}
for Pair in [["zero", 0], ["empty", ""], ["string", "PRIVATE_BODY_PRIMITIVE"]]
	Test("managed remote native: " . Pair[1] . " exception retains priority (managed-fixture-primary-cleanup)",
		_ManagedRemotePrimaryPrimitiveControl.Bind(Pair[2]))
