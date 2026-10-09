; tests/meta/test_llm_orphan_sweep_nonblocking.ahk

; ==============================================================================
; MODULE: LLM Orphan-Sweep Non-Blocking Test
; DESCRIPTION:
; Regression guard for the freeze where, during a prediction, the keyboard locked
; up for tens of seconds and NOT ONE log line was emitted the whole time.
;
; Root cause: _LLM_Ollama_StreamCleanupOrphans swept the curl temp files with a
; RECURSIVE glob ("FR") rooted at A_Temp — it walked the ENTIRE %TEMP% subtree
; (100k+ entries / 20k+ dirs on a busy box → ~19 s per pass, run twice for *.json
; and *.out → ~38 s). It was called inline from the curl dispatch
; (_LLM_Ollama_DispatchAsync / LLM_OllamaGenerate_Streaming), which runs inside
; LLM_Engine_FirePrediction's Critical("On") section. Critical disables the message
; pump, so the walk froze every hotkey / InputHook / timer — the keyboard was dead
; and the logger silent until it finished (the user's "clavier bloque pendant la
; prediction" + the 37 s dead gap in the live logs).
;
; THE FIX (the contract this test pins):
;   1. The sweep is BOUNDED — it never uses the recursive "FR" glob over %TEMP%. It
;      sweeps the A_Temp root non-recursively ("F") and only its own ergopti_llm_*
;      per-instance dirs one level deep ("D").
;   2. The dispatch path NEVER calls the sweep directly (that ran inside Critical);
;      both dispatchers call _LLM_Ollama_ScheduleOrphanSweep instead.
;   3. The scheduler defers the sweep off-thread via SetTimer (it runs only after the
;      Critical dispatch returns) and throttles it (orphans are never urgent).
;
; Source-level (mirrors the sibling async-contract meta tests): a behavioural harness
; would need to stub the filesystem, A_Temp and SetTimer.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Sweep is bounded =======
; ===================================
; ===================================

_MetaCheckOrphanSweepNonBlocking() {
	; (1) The sweep is bounded — no recursive "FR" walk of the whole %TEMP% tree.
	SweepBody := _DriverFuncBody("_LLM_Ollama_StreamCleanupOrphans")
	Assert(SweepBody != "", "api_ollama.ahk must define _LLM_Ollama_StreamCleanupOrphans()")
	Assert(!InStr(SweepBody, '"FR"') and !InStr(SweepBody, '"RF"'),
		"_LLM_Ollama_StreamCleanupOrphans must NOT use the recursive 'FR' file glob — it "
		. "walked the entire %TEMP% subtree (~19 s/pass) and froze the keyboard mid-prediction")
	Assert(InStr(SweepBody, "ergopti_llm_"),
		"_LLM_Ollama_StreamCleanupOrphans must scope its walk to the driver's own "
		. "ergopti_llm_* per-instance dirs, not all of %TEMP%")

	; (2) The dispatch path must NOT call the sweep directly (that ran inside the
	; FirePrediction Critical section); it must schedule it off-thread instead.
	DispatchBody := _DriverFuncBody("_LLM_Ollama_DispatchAsync")
	Assert(DispatchBody != "", "api_ollama.ahk must define _LLM_Ollama_DispatchAsync()")
	Assert(!InStr(DispatchBody, "_LLM_Ollama_StreamCleanupOrphans("),
		"_LLM_Ollama_DispatchAsync must NOT call _LLM_Ollama_StreamCleanupOrphans() directly "
		. "— it runs inside FirePrediction's Critical section and would freeze the message loop")
	Assert(InStr(DispatchBody, "_LLM_Ollama_ScheduleOrphanSweep("),
		"_LLM_Ollama_DispatchAsync must defer the sweep via _LLM_Ollama_ScheduleOrphanSweep()")

	StreamBody := _DriverFuncBody("LLM_OllamaGenerate_Streaming")
	Assert(StreamBody != "", "api_ollama.ahk must define LLM_OllamaGenerate_Streaming()")
	Assert(!InStr(StreamBody, "_LLM_Ollama_StreamCleanupOrphans("),
		"LLM_OllamaGenerate_Streaming must NOT call _LLM_Ollama_StreamCleanupOrphans() directly")
	Assert(InStr(StreamBody, "_LLM_Ollama_ScheduleOrphanSweep("),
		"LLM_OllamaGenerate_Streaming must defer the sweep via _LLM_Ollama_ScheduleOrphanSweep()")

	; (3) The scheduler defers off-thread (SetTimer) and throttles (orphans never urgent).
	SchedBody := _DriverFuncBody("_LLM_Ollama_ScheduleOrphanSweep")
	Assert(SchedBody != "", "api_ollama.ahk must define _LLM_Ollama_ScheduleOrphanSweep()")
	Assert(InStr(SchedBody, "SetTimer("),
		"_LLM_Ollama_ScheduleOrphanSweep must defer via SetTimer so the sweep runs AFTER the "
		. "Critical dispatch returns (never blocking the message pump)")
	Assert(InStr(SchedBody, "_LLM_Ollama_LastSweepTick"),
		"_LLM_Ollama_ScheduleOrphanSweep must throttle via _LLM_Ollama_LastSweepTick")
}

Test("meta llm: orphan sweep is bounded + off the Critical dispatch path (llm-orphan-sweep-temp-recursion)",
	_MetaCheckOrphanSweepNonBlocking)
