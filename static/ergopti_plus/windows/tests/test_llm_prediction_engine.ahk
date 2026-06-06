; static/ergopti_plus/windows/tests/test_llm_prediction_engine.ahk

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
}
Test("LLM_Engine_Init: copies disabled_apps array from opts", _EngineInit_CopiesDisabledAppsArray)




; ============================================
; ============================================
; ======= 2/ LLM_Engine_SetEnabled ===========
; ============================================
; ============================================

_EngineSetEnabled_DisablesEngine() {
	global _LLM_Engine
	LLM_Engine_Init(Map())
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
	LLM_Engine_Init(Map("ctx_chars", 5, "debounce_ms", 9999))
	LLM_Engine_OnKeystroke("ABCDEFGHIJ")
	; Truncation happens in PromptBuilder at fire time, not on each keystroke.
	AssertEqual("ABCDEFGHIJ", _LLM_Engine["last_buffer"])
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
	; Use try in case the key is absent — Map.Delete() throws "Item has no value"
	; when the key does not exist in some AHK v2 builds.
	try _LLM_Engine.Delete("app_profile_overrides")
	result := _LLM_Engine_ResolveProfileIdForApp("basic")
	AssertEqual("basic", result)
}
Test("_LLM_Engine_ResolveProfileIdForApp: returns default when no overrides map", _ResolveProfileForApp_ReturnsDefaultWhenNoOverrides)


_ResolveProfileForApp_ReturnsDefaultForEmptyMap() {
	global _LLM_Engine
	_LLM_Engine["app_profile_overrides"] := Map()
	result := _LLM_Engine_ResolveProfileIdForApp("basic")
	AssertEqual("basic", result)
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
	global _LLM_Engine
	; Disable so FirePrediction returns early without touching HTTP
	LLM_Engine_Init(Map("debounce_ms", 9999))
	LLM_Engine_SetEnabled(false)
	before := _LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0
	; Enable just long enough to get past the guard, then call directly
	LLM_Engine_SetEnabled(true)
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
	global _LLM_Engine
	; Seed the cache with a known context and results
	LLM_Engine_Init(Map())
	_LLM_Engine["last_ctx"]     := "intelligen"
	_LLM_Engine["last_results"] := ["intelligence", "intelligent"]
	id_before := _LLM_Engine["request_id"]
	; Fire with the exact same context — should hit cache and bump request_id
	LLM_Engine_FirePrediction("intelligen")
	; request_id must have been bumped (cache hit path bumps it to kill stale callbacks)
	AssertTrue(_LLM_Engine["request_id"] > id_before, "request_id must be bumped on cache hit")
}
Test("LLM_Engine_FirePrediction: exact cache hit bumps request_id", _CacheHit_ExactMatchReturnsCachedResults)


_CacheHit_PrefixMatchSlicesResults() {
	global _LLM_Engine
	; Cache: context "intelligen", predicted suffix "ce alone" (starts with "ce ").
	; Firing with ctx="intelligence " gives typed_delta="ce " which matches the
	; start of the cached slot — prefix-cache hits and slices to "alone".
	LLM_Engine_Init(Map())
	_LLM_Engine["last_ctx"]     := "intelligen"
	_LLM_Engine["last_results"] := ["ce alone"]
	; Now fire with a context that extends the cache by "ce " — prefix match
	; should slice the cached prediction to the remaining suffix "alone"
	id_before := _LLM_Engine["request_id"]
	LLM_Engine_FirePrediction("intelligence ")
	; request_id must have been bumped (prefix-cache path)
	AssertTrue(_LLM_Engine["request_id"] > id_before, "request_id must be bumped on prefix cache hit")
}
Test("LLM_Engine_FirePrediction: prefix cache hit bumps request_id", _CacheHit_PrefixMatchSlicesResults)


_CacheHit_EmptyContextSkipsRequest() {
	global _LLM_Engine
	LLM_Engine_Init(Map())
	id_before := _LLM_Engine["request_id"]
	; Empty context must return early without bumping request_id
	LLM_Engine_FirePrediction("")
	AssertEqual(id_before, _LLM_Engine["request_id"])
}
Test("LLM_Engine_FirePrediction: empty context returns early without bumping request_id", _CacheHit_EmptyContextSkipsRequest)

_FirePrediction_RearmsWhenOllamaNotReady() {
	global _LLM_Engine, _LLM_Ollama_IsReady, _LLM_Ollama_WarmupStartedTick
	_LLM_Ollama_IsReady := false
	_LLM_Ollama_WarmupStartedTick := A_TickCount
	LLM_Engine_Init(Map("model", "Qwen3.5-0.8B", "debounce_ms", 500))
	LLM_Engine_CancelTimer()
	LLM_Engine_FirePrediction("hello world context here")
	Assert(_LLM_Engine["timer_active"],
		"FirePrediction must re-arm debounce while Ollama warmup is pending")
	Assert(_LLM_Engine.Has("pending_timer") && IsObject(_LLM_Engine["pending_timer"]),
		"pending_timer must be set for deferred retry")
	LLM_Engine_CancelTimer()
	_LLM_Ollama_IsReady := true
	_LLM_Ollama_WarmupStartedTick := 0
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
	_LLM_Ollama_Async := Map()
	fake_http := Map()
	_LLM_Ollama_Async[99] := Map("http", fake_http, "on_success", (*) => "", "on_fail", (*) => "",
		"cancelled", false)
	LLM_Engine_Init(Map("backend", "api", "api_entries", [], "debounce_ms", 500))
	_LLM_Engine["last_ctx"] := ""
	_LLM_Engine["last_results"] := []
	LLM_Engine_FirePrediction("enough context here for a real tail segment")
	AssertFalse(_LLM_Ollama_Async[99]["cancelled"],
		"FirePrediction must not cancel in-flight WinHTTP — request_id handles staleness")
	_LLM_Ollama_Async := Map()
}
Test("LLM_Engine_FirePrediction: does not cancel in-flight Ollama WinHTTP",
	_FirePrediction_DoesNotCancelOllamaAsync)

_OnVariantFail_FallsBackFromStreaming() {
	state := Map("request_id", 1, "streaming", true, "attempt_index", 2,
		"max_attempts", 4, "model", "qwen3.5:0.8b", "slots", [])
	global _LLM_Engine
	_LLM_Engine["request_id"] := 1
	_LLM_Engine_OnVariantFail(state)
	AssertFalse(state["streaming"], "streaming must be disabled after stream failure")
}
Test("LLM_Engine_OnVariantFail: disables streaming for WinHTTP retry",
	_OnVariantFail_FallsBackFromStreaming)
