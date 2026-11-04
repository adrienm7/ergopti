; tests/unit/platform/network/test_managed_remote_readiness_diagnostics.ahk

; ==============================================================================
; MODULE: Managed Remote Generation and Readiness Diagnostics
; DESCRIPTION:
; Generation and readiness checkpoints observe the actual retained
; callbacks, close their scalar domains, refuse malformed receipts and keep
; the original assertion; startup and TLS-phase projections stay closed.
; ==============================================================================

#Requires AutoHotkey v2.0





; Generation evidence comes only from the exact retained callback and transport.
_ManagedRemoteFixtureGenerationInteger(Value, Minimum, Maximum) {
	return Type(Value) == "Integer" && Value >= Minimum && Value <= Maximum
		? Format("{:d}", Value) : "unknown"
}

_ManagedRemoteFixtureGenerationReceipt(Receipt, Policy) {
	if !(Receipt is Map)
		return Map("state", "unavailable", "fields", Map())
	if Receipt.Count == 0
		return Map("state", "missing", "fields", Map())
	if Receipt.Count > Policy["fields"].Count
		return Map("state", "invalid", "fields", Map())
	Fields := Map()
	Fields.CaseSense := "On"
	for Name, Value in Receipt {
		Definition := _ManagedNetwork_Get(Policy["fields"], Name)
		if !(Definition is Map) || !_ManagedNetwork_Scalar(Value, Definition)
			|| (Definition["type"] == "integer" && Type(Value) != "Integer")
			|| (Value is String && (StrLen(Value) > 128 || _ManagedNetworkWindows_HasStoredNul(Value)))
			return Map("state", "invalid", "fields", Map())
		Fields[Name] := Value
	}
	return Map("state", "admitted", "fields", Fields)
}

