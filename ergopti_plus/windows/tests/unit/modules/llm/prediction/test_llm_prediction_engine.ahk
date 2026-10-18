; static/ergopti_plus/windows/tests/unit/modules/llm/prediction/test_llm_prediction_engine.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine Tests
; DESCRIPTION:
; Unit-tests for the purely-logical helpers in modules/llm/prediction_engine.ahk:
; LLM_Engine_Init, LLM_Engine_SetEnabled, LLM_Engine_CancelTimer,
; LLM_Engine_OnKeystroke, _LLM_Engine_SplitBatchBlocks,
; _LLM_Engine_MaxAttempts, _LLM_Engine_ResolveProfileIdForApp,
; _LLM_Engine_GetActiveApiEntry, and the request-id / cache hit logic
; (exercised through LLM_Engine_FirePrediction via stub dispatch functions).
; No real HTTP calls are made — dispatch functions are replaced with stubs.
; ==============================================================================




; =========================================
; =========================================
; ======= 1/ LLM_Engine_Init ==============
; =========================================
; =========================================

_TLPE_PerformanceReceiptOwnsItsRequest() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	try {
		Perf := { Id: 7, Started: A_TickCount, Path: "exact_cache", FirstVisible: false, FinalLogged: false }
		_LLM_Engine := Map("performance_request", Perf)
		AssertFalse(_LLM_Engine_PerformanceRender(6, 1, true),
			"a superseded response cannot borrow the new request's timer")
		AssertFalse(_LLM_Engine_PerformanceRender(7, 0, false),
			"a refused streaming paint is not a first usable prediction")
		AssertFalse(Perf.FirstVisible)
		AssertTrue(_LLM_Engine_PerformanceRender(7, 13, false))
		AssertTrue(Perf.FirstVisible)
		AssertFalse(_LLM_Engine_PerformanceRender(7, 14, false),
			"streaming updates must not create per-frame INFO traffic")
		AssertTrue(_LLM_Engine_PerformanceRender(7, 0, true))
		AssertTrue(Perf.FinalLogged)
		AssertFalse(_LLM_Engine_PerformanceRender(7, 15, true),
			"one request has one final presentation outcome")
	} finally {
		_LLM_Engine := SavedEngine
	}
}

Test("LLM engine: performance receipts own the request and visible commit (llm-perf-receipt-2026-10-02)",
	_TLPE_PerformanceReceiptOwnsItsRequest)

_EngineInit_SetsEnabledTrue() {
	global _LLM_Engine
	_LLM_Engine["enabled"] := false
	LLM_Engine_Init(Map("model", "qwen2.5:3b"))
	AssertTrue(_LLM_Engine["enabled"])
}
Test("LLM_Engine_Init: sets enabled to true", _EngineInit_SetsEnabledTrue)


_EngineInit_OverridesModel() {
	global _LLM_Engine
	LLM_Engine_Init(Map("model", "mistral:7b"))
	AssertEqual("mistral:7b", _LLM_Engine["model"])
}
Test("LLM_Engine_Init: overrides model from opts", _EngineInit_OverridesModel)


_EngineInit_OverridesDebounceMs() {
	global _LLM_Engine
	LLM_Engine_Init(Map("debounce_ms", 250))
	AssertEqual(250, _LLM_Engine["debounce_ms"])
}
Test("LLM_Engine_Init: overrides debounce_ms from opts", _EngineInit_OverridesDebounceMs)


_EngineInit_OverridesNPredictions() {
	global _LLM_Engine
	LLM_Engine_Init(Map("n_predictions", 5))
	AssertEqual(5, _LLM_Engine["n_predictions"])
}
Test("LLM_Engine_Init: overrides n_predictions from opts", _EngineInit_OverridesNPredictions)


