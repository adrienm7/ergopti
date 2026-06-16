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




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_WBPG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_WBPG_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}


; ===================================================
; ===================================================
; ======= 2/ Assertions =============================
; ===================================================
; ===================================================

_WBPG_CancelHasResetBackoffParam() {
	Src := _WBPG_ReadSource("modules/llm/api_ollama.ahk")
	; Locate the function declaration line — it must include the parameter name
	DeclPos := InStr(Src, "LLM_OllamaCancelWarmupRetry(")
	Assert(DeclPos > 0,
		"LLM_OllamaCancelWarmupRetry must exist in api_ollama.ahk")
	; Scope the declaration to a single line to avoid false positives in callers
	DeclEnd := InStr(Src, "`n", false, DeclPos)
	DeclLine := (DeclEnd > 0) ? SubStr(Src, DeclPos, DeclEnd - DeclPos) : SubStr(Src, DeclPos)
	Assert(InStr(DeclLine, "reset_backoff") > 0,
		"LLM_OllamaCancelWarmupRetry declaration must include the reset_backoff parameter "
		. "— callers rely on a default of false so that ordinary cancels do not reset "
		. "the exponential backoff interval")
}
Test("api_ollama: LLM_OllamaCancelWarmupRetry has reset_backoff parameter",
	_WBPG_CancelHasResetBackoffParam)

_WBPG_BackoffResetIsConditional() {
	Src := _WBPG_ReadSource("modules/llm/api_ollama.ahk")
	Body := _WBPG_FuncBody(Src, "LLM_OllamaCancelWarmupRetry(")
	Assert(Body != "",
		"LLM_OllamaCancelWarmupRetry body must be extractable from api_ollama.ahk")

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