_ManagedRemoteFixtureGenerationDiagnostic(Mode, Ordinal, ExpectedSuccess, Result, Receipt := 0) {
	global _SharedDir
	Policy := ManagedNetworkFailureContract(JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8"))).Policy
	Success := Result is Map ? _ManagedNetwork_Get(Result, "success") : 0
	Failure := Result is Map ? _ManagedNetwork_Get(Result, "failure") : 0
	Info := Failure is Array && Failure.Length == 1 && Failure[1] is Map ? Failure[1] : Map()
	Reason := _ManagedRemoteFixtureDiagnosticEnum(_ManagedNetwork_Get(Info, "reason", ""),
		"transport|timeout|dispatch|proxy_resolution|provider_error|empty_body|malformed_json|unsupported_json_root|unsupported_shape|canonical_empty|trimmed|invalid_model|not_chat|completion")
	Fact := "generation_mode=" . _ManagedRemoteFixtureDiagnosticEnum(Mode, "fixed|pac")
		. " generation_ordinal=" . _ManagedRemoteFixtureGenerationInteger(Ordinal, 1, 4)
		. " expected_success=" . _ManagedRemoteFixtureDiagnosticBoolean(ExpectedSuccess)
		. " success_callbacks=" . (Success is Array ? _ManagedRemoteFixtureGenerationInteger(Success.Length, 0, 65535) : "unknown")
		. " failure_callbacks=" . (Failure is Array ? _ManagedRemoteFixtureGenerationInteger(Failure.Length, 0, 65535) : "unknown")
		. " callback_reason=" . Reason
		. " callback_status=" . _ManagedRemoteFixtureGenerationInteger(_ManagedNetwork_Get(Info, "status", ""), 0, 599)
	return Fact . _ManagedRemoteFixtureTransportDiagnostic(Receipt, Policy)
}

; Both checkpoints use the same existing closed receipt parser and field projection.
_ManagedRemoteFixtureTransportDiagnostic(Receipt, Policy) {
	Fact := ""
	Admitted := _ManagedRemoteFixtureGenerationReceipt(Receipt, Policy)
	Fact .= " native_receipt=" . Admitted["state"]
	Fields := Admitted["fields"]
	for Name in ["backend", "stage", "failure_provenance", "proxy_mode", "native_errno_domain", "tls_status", "tls_verification", "dotnet_web_status"] {
		Value := _ManagedNetwork_Get(Fields, Name, "")
		Definition := Policy["fields"][Name]
		Fact .= " " . Name . "=" . (Value is String && Value != "" && _ManagedNetwork_Scalar(Value, Definition) ? Value : "unknown")
	}
	for Pair in [["curl_exit", 255], ["http_status", 599], ["proxy_connect_status", 599]]
		Fact .= " " . Pair[1] . "=" . _ManagedRemoteFixtureGenerationInteger(_ManagedNetwork_Get(Fields, Pair[1], ""), 0, Pair[2])
	Code := _ManagedNetwork_Get(Fields, "native_errno", "")
	NativeCode := "unknown"
	if Code is String && RegExMatch(Code, "\A-?(?:0|[1-9][0-9]{0,9})\z") {
		NativeValue := Integer(Code)
		if NativeValue >= -2147483648 && NativeValue <= 2147483647
			NativeCode := Format("{:d}", NativeValue)
	}
	return Fact . " native_errno=" . NativeCode
}

_ManagedRemoteFixtureEmitGenerationDiagnostic(Fixture, ReqId, Reservation, Result, ExpectedSuccess, Mode, Ordinal) {
	Fixture.GenerationDiagnosticStatus := "unavailable"
	try {
		Receipt := 0
		if Fixture.Requests is Map && Fixture.Requests.Has(ReqId)
			&& Fixture.Requests[ReqId] == Reservation && Reservation is Map {
			Http := Reservation.Get("http", 0)
			if Http is CurlAsyncRequest && Type(Http.ManagedTransport) == "Integer" && Http.ManagedTransport == true
				Receipt := Http.NativeReceipt
		}
		Fact := _ManagedRemoteFixtureGenerationDiagnostic(Mode, Ordinal, ExpectedSuccess, Result, Receipt)
		Fixture.GenerationDiagnosticPrinter.Call("::notice title=Windows native generation diagnostic::" . Fact)
		Fixture.GenerationDiagnosticStatus := "reported"
	} catch Any {
		; Reporting refusal leaves the original acceptance failure authoritative.
		Fixture.GenerationDiagnosticStatus := "unavailable"
	}
}


; The declared HTTP seam drives the actual generation producer without networking.
class _ManagedRemoteGenerationDiagnosticHttp extends CurlAsyncRequest {
	__New(Receipt) {
		super.__New()
		this.ManagedTransport := true
		this.NativeReceipt := Receipt
		this.Polls := 0
	}
	SetManagedRouting(Args*) {
	}
	SetDeadline(Args*) {
	}
	Open(Args*) {
	}
	SetRequestHeader(Args*) {
	}
	Send(Args*) => true
	WaitForResponse(Args*) {
		this.Polls += 1
		return this.Polls >= 2
	}
	Abort() => true
}

class _ManagedRemoteGenerationDiagnosticOwner extends _ManagedRemoteFixtureOwner {
	__New(Printer, Receipt) {
		this.Identity := "generation-diagnostic-control"
		this.Mode := "fixed"
		this.GenerationCount := 1
		this.Requests := Map()
		this.BaseUrl := "https://managed-fixture.invalid:443/v1"
		this.Http := _ManagedRemoteGenerationDiagnosticHttp(Receipt)
		this.Port := Map("managed_settings", ObjBindMethod(this, "ReadConfig"), "create_http", ObjBindMethod(this, "CreateHttp"))
		this.GenerationDiagnosticPrinter := Printer
		this.GenerationDiagnosticStatus := "not_requested"
	}
	ReadConfig() => Map()
	CreateHttp() => this.Http
}

_ManagedRemoteGenerationDiagnosticReceipt() {
	return Map("backend", "curl", "stage", "connect", "failure_provenance", "verified", "tls_verification", "enforced",
		"curl_exit", 60, "http_status", 0, "proxy_connect_status", 200, "proxy_mode", "selected")
}

_ManagedRemoteGenerationCollect(Control, Text) {
	Control["calls"] += 1
	Control["fact"] := Text
	if Control.Get("refuse", false)
		throw Error("PRIVATE_REPORTER_EXCEPTION")
}

_ManagedRemoteGenerationDiagnosticProducer(RefusePrinter := false) {
	global _LLM_Remote_Async
	Control := Map("calls", 0, "fact", "", "refuse", RefusePrinter)
	Fixture := _ManagedRemoteGenerationDiagnosticOwner(_ManagedRemoteGenerationCollect.Bind(Control), _ManagedRemoteGenerationDiagnosticReceipt())
	Caught := 0
	try Fixture.CheckGeneration(true)
	catch Error as Failure {
		Caught := Failure
	}
	finally {
		for ReqId, Reservation in Fixture.Requests {
			if _LLMRemote_RequestOwns(ReqId, Reservation) {
				Fixture.Http.Abort()
				_LLMRemote_DeleteOwned(ReqId, Reservation)
			}
		}
	}
	AssertEqual("Error", Type(Caught), "only the original generation assertion is expected")
	AssertEqual("generation must obey actual system-root admission - expected: <1>, actual: <0>", Caught.Message)
	AssertEqual(1, Control["calls"], "actual producer must expose the owned callback before its original refusal")
	AssertTrue(Fixture.Http.Polls >= 2, "the real managed poll owns the callback")
	AssertContains(Control["fact"], "generation_mode=fixed generation_ordinal=2 expected_success=true success_callbacks=0 failure_callbacks=1 callback_reason=transport callback_status=0")
	AssertContains(Control["fact"], "native_receipt=admitted backend=curl stage=connect")
	AssertContains(Control["fact"], "proxy_mode=selected")
	AssertContains(Control["fact"], "curl_exit=60 http_status=0 proxy_connect_status=200")
	AssertFalse(InStr(Control["fact"], "managed-fixture.invalid"))
	AssertEqual(RefusePrinter ? "unavailable" : "reported", Fixture.GenerationDiagnosticStatus)
	for ReqId in Fixture.Requests
		AssertFalse(_LLM_Remote_Async.Has(ReqId), "no exact controlled request survives the original assertion")
}
Test("managed remote native: generation checkpoint observes actual retained callback (managed-fixture-generation-diagnostic)", _ManagedRemoteGenerationDiagnosticProducer)
Test("managed remote native: generation reporter refusal preserves original assertion (managed-fixture-generation-diagnostic)", _ManagedRemoteGenerationDiagnosticProducer.Bind(true))

_ManagedRemoteGenerationDiagnosticScalars() {
	Result := Map("success", [], "failure", [Map("reason", "transport", "status", 0, "message", "PRIVATE_MESSAGE")])
	for Value in [0, 1.0, "1", [], Map(), Buffer(2)] {
		Fact := _ManagedRemoteFixtureGenerationDiagnostic(Value, Value, Value, Result)
		AssertContains(Fact, "generation_mode=unknown")
		AssertContains(Fact, "generation_ordinal=unknown")
	}
	for Mode in ["fixed", "pac"] {
		Fact := _ManagedRemoteFixtureGenerationDiagnostic(Mode, 3, true, Result)
		AssertContains(Fact, "generation_mode=" . Mode . " generation_ordinal=3")
		AssertFalse(InStr(Fact, "PRIVATE_"))
	}
	for Value in ["PRIVATE_REASON", "Transport", 1, 1.0, [], Map(), Buffer(2)] {
		Result["failure"][1]["reason"] := Value
		AssertContains(_ManagedRemoteFixtureGenerationDiagnostic("fixed", 2, true, Result), "callback_reason=unknown")
	}
	for Value in [-1, 600, 1.0, "1", [], Map(), Buffer(2)] {
		Result["failure"][1]["status"] := Value
		AssertContains(_ManagedRemoteFixtureGenerationDiagnostic("fixed", 2, true, Result), "callback_status=unknown")
	}
}
Test("managed remote native: generation checkpoint closes scalar domains (managed-fixture-generation-diagnostic)", _ManagedRemoteGenerationDiagnosticScalars)

_ManagedRemoteGenerationDiagnosticReceiptControls() {
	Result := Map("success", [], "failure", [])
	for Value in [0, 1.0, "PRIVATE_RECEIPT", [], Buffer(2)]
		AssertContains(_ManagedRemoteFixtureGenerationDiagnostic("pac", 3, true, Result, Value), "native_receipt=unavailable")
	AssertContains(_ManagedRemoteFixtureGenerationDiagnostic("pac", 3, true, Result, Map()), "native_receipt=missing")
	for Value in ["PRIVATE_BACKEND", "Curl", 1, 1.0, [], Map(), Buffer(2)] {
		Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
		Receipt["backend"] := Value
		Fact := _ManagedRemoteFixtureGenerationDiagnostic("pac", 3, true, Result, Receipt)
		AssertContains(Fact, "native_receipt=invalid backend=unknown")
		AssertFalse(InStr(Fact, "PRIVATE_"))
	}
	Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
	Receipt["PRIVATE_PATH"] := "PRIVATE_BODY"
	AssertContains(_ManagedRemoteFixtureGenerationDiagnostic("fixed", 2, true, Result, Receipt), "native_receipt=invalid")

	for Name in ["stage", "failure_provenance", "proxy_mode", "native_errno_domain", "tls_status", "tls_verification", "dotnet_web_status"] {
		for Value in ["PRIVATE_ENUM", 0, 1.0, [], Map(), Buffer(2)] {
			Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
			Receipt[Name] := Value
			AssertContains(_ManagedRemoteFixtureGenerationDiagnostic("pac", 3, true, Result, Receipt), "native_receipt=invalid")
		}
	}
	for Name in ["curl_exit", "http_status", "proxy_connect_status"] {
		for Value in [1.0, "1", [], Map(), Buffer(2)] {
			Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
			Receipt[Name] := Value
			AssertContains(_ManagedRemoteFixtureGenerationDiagnostic("pac", 3, true, Result, Receipt), "native_receipt=invalid")
		}
	}
	for Pair in [["-2147483648", "-2147483648"], ["2147483647", "2147483647"], ["0", "0"]] {
		Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
		Receipt["native_errno_domain"] := "winsock"
		Receipt["native_errno"] := Pair[1]
		AssertContains(_ManagedRemoteFixtureGenerationDiagnostic("fixed", 2, true, Result, Receipt), "native_errno=" . Pair[2])
	}

	for Value in ["PRIVATE_ERRNO", "01", "2147483648", "-2147483649"] {
		Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
		Receipt["native_errno"] := Value
		Fact := _ManagedRemoteFixtureGenerationDiagnostic("fixed", 2, true, Result, Receipt)
		AssertContains(Fact, "native_errno=unknown")
		AssertFalse(InStr(Fact, "PRIVATE_"))
	}
}
Test("managed remote native: generation checkpoint rejects malformed native receipt (managed-fixture-generation-diagnostic)", _ManagedRemoteGenerationDiagnosticReceiptControls)

; Wrap the declared creator while returning the exact object it produced.
_ManagedRemoteCaptureReadinessHttp(Observation, Factory) {
	Http := Factory.Call()
	Observation["http"] := Http
	return Http
}

_ManagedRemoteReadinessDiagnostic(Mode, Expected, Results, Elapsed, Budget, Status, Receipt) {
	global _SharedDir
	Policy := ManagedNetworkFailureContract(JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8"))).Policy
	Admitted := _ManagedRemoteFixtureGenerationReceipt(Receipt, Policy)
	Fields := Admitted["fields"]
	Fact := "mode=" . _ManagedRemoteFixtureDiagnosticEnum(Mode, "fixed|pac")
		. " expected=" . _ManagedRemoteFixtureDiagnosticBoolean(Expected)
		. " callbacks=" . (Results is Array ? _ManagedRemoteFixtureGenerationInteger(Results.Length, 0, 65535) : "unknown")
		. " ready=" . (Results is Array && Results.Length == 1 ? _ManagedRemoteFixtureDiagnosticBoolean(Results[1]) : "unknown")
		. " elapsed_ms=" . _ManagedRemoteFixtureGenerationInteger(Elapsed, 0, 2147483647)
		. " budget_ms=" . _ManagedRemoteFixtureGenerationInteger(Budget, 1, 2147483647)
		. " http_status=" . _ManagedRemoteFixtureGenerationInteger(Status, 0, 599)
		. " native_receipt=" . Admitted["state"]
	for Name in ["backend", "stage", "failure_provenance", "tls_status", "tls_verification", "proxy_resolution_status"] {
		Value := _ManagedNetwork_Get(Fields, Name, "")
		Definition := Policy["fields"][Name]
		Fact .= " " . Name . "=" . (Value is String && Value != "" && _ManagedNetwork_Scalar(Value, Definition) ? Value : "unknown")
	}
	return Fact . " curl_exit=" . _ManagedRemoteFixtureGenerationInteger(_ManagedNetwork_Get(Fields, "curl_exit", ""), 0, 255)
}

_ManagedRemoteEmitReadinessDiagnostic(Fixture, Expected, Results, Observation, Owner, Budget) {
	try {
		Http := Observation.Get("http", 0)
		Receipt := 0
		Status := "unknown"
		if Http is CurlAsyncRequest {
			Status := Http.Status
			if Type(Http.ManagedTransport) == "Integer" && Http.ManagedTransport == true
				Receipt := Http.NativeReceipt
		}
		Start := Owner.Get("network_start_tick", 0)
		Elapsed := Type(Start) == "Integer" && Start > 0 ? TickElapsed64(Start) : "unknown"
		Fact := _ManagedRemoteReadinessDiagnostic(Fixture.Mode, Expected, Results, Elapsed, Budget, Status, Receipt)
		Printer := Fixture.HasOwnProp("Group6ReadinessDiagnosticPrinter") ? Fixture.Group6ReadinessDiagnosticPrinter : _TestPrint
		Printer.Call("::notice title=Windows native readiness diagnostic::" . Fact)
	} catch Any {
		; Projection/printing failure cannot replace the original readiness assertion.
	}
}

_ManagedRemoteReadinessDiagnosticControls() {
	Receipt := Map("backend", "curl", "stage", "tls", "failure_provenance", "verified",
		"tls_verification", "enforced", "tls_status", "untrusted_certificate", "curl_exit", 60)
	Fact := _ManagedRemoteReadinessDiagnostic("fixed", true, [false], 1234, 3000, 0, Receipt)
	AssertContains(Fact, "mode=fixed expected=true callbacks=1 ready=false elapsed_ms=1234 budget_ms=3000 http_status=0 native_receipt=admitted")
	AssertContains(Fact, "stage=tls failure_provenance=verified tls_status=untrusted_certificate tls_verification=enforced")
	AssertContains(Fact, "curl_exit=60")
	Receipt["PRIVATE_URL"] := "PRIVATE_TOKEN"
	Fact := _ManagedRemoteReadinessDiagnostic("PRIVATE_MODE", true, [], "3000", "3000", "200", Receipt)
	AssertContains(Fact, "mode=unknown")
	AssertContains(Fact, "callbacks=0 ready=unknown elapsed_ms=unknown budget_ms=unknown http_status=unknown native_receipt=invalid")
	AssertFalse(InStr(Fact, "PRIVATE"), "unknown or private receipt fields cannot enter the projection")
	Http := Object()
	Observation := Map("http", 0)
	Control := {Calls: 0}
	Factory := () => (Control.Calls += 1, Http)
	Returned := _ManagedRemoteCaptureReadinessHttp(Observation, Factory)
	AssertTrue(Returned == Http && Observation["http"] == Http, "the declared factory's exact object returns unchanged")
	AssertEqual(1, Control.Calls, "the passive wrapper creates no additional worker")
}
Test("managed remote native: readiness observations retain exact factory and closed native facts", _ManagedRemoteReadinessDiagnosticControls)

class _ManagedRemoteGroup6ReadinessDiagnosticOwner extends _ManagedRemoteFixtureOwner {
	__New(Printer) {
		this.Identity := "readiness_diagnostic_" . _ManagedRemoteFixtureGuid()
		this.Mode := "fixed"
		this.BaseUrl := "https://managed-fixture.invalid:443/v1"
		this.Http := _ManagedRemoteGenerationDiagnosticHttp(_ManagedRemoteGenerationDiagnosticReceipt())
		this.ReadyOwners := []
		this.ReadyCancels := []
		this.Group6ReadinessDiagnosticPrinter := Printer
		this.ReadinessCount := 0
		this.ReadinessRuns := Map()
		this.ReadinessDiagnosticPrinter := _TestPrint
		this.ReadinessDiagnosticStatus := "not_requested"
		this.FactoryCalls := 0
		this.Port := Map("managed_settings", (*) => Map(), "create_http", ObjBindMethod(this, "CreateHttp"))
	}
	CreateHttp() {
		this.FactoryCalls += 1
		return this.Http
	}
}

_ManagedRemoteGroup6ReadinessDiagnosticProducer(RefusePrinter := false) {
	Control := Map("calls", 0, "fact", "", "refuse", RefusePrinter)
	Fixture := _ManagedRemoteGroup6ReadinessDiagnosticOwner(_ManagedRemoteGenerationCollect.Bind(Control))
	Caught := 0
	try Fixture.CheckReadiness(true)
	catch Error as Failure {
		Caught := Failure
	}
	AssertEqual("Error", Type(Caught), "the real receiving entry retains its readiness assertion")
	AssertEqual("readiness must obey the actual system root and selected relay - expected: <1>, actual: <0>", Caught.Message)
	AssertEqual(1, Control["calls"], "the actual receiving entry diagnoses before its unchanged assertion")
	AssertEqual(1, Fixture.FactoryCalls, "the declared HTTP creator is used exactly once")
	AssertTrue(Fixture.Http.Polls >= 2, "the real readiness poll produces its callback")
	AssertContains(Control["fact"], "mode=fixed expected=true callbacks=1 ready=false")
	AssertContains(Control["fact"], "http_status=0 native_receipt=admitted backend=curl stage=connect")
	AssertContains(Control["fact"], "curl_exit=60")
	AssertFalse(InStr(Control["fact"], "managed-fixture.invalid"), "the actual receiving observation never publishes its destination")
}
Test("managed remote native: actual readiness receiving entry reports its retained transport", _ManagedRemoteGroup6ReadinessDiagnosticProducer)
Test("managed remote native: readiness reporter refusal preserves the original assertion", _ManagedRemoteGroup6ReadinessDiagnosticProducer.Bind(true))


; Capture exact factory returns without changing dispatch, callback or retirement.
_ManagedRemoteFixtureCaptureReadinessHttp(Run, Factory) {
	Http := Factory.Call()
	try Run["http"].Push(Http)
	catch Any {
		Run["capture"] := "unavailable"
	}
	return Http
}

; This observer never changes completion or cleanup, including a failed clock/read.
_ManagedRemoteFixtureCaptureReadinessCallback(Fixture, Run, Owner, TickFn := 0) {
	global TICK_MAX_DURATION_MS
	try {
		if !(Run is Map) || !(Owner is Map) || !(Fixture.ReadinessRuns is Map)
				|| !Fixture.ReadinessRuns.Has(Run.Get("ordinal", 0))
				|| Fixture.ReadinessRuns[Run["ordinal"]] != Run || Run.Get("owner", 0) != Owner
			return false
		Run["callback_capture"] := "unavailable"
		Run["callback_snapshot"] := 0
		if Run.Get("capture", "") != "retained" || !(Run["http"] is Array) || Run["http"].Length != 1
			return false
		Http := Run["http"][1]
		if !(Http is CurlAsyncRequest)
			return false
		Snapshot := Map()
		for Pair in [["send_started", "SendStarted"], ["managed_transport", "ManagedTransport"],
				["payload_reserved", "ManagedPayloadPublished"], ["completed", "Completed"], ["aborted", "Aborted"]] {
			Property := Pair[2]
			Value := Http.%Property%
			if Type(Value) == "Integer" && (Value == 0 || Value == 1)
				Snapshot[Pair[1]] := Value
		}
		Snapshot["handle_retained"] := IsObject(Http.Handle)
		Snapshot["admission_fn_retained"] := IsObject(Http.ManagedAdmissionFn)
		Snapshot["owner_current"] := LLM_AuxIsCurrent(Owner)
		Tick := HasMethod(TickFn, "Call") ? TickFn.Call() : A_TickCount
		Elapsed := TickElapsed64(Owner.Get("network_start_tick", ""), Tick)
		if Type(Elapsed) == "Integer" && Elapsed >= 0 && Elapsed <= TICK_MAX_DURATION_MS
			Snapshot["elapsed_ms"] := Elapsed
		Deadline := Run.Get("deadline_ms", "")
		if Type(Deadline) == "Integer" && Deadline >= 0 && Deadline <= TICK_MAX_DURATION_MS
			Snapshot["deadline_ms"] := Deadline
		Run["callback_snapshot"] := Snapshot
		Run["callback_capture"] := "retained"
		return true
	} catch Any {
		; Unavailable observation cannot suppress the original Boolean callback.
		return false
	}
}

_ManagedRemoteFixtureReadinessCallbackDiagnostic(Snapshot) {
	global TICK_MAX_DURATION_MS
	Fields := Snapshot is Map ? Snapshot : Map()
	Fact := ""
	for Name in ["send_started", "managed_transport", "payload_reserved", "completed", "aborted",
			"handle_retained", "admission_fn_retained", "owner_current"]
		Fact .= " callback_" . Name . "=" . _ManagedRemoteFixtureDiagnosticBoolean(Fields.Get(Name, ""))
	for Name in ["elapsed_ms", "deadline_ms"]
		Fact .= " callback_" . Name . "=" . _ManagedRemoteFixtureGenerationInteger(Fields.Get(Name, ""), 0, TICK_MAX_DURATION_MS)
	return Fact
}

_ManagedRemoteFixtureReadinessDiagnostic(Mode, Ordinal, ExpectedSuccess, Result, Created, Status, Capture, Receipt := 0, CallbackSnapshot := 0, CallbackCapture := "unavailable") {
	global _SharedDir
	Policy := ManagedNetworkFailureContract(JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8"))).Policy
	Actual := Result is Array && Result.Length == 1 ? _ManagedRemoteFixtureDiagnosticBoolean(Result[1]) : "unknown"
	Fact := "readiness_mode=" . _ManagedRemoteFixtureDiagnosticEnum(Mode, "fixed|pac")
		. " readiness_ordinal=" . _ManagedRemoteFixtureGenerationInteger(Ordinal, 1, 4)
		. " expected_success=" . _ManagedRemoteFixtureDiagnosticBoolean(ExpectedSuccess)
		. " callbacks=" . (Result is Array ? _ManagedRemoteFixtureGenerationInteger(Result.Length, 0, 65535) : "unknown")
		. " callback_success=" . Actual
		. " capture=" . _ManagedRemoteFixtureDiagnosticEnum(Capture, "retained|unavailable")
		. " http_created=" . _ManagedRemoteFixtureGenerationInteger(Created, 0, 65535)
		. " request_status=" . _ManagedRemoteFixtureGenerationInteger(Status, 0, 599)
	return Fact . " callback_capture=" . _ManagedRemoteFixtureDiagnosticEnum(CallbackCapture, "retained|unavailable")
		. _ManagedRemoteFixtureReadinessCallbackDiagnostic(CallbackSnapshot) . _ManagedRemoteFixtureTransportDiagnostic(Receipt, Policy)
}

_ManagedRemoteFixtureEmitReadinessDiagnostic(Fixture, Run, Result, ExpectedSuccess) {
	Fixture.ReadinessDiagnosticStatus := "unavailable"
	try {
		Receipt := 0
		Created := ""
		Status := ""
		Capture := "unavailable"
		if Run is Map && Fixture.ReadinessRuns is Map
			&& Fixture.ReadinessRuns.Has(Run["ordinal"]) && Fixture.ReadinessRuns[Run["ordinal"]] == Run {
			Capture := Run["capture"]
			if Capture == "retained" && Run["http"] is Array {
				Created := Run["http"].Length
				if Created == 1 {
					Http := Run["http"][1]
					if Http is CurlAsyncRequest {
						Status := Http.Status
						if Type(Http.ManagedTransport) == "Integer" && Http.ManagedTransport == true
							Receipt := Http.NativeReceipt
					}
				}
			}
		}
		Fact := _ManagedRemoteFixtureReadinessDiagnostic(Run["mode"], Run["ordinal"], ExpectedSuccess, Result, Created, Status, Capture, Receipt,
			Run.Get("callback_snapshot", 0), Run.Get("callback_capture", "unavailable"))
		Fixture.ReadinessDiagnosticPrinter.Call("::notice title=Windows native readiness diagnostic::" . Fact)
		Fixture.ReadinessDiagnosticStatus := "reported"
	} catch Any {
		; Reporting refusal cannot replace the original readiness assertion.
		Fixture.ReadinessDiagnosticStatus := "unavailable"
	}
}

class _ManagedRemoteReadinessDiagnosticOwner extends _ManagedRemoteGenerationDiagnosticOwner {
	__New(Printer, Receipt) {
		super.__New(Printer, Receipt)
		this.Identity := "readiness-diagnostic-control"
		this.ReadyOwners := []
		this.ReadyCancels := []
		this.ReadinessCount := 0
		this.ReadinessRuns := Map()
		this.ReadinessDiagnosticPrinter := Printer
		this.ReadinessDiagnosticStatus := "not_requested"
	}
}

_ManagedRemoteReadinessDiagnosticProducer(RefusePrinter := false, ExpectedSuccess := true, Reachable := false, RefuseObservation := false) {
	Control := Map("calls", 0, "fact", "", "refuse", RefusePrinter)
	Fixture := _ManagedRemoteReadinessDiagnosticOwner(_ManagedRemoteGenerationCollect.Bind(Control), _ManagedRemoteGenerationDiagnosticReceipt())
	Fixture.Http.Status := Reachable ? 200 : 0
	if RefuseObservation
		Fixture.Http.DefineProp("SendStarted", {Get: _ManagedRemoteReadinessCallbackThrow})
	Caught := 0
	try Fixture.CheckReadiness(ExpectedSuccess)
	catch Error as Failure {
		Caught := Failure
	}
	if ExpectedSuccess != Reachable {
		AssertEqual("Error", Type(Caught))
		AssertEqual("readiness must obey the actual system root and selected relay - expected: <1>, actual: <0>", Caught.Message)
		AssertEqual(1, Control["calls"], "the actual producer must emit its retained readiness fact before the unchanged assertion")
		AssertContains(Control["fact"], "readiness_mode=fixed readiness_ordinal=1 expected_success=true callbacks=1 callback_success=false capture=retained http_created=1 request_status=0")
		AssertContains(Control["fact"], "native_receipt=admitted backend=curl stage=connect")
		AssertEqual(RefusePrinter ? "unavailable" : "reported", Fixture.ReadinessDiagnosticStatus)
	} else {
		AssertEqual(0, Caught)
		AssertEqual(0, Control["calls"], "an expected false result does not emit a mismatch")
		AssertEqual("not_requested", Fixture.ReadinessDiagnosticStatus)
	}
	AssertTrue(Fixture.Http.Polls >= 2, "the existing real poll delivers the callback")
	AssertTrue(Fixture.ReadinessRuns[1]["http"][1] == Fixture.Http, "the factory forwarded the same retained transport")
	Run := Fixture.ReadinessRuns[1]
	if RefuseObservation {
		AssertEqual("unavailable", Run["callback_capture"], "a refused observation remains explicit without replacing completion")
		AssertEqual(0, Run["callback_snapshot"])
		AssertContains(Control["fact"], "callback_send_started=unknown")
	} else {
		AssertEqual("retained", Run["callback_capture"])
		AssertEqual(true, Run["callback_snapshot"]["owner_current"], "capture precedes the real auxiliary finish")
		AssertEqual(Run["deadline_ms"], Run["callback_snapshot"]["deadline_ms"], "observation retains the dispatch's original deadline")
		AssertTrue(Type(Run["callback_snapshot"]["elapsed_ms"]) == "Integer" && Run["callback_snapshot"]["elapsed_ms"] >= 0)
	}
	for Owner in Fixture.ReadyOwners
		AssertFalse(LLM_AuxIsCurrent(Owner), "the original owner finishes on the original callback path")
	for CancelFn in Fixture.ReadyCancels
		AssertTrue(CancelFn.Call(), "the original exact cancellation remains available")
	AssertFalse(InStr(Control["fact"], "managed-fixture.invalid"))
	AssertFalse(InStr(Control["fact"], "PRIVATE_"))
}
Test("managed remote native: readiness checkpoint observes actual false callback (managed-fixture-readiness-diagnostic)", _ManagedRemoteReadinessDiagnosticProducer)
Test("managed remote native: readiness reporter refusal preserves original assertion (managed-fixture-readiness-diagnostic)", _ManagedRemoteReadinessDiagnosticProducer.Bind(true))
Test("managed remote native: expected false readiness emits no mismatch (managed-fixture-readiness-diagnostic)", _ManagedRemoteReadinessDiagnosticProducer.Bind(false, false))
Test("managed remote native: successful readiness emits no mismatch (managed-fixture-readiness-diagnostic)", _ManagedRemoteReadinessDiagnosticProducer.Bind(false, true, true))
Test("managed remote native: callback observation refusal preserves original false result and cleanup (managed-fixture-readiness-callback)",
	_ManagedRemoteReadinessDiagnosticProducer.Bind(false, true, false, true))

_ManagedRemoteReadinessCallbackThrow(Args*) {
	throw Error("PRIVATE_OBSERVATION_FAILURE")
}

_ManagedRemoteReadinessCallbackClosedControl() {
	Fixture := _ManagedRemoteReadinessDiagnosticOwner((*) => 0, Map())
	Owner := LLM_AuxBegin(Fixture.Identity)
	Owner["network_start_tick"] := 100
	Run := Map("ordinal", 1, "owner", Owner, "deadline_ms", 3000, "capture", "retained", "http", [Fixture.Http])
	Fixture.ReadinessRuns[1] := Run
	try {
		AssertTrue(_ManagedRemoteFixtureCaptureReadinessCallback(Fixture, Run, Owner, (*) => 137))
		AssertEqual(37, Run["callback_snapshot"]["elapsed_ms"], "elapsed belongs to the original network clock")
		AssertEqual(3000, Run["callback_snapshot"]["deadline_ms"])
		AssertEqual(false, Run["callback_snapshot"]["aborted"])
		Fixture.Http.Aborted := true
		AssertEqual(false, Run["callback_snapshot"]["aborted"], "later cleanup cannot rewrite the callback snapshot")
		Foreign := Run.Clone()
		AssertFalse(_ManagedRemoteFixtureCaptureReadinessCallback(Fixture, Foreign, Owner, (*) => 137), "equal metadata does not replace the exact Run")
		AssertFalse(_ManagedRemoteFixtureCaptureReadinessCallback(Fixture, Run, Owner.Clone(), (*) => 137), "a borrowed owner cannot supply callback context")
		AssertFalse(_ManagedRemoteFixtureCaptureReadinessCallback(Fixture, Run, Owner, _ManagedRemoteReadinessCallbackThrow))
		AssertEqual("unavailable", Run["callback_capture"])
		AssertEqual(0, Run["callback_snapshot"], "failed observation cannot reuse prior scalars")
	} finally _LLM_AuxRetireOwner(Owner)
}
Test("managed remote native: callback scalar capture owns Run clock and immutable observation (managed-fixture-readiness-callback)",
	_ManagedRemoteReadinessCallbackClosedControl)

_ManagedRemoteReadinessCallbackScalarPrivacy(Value) {
	Fields := Map()
	for Name in ["send_started", "managed_transport", "payload_reserved", "completed", "aborted",
			"handle_retained", "admission_fn_retained", "owner_current", "elapsed_ms", "deadline_ms"]
		Fields[Name] := Value
	Fact := _ManagedRemoteFixtureReadinessCallbackDiagnostic(Fields)
	AssertFalse(InStr(Fact, "PRIVATE_"))
	AssertContains(Fact, "callback_send_started=unknown")
	AssertContains(Fact, "callback_elapsed_ms=unknown")
}
for Index, Value in ["PRIVATE_CALLBACK", "true", 1.5, Map("PRIVATE_FIELD", "PRIVATE_VALUE"), [], -1]
	Test("managed remote native: callback scalar " . Type(Value) . " case " . Index . " remains closed (managed-fixture-readiness-callback)",
		_ManagedRemoteReadinessCallbackScalarPrivacy.Bind(Value))

_ManagedRemoteReadinessDiagnosticScalars(Value) {
	Fact := _ManagedRemoteFixtureReadinessDiagnostic(Value, Value, Value, [Value], Value, Value, Value, Value)
	AssertFalse(InStr(Fact, "PRIVATE_"))
	AssertContains(Fact, "readiness_mode=unknown")
	AssertContains(Fact, "native_receipt=" . (Value is Map ? "invalid" : "unavailable"))
}
for Value in ["PRIVATE_SECRET", 1.5, Map("PRIVATE_FIELD", "PRIVATE_SECRET"), [], "true"]
	Test("managed remote native: readiness scalar " . Type(Value) . " refuses private facts (managed-fixture-readiness-diagnostic)",
		_ManagedRemoteReadinessDiagnosticScalars.Bind(Value))

_ManagedRemoteReadinessDiagnosticMalformedReceipt() {
	Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
	Receipt["PRIVATE_FIELD"] := "PRIVATE_SECRET"
	Fact := _ManagedRemoteFixtureReadinessDiagnostic("pac", 3, true, [false], 1, 0, "retained", Receipt)
	AssertContains(Fact, "native_receipt=invalid")
	AssertContains(Fact, "backend=unknown")
	AssertFalse(InStr(Fact, "PRIVATE_"))
	for Pair in [["stage", "PRIVATE_STAGE"], ["backend", "PRIVATE_BACKEND"], ["curl_exit", 1.5]] {
		Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
		Receipt[Pair[1]] := Pair[2]
		Fact := _ManagedRemoteFixtureReadinessDiagnostic("fixed", 2, true, [false], 1, 0, "retained", Receipt)
		AssertContains(Fact, "native_receipt=invalid")
		AssertFalse(InStr(Fact, "PRIVATE_"))
	}
	Receipt := _ManagedRemoteGenerationDiagnosticReceipt()
	Receipt["native_errno"] := "PRIVATE_NOT_AN_INTEGER"
	Fact := _ManagedRemoteFixtureReadinessDiagnostic("fixed", 2, true, [false], 1, 0, "retained", Receipt)
	AssertContains(Fact, "native_errno=unknown")
	AssertFalse(InStr(Fact, "PRIVATE_"))
}
Test("managed remote native: readiness malformed receipt emits no native facts (managed-fixture-readiness-diagnostic)", _ManagedRemoteReadinessDiagnosticMalformedReceipt)


_ManagedRemoteReadinessFactoryRefusal(Failure) {
	throw Failure
}

_ManagedRemoteReadinessFactoryPrimary() {
	Run := Map("http", [], "capture", "retained")
	Primary := Error("PRIVATE_FACTORY_REFUSAL")
	Observed := 0
	try _ManagedRemoteFixtureCaptureReadinessHttp(Run, _ManagedRemoteReadinessFactoryRefusal.Bind(Primary))
	catch Any as Failure {
		Observed := Failure
	}
	AssertTrue(Observed == Primary, "observation never replaces the original factory exception")
	AssertEqual(0, Run["http"].Length)
}
Test("managed remote native: readiness capture preserves factory failure (managed-fixture-readiness-diagnostic)", _ManagedRemoteReadinessFactoryPrimary)

_ManagedRemoteTimingChangedRegistryBudget(Expected, *) {
	global LLM_REMOTE_READY_PING_DEADLINE_MS
	AssertEqual(Expected, LLM_REMOTE_READY_PING_DEADLINE_MS, "the genuine timing loader consumes the changed canonical value")
}

_ManagedRemoteTimingReadinessRegistryChange() {
	global _TimingsCache
	Previous := _TimingsCache
	Changed := Previous.Clone()
	Changed["llm"] := Previous["llm"].Clone()
	Changed["llm"]["request_timeout_ms"] := 7000
	try {
		_TimingsCache := Changed
		_ManagedRemoteFixtureWithLlmTimings(_ManagedRemoteTimingChangedRegistryBudget.Bind(7000))
	} finally _TimingsCache := Previous
}
Test("managed remote native: readiness loader consumes changed canonical request timing (ready-canonical-budget)",
	_ManagedRemoteTimingReadinessRegistryChange)


_ManagedRemoteStartupClosedProjection() {
	StartupState := Map("version", 1, "startup_phase", "constructor", "startup_constructor_phase", "native_tls",
		"startup_errors", [Map("kind", "method_invocation", "hresult", -2146233087),
			Map("kind", "invalid_operation", "hresult", -2146233079)], "startup_errors_truncated", false,
		"private", "PRIVATE_MESSAGE_AND_PATH")
	StartupExpected := "startup_phase=constructor constructor_phase=native_tls exception0=method_invocation:-2146233087 exception1=invalid_operation:-2146233079 truncated=false"
	AssertEqual(StartupExpected, _ManagedRemoteFixtureStartupDiagnostic(StartupState))
	AssertFalse(InStr(_ManagedRemoteFixtureStartupDiagnostic(StartupState), "PRIVATE_"))
	for StartupPair in [["startup_phase", "PRIVATE_PHASE"], ["startup_constructor_phase", "native_tls`nPRIVATE"],
		["startup_errors", []], ["startup_errors_truncated", "false"],
		["startup_errors", [Map("kind", "PRIVATE_TYPE", "hresult", 0)]],
		["startup_errors", [Map("kind", "other", "hresult", "0")]],
		["startup_errors", [Map("kind", "other", "hresult", 2147483648)]],
		["startup_errors", [Map("kind", "other", "hresult", -2147483649)]],
		["startup_errors", [Map(), Map(), Map(), Map(), Map()]]] {
		StartupInvalid := StartupState.Clone()
		StartupInvalid[StartupPair[1]] := StartupPair[2]
		AssertEqual("", _ManagedRemoteFixtureStartupDiagnostic(StartupInvalid), "unknown/private/oversized facts refuse before output")
	}
	StartupState["startup_errors"] := [Map("kind", "other", "hresult", -2147483648), Map("kind", "other", "hresult", 2147483647)]
	StartupState["startup_errors_truncated"] := true
	AssertContains(_ManagedRemoteFixtureStartupDiagnostic(StartupState), "exception0=other:-2147483648 exception1=other:2147483647 truncated=true")
}
Test("managed remote native: startup exception projection keeps closed ordered bounded facts", _ManagedRemoteStartupClosedProjection)

_ManagedRemoteStartupFailedStateRoute() {
	global TEST_RESULTS_FILE
	StartupFixture := _ManagedRemoteFixtureOwner()
	StartupDirectory := _SR_AcquireCaptureDirectory()
	StartupFixture.Capture := Map("TmpFile", StartupDirectory . "output.tmp", "CaptureDir", StartupDirectory)
	StartupState := '{"version":1,"state":"failed","root_store_scope":"CurrentUser","service_failure_stage":"fixture_boundary","service_failure_kind":"other","service_failure_hresult":-2146233087,"startup_phase":"constructor","startup_constructor_phase":"keys","startup_errors":[{"kind":"method_invocation","hresult":-2146233087},{"kind":"cryptographic","hresult":-2146893802}],"startup_errors_truncated":false,"private":"PRIVATE_MESSAGE_AND_PATH"}'
	FileAppend(StartupState, StartupFixture.Capture["TmpFile"], "UTF-8-RAW")
	StartupOffset := FileGetSize(TEST_RESULTS_FILE)
	StartupCaught := 0
	try {
		try StartupFixture.ReadState()
		catch as StartupFailure
			StartupCaught := StartupFailure
		AssertTrue(IsObject(StartupCaught), "actual failed receipt must retain its original refusal")
		AssertEqual("Actual managed-network fixture reported native failure.", StartupCaught.Message)
		StartupTranscript := FileOpen(TEST_RESULTS_FILE, "r", "UTF-8")
		try {
			StartupTranscript.Seek(StartupOffset, 0)
			StartupOutput := StartupTranscript.Read()
		} finally StartupTranscript.Close()
		AssertContains(StartupOutput, "stage=fixture_boundary kind=other hresult=-2146233087")
		AssertContains(StartupOutput, "startup_phase=constructor constructor_phase=keys exception0=method_invocation:-2146233087 exception1=cryptographic:-2146893802 truncated=false")
		AssertFalse(InStr(StartupOutput, "PRIVATE_"))
		AssertFalse(StartupFixture.GracefulReceiptVerified, "diagnostics cannot acknowledge native retirement")
	} finally AssertTrue(StartupFixture.Close(), "only the controlled capture is retired")
}
Test("managed remote native: actual failed state consumes startup facts and preserves refusal",
	_ManagedRemoteScopeWithEnvironment.Bind("CurrentUser", "", "", _ManagedRemoteStartupFailedStateRoute))

_ManagedRemoteTlsPhaseClosedProjection() {
	TlsPhases := ["not_entered", "preconditions", "directories", "source_fences", "crypto_image",
		"ssl_image", "dependency_images", "identity", "initialize", "exports", "context",
		"certificate", "private_key", "source_receiving", "ready"]
	for Phase in TlsPhases {
		State := Map("version", 1, "tls_initialization_phase", Phase, "private", "PRIVATE_MESSAGE_AND_PATH")
		AssertEqual("phase=" . Phase, _ManagedRemoteFixtureTlsDiagnostic(State))
	}
	for Invalid in [Map(), 0, Map("version", "1", "tls_initialization_phase", "ready"),
		Map("version", 2, "tls_initialization_phase", "ready"), Map("version", 1),
		Map("version", 1, "tls_initialization_phase", ""), Map("version", 1, "tls_initialization_phase", 0),
		Map("version", 1, "tls_initialization_phase", "PRIVATE_MESSAGE_AND_PATH"),
		Map("version", 1, "tls_initialization_phase", "ready`nPRIVATE_MESSAGE_AND_PATH"),
		Map("version", 1, "tls_initialization_phase", "ready ")] {
		AssertEqual("", _ManagedRemoteFixtureTlsDiagnostic(Invalid), "only closed native TLS phases may reach the console")
	}
}
Test("managed remote native: startup TLS phase admits only closed scalar facts (managed-fixture-tls-phase-closed)",
	_ManagedRemoteTlsPhaseClosedProjection)

_ManagedRemoteTlsPhaseFailedStateRoute() {
	global TEST_RESULTS_FILE
	Fixture := _ManagedRemoteFixtureOwner()
	Directory := _SR_AcquireCaptureDirectory()
	Fixture.Capture := Map("TmpFile", Directory . "output.tmp", "CaptureDir", Directory)
	State := '{"version":1,"state":"failed","root_store_scope":"CurrentUser","service_failure_stage":"fixture_boundary","service_failure_kind":"other","service_failure_hresult":-2146233087,"tls_initialization_phase":"dependency_images","private":"PRIVATE_MESSAGE_AND_PATH"}'
	FileAppend(State, Fixture.Capture["TmpFile"], "UTF-8-RAW")
	Offset := FileGetSize(TEST_RESULTS_FILE)
	Caught := 0
	try {
		try Fixture.ReadState()
		catch as Failure
			Caught := Failure
		AssertTrue(IsObject(Caught), "the TLS phase cannot turn the failed fixture into readiness")
		AssertEqual("Actual managed-network fixture reported native failure.", Caught.Message)
		Transcript := FileOpen(TEST_RESULTS_FILE, "r", "UTF-8")
		try {
			Transcript.Seek(Offset, 0)
			Output := Transcript.Read()
		} finally Transcript.Close()
		AssertContains(Output, "stage=fixture_boundary kind=other hresult=-2146233087")
		AssertContains(Output, "Windows native TLS initialization diagnostic::phase=dependency_images")
		AssertFalse(InStr(Output, "PRIVATE_"))
		AssertFalse(Fixture.GracefulReceiptVerified, "phase reporting cannot acknowledge native retirement")
	} finally AssertTrue(Fixture.Close(), "only the controlled capture is retired")
}
Test("managed remote native: startup TLS phase survives actual failed-state routing (managed-fixture-tls-phase-route)",
	_ManagedRemoteScopeWithEnvironment.Bind("CurrentUser", "", "", _ManagedRemoteTlsPhaseFailedStateRoute))
