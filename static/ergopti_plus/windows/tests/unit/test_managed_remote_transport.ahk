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
_ManagedRemoteFixtureCleanupDiagnostic(Completions, State, ReadStatus, ExpectedScope := 0) {
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
	if ExpectedScope is String {
		ScopeMatched := ReadStatus == "readable" && _ManagedRemoteFixtureRootScopeMatches(State, ExpectedScope)
		Fields .= " root_scope=" . (ScopeMatched ? "true" : "false")
		if Gate == "none" && !ScopeMatched
			Gate := "root_scope"
	}
	return "cleanup_gate=" . Gate . " receipt_read=" . ReadStatus . Fields
}

_ManagedRemoteFixtureDiagnosticBoolean(Value) {
	return Type(Value) == "Integer" && (Value == 0 || Value == 1) ? (Value ? "true" : "false") : "unknown"
}

_ManagedRemoteFixtureEmitCleanupDiagnostic(Completions, State, ReadStatus, PrintFn := unset, ExpectedScope := 0) {
	if !IsSet(PrintFn)
		PrintFn := _TestPrint
	try {
		PrintFn.Call("::notice title=Windows native fixture cleanup diagnostic::"
			. _ManagedRemoteFixtureCleanupDiagnostic(Completions, State, ReadStatus, ExpectedScope))
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
		State := Valid ? '{"root_store_scope":"' . Fixture.RootStoreScope
			. '","state":"stopped","root_removed":true,"service_stopped":true,"server_tls_owned_streams":0,"server_tls_owned_modules":0,"server_tls_owned_source_fences":0,"server_tls_source_unchanged":true}' : "PRIVATE_INVALID_JSON"
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

; Filtered native tests skip the timing-loader test that a complete suite runs.
; Use the canonical boot owner for each asynchronous acceptance operation, then
; restore the caller's exact timing state even when dispatch or assertions fail.
_ManagedRemoteFixtureWithLlmTimings(Callback) {
	global LLM_OLLAMA_POLL_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_POLL_MS
	global LLM_INSTALLED_CACHE_TTL_MS, LLM_DEPS_POLL_TIMEOUT_MS
	Previous := [IsSet(LLM_OLLAMA_POLL_MS) ? LLM_OLLAMA_POLL_MS : unset,
		IsSet(LLM_REMOTE_TIMEOUT_MS) ? LLM_REMOTE_TIMEOUT_MS : unset,
		IsSet(LLM_REMOTE_POLL_MS) ? LLM_REMOTE_POLL_MS : unset,
		IsSet(LLM_INSTALLED_CACHE_TTL_MS) ? LLM_INSTALLED_CACHE_TTL_MS : unset,
		IsSet(LLM_DEPS_POLL_TIMEOUT_MS) ? LLM_DEPS_POLL_TIMEOUT_MS : unset]
	try {
		LLMApiLoadTimings()
		return Callback.Call()
	} finally {
		LLM_OLLAMA_POLL_MS := Previous.Has(1) ? Previous[1] : unset
		LLM_REMOTE_TIMEOUT_MS := Previous.Has(2) ? Previous[2] : unset
		LLM_REMOTE_POLL_MS := Previous.Has(3) ? Previous[3] : unset
		LLM_INSTALLED_CACHE_TTL_MS := Previous.Has(4) ? Previous[4] : unset
		LLM_DEPS_POLL_TIMEOUT_MS := Previous.Has(5) ? Previous[5] : unset
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
		return _ManagedRemoteFixtureWithLlmTimings(ObjBindMethod(this, "_CheckReadiness", ExpectedSuccess))
	}

	_CheckReadiness(ExpectedSuccess) {
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
				if !this.GracefulReceiptVerified
					this.CleanupDiagnosticStatus := _ManagedRemoteFixtureEmitCleanupDiagnostic(
						this.Completions, FinalState, ReceiptRead, this.CleanupDiagnosticPrinter, this.RootStoreScope)
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

class _ManagedRemoteTimingControlHttp {
	__New() {
		this.Polls := 0
		this.Aborts := 0
		this.Pending := false
		this.Status := 0
		this.ResponseText := ""
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
	global LLM_INSTALLED_CACHE_TTL_MS, LLM_DEPS_POLL_TIMEOUT_MS
	Control["calls"] += 1
	AssertEqual(TimingsGet("llm", "poll_interval_ms"), LLM_OLLAMA_POLL_MS)
	AssertEqual(TimingsGet("llm", "request_timeout_ms"), LLM_REMOTE_TIMEOUT_MS)
	AssertEqual(TimingsGet("llm", "poll_interval_ms"), LLM_REMOTE_POLL_MS)
	AssertEqual(TimingsGet("llm", "installed_cache_ttl_ms"), LLM_INSTALLED_CACHE_TTL_MS)
	AssertEqual(TimingsGet("llm", "dependency_bootstrap_timeout_ms"), LLM_DEPS_POLL_TIMEOUT_MS)
	if Control["fail"]
		throw Control["failure"]
	return "completed"
}

_ManagedRemoteTimingScopeRestores() {
	global LLM_OLLAMA_POLL_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_POLL_MS
	global LLM_INSTALLED_CACHE_TTL_MS, LLM_DEPS_POLL_TIMEOUT_MS, _TimingsCache
	Previous := [IsSet(LLM_OLLAMA_POLL_MS) ? LLM_OLLAMA_POLL_MS : unset,
		IsSet(LLM_REMOTE_TIMEOUT_MS) ? LLM_REMOTE_TIMEOUT_MS : unset,
		IsSet(LLM_REMOTE_POLL_MS) ? LLM_REMOTE_POLL_MS : unset,
		IsSet(LLM_INSTALLED_CACHE_TTL_MS) ? LLM_INSTALLED_CACHE_TTL_MS : unset,
		IsSet(LLM_DEPS_POLL_TIMEOUT_MS) ? LLM_DEPS_POLL_TIMEOUT_MS : unset]
	Cache := _TimingsCache
	try {
		for Mode in ["success", "body_failure", "loader_failure", "unset"] {
			LLM_OLLAMA_POLL_MS := Mode == "unset" ? unset : 101
			LLM_REMOTE_TIMEOUT_MS := Mode == "unset" ? unset : 103
			LLM_REMOTE_POLL_MS := Mode == "unset" ? unset : 107
			LLM_INSTALLED_CACHE_TTL_MS := Mode == "unset" ? unset : 109
			LLM_DEPS_POLL_TIMEOUT_MS := Mode == "unset" ? unset : 113
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
					|| IsSet(LLM_INSTALLED_CACHE_TTL_MS) || IsSet(LLM_DEPS_POLL_TIMEOUT_MS), "unset ownership is restored exactly")
			} else {
				AssertEqual(101, LLM_OLLAMA_POLL_MS)
				AssertEqual(103, LLM_REMOTE_TIMEOUT_MS)
				AssertEqual(107, LLM_REMOTE_POLL_MS)
				AssertEqual(109, LLM_INSTALLED_CACHE_TTL_MS)
				AssertEqual(113, LLM_DEPS_POLL_TIMEOUT_MS)
			}
		}
	} finally {
		_TimingsCache := Cache
		LLM_OLLAMA_POLL_MS := Previous.Has(1) ? Previous[1] : unset
		LLM_REMOTE_TIMEOUT_MS := Previous.Has(2) ? Previous[2] : unset
		LLM_REMOTE_POLL_MS := Previous.Has(3) ? Previous[3] : unset
		LLM_INSTALLED_CACHE_TTL_MS := Previous.Has(4) ? Previous[4] : unset
		LLM_DEPS_POLL_TIMEOUT_MS := Previous.Has(5) ? Previous[5] : unset
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
		while Results.Length == 0 && !TickExpired64(Started, 5000) {
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
		while Results.Length == 0 && !TickExpired64(Started, 5000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Results.Length)
		AssertEqual(0, Results[1]["exit"], "the actual producer and remover guards enforce native permission before store access")
		AssertEqual("OWNED_ROOT_SCOPE_CONTROL_PASS", Trim(Results[1]["stdout"], "`r`n "))
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