_EngineInit_LanguageFollowsLocale() {
	global _LLM_Engine, _I18nLocale
	Saved := _I18nLocale
	_I18nLocale := "en"
	LLM_Engine_Init(Map())
	; These cases exercise the cache and debounce paths, not the privacy gate.
	; State the posture explicitly: the shared default now BLOCKS secure fields,
	; and the production gate fails closed when the detector cannot answer —
	; which is always the case in a headless harness, so every prediction would
	; be suppressed and these tests would assert nothing about their own subject.
	_LLM_Engine["disable_password_fields"] := false
	Lang := _LLM_Engine["language"]
	_I18nLocale := Saved
	AssertEqual("en", Lang)
}
Test("LLM_Engine_Init: language follows the active UI locale, not a hardcoded fr", _EngineInit_LanguageFollowsLocale)


_EngineInit_LanguageOptsOverride() {
	global _LLM_Engine, _I18nLocale
	Saved := _I18nLocale
	_I18nLocale := "en"
	LLM_Engine_Init(Map("language", "de"))
	Lang := _LLM_Engine["language"]
	_I18nLocale := Saved
	AssertEqual("de", Lang)
}
Test("LLM_Engine_Init: explicit opts language overrides the locale default", _EngineInit_LanguageOptsOverride)


_AHK011_EngineInitPublishesEffectiveStreaming() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	_LLM_Engine := SavedEngine.Clone()
	try {
		for Backend in ["ollama", "api"] {
			LLM_Engine_Init(Map("backend", Backend, "streaming", true))
			AssertFalse(_LLM_Engine["streaming"],
				Backend . " must not publish an enabled runtime setting while its "
				. "backend has no supported streaming transport")
		}
	} finally {
		_LLM_Engine := SavedEngine
	}
}
Test("AHK-011: engine admission publishes only effective streaming",
	_AHK011_EngineInitPublishesEffectiveStreaming)


_AHK011_DispatchFixture(ShowAllAtOnce) {
	global _LLM_Engine
	return Map(
		"ctx", "bonjour",
		"request_id", _LLM_Engine["request_id"],
		"semantic_signature", _LLM_Engine["active_request_signature"],
		"slots", ["premiere"],
		"requested", 2,
		"attempt_index", 2,
		"max_attempts", 4,
		"base_temp", 0.1,
		"dispatch_fn", (Temp, OnSuccess, OnFail) => 0,
		"dispatch_stream_fn", "",
		"streaming", false,
		"show_all_at_once", ShowAllAtOnce)
}


_AHK011_AllAtOnceSuppressesEveryIntermediateFrame() {
	global _LLM_Engine, _Stub_LlmTooltipCalls
	SavedEngine := _LLM_Engine
	SavedCalls := _Stub_LlmTooltipCalls
	_LLM_Engine := SavedEngine.Clone()
	try {
		_LLM_Engine["request_id"] := 11011
		_LLM_Engine["active_request_signature"] := "ahk-011"
		_Stub_LlmTooltipCalls := []
		_LLM_Engine_DispatchVariant(_AHK011_DispatchFixture(true))
		AssertEqual(0, _Stub_LlmTooltipCalls.Length,
			"show_all_at_once must suppress the sibling preview emitted while "
			. "the next sequential variant is dispatched")
	} finally {
		_LLM_Engine := SavedEngine
		_Stub_LlmTooltipCalls := SavedCalls
	}
}
Test("AHK-011: show-all-at-once suppresses every intermediate frame",
	_AHK011_AllAtOnceSuppressesEveryIntermediateFrame)


