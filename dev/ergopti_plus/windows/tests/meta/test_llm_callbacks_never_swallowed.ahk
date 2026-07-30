; tests/meta/test_llm_callbacks_never_swallowed.ahk

; ==============================================================================
; MODULE: Regression — an LLM completion callback that throws must not vanish
;         (llm-callbacks-never-swallowed)
; DESCRIPTION:
; Every LLM backend hands its result to a caller-supplied callback, and every
; one of those hand-offs was written as a bare `try on_x(...)`. A bare try
; discards the exception with no log line at all, so an engine-side throw — a
; malformed response the parser chokes on, a renderer hitting an unset global —
; looked exactly like a request that simply never completed. No prediction, no
; error, nothing to search the log for.
;
; ROOT CAUSE ENCODED: `try` without `catch` is not error handling, it is error
; deletion. The adapters were already ratcheted against precisely this shape
; (test_adapter_callback_swallow_logged.ahk, after the same bug in text_sender
; and http_client); the LLM backends were never brought in line, and grew to
; roughly fifty such sites.
;
; The audit rates these code-reading only, because the LLM subsystem was dormant
; across all eleven days of field logs — which is itself the point. A subsystem
; that has never run in anger is exactly where a silent failure mode survives,
; and the cost of finding out the hard way is a user reporting "predictions just
; don't appear" with an empty log to go on.
;
; SCOPE: behavioural for the wrapper (it is a pure function in the headless
; include graph); source-level for the absence of bare sites, which is the only
; way to assert that a shape is gone tree-wide.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ The wrapper logs instead of swallowing ================
; ==================================================================
; ==================================================================

; A callback that always raises, standing in for the real failure modes: a
; parser choking on a malformed response, a renderer hitting an unset global.
_LCS_Throws(Args*) {
	throw Error("boom")
}

; A throwing callback must be reported and contained: reported, or the failure
; is invisible; contained, because these run from HTTP completion handlers and
; timer callbacks where an escaping exception reaches the global error net and,
; before the driver is ready, is treated as fatal.
_LCS_ThrowingCallbackIsLoggedNotSwallowed() {
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	Threw := ""
	try {
		_LLM_InvokeCallback(_LCS_Throws, "on_success", "payload")
	} catch as Err {
		Threw := Err.Message
	}
	LoggerClearTestSink()

	Assert(Threw == "",
		"the wrapper must contain the exception — it runs from completion handlers where an escaping throw reaches the global error net and is fatal before the driver is ready. Got: " . Threw)

	Joined := ""
	for Line in Captured
		Joined .= Line . "`n"
	Assert(InStr(Joined, "on_success") > 0,
		"the log line must name the callback that threw, or the report is useless for locating it. Got: " . Joined)
	Assert(InStr(Joined, "boom") > 0,
		"the log line must carry the original error message — that is the whole content of the diagnosis. Got: " . Joined)
}

; The nominal path must be untouched: arguments forwarded verbatim, no logging.
_LCS_SuccessfulCallbackIsForwardedQuietly() {
	Seen := []
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	_LLM_InvokeCallback((A, B) => Seen.Push(A, B), "on_result", "first", 42)
	LoggerClearTestSink()

	Assert(Seen.Length == 2, "every argument must be forwarded to the callback")
	AssertEqual("first", Seen[1], "the first argument must arrive unchanged")
	AssertEqual(42, Seen[2], "the second argument must arrive unchanged")

	Joined := ""
	for Line in Captured
		Joined .= Line . "`n"
	Assert(InStr(Joined, "raised") == 0,
		"a callback that did not throw must produce no error line — a wrapper that logs on the happy path is noise nobody reads")
}

; A missing callback is a no-op, matching what the bare `try` did when a caller
; passed nothing. Making this throw would turn optional callbacks into crashes.
_LCS_MissingCallbackIsANoOp() {
	Threw := ""
	try _LLM_InvokeCallback("", "on_fail")
	catch as Err
		Threw := Err.Message
	Assert(Threw == "",
		"an absent callback must be a no-op — several backends leave on_partial and on_cancel unset by design. Got: " . Threw)
}




; ==================================================================
; ==================================================================
; ======= 2/ No bare-try callback site survives ====================
; ==================================================================
; ==================================================================

; The shape, tree-wide. This is the assertion that makes the class closed: a new
; backend written in the old style would otherwise reintroduce the silence with
; nothing failing.
_LCS_NoBareTryCallbackRemains() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))
	Assert(Src != "", "the LLM module sources must be readable")

	Offenders := []
	for Line in StrSplit(Src, "`n", "`r") {
		Trimmed := Trim(Line, " `t")
		if RegExMatch(Trimmed, "^try\s+on_[A-Za-z_]\w*\s*\(")
			Offenders.Push(Trimmed)
	}
	Report := ""
	for O in Offenders
		Report .= "`n    " . O
	Assert(Offenders.Length == 0,
		"every LLM completion callback must route through _LLM_InvokeCallback. A bare `try on_x(...)` deletes the exception rather than handling it, so an engine-side throw is indistinguishable from a request that never completed. Offending site(s):" . Report)
}

; And the wrapper must actually be used, not merely defined — a guard that only
; forbids the old shape is satisfied by deleting the call entirely.
_LCS_WrapperIsWidelyUsed() {
	Src := _StripFullLineComments(_DriverDirConcat("modules/llm"))
	Uses := 0
	Pos := 1
	while (F := RegExMatch(Src, "_LLM_InvokeCallback\(", &M, Pos)) {
		Pos := F + M.Len
		Uses += 1
	}
	; Roughly fifty hand-offs across the Ollama, streaming and remote backends,
	; plus the definition itself.
	Assert(Uses >= 40,
		"the LLM backends must actually route their callbacks through the wrapper (found only " . Uses . " use(s)) — a scan that finds almost none means the calls were removed rather than wrapped")
}


Test("meta llm-callbacks-never-swallowed: a throwing callback is logged, not swallowed",
	_LCS_ThrowingCallbackIsLoggedNotSwallowed)
Test("meta llm-callbacks-never-swallowed: a successful callback is forwarded quietly",
	_LCS_SuccessfulCallbackIsForwardedQuietly)
Test("meta llm-callbacks-never-swallowed: a missing callback is a no-op",
	_LCS_MissingCallbackIsANoOp)
Test("meta llm-callbacks-never-swallowed: no bare-try callback site survives",
	_LCS_NoBareTryCallbackRemains)
Test("meta llm-callbacks-never-swallowed: the wrapper is widely used",
	_LCS_WrapperIsWidelyUsed)
