; tests/meta/test_ollama_trim_registry_min_id.ahk

; ==============================================================================
; MODULE: Ollama Trim Registry Min-ID Meta Test
; DESCRIPTION:
; Static source guards for two bugs in modules/llm/api_ollama.ahk:
;
; BUG 1 (trim-async-registry-map-order):
; _LLM_Ollama_TrimAsyncRegistry iterated the async Map with a for-loop and took
; the first key, relying on an undocumented insertion-order property. AHK v2
; Maps do NOT guarantee iteration order, so a random in-flight request was
; killed instead of the oldest one (lowest numeric ID).
; Fix: explicit min-ID scan before deletion.
;
; BUG 2 (ollama-com-exception-busy-loop):
; _LLM_Ollama_PollRequest used a bare `try ready := http.WaitForResponse(0)`.
; A COM exception (network drop, Ollama crash) was swallowed silently, leaving
; ready=false and re-queuing the 50ms poller indefinitely — saturating the CPU
; for up to 3 minutes until the global deadline fired.
; Fix: explicit catch clause that calls on_fail and exits immediately.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================
; =========================================================
; ======= 1/ TrimAsyncRegistry uses explicit min-ID =======
; =========================================================
; =========================================================

_OTR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_OTR_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_OTR_TrimUsesMinId() {
	Src := _OTR_StripComments(_OTR_ReadSource("modules/llm/api_ollama.ahk"))
	; Use the definition pattern (with trailing " {") to avoid matching the call site.
	Body := _DriverFuncBody("_LLM_Ollama_TrimAsyncRegistry")

	Assert(Body != "", "_LLM_Ollama_TrimAsyncRegistry must exist in api_ollama.ahk")

	; The fix searches explicitly for the minimum numeric ID.
	; 0x7FFFFFFFFFFFFFFF is the max signed 64-bit integer — a safe "larger than any real ID" sentinel.
	Assert(InStr(Body, "0x7FFFFFFFFFFFFFFF") > 0,
		"TrimAsyncRegistry must initialise oldest_id := 0x7FFFFFFFFFFFFFFF for explicit min search (trim-async-registry-map-order)")
	Assert(RegExMatch(Body, "if\s*\(\s*id\s*<\s*oldest_id\s*\)") > 0,
		"TrimAsyncRegistry must scan for the min ID with 'if (id < oldest_id)' (trim-async-registry-map-order)")

	; The old first-key shortcut (for id, entry in Map { ...; return }) must be gone
	Assert(!InStr(Body, "for oldest_id, oldest_entry in _LLM_Ollama_Async"),
		"TrimAsyncRegistry must NOT rely on first-key Map iteration — use explicit min scan (trim-async-registry-map-order)")
}
Test("api_ollama: TrimAsyncRegistry uses explicit min-ID scan (trim-async-registry-map-order)", _OTR_TrimUsesMinId)





; ====================================================
; ====================================================
; ======= 2/ PollRequest catches COM exception =======
; ====================================================
; ====================================================

_OTR_PollCatchesCom() {
	Src := _OTR_StripComments(_OTR_ReadSource("modules/llm/api_ollama.ahk"))
	Body := _DriverFuncBody("_LLM_Ollama_PollRequest")

	Assert(Body != "", "_LLM_Ollama_PollRequest must exist in api_ollama.ahk")

	; The bare `try ready := ...` swallows the error silently and re-queues
	; the poller — the fix requires an explicit catch that aborts
	Assert(RegExMatch(Body, "catch\s+as\s+\w+") > 0,
		"_LLM_Ollama_PollRequest must have an explicit catch clause for WaitForResponse COM errors (ollama-com-exception-busy-loop)")

	; The catch must call on_fail and exit, not re-queue the poller
	; Any of the three call shapes satisfies the invariant. The completion
	; callbacks now route through _LLM_InvokeCallback so a throw inside on_fail
	; cannot vanish; that changes how the call is spelled, not what is being
	; asserted — the COM catch must still notify the caller rather than
	; re-queueing the poller and spinning to the deadline.
	Assert(InStr(Body, "on_fail()") > 0 or InStr(Body, "on_fail.Call()") > 0
			or InStr(Body, "on_fail,") > 0,
		"_LLM_Ollama_PollRequest COM catch must call on_fail to honour the async contract (ollama-com-exception-busy-loop)")
}
Test("api_ollama: PollRequest catches COM exception and aborts immediately (ollama-com-exception-busy-loop)", _OTR_PollCatchesCom)