_AHK011_ProgressiveModeStillPaintsIntermediateFrame() {
	global _LLM_Engine, _Stub_LlmTooltipCalls
	SavedEngine := _LLM_Engine
	SavedCalls := _Stub_LlmTooltipCalls
	_LLM_Engine := SavedEngine.Clone()
	try {
		_LLM_Engine["request_id"] := 11012
		_LLM_Engine["active_request_signature"] := "ahk-011-control"
		_Stub_LlmTooltipCalls := []
		_LLM_Engine_DispatchVariant(_AHK011_DispatchFixture(false))
		AssertEqual(1, _Stub_LlmTooltipCalls.Length,
			"the progressive control must still publish one intermediate frame")
		AssertFalse(_Stub_LlmTooltipCalls[1].is_final,
			"the control frame must remain explicitly intermediate")
		AssertEqual("premiere", _Stub_LlmTooltipCalls[1].slots[1],
			"the progressive frame must carry the accumulated real slot")
	} finally {
		_LLM_Engine := SavedEngine
		_Stub_LlmTooltipCalls := SavedCalls
	}
}
Test("AHK-011: progressive mode retains its intermediate frame control",
	_AHK011_ProgressiveModeStillPaintsIntermediateFrame)


_LLM_TooltipVanishOnAccept() {
    global _TooltipDequeueActive
    _TooltipDequeueActive := true
    LLM_TooltipHide()
    AssertFalse(_TooltipDequeueActive, "LLM_TooltipHide must force hide the tooltip immediately when an LLM suggestion is accepted")
}
Test("LLM Tooltip: vanishes immediately on accept", _LLM_TooltipVanishOnAccept)


_EngineInit_IgnoresUnknownKeys() {
	global _LLM_Engine
	; Must not throw when an unknown key is present in opts
	LLM_Engine_Init(Map("nonexistent_key_xyz", "value"))
	AssertTrue(_LLM_Engine["enabled"])
}
Test("LLM_Engine_Init: ignores unknown keys without throwing", _EngineInit_IgnoresUnknownKeys)


_EngineInit_CopiesDisabledAppsArray() {
	global _LLM_Engine
	apps := ["slack.exe", "chrome.exe"]
	LLM_Engine_Init(Map("disabled_apps", apps))
	AssertEqual(2, _LLM_Engine["disabled_apps"].Length)
	AssertEqual("slack.exe", _LLM_Engine["disabled_apps"][1])
	apps[1] := "mutated.exe"
	AssertEqual("slack.exe", _LLM_Engine["disabled_apps"][1],
		"engine admission must detach the caller-owned disabled-app array")
}
Test("LLM_Engine_Init: copies disabled_apps array from opts", _EngineInit_CopiesDisabledAppsArray)

_EngineInit_DetachesNestedOptions() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	_LLM_Engine := SavedEngine.Clone()
	try {
		StopSequences := ["END"]
		Profile := Map(
			"id", "custom",
			"label", "Custom",
			"stop_sequences", StopSequences)
		Profiles := [Profile]
		ApiEntry := { Id: "api-1", Name: "Production" }
		ApiEntries := [ApiEntry]
		Overrides := Map("notepad", "custom")
		LLM_Engine_Init(Map(
			"user_profiles", Profiles,
			"api_entries", ApiEntries,
			"app_profile_overrides", Overrides))

		StopSequences[1] := "MUTATED"
		Profile["label"] := "Mutated"
		Profiles.Push(Map("id", "late"))
		ApiEntry.Name := "Mutated"
		ApiEntries.Push(Map("Id", "api-2"))
		Overrides["notepad"] := "basic"

		AssertEqual(1, _LLM_Engine["user_profiles"].Length,
			"engine admission must detach the caller-owned profile array")
		AssertEqual("Custom", _LLM_Engine["user_profiles"][1]["label"],
			"engine admission must detach each profile record")
		AssertEqual("END", _LLM_Engine["user_profiles"][1]["stop_sequences"][1],
			"engine admission must detach nested profile arrays")
		AssertEqual(1, _LLM_Engine["api_entries"].Length,
			"engine admission must detach the caller-owned API-entry array")
		AssertEqual("Production", _LLM_Engine["api_entries"][1]["Name"],
			"engine admission must detach each API-entry record")
		AssertEqual("custom", _LLM_Engine["app_profile_overrides"]["notepad"],
			"engine admission must detach the caller-owned override map")
	} finally {
		_LLM_Engine := SavedEngine
	}
}
Test("LLM_Engine_Init: composite options are deeply detached at admission "
	. "(llm-persisted-option-type-boundary-detached)",
	_EngineInit_DetachesNestedOptions)

