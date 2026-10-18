; tests/unit/modules/llm/prediction/test_llm_prediction_engine_state.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine State and Cache
; DESCRIPTION:
; The prediction engine's enable switch, timer cancellation, keystroke
; handling, batch splitting, retry bound, profile and API entry resolution,
; request-id generations, cache hits and tooltip placeholders.
; ==============================================================================

#Requires AutoHotkey v2.0





_EngineSetEnabled_DisablesEngine() {
	global _LLM_Engine
	LLM_Engine_Init(Map())
	; These cases exercise the cache and debounce paths, not the privacy gate.
	; State the posture explicitly: the shared default now BLOCKS secure fields,
	; and the production gate fails closed when the detector cannot answer —
	; which is always the case in a headless harness, so every prediction would
	; be suppressed and these tests would assert nothing about their own subject.
	_LLM_Engine["disable_password_fields"] := false
	LLM_Engine_SetEnabled(false)
	AssertFalse(_LLM_Engine["enabled"])
}
Test("LLM_Engine_SetEnabled: sets enabled to false", _EngineSetEnabled_DisablesEngine)


_EngineSetEnabled_EnablesEngine() {
	global _LLM_Engine
	_LLM_Engine["enabled"] := false
	LLM_Engine_SetEnabled(true)
	AssertTrue(_LLM_Engine["enabled"])
}
Test("LLM_Engine_SetEnabled: sets enabled to true", _EngineSetEnabled_EnablesEngine)


_EngineSetEnabled_CancelsTimerOnDisable() {
	global _LLM_Engine
	; Arm a fake timer marker, then disable — timer_active must be cleared
	LLM_Engine_Init(Map())
	; These cases exercise the cache and debounce paths, not the privacy gate.
	; State the posture explicitly: the shared default now BLOCKS secure fields,
	; and the production gate fails closed when the detector cannot answer —
	; which is always the case in a headless harness, so every prediction would
	; be suppressed and these tests would assert nothing about their own subject.
	_LLM_Engine["disable_password_fields"] := false
	_LLM_Engine["timer_active"] := true
	_LLM_Engine["pending_timer"] := ""   ; no real timer object, just the flag
	LLM_Engine_SetEnabled(false)
	AssertFalse(_LLM_Engine["timer_active"])
}
Test("LLM_Engine_SetEnabled: clears timer_active when disabling", _EngineSetEnabled_CancelsTimerOnDisable)




; =============================================
; =============================================
; ======= 3/ LLM_Engine_CancelTimer ===========
; =============================================
; =============================================

_EngineCancelTimer_ClearsFlag() {
	global _LLM_Engine
	_LLM_Engine["timer_active"] := true
	_LLM_Engine["pending_timer"] := ""
	LLM_Engine_CancelTimer()
	AssertFalse(_LLM_Engine["timer_active"])
}
Test("LLM_Engine_CancelTimer: clears timer_active flag", _EngineCancelTimer_ClearsFlag)


_EngineCancelTimer_ClearsPendingTimer() {
	global _LLM_Engine
	_LLM_Engine["timer_active"]  := true
	_LLM_Engine["pending_timer"] := "fake_ref"
	LLM_Engine_CancelTimer()
	AssertEqual("", _LLM_Engine["pending_timer"])
}
Test("LLM_Engine_CancelTimer: clears pending_timer reference", _EngineCancelTimer_ClearsPendingTimer)

