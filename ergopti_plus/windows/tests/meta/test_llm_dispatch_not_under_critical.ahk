; tests/meta/test_llm_dispatch_not_under_critical.ahk

; ==============================================================================
; MODULE: LLM Ollama Dispatch Not Under Critical Meta Test
; DESCRIPTION:
; Regression guard for AHK-28: _LLM_Ollama_DispatchAsync was called from
; LLM_Engine_FirePrediction inside a Critical section. The function then
; performed FSWrite (disk I/O) and Run() (process creation) synchronously
; under that same Critical — blocking all AHK message processing for the
; duration of the curl launch on every prediction. On slow disks or when
; AppLocker/AV held the run for >100 ms, the UI would freeze and keyboard
; input could be dropped.
;
; The fix (AHK-28) splits the dispatch:
;   (1) _LLM_Ollama_DispatchAsync reserves the _LLM_Ollama_Async[req_id]
;       slot synchronously (so DrainPending's .Count > 0 coalescing check
;       sees the slot even before the process launches).
;   (2) FSWrite + Run() are deferred via SetTimer(-1) into
;       _LLM_Ollama_DoSpawn, which executes after Critical has released.
;
; This test asserts (source introspection):
;   (a) _LLM_Ollama_DispatchAsync body contains SetTimer — the deferral
;       mechanism is present and the OS calls are not inlined anymore.
;   (b) _LLM_Ollama_DispatchAsync body contains "_LLM_Ollama_Async[req_id]"
;       assignment — the slot is still reserved synchronously.
;   (c) The slot reservation appears BEFORE SetTimer in the body — so the
;       coalescing count is visible to DrainPending before the spawn runs.
;   (d) _LLM_Ollama_DoSpawn exists and contains both FSWrite and Run( —
;       confirming the OS calls moved to the deferred helper.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TLDNUC_CheckDispatchDeferred() {
	Body := _DriverFuncBody("_LLM_Ollama_DispatchAsync")
	Assert(Body != "", "_LLM_Ollama_DispatchAsync must exist in modules/llm/api_ollama.ahk")

	; (a) SetTimer must be present — the OS calls are deferred
	Assert(InStr(Body, "SetTimer"),
		"AHK-28: _LLM_Ollama_DispatchAsync must use SetTimer to defer FSWrite + Run() outside the Critical region — blocking OS calls under Critical freeze AHK message processing and can drop keyboard input")

	; (b) The slot reservation must still be present in the synchronous part
	Assert(InStr(Body, "_LLM_Ollama_Async[req_id]"),
		"AHK-28: _LLM_Ollama_DispatchAsync must still reserve the _LLM_Ollama_Async[req_id] slot synchronously so DrainPending's .Count > 0 coalescing check sees the in-flight slot before the deferred spawn runs")

	; (c) Slot reservation must precede SetTimer in the body
	SlotPos  := InStr(Body, "_LLM_Ollama_Async[req_id]")
	TimerPos := InStr(Body, "SetTimer")
	Assert(SlotPos < TimerPos,
		"AHK-28: the _LLM_Ollama_Async[req_id] slot reservation must appear BEFORE SetTimer in _LLM_Ollama_DispatchAsync — the slot must be visible to any concurrent DrainPending check from the moment DispatchAsync returns, not only after the deferred spawn completes")

	; (d) The deferred helper must exist and contain the OS calls
	SpawnBody := _DriverFuncBody("_LLM_Ollama_DoSpawn")
	Assert(SpawnBody != "", "AHK-28: _LLM_Ollama_DoSpawn must exist — it is the deferred helper that performs FSWrite + Run() outside the Critical region")
	Assert(InStr(SpawnBody, "FSWrite"),
		"AHK-28: _LLM_Ollama_DoSpawn must contain FSWrite — the payload file write must happen in the deferred helper, not under Critical")
	Assert(InStr(SpawnBody, "_LLM_CurlRunOwned("),
		"AHK-28: _LLM_Ollama_DoSpawn must launch the owned curl process in the deferred helper, not under Critical")
}

_TLDNUC_CheckPredictionPreparationIsInterruptible() {
	Body := _DriverFuncBody("LLM_Engine_FirePrediction")
	Assert(Body != "", "LLM_Engine_FirePrediction must exist in modules/llm/prediction_exec.ahk")
	Assert(InStr(Body, "Critical(") = 0,
		"AHK-016: FirePrediction must not hold Critical across secure-field/window checks, profile/model loading, tooltip work, or backend dispatch; only an explicit tiny reservation helper may be critical")
}


Test("meta ahk-28: _LLM_Ollama_DispatchAsync defers FSWrite + Run() via SetTimer so blocking OS calls do not execute under Critical",
	_TLDNUC_CheckDispatchDeferred)
Test("meta ahk-016: LLM_Engine_FirePrediction keeps preparation and dispatch interruptible",
	_TLDNUC_CheckPredictionPreparationIsInterruptible)
