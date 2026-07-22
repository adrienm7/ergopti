; tests/meta/test_remote_connect_timeout_bounded.ahk

; ==============================================================================
; MODULE: Remote Generate Connect-Timeout Bound Meta Test
; DESCRIPTION:
; Static source guard for finding remote-generate-connect-blocks (F-H03, mitigation).
;
; WinHttpRequest.5.1's "async" mode (Open(...,true) + Send()) makes only the
; RESPONSE wait asynchronous; the DNS resolve + TCP connect still run SYNCHRONOUSLY
; on the message-loop thread that pumps the PrefixWatcher InputHook. So a stalled
; remote host froze typing (and dropped keystrokes via LowLevelHooksTimeout) for the
; whole request timeout on every remote-API prediction fire.
;
; The COMPLETE fix is to move the POST onto a curl child process (mirror
; _LLM_Ollama_DispatchAsync), which does the connect in its own process; that needs a
; live remote-API key to validate end-to-end and is tracked for hands-on completion.
; This bounded mitigation caps the synchronous resolve+connect phase with a dedicated
; short LLM_REMOTE_CONNECT_TIMEOUT_MS so the worst-case freeze is a few seconds, not
; the full request timeout.
;
; Source-scan: asserts the dedicated connect timeout exists and no remote SetTimeouts
; uses the full request timeout for the resolve+connect args.
; ==============================================================================

#Requires AutoHotkey v2.0


_RCT_AssertConnectBounded() {
	; Scan the whole driver source so the test survives a file move of api_remote.
	src := _DriverSourceConcat()
	Assert(InStr(src, "LLM_REMOTE_CONNECT_TIMEOUT_MS :=") > 0,
		"a dedicated short connect timeout must bound the synchronous resolve+connect phase (remote-generate-connect-blocks)")
	Assert(!InStr(src, "SetTimeouts(LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS"),
		"no remote SetTimeouts may use the full request timeout for the resolve+connect (1st/2nd) args — that lets a stalled connect freeze the typing thread for the whole timeout (remote-generate-connect-blocks)")
}
Test("LLM remote: synchronous resolve+connect is bounded by a dedicated short timeout (remote-generate-connect-blocks)", _RCT_AssertConnectBounded)