; ULTIMATE encore plus: pause on every engine path + diagnostic integration + volume + pcall/errors to sink (for 100% certainty on the enriched healthcheck).
; Silence is implemented by the `enabled` flag, which the suspend handler clears
; — not by an A_IsSuspended read inside the engine. Assert the mechanism that
; actually exists: with enabled false, OnKeystroke arms nothing at all. A timer
; armed here fires an HTTP request and types into the user's document, so
; "returns early" has to mean "left no timer behind".
_EnginePauseSilencesAndDiagnosticSeesState() {
	global _LLM_Engine
	LLM_Engine_Init(Map("model", "test"))

	_LLM_Engine["enabled"] := false
	_LLM_Engine["pending_timer"] := ""
	_LLM_Engine["timer_active"] := false
	_LLM_Engine["last_buffer"] := ""

	LLM_Engine_OnKeystroke("bonjour")

	AssertEqual("", _LLM_Engine["pending_timer"],
		"a disabled engine must not arm a prediction timer — that timer fires an HTTP request "
		. "and types into the user's document")
	AssertFalse(_LLM_Engine["timer_active"], "and must not mark itself active")
	AssertEqual("", _LLM_Engine["last_buffer"],
		"nor record the keystroke buffer, which is what the prompt is built from")

	; Re-enabled, the very same call does arm — so the assertion above is about the
	; gate, not about a keystroke that never reached the engine.
	_LLM_Engine["enabled"] := true
	LLM_Engine_OnKeystroke("bonjour")
	AssertEqual("bonjour", _LLM_Engine["last_buffer"],
		"an enabled engine must record the buffer — otherwise the check above proves nothing")
	LLM_Engine_CancelTimer()
}
Test("LLM Prediction Engine: pause must silence OnKeystroke/Fire/timers + diagnostic must still see llm state + errors sink", _EnginePauseSilencesAndDiagnosticSeesState)

; Every keystroke cancels the in-flight request before re-arming. Two hundred of
; them must therefore leave exactly ONE armed timer, not two hundred: a leak here
; is what kept the "génération en cours" spinner alive and queued stale work
; behind Ollama's single slot for seconds after the user stopped typing.
_EngineHighVolumePcallBackendToErrorsSinkUnderPause() {
	global _LLM_Engine
	LLM_Engine_Init(Map("model", "test"))

	Loop 200 {
		LLM_Engine_OnKeystroke("a" . A_Index)
	}

	AssertTrue(_LLM_Engine["timer_active"],
		"after a burst the engine must hold exactly one armed timer")
	AssertEqual("a200", _LLM_Engine["last_buffer"],
		"and it must be the LAST buffer — an earlier one would predict against text the user "
		. "has already typed past")

	; Cancelling once is enough, because there is only ever one.
	LLM_Engine_CancelTimer()
	AssertFalse(_LLM_Engine["timer_active"],
		"a single cancel must clear the whole burst — 200 surviving timers would each fire an "
		. "HTTP request")
	AssertEqual("", _LLM_Engine["pending_timer"], "and drop the timer reference")
}
Test("LLM Prediction Engine: high volume (200+) + pcall backend ERROR to errors sink under pause; diagnostic visibility", _EngineHighVolumePcallBackendToErrorsSinkUnderPause)



_EngineCancelTimer_NoOpWhenInactive() {
	global _LLM_Engine
	_LLM_Engine["timer_active"] := false
	; Must not throw
	LLM_Engine_CancelTimer()
	AssertFalse(_LLM_Engine["timer_active"])
}
Test("LLM_Engine_CancelTimer: no-op when timer is not active", _EngineCancelTimer_NoOpWhenInactive)




; ================================================
; ================================================
; ======= 4/ LLM_Engine_OnKeystroke ==============
; ================================================
; ================================================

_EngineOnKeystroke_ArmsTimer() {
	global _LLM_Engine
	LLM_Engine_Init(Map("debounce_ms", 9999))
	LLM_Engine_OnKeystroke("hello ")
	AssertTrue(_LLM_Engine["timer_active"])
	; Clean up
	LLM_Engine_CancelTimer()
}
Test("LLM_Engine_OnKeystroke: arms debounce timer", _EngineOnKeystroke_ArmsTimer)


_EngineOnKeystroke_StoresBuffer() {
	global _LLM_Engine
	LLM_Engine_Init(Map("ctx_chars", 500, "debounce_ms", 9999))
	LLM_Engine_OnKeystroke("test context")
	AssertEqual("test context", _LLM_Engine["last_buffer"])
	LLM_Engine_CancelTimer()
}
Test("LLM_Engine_OnKeystroke: stores full buffer in last_buffer", _EngineOnKeystroke_StoresBuffer)


