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


; ===================================================
; ===================================================
; ======= 2/ Assertions =============================
; ===================================================
; ===================================================

_WRS_WarmupTickHasSuspendGuard() {
	Src := _WRS_ReadSource("modules/llm/api_ollama.ahk")
	Seg := _DriverFuncBody("LLM_Ollama_WarmupRetryTick")
	Assert(Seg != "", "LLM_Ollama_WarmupRetryTick must exist in api_ollama.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"LLM_Ollama_WarmupRetryTick must check A_IsSuspended — SetTimer bypasses Suspend; without this guard HTTP calls fire while paused")
}
Test("api_ollama: LLM_Ollama_WarmupRetryTick has A_IsSuspended guard", _WRS_WarmupTickHasSuspendGuard)

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
}
Test("ErgoptiPlus: Ergopti_OnSuspendEnter cancels Ollama warmup retry on pause", _WRS_SuspendEnterCancelsWarmupRetry)
_WRS_DepsPollHasSuspendGuard() {
	Seg1 := _DriverFuncBody("LLM_Deps_PollServerReady")
	Assert(InStr(Seg1, "A_IsSuspended") > 0,
		"LLM_Deps_PollServerReady must check A_IsSuspended (warmup-retry-ignores-suspend)")
	; LLM_Deps_PollFile (the PS1-stdout poll callback this invariant originally
	; guarded alongside PollServerReady) was deleted by the AHK-29 winget
	; refactor as unreachable dead code — winget has no PS1 stdout to poll, so
	; there is no second poll callback left to check; see
	; test_dead_ps1_pipeline_absent.ahk for the regression guard on its removal.
}
Test("ollama_deps_checker: deps poll callbacks have A_IsSuspended guard", _WRS_DepsPollHasSuspendGuard)

_WRS_SuspendEnterCancelsDepsPoll() {
	Src := _DriverSourceConcat()
	
	FuncPos := InStr(Src, "Ergopti_OnSuspendEnter() {")
	Assert(FuncPos > 0, "Ergopti_OnSuspendEnter must exist")
	Tail := SubStr(Src, FuncPos)
	NextFunc := InStr(Tail, "`nErgopti_On")
	Segment := (NextFunc > 0) ? SubStr(Tail, 1, NextFunc) : Tail
	Assert(InStr(Segment, "SetTimer(_LLM_Deps_PollTimer, 0)") > 0,
		"Ergopti_OnSuspendEnter must stop _LLM_Deps_PollTimer when paused")
		
	FuncPos2 := InStr(Src, "Ergopti_OnSuspendResume() {")
	Assert(FuncPos2 > 0, "Ergopti_OnSuspendResume must exist")
	Tail2 := SubStr(Src, FuncPos2)
	NextFunc2 := InStr(Tail2, "`n_SuspendStateWatchdog")
	Segment2 := (NextFunc2 > 0) ? SubStr(Tail2, 1, NextFunc2) : Tail2
	Assert(InStr(Segment2, "SetTimer(_LLM_Deps_PollTimer, 3000)") > 0,
		"Ergopti_OnSuspendResume must resume _LLM_Deps_PollTimer if checking")
}
Test("ErgoptiPlus: Suspend toggles pause deps poll timer", _WRS_SuspendEnterCancelsDepsPoll)


; F26: LLM_OllamaScheduleWarmupRetry's FIRST dispatch is reachable directly
; from LLM_Menu_SetModel and LLM_Menu_OnDepsReady while suspended, with no
; guard anywhere else on that path — unlike the recurring retry tick above,
; which was already guarded. The fix adds the guard at the top of the
; function itself so both menu-click call sites are protected at once.
_WRS_ScheduleWarmupRetryHasSuspendGuard() {
	Seg := _DriverFuncBody("LLM_OllamaScheduleWarmupRetry")
	Assert(Seg != "", "LLM_OllamaScheduleWarmupRetry must exist in modules/llm/api_ollama")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"LLM_OllamaScheduleWarmupRetry must check A_IsSuspended at its own top — its first dispatch is reachable directly from LLM_Menu_SetModel and LLM_Menu_OnDepsReady while suspended (F26)")
}
Test("api_ollama: LLM_OllamaScheduleWarmupRetry guards its own first dispatch against Suspend (F26)", _WRS_ScheduleWarmupRetryHasSuspendGuard)
