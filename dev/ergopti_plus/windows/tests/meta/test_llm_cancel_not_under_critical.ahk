; tests/meta/test_llm_cancel_not_under_critical.ahk

; ==============================================================================
; MODULE: LLM Cancellation Off-Critical Meta Test
; DESCRIPTION:
; Guard for the transport kills that ran under the per-keystroke Critical, found
; by the 2026-07-21 performance audit.
;
; Every keystroke reaches LLM_Engine_OnKeystroke, which takes Critical and then
; cancels whatever generation is in flight. Critical suspends the message pump,
; so a TerminateProcess that does not return promptly -- an anti-virus filter on
; the target, a WerFault dialog -- or a cross-apartment WinHTTP Abort starves the
; keyboard hook for as long as it blocks. Flipping the cancelled flags is pure
; memory and belongs inside Critical, because the poll ticks read them; killing
; the transport is OS work and does not.
;
; This mirrors the fix already applied to the SPAWN side, which defers Run() and
; the payload write through a negative SetTimer.
;
; WHY THE OBVIOUS ASSERTION WOULD BE A NO-OP:
; Asserting that LLM_Engine_OnKeystroke / LLM_Engine_CancelInflight /
; LLM_Engine_StopGeneration contain no ProcessClose would pass against the
; UNFIXED driver, because none of them ever contained one: they call the three
; cancel helpers, and the kills live inside those. A guard has to name the
; helpers themselves or it certifies the defect.
;
; WHY THE SPLIT IS INSIDE THE HELPERS AND NOT AT THE CALL SITE:
; Critical in AHK v2 is thread state, not a counter. Releasing it inside
; CancelInflight would disarm the Critical that OnKeystroke took for its own
; debounce arming, and CancelInflight's finally would restore it anyway. A
; negative SetTimer is indifferent to nesting depth: the callback runs on a new
; thread once the current one ends.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================================
; =============================================================
; ======= 1/ Every cancel helper defers its OS/COM work =======
; =============================================================
; =============================================================

_LCNC_HelperDefersItsKill(Name) {
	Body := _DriverFuncBody(Name)
	Assert(Body != "", Name . "() must exist in the driver source")
	Assert(InStr(Body, "LLM_DeferCancelKills(") > 0,
		Name . " must hand its transport kill to LLM_DeferCancelKills - it is reached from the per-keystroke Critical, where a blocking TerminateProcess or a WinHTTP Abort starves the keyboard hook")
	Assert(InStr(Body, "ProcessClose(") == 0,
		Name . " must not call ProcessClose inline - that is the OS work this fix moved off the keystroke thread")
	Assert(InStr(Body, ".Abort()") == 0,
		Name . " must not call .Abort() inline - a cross-apartment COM call under Critical blocks the message pump")
}

_LCNC_AllCancelHelpersDeferTheirKills() {
	; All four live sites, not just the two the audit first named: the streams
	; helper reaches its kill through LLM_OllamaCancelStream, which is a call site
	; of its own and was missed by the first pass.
	for _, Name in ["LLM_OllamaCancelAllAsync", "LLM_OllamaCancelStream", "LLM_RemoteCancelAllAsync"]
		_LCNC_HelperDefersItsKill(Name)
}
Test("LLM: every cancellation helper defers its transport kill off the keystroke thread (llm-cancel-under-critical)",
	_LCNC_AllCancelHelpersDeferTheirKills)





; ==========================================================
; ==========================================================
; ======= 2/ The flags stay inside the critical span =======
; ==========================================================
; ==========================================================

; Deferring the FLAG would be a correctness regression, not an optimisation: the
; poll ticks decide whether to keep processing a response by reading it, so it
; has to be true before the current thread ends.
_LCNC_FlagsAreStillSetInline() {
	for _, Name in ["LLM_OllamaCancelAllAsync", "LLM_RemoteCancelAllAsync"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		Assert(InStr(Body, 'entry["cancelled"] := true') > 0,
			Name . " must keep flipping the cancelled flag inline - the poll ticks read it to decide whether to drop a late response, so deferring it would let a cancelled generation paint")
	}
	Stream := _DriverFuncBody("LLM_OllamaCancelStream")
	Assert(Stream != "", "LLM_OllamaCancelStream() must exist in the driver source")
	Assert(InStr(Stream, "handle.Cancelled := true") > 0,
		"LLM_OllamaCancelStream must keep flipping its handle flag inline for the same reason")
}
Test("LLM: cancellation flags are still set inline, only the kill is deferred (llm-cancel-under-critical)",
	_LCNC_FlagsAreStillSetInline)





; ===========================================================
; ===========================================================
; ======= 3/ The deferred kill runs on a fresh thread =======
; ===========================================================
; ===========================================================

_LCNC_DeferralUsesANewThread() {
	Body := _DriverFuncBody("LLM_DeferCancelKills")
	Assert(Body != "", "LLM_DeferCancelKills() must exist in the driver source")
	Assert(InStr(Body, "SetTimer(") > 0,
		"LLM_DeferCancelKills must use SetTimer - a negative period runs the callback on a NEW thread once the current one ends, which is what puts the kill outside Critical regardless of nesting depth")
	Assert(InStr(Body, "-1") > 0,
		"LLM_DeferCancelKills must arm its timer with a negative period, i.e. one shot as soon as the current thread finishes")

	Runner := _DriverFuncBody("_LLM_RunCancelKills")
	Assert(Runner != "", "_LLM_RunCancelKills() must exist in the driver source")
	Assert(InStr(Runner, "ProcessClose(") > 0,
		"_LLM_RunCancelKills must be the one place that actually kills the transport")
}
Test("LLM: the deferred cancellation runs on a thread of its own (llm-cancel-under-critical)",
	_LCNC_DeferralUsesANewThread)





; ===========================================================
; ===========================================================
; ======= 4/ The engine still calls the three helpers =======
; ===========================================================
; ===========================================================

; test_llm_input_cancels_generation pins these three names at the call site, so
; the refactor had to happen INSIDE the helpers. Restate it here so a future
; rename cannot quietly break that pairing.
_LCNC_EngineStillCallsTheHelpers() {
	Body := _DriverFuncBody("LLM_Engine_CancelInflight")
	Assert(Body != "", "LLM_Engine_CancelInflight() must exist in the driver source")
	for _, Name in ["LLM_OllamaCancelStreams(", "LLM_OllamaCancelAllAsync(", "LLM_RemoteCancelAllAsync("] {
		Assert(InStr(Body, Name) > 0,
			"LLM_Engine_CancelInflight must still call " . Name . " - the deferral belongs inside the helpers, so these call sites are unchanged")
	}
}
Test("LLM: the engine still cancels through the same three helpers (llm-cancel-under-critical)",
	_LCNC_EngineStillCallsTheHelpers)