_EngineOnKeystroke_KeepsFullBuffer() {
	global _LLM_Engine
	InputText := "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ"
	LLM_Engine_Init(Map("ctx_chars", 50, "debounce_ms", 9999))
	LLM_Engine_OnKeystroke(InputText)
	; Truncation happens in PromptBuilder at fire time, not on each keystroke.
	AssertEqual(InputText, _LLM_Engine["last_buffer"])
	LLM_Engine_CancelTimer()
}
Test("LLM_Engine_OnKeystroke: keeps full buffer (ctx cap applied at fire)", _EngineOnKeystroke_KeepsFullBuffer)


_EngineOnKeystroke_NoOpWhenDisabled() {
	global _LLM_Engine
	LLM_Engine_SetEnabled(false)
	_LLM_Engine["last_ctx"] := "before"
	LLM_Engine_OnKeystroke("new text")
	; Context should NOT be updated when engine is disabled
	AssertEqual("before", _LLM_Engine["last_ctx"])
	LLM_Engine_SetEnabled(true)
}
Test("LLM_Engine_OnKeystroke: no-op when engine is disabled", _EngineOnKeystroke_NoOpWhenDisabled)




; =========================================================
; =========================================================
; ======= 5/ _LLM_Engine_SplitBatchBlocks =================
; =========================================================
; =========================================================

_SplitBatch_SingleBlock() {
	blocks := _LLM_Engine_SplitBatchBlocks("hello world")
	AssertEqual(1, blocks.Length)
	AssertEqual("hello world", blocks[1])
}
Test("_LLM_Engine_SplitBatchBlocks: single block with no separator", _SplitBatch_SingleBlock)


_SplitBatch_TwoBlocks() {
	blocks := _LLM_Engine_SplitBatchBlocks("first===second")
	AssertEqual(2, blocks.Length)
	AssertEqual("first",  blocks[1])
	AssertEqual("second", blocks[2])
}
Test("_LLM_Engine_SplitBatchBlocks: splits on === separator", _SplitBatch_TwoBlocks)


_SplitBatch_ThreeBlocks() {
	blocks := _LLM_Engine_SplitBatchBlocks("A===B===C")
	AssertEqual(3, blocks.Length)
	AssertEqual("A", blocks[1])
	AssertEqual("B", blocks[2])
	AssertEqual("C", blocks[3])
}
Test("_LLM_Engine_SplitBatchBlocks: splits three blocks", _SplitBatch_ThreeBlocks)


_SplitBatch_TrimsWhitespace() {
	blocks := _LLM_Engine_SplitBatchBlocks("  first  ===  second  ")
	AssertEqual(2, blocks.Length)
	AssertEqual("first",  blocks[1])
	AssertEqual("second", blocks[2])
}
Test("_LLM_Engine_SplitBatchBlocks: trims whitespace from each block", _SplitBatch_TrimsWhitespace)


_SplitBatch_EmptyBlocksDropped() {
	blocks := _LLM_Engine_SplitBatchBlocks("first======second")
	; "first", empty (dropped), "second"
	AssertEqual(2, blocks.Length)
	AssertEqual("first",  blocks[1])
	AssertEqual("second", blocks[2])
}
Test("_LLM_Engine_SplitBatchBlocks: empty blocks between separators are dropped", _SplitBatch_EmptyBlocksDropped)


_SplitBatch_EmptyInputReturnsEmpty() {
	blocks := _LLM_Engine_SplitBatchBlocks("")
	AssertEqual(0, blocks.Length)
}
Test("_LLM_Engine_SplitBatchBlocks: empty input returns empty array", _SplitBatch_EmptyInputReturnsEmpty)


_SplitBatch_MultilineBlockPreserved() {
	raw := "line1`nline2===line3"
	blocks := _LLM_Engine_SplitBatchBlocks(raw)
	AssertEqual(2, blocks.Length)
	AssertContains(blocks[1], "line1")
	AssertContains(blocks[1], "line2")
}
Test("_LLM_Engine_SplitBatchBlocks: multiline block is preserved as one block", _SplitBatch_MultilineBlockPreserved)


