; tests/unit/test_managed_curl_owner.ahk

; ==============================================================================
; MODULE: Managed Curl Request Ownership Controls
; DESCRIPTION:
; Calls actual request and generation owners through explicit I/O ports. These
; controls prove driver admission/retirement behavior, not native wire success.
; The preserved eight-case fixture separately calls the real managed worker.
; ==============================================================================

class _ManagedCurlControlJob {
	__New(State) {
		this.State := State
	}
	start() {
		this.State["starts"] += 1
		return true
	}
	terminate() {
		this.State["terminates"].Push(ObjPtr(this))
		return this.State["retire"]
	}
}

_ManagedCurlControlSpawn(State, Executable, Args, Callback, *) {
	State["spawns"] += 1
	State["executable"] := Executable
	State["argv"] := Args.Clone()
	State["callback"] := Callback
	State["directory"] := State["request"].ManagedCapture["CaptureDir"]
	State["input"] := JsonParse(FileRead(State["request"].ManagedCapture["TmpFile"], "UTF-8"))
	State["job"] := _ManagedCurlControlJob(State)
	if State.Get("cancel_in_spawn", false)
		State["request"].Abort()
	return State["job"]
}

_ManagedCurlControlNew(State) {
	Request := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(State)))
	State["request"] := Request
	Request.SetManagedRouting()
	State["origin"] := A_TickCount
	Request.SetDeadline(State["origin"], 20000)
	Request.Open("POST", "https://safe.invalid/api?private=owned-url", true)
	Request.SetRequestHeader("Authorization", "Bearer private-provider-token")
	return Request
}

_ManagedCurlControlState() {
	return Map("spawns", 0, "starts", 0, "terminates", [], "retire", true)
}

_ManagedCurlControlAck(State, Mode := "valid", OpenFn := 0) {
	Request := State["request"]
	Ack := '{"schema_version":1,"state":"ready","request_id":'
		. JsonStringLiteral(Mode == "foreign" ? "foreign_request" : Request.CleanupDebtId)
	Ack .= ',"tls_backend":"schannel","child_quiesced":' . (Mode == "forged" ? '"1"' : "true") . '}'
	; Match the worker's private stage/rename protocol: the active admission timer
	; must never see a final receipt while its bytes are still being written.
	Stage := State["directory"] . "admission.pending"
	AssertTrue(FSWrite(Stage, Ack, OpenFn), "the explicit native-receipt port must stage its owned control")
	AssertEqual(1, FSAtomicMoveCreate(Stage, State["directory"] . "admission.json"),
		"only the complete exact staged admission may acquire the final path")
}

_ManagedCurlControlAckOpenDuringPoll(State, Path, Mode, Encoding) {
	File := FileOpen(Path, Mode, Encoding)
	if !IsObject(File)
		return File
	try {
		State["poll_during_ack_write"] += 1
		Request := State["request"]
		Request._PollManagedAdmission()
		AssertFalse(Request.Aborted, "an incomplete private stage cannot retire the request")
		AssertFalse(Request.ManagedPayloadPublished, "an incomplete ACK cannot admit secrets")
		AssertFalse(FileExist(State["directory"] . "admission.json"), "the final ACK stays absent until its staged bytes close")
		AssertFalse(FileExist(State["directory"] . "transport.json"), "transport stays absent during the controlled publication boundary")
		return File
	} catch as Failure {
		File.Close()
		throw Failure
	}
}

_ManagedCurlControlAckPublicationBoundary() {
	State := _ManagedCurlControlState()
	State["poll_during_ack_write"] := 0
	Request := _ManagedCurlControlNew(State)
	try {
		AssertTrue(Request.Send("private-user-payload"))
		_ManagedCurlControlAck(State, "valid", _ManagedCurlControlAckOpenDuringPoll.Bind(State))
		AssertEqual(1, State["poll_during_ack_write"], "the control must poll after real file creation and before any ACK bytes")
		Request._PollManagedAdmission()
		AssertFalse(Request.Aborted, "complete owned publication preserves the original request")
		AssertTrue(Request.ManagedPayloadPublished, "only the complete admitted ACK releases transport staging")
		Published := JsonParse(FileRead(State["directory"] . "transport.json", "UTF-8"))
		AssertEqual(Request.CleanupDebtId, Published["request_id"], "publication retains the exact native request identity")
		AssertEqual("private-user-payload", Published["body"])
		AssertEqual(State["origin"], Request.DeadlineStart, "publication cannot restart the native clock")
		AssertEqual(20000, Request.DeadlineTimeout, "publication cannot increase the original budget")
	} finally _ManagedCurlControlRelease(State)
}
Test("managed curl owner: a poll during ACK staging cannot observe partial admission (managed-ack-publication)",
	_ManagedCurlControlAckPublicationBoundary)

