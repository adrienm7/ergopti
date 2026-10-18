; tests/unit/platform/network/test_managed_remote_cleanup_diagnostics.ahk

; ==============================================================================
; MODULE: Managed Remote Fixture Cleanup Diagnostics
; DESCRIPTION:
; The managed remote fixture's cleanup diagnostics: closed projections that
; exclude private captures, retained cleanup gates and receipts, and a TAP
; reporter or printer failure that preserves the cleanup result.
; ==============================================================================

#Requires AutoHotkey v2.0





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

; Independent startup facts supplement, never replace, the original service fact.
_ManagedRemoteFixtureStartupDiagnostic(StartupState) {
	if !(StartupState is Map) || Type(StartupState.Get("version", "")) != "Integer" || StartupState["version"] != 1
		return ""
	StartupPhase := StartupState.Get("startup_phase", "")
	StartupConstructor := StartupState.Get("startup_constructor_phase", "")
	StartupRows := StartupState.Get("startup_errors", 0)
	StartupTruncated := StartupState.Get("startup_errors_truncated", "")
	if Type(StartupPhase) != "String" || !RegExMatch(StartupPhase, "\A(?:admission|curl_preflight|add_type|constructor|open_events|initial_publish|event_loop)\z")
		return ""
	if Type(StartupConstructor) != "String" || !RegExMatch(StartupConstructor, "\A(?:not_entered|listeners|keys|root_certificate|leaf_certificate|crl|native_tls|listener_threads)\z")
		return ""
	if !(StartupRows is Array) || StartupRows.Length < 1 || StartupRows.Length > 4
			|| Type(StartupTruncated) != "Integer" || (StartupTruncated != 0 && StartupTruncated != 1)
		return ""
	StartupFact := "startup_phase=" . StartupPhase . " constructor_phase=" . StartupConstructor
	for StartupIndex, StartupRow in StartupRows {
		if !(StartupRow is Map)
			return ""
		StartupKind := StartupRow.Get("kind", "")
		StartupCode := StartupRow.Get("hresult", "")
		if Type(StartupKind) != "String" || !RegExMatch(StartupKind, "\A(?:runtime|method_invocation|parse|target_invocation|type_initialization|invalid_operation|cryptographic|win32|io|invalid_data|disposed|type_load|dll_not_found|entry_point_not_found|missing_method|security|argument|other)\z")
			return ""
		if Type(StartupCode) != "Integer" || StartupCode < -2147483648 || StartupCode > 2147483647
			return ""
		StartupFact .= " exception" . (StartupIndex - 1) . "=" . StartupKind . ":" . Format("{:d}", StartupCode)
	}
	return StartupFact . " truncated=" . (StartupTruncated ? "true" : "false")
}

; Native TLS progress is supplementary data, never a readiness or cleanup ACK.
_ManagedRemoteFixtureTlsDiagnostic(State) {
	if !(State is Map) || Type(State.Get("version", "")) != "Integer" || State["version"] != 1
		return ""
	Phase := State.Get("tls_initialization_phase", "")
	if Type(Phase) != "String" || !RegExMatch(Phase, "\A(?:not_entered|preconditions|directories|source_fences|crypto_image|ssl_image|dependency_images|identity|initialize|exports|context|certificate|private_key|source_receiving|ready)\z")
		return ""
	return "phase=" . Phase
}

_ManagedRemoteFixtureEmitDiagnostic(State) {
	try {
		Fact := _ManagedRemoteFixtureDiagnostic(State)
		if Fact != ""
			_TestPrint("::notice title=Windows native service diagnostic::" . Fact)
	}
	try {
		StartupFact := _ManagedRemoteFixtureStartupDiagnostic(State)
		if StartupFact != ""
			_TestPrint("::notice title=Windows native startup diagnostic::" . StartupFact)
	} catch Any {
		; Optional startup reporting cannot replace the original refusal.
	}
	try {
		TlsFact := _ManagedRemoteFixtureTlsDiagnostic(State)
		if TlsFact != ""
			_TestPrint("::notice title=Windows native TLS initialization diagnostic::" . TlsFact)
	} catch Any {
		; Optional TLS progress cannot replace the original refusal.
	}
}

; Project the already-closed owner and final receipt before their private removal.
_ManagedRemoteFixtureGroup6CleanupDiagnosticFact(State, Completions) {
	try {
		if !(State is Map) || !(Completions is Array) || Completions.Length > 4096
			return ""
		Phase := State.Get("state", "unknown")
		if !(Phase is String) || !RegExMatch(Phase, "\A(?:unknown|starting|ready|failed|stopped)\z")
			Phase := "unknown"
		Stage := State.Get("root_install_stage", "unknown")
		if !(Stage is String) || !RegExMatch(Stage, "\A(?:unknown|none|create_store|open_store|verify_absent|export_public|add_root|verify_present|close_store|complete)\z")
			Stage := "unknown"
		Fact := "state=" . Phase . " root_install_stage=" . Stage
		for Name in ["root_removed", "service_stopped", "server_tls_source_unchanged"] {
			Value := State.Get(Name, -1)
			if Type(Value) != "Integer" || (Value != 0 && Value != 1)
				Value := -1
			Fact .= " " . Name . "=" . Value
		}
		for Name in ["ServiceFailures", "server_tls_owned_streams", "server_tls_owned_modules", "server_tls_owned_source_fences"] {
			Value := State.Get(Name, -1)
			if Type(Value) != "Integer" || Value < -1 || Value > 4096
				Value := -1
			Fact .= " " . Name . "=" . Value
		}
		Fact .= " completions=" . Completions.Length
		ExitCode := "unknown"
		Marker := "unknown"
		if Completions.Length == 1 && Completions[1] is Map {
			Code := Completions[1].Get("exit", "unknown")
			if Type(Code) == "Integer" && Code >= -2147483648 && Code <= 4294967295
				ExitCode := Format("{:d}", Code)
			Out := Completions[1].Get("stdout", "")
			if Out is String
				Marker := Trim(Out, "`r`n ") == "OWNED_FIXTURE_STOPPED_ROOT_REMOVED" ? "match" : "mismatch"
		}
		return Fact . " exit=" . ExitCode . " marker=" . Marker
	}
	return ""
}