_SplitBatch_MaxCountCap() {
	; A hallucinating model that emits 20 "===" separators must not flood the
	; tooltip with 20 blocks when n_predictions = 3 (llm-split-batch-no-cap).
	raw := "A===B===C===D===E===F===G===H===I===J===K===L===M===N===O===P===Q===R===S===T"
	; Without cap: all 20 blocks
	all_blocks := _LLM_Engine_SplitBatchBlocks(raw)
	Assert(all_blocks.Length > 5,
		"Without cap, SplitBatchBlocks must return all blocks from a long hallucination")
	; With cap of 3: exactly 3 blocks
	capped := _LLM_Engine_SplitBatchBlocks(raw, 3)
	AssertEqual(3, capped.Length)
	AssertEqual("A", capped[1])
	AssertEqual("B", capped[2])
	AssertEqual("C", capped[3])
}
Test("_LLM_Engine_SplitBatchBlocks: max_count cap stops parsing after N blocks (llm-split-batch-no-cap)", _SplitBatch_MaxCountCap)


_SplitBatch_MaxCountZeroMeansUnlimited() {
	; max_count = 0 (the default) must NOT limit output
	raw := "A===B===C===D===E"
	blocks := _LLM_Engine_SplitBatchBlocks(raw, 0)
	AssertEqual(5, blocks.Length)
}
Test("_LLM_Engine_SplitBatchBlocks: max_count=0 is unlimited (default behaviour preserved)", _SplitBatch_MaxCountZeroMeansUnlimited)




; =====================================================
; =====================================================
; ======= 6/ _LLM_Engine_MaxAttempts ==================
; =====================================================
; =====================================================

_MaxAttempts_AtLeastN() {
	; Regardless of the retry policy, max attempts must be >= n
	result := _LLM_Engine_MaxAttempts(3)
	Assert(result >= 3, "max_attempts must be >= n_predictions")
}
Test("_LLM_Engine_MaxAttempts: result is at least n", _MaxAttempts_AtLeastN)


_MaxAttempts_PositiveForOne() {
	result := _LLM_Engine_MaxAttempts(1)
	Assert(result >= 1, "max_attempts must be >= 1 for n=1")
}
Test("_LLM_Engine_MaxAttempts: returns at least 1 for n=1", _MaxAttempts_PositiveForOne)


_MaxAttempts_ScalesWithN() {
	r1 := _LLM_Engine_MaxAttempts(1)
	r3 := _LLM_Engine_MaxAttempts(3)
	Assert(r3 >= r1, "max_attempts must be non-decreasing with n")
}
Test("_LLM_Engine_MaxAttempts: scales up with larger n", _MaxAttempts_ScalesWithN)




; ===========================================================
; ===========================================================
; ======= 7/ _LLM_Engine_ResolveProfileIdForApp =============
; ===========================================================
; ===========================================================

_ResolveProfileForApp_ReturnsDefaultWhenNoOverrides() {
	global _LLM_Engine
	; The absent key is this case's fixture; the engine's own map returns for
	; the tests that read it afterwards.
	HadOverrides := _LLM_Engine.Has("app_profile_overrides")
	SavedOverrides := HadOverrides ? _LLM_Engine["app_profile_overrides"] : ""
	try {
		if HadOverrides
			_LLM_Engine.Delete("app_profile_overrides")
		result := _LLM_Engine_ResolveProfileIdForApp("basic")
		AssertEqual("basic", result)
	} finally {
		if HadOverrides
			_LLM_Engine["app_profile_overrides"] := SavedOverrides
		else if _LLM_Engine.Has("app_profile_overrides")
			_LLM_Engine.Delete("app_profile_overrides")
	}
}
Test("_LLM_Engine_ResolveProfileIdForApp: returns default when no overrides map", _ResolveProfileForApp_ReturnsDefaultWhenNoOverrides)