_ManagedCurlControlSecretsWaitForNativeAdmission() {
	State := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(State)
	try {
		AssertTrue(Request.Send("private-user-payload"))
		AssertEqual(1, State["spawns"], "the request owns one Job across all native phases")
		AssertEqual(State["origin"], State["input"]["started_tick"], "discovery cannot reset the original native clock")
		AssertEqual(20000, State["input"]["deadline_ms"], "capability and transport inherit the exact original duration")
		AssertEqual("", State["input"]["body"], "no payload is staged before an actual owned capability acknowledgement")
		AssertEqual(0, State["input"]["headers"].Length, "no provider header is staged before owned native admission")
		AssertFalse(FileExist(State["directory"] . "transport.json"), "transport input stays unpublished before admission")
		for Argument in State["argv"] {
			AssertFalse(InStr(Argument, "private-provider-token"), "tokens never enter argv")
			AssertFalse(InStr(Argument, "private-user-payload"), "typed payload never enters argv")
			AssertFalse(InStr(Argument, "safe.invalid"), "the complete URL remains private")
		}
		_ManagedCurlControlAck(State)
		Request._PollManagedAdmission()
		Published := JsonParse(FileRead(State["directory"] . "transport.json", "UTF-8"))
		AssertEqual("private-user-payload", Published["body"], "the exact admitted body remains unchanged")
		AssertEqual("Bearer private-provider-token", Published["headers"][1]["value"], "the captured provider header remains private and exact")
		AssertEqual(Request.CleanupDebtId, Published["request_id"], "the private transport carries the same exact request identity")
		AssertFalse(IsObject(Request.ManagedAdmissionFn), "successful admission releases its timer callback")
		AssertEqual("", Request.ManagedTransportImage, "publication releases the retained staging image")
	} finally _ManagedCurlControlRelease(State)
}
Test("managed curl owner: secrets wait for exact native admission under the original clock", _ManagedCurlControlSecretsWaitForNativeAdmission)

_ManagedCurlControlBadAck(Mode) {
	State := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(State)
	try {
		AssertTrue(Request.Send("private-user-payload"))
		_ManagedCurlControlAck(State, Mode)
		Request._PollManagedAdmission()
		AssertTrue(Request.Aborted, "a foreign or forged acknowledgement retires the exact request")
		AssertFalse(Request.ManagedPayloadPublished, "bad native admission cannot stage provider data")
		AssertFalse(FileExist(State["directory"] . "transport.json"), "bad admission cannot publish transport input")
		AssertEqual(0, Request.Status, "a rejected receipt cannot publish a response")
		AssertFalse(IsObject(Request.ManagedAdmissionFn), "retirement releases the admission callback")
	} finally _ManagedCurlControlRelease(State)
}
Test("managed curl owner: foreign request acknowledgement refuses payload publication", _ManagedCurlControlBadAck.Bind("foreign"))
Test("managed curl owner: string-valued native closing acknowledgement refuses publication", _ManagedCurlControlBadAck.Bind("forged"))

_ManagedCurlControlExpiredAck() {
	State := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(State)
	try {
		AssertTrue(Request.Send("private-user-payload"))
		; This control manually delivers the poll after expiry. Stop only this
		; request's admission callback before ACK publication can make it due.
		AssertTrue(IsObject(Request.ManagedAdmissionFn), "manual expiry must own the actual admission callback")
		SetTimer(Request.ManagedAdmissionFn, 0)
		_ManagedCurlControlAck(State)
		Request.DeadlineStart := 0
		Request.DeadlineTimeout := 1
		Request._PollManagedAdmission()
		AssertTrue(Request.Aborted, "expiry is checked at acknowledgement, without waiting for deadline-timer dispatch")
		AssertFalse(Request.ManagedPayloadPublished, "late native receipts cannot revive payload admission")
		AssertEqual(0, Request.Status, "expired requests publish no response")
	} finally _ManagedCurlControlRelease(State)
}
Test("managed curl owner: a late native acknowledgement cannot revive the expired absolute budget", _ManagedCurlControlExpiredAck)