_ManagedRemoteFixtureGroup6CleanupDiagnostic(State, Completions) {
	try {
		Fact := _ManagedRemoteFixtureGroup6CleanupDiagnosticFact(State, Completions)
		if Fact != ""
			_TestPrint("::notice title=Windows native cleanup receipt::" . Fact)
	}
}

; Observe only a dialog class belonging to the still-owned native child, before termination.
; Window text and certificate identities never leave the private owner.
_ManagedRemoteFixtureGroup6ObserveDialog(Handle) {
	Callback := 0
	try {
		Pid := Handle.processId()
		if !(Pid is Integer) || Pid <= 0 || Pid > 4294967295
			return
		Observation := Map("dialog", 0, "visible", 0, "failed", false)
		Callback := CallbackCreate(_ManagedRemoteFixtureGroup6InspectWindow.Bind(Pid, Observation), "", 2)
		if !DllCall("User32\EnumWindows", "Ptr", Callback, "Ptr", 0, "Int") || Observation["failed"]
			return
		_TestPrint("::notice title=Windows native owned dialog::dialog=" . Observation["dialog"] . " visible=" . Observation["visible"])
	} finally {
		if Callback
			CallbackFree(Callback)
	}
}

_ManagedRemoteFixtureGroup6InspectWindow(Pid, Observation, Window, Parameter) {
	try {
		WindowPid := 0
		if !DllCall("User32\GetWindowThreadProcessId", "Ptr", Window, "UInt*", &WindowPid, "UInt") {
			Observation["failed"] := true
			return 1
		}
		if WindowPid != Pid
			return 1
		ClassName := Buffer(128, 0)
		if !DllCall("User32\GetClassNameW", "Ptr", Window, "Ptr", ClassName, "Int", 64, "Int") {
			Observation["failed"] := true
			return 1
		}
		if StrGet(ClassName, "UTF-16") == "#32770" {
			Observation["dialog"] := 1
			if DllCall("User32\IsWindowVisible", "Ptr", Window, "Int")
				Observation["visible"] := 1
		}
	} catch {
		Observation["failed"] := true
	}
	return 1
}

_ManagedRemoteFixtureGroup6CleanupDiagnosticControls() {
	State := Map("state", "stopped", "root_removed", true, "service_stopped", true,
		"server_tls_source_unchanged", true, "ServiceFailures", 0, "server_tls_owned_streams", 0,
		"server_tls_owned_modules", 0, "server_tls_owned_source_fences", 0)
	Completion := Map("exit", 0, "stdout", "OWNED_FIXTURE_STOPPED_ROOT_REMOVED", "stderr", "private")
	Expected := "state=stopped root_install_stage=unknown root_removed=1 service_stopped=1 server_tls_source_unchanged=1"
		. " ServiceFailures=0 server_tls_owned_streams=0 server_tls_owned_modules=0 server_tls_owned_source_fences=0"
		. " completions=1 exit=0 marker=match"
	AssertEqual(Expected, _ManagedRemoteFixtureGroup6CleanupDiagnosticFact(State, [Completion]))
	for Pair in [["state", "stopped`nprivate"], ["root_install_stage", "add_root`nprivate"], ["root_removed", "private"],
		["server_tls_owned_streams", 4097], ["ServiceFailures", -2]] {
		Invalid := State.Clone()
		Invalid[Pair[1]] := Pair[2]
		Fact := _ManagedRemoteFixtureGroup6CleanupDiagnosticFact(Invalid, [Completion])
		AssertTrue(Fact != "", "unknown scalar observations must remain explicit")
		AssertTrue(!InStr(Fact, "private"), "private values cannot enter the diagnostic")
	}
	Completion["stdout"] := "private signed URL and credentials"
	AssertContains(_ManagedRemoteFixtureGroup6CleanupDiagnosticFact(State, [Completion]), "marker=mismatch")
	AssertTrue(!InStr(_ManagedRemoteFixtureGroup6CleanupDiagnosticFact(State, [Completion]), "private"))
	AssertContains(_ManagedRemoteFixtureGroup6CleanupDiagnosticFact(State, []), "completions=0 exit=unknown marker=unknown")
	AssertEqual("", _ManagedRemoteFixtureGroup6CleanupDiagnosticFact(0, []))
}
Test("managed remote native: closed cleanup projection excludes private captures", _ManagedRemoteFixtureGroup6CleanupDiagnosticControls)

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