_ResolveProfileForApp_ReturnsDefaultForEmptyMap() {
	global _LLM_Engine
	HadOverrides := _LLM_Engine.Has("app_profile_overrides")
	SavedOverrides := HadOverrides ? _LLM_Engine["app_profile_overrides"] : ""
	try {
		_LLM_Engine["app_profile_overrides"] := Map()
		result := _LLM_Engine_ResolveProfileIdForApp("basic")
		AssertEqual("basic", result)
	} finally {
		if HadOverrides
			_LLM_Engine["app_profile_overrides"] := SavedOverrides
		else
			_LLM_Engine.Delete("app_profile_overrides")
	}
}
Test("_LLM_Engine_ResolveProfileIdForApp: returns default when overrides map is empty", _ResolveProfileForApp_ReturnsDefaultForEmptyMap)




; ===========================================================
; ===========================================================
; ======= 8/ _LLM_Engine_GetActiveApiEntry ==================
; ===========================================================
; ===========================================================

_GetActiveEntry_EmptyWhenNoEntries() {
	global _LLM_Engine
	_LLM_Engine["api_entries"] := []
	_LLM_Engine["api_entry_id"] := ""
	result := _LLM_Engine_GetActiveApiEntry()
	AssertEqual("", result)
}
Test("_LLM_Engine_GetActiveApiEntry: returns empty when api_entries is empty", _GetActiveEntry_EmptyWhenNoEntries)


_GetActiveEntry_FallsBackToFirst() {
	global _LLM_Engine
	e1 := Map("Id", "e1", "Provider", "openai", "Token", "t", "Model", "m")
	_LLM_Engine["api_entries"] := [e1]
	_LLM_Engine["api_entry_id"] := ""   ; no selection — must fall back to first
	result := _LLM_Engine_GetActiveApiEntry()
	AssertFalse(result == "", "must return first entry as fallback")
	AssertEqual("e1", result["Id"])
}
Test("_LLM_Engine_GetActiveApiEntry: falls back to first entry when no id selected", _GetActiveEntry_FallsBackToFirst)


_GetActiveEntry_ReturnsMatchedEntry() {
	global _LLM_Engine
	e1 := Map("Id", "e1", "Provider", "openai", "Token", "t1", "Model", "m1")
	e2 := Map("Id", "e2", "Provider", "anthropic", "Token", "t2", "Model", "m2")
	_LLM_Engine["api_entries"] := [e1, e2]
	_LLM_Engine["api_entry_id"] := "e2"
	result := _LLM_Engine_GetActiveApiEntry()
	AssertEqual("e2", result["Id"])
	AssertEqual("anthropic", result["Provider"])
}
Test("_LLM_Engine_GetActiveApiEntry: returns entry matching api_entry_id", _GetActiveEntry_ReturnsMatchedEntry)


_GetActiveEntry_RejectsDuplicateIdentity() {
	global _LLM_Engine
	e1 := Map("Id", "duplicate", "Provider", "openai", "Token", "t1", "Model", "m1")
	e2 := Map("Id", "duplicate", "Provider", "anthropic", "Token", "t2", "Model", "m2")
	_LLM_Engine["api_entries"] := [e1, e2]
	_LLM_Engine["api_entry_id"] := "duplicate"
	AssertEqual("", _LLM_Engine_GetActiveApiEntry(),
		"an ambiguous durable identity must fail closed instead of choosing the first credential")
}
Test("_LLM_Engine_GetActiveApiEntry: rejects duplicate identities "
	. "(api-entry-identity-cardinality)",
	_GetActiveEntry_RejectsDuplicateIdentity)


_GetActiveEntry_FallsBackToFirstOnUnknownId() {
	global _LLM_Engine
	e1 := Map("Id", "e1", "Provider", "openai", "Token", "t", "Model", "m")
	_LLM_Engine["api_entries"] := [e1]
	_LLM_Engine["api_entry_id"] := "nonexistent_id"
	result := _LLM_Engine_GetActiveApiEntry()
	AssertEqual("e1", result["Id"])
}
Test("_LLM_Engine_GetActiveApiEntry: falls back to first entry when active id not found", _GetActiveEntry_FallsBackToFirstOnUnknownId)




