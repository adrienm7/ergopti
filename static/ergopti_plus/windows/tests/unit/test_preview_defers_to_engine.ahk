; static/ergopti_plus/windows/tests/unit/test_preview_defers_to_engine.ahk

; ==============================================================================
; MODULE: Preview / Engine Word-Boundary Agreement (regression)
; DESCRIPTION:
; The tooltip advertised an expansion the engine then refused. Typing "at" and
; pressing the magic key produced "att" (the repeat key doubling the "t"), while
; the tooltip offered "tt -> télétravail" — a trigger the engine will not fire
; mid-word. Pressing the magic key again did nothing, because the engine was
; right and the tooltip was wrong.
;
; ROOT CAUSE ENCODED — TWO BUFFERS, TWO QUESTIONS:
; The preview inferred "am I at a word start?" from its OWN anchor: the suffix
; after the last boundary character in _PrefixBuffer. The engine asks
; _HSE_WordBoundaryAllows(HSE_Buffer, Spec). Those are different questions over
; different buffers, and they diverge after any expansion because _PrefixBuffer
; is rebuilt by the watcher's post-expansion sync while HSE_Buffer keeps the real
; typed context.
;
; Measured, from the driver's own DEBUG log (2026-07-21 18:10:30):
;     OnChar: char='★' prefixBuf='at' hseBuf='…télétravail ⚠️ at'
;     FIRE trig='t★' bs=2 burst='{BackSpace 2}{Text}tt'
;     _LookupAndRender: buf='tt'  ->  prefix MATCH for 'tt' (2 candidates)
; The watcher's buffer became "tt"; the engine's stayed "…att". "tt" looked
; word-initial to the preview and mid-word to the engine.
;
; WHY IT WAS SILENT:
; Nothing throws. The tooltip renders, the engine declines, and the two never
; compare notes — the only symptom is a suggestion that refuses to be validated,
; which reads as "the magic key didn't work" rather than as a preview defect.
;
; THE FIX:
; _PrefixCollectCandidates asks HSE_PreviewNextDecision directly. That oracle
; runs the real matcher, ordered personal/repeat fallbacks and dispatch gates,
; so no preview-local candidate exists to bypass a boundary or hide a different
; fallback winner.
; ==============================================================================





; ===================================================
; ===================================================
; ======= 1/ The Preview Defers To The Engine =======
; ===================================================
; ===================================================

; Registers a single star trigger with the real engine and points the engine
; buffer at `Buf`, so the collector sees a faithful registry.
; @param Trigger The trigger to register (e.g. "tt★").
; @param Buf     The engine buffer to simulate.
_PreviewAgree_Setup(Trigger, Buf) {
	global HSE_RegistryByLastChar, HSE_StarSpecs, HSE_Buffer, HSE_StartIsWordBoundary
	global ScriptInformation
	if !IsSet(ScriptInformation)
		ScriptInformation := Map()
	if !ScriptInformation.Has("MagicKey")
		ScriptInformation["MagicKey"] := "★"
	; Clear through the engine's own entry point rather than re-initialising the
	; globals by hand: they are not all Maps (HSE_StarSpecs is an Array), and a
	; hand-built registry would be testing a shape the engine never produces.
	HSE_RegistryClear()
	; "*" marks a star trigger, no "?" so the trigger is word-anchored — the
	; same flags a normal magic-key hotstring is registered with.
	Spec := HSE_Register("*", Trigger, 0,
		Map("Replacement", "expanded", "OnlyText", true,
			"Category", "test", "Section", "boundary"))
	HSE_Buffer := Buf
	; The buffer start is a real word boundary in every case below, so a refusal
	; can only come from the character preceding the trigger — never from an
	; unknown left edge.
	HSE_StartIsWordBoundary := true
	return Spec
}

; @return The canonical row for Trigger, or "" when that trigger is not the
; engine's complete next decision.
_PreviewAgree_RowFor(Trigger) {
	for _, Row in _PrefixCollectCandidates() {
		if Row.Trigger == Trigger
			return Row
	}
	return ""
}

TestPreviewAgree_RefusesMidWordStarTrigger() {
	; The measured case: engine buffer ends "att", so the "tt" body of "tt★" is
	; preceded by a letter and the engine will not fire it.
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer att")
	Assert(!IsObject(_PreviewAgree_RowFor("tt" . "★")),
		"a star trigger whose body sits mid-word must NOT be offered — the engine refuses it, "
		. "so advertising it produces a tooltip the magic key cannot validate")
}
Test("preview: a mid-word star trigger is not offered",
	TestPreviewAgree_RefusesMidWordStarTrigger)

