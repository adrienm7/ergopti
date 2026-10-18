; tests/unit/modules/llm/prediction/test_llm_prediction_engine_pointer_dismiss.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine Pointer Dismiss
; DESCRIPTION:
; A pointer dismissal while the engine is busy: each case states all four
; sources of LLM_Engine_IsBusy and the fired prediction that follows.
; ==============================================================================

#Requires AutoHotkey v2.0





_LLM_EngineIsBusy_Case(TimerActive, Streams, OllamaAsync, RemoteAsync) {
	global _LLM_Engine, _LLM_Ollama_ActiveStreams, _LLM_Ollama_Async, _LLM_Remote_Async
	Saved := {
		Engine: _LLM_Engine, Streams: _LLM_Ollama_ActiveStreams,
		OllamaAsync: _LLM_Ollama_Async, RemoteAsync: _LLM_Remote_Async
	}
	try {
		_LLM_Engine := Map("timer_active", TimerActive)
		_LLM_Ollama_ActiveStreams := Streams
		_LLM_Ollama_Async := OllamaAsync
		_LLM_Remote_Async := RemoteAsync
		return LLM_Engine_IsBusy()
	} finally {
		_LLM_Engine := Saved.Engine
		_LLM_Ollama_ActiveStreams := Saved.Streams
		_LLM_Ollama_Async := Saved.OllamaAsync
		_LLM_Remote_Async := Saved.RemoteAsync
	}
}

_LLM_EngineIsBusy_TimerActive() {
	AssertTrue(_LLM_EngineIsBusy_Case(true, [], Map(), Map()),
		"engine is busy when debounce timer is active")
}
Test("LLM_Engine_IsBusy: detects active debounce timer", _LLM_EngineIsBusy_TimerActive)

_LLM_EngineIsBusy_ActiveStreams() {
	AssertTrue(_LLM_EngineIsBusy_Case(false, [1], Map(), Map()),
		"engine is busy when streams are active")
}
Test("LLM_Engine_IsBusy: detects active streams", _LLM_EngineIsBusy_ActiveStreams)

_LLM_EngineIsBusy_ActiveOllamaAsync() {
	AssertTrue(_LLM_EngineIsBusy_Case(false, [], Map(1, Map("cancelled", false)), Map()),
		"engine is busy when Ollama async request is active")
}
Test("LLM_Engine_IsBusy: detects active Ollama async", _LLM_EngineIsBusy_ActiveOllamaAsync)

_LLM_EngineIsBusy_Idle() {
	AssertFalse(_LLM_EngineIsBusy_Case(false, [], Map(), Map()),
		"engine is not busy when idle")
}
Test("LLM_Engine_IsBusy: false when idle", _LLM_EngineIsBusy_Idle)

; Regression: a debounce timer that outlives the engine map must be a no-op.
;
; The timer is armed with SetTimer and fires from AHK's timer thread, long after
; the call site returned. Several cases in this very file replace _LLM_Engine
; with a one-key Map, and a stray timer landing in that window read
; _LLM_Engine["enabled"] on a map that no longer had the key -- "Item has no
; value", raised from a timer thread where no caller can catch it, so it took the
; whole process down rather than one prediction. It surfaced as an intermittent
; FATAL STARTUP ERROR that moved around the suite depending on timing.
;
; The state a stale timer was armed for is gone; dropping the prediction is the
; only correct outcome, and it must be a return, never a raise.
_LLM_EngineFire_SurvivesTornDownEngine() {
	global _LLM_Engine
	Saved := _LLM_Engine

	_LLM_Engine := Map("timer_active", true)   ; the shape a mid-test case leaves behind
	Threw := false
	try {
		LLM_Engine_FirePrediction("bonjour le")
	} catch {
		Threw := true
	}
	_LLM_Engine := Saved
	AssertFalse(Threw,
		"a debounce timer firing against a torn-down engine must drop the prediction, not raise from "
		. "a timer thread where nothing can catch it")
}
Test("LLM_Engine_FirePrediction: a stale timer against a torn-down engine is a no-op", _LLM_EngineFire_SurvivesTornDownEngine)

