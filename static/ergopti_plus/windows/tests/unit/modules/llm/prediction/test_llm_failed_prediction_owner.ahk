; tests/unit/modules/llm/prediction/test_llm_failed_prediction_owner.ahk

; ==============================================================================
; MODULE: Failed Prediction Presentation Ownership Tests
; DESCRIPTION:
; Public prediction requests retain their real asynchronous engine callbacks.
; The genuine logger yields to a native timer which admits and answers B before
; A's failed finalizer resumes. The existing suite presentation port observes
; exact record, text and visibility; no native pixels or HTTP effect is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_LFO_Transport(State, Entry, SystemPrompt, Context, Temperature, OnSuccess, OnFail,
		Tail := "", MaxTokens := "", Kind := "", TimeoutMs := 0, CurrentFn := 0) {
	global _LLM_Engine
	State.Calls.Push(Map("entry", Entry, "system", SystemPrompt, "ctx", Context,
		"temperature", Temperature, "on_success", OnSuccess, "on_fail", OnFail,
		"tail", Tail, "max_tokens", MaxTokens, "requester_current", CurrentFn, "request_id", _LLM_Engine["request_id"]))
	return State.Calls.Length
}

_LFO_WaitForB(State) {
	Started := A_TickCount
	while !State.Done && TickElapsed64(Started) < 3000
		Sleep(10)
	if IsObject(State.Failure)
		throw State.Failure
	AssertTrue(State.Done && State.TimerCalls == 1,
		"The owned native timer must finish B before the interrupted A frame can resume.")
}

_LFO_AdmitB(State) {
	global _LLM_Engine, _Stub_LlmPresentedRecord, _Stub_LlmTooltipVisible
	global _Stub_LlmTooltipLoading, _Stub_LlmTooltipText
	try {
		AssertFalse(A_IsCritical, "The native callback must not inherit a forced Critical scope.")
		AssertFalse(A_IsSuspended)
		State.TimerCalls += 1
		Before := State.Calls.Length
		LLM_Engine_FirePrediction("Le second message")
		AssertEqual(Before + 1, State.Calls.Length,
			"The genuine backend floor must already permit the one public B dispatch.")
		Call := State.Calls[State.Calls.Length]
		State.BId := Call["request_id"]
		AssertTrue(State.BId != State.AId && _LLM_Engine["request_id"] == State.BId)
		_LPP_Answer(Call, "une suite correcte")
		AssertTrue(_Stub_LlmTooltipVisible && !_Stub_LlmTooltipLoading)
		AssertEqual("une suite correcte", Trim(_Stub_LlmTooltipText))
		State.BRecord := _Stub_LlmPresentedRecord
		AssertTrue(IsObject(State.BRecord) && State.BRecord.IsFinal
			&& State.BRecord.Lifecycle.OfferId == State.BId,
			"B must own a complete affirmative presentation before A resumes.")
		State.BText := _Stub_LlmTooltipText
	} catch Any as Failure {
		if !IsObject(State.Failure)
			State.Failure := Failure
	} finally State.Done := true
}

_LFO_Log(State, Line) {
	if !InStr(Line, "[WARNING] [LLM] All variants failed for model")
		return
	try {
		State.FailedLines += 1
		if State.Mode != "logger-gap" || !State.Armed
			return
		AssertFalse(A_IsCritical)
		State.Armed := false
		; Use the real backend floor. No request timestamp or rate state is changed.
		SetTimer(State.Timer, -State.FloorMs)
		_LFO_WaitForB(State)
	} catch Any as Failure {
		if !IsObject(State.Failure)
			State.Failure := Failure
		throw Failure
	}
}

_LFO_Exercise(State) {
	global _LLM_Engine, _Stub_LlmPresentedRecord, _Stub_LlmTooltipVisible
	global _Stub_LlmTooltipLoading, _Stub_LlmTooltipText
	AssertFalse(A_IsSuspended)
	AssertFalse(A_IsCritical)
	State.FloorMs := _LLM_Engine["min_request_interval_ms"] + 1
	AssertTrue(State.FloorMs is Integer && State.FloorMs > 1 && State.FloorMs < 3000)
	State.Timer := _LFO_AdmitB.Bind(State)
	LLM_Engine_FirePrediction("Le premier message")
	AssertEqual(1, State.Calls.Length)
	State.AId := State.Calls[1]["request_id"]
	AssertTrue(_Stub_LlmTooltipVisible && _Stub_LlmTooltipLoading
		&& _Stub_LlmPresentedRecord.Lifecycle.OfferId == State.AId,
		"A must own the genuine loading presentation before any failure.")
	if State.Mode == "stale-entry" {
		SetTimer(State.Timer, -State.FloorMs)
		_LFO_WaitForB(State)
		State.Calls[1]["on_fail"].Call(Map("reason", "transport", "message", "controlled unavailable backend"))
		AssertEqual(0, State.FailedLines, "The stale entry control must not enter the old finalizer.")
	} else {
		AssertTrue(State.Mode == "current" || State.Mode == "logger-gap")
		State.Armed := State.Mode == "logger-gap"
		Attempts := _LLM_Engine_MaxAttempts(1)
		AssertTrue(Attempts is Integer && Attempts > 0)
		loop Attempts {
			AssertEqual(A_Index, State.Calls.Length,
				"Every actual retry must come from the engine's current attempt budget.")
			State.Calls[A_Index]["on_fail"].Call(Map("reason", "transport", "message", "controlled unavailable backend"))
		}
		if IsObject(State.Failure)
			throw State.Failure
		AssertEqual(1, State.FailedLines, "The genuine empty-result finalizer must cross its diagnostic boundary.")
	}
	if State.Mode != "current" {
		AssertTrue(State.Done && State.TimerCalls == 1 && State.BId != State.AId)
		AssertEqual(State.BId, _LLM_Engine["request_id"])
		AssertTrue(IsObject(State.BRecord) && State.BRecord.Lifecycle.OfferId == State.BId)
	}
	_TestPrint("# FAILED_PREDICTION_RECEIPT mode=" . State.Mode . " a=" . State.AId . " b=" . State.BId
		. " timer_calls=" . State.TimerCalls . " failed_lines=" . State.FailedLines
		. " visible=" . _Stub_LlmTooltipVisible . " loading=" . _Stub_LlmTooltipLoading
		. " presentation_present=" . IsObject(_Stub_LlmPresentedRecord))
	if State.Mode == "current" {
		AssertEqual(0, State.TimerCalls)
		AssertEqual(State.AId, _LLM_Engine["request_id"])
		AssertFalse(_Stub_LlmTooltipVisible, "The current failed request must dismiss its own loading presentation.")
		AssertFalse(IsObject(_Stub_LlmPresentedRecord))
	} else {
		AssertTrue(_Stub_LlmTooltipVisible, "A superseded failure cannot hide B's successful presentation.")
		AssertTrue(IsObject(_Stub_LlmPresentedRecord) && _Stub_LlmPresentedRecord == State.BRecord)
		AssertFalse(_Stub_LlmTooltipLoading)
		AssertEqual(State.BText, _Stub_LlmTooltipText)
		AssertEqual("une suite correcte", Trim(_Stub_LlmTooltipText))
	}
}