_EngineInit_RejectsNestedDisabledApps() {
	global _LLM_Engine
	SavedEnabled := _LLM_Engine["enabled"]
	SavedModel := _LLM_Engine["model"]
	SavedApps := _LLM_Engine["disabled_apps"]
	_LLM_Engine["enabled"] := false
	_LLM_Engine["model"] := "safe-model"
	_LLM_Engine["disabled_apps"] := ["safe-app"]
	try {
		Thrown := false
		Failure := ""
		try LLM_Engine_Init(Map(
			"model", "must-not-publish",
			"disabled_apps", [["notepad"]]))
		catch as Err {
			Thrown := true
			Assert(Err is TypeError,
				"nested disabled_apps must fail with the admission TypeError")
			Failure := Err.Message
		}
		AssertTrue(Thrown,
			"a nonvalidated caller must fail fast on a nested disabled_apps value")
		AssertContains(Failure, "disabled_apps",
			"the admission error must identify the rejected option")
		AssertFalse(_LLM_Engine["enabled"],
			"failed validation must not enable the engine")
		AssertEqual("safe-model", _LLM_Engine["model"],
			"failed validation must not publish scalar options before the bad array")
		AssertEqual("safe-app", _LLM_Engine["disabled_apps"][1],
			"failed validation must not publish partial engine state")
	} finally {
		_LLM_Engine["enabled"] := SavedEnabled
		_LLM_Engine["model"] := SavedModel
		_LLM_Engine["disabled_apps"] := SavedApps
	}
}
Test("LLM_Engine_Init: nested disabled_apps fails before hot-path publication "
	. "(llm-persisted-option-type-boundary)",
	_EngineInit_RejectsNestedDisabledApps)

_EngineInit_AssertCompositeScalarRejected(Key, BadValue, Baseline, Slug) {
	global _LLM_Engine
	SavedEnabled := _LLM_Engine["enabled"]
	SavedLanguage := _LLM_Engine["language"]
	SavedTarget := _LLM_Engine[Key]
	_LLM_Engine["enabled"] := false
	_LLM_Engine["language"] := "safe-language"
	_LLM_Engine[Key] := Baseline
	try {
		Thrown := false
		Failure := ""
		try LLM_Engine_Init(Map(
			"language", "must-not-publish",
			Key, BadValue))
		catch as Err {
			Thrown := true
			Assert(Err is TypeError,
				Slug . " must fail with the engine admission TypeError")
			Failure := Err.Message
		}
		AssertTrue(Thrown, Slug . " must fail fast at engine admission")
		AssertContains(Failure, Key,
			Slug . " admission error must identify the rejected option")
		AssertFalse(_LLM_Engine["enabled"],
			Slug . " must not enable the engine before validation completes")
		AssertEqual("safe-language", _LLM_Engine["language"],
			Slug . " must not partially publish an earlier valid option")
		AssertEqual(Baseline, _LLM_Engine[Key],
			Slug . " must retain its seeded value")
	} finally {
		_LLM_Engine["enabled"] := SavedEnabled
		_LLM_Engine["language"] := SavedLanguage
		_LLM_Engine[Key] := SavedTarget
	}
}

_EngineInit_RejectsCompositeString() {
	_EngineInit_AssertCompositeScalarRejected(
		"model", [["bad"]], "safe-model", "composite string")
}
Test("LLM_Engine_Init: composite string is rejected atomically "
	. "(llm-persisted-option-type-boundary-engine-string)",
	_EngineInit_RejectsCompositeString)

_EngineInit_RejectsCompositeInteger() {
	_EngineInit_AssertCompositeScalarRejected(
		"n_predictions", [[9]], 3, "composite integer")
}
Test("LLM_Engine_Init: composite integer is rejected atomically "
	. "(llm-persisted-option-type-boundary-engine-integer)",
	_EngineInit_RejectsCompositeInteger)

