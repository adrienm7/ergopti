; tests/meta/ai/api/test_suspend_enter_cancels_warmup.ahk

; ==============================================================================
; MODULE: Pause Entry Cancels the Ollama Warmup Retry
; DESCRIPTION:
; SetTimer callbacks keep firing under native Suspend, so the pause entry
; tears the warmup retry down at the source: Ergopti_OnSuspendEnter runs
; LLM_OllamaCancelWarmupRetry as a required lifecycle step whose receipt must
; succeed (warmup-retry-bypasses-suspend). The tick's and the scheduler's own
; pause refusals are called under a real Suspend in
; tests/unit/ai/api/test_ollama_warmup_pause.ahk. This step stays a source scan:
; the pause entry lives in ErgoptiPlus.ahk, which the headless runner cannot
; include.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================
; =============================
; ======= 1/ Assertions =======
; =============================
; =============================

_WRS_SuspendEnterCancelsWarmupRetry() {
	Src := _DriverSourceConcat()
	; Search from the declaration of Ergopti_OnSuspendEnter in the tail.
	FuncPos := InStr(Src, "Ergopti_OnSuspendEnter() {")
	Assert(FuncPos > 0, "Ergopti_OnSuspendEnter must exist in ErgoptiPlus.ahk")
	Tail := SubStr(Src, FuncPos)
	; The cancel call must appear before the next function definition.
	NextFunc := InStr(Tail, "`nErgopti_On")
	Segment := (NextFunc > 0) ? SubStr(Tail, 1, NextFunc) : Tail
	Assert(InStr(Segment, "LLM_OllamaCancelWarmupRetry") > 0,
		"Ergopti_OnSuspendEnter must call LLM_OllamaCancelWarmupRetry() to stop background warmup HTTP when paused")
	Assert(RegExMatch(Segment,
		's)_LifecycleRunRequiredStep\(Transition,\s*"ollama-warmup",\s*LLM_OllamaCancelWarmupRetry,\s*true\)'),
		"suspend must require an explicit successful warmup cancellation receipt")
}
Test("ErgoptiPlus: Ergopti_OnSuspendEnter cancels Ollama warmup retry on pause", _WRS_SuspendEnterCancelsWarmupRetry)
