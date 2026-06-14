; tests/meta/test_warmup_retry_suspend_guard.ahk

; ==============================================================================
; MODULE: Warmup-Retry Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the "warmup retry bypasses suspend" finding
; (warmup-retry-bypasses-suspend).
;
; LLM_Ollama_WarmupRetryTick() is a SetTimer callback that fires at an
; exponentially-growing interval while Ollama is loading. Because SetTimer
; callbacks bypass native Suspend (they fire regardless of A_IsSuspended), the
; tick was making live HTTP requests to Ollama even while the driver was paused
; — violating the "pause = tout eteint" invariant.
;
; The fix adds two layers of defence:
; 1. LLM_Ollama_WarmupRetryTick begins with `if A_IsSuspended return` so any
;    timer that slips through the pause transition cannot make a network call.
; 2. Ergopti_OnSuspendEnter (ErgoptiPlus.ahk) now calls
;    LLM_OllamaCancelWarmupRetry() so the timer is torn down at the moment
;    pause is triggered — stopping future ticks at the source.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_WRS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_WRS_FuncBody(Src, FuncDef) {
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

_WRS_WarmupTickHasSuspendGuard() {
	Src := _WRS_ReadSource("modules/llm/api_ollama.ahk")
	Seg := _WRS_FuncBody(Src, "LLM_Ollama_WarmupRetryTick() {")
	Assert(Seg != "", "LLM_Ollama_WarmupRetryTick must exist in api_ollama.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"LLM_Ollama_WarmupRetryTick must check A_IsSuspended — SetTimer bypasses Suspend; without this guard HTTP calls fire while paused")
}
Test("api_ollama: LLM_Ollama_WarmupRetryTick has A_IsSuspended guard", _WRS_WarmupTickHasSuspendGuard)

_WRS_SuspendEnterCancelsWarmupRetry() {
	Src := _WRS_ReadSource("ErgoptiPlus.ahk")
	; Search from the declaration of Ergopti_OnSuspendEnter in the tail.
	FuncPos := InStr(Src, "Ergopti_OnSuspendEnter() {")
	Assert(FuncPos > 0, "Ergopti_OnSuspendEnter must exist in ErgoptiPlus.ahk")
	Tail := SubStr(Src, FuncPos)
	; The cancel call must appear before the next function definition.
	NextFunc := InStr(Tail, "`nErgopti_On")
	Segment := (NextFunc > 0) ? SubStr(Tail, 1, NextFunc) : Tail
	Assert(InStr(Segment, "LLM_OllamaCancelWarmupRetry") > 0,
		"Ergopti_OnSuspendEnter must call LLM_OllamaCancelWarmupRetry() to stop background warmup HTTP when paused")
}
Test("ErgoptiPlus: Ergopti_OnSuspendEnter cancels Ollama warmup retry on pause", _WRS_SuspendEnterCancelsWarmupRetry)
