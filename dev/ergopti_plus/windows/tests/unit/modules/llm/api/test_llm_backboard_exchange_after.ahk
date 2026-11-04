; tests/unit/modules/llm/api/test_llm_backboard_exchange_after.ahk

; ==============================================================================
; MODULE: Backboard Exchange Reentrancy Controls
; DESCRIPTION:
; AFTER-only controls use genuine managed request owners through the existing
; transport boundary. A logger callout cancels the inter-stage gap, a retained
; real callback is delivered late, and an old synchronous stage throws after
; admitting its successor. Process and callback delivery remain explicit ports.
; ==============================================================================

#Requires AutoHotkey v2.0

_BBCA_Log(State, Line) {
	if State["mode"] != "cancelall-gap" || !InStr(Line, "Backboard assistant created, kept for this session.")
		return
	try {
		State["gap_seen"] += 1
		AssertEqual(1, State["records"].Length, "the real logger callout must precede message admission")
		LLM_RemoteCancelAllAsync()
	} catch as Failure
		State["sink_error"] := Failure
}

_BBCA_Post(State, Resolved, Url, Payload, OnSuccess, OnFail, TimeoutMs := 0, Kind := "") {
	Id := _BBCR_Post(State, Resolved, Url, Payload, OnSuccess, OnFail, TimeoutMs, Kind)
	if State["mode"] == "old-stage-throws" && State["records"].Length == 1 {
		_BBCR_Complete(State["records"][1], '{"assistant_id":"asst_private","name":"Ergopti+"}')
		throw Error("Controlled old transport return after its synchronous success.")
	}
	return Id
}

_BBCA_Exercise(State) {
	global _LLM_Remote_Async, _LLM_Remote_BackboardExchanges
	Id := _BBCR_Start(State)
	AssertTrue(Id is Integer && Id > 0)
	First := State["records"][1]
	if State["mode"] != "old-stage-throws"
		_BBCR_Complete(First, '{"assistant_id":"asst_private","name":"Ergopti+"}')
	if IsObject(State["sink_error"])
		throw State["sink_error"]
	if State["mode"] == "cancelall-gap" {
		AssertEqual(1, State["gap_seen"], "CancelAll must run at the actual assistant-created logger")
		AssertEqual(1, State["records"].Length, "blanket cancellation must prohibit message admission across the gap")
		AssertFalse(_LLM_Remote_BackboardExchanges.Has(Id), "the exact logical owner must be retired")
		AssertEqual(0, _LLM_Remote_Async.Count, "all private physical reservations must have retired")
	} else {
		AssertEqual(2, State["records"].Length, "the actual continuation must admit exactly its message")
		Current := State["records"][2]
		AssertTrue(_LLMRemote_RequestOwns(Current["id"], Current["entry"]), "the real message reservation must remain current")
		if State["mode"] == "late-callback" {
			Late := Current["entry"]["on_success"]
			LLM_RemoteCancelAsync(Id)
			_LLMRemote_PollRequest(Current["id"])
			AssertTrue(Current["http"].Aborted && Current["http"].Completed)
			AssertEqual(1, Current["control"]["terminates"].Length)
			AssertEqual(ObjPtr(Current["control"]["job"]), Current["control"]["terminates"][1])
			Late.Call('{"content":"stale reply","status":"COMPLETED"}', "")
			AssertFalse(_LLM_Remote_BackboardExchanges.Has(Id), "a retained stale callback cannot revive a logical owner")
			AssertEqual(0, State["successes"], "late delivery must remain silent after real public cancellation")
		} else {
			AssertTrue(_LLM_Remote_BackboardExchanges.Has(Id), "an old-stage exception cannot retire its admitted successor")
			AssertFalse(Current["entry"]["cancelled"], "the successor reservation must remain admitted")
			AssertFalse(Current["http"].Aborted, "the successor facade must remain live")
			AssertEqual(0, Current["control"]["terminates"].Length, "the old return cannot terminate the successor Job")
			_BBCR_Complete(Current, '{"content":"golden successor","status":"COMPLETED"}')
			AssertEqual(1, State["successes"], "the preserved successor must actually deliver")
			AssertEqual("golden successor", State["text"])
			AssertFalse(_LLM_Remote_BackboardExchanges.Has(Id), "normal final completion must release its logical owner")
		}
	}
	AssertEqual(0, State["failures"], "neither user cancellation nor an obsolete stage may publish failure")
}

_BBCA_Case(Mode) {
	global _LLM_Remote_Async, _LLM_Remote_BackboardAssistants, _LLM_Remote_PostBodyFn, _LLM_Remote_BackboardExchanges
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	Saved := {Registry: _LLM_Remote_Async, Cache: _LLM_Remote_BackboardAssistants,
		Post: _LLM_Remote_PostBodyFn, Exchanges: _LLM_Remote_BackboardExchanges}
	State := Map("records", [], "saved_registry", Saved.Registry, "successes", 0, "failures", 0,
		"text", "", "mode", Mode, "gap_seen", 0, "sink_error", 0)
	Primary := 0, CleanupError := 0
	try {
		AssertFalse(SavedLogger.FlushActive)
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		LoggerSetTestSink(_BBCA_Log.Bind(State))
		_LLM_Remote_Async := Map(), _LLM_Remote_BackboardAssistants := Map(), _LLM_Remote_BackboardExchanges := Map()
		_LLM_Remote_PostBodyFn := _BBCA_Post.Bind(State)
		_BBCA_Exercise(State)
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			_BBCR_Release(State)
			AssertEqual(0, _LLM_Remote_BackboardExchanges.Count, "all private logical owners must retire with their child cleanup")
		} catch as Failure {
			CleanupError := Failure
		} finally {
			_LLM_Remote_Async := Saved.Registry, _LLM_Remote_BackboardAssistants := Saved.Cache
			_LLM_Remote_PostBodyFn := Saved.Post, _LLM_Remote_BackboardExchanges := Saved.Exchanges
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Value in SavedExtra
				%Name% := Value
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupError)
		throw CleanupError
}

for _BBCA_Mode in ["cancelall-gap", "late-callback", "old-stage-throws"]
	Test("Backboard exchange AFTER: " . _BBCA_Mode . " retains exact continuation authority (backboard-exchange-after)", _BBCA_Case.Bind(_BBCA_Mode))