_LFO_Case(Mode) {
	global _LLM_Engine, _LLM_Menu, _LLM_Engine_RemoteTransport, _LLM_Live
	global _LLM_Remote_Async, _LLM_Remote_BackboardExchanges, _LLM_Ollama_Async
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_Pending, _LLM_Bridge_PrefixObserver
	global _Stub_LlmTooltipCalls, _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading
	global _Stub_LlmTooltipText, _Stub_LlmPresentedRecord, _Stub_LlmLogCalls
	global _Stub_LlmLogFailedCalls, _Stub_LlmSuggestedCalls
	global _LLM_ProfilesCache, _LLM_COMMON_INFERENCE, _LLM_COMMON_INFERENCE_RAW
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	Names := ["_LLM_Engine", "_LLM_Menu", "_LLM_Engine_RemoteTransport", "_LLM_Live",
		"_LLM_Remote_Async", "_LLM_Remote_BackboardExchanges", "_LLM_Ollama_Async",
		"_LLM_Ollama_ActiveStreams", "_LLM_Ollama_Pending", "_LLM_Bridge_PrefixObserver",
		"_Stub_LlmTooltipCalls", "_Stub_LlmTooltipVisible", "_Stub_LlmTooltipLoading",
		"_Stub_LlmTooltipText", "_Stub_LlmPresentedRecord", "_Stub_LlmLogCalls",
		"_Stub_LlmLogFailedCalls", "_Stub_LlmSuggestedCalls", "_LLM_ProfilesCache",
		"_LLM_COMMON_INFERENCE", "_LLM_COMMON_INFERENCE_RAW", "_LOGGER_TEST_SINK",
		"_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED",
		"_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
	PreviousCritical := Critical("On")
	Saved := Map(), SavedLogger := _TLOG_CaptureLoggerState()
	for Name in Names
		Saved[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	Store := _LLM_Engine_SlotDisplayStore()
	SavedCtx := Store.Ctx, SavedDisplays := Store.ByText
	State := {Mode: Mode, Calls: [], AId: 0, BId: 0, Timer: 0, TimerCalls: 0,
		Done: false, Failure: 0, FailedLines: 0, Armed: false, FloorMs: 0, BRecord: 0, BText: ""}
	Primary := 0, PrivateEngineOwned := false
	try {
		AssertFalse(SavedLogger.FlushActive, "A foreign logger flush cannot be detached by this fixture.")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_LOGGER_INFO_ENABLED := true, _LOGGER_WARN_ENABLED := true
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		_LLM_Remote_Async := Map(), _LLM_Remote_BackboardExchanges := Map(), _LLM_Ollama_Async := Map()
		_LLM_Ollama_ActiveStreams := [], _LLM_Ollama_Pending := "", _LLM_Bridge_PrefixObserver := 0
		_LLM_Live := Map("active", false, "profile_id", "", "num_predictions", 0)
		_LLM_Engine := _LPP_Engine(Saved["_LLM_Engine"].Value)
		PrivateEngineOwned := true
		_LLM_Engine["pending_timer"] := "", _LLM_Engine["timer_active"] := false
		_LLM_Menu := _LPP_Menu()
		_Stub_LlmTooltipCalls := [], _Stub_LlmTooltipVisible := false, _Stub_LlmTooltipLoading := false
		_Stub_LlmTooltipText := "", _Stub_LlmPresentedRecord := 0
		_Stub_LlmLogCalls := [], _Stub_LlmLogFailedCalls := [], _Stub_LlmSuggestedCalls := []
		_LLM_ProfilesCache := unset, _LLM_COMMON_INFERENCE := unset, _LLM_COMMON_INFERENCE_RAW := unset
		Store.Ctx := "", Store.ByText := Map()
		_LLM_Engine_RemoteTransport := _LFO_Transport.Bind(State)
		_LOGGER_TEST_SINK := _LFO_Log.Bind(State)
		Critical("Off")
		LLM_Engine_Init(Map("profile_id", "basic", "n_predictions", 1, "show_info_bar", false))
		_LFO_Exercise(State)
	} catch Any as Failure {
		Primary := Failure
	}
	try {
		State.Armed := false
		if IsObject(State.Timer)
			SetTimer(State.Timer, 0)
		if PrivateEngineOwned {
			LLM_Engine_StopGeneration()
			AssertFalse(_LLM_Engine["timer_active"])
			AssertEqual(0, _LLM_Remote_Async.Count)
			AssertEqual(0, _LLM_Ollama_Async.Count)
		}
	} catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	} finally {
		Critical("On")
		try {
			State.Timer := 0
			State.Calls := []
			State.BRecord := 0
			Store.Ctx := SavedCtx, Store.ByText := SavedDisplays
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Item in Saved
				%Name% := Item.Present ? Item.Value : unset
		} finally Critical(PreviousCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _LFO_Mode in ["current", "stale-entry", "logger-gap"]
	Test("LLM failed prediction: " . _LFO_Mode . " preserves the presentation owner (llm-failure-finalizer-owner)",
		_LFO_Case.Bind(_LFO_Mode))

; Append to test_llm_failed_prediction_owner.ahk. Real parser/engine remain unchanged.
_LSP_LastSlot() {
    global _Stub_LlmTooltipCalls
    AssertTrue(_Stub_LlmTooltipCalls.Length > 0)
    Call := _Stub_LlmTooltipCalls[_Stub_LlmTooltipCalls.Length]
    AssertTrue(Call.slots.Length == 1)
    return Call.slots[1]
}
_LSP_AdmitB(State) {
    global _LLM_Engine, _Stub_LlmPresentedRecord
    try {
        AssertFalse(A_IsCritical)
        State.TimerCalls += 1
        Before := State.Calls.Length
        LLM_Engine_FirePrediction("Je dis bonjou")
        AssertEqual(Before + 1, State.Calls.Length, "B must cross the genuine public network-dispatch boundary once")
        Call := State.Calls[State.Calls.Length]
        State.BId := Call["request_id"]
        AssertTrue(State.BId != State.AId && _LLM_Engine["request_id"] == State.BId)
        _LPP_Answer(Call, "TAIL_CORRECTED: Je dis bonjour`nNEXT_WORDS: tout le monde")
        State.BRoles := _LLS_Roles(_LSP_LastSlot())
        State.BText := _LLM_SlotGetText(_LSP_LastSlot())
        AssertEqual("r tout le monde", State.BText)
        AssertEqual("typed:bonjou|corrected:r|next: tout le monde", State.BRoles,
            "the affirmative current B must really publish the parser's three-piece projection")
        State.BRecord := _Stub_LlmPresentedRecord
        AssertTrue(IsObject(State.BRecord) && State.BRecord.IsFinal
            && State.BRecord.Lifecycle.OfferId == State.BId)
    } catch Any as Failure {
        State.Failure := Failure
    } finally State.Done := true
}
_LSP_Log(State, Line) {
    if !InStr(Line, "[WARNING] [LLM.parser] Prediction refused: model text exceeds the shared parser resource limits.")
        return
    State.FailedLines += 1
    if State.Mode != "parse-gap" || !State.Armed
        return
    State.Armed := false
    AssertFalse(A_IsCritical)
    SetTimer(State.Timer, -State.FloorMs)
    _LFO_WaitForB(State)
}
_LSP_ReplayB(State) {
    global _LLM_Engine, _Stub_LlmPresentedRecord
    try {
        State.ReplayCalls += 1
        Before := State.Calls.Length
        LLM_Engine_FirePrediction("Je dis bonjou")
        State.ReplayNetworkDelta := State.Calls.Length - Before
        State.ReplayId := _LLM_Engine["request_id"]
        State.ReplayRoles := _LLS_Roles(_LSP_LastSlot())
        State.ReplayText := _LLM_SlotGetText(_LSP_LastSlot())
        State.ReplayRecord := _Stub_LlmPresentedRecord
    } catch Any as Failure {
        State.Failure := Failure
    } finally State.Replayed := true
}
_LSP_Exercise(State) {
    global _LLM_Engine, _SharedDir
    State.FloorMs := _LLM_Engine["min_request_interval_ms"] + 1
    AssertTrue(State.FloorMs is Integer && State.FloorMs > 1 && State.FloorMs < 3000)
    State.Timer := _LSP_AdmitB.Bind(State)
    State.ReplayTimer := _LSP_ReplayB.Bind(State)
    State.Replayed := false, State.ReplayCalls := 0
    State.BRoles := "", State.ReplayRoles := "", State.ReplayText := "", State.ReplayId := 0
    State.ReplayNetworkDelta := -1, State.ReplayRecord := 0
    Limits := JsonParse(FSReadUtf8Exact(_SharedDir . "\modules\llm\parser_limits.json"))
    Huge := ""
    Loop Limits["max_operand_bytes"] + 1
        Huge .= "x"
    RawA := "TAIL_CORRECTED: " . Huge . "`nNEXT_WORDS: refused"
    LLM_Engine_FirePrediction("Le premier message")
    AssertEqual(1, State.Calls.Length)
    State.AId := State.Calls[1]["request_id"]
    if State.Mode == "stale-entry" {
        SetTimer(State.Timer, -State.FloorMs)
        _LFO_WaitForB(State)
    } else {
        AssertEqual("parse-gap", State.Mode)
        State.Armed := true
    }
    _LPP_Answer(State.Calls[1], RawA)
    if IsObject(State.Failure)
        throw State.Failure
    AssertTrue(State.Done && State.TimerCalls == 1)
    AssertEqual(State.Mode == "parse-gap" ? 1 : 0, State.FailedLines,
        "only the mid-parser case crosses the real refusal diagnostic; the stale-entry control is rejected before parsing")
    AssertEqual(State.BId, _LLM_Engine["request_id"], "the stale callback cannot take B's request identity")
    AssertEqual("Je dis bonjou", _LLM_Engine["last_ctx"], "the current cache must still belong to B")
    SetTimer(State.ReplayTimer, -State.FloorMs)
    Started := A_TickCount
    while !State.Replayed && TickElapsed(Started) < 3000
        Sleep(10)
    if IsObject(State.Failure)
        throw State.Failure
    Store := _LLM_Engine_SlotDisplayStore()
    _TestPrint("# SLOT_DISPLAY_STALE_PARSER " . KL_JsonEncode(Map("mode", State.Mode,
        "a_id", State.AId, "b_id", State.BId, "timer_calls", State.TimerCalls,
        "parser_refusals", State.FailedLines, "replay_calls", State.ReplayCalls,
        "replay_network_delta", State.ReplayNetworkDelta, "replay_id", State.ReplayId,
        "initial_roles", State.BRoles, "replay_roles", State.ReplayRoles,
        "initial_text", State.BText, "replay_text", State.ReplayText, "display_store_context", Store.Ctx)))
    AssertTrue(State.Replayed && State.ReplayCalls == 1)
    AssertEqual(0, State.ReplayNetworkDelta, "the public replay must use B's genuine exact-result cache")
    AssertTrue(State.ReplayId != State.BId && IsObject(State.ReplayRecord)
        && State.ReplayRecord.Lifecycle.OfferId == State.ReplayId && State.ReplayRecord.IsFinal)
    AssertEqual(State.BText, State.ReplayText, "the cached physical injection text stays unchanged")
    AssertEqual(State.BRoles, State.ReplayRoles, "a superseded parser cannot erase the current result's typed/corrected/next projection")
}
_LSP_Case(Mode) {
	global _LLM_Engine, _LLM_Menu, _LLM_Engine_RemoteTransport, _LLM_Live
	global _LLM_Remote_Async, _LLM_Remote_BackboardExchanges, _LLM_Ollama_Async
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_Pending, _LLM_Bridge_PrefixObserver
	global _Stub_LlmTooltipCalls, _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading
	global _Stub_LlmTooltipText, _Stub_LlmPresentedRecord, _Stub_LlmLogCalls
	global _Stub_LlmLogFailedCalls, _Stub_LlmSuggestedCalls
	global _LLM_ProfilesCache, _LLM_COMMON_INFERENCE, _LLM_COMMON_INFERENCE_RAW
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	Names := ["_LLM_Engine", "_LLM_Menu", "_LLM_Engine_RemoteTransport", "_LLM_Live",
		"_LLM_Remote_Async", "_LLM_Remote_BackboardExchanges", "_LLM_Ollama_Async",
		"_LLM_Ollama_ActiveStreams", "_LLM_Ollama_Pending", "_LLM_Bridge_PrefixObserver",
		"_Stub_LlmTooltipCalls", "_Stub_LlmTooltipVisible", "_Stub_LlmTooltipLoading",
		"_Stub_LlmTooltipText", "_Stub_LlmPresentedRecord", "_Stub_LlmLogCalls",
		"_Stub_LlmLogFailedCalls", "_Stub_LlmSuggestedCalls", "_LLM_ProfilesCache",
		"_LLM_COMMON_INFERENCE", "_LLM_COMMON_INFERENCE_RAW", "_LOGGER_TEST_SINK",
		"_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED",
		"_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
	PreviousCritical := Critical("On")
	Saved := Map(), SavedLogger := _TLOG_CaptureLoggerState()
	for Name in Names
		Saved[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	Store := _LLM_Engine_SlotDisplayStore()
	SavedCtx := Store.Ctx, SavedDisplays := Store.ByText
	State := {Mode: Mode, Calls: [], AId: 0, BId: 0, Timer: 0, TimerCalls: 0,
		Done: false, Failure: 0, FailedLines: 0, Armed: false, FloorMs: 0, BRecord: 0, BText: ""}
	Primary := 0, PrivateEngineOwned := false
	try {
		AssertFalse(SavedLogger.FlushActive, "A foreign logger flush cannot be detached by this fixture.")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_LOGGER_INFO_ENABLED := true, _LOGGER_WARN_ENABLED := true
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		_LLM_Remote_Async := Map(), _LLM_Remote_BackboardExchanges := Map(), _LLM_Ollama_Async := Map()
		_LLM_Ollama_ActiveStreams := [], _LLM_Ollama_Pending := "", _LLM_Bridge_PrefixObserver := 0
		_LLM_Live := Map("active", false, "profile_id", "", "num_predictions", 0)
		_LLM_Engine := _LPP_Engine(Saved["_LLM_Engine"].Value)
		PrivateEngineOwned := true
		_LLM_Engine["pending_timer"] := "", _LLM_Engine["timer_active"] := false
		_LLM_Menu := _LPP_Menu()
		_Stub_LlmTooltipCalls := [], _Stub_LlmTooltipVisible := false, _Stub_LlmTooltipLoading := false
		_Stub_LlmTooltipText := "", _Stub_LlmPresentedRecord := 0
		_Stub_LlmLogCalls := [], _Stub_LlmLogFailedCalls := [], _Stub_LlmSuggestedCalls := []
		_LLM_ProfilesCache := unset, _LLM_COMMON_INFERENCE := unset, _LLM_COMMON_INFERENCE_RAW := unset
		Store.Ctx := "", Store.ByText := Map()
		_LLM_Engine_RemoteTransport := _LFO_Transport.Bind(State)
		_LOGGER_TEST_SINK := _LSP_Log.Bind(State)
		Critical("Off")
		LLM_Engine_Init(Map("profile_id", "basic", "n_predictions", 1, "show_info_bar", false))
		_LSP_Exercise(State)
	} catch Any as Failure {
		Primary := Failure
	}
	try {
		State.Armed := false
		if IsObject(State.Timer)
			SetTimer(State.Timer, 0)
		if State.HasOwnProp("ReplayTimer") && IsObject(State.ReplayTimer)
			SetTimer(State.ReplayTimer, 0)
		if PrivateEngineOwned {
			LLM_Engine_StopGeneration()
			AssertFalse(_LLM_Engine["timer_active"])
			AssertEqual(0, _LLM_Remote_Async.Count)
			AssertEqual(0, _LLM_Ollama_Async.Count)
		}
	} catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	} finally {
		Critical("On")
		try {
			State.Timer := 0
			State.Calls := []
			State.BRecord := 0
			Store.Ctx := SavedCtx, Store.ByText := SavedDisplays
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Item in Saved
				%Name% := Item.Present ? Item.Value : unset
		} finally Critical(PreviousCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _LSP_Mode in ["stale-entry", "parse-gap"]
    Test("LLM slot display: " . _LSP_Mode . " preserves the current cached projection (llm-slot-display-stale-parser)",
        _LSP_Case.Bind(_LSP_Mode))


; Append to test_llm_failed_prediction_owner.ahk. Family066 downstream variant coverage.
_RUAG_Exercise(State) {
    global LLM_REMOTE_MODEL_PRICES, _Stub_LlmLogCalls, _Stub_LlmPresentedRecord, _LLM_Engine
    Count := (State.Mode == "ordinary-two" || State.Mode == "cost-two") ? 2 : 3
    Price := (State.Mode == "cost-two" || State.Mode == "cost-three") ? 1e308 : (State.Mode == "ordinary-two" ? 2.0 : 0.0)
    LLM_REMOTE_MODEL_PRICES := _LLMRemoteAdmitPrices(Map("model-a", Map("in", Price, "out", 0.0)))
    AssertTrue(LLM_REMOTE_MODEL_PRICES.Has("model-a"), "the genuine price boundary admits this finite nonnegative price")
    PerPrompt := (State.Mode == "integer-three" || State.Mode == "integer-three-independent") ? 0x7FFFFFFFFFFFFFFF
        : ((State.Mode == "cost-two" || State.Mode == "cost-three") ? 1000000 : 2)
    PerCompletion := State.Mode == "ordinary-two" ? 1 : (State.Mode == "integer-three-independent" ? 2 : 0)
    PerTotal := State.Mode == "integer-three-independent" ? 0x7FFFFFFFFFFFFFFF : PerPrompt + PerCompletion
    PerResponse := [], Contents := ["premiere variante correcte", "deuxieme variante correcte", "troisieme variante correcte"]
    LLM_Engine_FirePrediction("Le message du controle")
    AssertEqual(1, State.Calls.Length, "the actual public request must dispatch its first sequential variant")
    RequestId := State.Calls[1]["request_id"]
    loop Count {
        Index := A_Index
        AssertEqual(Index, State.Calls.Length, "every later dispatch must be produced by the real preceding engine success")
        Call := State.Calls[Index]
        AssertEqual(RequestId, Call["request_id"], "all sequential responses belong to one real prediction request")
        Body := '{"choices":[{"message":{"role":"assistant","content":' . JsonStringLiteral(Contents[Index])
            . '}}],"usage":{"prompt_tokens":' . PerPrompt . ',"completion_tokens":' . PerCompletion . ',"total_tokens":' . PerTotal . '}}'
        Classified := _LLMRemoteClassifyResponse("openai", Body, "model-a")
        AssertTrue(Classified["ok"])
        Usage := Classified["usage"]
        AssertTrue(Usage["prompt_tokens"] is Integer && Usage["prompt_tokens"] >= 0)
        AssertTrue(Usage["completion_tokens"] is Integer && Usage["completion_tokens"] >= 0)
        AssertTrue(Usage["total_tokens"] is Integer && Usage["total_tokens"] >= 0)
        AssertTrue(_LLMRemote_CatalogPriceIsValid(Usage["est_cost_usd"]), "every response independently obeys the already fixed native usage/cost domain")
        PerResponse.Push(Map("prompt", String(Usage["prompt_tokens"]), "completion", String(Usage["completion_tokens"]),
            "total", String(Usage["total_tokens"]), "cost", String(Usage["est_cost_usd"])))
        Call["on_success"].Call(Classified["text"], Usage)
    }
    AssertEqual(Count, State.Calls.Length, "distinct valid predictions must finalize without an invented extra attempt")
    Events := []
    for Log in _Stub_LlmLogCalls {
        if Log.event_type == "generation"
            Events.Push(Log.evt)
    }
    AssertEqual(1, Events.Length, "the final public keystats consumer must receive one aggregate generation event")
    Event := Events[1]
    Prompt := Event.Get("prompt_tokens", 0), Completion := Event.Get("completion_tokens", 0)
    Total := Event.Get("total_tokens", 0), Cost := Event.Get("est_cost_usd", 0.0)
    _TestPrint("# REQUEST_USAGE_AGGREGATE " . KL_JsonEncode(Map("mode", State.Mode, "request_id", RequestId,
        "responses", PerResponse, "dispatches", State.Calls.Length, "generation_events", Events.Length,
        "aggregate_prompt", String(Prompt), "aggregate_completion", String(Completion), "aggregate_total", String(Total),
        "aggregate_cost", String(Cost), "aggregate_cost_finite", _LLMRemote_CatalogPriceIsValid(Cost),
        "prediction_count", Event["predictions"].Length, "presentation_final", IsObject(_Stub_LlmPresentedRecord) && _Stub_LlmPresentedRecord.IsFinal)))
    AssertEqual(Count, Event["predictions"].Length, "billing refusal must not lose the actual successful predictions")
    AssertTrue(IsObject(_Stub_LlmPresentedRecord) && _Stub_LlmPresentedRecord.IsFinal
        && _Stub_LlmPresentedRecord.Lifecycle.OfferId == RequestId)
    if State.Mode == "ordinary-two" {
        AssertEqual(4, Prompt), AssertEqual(2, Completion), AssertEqual(6, Total)
        AssertTrue(Abs(Cost - 0.000008) < 1e-12, "ordinary per-response costs must accumulate unchanged")
    } else if State.Mode == "integer-three" || State.Mode == "integer-three-independent" {
        AssertEqual(0, Prompt, "an unrepresentable full-request count stays unknown, not a positive wrapped partial total")
        AssertEqual(0, Total)
        AssertEqual(State.Mode == "integer-three-independent" ? 6 : 0, Completion, "one unknown counter cannot erase an independently representable completion count")
    } else {
        AssertTrue(State.Mode == "cost-two" || State.Mode == "cost-three")
        AssertEqual(Count * 1000000, Prompt), AssertEqual(Count * 1000000, Total)
        AssertTrue(_LLMRemote_CatalogPriceIsValid(Cost), "the final consumer cannot receive infinity from individually admitted prices and usages")
        AssertEqual(0.0, Cost, "the existing unrepresentable cost policy is unknown zero, never infinity or a fabricated finite ceiling")
    }
}
_RUAG_Case(Mode) {
	global _LLM_Engine, _LLM_Menu, _LLM_Engine_RemoteTransport, _LLM_Live, LLM_REMOTE_MODEL_PRICES
	global _LLM_Remote_Async, _LLM_Remote_BackboardExchanges, _LLM_Ollama_Async
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_Pending, _LLM_Bridge_PrefixObserver
	global _Stub_LlmTooltipCalls, _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading
	global _Stub_LlmTooltipText, _Stub_LlmPresentedRecord, _Stub_LlmLogCalls
	global _Stub_LlmLogFailedCalls, _Stub_LlmSuggestedCalls
	global _LLM_ProfilesCache, _LLM_COMMON_INFERENCE, _LLM_COMMON_INFERENCE_RAW
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	Names := ["LLM_REMOTE_MODEL_PRICES", "_LLM_Engine", "_LLM_Menu", "_LLM_Engine_RemoteTransport", "_LLM_Live",
		"_LLM_Remote_Async", "_LLM_Remote_BackboardExchanges", "_LLM_Ollama_Async",
		"_LLM_Ollama_ActiveStreams", "_LLM_Ollama_Pending", "_LLM_Bridge_PrefixObserver",
		"_Stub_LlmTooltipCalls", "_Stub_LlmTooltipVisible", "_Stub_LlmTooltipLoading",
		"_Stub_LlmTooltipText", "_Stub_LlmPresentedRecord", "_Stub_LlmLogCalls",
		"_Stub_LlmLogFailedCalls", "_Stub_LlmSuggestedCalls", "_LLM_ProfilesCache",
		"_LLM_COMMON_INFERENCE", "_LLM_COMMON_INFERENCE_RAW", "_LOGGER_TEST_SINK",
		"_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED",
		"_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
	PreviousCritical := Critical("On")
	Saved := Map(), SavedLogger := _TLOG_CaptureLoggerState()
	for Name in Names
		Saved[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	Store := _LLM_Engine_SlotDisplayStore()
	SavedCtx := Store.Ctx, SavedDisplays := Store.ByText
	State := {Mode: Mode, Calls: [], AId: 0, BId: 0, Timer: 0, TimerCalls: 0,
		Done: false, Failure: 0, FailedLines: 0, Armed: false, FloorMs: 0, BRecord: 0, BText: ""}
	Primary := 0, PrivateEngineOwned := false
	try {
		AssertFalse(SavedLogger.FlushActive, "A foreign logger flush cannot be detached by this fixture.")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_LOGGER_INFO_ENABLED := true, _LOGGER_WARN_ENABLED := true
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		_LLM_Remote_Async := Map(), _LLM_Remote_BackboardExchanges := Map(), _LLM_Ollama_Async := Map()
		_LLM_Ollama_ActiveStreams := [], _LLM_Ollama_Pending := "", _LLM_Bridge_PrefixObserver := 0
		_LLM_Live := Map("active", false, "profile_id", "", "num_predictions", 0)
		_LLM_Engine := _LPP_Engine(Saved["_LLM_Engine"].Value)
		PrivateEngineOwned := true
		_LLM_Engine["pending_timer"] := "", _LLM_Engine["timer_active"] := false
		_LLM_Menu := _LPP_Menu()
		_Stub_LlmTooltipCalls := [], _Stub_LlmTooltipVisible := false, _Stub_LlmTooltipLoading := false
		_Stub_LlmTooltipText := "", _Stub_LlmPresentedRecord := 0
		_Stub_LlmLogCalls := [], _Stub_LlmLogFailedCalls := [], _Stub_LlmSuggestedCalls := []
		_LLM_ProfilesCache := unset, _LLM_COMMON_INFERENCE := unset, _LLM_COMMON_INFERENCE_RAW := unset
		Store.Ctx := "", Store.ByText := Map()
		_LLM_Engine_RemoteTransport := _LFO_Transport.Bind(State)
		_LOGGER_TEST_SINK := 0
		Critical("Off")
		LLM_Engine_Init(Map("profile_id", "basic", "n_predictions", (Mode == "ordinary-two" || Mode == "cost-two") ? 2 : 3, "show_info_bar", false))
		_RUAG_Exercise(State)
	} catch Any as Failure {
		Primary := Failure
	}
	try {
		State.Armed := false
		if IsObject(State.Timer)
			SetTimer(State.Timer, 0)
		if PrivateEngineOwned {
			LLM_Engine_StopGeneration()
			AssertFalse(_LLM_Engine["timer_active"])
			AssertEqual(0, _LLM_Remote_Async.Count)
			AssertEqual(0, _LLM_Ollama_Async.Count)
		}
	} catch Any as Failure {
		if !IsObject(Primary)
			Primary := Failure
	} finally {
		Critical("On")
		try {
			State.Timer := 0
			State.Calls := []
			State.BRecord := 0
			Store.Ctx := SavedCtx, Store.ByText := SavedDisplays
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Item in Saved
				%Name% := Item.Present ? Item.Value : unset
		} finally Critical(PreviousCritical)
	}
	if IsObject(Primary)
		throw Primary
}

for _RUAG_Mode in ["ordinary-two", "cost-two", "integer-three", "cost-three", "integer-three-independent"]
    Test("Request usage aggregate: " . _RUAG_Mode . " preserves the final consumer domain (request-usage-aggregate-domain)",
        _RUAG_Case.Bind(_RUAG_Mode))

; Actual native fallback InputHook -> Bridge -> OnKeystroke -> native timer ->
; FirePrediction -> genuine managed HTTP. No provider service or fake subject.
global _LDP_Debt := []
; Whether the real engine armed after a baseline, as an event, not a sampled
; window: the debounce timer is active only between the arm and its fire, so a
; busy runner can miss it. A fresh pending token, a fire (request id) or the
; remote reservation that fire made is monotonic proof of the arm.
_LDP_ArmedSince(ArmToken, RequestId, Counter) {
    global _LLM_Engine, _LLM_Remote_AsyncCounter
    Pending := _LLM_Engine_Plan().Pending
    return (_LLM_Engine["timer_active"] && IsObject(Pending) && Pending["token"] != ArmToken)
        || _LLM_Engine.Get("request_id", 0) > RequestId || _LLM_Remote_AsyncCounter > Counter
}

; Wait for the native producer and the real deferred prefix owner to finish a
; burst, and, when the burst is admitted, for its arm event. The deadline only
; bounds that event; it is never a measured duration.
_LDP_AwaitBurst(State, Expected, MustArm, ArmToken, RequestId, Counter) {
    global _LLM_Bridge_PrefixObserver
    Started := A_TickCount
    while (State.InputChars != Expected || State.InputCompleted != State.InputCallbacks
            || IsObject(_LLM_Bridge_PrefixObserver) || (MustArm && !_LDP_ArmedSince(ArmToken, RequestId, Counter)))
            && TickElapsed64(Started) < 2000
        Sleep(5)
    if IsObject(State.Failure)
        throw State.Failure
    if MustArm && !_LDP_ArmedSince(ArmToken, RequestId, Counter)
        _TestPrint("# LLM_DEBOUNCE_PRIVACY_TRACE " . KL_JsonEncode(Map("now", _LDP_PrivacyTraceState(),
            "completed", State.InputCompleted, "callbacks", State.InputCallbacks, "trace", State.PrivacyTrace)))
}

_LDP_PrivacyTraceState() {
    global _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration, _LLM_Bridge_BufferSource
    global _LLM_Bridge_ReadLiveFocus, _LLM_Engine, SFD_FIELD_CACHE, _PrefixDeferredGeneration
    global _LLM_Bridge_PrefixObserver, _LLM_Remote_AsyncCounter
    Source := _LLM_Bridge_BufferSource
    Pending := _LLM_Engine_Plan().Pending
    return Map("buffer_units", StrLen(_LLM_Bridge_Buffer), "engine_units", StrLen(_LLM_Engine.Get("last_buffer", "")),
        "timer_active", _LLM_Engine.Get("timer_active", false) ? 1 : 0,
        "pending_token", IsObject(Pending) ? Pending["token"] : 0,
        "request_id", _LLM_Engine.Get("request_id", 0), "async_counter", _LLM_Remote_AsyncCounter,
        "observer_pending", IsObject(_LLM_Bridge_PrefixObserver) ? 1 : 0,
        "content_generation", _LLM_Bridge_ContentGeneration, "lifecycle", _PrefixDeferredGeneration,
        "source_hwnd", Source is Map ? Source.Get("hwnd", 0) : 0,
        "source_control", Source is Map ? Source.Get("control", 0) : 0,
        "source_focus_generation", Source is Map ? Source.Get("input_focus_generation", -1) : -1,
        "source_element_matches", Source is Map ? Source.Get("input_element_id", "") == SFD_FIELD_CACHE["current_element_id"] : -1,
        "cache_hwnd", SFD_FIELD_CACHE["hwnd"], "cache_generation", SFD_FIELD_CACHE["focus_generation"],
        "cache_secure", SFD_FIELD_CACHE["secure"], "cache_tracking", SFD_FIELD_CACHE["focus_tracking_active"],
        "cache_at", SFD_FIELD_CACHE["at"], "focus_reader", ObjPtr(_LLM_Bridge_ReadLiveFocus))
}
_LDP_Char(State, IH, Char) {
    if !State.InputActive
        return
    try {
        State.InputChars .= Char
        State.InputCallbacks += 1
        AssertEqual(State.TypedHwnd, WIGetForegroundHwnd())
        AssertEqual(State.TypedControl, WIGetFocusedControlToken())
        EntryOrder := State.InputCallbacks, EntryUnits := StrLen(State.InputChars)
        Before := _LDP_PrivacyTraceState()
        if State.HasOwnProp("StylePrefix") && State.StylePrefix {
            MirrorCritical := Critical("On")
            try {
                NativePassword := !!(WinGetStyle("ahk_id " . State.TypedControl) & 0x20)
                State.StylePasswordCallbacks += NativePassword ? 1 : 0
                State.StyleMaxInputAge := Max(State.StyleMaxInputAge, TickElapsed64(State.StyleOriginAt))
                if State.InputCallbacks == 1 {
                    global SFD_FIELD_CACHE
                    State.StyleFirstNegative := SFD_FIELD_CACHE["hwnd"] == State.TypedControl
                        && !SFD_FIELD_CACHE["secure"]
                        && SFD_FIELD_CACHE["focus_generation"] == State.StyleOriginGeneration
                        && SFD_FIELD_CACHE["current_element_id"] == State.StyleOriginElement
                }
                global _LLM_Bridge_Buffer
                UnitsBefore := StrLen(_LLM_Bridge_Buffer)
                LLM_Bridge_FeedCharForPrefix(Char)
                if NativePassword
                    State.StylePrivateMirroredUnits += Max(0, StrLen(_LLM_Bridge_Buffer) - UnitsBefore)
            } finally Critical(MirrorCritical)
        } else
            _LLM_Bridge_OnDispatcherChar(IH, Char)
        After := _LDP_PrivacyTraceState()
        State.InputCompleted += 1
        State.PrivacyTrace.Push(Map("entry", EntryOrder, "completion", State.InputCompleted,
            "entry_units", EntryUnits, "completed_at_units", StrLen(State.InputChars), "chunk_units", StrLen(Char),
            "before", Before, "after", After))
    } catch Any as Err {
        State.Failure := Err
    }
}
_LDP_Down(State, IH, VK, SC) {
    if !State.InputActive
        return
    try {
        State.InputDowns += 1
        _LLM_Bridge_OnDispatcherKey(IH, VK, SC)
    } catch Any as Err {
        State.Failure := Err
    }
}
_LDP_Join(State, Role) {
    Owner := Role == "peer" ? State.Peer : State.App
    Stop := Role == "peer" ? State.PeerStop : State.AppStop
    if !(Owner is Map) || Owner.Get("released", false)
        return
    AssertTrue(State.DirectoryOwned)
    AssertTrue(FSWrite(Stop, "owned stop"))
    Started := A_TickCount
    while !_LLM_CurlProcessExited(Owner) && TickElapsed64(Started) < 5000
        Sleep(10)
    AssertTrue(_LLM_CurlProcessExited(Owner), Role . " must acknowledge its private stop")
    ExitCode := -1, Diagnostic := ""
    AssertTrue(_SR_TreeReadExitCode(Owner["handle"], &ExitCode, &Diagnostic))
    AssertEqual(0, ExitCode, Role . " must acknowledge a normal native exit")
    AssertTrue(_LLM_CurlReleaseProcess(Owner))
}
_LDP_Cleanup(State) {
    global _LLM_Engine, _LLM_Bridge_Active, _LLM_Remote_Async, SFD_FIELD_CACHE
    Errors := []
    State.InputActive := false
    try {
        if IsObject(State.Hook)
            State.Hook.Stop()
        AssertTrue(!IsObject(State.Hook) || !State.Hook.InProgress)
    } catch Any as Err
        Errors.Push(Err)
    try {
        if State.Engine is Map && _LLM_Engine == State.Engine {
            for Id, Entry in _LLM_Remote_Async {
                Http := Entry.Get("http", 0)
                AssertTrue(IsObject(Http) && Http.Url == State.Endpoint,
                    "a private engine scope cannot adopt a foreign endpoint for cleanup")
                State.OwnEntries[Id] := Entry
            }
            _LLM_Bridge_Active := false
            LLM_Engine_StopGeneration()
        } else if State.Engine is Map {
            Pending := State.Engine.Get("pending_timer", 0)
            if HasMethod(Pending, "Call")
                SetTimer(Pending, 0)
            if State.Engine.Get("request_plan", 0) is LLMRequestPlan
                State.Engine["request_plan"].OnCancel()
            State.Engine["pending_timer"] := "", State.Engine["timer_active"] := false
        }
        if State.Entry is Map
            State.OwnEntries[State.Id] := State.Entry
        for Id, Entry in State.OwnEntries {
            if _LLM_Remote_Async.Get(Id, 0) == Entry {
                LLM_RemoteCancelAsync(Id)
                _LLMRemote_PollRequest(Id)
            }
            Http := Entry.Get("http", 0)
            if IsObject(Http)
                AssertTrue(Http.Abort(), "each exact native request must acknowledge retirement")
            AssertFalse(_LLM_Remote_Async.Get(Id, 0) == Entry)
        }
        AssertFalse(State.Engine["timer_active"])
    } catch Any as Err
        Errors.Push(Err)
    try {
        if State.SfdOwned {
            AssertTrue(SFD_FIELD_CACHE == State.SfdCache, "only the exact private detector cache can be retired")
            AssertTrue(SFD_Stop(), "the private detector must acknowledge native hook retirement")
            AssertTrue(SFD_FIELD_CACHE == State.SfdCache)
            AssertEqual(0, SFD_FIELD_CACHE.Get("pending_hwnd", 0), "native Edit classification must not strand a UIA probe")
            SFD_FIELD_CACHE := State.SfdPrevious
            State.SfdOwned := false
        }
    } catch Any as Err
        Errors.Push(Err)
    for Role in ["peer", "app"] {
        try _LDP_Join(State, Role)
        catch Any as Err
            Errors.Push(Err)
    }
    try {
        if IsObject(State.GuiA) {
            State.GuiA.Destroy()
            State.GuiA := 0
        }
    } catch Any as Err
        Errors.Push(Err)
    try {
        if Errors.Length == 0 && State.DirectoryOwned && DirExist(State.Directory)
            DirDelete(State.Directory, true)
    } catch Any as Err
        Errors.Push(Err)
    if Errors.Length {
        for Err in Errors
            _TestPrint("# LLM_DEBOUNCE_SOURCE_CLEANUP " . KL_JsonEncode(Map("error", Type(Err), "message", Err.Message)))
        throw Errors[1]
    }
}
_LDP_DrainDebt() {
    global _LDP_Debt
    Remaining := []
    for State in _LDP_Debt {
        try _LDP_Cleanup(State)
        catch Any as Err
            Remaining.Push(State)
    }
    _LDP_Debt := Remaining
    AssertEqual(0, Remaining.Length, "new cases cannot hide exact native retirement debt")
}
_LDP_Native(Mode, Calls, Lines) {
    global _DriverDir, _LLM_Engine, _LLM_Menu, _LLM_Engine_RemoteTransport
    global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration
    global _LLM_Bridge_AgentBuffer, _LLM_Bridge_LastLogTick, _LLM_Bridge_PrefixObserver
    global _LLM_Agent_Generation, _LLM_Agent_Auto, _PrefixInputHook, HSE_Buffer, _PrefixBuffer
    global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, _LDP_Debt, _LLM_Live
    global _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading, _Stub_LlmTooltipText, _Stub_LlmPresentedRecord
    global SFD_FIELD_CACHE
    global _LLM_Bridge_BufferSource, _LLM_Bridge_AgentBufferSource, _LLM_Bridge_AgentContentGeneration
    global _LLM_Bridge_BufferAgentSafe, _LLM_Bridge_PrivacyAppCache
    global _AHK_DRY_RUN, SFD_FIELD_CACHE_TTL_MS
    StyleProbe := Mode == "style-password-prefix" || Mode == "style-plain-prefix"
    Retyped := Mode == "excluded-switches-typed" || Mode == "password-switches-typed"
    PasswordProbe := StyleProbe || Mode == "password-stays" || Mode == "password-switches" || Mode == "plain-stays" || Mode == "password-switches-typed"
    SecretOrigin := PasswordProbe && Mode != "plain-stays" && !StyleProbe
    AllowedOrigin := Mode == "allowed-stays" || Mode == "plain-stays" || Mode == "style-plain-prefix"
    Switches := Mode == "excluded-switches" || Mode == "password-switches" || Retyped
    AssertFalse(A_IsCritical)
    AssertFalse(A_IsSuspended)
    AssertEqual(0, _LLM_Remote_Async.Count)
    AssertFalse(_LLM_Bridge_Active, "do not borrow an active bridge")
    AssertFalse(IsObject(_LLM_Bridge_PrefixObserver), "do not replace an armed prefix observer")
    AssertFalse(_LLM_Agent_Auto is Map && HasMethod(_LLM_Agent_Auto.Get("timer", 0), "Call"),
        "do not replace a foreign automatic-agent pause")
    AssertFalse(IsObject(_PrefixInputHook), "do not replace a live prefix watcher")
    OldHook := HookDispatcher._ih
    AssertTrue(!IsObject(OldHook) || !OldHook.InProgress, "do not borrow a foreign native dispatcher hook")
    Saved := {Active: _LLM_Bridge_Active, Buffer: _LLM_Bridge_Buffer,
        Content: _LLM_Bridge_ContentGeneration, AgentBuffer: _LLM_Bridge_AgentBuffer,
        LogTick: _LLM_Bridge_LastLogTick, Observer: _LLM_Bridge_PrefixObserver,
        AgentGeneration: _LLM_Agent_Generation, AgentAuto: _LLM_Agent_Auto,
        Hse: HSE_Buffer, Prefix: _PrefixBuffer, Live: _LLM_Live,
        BufferSource: _LLM_Bridge_BufferSource, AgentSource: _LLM_Bridge_AgentBufferSource,
        AgentContent: _LLM_Bridge_AgentContentGeneration, AgentSafe: _LLM_Bridge_BufferAgentSafe,
        PrivacyCache: _LLM_Bridge_PrivacyAppCache}
    State := {Directory: "", DirectoryOwned: false, Peer: 0, PeerStop: "", App: 0, AppStop: "",
        GuiA: 0, Hook: 0, InputActive: false, InputChars: "", InputCallbacks: 0, InputDowns: 0,
        TypedHwnd: 0, TypedControl: 0, Failure: 0, Id: 0, Entry: 0, Engine: _LLM_Engine,
        Endpoint: "", OwnEntries: Map(), PrivacyTrace: [], InputCompleted: 0, SfdOwned: false, SfdPrevious: 0, SfdCache: 0, SecureSource: -1, SecureFocus: -1}
    State.StylePrefix := StyleProbe
    State.StylePrivateMirroredUnits := 0, State.StylePasswordCallbacks := 0
    State.StyleMaxInputAge := 0, State.StyleFirstNegative := false
    Primary := 0
    try {
        AssertFalse(SFD_FIELD_CACHE.Get("focus_tracking_active", false), "do not borrow a live native secure-field observer")
        AssertEqual(0, SFD_FIELD_CACHE.Get("focus_hook", 0))
        AssertEqual(0, SFD_FIELD_CACHE.Get("focus_callback", 0))
        AssertEqual(0, SFD_FIELD_CACHE.Get("pending_hwnd", 0), "do not borrow a pending UIA classification")
        State.SfdPrevious := SFD_FIELD_CACHE
        State.SfdCache := SFD_FIELD_CACHE.Clone()
        SFD_FIELD_CACHE := State.SfdCache
        State.SfdOwned := true
        SFD_Refresh()
        State.Directory := A_Temp . "\ergopti_llm_source_" . A_TickCount . "_" . Random(1, 1000000)
        Ack := FSCreateDirectoryExclusiveStrict(State.Directory)
        AssertTrue(Ack is Integer && Ack == 1)
        State.DirectoryOwned := true
        Nonce := String(A_TickCount) . "_" . Random(1, 1000000)
        PeerReady := State.Directory . "\peer.txt", Receipt := State.Directory . "\http.jsonl"
        AppReady := State.Directory . "\app.txt"
        State.PeerStop := State.Directory . "\peer.stop", State.AppStop := State.Directory . "\app.stop"
        Runtime := State.Directory . "\ergopti_allowed_" . Nonce . ".exe"
        FileCopy(A_AhkPath, Runtime, false)
        AssertEqual(CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath)), CryptoSha256Bytes(FSReadBytesStrict(Runtime)))
        AppScript := _DriverDir . "\tests\fixtures\llm_debounce_privacy_app.ahk"
        PeerScript := _DriverDir . "\tests\fixtures\llm_debounce_privacy_peer.ahk"
        AssertTrue(FileExist(AppScript) && FileExist(PeerScript))
        Pid := 0
        _LLM_CurlArtifactRun(_SR_BuildDirectCommandLine(Runtime, ["/ErrorStdOut", AppScript, AppReady, State.AppStop, Nonce]),
            State.Directory, "", &Pid, &AppOwner)
        State.App := AppOwner
        AppPid := Pid
        _LLM_CurlArtifactRun(_SR_BuildDirectCommandLine(A_AhkPath,
            ["/ErrorStdOut", PeerScript, PeerReady, Receipt, "200", "done", State.PeerStop]),
            State.Directory, "Hide", &Pid, &PeerOwner)
        State.Peer := PeerOwner
        Started := A_TickCount
        while (!FileExist(AppReady) || !FileExist(PeerReady)) && TickElapsed64(Started) < 5000
            Sleep(10)
        AssertTrue(FileExist(AppReady) && FileExist(PeerReady))
        AppRecord := FileRead(AppReady, "UTF-8-RAW")
        AssertTrue(RegExMatch(AppRecord, "^([0-9]+)\|([0-9]+)\|([0-9]+)\|" . Nonce . "`n\z", &Match))
        AssertEqual(AppPid, Integer(Match[1]))
        BHwnd := Integer(Match[2]), BControl := Integer(Match[3])
        ActualPid := 0
        AssertTrue(DllCall("User32\GetWindowThreadProcessId", "Ptr", BHwnd, "UInt*", &ActualPid, "UInt") > 0)
        AssertEqual(AppPid, ActualPid)
        AssertTrue(DllCall("User32\IsChild", "Ptr", BHwnd, "Ptr", BControl, "Int"))
        PortRecord := FileRead(PeerReady, "UTF-8-RAW")
        AssertTrue(RegExMatch(PortRecord, "^[0-9]{1,5}`n\z"))
        Port := Integer(SubStr(PortRecord, 1, -1))
        AssertTrue(Port > 0 && Port <= 65535)
        State.GuiA := Gui(, "Owned excluded source " . Nonce)
        EditA := State.GuiA.AddEdit("w360 h100" . (SecretOrigin ? " Password" : ""))
        State.GuiA.Show("w400 h150")
        AHwnd := State.GuiA.Hwnd, AControl := EditA.Hwnd
        AApp := WinGetProcessName("ahk_id " . AHwnd), BApp := WinGetProcessName("ahk_id " . BHwnd)
        AssertTrue(AApp != "" && BApp != "" && StrCompare(AApp, BApp, false) != 0)
        Entry := Map("Id", "source-owned", "Provider", "openai_compat", "Model", "fixture-model",
            "Token", "owned-fixture-key", "BaseUrl", "http://127.0.0.1:" . Port . "/v1")
        State.Endpoint := Entry["BaseUrl"] . "/chat/completions"
        _LLM_Menu["api_entries"] := [Entry], _LLM_Menu["api_entry_id"] := "source-owned"
        _LLM_Menu["agent_mode"] := "off"
        _LLM_Bridge_Active := true, _LLM_Bridge_Buffer := "", _LLM_Bridge_AgentBuffer := ""
        _LLM_Bridge_BufferSource := 0, _LLM_Bridge_AgentBufferSource := 0
        _LLM_Bridge_AgentContentGeneration := 0, _LLM_Bridge_BufferAgentSafe := true
        _LLM_Bridge_PrivacyAppCache := 0
        _LLM_Live := Map("active", false, "profile_id", "", "num_predictions", 0)
        _Stub_LlmTooltipVisible := false, _Stub_LlmTooltipLoading := false
        _Stub_LlmTooltipText := "", _Stub_LlmPresentedRecord := 0
        _LLM_Bridge_PrefixObserver := 0, HSE_Buffer := "", _PrefixBuffer := ""
        _LLM_Agent_Auto := Map("timer", 0, "offer", "", "triaged", Map(), "order", [])
        _LLM_Engine_RemoteTransport := 0
        LLM_Engine_Init(Map("backend", "api", "api_entries", [Entry], "api_entry_id", "source-owned",
            "profile_id", "basic", "n_predictions", 1, "disabled_apps", PasswordProbe ? [] : [AApp],
            "disable_password_fields", true,
            "debounce_ms", StyleProbe ? 100 : 1000, "instant_on_word_end", false, "show_info_bar", false))
        State.TypedHwnd := AllowedOrigin && !StyleProbe ? BHwnd : AHwnd
        State.TypedControl := AllowedOrigin && !StyleProbe ? BControl : AControl
        WinActivate("ahk_id " . State.TypedHwnd)
        AssertTrue(WinWaitActive("ahk_id " . State.TypedHwnd, , 2))
        ControlFocus(State.TypedControl)
        AssertEqual(State.TypedControl, WIGetFocusedControlToken())
        AssertEqual(!PasswordProbe && Mode != "allowed-stays", _LLM_Engine_ShouldSuppressForDisabledApps(),
            "native app identity establishes the real excluded/allowed precondition")
        if StyleProbe {
            AssertEqual(100, _LLM_Engine["debounce_ms"], "the actual user debounce remains shorter than the unmodified detector TTL")
            AssertEqual(1000, SFD_FIELD_CACHE_TTL_MS, "the style probe must retain the actual native detector TTL")
            ; Only the synchronous hook acquisition opts out of the suite's
            ; dry-run sentinel. Restore it before yielding or delivering input.
            TrackingCritical := Critical("On")
            DryRunWasSet := IsSet(_AHK_DRY_RUN)
            if DryRunWasSet
                SavedDryRun := _AHK_DRY_RUN
            try {
                _AHK_DRY_RUN := unset
                AssertTrue(SFD_EnsureFocusTracking(), "the style composition requires a genuinely acquired native focus hook")
            } finally {
                if DryRunWasSet
                    _AHK_DRY_RUN := SavedDryRun
                else
                    _AHK_DRY_RUN := unset
                Critical(TrackingCritical)
            }
            Sleep(100)
            AssertEqual(State.TypedControl, WIGetFocusedControlToken())
        }
        if PasswordProbe {
            AssertTrue(_LLM_Engine["disable_password_fields"], "the real typed engine option must enable password protection")
            AssertEqual(SecretOrigin, !!(WinGetStyle("ahk_id " . State.TypedControl) & 0x20), "the actual source Edit must carry the intended native ES_PASSWORD style")
            AssertEqual(State.TypedControl, SFD_FocusedHwnd(), "the real detector must identify the exact native source control")
            State.SecureSource := SFD_IsSecureField()
            AssertEqual(SecretOrigin, State.SecureSource, "the genuine native detector must independently classify the source before typing")
        } else {
            ; The source is a native plain Edit in every old app-only case.
            ; Warm its genuine conclusive verdict before controlled injection.
            State.SecureSource := SFD_IsSecureField()
            AssertFalse(State.SecureSource)
        }
        if StyleProbe {
            State.StyleOriginAt := SFD_FIELD_CACHE["at"]
            State.StyleOriginGeneration := SFD_FIELD_CACHE["focus_generation"]
            State.StyleOriginElement := SFD_FIELD_CACHE["current_element_id"]
            AssertTrue(SFD_FIELD_CACHE["focus_hook"] && SFD_FIELD_CACHE["focus_callback"]
                && SFD_FIELD_CACHE["focus_tracking_active"] && !SFD_FIELD_CACHE["secure"]
                && SFD_FIELD_CACHE["hwnd"] == State.TypedControl && State.StyleOriginElement != "",
                "the original normal receipt must belong to the real native focus hook and exact Edit")
            if Mode == "style-password-prefix"
                EditA.Opt("+Password")
            Sleep(50)
            AssertEqual(AHwnd, WIGetForegroundHwnd())
            AssertEqual(AControl, WIGetFocusedControlToken())
            NativeStyleSecure := SFD_DetectNative(AControl, &NativeStyleConclusive)
            AssertTrue(NativeStyleConclusive)
            AssertEqual(Mode == "style-password-prefix", NativeStyleSecure)
        }
        Canary := AllowedOrigin ? "allowed_context_b_canary" : "private_context_a_canary"
        State.Hook := InputHook("V L0 I1")
        State.Hook.KeyOpt("{All}", "+N")
        State.Hook.OnChar := _LDP_Char.Bind(State)
        State.Hook.OnKeyDown := _LDP_Down.Bind(State)
        HookDispatcher._ih := State.Hook
        State.InputActive := true
        State.Hook.Start()
        AssertTrue(State.Hook.InProgress)
        PreviousSendLevel := A_SendLevel
        PreviousKeyDelay := A_KeyDelay, PreviousKeyDuration := A_KeyDuration
        ; Baselines of the arm event: A may arm and even fire before the snapshot.
        BeforeCounter := _LLM_Remote_AsyncCounter, BeforeRequestId := _LLM_Engine.Get("request_id", 0)
        try {
            if StyleProbe
                SetKeyDelay(-1, -1)
            SendLevel(2)
            SendEvent("{Text}" . Canary)
        } finally {
            SendLevel(PreviousSendLevel)
            if StyleProbe
                SetKeyDelay(PreviousKeyDelay, PreviousKeyDuration)
        }
        ; An admitted origin waits for its arm; a private one for the owner that purges it.
        _LDP_AwaitBurst(State, Canary, AllowedOrigin, 0, BeforeRequestId, BeforeCounter)
        AssertEqual(Canary, State.InputChars, "the actual I1 native callback observes the complete typed canary")
        AssertEqual(Canary, ControlGetText(State.TypedControl), "the same actual text is present in the original native Edit")
        AssertEqual(State.InputCallbacks, State.InputCompleted, "the native producer must finish before its context is sampled")
        AssertFalse(IsObject(_LLM_Bridge_PrefixObserver), "the real deferred prefix owner must finish before the request receipt is sampled")
        SnapshotCritical := Critical("On")
        try {
            PrivatePurged := !AllowedOrigin && _LLM_Bridge_Buffer == ""
            if PrivatePurged {
                AssertEqual("", _LLM_Engine["last_buffer"], "upstream rejection must leave no private engine context")
                AssertFalse(_LLM_Engine["timer_active"])
                AssertFalse(IsObject(_LLM_Engine_Plan().Pending))
                ArmToken := 0
            } else {
                AssertEqual(Canary, _LLM_Bridge_Buffer)
                AssertEqual(Canary, _LLM_Engine["last_buffer"])
                AssertTrue(_LDP_ArmedSince(0, BeforeRequestId, BeforeCounter),
                    "admitted source text must own the genuine native debounce timer")
                ; A timer that already fired leaves no pending token to supersede.
                Pending := _LLM_Engine_Plan().Pending
                ArmToken := _LLM_Engine["timer_active"] && IsObject(Pending) ? Pending["token"] : 0
            }
            InputCount := State.InputCallbacks, DownCount := State.InputDowns
            ; BeforeCounter stays the pre-typing baseline: an A request reserved
            ; before this snapshot still belongs to this case's single reservation.
            BeforeFreshRequestId := _LLM_Engine.Get("request_id", 0)
        } finally Critical(SnapshotCritical)
        if Switches {
            ; No Send/keys/click: this is an application's ordinary activation.
            AssertTrue(DllCall("User32\SetForegroundWindow", "Ptr", BHwnd, "Int"),
                "the current foreground owner transfers activation through the real native API")
            AssertTrue(WinWaitActive("ahk_id " . BHwnd, , 2))
            AssertEqual(BControl, WIGetFocusedControlToken())
            AssertFalse(_LLM_Engine_ShouldSuppressForDisabledApps(), "the live B app is genuinely allowed")
        }
        if PasswordProbe {
            AssertEqual(Switches ? BControl : State.TypedControl, SFD_FocusedHwnd())
            ; The new style observer is passive: do not refresh the subject's
            ; secure cache before its own deferred input/HTTP path gets to read it.
            State.SecureFocus := StyleProbe ? !!(WinGetStyle("ahk_id " . State.TypedControl) & 0x20) : SFD_IsSecureField()
            if !StyleProbe
                AssertEqual(SecretOrigin && !Switches, State.SecureFocus, "the real current-field detector must distinguish source password A from the current plain B")
        }
        OriginHwnd := State.TypedHwnd, OriginControl := State.TypedControl
        if Retyped {
            ; Genuine new input rearms from B. The new context may be sent, but
            ; none of the excluded/password A canary may survive that rearm.
            State.TypedHwnd := BHwnd, State.TypedControl := BControl
            AllowedCanary := "allowed_context_b_canary"
            PriorCallbacks := State.InputCallbacks
            AssertFalse(SFD_IsSecureField(), "the exact fresh B Edit has a conclusive genuine plain verdict before injection")
            PreviousSendLevel := A_SendLevel
            try {
                SendLevel(2)
                SendEvent("{Text}" . AllowedCanary)
            } finally SendLevel(PreviousSendLevel)
            _LDP_AwaitBurst(State, Canary . AllowedCanary, true, ArmToken, BeforeFreshRequestId, BeforeCounter)
            AssertEqual(Canary . AllowedCanary, State.InputChars, "both actual I1 input bursts must be observed in order")
            AssertEqual(AllowedCanary, ControlGetText(BControl), "the fresh allowed context is genuinely present in native B")
            AssertEqual(PriorCallbacks + StrLen(AllowedCanary), State.InputCallbacks)
            FreshBCompletedAtSnapshot := State.InputCompleted
            FreshBBufferExact := _LLM_Bridge_Buffer == AllowedCanary
            FreshBEngineExact := _LLM_Engine["last_buffer"] == AllowedCanary
            AssertTrue(_LDP_ArmedSince(ArmToken, BeforeFreshRequestId, BeforeCounter),
                "fresh B input supersedes the original A arm through the real engine")
            InputCount := State.InputCallbacks, DownCount := State.InputDowns
        }
        PendingAfterSwitch := IsObject(_LLM_Engine_Plan().Pending)
        Started := A_TickCount
        loop {
            Id := BeforeCounter + 1
            if _LLM_Remote_Async.Has(Id) {
                State.Id := Id, State.Entry := _LLM_Remote_Async[Id]
            }
            if !_LLM_Engine["timer_active"] && !IsObject(_LLM_Engine_Plan().Pending) && _LLM_Remote_Async.Count == 0
                break
            if TickElapsed64(Started) >= 20000
                throw Error("The actual debounce/request owner did not settle.")
            _SR_TreePoll()
            Sleep(10)
        }
        if IsObject(State.Failure)
            throw State.Failure
        AssertEqual(InputCount, State.InputCallbacks, "settlement introduces no characters beyond the explicitly admitted native bursts")
        AssertEqual(DownCount, State.InputDowns, "settlement introduces no additional keydown beyond the admitted native bursts")
        State.InputActive := false
        State.Hook.Stop()
        AssertFalse(State.Hook.InProgress)
        NativeDelta := _LLM_Remote_AsyncCounter - BeforeCounter
        Source := _LLM_Engine.Get("request_accept_source", Map())
        SourceApp := Source is Map ? Source.Get("app_name", "") : ""
        FocusApp := WIGetFocused()["appId"]
        _LDP_Join(State, "peer")
        Posts := 0, SourceA := 0, SourceB := 0
        if FileExist(Receipt) {
            for Line in StrSplit(FileRead(Receipt, "UTF-8-RAW"), "`n", "`r") {
                if Line == ""
                    continue
                Row := JsonParse(Line)
                AssertEqual("POST", Row["method"]), AssertEqual("/v1/chat/completions", Row["path"])
                AssertEqual(200, Row["status"])
                Posts += 1, SourceA += Row["source_a"] == true, SourceB += Row["source_b"] == true
            }
        }
        _TestPrint("# LLM_DEBOUNCE_SOURCE " . KL_JsonEncode(Map("mode", Mode, "arm_token", ArmToken,
            "pending_after_switch", PendingAfterSwitch, "native_chars", State.InputCallbacks, "native_keydowns", State.InputDowns,
            "source_app", SourceApp, "focus_app", FocusApp, "a_app", AApp, "b_app", BApp,
            "source_secure", State.SecureSource, "focus_secure", State.SecureFocus,
            "origin_hwnd", OriginHwnd, "origin_control", OriginControl, "fresh_b_input", Retyped,
            "private_source_purged", PrivatePurged,
            "fresh_b_buffer_exact", Retyped ? FreshBBufferExact : -1,
            "fresh_b_completed_at_snapshot", Retyped ? FreshBCompletedAtSnapshot : -1,
            "fresh_b_engine_exact", Retyped ? FreshBEngineExact : -1,
            "typed_hwnd", State.TypedHwnd, "typed_control", State.TypedControl,
            "captured_source_hwnd", Source is Map ? Source.Get("hwnd", 0) : 0,
            "captured_source_control", Source is Map ? Source.Get("control", 0) : 0,
            "focus_hwnd", WIGetForegroundHwnd(),
            "native_request_delta", NativeDelta, "http_posts", Posts, "source_a_received", SourceA,
            "source_b_received", SourceB, "remaining_requests", _LLM_Remote_Async.Count)))
        if StyleProbe {
            _TestPrint("# LLM_PREFIX_NATIVE_STYLE " . KL_JsonEncode(Map("mode", Mode,
                "native_chars", State.InputCallbacks, "native_password_callbacks", State.StylePasswordCallbacks,
                "first_cached_negative", State.StyleFirstNegative, "mirrored_private_units", State.StylePrivateMirroredUnits,
                "max_input_age_ms", State.StyleMaxInputAge, "ttl_ms", SFD_FIELD_CACHE_TTL_MS,
                "http_posts", Posts, "private_canary_posts", SourceA, "plain_canary_posts", SourceB)))
            AssertTrue(State.StyleMaxInputAge < SFD_FIELD_CACHE_TTL_MS,
                "the actual input must arrive within the original unmodified negative-cache TTL")
            AssertEqual(Mode == "style-password-prefix" ? State.InputCallbacks : 0, State.StylePasswordCallbacks,
                "each actually observed input character must belong to its real intended native password style")
            AssertEqual(0, State.StylePrivateMirroredUnits,
                "the RAM prefix producer must not retain characters whose unchanged native Edit is already private")
        }
        if Retyped && (!FreshBBufferExact || !FreshBEngineExact)
            _TestPrint("# LLM_DEBOUNCE_PRIVACY_TRACE " . KL_JsonEncode(State.PrivacyTrace))
        if Retyped {
            AssertTrue(FreshBBufferExact, "the rolling context must contain exactly B, never retained private A")
            AssertTrue(FreshBEngineExact, "the armed engine must contain exactly B")
        }
        ExpectedPosts := (AllowedOrigin || Retyped) ? 1 : 0
        ; A missing request on an allowed context is intermittent on hosted
        ; runners: record the engine and detector state, and every native
        ; character's before/after trace, before the verdict.
        if Posts != ExpectedPosts
            _TestPrint("# LLM_DEBOUNCE_MISSING_REQUEST " . KL_JsonEncode(Map("mode", Mode,
                "expected_posts", ExpectedPosts, "posts", Posts, "native_request_delta", NativeDelta,
                "settled_ms", TickElapsed64(Started), "ttl_ms", SFD_FIELD_CACHE_TTL_MS,
                "now", _LDP_PrivacyTraceState(), "trace", State.PrivacyTrace)))
        AssertEqual(ExpectedPosts, Posts, "only the genuinely allowed context may produce one HTTP request")
        if ExpectedPosts
            AssertEqual(1, NativeDelta, "the live control creates its genuine remote reservation once")
        if Posts {
            AssertTrue(Source is Map)
            AssertEqual(State.TypedHwnd, Source.Get("hwnd", 0))
            AssertEqual(State.TypedControl, Source.Get("control", 0))
        }
        AssertEqual(0, SourceA, "the private A canary is never admitted")
        AssertEqual(ExpectedPosts, SourceB)
        AssertEqual(0, Calls.Length, "the probe never invokes the fake remote transport")
    } catch Any as Err {
        Primary := Err
    } finally {
        try _LDP_Cleanup(State)
        catch Any as Err {
            _LDP_Debt.Push(State)
            if !IsObject(Primary)
                Primary := Err
        }
        if IsObject(State.Hook) && IsObject(HookDispatcher._ih) && ObjPtr(HookDispatcher._ih) == ObjPtr(State.Hook)
            HookDispatcher._ih := OldHook
        _LLM_Bridge_Active := Saved.Active, _LLM_Bridge_Buffer := Saved.Buffer
        _LLM_Bridge_ContentGeneration := Saved.Content, _LLM_Bridge_AgentBuffer := Saved.AgentBuffer
        _LLM_Bridge_LastLogTick := Saved.LogTick, _LLM_Bridge_PrefixObserver := Saved.Observer
        _LLM_Agent_Generation := Saved.AgentGeneration, _LLM_Agent_Auto := Saved.AgentAuto
        HSE_Buffer := Saved.Hse, _PrefixBuffer := Saved.Prefix, _LLM_Live := Saved.Live
        _LLM_Bridge_BufferSource := Saved.BufferSource, _LLM_Bridge_AgentBufferSource := Saved.AgentSource
        _LLM_Bridge_AgentContentGeneration := Saved.AgentContent, _LLM_Bridge_BufferAgentSafe := Saved.AgentSafe
        _LLM_Bridge_PrivacyAppCache := Saved.PrivacyCache
    }
    if IsObject(Primary)
        throw Primary
}
_LDP_Fixture(Mode) {
    global _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading, _Stub_LlmTooltipText, _Stub_LlmPresentedRecord
    Saved := {Visible: _Stub_LlmTooltipVisible, Loading: _Stub_LlmTooltipLoading,
        Text: _Stub_LlmTooltipText, Presented: _Stub_LlmPresentedRecord}
    try _LPP_Run(_LPP_Menu(), "", _LDP_Native.Bind(Mode), true)
    finally {
        _Stub_LlmTooltipVisible := Saved.Visible, _Stub_LlmTooltipLoading := Saved.Loading
        _Stub_LlmTooltipText := Saved.Text, _Stub_LlmPresentedRecord := Saved.Presented
    }
}
_LDP_Run(Mode) {
    PreviousCritical := Critical("Off")
    try {
        _LDP_DrainDebt()
        _ManagedRemoteFixtureWithLlmTimings(_LATHTTP_HostScope.Bind(_LDP_Fixture.Bind(Mode)))
    } finally Critical(PreviousCritical)
}
for _LDP_Mode in ["excluded-stays", "allowed-stays", "excluded-switches"]
    Test("Debounce source privacy: " . _LDP_Mode . " retains native typed provenance (llm-debounce-source-privacy)",
        _LDP_Run.Bind(_LDP_Mode))

for _LDP_PasswordMode in ["password-stays", "plain-stays", "password-switches"]
    Test("Debounce password source privacy: " . _LDP_PasswordMode . " retains actual secure-field provenance (llm-debounce-password-source-privacy)",
        _LDP_Run.Bind(_LDP_PasswordMode))

for _LDP_RetypedMode in ["excluded-switches-typed", "password-switches-typed"]
    Test("Debounce private rolling context: " . _LDP_RetypedMode . " never taints fresh allowed native input (llm-debounce-private-retyped-context)",
        _LDP_Run.Bind(_LDP_RetypedMode))


; These additional modes retain all eight old mode definitions and oracles.
; Input is real SendEvent at level2 into the owned Edit, not hardware typing.
for _LDP_StyleMode in ["style-password-prefix", "style-plain-prefix"]
    Test("Native prefix style privacy: " . _LDP_StyleMode . " retains actual capture-time style (llm-prefix-native-style-privacy)",
        _LDP_Run.Bind(_LDP_StyleMode))