_LLM_EngineFire_SurvivesNonMapEngine() {
	global _LLM_Engine
	Saved := _LLM_Engine

	_LLM_Engine := ""                          ; the shape a teardown leaves behind
	Threw := false
	try {
		LLM_Engine_FirePrediction("bonjour le")
	} catch {
		Threw := true
	}
	_LLM_Engine := Saved
	AssertFalse(Threw, "an engine that is not a Map at all must also be survivable")
}
Test("LLM_Engine_FirePrediction: a stale timer against a non-Map engine is a no-op", _LLM_EngineFire_SurvivesNonMapEngine)


; Regression: the loading spinner must NOT replace a prediction already on screen.
; macOS parity (prediction_engine.lua:590) — replacing a shown prediction with the
; violet "Génération en cours…" spinner on every follow-up keystroke is the churn
; that made suggestions vanish before the user could read them. _LLM_Engine_Show-
; LoadingTooltip must skip the spinner while a real prediction is visible, and
; still paint it when the screen is empty.
_LLM_EngineShowLoading_SuppressedWhenPredictionVisible() {
	global _LLM_Engine, _Stub_LlmTooltipCalls, _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading
	Saved := {
		Engine: _LLM_Engine, Calls: _Stub_LlmTooltipCalls,
		Visible: _Stub_LlmTooltipVisible, Loading: _Stub_LlmTooltipLoading
	}
	try {
		_LLM_Engine := Map("inline_autotype", false)
		_Stub_LlmTooltipVisible := true    ; a real prediction is on screen…
		_Stub_LlmTooltipLoading := false   ; …not the loading spinner
		_Stub_LlmTooltipCalls := []
		_LLM_Engine_ShowLoadingTooltip()
		shown := false
		for c in _Stub_LlmTooltipCalls {
			if (c.HasOwnProp("loading") and c.loading)
				shown := true
		}
		AssertFalse(shown, "loading spinner must NOT replace a prediction already on screen")
	} finally {
		_LLM_Engine := Saved.Engine
		_Stub_LlmTooltipCalls := Saved.Calls
		_Stub_LlmTooltipVisible := Saved.Visible
		_Stub_LlmTooltipLoading := Saved.Loading
	}
}
Test("LLM engine: loading spinner suppressed while a prediction is visible", _LLM_EngineShowLoading_SuppressedWhenPredictionVisible)


_LLM_EngineShowLoading_ShownWhenScreenEmpty() {
	global _LLM_Engine, _Stub_LlmTooltipCalls, _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading
	Saved := {
		Engine: _LLM_Engine, Calls: _Stub_LlmTooltipCalls,
		Visible: _Stub_LlmTooltipVisible, Loading: _Stub_LlmTooltipLoading
	}
	try {
		_LLM_Engine := Map(
			"inline_autotype", false,
			"request_id", 41,
			"active_request_signature", "sig-A")
		_Stub_LlmTooltipVisible := false   ; nothing on screen
		_Stub_LlmTooltipLoading := false
		_Stub_LlmTooltipCalls := []
		_LLM_Engine_ShowLoadingTooltip()
		shown := false
		LoadingCall := 0
		for c in _Stub_LlmTooltipCalls {
			if (c.HasOwnProp("loading") and c.loading) {
				shown := true
				LoadingCall := c
			}
		}
		AssertTrue(shown, "loading spinner must paint when the screen is empty")
		AssertTrue(IsObject(LoadingCall) && LoadingCall.meta.Has("render_guard")
				&& HasMethod(LoadingCall.meta["render_guard"], "Call"),
			"deferred loading must carry the exact request identity to publication")
		LoadingGuard := LoadingCall.meta["render_guard"]
		AssertTrue(LoadingGuard.Call(),
			"loading identity must accept the request which scheduled it")
		_LLM_Engine["request_id"] := 42
		_LLM_Engine["active_request_signature"] := "sig-B"
		AssertFalse(LoadingGuard.Call(),
			"loading identity must reject after a later keystroke cancels its request")
	} finally {
		_LLM_Engine := Saved.Engine
		_Stub_LlmTooltipCalls := Saved.Calls
		_Stub_LlmTooltipVisible := Saved.Visible
		_Stub_LlmTooltipLoading := Saved.Loading
	}
}
Test("LLM engine: loading spinner shown when no prediction is visible", _LLM_EngineShowLoading_ShownWhenScreenEmpty)


