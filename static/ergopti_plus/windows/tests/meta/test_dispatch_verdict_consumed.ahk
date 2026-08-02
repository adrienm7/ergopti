; tests/meta/test_dispatch_verdict_consumed.ahk

; ==============================================================================
; MODULE: Regression — a declined expansion must never swallow the keystroke
;         (dispatch-verdict-consumed)
; DESCRIPTION:
; With Space configured as a tap-hold, typing an end-char trigger, pausing past
; the activation delay and tapping Space produced NOTHING: no expansion, and no
; space either. The keylogger recorded a hotstring fire that never happened, and
; HSE_Buffer kept a space the screen did not have, so the next trigger was
; mis-framed.
;
; ROOT CAUSE ENCODED: HSE_FeedChar returns a CANDIDATE, not a decision.
; HSE_DispatchMatch is the decision, and it declines on four distinct paths —
; the time-activation gate, a mixed-case conform verdict, a raw callback that
; refuses, and a spec with neither Replacement nor Callback. It reports every
; one of them through its return value, which _SpaceTap discarded before
; returning early, skipping the literal-space emission below.
;
; This is the exact class commit 356ba64c0 fixed in _OnPrefixChar. It was fixed
; at ONE of the two call sites; the sibling kept the bug for another two months.
; The guard below therefore enumerates EVERY call site from source rather than
; pinning the one that was found — the recurring shape in this driver is the one
; missed sibling, and a per-site assertion is the only form that catches it.
;
; SCOPE: behavioural for the decline verdict itself (the engine is in this
; runner's include graph); source-level for the call sites, because
; platform/remap/space.ahk defines live hotkeys and cannot be loaded headless.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ The verdict is real and reports a decline =============
; ==================================================================
; ==================================================================

; If the dispatch never declined, consuming its verdict would be pointless and
; every assertion in section 2 would be guarding nothing. Prove the decline
; exists first, through the same gate the field repro used.
_DVC_ExpiredGateDeclines() {
	global HSE_Buffer, HSE_Suppressed
	HSE_Suppressed := 0
	HSE_Buffer := "teh "

	; A spec whose activation window has already elapsed: PrevCharKey was never
	; registered with UpdateLastSentCharacter, so the gate reads it as expired.
	Spec := { Trigger: "teh", Replacement: "the", Length: 3,
		TimeActivationSeconds: 1, PrevCharKey: "￿_never_typed" }

	Fired := HSE_DispatchMatch(Spec, " ")
	Assert(Fired == false,
		"the time-activation gate must DECLINE and say so — if the dispatch cannot report a refusal, no caller can distinguish 'expanded' from 'refused to expand'")
}

; The opposite verdict must be equally real, or a caller could satisfy every
; guard by treating the dispatch as always-false and never expanding anything.
_DVC_EmptySpecDeclines() {
	Assert(HSE_DispatchMatch("", "") == false,
		"an empty spec must decline")
	Invoked := false
	Spec := { Trigger: "x", Callback: (EndChar) => (Invoked := true) }
	Assert(HSE_DispatchMatch(Spec, "") == true,
		"a spec whose callback ran must report a FIRE — a dispatch that always returned false would make every caller emit both the expansion and the literal keystroke")
	Assert(Invoked, "the callback must actually have been invoked")
}




; ==================================================================
; ==================================================================
; ======= 2/ Every call site consumes that verdict =================
; ==================================================================
; ==================================================================

; Collect the source line of every HSE_DispatchMatch CALL (the definition and
; comment mentions excluded), so the assertion is per-site rather than pinned to
; whichever site the bug was reported at.
_DVC_CallLines() {
	Lines := []
	for Line in StrSplit(_DriverSourceNoComments(), "`n", "`r") {
		Trimmed := Trim(Line, " `t")
		if !InStr(Trimmed, "HSE_DispatchMatch(")
			continue
		; The definition itself, not a call. Matched on the trailing `) {` rather
		; than on the line merely STARTING with the name: a bare, unguarded call
		; also starts with it once trimmed, and excluding those would make this
		; scan blind to the exact shape it exists to catch.
		if RegExMatch(Trimmed, "^HSE_DispatchMatch\([^\r\n]*\)\s*\{")
			continue
		Lines.Push(Trimmed)
	}
	return Lines
}

; A call whose result is neither assigned nor tested is a discarded verdict, and
; a discarded verdict is this bug. Both surviving shapes are accepted: assigning
; it to a local, or testing it inline in the condition that guards the fired
; branch.
_DVC_EveryCallSiteConsumesTheVerdict() {
	Calls := _DVC_CallLines()
	; Non-vacuity floor: the driver has the prefix-watcher site and the space
	; tap-hold site. A scan that matched nothing would pass silently.
	Assert(Calls.Length >= 2,
		"the scan must reach the real dispatch call sites (found only " . Calls.Length . ") — a scan that matches nothing cannot fail")

	for Line in Calls {
		Consumed := RegExMatch(Line, ":=\s*HSE_DispatchMatch\(")
			or RegExMatch(Line, "i)\bif\b[^\r\n]*HSE_DispatchMatch\(")
			or RegExMatch(Line, "i)\breturn\b[^\r\n]*HSE_DispatchMatch\(")
		Assert(Consumed,
			"every HSE_DispatchMatch call must consume its verdict — this line discards it: '" . Line . "'. A discarded decline means the caller reports an expansion that never reached the screen and swallows the keystroke it should have emitted instead")
	}
}

; The space tap-hold specifically: the literal space must remain reachable when
; the dispatch declines. Guarding the call is not enough if the early return
; still runs unconditionally.
_DVC_SpaceTapFallsThroughOnDecline() {
	Body := _DriverFuncBody("_SpaceTap")
	Assert(Body != "", "_SpaceTap() must exist in the driver source")

	DispatchPos := InStr(Body, "HSE_DispatchMatch")
	PressPos    := InStr(Body, 'TextPressKey("Space"')
	Assert(DispatchPos > 0, "_SpaceTap must still route the candidate through the dispatch")
	Assert(PressPos > DispatchPos,
		"the literal space must be emitted AFTER the expansion decision, so a decline still produces a space")

	; The keylogger fire record must live inside the fired branch. Logging it
	; before the verdict is what put phantom expansions in the metrics.
	;
	; Matched on either channel: the record is queued rather than written inline
	; (see fire-log-never-synchronous), and pinning one spelling would make this
	; guard fail the day the channel changes for an unrelated reason — while
	; still not noticing a record emitted before the verdict.
	LogPos := InStr(Body, "_HSE_QueueFireLog")
	if (LogPos == 0)
		LogPos := InStr(Body, "KL_LogHotstring")
	Assert(LogPos > 0,
		"_SpaceTap must still record the fire for the metrics pipeline, through the deferred queue or directly")
	Assert(LogPos > DispatchPos,
		"the hotstring fire must be logged only after the dispatch has confirmed it — a fire logged on a declined match is an expansion the user never saw")
	Assert(LogPos < PressPos,
		"the fire log belongs in the fired branch, above the literal-space fallthrough")
}


Test("meta dispatch-verdict-consumed: an expired activation gate declines and reports it",
	_DVC_ExpiredGateDeclines)
Test("meta dispatch-verdict-consumed: the fired verdict is equally real",
	_DVC_EmptySpecDeclines)
Test("meta dispatch-verdict-consumed: every dispatch call site consumes the verdict",
	_DVC_EveryCallSiteConsumesTheVerdict)
Test("meta dispatch-verdict-consumed: the space tap-hold still emits a space on decline",
	_DVC_SpaceTapFallsThroughOnDecline)
