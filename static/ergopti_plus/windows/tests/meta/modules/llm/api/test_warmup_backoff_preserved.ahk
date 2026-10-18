; tests/meta/modules/llm/api/test_warmup_backoff_preserved.ahk

; ==============================================================================
; MODULE: Warmup Backoff Preserved Meta Test
; DESCRIPTION:
; Static source guard for the "warmup backoff reset must be conditional"
; invariant (T-W05).
;
; LLM_OllamaCancelWarmupRetry() is called from two sites with different intent:
; 1. On warmup success — the caller passes reset_backoff := true so the next
;    warmup cycle starts from the base 5 s interval instead of the last
;    exponentially-grown interval.
; 2. On ordinary cancel (bridge stop, LLM feature toggled off, suspend) — no
;    argument is passed (reset_backoff defaults to false), so the accumulated
;    backoff is preserved across re-enables and Ollama is not hammered with
;    immediate retries.
;
; The bug would be an unconditional `_LLM_Ollama_WarmupRetryIntervalMs := 5000`
; at the top level of the function body, which would silently reset the backoff
; on every cancel call regardless of whether the warmup actually succeeded.
;
; This test asserts:
; 1. The function signature declares reset_backoff as a parameter.
; 2. The backoff assignment is inside a conditional on reset_backoff, never
;    at the unconditional top level of the function body.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================
; =============================
; ======= 1/ Assertions =======
; =============================
; =============================

_WBPG_CancelHasResetBackoffParam() {
	; Move-resilient: LLM_OllamaCancelWarmupRetry used to live directly in
	; modules/llm/api_ollama.ahk, but that file is now a thin #Include redirect
	; shim to api_ollama/ollama_warmup.ahk (post-split). _DriverFuncBody already
	; anchors on the column-0 DEFINITION line (never a call site) across the
	; whole driver, so it survives further file moves.
	DeclLine := _DriverFuncBody("LLM_OllamaCancelWarmupRetry")
	Assert(DeclLine != "",
		"LLM_OllamaCancelWarmupRetry definition must exist in the Ollama API module")
	Assert(InStr(DeclLine, "reset_backoff") > 0,
		"LLM_OllamaCancelWarmupRetry declaration must include the reset_backoff parameter "
		. "— callers rely on a default of false so that ordinary cancels do not reset "
		. "the exponential backoff interval")
}
Test("api_ollama: LLM_OllamaCancelWarmupRetry has reset_backoff parameter",
	_WBPG_CancelHasResetBackoffParam)

_WBPG_BackoffResetIsConditional() {
	Body := _DriverFuncBody("LLM_OllamaCancelWarmupRetry")
	Assert(Body != "",
		"LLM_OllamaCancelWarmupRetry body must be extractable from the Ollama API module")

	; The backoff reset assignment must be present somewhere in the body
	AssignPos := InStr(Body, "_LLM_Ollama_WarmupRetryIntervalMs := 5000")
	Assert(AssignPos > 0,
		"LLM_OllamaCancelWarmupRetry must assign _LLM_Ollama_WarmupRetryIntervalMs := 5000 "
		. "to reset the backoff interval for callers that pass reset_backoff := true")

	; The conditional guard (`if reset_backoff` or `if (reset_backoff)`) must
	; appear before the assignment — the assignment is only reached through it
	GuardPos1 := InStr(Body, "if reset_backoff")
	GuardPos2 := InStr(Body, "if (reset_backoff)")
	GuardPos := (GuardPos1 > 0 && (GuardPos2 == 0 || GuardPos1 < GuardPos2))
		? GuardPos1 : GuardPos2
	Assert(GuardPos > 0,
		"LLM_OllamaCancelWarmupRetry must guard the backoff reset with "
		. "`if reset_backoff` or `if (reset_backoff)` — an unconditional reset "
		. "discards the exponential backoff on every cancel call, including "
		. "LLM_Bridge_Stop and suspend, causing the server to be hammered with "
		. "immediate retries on every re-enable")
	Assert(GuardPos < AssignPos,
		"the `if reset_backoff` guard (offset " . GuardPos . ") must precede "
		. "the _LLM_Ollama_WarmupRetryIntervalMs assignment (offset " . AssignPos . ") "
		. "— the assignment must be inside the conditional block, not at the top level")
}
Test("api_ollama: backoff reset is conditional on reset_backoff parameter",
	_WBPG_BackoffResetIsConditional)

; F-12  LLM_OllamaCancelWarmupRetry never bumped _LLM_Ollama_WarmupGeneration.
; The counter moved only on the START path, so the gen guard in the
; completion callbacks could not invalidate anything a RESET was meant to
; invalidate. The poll chain re-arms from an anonymous closure with no
; cancel handle, so bumping the generation is the only way a cancel can
_A0720B2_WarmupCancelBumpsGeneration() {
	Body := _DriverFuncBody("LLM_OllamaCancelWarmupRetry")
	Assert(Body != "", "LLM_OllamaCancelWarmupRetry must exist")
	Assert(InStr(Body, "_LLM_Ollama_WarmupGeneration += 1") > 0,
		"LLM_OllamaCancelWarmupRetry must bump _LLM_Ollama_WarmupGeneration — a counter incremented only on the START path can never invalidate a RESET, and the warmup poll chain re-arms from an anonymous closure with no cancel handle, so this bump is the only thing stopping a late response from setting _LLM_Ollama_IsReady and resetting the backoff ramp after the user paused")
	Assert(InStr(Body, "global") > 0 and InStr(Body, "_LLM_Ollama_WarmupGeneration") > 0,
		"_LLM_Ollama_WarmupGeneration must be declared global in the cancel function, or the increment would create a local and silently do nothing")
}
Test("llm-ollama: cancelling warmup invalidates in-flight callbacks (F-12)",
	_A0720B2_WarmupCancelBumpsGeneration)

;
; F-21  LLM_Ollama_WarmupRetryTick is a one-shot whose only re-arm sits at the
; tail of the schedule function, so any early return ended the retry chain
; for the session — including the in-flight-prediction guard, which is the
_A0720B3_WarmupChainSurvivesTransientSkips() {
	Body := _DriverFuncBody("LLM_Ollama_WarmupRetryTick")
	Assert(Body != "", "LLM_Ollama_WarmupRetryTick must exist")

	ReadyIdx := InStr(Body, "LLM_OllamaIsReady()")
	ReArmIdx := InStr(Body, "SetTimer(_LLM_Ollama_WarmupRetryFn")
	SuspendIdx := InStr(Body, "A_IsSuspended")
	AsyncIdx := InStr(Body, "_LLM_Ollama_Async.Count")

	Assert(ReadyIdx > 0 and ReArmIdx > 0 and SuspendIdx > 0 and AsyncIdx > 0,
		"prerequisite: the tick must still have its terminal check, its re-arm and both transient guards")
	Assert(ReadyIdx < ReArmIdx,
		"the TERMINAL condition (warmup already ready) must return BEFORE the re-arm, or the chain would never stop")
	Assert(ReArmIdx < SuspendIdx and ReArmIdx < AsyncIdx,
		"the re-arm must precede every TRANSIENT guard — this is a one-shot timer whose only other re-arm is on the success path, so a tick that merely skips one attempt (a prediction in flight is the normal state while typing) would otherwise end the retry chain for the whole session")
}
Test("llm-ollama: the warmup retry chain survives a transient skip (F-21)",
	_A0720B3_WarmupChainSurvivesTransientSkips)