_EngineInit_RejectsCompositeBoolean() {
	_EngineInit_AssertCompositeScalarRejected(
		"show_info_bar", [[true]], true, "composite boolean")
}
Test("LLM_Engine_Init: composite boolean is rejected atomically "
	. "(llm-persisted-option-type-boundary-engine-boolean)",
	_EngineInit_RejectsCompositeBoolean)

_EngineInit_RejectsCompositeTemperature() {
	_EngineInit_AssertCompositeScalarRejected(
		"temperature", [[0.25]], "0.10", "composite temperature")
}
Test("LLM_Engine_Init: composite temperature is rejected atomically "
	. "(llm-persisted-option-type-boundary-engine-temperature)",
	_EngineInit_RejectsCompositeTemperature)

_EngineInit_AssertCompositeContainerRejected(Key, BadValue, Baseline, Slug) {
	global _LLM_Engine
	SavedEnabled := _LLM_Engine["enabled"]
	SavedLanguage := _LLM_Engine["language"]
	SavedTarget := _LLM_Engine[Key]
	_LLM_Engine["enabled"] := false
	_LLM_Engine["language"] := "safe-language"
	_LLM_Engine[Key] := Baseline
	try {
		Thrown := false
		Failure := ""
		try LLM_Engine_Init(Map(
			"language", "must-not-publish",
			Key, BadValue))
		catch as Err {
			Thrown := true
			Assert(Err is TypeError,
				Slug . " must fail with the engine admission TypeError")
			Failure := Err.Message
		}
		AssertTrue(Thrown, Slug . " must fail fast at engine admission")
		AssertContains(Failure, Key,
			Slug . " admission error must identify the rejected option")
		AssertFalse(_LLM_Engine["enabled"],
			Slug . " must not enable the engine before validation completes")
		AssertEqual("safe-language", _LLM_Engine["language"],
			Slug . " must not partially publish an earlier valid option")
		AssertEqual(Baseline, _LLM_Engine[Key],
			Slug . " must retain the exact seeded container")
	} finally {
		_LLM_Engine["enabled"] := SavedEnabled
		_LLM_Engine["language"] := SavedLanguage
		_LLM_Engine[Key] := SavedTarget
	}
}

_EngineInit_RejectsCompositeUserProfile() {
	_EngineInit_AssertCompositeContainerRejected(
		"user_profiles", [["bad"]], [], "composite user profile")
}
Test("LLM_Engine_Init: composite user profile is rejected atomically "
	. "(llm-persisted-option-type-boundary-engine-user-profiles)",
	_EngineInit_RejectsCompositeUserProfile)

_EngineInit_RejectsCompositeApiEntry() {
	_EngineInit_AssertCompositeContainerRejected(
		"api_entries", [["bad"]], [], "composite API entry")
}
Test("LLM_Engine_Init: composite API entry is rejected atomically "
	. "(llm-persisted-option-type-boundary-engine-api-entries)",
	_EngineInit_RejectsCompositeApiEntry)

_EngineInit_RejectsCompositeAppOverride() {
	_EngineInit_AssertCompositeContainerRejected(
		"app_profile_overrides", Map("notepad", []), Map(),
		"composite app-profile override")
}
Test("LLM_Engine_Init: composite app override is rejected atomically "
	. "(llm-persisted-option-type-boundary-engine-app-overrides)",
	_EngineInit_RejectsCompositeAppOverride)

_EngineInit_AcceptsManifestNumericRepresentations() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	try {
		_LLM_Engine := SavedEngine.Clone()
		LLM_Engine_Init(Map("n_predictions", 3.0, "temperature", 0.25))
		AssertEqual(3, _LLM_Engine["n_predictions"],
			"an integral manifest number must normalize to the engine integer")
		AssertEqual("0.25", _LLM_Engine["temperature"],
			"a numeric manifest temperature must normalize to the engine string")
	} finally {
		_LLM_Engine := SavedEngine
	}
}
Test("LLM_Engine_Init: valid manifest numeric representations remain accepted "
	. "(llm-persisted-option-type-boundary-engine-valid-number)",
	_EngineInit_AcceptsManifestNumericRepresentations)

