; tests/meta/test_preview_matches_engine.ahk

; ==============================================================================
; MODULE: Regression — a previewed expansion must be one the engine will fire
; DESCRIPTION:
; Field report: the tooltip offered an expansion for a trigger followed by the
; magic key, but pressing the magic key produced the LAST LETTER DOUBLED instead
; of that expansion.
;
; ROOT CAUSE ENCODED:
; The preview and the matcher gated on two different word-boundary sets. The
; preview set was the engine terminator set plus the three double quotes, under
; a constant named PREVIEW_EXTRA_BOUNDARIES. So on a buffer holding an opening
; quote, one letter, then the magic key:
;
;   - the PREVIEW treats the quote as a boundary, sees `c` starting a word, and
;     renders the expansion;
;   - the MATCHER gates on the narrower terminator set, does not see a boundary,
;     and REFUSES the expansion;
;   - the repeat fallback then runs, and it tests the same predecessor against
;     the same narrow set in the OPPOSITE direction — so the quote PASSES and
;     the letter is doubled.
;
; One character blocked the real expansion and licensed the fallback that
; replaced it. Both halves of that are fixed by giving the boundary question a
; single answer: _HSE_WordBoundarySet(), derived on every read, which the preview
; set is assigned from — no cache on either side, so neither can go stale.
;
; The doubling is a FALLBACK. It must never win a buffer where a registered
; expansion is previewable — that is the invariant this file exists to hold.
;
; SCOPE: behavioural against the real matcher, plus the structural invariant
; that no second boundary definition can reappear.
; ==============================================================================

#Requires AutoHotkey v2.0

; Seed the engine buffer and feed a tail character, mirroring the harness in
; tests/unit/test_domain_expander.ahk. Returns the Spec or "".
_PME_Decide(Buffer, TailChar, StartIsBoundary := true) {
	global HSE_Buffer, HSE_StartIsWordBoundary
	HSE_Buffer := Buffer
	HSE_StartIsWordBoundary := StartIsBoundary
	return HSE_FeedChar(TailChar)
}

_PME_IsRepeat(Spec) {
	return Spec != "" and Spec.HasOwnProp("IsRepeat") and Spec.IsRepeat
}





; ===============================================
; ===============================================
; ======= 1/ The reported bug, end to end =======
; ===============================================
; ===============================================

; The exact field scenario: an opening quote, one letter, the magic key.
_PME_QuotedWordStillExpands() {
	global HSE_RepeatEnabled
	MK := "★"
	PrevRepeat := HSE_RepeatEnabled
	HSE_RepeatEnabled := true
	try {
		; "*" makes it a STAR trigger (fires on the magic key itself, no end char);
		; omitting "?" keeps the word-boundary requirement, which is the gate under test.
		HSE_Register("*", "c" . MK, 0, Map("Replacement", "cependant"))
		Spec := _PME_Decide('"c', MK)

		Assert(Spec != "",
			"an expansion registered for c+magic key must still match when the word is opened by a double quote — the preview anchors on the quote as a word boundary, so refusing here is exactly the divergence the user reported")
		Assert(!_PME_IsRepeat(Spec),
			"the REPEAT fallback must not win this buffer: the doubling is a fallback for when nothing matched, and a registered expansion is available here. This is the reported symptom — the tooltip showed the expansion and the magic key doubled the letter instead")
		Assert(Spec.HasOwnProp("Replacement") and Spec.Replacement == "cependant",
			"the matched spec must carry the expansion the preview promised")
	} finally {
		HSE_RepeatEnabled := PrevRepeat
	}
}

; The mirror case, so the fix is not "always prefer the expansion": mid-word,
; with no registered expansion available, doubling is still correct.
_PME_MidWordStillDoubles() {
	global HSE_RepeatEnabled
	MK := "★"
	PrevRepeat := HSE_RepeatEnabled
	HSE_RepeatEnabled := true
	try {
		Spec := _PME_Decide("ab", MK)
		if (Spec == "")
			Spec := HSE_TryRepeatKey(MK)
		Assert(_PME_IsRepeat(Spec),
			"mid-word with nothing registered, the magic key must still double the previous letter — the fallback has to keep working, or fixing the divergence would just break it the other way")
		Assert(Spec.Replacement == "bb",
			"the repeat must double the character before the magic key")
	} finally {
		HSE_RepeatEnabled := PrevRepeat
	}
}