_ManagedCurlControlLateHandle() {
	State := _ManagedCurlControlState()
	State["cancel_in_spawn"] := true
	Request := _ManagedCurlControlNew(State)
	try {
		AssertFalse(Request.Send("private-user-payload"), "a cancellation during owner construction refuses dispatch")
		AssertEqual(0, State["starts"], "a late returned handle must never start")
		AssertEqual(1, State["terminates"].Length, "the exact late owner must physically retire once")
		AssertEqual(ObjPtr(State["job"]), State["terminates"][1], "retirement must target the returned Job identity")
		AssertTrue(Request.Completed, "the acknowledged late owner settles the canceled request")
		AssertFalse(Request.ManagedPayloadPublished, "late construction cannot publish provider data")
	} finally _ManagedCurlControlRelease(State)
}
Test("managed curl owner: cancellation during Job construction retires the exact late handle", _ManagedCurlControlLateHandle)

_ManagedCurlControlRefusedRetirement() {
	global _HTTP_CURL_ABORT_DEBTS
	State := _ManagedCurlControlState()
	State["retire"] := false
	Request := _ManagedCurlControlNew(State)
	try {
		AssertTrue(Request.Send("private-user-payload"))
		AssertFalse(Request.Abort(), "a refused Job close cannot claim completion")
		AssertFalse(Request.Completed, "physical debt keeps the request nonterminal")
		AssertTrue(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId), "the exact request remains strongly retained")
		AssertEqual(ObjPtr(State["job"]), ObjPtr(Request.Handle), "unacknowledged ownership retains the exact handle")
		AssertFalse(IsObject(Request.ManagedAdmissionFn), "cancellation stops future payload admission")
		AssertFalse(Request.ManagedPayloadPublished, "retained debt is never new consent")
		State["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
		AssertTrue(Request.Completed, "a later exact tree completion can settle refused retirement")
		AssertEqual(0, Request.Status, "canceled completion cannot publish success")
		AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId), "physical completion releases only its exact debt")
	} finally {
		State["retire"] := true
		_ManagedCurlControlRelease(State)
	}
}
Test("managed curl owner: refused Job retirement retains exact debt and discards late success", _ManagedCurlControlRefusedRetirement)

_ManagedCurlControlReplacementFactory(State) {
	global _LLM_Remote_Async
	Request := _ManagedCurlControlNew(State)
	State["reservation"]["cancelled"] := true
	State["replacement"] := Map("cancelled", false)
	_LLM_Remote_Async[State["id"]] := State["replacement"]
	return Request
}

_ManagedCurlControlGenerationSupersession() {
	global _LLM_Remote_Async
	Saved := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _ManagedCurlControlState()
	State["id"] := 902143
	try {
		Resolved := Map("Format", "openai", "Token", "private-provider-token", "Model", "fixture")
		State["reservation"] := _LLMRemote_ReserveRequest(State["id"], (*) => 0, (*) => 0, 20000, A_TickCount, Resolved)
		Port := Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
			"create_http", _ManagedCurlControlReplacementFactory.Bind(State))
		AssertTrue(_LLMRemote_DispatchManagedCurl(State["id"], State["reservation"], Resolved,
			"https://safe.invalid/api", "private-user-payload", Port))
		AssertEqual(0, State["spawns"], "a superseded generation cannot stage or start the transport")
		AssertEqual(ObjPtr(State["replacement"]), ObjPtr(_LLM_Remote_Async[State["id"]]),
			"old cleanup cannot consume the successor registry owner")
		AssertTrue(State["request"].Aborted, "the canceled facade is retired before dispatch")
	} finally {
		if State.Has("request")
			_ManagedCurlControlRelease(State)
		_LLM_Remote_Async := Saved
	}
}
Test("managed curl owner: production generation preserves a reentrant successor before staging", _ManagedCurlControlGenerationSupersession)

_ManagedCurlControlRelease(State) {
	if State.Has("request")
		State["request"].Abort()
	if State.Has("job")
		State["job"].State := 0
	for Name in ["job", "callback", "request", "reservation", "replacement"]
		if State.Has(Name)
			State.Delete(Name)
}

_ManagedCurlControlExpireBeforePublish(Request) {
	Request.DeadlineStart := 0
	Request.DeadlineTimeout := 1
}