_EngineFinalize_ReadinessState(Backend, RequestId, Signature) {
	return Map(
		"request_id", RequestId,
		"semantic_signature", Signature,
		"slots", ["suggestion"],
		"requested", 1,
		"dedup_stats", Map("candidates", 1, "duplicates", 0, "kept", 1),
		"model", "model",
		"backend", Backend,
		"ctx", "context",
		"system_prompt", "system",
		"is_batch", false,
		"request_start", 0
	)
}

_EngineFinalize_ReadyFlagBelongsToOllama() {
	global _LLM_Engine, _LLM_Ollama_IsReady, _Stub_LlmTooltipCalls
	SavedEngine := _LLM_Engine
	SavedReady := _LLM_Ollama_IsReady
	SavedTooltipCalls := _Stub_LlmTooltipCalls
	try {
		RequestId := 731
		Signature := "readiness-owner-signature"
		_LLM_Engine := SavedEngine.Clone()
		_LLM_Engine["request_id"] := RequestId
		_LLM_Engine["active_request_signature"] := Signature
		_LLM_Engine["inline_autotype"] := false
		_Stub_LlmTooltipCalls := []

		_LLM_Ollama_IsReady := false
		_LLM_Engine_FinalizeRequest(
			_EngineFinalize_ReadinessState("api", RequestId, Signature))
		AssertFalse(_LLM_Ollama_IsReady,
			"(ahk2-13-backend-readiness-owner) remote API success must not publish Ollama readiness")
		AssertEqual(1, _Stub_LlmTooltipCalls.Length,
			"(ahk2-13-backend-readiness-owner) the remote control must still complete its ordinary final render")

		_LLM_Ollama_IsReady := false
		_LLM_Engine_FinalizeRequest(
			_EngineFinalize_ReadinessState("ollama", RequestId, Signature))
		AssertTrue(_LLM_Ollama_IsReady,
			"(ahk2-13-backend-readiness-owner) Ollama success still owns its readiness publication")
		AssertEqual(2, _Stub_LlmTooltipCalls.Length,
			"(ahk2-13-backend-readiness-owner) both backend controls must reach the common finalizer")
	} finally {
		_LLM_Engine := SavedEngine
		_LLM_Ollama_IsReady := SavedReady
		_Stub_LlmTooltipCalls := SavedTooltipCalls
	}
}
Test("LLM finalizer: Ollama readiness remains backend-owned (ahk2-13-backend-readiness-owner)",
	_EngineFinalize_ReadyFlagBelongsToOllama)