TestPreviewAgree_OffersStarTriggerAtWordStart() {
	; The mirror case — the fix must not silence legitimate suggestions.
	Spec := _PreviewAgree_Setup("tt" . "★", "je viens d’activer tt")
	Row := _PreviewAgree_RowFor("tt" . "★")
	Assert(IsObject(Row),
		"the same trigger at a genuine word start must still be offered, or the fix has "
		. "traded a false positive for a false negative")
	Assert(Row.HasOwnProp("FireDecision")
		and ObjPtr(Row.FireDecision.Spec) == ObjPtr(Spec),
		"the offered row must carry the exact live Spec selected by the canonical engine decision")
}
Test("preview: a word-initial star trigger is still offered",
	TestPreviewAgree_OffersStarTriggerAtWordStart)

TestPreviewAgree_RefusesWhenBodyIsNotTheSuffix() {
	; The SearchKey scan can surface a candidate whose body is not actually at
	; the end of the engine buffer. Offering it would advertise an expansion for
	; text the user has not typed.
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer atx")
	Assert(!IsObject(_PreviewAgree_RowFor("tt" . "★")),
		"a candidate whose body does not end the engine buffer must not be offered")
}
Test("preview: a candidate that does not match the buffer suffix is not offered",
	TestPreviewAgree_RefusesWhenBodyIsNotTheSuffix)

TestPreviewAgree_FailsClosedForUnknownTrigger() {
	global _PrefixIndex, _TriggerSet
	SavedIndex := _PrefixIndex
	SavedSet := _TriggerSet
	try {
		_PreviewAgree_Setup("tt" . "★", "je viens d’activer zz")
		_PrefixIndex := Map()
		_TriggerSet := Map()
		_AddTriggerToIndex("zz" . "★", "stale", "test", "removed", 999)
		Assert(_PrefixIndex.Has("zz"),
			"sanity: the obsolete catalogue row must exist for this test to prove it has no authority")
		Assert(!IsObject(_PreviewAgree_RowFor("zz" . "★")),
			"an unregistered trigger must fail closed even when the auxiliary catalogue still contains it")
	} finally {
		_PrefixIndex := SavedIndex
		_TriggerSet := SavedSet
	}
}
Test("preview: an unknown trigger fails closed",
	TestPreviewAgree_FailsClosedForUnknownTrigger)


; During a live rebuild the engine refuses every registered match and both
; fallbacks, so every preview source must stay closed until the new generation
; is published.
TestPreviewAgree_RebuildFenceOverridesFailOpen() {
	global HSE_RebuildInProgress
	PreviousRebuild := HSE_RebuildInProgress
	_PreviewAgree_Setup("tt" . "★", "je viens d’activer tt")
	try {
		HSE_RebuildInProgress := true
		AssertEqual(0, _PrefixCollectCandidates().Length,
			"a registered trigger must not be offered while the engine’s rebuild fence makes it unavailable")
	} finally {
		HSE_RebuildInProgress := PreviousRebuild
	}
}
Test("preview: the live-rebuild fence keeps every candidate closed",
	TestPreviewAgree_RebuildFenceOverridesFailOpen)

TestPreviewAgree_NoOpCandidateLosesToCanonicalFallback() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_RepeatEnabled
	global ScriptInformation
	MK := ScriptInformation["MagicKey"]
	SavedRepeat := HSE_RepeatEnabled
	HSE_RegistryClear()
	try {
		HSE_RepeatEnabled := true
		HSE_Register("*", "ok" . MK, 0,
			Map("Replacement", "ok" . MK, "Category", "test", "Section", "noop"))
		HSE_Buffer := "ok"
		HSE_StartIsWordBoundary := true

		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"the collector must expose only the canonical repeat decision")
		AssertEqual("k" . MK, Rows[1].Trigger,
			"the tooltip must advertise the repeat fallback, never the rejected no-op mapping")
		Assert(Rows[1].FireDecision.Spec.HasOwnProp("TransientKind")
			and Rows[1].FireDecision.Spec.TransientKind == "repeat",
			"the row must transport the engine-owned repeat decision, not rebuild a lookalike from the rejected candidate")
	} finally {
		HSE_RepeatEnabled := SavedRepeat
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("preview: a no-op candidate cannot hide the canonical repeat winner",
	TestPreviewAgree_NoOpCandidateLosesToCanonicalFallback)
