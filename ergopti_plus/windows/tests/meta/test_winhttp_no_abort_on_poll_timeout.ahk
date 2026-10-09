; tests/meta/test_winhttp_no_abort_on_poll_timeout.ahk

; ==============================================================================
; MODULE: WinHTTP Poll-Timeout Abort Meta Test
; DESCRIPTION:
; Static source guard for the winhttp-no-abort-on-poll-timeout finding.
;
; When a WinHTTP poll loop gives up (poll-timeout / cancelled), it used to drop
; its reference to the COM request object and trust the underlying request to
; wind down on its own internal timeout. A provider that accepts the connection
; but never responds keeps the COM object + socket resident far longer than
; intended; under rapid typing many such stuck requests accumulate briefly.
;
; The fix calls ``http.Abort()`` (wrapped in try) before deleting the registry
; entry on:
;   a) _LLMRemote_PollRequest's cancelled path,
;   b) _LLMRemote_PollRequest's deadline path,
;   c) _LLM_Ollama_PollGeneric's deadline (poll-timeout) path.
;
; This is a meta-static test (scans source text) because driving the real poll
; loops requires a live WinHTTP COM object and a stalled network endpoint.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Abort-on-give-up assertions ============
; ===================================================
; ===================================================

_WNAPT_RemotePollAbortsOnGiveUp() {
	; Move-resilient: extract _LLMRemote_PollRequest()'s body by name via the
	; framework helper instead of a pinned modules/llm/api_remote.ahk read. The
	; helper strips full-line comments, so an assertion can never match a phrase
	; that only appears in a comment.
	Body := _DriverFuncBody("_LLMRemote_PollRequest")
	Assert(Body != "", "_LLMRemote_PollRequest must exist in api_remote.ahk")
	; Both the cancelled and the deadline branch must Abort the live request
	; before dropping the registry reference. Two .Abort() call sites in the
	; function body proves both branches are covered (cancel + deadline).
	count := 0
	pos := 1
	while (pos := InStr(Body, ".Abort()", false, pos)) {
		count += 1
		pos += 1
	}
	Assert(count >= 2,
		"_LLMRemote_PollRequest must call http.Abort() on BOTH the cancelled and the deadline give-up paths -- otherwise a stalled WinHTTP request leaks until its internal timeout fires (winhttp-no-abort-on-poll-timeout)")
}
Test("api_remote: _LLMRemote_PollRequest aborts WinHTTP on cancel and deadline give-up (winhttp-no-abort-on-poll-timeout)", _WNAPT_RemotePollAbortsOnGiveUp)

_WNAPT_OllamaGenericPollAbortsOnTimeout() {
	Body := _DriverFuncBody("_LLM_Ollama_PollGeneric")
	Assert(Body != "", "_LLM_Ollama_PollGeneric must exist in api_ollama.ahk")
	Assert(InStr(Body, "http.Abort()") > 0,
		"_LLM_Ollama_PollGeneric must call http.Abort() on its deadline timeout path so a never-responding endpoint does not leak the COM request until WinHTTP's own timeout fires (winhttp-no-abort-on-poll-timeout)")
}
Test("api_ollama: _LLM_Ollama_PollGeneric aborts WinHTTP on poll-timeout give-up (winhttp-no-abort-on-poll-timeout)", _WNAPT_OllamaGenericPollAbortsOnTimeout)
