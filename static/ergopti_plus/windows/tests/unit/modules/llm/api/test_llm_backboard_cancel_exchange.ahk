; tests/unit/modules/llm/api/test_llm_backboard_cancel_exchange.ahk

; ==============================================================================
; MODULE: Backboard Exchange Cancellation Controls
; DESCRIPTION:
; Calls the public generation and cancellation APIs across assistant creation.
; The existing transport seam owns real registry reservations and managed HTTP
; facades; only the external process boundary is controlled. It does not claim
; wire traffic, native process exit or elapsed timer delivery.
; ==============================================================================

#Requires AutoHotkey v2.0

_BBCR_NewHttp(Record) {
	Control := _ManagedCurlControlState()
	Request := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(Control)))
	Control["request"] := Request
	Record["control"] := Control
	Record["http"] := Request
	return Request
}

; This is the existing Backboard transport port, not an exchange implementation.
; Real reservation, admission, terminal decoding and polling remain production code.
_BBCR_Post(State, Resolved, Url, Payload, OnSuccess, OnFail, TimeoutMs := 0, Kind := "") {
	global _LLM_Remote_AsyncCounter
	ReqId := ++_LLM_Remote_AsyncCounter
	AssertFalse(State["saved_registry"].Has(ReqId), "a new monotonic ID cannot alias a parked request")
	Entry := _LLMRemote_ReserveRequest(ReqId, OnSuccess, OnFail, TimeoutMs, A_TickCount, Resolved)
	Entry["kind"] := Kind
	Record := Map("id", ReqId, "entry", Entry, "url", Url)
	State["records"].Push(Record)
	Settings := (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", "")
	Port := Map("managed_settings", Settings, "create_http", _BBCR_NewHttp.Bind(Record))
	AssertTrue(_LLMRemote_DispatchManagedCurl(ReqId, Entry, Resolved, Url, Payload, Port),
		"the actual managed dispatcher must accept this exact transport owner")
	Request := Record["http"]
	AssertTrue(Request.Handle == Record["control"]["job"], "the facade must retain its exact controlled Job")
	AssertTrue(IsObject(Request.ManagedAdmissionFn), "the real admission callback must exist")
	SetTimer(Request.ManagedAdmissionFn, 0)
	_ManagedCurlControlAck(Record["control"])
	Request._PollManagedAdmission()
	AssertTrue(Request.ManagedPayloadPublished, "real receipt admission must publish the original body")
	return ReqId
}

_BBCR_Complete(Record, Body) {
	Request := Record["http"]
	AssertTrue(FSWrite(Request.BodyPath, Body), "the owned response body must be durable")
	AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
	Record["control"]["callback"].Call(0,
		'{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
	AssertTrue(Request.Completed, "the managed terminal callback must settle the actual facade")
	AssertEqual(200, Request.Status, "a real successful receipt must reach the consumer")
	AssertTrue(Request.ResponseEncodingValid, "these positive JSON bodies must contain valid UTF-8")
	_LLMRemote_PollRequest(Record["id"])
}

_BBCR_Start(State) {
	return LLM_RemoteGenerate_Async(_LRF_BackboardEntry(), "You predict.", "private exchange text", 0.2,
		(Text, Usage := "") => (State["successes"] += 1, State["text"] := Text),
		(Info := "") => State["failures"] += 1, "", "", "backboard_cancel_control", 20000)
}

_BBCR_Log(State, Line) {
	if State["mode"] != "transition-cancel" || !InStr(Line, "Backboard assistant created, kept for this session.")
		return
	try {
		State["transition_seen"] += 1
		AssertEqual(1, State["records"].Length, "the real logger boundary must precede message dispatch")
		LLM_RemoteCancelAsync(State["initial_id"])
	} catch as Failure
		State["sink_error"] := Failure
}

_BBCR_Transition(State) {
	global _LLM_Remote_Async
	InitialId := _BBCR_Start(State)
	State["initial_id"] := InitialId
	AssertEqual(1, State["records"].Length)
	First := State["records"][1]
	AssertTrue(InitialId is Integer && InitialId > 0, "the public exchange handle must be usable for cancellation")
	AssertContains(First["url"], "/assistants")
	_BBCR_Complete(First, '{"assistant_id":"asst_private","name":"Ergopti+"}')
	if IsObject(State["sink_error"])
		throw State["sink_error"]
	AssertEqual(1, State["transition_seen"], "public cancellation must run at the actual inter-stage logger callout")
	FileAppend("RECEIPT backboard-cancel mode=transition-cancel initial=" . InitialId
		. " requests=" . State["records"].Length . " registry=" . _LLM_Remote_Async.Count
		. " boundary_calls=" . State["transition_seen"] . "`n", "*")
	AssertEqual(1, State["records"].Length, "a cancelled public exchange must never admit its second request after the callout")
	for ReqId, Entry in _LLM_Remote_Async
		AssertTrue(Entry["cancelled"], "no uncancelled private reservation may survive inter-stage cancellation")
	AssertFalse(IsObject(First["http"].Handle), "the already completed assistant must have handed back its exact Job")
	AssertEqual(0, State["successes"])
	AssertEqual(0, State["failures"], "user cancellation must not publish a failure verdict")
}

_BBCR_Release(State) {
	global _LLM_Remote_Async, _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS
	FirstError := 0
	for Record in State["records"] {
		try {
			if Record.Has("http") {
				Request := Record["http"]
				AssertTrue(Request.Abort(), "the exact private Job must acknowledge final retirement")
				AssertFalse(IsObject(Request.Handle), "the exact request must release its controlled handle")
				AssertFalse(IsObject(Request.ManagedCapture), "private capture ownership must retire")
				AssertFalse(Request.CleanupPending, "no private artifact cleanup may be silently deferred")
				AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId))
				AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId))
				for FilePath in [Request.ConfigPath, Request.BodyPath, Request.HeaderPath]
					AssertFalse(FileExist(FilePath), "all private request artifacts must be removed")
			}
			if Record.Has("control") && Record["control"].Has("directory")
				AssertFalse(DirExist(Record["control"]["directory"]), "the private native capture directory must retire")
			if Record.Has("control")
				_ManagedCurlControlRelease(Record["control"])
		} catch as Failure {
			if !IsObject(FirstError)
				FirstError := Failure
		} finally _LLMRemote_DeleteOwned(Record["id"], Record["entry"])
	}
	if IsObject(FirstError)
		throw FirstError
	State["records"].Length := 0
}