_EngineTypedRestoreFeedsValidatedAppFilter() {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_Engine
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	SavedEngine := _LLM_Engine
	try {
		_LLM_Menu := _LLM_Menu.Clone()
		_LLM_Engine := SavedEngine.Clone()
		_LLM_Menu["disabled_apps"] := []
		_LLM_Menu["n_predictions"] := 3
		_LLM_Menu["show_info_bar"] := true
		_LLM_Menu["app_profile_overrides"] := Map("safe", "basic")
		_LLM_Menu_Loaded := false
		AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(Map(
			"disabled_apps", [" Notepad.EXE "],
			"n_predictions", [[99]],
			"show_info_bar", [[false]],
			"app_profile_overrides", Map("notepad", []))))
		AssertEqual(3, _LLM_Menu["n_predictions"],
			"invalid numeric restore must retain the menu default")
		AssertTrue(_LLM_Menu["show_info_bar"],
			"invalid boolean restore must retain the menu default")
		AssertEqual("notepad.exe", _LLM_Menu["disabled_apps"][1],
			"valid app exclusions must be normalized during restore")
		AssertEqual("basic", _LLM_Menu["app_profile_overrides"]["safe"],
			"invalid override values must retain the validated menu default")

		LLM_Engine_Init(Map("disabled_apps", _LLM_Menu["disabled_apps"]))
		FocusCalls := 0
		FocusFn := (*) => (FocusCalls += 1, Map("appId", "Notepad.EXE"))
		AssertTrue(_LLM_Engine_ShouldSuppressForDisabledApps(FocusFn),
			"the production privacy decision must suppress the restored app")
		AssertEqual(1, FocusCalls,
			"a nonempty validated exclusion list must resolve focus exactly once")
		AllowedCalls := 0
		AllowedFocusFn := (*) => (AllowedCalls += 1, Map("appId", "wordpad.exe"))
		AssertFalse(_LLM_Engine_ShouldSuppressForDisabledApps(AllowedFocusFn),
			"a non-excluded focused app must remain eligible for predictions")
		AssertEqual(1, AllowedCalls,
			"a nonempty exclusion list must resolve an allowed focus exactly once")
		_LLM_Engine["disabled_apps"] := []
		EmptyCalls := 0
		EmptyFocusFn := (*) => (EmptyCalls += 1, Map("appId", "notepad.exe"))
		AssertFalse(_LLM_Engine_ShouldSuppressForDisabledApps(EmptyFocusFn),
			"an empty exclusion list must not suppress predictions")
		AssertEqual(0, EmptyCalls,
			"an empty exclusion list must avoid the focus lookup entirely")
		_LLM_Engine["disabled_apps"] := Map("corrupt", true)
		AssertTrue(_LLM_Engine_ShouldSuppressForDisabledApps(FocusFn),
			"corrupt internal exclusion state must fail closed")
		AssertEqual(1, FocusCalls,
			"invalid internal state must be rejected before any focus query")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
		_LLM_Engine := SavedEngine
	}
}
Test("LLM options: typed restore reaches the production app filter "
	. "(llm-persisted-option-type-boundary-restore-engine-filter)",
	_EngineTypedRestoreFeedsValidatedAppFilter)

_AuditAhk006_ThrowingFocusResolver(*) {
	throw Error("injected focus failure")
}

_AuditAhk006_DisabledAppPolicyFailsClosedOnUnknownFocus() {
	global _LLM_Engine
	SavedEngine := _LLM_Engine
	try {
		_LLM_Engine := Map("disabled_apps", ["notepad.exe"])
		for Fixture in [
			["empty map", (*) => Map()],
			["empty identity", (*) => Map("appId", "")],
			["malformed result", (*) => "not-a-focus-map"],
			["malformed identity", (*) => Map("appId", [])],
			["throwing resolver", _AuditAhk006_ThrowingFocusResolver]
		] {
			AssertTrue(_LLM_Engine_ShouldSuppressForDisabledApps(Fixture[2]),
				Fixture[1] . " must suppress while a disabled-app policy is configured")
		}

		_LLM_Engine := Map("disabled_apps", ["notepad.exe"])
		MutatingResolver := (*) => (
			_LLM_Engine["disabled_apps"] := [],
			Map("appId", "notepad.exe"))
		AssertTrue(_LLM_Engine_ShouldSuppressForDisabledApps(MutatingResolver),
			"a focus callback must not replace the policy snapshot used by its own decision")

		_LLM_Engine := Map("disabled_apps", [])
		Calls := 0
		AssertFalse(_LLM_Engine_ShouldSuppressForDisabledApps(
			(*) => (Calls += 1, Map("appId", "notepad.exe"))),
			"an empty policy must keep predictions enabled")
		AssertEqual(0, Calls,
			"an empty policy must not resolve focus")
	} finally {
		_LLM_Engine := SavedEngine
	}
}

Test("LLM privacy: disabled-app policy rejects uncertain focus (audit-ahk-006)",
	_AuditAhk006_DisabledAppPolicyFailsClosedOnUnknownFocus)
