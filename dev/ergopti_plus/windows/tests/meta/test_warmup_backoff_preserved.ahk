; tests/meta/test_warmup_backoff_preserved.ahk

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