_LLM_EnginePartialRender_RejectsSupersededIdentity() {
	global _LLM_Engine, _Stub_LlmTooltipCalls
	global _Stub_LlmTooltipVisible, _Stub_LlmTooltipLoading
	global _Stub_LlmTooltipText, _Stub_LlmPresentedRecord
	Saved := {
		Engine: _LLM_Engine, Calls: _Stub_LlmTooltipCalls,
		Visible: _Stub_LlmTooltipVisible, Loading: _Stub_LlmTooltipLoading,
		Text: _Stub_LlmTooltipText, Presented: _Stub_LlmPresentedRecord
	}
	try {
		_LLM_Engine := Map(
			"request_id", 2,
			"active_request_signature", "sig-B",
			"profile_id", "",
			"user_profiles", [],
			"inline_autotype", false)
		_Stub_LlmTooltipCalls := []

		LLM_Engine_OnResults(
			["stale-A"], "ctx-A", 1, false, 1, "sig-A")
		AssertEqual(0, _Stub_LlmTooltipCalls.Length,
			"a superseded intermediate callback must not repaint after its request was cancelled")

		LLM_Engine_OnResults(
			["live-B"], "ctx-B", 1, false, 2, "sig-B")
		AssertEqual(1, _Stub_LlmTooltipCalls.Length,
			"the current intermediate callback must still paint exactly once")
		Call := _Stub_LlmTooltipCalls[1]
		AssertFalse(Call.is_final,
			"the control render must remain an intermediate tooltip update")
		AssertEqual("live-B", Call.slots[1],
			"the admitted intermediate render must carry the current request's slot")
		AssertTrue(Call.meta.Has("render_guard")
				&& HasMethod(Call.meta["render_guard"], "Call"),
			"each identified render must carry its immutable publication guard")
		RenderGuard := Call.meta["render_guard"]
		AssertTrue(RenderGuard.Call(),
			"the publication guard must accept the exact current request identity")
		_LLM_Engine["request_id"] := 3
		_LLM_Engine["active_request_signature"] := "sig-C"
		AssertFalse(RenderGuard.Call(),
			"the same bound guard must reject after a later keystroke supersedes its request")
	} finally {
		_LLM_Engine := Saved.Engine
		_Stub_LlmTooltipCalls := Saved.Calls
		_Stub_LlmTooltipVisible := Saved.Visible
		_Stub_LlmTooltipLoading := Saved.Loading
		_Stub_LlmTooltipText := Saved.Text
		_Stub_LlmPresentedRecord := Saved.Presented
	}
}

Test("LLM engine: superseded partial render cannot repaint (ahk026-partial-render-identity)",
	_LLM_EnginePartialRender_RejectsSupersededIdentity)


; A5 follow-up — per-call token budget mirrors macOS fetch_batch scaling.
; A sequential-variant call yields 1 prediction; a single batch call yields N.
_LLM_EngineCallTokenBudget_Sequential() {
	; preds_per_call = 1 -> maxTokens + 1*5
	AssertEqual(105, _LLM_Engine_CallTokenBudget(100, 1), "sequential call = maxTokens + overhead")
}
Test("LLM engine: per-call token budget for a sequential variant", _LLM_EngineCallTokenBudget_Sequential)

_LLM_EngineCallTokenBudget_Batch() {
	; preds_per_call = 3 -> maxTokens*3 + 3*5 (all 3 predictions in one response)
	AssertEqual(315, _LLM_Engine_CallTokenBudget(100, 3), "batch call scales by num_predictions")
}
Test("LLM engine: per-call token budget scales for a batch call", _LLM_EngineCallTokenBudget_Batch)

_LLM_EngineCallTokenBudget_GuardsInvalidCount() {
	; A non-positive / non-integer count is treated as a single prediction.
	AssertEqual(105, _LLM_Engine_CallTokenBudget(100, 0), "zero predictions guarded to one")
}
Test("LLM engine: per-call token budget guards an invalid prediction count", _LLM_EngineCallTokenBudget_GuardsInvalidCount)
