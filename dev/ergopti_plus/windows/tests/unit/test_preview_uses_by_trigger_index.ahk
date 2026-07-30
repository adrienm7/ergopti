; tests/unit/test_preview_uses_by_trigger_index.ahk

; ==============================================================================
; MODULE: Regression — the preview resolves a Spec through the by-trigger
;         indexes (preview-still-walks-the-last-char-bucket)
; DESCRIPTION:
; _PreviewEngineWouldFire asks the engine whether it would fire a candidate. To
; find the engine's Spec it walked HSE_RegistryByLastChar[last char of trigger].
;
; ROOT CAUSE ENCODED: that is the exact scan the matcher already abandoned.
; Every star trigger ends in the magic key, so they all share ONE bucket of
; ~2100 entries — hotstring_match.ahk documents it at "~21 ms per press" as the
; reason HSE_FindMatchAtEnd was converted to the O(1) by-trigger indexes. The
; preview was the one production reader left on the old index, and it paid the
; FULL scan precisely in the useless case: a trigger the bucket does not hold,
; where the answer is the fail-open default.
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
		Assert(!_PreviewEngineWouldFire("abC"),
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
		HSE_Register("", "abC", 0, Map("Replacement", "expanded", "Category", "test", "Section", "bytrigger"))
		HSE_Buffer := "abC"
		HSE_StartIsWordBoundary := true
		Assert(_PreviewEngineWouldFire("abC"),
			"a trigger sitting at the end of the engine buffer on a word boundary must still be offered")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("hotstrings: the preview still offers a trigger the engine would fire",
	_PUBT_MatchingTriggerIsStillOffered)






; ======================================================================
; ======================================================================
; ======= 2/ The last-char bucket is no longer walked per render =======
; ======================================================================
; ======================================================================

_PUBT_PreviewDoesNotWalkTheLastCharBucket() {
	Body := _DriverFuncBody("_PreviewEngineWouldFire")
	Assert(Body != "", "_PreviewEngineWouldFire() must exist in the driver source")
	Assert(InStr(Body, "HSE_RegistryByLastChar") == 0,
		"the preview must not walk the last-char bucket — every star trigger shares one ~2100-entry bucket, and the matcher already replaced this scan for exactly that reason")

	Resolver := _DriverFuncBody("_PreviewSpecForTrigger")
	Assert(Resolver != "", "_PreviewSpecForTrigger() must exist as the single Spec resolver")
	Assert(InStr(Resolver, "HSE_RegistryByLastChar") == 0,
		"and the resolver must not reintroduce the bucket walk one level down")
	Assert(InStr(Resolver, "HSE_StarByTrigger") > 0,
		"it must resolve through the star by-trigger indexes the matcher uses")
	Assert(InStr(Resolver, "HSE_EndByTrigger") > 0,
		"and through their end-char twins, so an end-char candidate is resolved the same way")
}
Test("meta hotstrings: the preview resolves Specs through the by-trigger indexes",
	_PUBT_PreviewDoesNotWalkTheLastCharBucket)
