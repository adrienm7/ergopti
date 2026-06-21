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
; The fix calls _LLM_Ollama_StreamCleanupOrphans() from _LLM_Ollama_DispatchAsync
; before writing the new payload, so the reaper can never again be orphaned to
; a dead code path. This is a meta-static test (scans source text) because
; calling the dispatcher would spawn a real curl child process.
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
	Assert(InStr(Seg, "_LLM_Ollama_StreamCleanupOrphans(") > 0,
		"_LLM_Ollama_DispatchAsync must call _LLM_Ollama_StreamCleanupOrphans() -- the non-streaming hot path writes PII payload files and must reap crash orphans (curl-payload-pii-temp-leak)")
}
Test("api_ollama: _LLM_Ollama_DispatchAsync sweeps orphaned curl payloads (curl-payload-pii-temp-leak)", _CPTL_DispatchSweepsOrphans)