; The repeat's own guard must agree with the gate rather than contradict it: at
; the START of a word there is nothing to double, and a quote opens a word.
_PME_RepeatRefusesAtWordStart() {
	global HSE_RepeatEnabled, HSE_Buffer, HSE_StartIsWordBoundary
	MK := "★"
	PrevRepeat := HSE_RepeatEnabled
	HSE_RepeatEnabled := true
	try {
		HSE_Buffer := '"c' . MK
		HSE_StartIsWordBoundary := true
		Spec := HSE_TryRepeatKey(MK)
		Assert(!_PME_IsRepeat(Spec),
			"the repeat fallback must refuse after an opening quote — the letter is the FIRST of its word, so doubling it is meaningless. Reading the narrow terminator set here is what let the quote satisfy both the expansion gate (as a non-boundary) and the repeat guard (as a non-terminator) at once")
	} finally {
		HSE_RepeatEnabled := PrevRepeat
	}
}





; =============================================================
; =============================================================
; ======= 2/ No second boundary definition may reappear =======
; =============================================================
; =============================================================

; The structural half. The behavioural cases above pin the quote; this pins the
; CLASS, so adding a fourth boundary character to one set and not the other
; fails here instead of shipping as another silent divergence.
_PME_PreviewAndEngineShareOneSet() {
	Assert(_HSE_WordBoundarySet() != "",
		"the engine word-boundary derivation must return a non-empty set")
	Preview := _PrefixWordBoundaries()
	Assert(Preview == _HSE_WordBoundarySet(),
		"the preview and the matcher must hold the SAME boundary value, not merely derive from a common source — any difference is a buffer on which the tooltip promises an expansion the engine refuses")
}

; The quotes must be in the shared set, and must still NOT be terminators: the
; two roles are different and collapsing them would break triggers whose body
; legitimately contains a quote.
_PME_QuotesBoundNotTerminate() {
	global HSE_WORD_TERMINATORS
	for Q in [Chr(0x22), Chr(0x201C), Chr(0x201D)] {
		Assert(InStr(_HSE_WordBoundarySet(), Q) > 0,
			"a double quote must count as a word boundary — it opens a word")
		Assert(InStr(HSE_WORD_TERMINATORS, Q) == 0,
			"a double quote must NOT become a trigger terminator — a trigger body may legitimately contain one, which is why the two sets exist")
	}
}

; Both branches of the gate must read one set. They test it in opposite
; directions on purpose; reading two different sets is what made a single
; character satisfy both at once.
_PME_GateReadsOneSetInBothBranches() {
	Body := _DriverFuncBody("_HSE_WordBoundaryAllows")
	Assert(Body != "", "_HSE_WordBoundaryAllows() must exist")
	Assert(InStr(Body, "HSE_WORD_TERMINATORS") == 0,
		"the word-boundary gate must not read the TERMINATOR set — that narrower set is what refused expansions the preview had already offered")
	Assert(InStr(Body, "Boundaries") > 0,
		"both branches must resolve the boundary set once and share it")
}


Test("meta hotstrings: a quoted word still expands on the magic key", _PME_QuotedWordStillExpands)
Test("meta hotstrings: mid-word doubling still works", _PME_MidWordStillDoubles)
Test("meta hotstrings: the repeat refuses at the start of a word", _PME_RepeatRefusesAtWordStart)
Test("meta hotstrings: preview and engine share one boundary set", _PME_PreviewAndEngineShareOneSet)
Test("meta hotstrings: quotes bound words without terminating triggers", _PME_QuotesBoundNotTerminate)
Test("meta hotstrings: the gate reads one set in both branches", _PME_GateReadsOneSetInBothBranches)
