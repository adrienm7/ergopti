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
		Tail := "", MaxTokens := "") {
	global _LLM_Engine
	State.Calls.Push(Map("entry", Entry, "system", SystemPrompt, "ctx", Context,
		"temperature", Temperature, "on_success", OnSuccess, "on_fail", OnFail,
		"tail", Tail, "max_tokens", MaxTokens, "request_id", _LLM_Engine["request_id"]))
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
	State.FloorMs := LLM_ApiCommon_GetRateLimitMs("api") + 1
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