; ===========================================================================
; ===========================================================================
; ======= 9/ Request-id generation counter (cache invalidation) =============
; ===========================================================================
; ===========================================================================

_RequestId_BumpsOnFirePrediction() {
	global _LLM_Engine, _LLM_Ollama_IsReady
	; Enable inference so FirePrediction gets past the warmup guard
	_LLM_Ollama_IsReady := true
	; Disable so FirePrediction returns early without touching HTTP
	LLM_Engine_Init(Map("debounce_ms", 9999))
	LLM_Engine_SetEnabled(false)
	before := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	; Enable just long enough to get past the guard, then call directly
	LLM_Engine_SetEnabled(true)
	; The password-field gate defaults on and fails closed without a focused
	; field; this test is about the request id, so it owns that precondition
	; instead of inheriting it from an earlier test.
	_LLM_Engine["disable_password_fields"] := false
	; Seed a stale cache so FirePrediction does NOT enter the cache-hit path
	_LLM_Engine["last_ctx"]     := "different ctx"
	_LLM_Engine["last_results"] := []
	; Stub out functions called by FirePrediction that would touch the OS
	LLM_Engine_FirePrediction("new ctx")
	after := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	Assert(after > before, "request_id must have been bumped")
}
Test("LLM_Engine_FirePrediction: bumps request_id on each new fire", _RequestId_BumpsOnFirePrediction)


_RequestId_InitialisesAtZero() {
	global _LLM_Engine
	; The default map initialises request_id to 0 before any Init/Fire
	_LLM_Engine["request_id"] := 0
	AssertEqual(0, _LLM_Engine["request_id"])
}
Test("_LLM_Engine: request_id is initialised at 0", _RequestId_InitialisesAtZero)




; ===================================================
; ===================================================
; ======= 10/ Cache hit logic ========================
; ===================================================
; ===================================================

_CacheHit_ExactMatchReturnsCachedResults() {
	global _LLM_Engine, _LLM_Ollama_IsReady
	_LLM_Ollama_IsReady := true
	; Seed the cache with a known context and results
	LLM_Engine_Init(Map("app_profile_overrides", Map()))
	; These cases exercise the cache and debounce paths, not the privacy gate.
	; State the posture explicitly: the shared default now BLOCKS secure fields,
	; and the production gate fails closed when the detector cannot answer —
	; which is always the case in a headless harness, so every prediction would
	; be suppressed and these tests would assert nothing about their own subject.
	_LLM_Engine["disable_password_fields"] := false
	_LLM_Engine["last_ctx"]     := "intelligen"
	_LLM_Engine["last_results"] := ["intelligence", "intelligent"]
	_LLM_Engine["last_semantic_signature"] :=
		_LLM_Engine_RequestSemanticSignature(_LLM_Engine["profile_id"])
	id_before := _LLM_Engine["request_id"]
	; Fire with the exact same context — should hit cache and bump request_id
	LLM_Engine_FirePrediction("intelligen")
	; request_id must have been bumped (cache hit path bumps it to kill stale callbacks)
	AssertTrue(_LLM_Engine["request_id"] > id_before, "request_id must be bumped on cache hit")
}
Test("LLM_Engine_FirePrediction: exact cache hit bumps request_id", _CacheHit_ExactMatchReturnsCachedResults)


