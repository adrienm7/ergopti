; tests/meta/test_curl_payload_pii_temp_leak.ahk

; ==============================================================================
; MODULE: Curl Payload PII Temp-Leak Meta Test
; DESCRIPTION:
; Static source guard for the curl-payload-pii-temp-leak finding.
;
; _LLM_Ollama_DispatchAsync is the NON-streaming hot path that writes the
; user's typed context (potential PII) into a temp curl payload file. The
; crash-orphan reaper (_LLM_Ollama_StreamCleanupOrphans) used to be called
; only from the streaming path, which is currently dead code -- so the active
; path that actually creates these files never reaped its own orphans. After
; a hard kill (Task Manager / BSOD / power loss) the PII file lingered with no
; bounded lifetime.
;
; The fix triggers the reaper from _LLM_Ollama_DispatchAsync so it can never again
; be orphaned to a dead code path. The dispatcher does NOT call the reaper inline
; (a direct call ran the sweep inside FirePrediction's Critical section, where an
; unbounded %TEMP% walk froze the keyboard for tens of seconds -- see
; llm-orphan-sweep-temp-recursion): it calls _LLM_Ollama_ScheduleOrphanSweep, which
; defers _LLM_Ollama_StreamCleanupOrphans off-thread. The end-to-end guarantee (the
; PII-writing hot path drives the reaper) is preserved. This is a meta-static test
; (scans source text) because calling the dispatcher would spawn a real curl child.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_CPTL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ===================================================
; ===================================================
; ======= 2/ Orphan-reaper assertions ===============
; ===================================================
; ===================================================

_CPTL_DispatchSweepsOrphans() {
	Src := _CPTL_ReadSource("modules/llm/api_ollama.ahk")
	Seg := _DriverFuncBody("_LLM_Ollama_DispatchAsync")
	Assert(Seg != "", "_LLM_Ollama_DispatchAsync must exist in api_ollama.ahk")
	; The PII-writing hot path must TRIGGER the reaper -- but off-thread via the
	; scheduler, never a direct inline call (that froze the keyboard inside the
	; FirePrediction Critical section; llm-orphan-sweep-temp-recursion).
	Assert(InStr(Seg, "_LLM_Ollama_ScheduleOrphanSweep(") > 0,
		"_LLM_Ollama_DispatchAsync must trigger the orphan reaper via _LLM_Ollama_ScheduleOrphanSweep() -- the non-streaming hot path writes PII payload files and must reap crash orphans (curl-payload-pii-temp-leak)")
	; And the scheduler must actually drive the reaper, so it is never orphaned to a
	; dead path again (the original curl-payload-pii-temp-leak guarantee, intact).
	Sched := _DriverFuncBody("_LLM_Ollama_ScheduleOrphanSweep")
	Assert(Sched != "", "_LLM_Ollama_ScheduleOrphanSweep must exist in api_ollama.ahk")
	Assert(InStr(Sched, "_LLM_Ollama_StreamCleanupOrphans") > 0,
		"_LLM_Ollama_ScheduleOrphanSweep must drive _LLM_Ollama_StreamCleanupOrphans so PII orphans are still reaped (curl-payload-pii-temp-leak)")
}
Test("api_ollama: _LLM_Ollama_DispatchAsync sweeps orphaned curl payloads (curl-payload-pii-temp-leak)", _CPTL_DispatchSweepsOrphans)