_BBCR_Case(Mode) {
	global _LLM_Remote_Async, _LLM_Remote_BackboardAssistants, _LLM_Remote_PostBodyFn
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	SavedRegistry := _LLM_Remote_Async
	SavedCache := _LLM_Remote_BackboardAssistants
	SavedPost := _LLM_Remote_PostBodyFn
	State := Map("records", [], "saved_registry", SavedRegistry, "successes", 0, "failures", 0, "text", "",
		"mode", Mode, "transition_seen", 0, "sink_error", 0)
	Primary := 0
	CleanupError := 0
	try {
		AssertFalse(SavedLogger.FlushActive, "the fixture cannot detach a foreign active logger flush")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		LoggerSetTestSink(_BBCR_Log.Bind(State))
		_LLM_Remote_Async := Map()
		_LLM_Remote_BackboardAssistants := Map()
		_LLM_Remote_PostBodyFn := _BBCR_Post.Bind(State)
		if Mode == "transition-cancel"
			_BBCR_Transition(State)
		else {
			if Mode == "cached-cancel"
				_LLM_Remote_BackboardAssistants[_LLMRemote_BackboardKey(_LLMRemoteResolveEntry(_LRF_BackboardEntry()))] := "asst_private"
			InitialId := _BBCR_Start(State)
			AssertEqual(1, State["records"].Length, "public dispatch must start exactly one request")
			First := State["records"][1]
			AssertTrue(InitialId is Integer && InitialId > 0, "the public exchange handle must be usable for cancellation")
			Create := Mode != "cached-cancel"
			if Create
				AssertContains(First["url"], "/assistants", "cold dispatch must genuinely create the assistant")
			if Create && Mode != "create-cancel" {
				_BBCR_Complete(First, '{"assistant_id":"asst_private","name":"Ergopti+"}')
				AssertEqual(2, State["records"].Length, "the real assistant callback must dispatch the message")
			}
			Current := State["records"][State["records"].Length]
			AssertTrue(_LLMRemote_RequestOwns(Current["id"], Current["entry"]), "the actual active request must be owned before cancellation")
			if Mode == "cold-success" {
				_BBCR_Complete(Current, '{"content":"golden reply","status":"COMPLETED"}')
				AssertEqual(1, State["successes"], "the real two-step exchange must deliver one completion")
				AssertEqual("golden reply", State["text"], "the independent reply must pass through real JSON and chat consumers")
				AssertEqual(0, State["failures"])
				AssertFalse(_LLM_Remote_Async.Has(Current["id"]), "successful message custody must retire")
			} else {
				if Mode == "cold-cancel-unrelated" {
					OtherId := _BBCR_Start(State)
					Other := State["records"][3]
					AssertTrue(OtherId is Integer && OtherId > 0, "the independent public cancellation handle must be valid")
					AssertTrue(_LLMRemote_RequestOwns(Other["id"], Other["entry"]), "the independent cached exchange must be live")
				}
				; This is the same immutable public ID retained by the real Cancel button.
				LLM_RemoteCancelAsync(InitialId)
				; Deliver the ordinary polling turn explicitly; elapsed timer latency is not claimed.
				_LLMRemote_PollRequest(Current["id"])
				Request := Current["http"]
				FileAppend("RECEIPT backboard-cancel mode=" . Mode . " initial=" . InitialId . " active=" . Current["id"]
					. " registered=" . _LLM_Remote_Async.Has(Current["id"]) . " cancelled=" . Current["entry"]["cancelled"]
					. " aborted=" . Request.Aborted . " completed=" . Request.Completed
					. " terminations=" . Current["control"]["terminates"].Length
					. " successes=" . State["successes"] . " failures=" . State["failures"] . "`n", "*")
				AssertFalse(_LLM_Remote_Async.Has(Current["id"]), "cancelling the public exchange ID must retire its active message reservation")
				AssertTrue(Request.Aborted && Request.Completed, "public cancellation must settle the actual active managed facade")
				AssertEqual(1, Current["control"]["terminates"].Length, "public cancellation must terminate exactly the active controlled Job")
				AssertEqual(ObjPtr(Current["control"]["job"]), Current["control"]["terminates"][1], "termination must target the active Job identity")
				AssertEqual(0, State["successes"])
				AssertEqual(0, State["failures"], "user cancellation must not produce a verdict")
				if Mode == "create-cancel"
					AssertEqual(1, State["records"].Length, "cancellation before creation completes must never send a message")
				if Mode == "cold-cancel-unrelated" {
					AssertTrue(_LLMRemote_RequestOwns(Other["id"], Other["entry"]), "cancelling one exchange must preserve another")
					AssertFalse(Other["http"].Aborted, "the unrelated actual facade must remain live")
					AssertEqual(0, Other["control"]["terminates"].Length, "no unrelated Job may be terminated")
				}
			}
		}
	} catch as Failure {
		Primary := Failure
	} finally {
		try _BBCR_Release(State)
		catch as Failure
			CleanupError := Failure
		finally {
			_LLM_Remote_Async := SavedRegistry
			_LLM_Remote_BackboardAssistants := SavedCache
			_LLM_Remote_PostBodyFn := SavedPost
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Value in SavedExtra
				%Name% := Value
			; Production IDs stay monotonic. Queued ordinary polls for these retired
			; IDs cannot alias the parked registry or any later request.
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

for Mode in ["cold-cancel", "cached-cancel", "create-cancel", "cold-success", "cold-cancel-unrelated", "transition-cancel"]
	Test("Backboard exchange: " . Mode . " preserves public cancellation ownership (backboard-exchange-cancel)", _BBCR_Case.Bind(Mode))
