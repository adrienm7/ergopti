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
; An Ollama poll tick used a bare `try ready := http.WaitForResponse(0)`.
; A COM exception (network drop, Ollama crash) was swallowed silently, leaving
; ready=false and re-queuing the 50ms poller indefinitely — saturating the CPU
; for up to 3 minutes until the global deadline fired.
; Fix: explicit catch clause that notifies the caller and exits immediately.
; The guard below names no poll function: it derives the set of Ollama functions
; that actually call WaitForResponse and requires the contract of each. Pinning
; one name meant the guard fired when the dead WinHTTP generation poll (never
; armed, and reading an "http" key no entry ever carried) was deleted, which is
; the opposite of what it was written to protect.
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

; Every Ollama function that reads WaitForResponse, found by walking back from each
; call site to the column-0 definition that encloses it. Deriving the set is what
; makes this a guarantee ("whoever polls WinHTTP abandons on a COM error") instead
; of a spelling ("_LLM_Ollama_PollRequest abandons").
_OTR_OllamaWaitForResponseFns() {
	Src := _OTR_StripComments(_DriverDirConcat("modules/llm/api_ollama"))
	Names := []
	Pos := 1
	while (F := RegExMatch(Src, "i):=\s*\w+\.WaitForResponse\(", &M, Pos)) {
		Pos := F + M.Len
		Head := SubStr(Src, 1, F)
		Owner := ""
		P := 1
		while (G := RegExMatch(Head, "m)^(\w+)\([^\r\n]*\)\s*\{", &MD, P)) {
			P := G + MD.Len
			Owner := MD[1]
		}
		if (Owner != "")
			Names.Push(Owner)
	}
	return Names
}

_OTR_PollCatchesCom() {
	Names := _OTR_OllamaWaitForResponseFns()
	Assert(Names.Length >= 1,
		"the Ollama backend must still have at least one WaitForResponse poll for this invariant to mean anything (found " . Names.Length . ") — a scan that matches nothing would pass vacuously")

	for _, Name in Names {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must be resolvable in the driver source")

		; The bare `try ready := ...` swallows the error silently and re-queues
		; the poller — the fix requires an explicit catch that abandons
		Assert(RegExMatch(Body, "catch\s+as\s+\w+") > 0,
			Name . " must have an explicit catch clause for WaitForResponse COM errors (ollama-com-exception-busy-loop)")

		; The catch must notify the caller and exit, not re-queue the poller.
		; The completion callbacks route through _LLM_InvokeCallback so a throw
		; inside the callback cannot vanish; that changes how the call is spelled,
		; not what is asserted. Both failure-callback names in this backend are
		; accepted — the generic poll reports through on_err, the request polls
		; through on_fail — because the invariant is "the caller is told", not
		; which parameter carries the news.
		Assert(InStr(Body, "on_fail") > 0 or InStr(Body, "on_err") > 0,
			Name . " COM catch must notify the caller to honour the async contract (ollama-com-exception-busy-loop)")

		; And it must release the transport, or the socket and COM object stay
		; resident long after we stopped polling them.
		Assert(InStr(Body, ".Abort()") > 0 or InStr(Body, "_LLM_Ollama_Async.Delete") > 0,
			Name . " must release the in-flight request when it abandons, not merely stop looking at it")
	}
}
Test("api_ollama: every WaitForResponse poll catches the COM exception and aborts immediately (ollama-com-exception-busy-loop)", _OTR_PollCatchesCom)