_CacheHit_PrefixMatchSlicesResults() {
	global _LLM_Engine, _LLM_Ollama_IsReady
	_LLM_Ollama_IsReady := true
	; Cache: context "intelligen", predicted suffix "ce alone" (starts with "ce ").
	; Firing with ctx="intelligence " gives typed_delta="ce " which matches the
	; start of the cached slot — prefix-cache hits and slices to "alone".
	LLM_Engine_Init(Map("app_profile_overrides", Map()))
	; These cases exercise the cache and debounce paths, not the privacy gate.
	; State the posture explicitly: the shared default now BLOCKS secure fields,
	; and the production gate fails closed when the detector cannot answer —
	; which is always the case in a headless harness, so every prediction would
	; be suppressed and these tests would assert nothing about their own subject.
	_LLM_Engine["disable_password_fields"] := false
	_LLM_Engine["last_ctx"]     := "intelligen"
	_LLM_Engine["last_results"] := ["ce alone"]
	_LLM_Engine["last_semantic_signature"] :=
		_LLM_Engine_RequestSemanticSignature(_LLM_Engine["profile_id"])
	; Now fire with a context that extends the cache by "ce " — prefix match
	; should slice the cached prediction to the remaining suffix "alone"
	id_before := _LLM_Engine["request_id"]
	LLM_Engine_FirePrediction("intelligence ")
	; request_id must have been bumped (prefix-cache path)
	AssertTrue(_LLM_Engine["request_id"] > id_before, "request_id must be bumped on prefix cache hit")
}
Test("LLM_Engine_FirePrediction: prefix cache hit bumps request_id", _CacheHit_PrefixMatchSlicesResults)


_CacheHit_EmptyContextSkipsRequest() {
	global _LLM_Engine, _LLM_Ollama_IsReady
	_LLM_Ollama_IsReady := true
	LLM_Engine_Init(Map())
	; These cases exercise the cache and debounce paths, not the privacy gate.
	; State the posture explicitly: the shared default now BLOCKS secure fields,
	; and the production gate fails closed when the detector cannot answer —
	; which is always the case in a headless harness, so every prediction would
	; be suppressed and these tests would assert nothing about their own subject.
	_LLM_Engine["disable_password_fields"] := false
	id_before := _LLM_Engine["request_id"]
	; Empty context must return early without bumping request_id
	LLM_Engine_FirePrediction("")
	AssertEqual(id_before, _LLM_Engine["request_id"])
}
Test("LLM_Engine_FirePrediction: empty context returns early without bumping request_id", _CacheHit_EmptyContextSkipsRequest)

_FirePrediction_RearmsWhenOllamaNotReady() {
	global _LLM_Engine, _LLM_Ollama_IsReady, _LLM_Ollama_WarmupStartedTick
	PreviousCritical := Critical("On")
	SavedEngine := _LLM_Engine
	SavedReady := _LLM_Ollama_IsReady
	SavedWarmupTick := _LLM_Ollama_WarmupStartedTick
	try {
		_LLM_Engine := SavedEngine.Clone()
		_LLM_Ollama_IsReady := false
		_LLM_Ollama_WarmupStartedTick := Max(1, A_TickCount)
		LLM_Engine_Init(Map("backend", "ollama", "model", "Qwen3.5-0.8B",
			"debounce_ms", 500, "disable_password_fields", false,
			"disabled_apps", []))
		LLM_Engine_CancelTimer()
		LLM_Engine_FirePrediction("hello world context here")
		Assert(_LLM_Engine["timer_active"],
			"FirePrediction must re-arm debounce while Ollama warmup is pending")
		Assert(_LLM_Engine.Has("pending_timer")
			&& IsObject(_LLM_Engine["pending_timer"]),
			"pending_timer must be set for deferred retry")
	} finally {
		LLM_Engine_CancelTimer()
		_LLM_Engine := SavedEngine
		_LLM_Ollama_IsReady := SavedReady
		_LLM_Ollama_WarmupStartedTick := SavedWarmupTick
		Critical(PreviousCritical)
	}
}
Test("LLM_Engine_FirePrediction: re-arms timer when Ollama not ready",
	_FirePrediction_RearmsWhenOllamaNotReady)

_OllamaAllowInference_GraceAfterWarmupStart() {
	global _LLM_Ollama_IsReady, _LLM_Ollama_WarmupStartedTick
	_LLM_Ollama_IsReady := false
	_LLM_Ollama_WarmupStartedTick := A_TickCount - 10000
	AssertTrue(LLM_OllamaAllowInference(), "grace must allow inference 8s after warmup start")
	_LLM_Ollama_WarmupStartedTick := 0
}
Test("LLM_OllamaAllowInference: grace period after warmup start",
	_OllamaAllowInference_GraceAfterWarmupStart)

