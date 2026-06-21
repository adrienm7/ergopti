; tests/meta/test_ollama_installer_sync_winhttp_blocks.ahk

; ==============================================================================
; MODULE: Ollama Installer Sync WinHTTP Blocks Meta Test
; DESCRIPTION:
; Static source guard for the ollama-installer-sync-winhttp-blocks finding.
;
; The background installer poll used to call the synchronous LLM_OllamaIsRunning()
; on the main thread. On an unreachable Ollama daemon (which is guaranteed while
; the installer runs), that blocking GET froze the driver for up to 2 s on every poll
; tick, causing severe latency and dropped keystrokes.
;
; The fix:
; a) LLM_Deps_DoCheck no longer calls the blocking LLM_OllamaIsRunning().
; b) LLM_Deps_PollFile exit path no longer calls the blocking LLM_OllamaIsRunning().
; c) Both now use LLM_OllamaIsRunning_Async().
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Installer poll non-blocking       =======
; ====================================================
; ====================================================

_OISW_DoCheckDoesNotCallSyncProbe() {
	; Move-resilient: locate LLM_Deps_DoCheck() across the whole driver source via
	; the framework helper instead of a pinned modules path
	Body := _DriverFuncBody("LLM_Deps_DoCheck")
	Assert(Body != "", "LLM_Deps_DoCheck must exist in modules/llm/ollama_deps_checker.ahk")
	Assert(InStr(Body, "LLM_OllamaIsRunning(") == 0,
		"LLM_Deps_DoCheck must not call the synchronous LLM_OllamaIsRunning() — its blocking WinHTTP GET freezes the driver (ollama-installer-sync-winhttp-blocks)")
}
Test("ollama_deps: DoCheck no longer calls synchronous LLM_OllamaIsRunning (ollama-installer-sync-winhttp-blocks)", _OISW_DoCheckDoesNotCallSyncProbe)

_OISW_DoCheckUsesAsyncProbe() {
	Body := _DriverFuncBody("LLM_Deps_DoCheck")
	Assert(InStr(Body, "LLM_OllamaIsRunning_Async(") > 0,
		"LLM_Deps_DoCheck must dispatch LLM_OllamaIsRunning_Async() so the message pump keeps running (ollama-installer-sync-winhttp-blocks)")
}
Test("ollama_deps: DoCheck dispatches LLM_OllamaIsRunning_Async instead (ollama-installer-sync-winhttp-blocks)", _OISW_DoCheckUsesAsyncProbe)


_OISW_OnPs1ExitDoesNotCallSyncProbe() {
	; Move-resilient: function-body existence check via the framework helper; the
	; sync-probe absent scan widens to the whole driver source, which strengthens it
	Body := _DriverFuncBody("_LLM_Deps_OnPs1Exit_Result")
	Assert(Body != "", "_LLM_Deps_OnPs1Exit_Result must exist in modules/llm/ollama_deps_checker.ahk")
	Assert(InStr(_DriverSourceConcat(), "if LLM_OllamaIsRunning() {") == 0,
		"No exit path should call the synchronous LLM_OllamaIsRunning() (ollama-installer-sync-winhttp-blocks)")
}
Test("ollama_deps: Exit path no longer calls synchronous LLM_OllamaIsRunning (ollama-installer-sync-winhttp-blocks)", _OISW_OnPs1ExitDoesNotCallSyncProbe)
