; tests/unit/test_preview_uses_by_trigger_index.ahk

; ==============================================================================
; MODULE: Regression — the preview delegates lookup to the complete engine
;         decision (preview-still-walks-the-last-char-bucket)
; DESCRIPTION:
; The retired preview predicate asked whether a pre-selected candidate would
; fire. To find its Spec it walked HSE_RegistryByLastChar[last char of trigger].
;
; ROOT CAUSE ENCODED: that is the exact scan the matcher already abandoned.
; Every star trigger ends in the magic key, so they all share ONE bucket of
; ~2100 entries — hotstring_match.ahk documents it at "~21 ms per press" as the
; reason HSE_FindMatchAtEnd was converted to the O(1) by-trigger indexes. The
; preview was the one production reader left on the old index, and it paid the
; FULL scan precisely in the useless case. The collector now asks the engine's
; complete decision and therefore shares its bounded by-trigger lookup without
; naming any registry index itself.
;
; It was also wrong, not merely slow. HSE_Register buckets a case-INSENSITIVE
; trigger under the LOWERCASED last character, while the preview looked up the
; raw one — so any CI trigger ending in an uppercase character always missed its
; bucket and took the fail-open path, advertising a row the engine would refuse.
; That is the behavioural half below.
; ==============================================================================

#Requires AutoHotkey v2.0






; ===================================================================
; ===================================================================
; ======= 1/ A trigger the engine would refuse is not offered =======
; ===================================================================
; ===================================================================

_PUBT_RowFor(Rows, Trigger) {
	for _, Row in Rows {
		if Row.Trigger == Trigger
			return Row
	}
	return ""
}

_PUBT_CaseInsensitiveTriggerIsResolved() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		; Case-insensitive (no "C" flag) and ending in an uppercase character:
		; HSE_Register files it under the lowercased last char, so the raw-last-char
		; lookup could never find it.
		HSE_Register("", "abC", 0, Map("Replacement", "expanded", "Category", "test", "Section", "bytrigger"))
		HSE_Buffer := "zz"
		HSE_StartIsWordBoundary := true
		Assert(!IsObject(_PUBT_RowFor(_PrefixCollectCandidates(), "abC")),
			"the preview must resolve the engine's Spec for a case-insensitive trigger ending in an uppercase character. Looking the bucket up by the RAW last character while the registry files it under the lowercased one made every such trigger miss and take the fail-open path, so the tooltip offered a row the engine would refuse against this buffer")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("hotstrings: the preview resolves a case-insensitive trigger through the by-trigger index (preview-still-walks-the-last-char-bucket)",
	_PUBT_CaseInsensitiveTriggerIsResolved)

; A trigger the engine WOULD fire must still be offered, or the fix would be a
; regression dressed up as a speed-up.
_PUBT_MatchingTriggerIsStillOffered() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		Spec := HSE_Register("", "abC", 0,
			Map("Replacement", "expanded", "Category", "test", "Section", "bytrigger"))
		HSE_Buffer := "abC"
		HSE_StartIsWordBoundary := true
		Row := _PUBT_RowFor(_PrefixCollectCandidates(), "abC")
		Assert(IsObject(Row),
			"a trigger sitting at the end of the engine buffer on a word boundary must still be offered")
		AssertEqual("abC", Row.Trigger,
			"the row must preserve the case-insensitive trigger's registered spelling")
		Assert(Row.HasOwnProp("FireDecision")
			and ObjPtr(Row.FireDecision.Spec) == ObjPtr(Spec),
			"the row must carry the exact Spec resolved through the engine's by-trigger lookup")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("hotstrings: the preview still offers a trigger the engine would fire",
	_PUBT_MatchingTriggerIsStillOffered)






; ===============================================================
; ===============================================================
; ======= 2/ No preview-local matcher may be reintroduced =======
; ===============================================================
; ===============================================================

_PUBT_PreviewDoesNotWalkTheLastCharBucket() {
	Body := _DriverFuncBody("_PrefixCollectCandidates")
	Oracle := _DriverFuncBody("HSE_PreviewNextDecision")
	Src := _DriverSourceNoComments()
	Assert(Body != "", "_PrefixCollectCandidates() must exist in the driver source")
	Assert(Oracle != "", "HSE_PreviewNextDecision() must exist in the driver source")
	Assert(Src != "", "the driver source must be readable")
	Assert(InStr(Body, "HSE_RegistryByLastChar") == 0,
		"the preview must not walk the last-char bucket — every star trigger shares one ~2100-entry bucket, and the matcher already replaced this scan for exactly that reason")
	Assert(InStr(Body, "HSE_PreviewNextDecision") > 0,
		"the collector must ask the canonical engine oracle for the complete decision")
	Assert(InStr(Oracle, "HSE_FeedChar") > 0,
		"the oracle must use the real matcher rather than duplicating its by-trigger lookup")
	Assert(InStr(Src, "_PreviewEngineWouldFire(") == 0,
		"the retired candidate predicate must stay deleted; keeping it recreates a second lookup path")
	for Forbidden in ["_PreviewSpecForTrigger", "HSE_SuffixMatches",
			"_HSE_WordBoundaryAllows", "HSE_StarByTrigger", "HSE_EndByTrigger"] {
		Assert(InStr(Body, Forbidden) == 0,
			"the preview collector must not retain duplicated matcher rule: " . Forbidden)
	}
}
Test("meta hotstrings: the preview delegates complete selection to the engine oracle",
	_PUBT_PreviewDoesNotWalkTheLastCharBucket)