_FirePrediction_DoesNotCancelOllamaAsync() {
	global _LLM_Engine, _LLM_Ollama_Async, _LLM_Ollama_IsReady
	_LLM_Ollama_IsReady := true
	; Init first so the backend-change guard in LLM_Engine_Init fires LLM_Engine_
	; StopGeneration (which calls LLM_OllamaCancelAllAsync) on an EMPTY async map.
	; Seeding _LLM_Ollama_Async before Init caused the fake entry to be cancelled
	; by the backend-switch stop, not by FirePrediction — the test was catching the
	; wrong event.
	_LLM_Ollama_Async := Map()
	LLM_Engine_Init(Map("backend", "api", "api_entries", [], "debounce_ms", 500))
	_LLM_Engine["last_ctx"] := ""
	_LLM_Engine["last_results"] := []
	; Inject the fake in-flight WinHTTP entry AFTER Init so StopGeneration cannot
	; reach it — we are now testing only what FirePrediction does.
	fake_http := Map()
	_LLM_Ollama_Async[99] := Map("http", fake_http, "on_success", (*) => "", "on_fail", (*) => "",
		"cancelled", false)
	LLM_Engine_FirePrediction("enough context here for a real tail segment")
	AssertFalse(_LLM_Ollama_Async[99]["cancelled"],
		"FirePrediction must not cancel in-flight WinHTTP — request_id handles staleness")
	_LLM_Ollama_Async := Map()
}
Test("LLM_Engine_FirePrediction: does not cancel in-flight Ollama WinHTTP",
	_FirePrediction_DoesNotCancelOllamaAsync)
_OnVariantFail_FallsBackFromStreaming() {
	state := Map("request_id", 1, "semantic_signature", "variant-test", "streaming", true, "attempt_index", 2,
		"max_attempts", 4, "model", "qwen3.5:0.8b", "slots", [], "requested", 1,
		"dispatch_fn", (*) => "", "base_temp", 0.1, "ctx", "some context")
	global _LLM_Engine
	_LLM_Engine["request_id"] := 1
	_LLM_Engine["active_request_signature"] := "variant-test"
	_LLM_Engine_OnVariantFail(state)
	AssertFalse(state["streaming"], "streaming must be disabled after stream failure")
}

Test("LLM_Engine_OnVariantFail: disables streaming for WinHTTP retry",
	_OnVariantFail_FallsBackFromStreaming)

; ===================================================
; ===================================================
; ======= 11/ Tooltip Placeholders ==================
; ===================================================
; ===================================================

_LLM_TestSlotIsPlaceholder() {
	global UI_LLM_SLOT_PLACEHOLDER := "sparkle"
	global LLM_TOOLTIP_PLACEHOLDER := "sparkle"
	AssertTrue(_LLM_SlotIsPlaceholder(""), "empty string is placeholder")
	AssertTrue(_LLM_SlotIsPlaceholder("sparkle"), "exact match is placeholder")
	AssertTrue(_LLM_SlotIsPlaceholder("…"), "ellipsis is placeholder")
	AssertTrue(_LLM_SlotIsPlaceholder("..."), "dot-dot-dot is placeholder")
	AssertTrue(_LLM_SlotIsPlaceholder("   "), "whitespace is placeholder")
	AssertFalse(_LLM_SlotIsPlaceholder("real text"), "real text is not placeholder")
}
Test("_LLM_SlotIsPlaceholder: detects placeholder strings", _LLM_TestSlotIsPlaceholder)

_LLM_TestAllSlotsPlaceholder() {
	global UI_LLM_SLOT_PLACEHOLDER := "sparkle"
	global LLM_TOOLTIP_PLACEHOLDER := "sparkle"
	AssertTrue(_LLM_AllSlotsPlaceholder(["", "...", "sparkle"]), "all placeholders should return true")
	AssertFalse(_LLM_AllSlotsPlaceholder(["", "real text", "sparkle"]), "one real text should return false")
	AssertFalse(_LLM_AllSlotsPlaceholder([]), "empty array should return false")
}
Test("_LLM_AllSlotsPlaceholder: checks array of slots", _LLM_TestAllSlotsPlaceholder)
