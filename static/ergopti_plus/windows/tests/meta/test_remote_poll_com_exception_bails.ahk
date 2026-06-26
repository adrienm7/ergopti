; tests/meta/test_remote_poll_com_exception_bails.ahk

; ==============================================================================
; MODULE: Remote Poll COM-Exception Fast-Bail Meta Test
; DESCRIPTION:
; Static source guard for finding ollama-com-exception-busy-loop (remote twin, F-M06).
;
; _LLMRemote_PollRequest read `try ready := http.WaitForResponse(0)` — a bare try
; with no catch. When the connection drops mid-request (WiFi cut, provider socket
; reset, VPN flap) WaitForResponse raises a COM exception that was swallowed; ready
; stayed false and the poll re-armed every LLM_REMOTE_POLL_MS, waking the message
; loop ~600 times over the 30 s deadline before on_fail finally fired. The sibling
; Ollama poll already wraps WaitForResponse in try/catch and aborts immediately; the
; remote twin never received that hardening. The fix wraps WaitForResponse in a
; try/catch that aborts the request and fires on_fail at once.
;
; Meta-static because modules/llm is not in the headless runner's include graph.
; ==============================================================================

#Requires AutoHotkey v2.0


_RPCE_AssertComExceptionBails() {
	Body := _DriverFuncBody("_LLMRemote_PollRequest")
	Assert(Body != "", "_LLMRemote_PollRequest must exist")
	WaitPos := InStr(Body, "WaitForResponse(0)")
	RearmPos := InStr(Body, "if !ready")
	Assert(WaitPos > 0 and RearmPos > WaitPos, "_LLMRemote_PollRequest must WaitForResponse then check !ready")
	CatchPos := InStr(Body, "catch", , WaitPos)
	Assert(CatchPos > WaitPos and CatchPos < RearmPos,
		"_LLMRemote_PollRequest must wrap WaitForResponse in a try/catch (before the !ready re-arm) so a COM exception aborts the dead request instead of busy-polling for the full deadline (ollama-com-exception-busy-loop)")
	OnFailPos := InStr(Body, "on_fail", , CatchPos)
	Assert(OnFailPos > CatchPos and OnFailPos < RearmPos,
		"the WaitForResponse catch must fire on_fail() and bail before re-arming the poll (ollama-com-exception-busy-loop)")
}
Test("LLM remote: WaitForResponse COM exception aborts instead of busy-polling (ollama-com-exception-busy-loop)", _RPCE_AssertComExceptionBails)
