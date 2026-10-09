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
; The complete fix moves the POST onto a curl child process and refuses dispatch
; when that transport is unavailable. No bounded synchronous fallback remains.
;
; Source-scan: asserts the dedicated connect timeout exists and no remote SetTimeouts
; uses the full request timeout for the resolve+connect args.
; ==============================================================================

#Requires AutoHotkey v2.0


_RCT_AssertConnectBounded() {
	Body := _DriverFuncBody("LLM_RemoteGenerate_Async")
	Assert(InStr(Body, "_LLMRemote_DispatchCurl(") > 0)
	Assert(!InStr(Body, "_LLMRemote_DispatchWinHttp("),
		"remote generation must have no synchronous WinHTTP fallback")
}
Test("LLM remote: production generation has no WinHTTP fallback (remote-generate-connect-blocks)", _RCT_AssertConnectBounded)
