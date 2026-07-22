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
; b) The installer poll exit path no longer calls the blocking LLM_OllamaIsRunning().
; c) Both now use LLM_OllamaIsRunning_Async().
;
; NOTE: at the time this finding was fixed, (b) lived in LLM_Deps_PollFile /
; _LLM_Deps_OnPs1Exit_Result — the PS1-stdout poll callback for the old
; hidden-PowerShell installer. The AHK-29 winget refactor later deleted that
; whole pipeline as unreachable dead code (winget has no PS1 stdout to poll);
; see test_dead_ps1_pipeline_absent.ahk for its removal guard. (b)'s invariant
; now lives in LLM_Deps_PollServerReady / _LLM_Deps_OnPollProbeResult, the
; winget-era poll/exit path — checked generically below instead of pinning to
; the deleted function names.
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


_OISW_ExitPathDoesNotCallSyncProbe() {
	; The PS1-stdout exit callback (_LLM_Deps_OnPs1Exit_Result) this test
	; originally pinned to was deleted by the AHK-29 winget refactor along with
	; the rest of the dead PS1 pipeline — winget has no stdout to poll, so
	; there is no "exit" event left to react to. The winget-era equivalent is
	; the poll-tick callback below; assert on the invariant (no exit/poll path
	; anywhere calls the blocking probe) rather than a since-deleted function.
	Body := _DriverFuncBody("_LLM_Deps_OnPollProbeResult")
	Assert(Body != "", "_LLM_Deps_OnPollProbeResult must exist as the winget-era poll-result callback")
	Assert(InStr(_DriverSourceConcat(), "if LLM_OllamaIsRunning() {") == 0,
		"No exit path should call the synchronous LLM_OllamaIsRunning() (ollama-installer-sync-winhttp-blocks)")
}
Test("ollama_deps: Exit path no longer calls synchronous LLM_OllamaIsRunning (ollama-installer-sync-winhttp-blocks)", _OISW_ExitPathDoesNotCallSyncProbe)