_ManagedCurlControlLatePublication() {
	State := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(State)
	Request.DispatchPort["before_response_publish"] := _ManagedCurlControlExpireBeforePublish
	try {
		AssertTrue(Request.Send("private-user-payload"))
		AssertTrue(FSWrite(Request.BodyPath, "late-response-body"))
		AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 200 OK`r`nX-Late: forbidden`r`n`r`n"))
		State["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
		AssertTrue(Request.Completed, "the exact physically closed Job may settle after publication expiry")
		AssertTrue(Request.Aborted, "final publication observes the original clock after a reentrant callback")
		AssertEqual(0, Request.Status, "expiry between receipt and final publication cannot publish status")
		AssertEqual("", Request.ResponseText, "expiry cannot publish materialized response data")
		AssertEqual(0, Request.ResponseHeaders.Count, "expiry cannot publish staged response headers")
		AssertFalse(IsObject(Request.Handle), "exact terminal Job acknowledgement releases its handle")
	} finally _ManagedCurlControlRelease(State)
}
Test("managed curl owner: reentrant final publication cannot outlive the original clock", _ManagedCurlControlLatePublication)

_ManagedCurlControlIdentityFactory(State) {
	return State["request"]
}

_ManagedCurlControlGenerationAdmissionRevoked(ReplaceOwner := false, YieldAfterAck := false) {
	global _LLM_Remote_Async
	Saved := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _ManagedCurlControlState()
	State["id"] := 902144
	Request := _ManagedCurlControlNew(State)
	PreviousCritical := A_IsCritical
	try {
		Resolved := Map("Format", "openai", "Token", "private-provider-token", "Model", "fixture")
		State["reservation"] := _LLMRemote_ReserveRequest(State["id"], (*) => 0, (*) => 0, 20000, A_TickCount, Resolved)
		Port := Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
			"create_http", _ManagedCurlControlIdentityFactory.Bind(State))
		AssertTrue(_LLMRemote_DispatchManagedCurl(State["id"], State["reservation"], Resolved,
			"https://safe.invalid/api", "private-user-payload", Port))
		; These controls deliver the poll only after generation revocation. Hold
		; this request's timer before the completed ACK can make admission due.
		AssertTrue(IsObject(Request.ManagedAdmissionFn), "manual generation revocation must own the actual admission callback")
		if YieldAfterAck {
			AssertEqual(0, A_IsCritical, "the interleave control must allow actual timer dispatch")
			SetTimer(Request.ManagedAdmissionFn, -1)
		}
		SetTimer(Request.ManagedAdmissionFn, 0)
		_ManagedCurlControlAck(State)
		if YieldAfterAck {
			Sleep(30)
			AssertTrue(IsObject(Request.ManagedAdmissionFn), "holding this timer preserves the exact callback until manual revocation")
			AssertFalse(Request.ManagedPayloadPublished, "a yielded completed ACK cannot bypass manual generation revocation")
			AssertFalse(Request.Aborted, "holding admission leaves the original request live until revocation")
			AssertEqual(State["reservation"]["start_tick"], Request.DeadlineStart, "the interleave cannot restart the original clock")
			AssertEqual(State["reservation"]["timeout_ms"], Request.DeadlineTimeout, "the interleave cannot extend the original budget")
		}
		Critical("On")
		if ReplaceOwner {
			State["replacement"] := Map("cancelled", false)
			_LLM_Remote_Async[State["id"]] := State["replacement"]
		} else {
			LLM_RemoteCancelAsync(State["id"])
			AssertFalse(Request.Aborted, "native termination remains deferred at the real cancellation boundary")
		}
		Request._PollManagedAdmission()
		AssertFalse(Request.ManagedPayloadPublished, "revoked exact generation admission cannot stage provider payload")
		AssertFalse(FileExist(State["directory"] . "transport.json"), "queued native acknowledgement cannot restore revoked consent")
		AssertTrue(Request.Aborted, "the facade retires revoked native admission without publishing data")
		if ReplaceOwner
			AssertEqual(ObjPtr(State["replacement"]), ObjPtr(_LLM_Remote_Async[State["id"]]), "old admission cleanup preserves the successor")
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
		_ManagedCurlControlRelease(State)
		_LLM_Remote_Async := Saved
	}
}
Test("managed curl owner: real generation cancellation revokes a queued native admission", _ManagedCurlControlGenerationAdmissionRevoked)
Test("managed curl owner: generation replacement after Send revokes native admission", _ManagedCurlControlGenerationAdmissionRevoked.Bind(true))
Test("managed curl owner: queued admission cannot beat cancellation after a yielded ACK", _ManagedCurlControlGenerationAdmissionRevoked.Bind(false, true))
Test("managed curl owner: queued admission cannot beat replacement after a yielded ACK", _ManagedCurlControlGenerationAdmissionRevoked.Bind(true, true))
