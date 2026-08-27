; tests/meta/test_remote_api_validate_async.ahk

; ==============================================================================
; MODULE: Remote API Validate Async Meta Test
; DESCRIPTION:
; Static source guard for the remote-api-validate-blocks-message-pump finding.
;
; Saving an API entry used to call the synchronous LLM_RemoteIsReady() on the
; main thread (WinHTTP opened with async=false). On an unreachable BaseUrl that
; blocking GET froze the whole driver for up to ~2 s, during which the user's
; first keystrokes could be dropped by LowLevelHooksTimeout. The save path runs
; immediately after the user dismisses the last InputBox, so the stall lands
; right when they switch to another window and start typing.
;
; The fix:
; a) menu_api_entries.ahk's save path no longer calls the blocking
;    LLM_RemoteIsReady(); it dispatches LLM_RemoteIsReady_Async() and surfaces
;    the TrayTip from the poll callback, so the message pump keeps running.
; b) api_remote.ahk defines LLM_RemoteIsReady_Async, which launches a tree-owned
;    curl request and polls it via a relaxed SetTimer loop with an absolute deadline.
;
; This is a meta-static test (scans source text): menu_api_entries.ahk is not
; in the headless run_all include graph, and LLM_RemoteIsReady_Async makes a
; live network call, so the entrypoint mapping is guarded statically here while
; the shared transport has a real delayed-listener heartbeat regression.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Save-path non-blocking assertions =======
; ====================================================
; ====================================================

_RAVB_SavePathDoesNotCallSyncProbe() {
	; Move-resilient: locate _LLM_Menu_PromptApiEntry across the driver source via
	; the framework helper (also strips full-line comments) instead of a pinned
	; menu_api_entries.ahk path.
	Body := _DriverFuncBody("_LLM_Menu_PromptApiEntry")
	Assert(Body != "", "_LLM_Menu_PromptApiEntry must exist in ui/menu/menu_llm/menu_api_entries.ahk")
	Assert(InStr(Body, "LLM_RemoteIsReady(") == 0,
		"_LLM_Menu_PromptApiEntry must not call the synchronous LLM_RemoteIsReady() — its blocking WinHTTP GET freezes the driver and drops keystrokes for up to 2 s on an unreachable host (remote-api-validate-blocks-message-pump)")
}
Test("api_entries: save path no longer calls synchronous LLM_RemoteIsReady (remote-api-validate-blocks-message-pump)", _RAVB_SavePathDoesNotCallSyncProbe)

_RAVB_SavePathUsesAsyncProbe() {
	Body := _DriverFuncBody("_LLM_Menu_PromptApiEntry")
	Assert(InStr(Body, "LLM_RemoteIsReady_Async(") > 0,
		"_LLM_Menu_PromptApiEntry must dispatch LLM_RemoteIsReady_Async() so the save path returns immediately and the message pump keeps running (remote-api-validate-blocks-message-pump)")
}
Test("api_entries: save path dispatches LLM_RemoteIsReady_Async instead (remote-api-validate-blocks-message-pump)", _RAVB_SavePathUsesAsyncProbe)





; ====================================================
; ====================================================
; ======= 2/ Async probe definition assertions =======
; ====================================================
; ====================================================

_RAVB_AsyncProbeExists() {
	Body := _DriverFuncBody("LLM_RemoteIsReady_Async")
	Assert(Body != "", "LLM_RemoteIsReady_Async must exist in modules/llm/api_remote.ahk (remote-api-validate-blocks-message-pump)")
}
Test("api_remote: LLM_RemoteIsReady_Async is defined (remote-api-validate-blocks-message-pump)", _RAVB_AsyncProbeExists)

_RAVB_AsyncProbeUsesChildTransport() {
	Body := _DriverFuncBody("LLM_RemoteIsReady_Async")
	Assert(Body != "", "LLM_RemoteIsReady_Async must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, "CurlAsyncRequest()") > 0,
		"remote readiness must use the tree-owned curl transport")
	Assert(!InStr(Body, "ComObject(") and !InStr(Body, "WinHttp"),
		"remote readiness must never construct WinHTTP on the AHK thread")
}
Test("api_remote: readiness uses a child transport (remote-api-validate-blocks-message-pump)", _RAVB_AsyncProbeUsesChildTransport)
