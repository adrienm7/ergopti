; tests/unit/test_preview_picks_engine_winner.ahk

; ==============================================================================
; MODULE: Regression — the preview's candidate set must be the engine's
;         (preview-candidate-set-anchored-at-the-word-boundary)
; DESCRIPTION:
; Typing « la dispo » and pausing offered « disponible » in the tooltip, and the
; magic key then produced « la disposition ». Two legitimate registered
; expansions, one advertised and a different one delivered, with nothing logged
; on either side.
;
; ROOT CAUSE ENCODED: the preview and the engine answered the same question over
; two different derivations. _LookupAndRender derived its CANDIDATE SET from a
; single index key — the tail of _PrefixBuffer after the last word-boundary
; character — while _PrefixAppendTypedChar wipes _PrefixBuffer on every boundary
; character. A key containing a space or an apostrophe was therefore
; structurally impossible to produce, even though _AddTriggerToIndex had indexed
; « la dispo★ » under exactly that key. The engine does the opposite: it probes
; EVERY suffix of HSE_Buffer and prefers the longer trigger.
; _PreviewEngineWouldFire cannot catch this — it only validates the candidate the
; preview already chose, it never asks which candidate the engine would pick.
;
; The cure for a duplicated derivation is to delete the second copy, so the
; candidate set now comes from the engine's own buffer suffixes. Thirty-nine
; bundled star triggers contain a word-boundary character in their body, so this
; is the common shape, not a corner case.
; ==============================================================================

#Requires AutoHotkey v2.0






; ==========================================================================
; ==========================================================================
; ======= 1/ The first candidate is the trigger the engine will fire =======
; ==========================================================================
; ==========================================================================

_PPEW_PreviewOffersTheEngineWinner() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global _PrefixIndex, _TriggerSet, _PrefixBuffer, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	PrevIndex := _PrefixIndex
	PrevSet := _TriggerSet
	PrevPrefixBuffer := _PrefixBuffer
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	_PrefixIndex := Map()
	_TriggerSet := Map()
	try {
		; The colliding pair straight out of the bundled magickey.toml: a short
		; trigger and a longer one whose body spans a space.
		HSE_Register("*", "dispo" . MK, 0, Map("Replacement", "disponible", "Category", "magickey", "Section", "preview"))
		HSE_Register("*", "la dispo" . MK, 0, Map("Replacement", "la disposition", "Category", "magickey", "Section", "preview"))
		; Priority passed explicitly so the index build does not go through the
		; override cascade — this test is about the candidate SET, not about
		; collision precedence, which _HSE_Beats already owns for both sides.
		_AddTriggerToIndex("dispo" . MK, "disponible", "magickey", "preview", 50)
		_AddTriggerToIndex("la dispo" . MK, "la disposition", "magickey", "preview", 50)

		; The state after typing « la dispo »: the preview buffer was wiped by the
		; space, the engine buffer was not.
		HSE_Buffer := "la dispo"
		HSE_StartIsWordBoundary := true
		_PrefixBuffer := "dispo"

		Candidates := _PrefixCollectCandidates()
		Assert(Candidates.Length >= 1,
			"the preview must find candidates for the text the engine is holding")
		Assert(Candidates[1].Trigger == "la dispo" . MK,
			"the preview's first (non-dimmed) candidate must be the trigger the engine will fire. Anchoring the lookup key at the last word boundary of the preview buffer makes every trigger whose body contains a space or an apostrophe unreachable, so the tooltip promised 'disponible' while the engine fired 'la disposition'")

		; And the engine really does prefer the longer, boundary-spanning trigger,
		; so the assertion above is measured against the real winner rather than
		; against an assumption about it.
		Winner := HSE_FeedChar(MK)
		Assert(IsObject(Winner),
			"sanity: the engine must match something for this buffer")
		Assert(Winner.Trigger == "la dispo" . MK,
			"sanity: the engine prefers the longer boundary-spanning trigger")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
		_PrefixIndex := PrevIndex
		_TriggerSet := PrevSet
		_PrefixBuffer := PrevPrefixBuffer
	}
}
Test("hotstrings: the preview offers the trigger the engine will fire (preview-candidate-set-anchored-at-the-word-boundary)",
	_PPEW_PreviewOffersTheEngineWinner)






; =====================================================
; =====================================================
; ======= 2/ No second word anchor may reappear =======
; =====================================================
; =====================================================

_PPEW_PreviewHasNoSecondWordAnchor() {
	Body := _DriverFuncBody("_LookupAndRender")
	Assert(Body != "", "_LookupAndRender() must exist in the driver source")
	Assert(InStr(Body, "LastTermPos") == 0,
		"the preview must not re-derive its own word anchor — the candidate set has to come from the buffer suffixes the matcher itself probes, or a trigger whose body spans a boundary becomes unreachable on the preview side only")
	Assert(InStr(Body, "_PrefixCollectCandidates") > 0,
		"the render must take its candidates from the single collector")

	Collect := _DriverFuncBody("_PrefixCollectCandidates")
	Assert(Collect != "", "_PrefixCollectCandidates() must exist as that collector")
	Assert(InStr(Collect, "HSE_Buffer") > 0,
		"and the collector must probe the ENGINE's buffer — deriving the set from the preview's own buffer is the duplication this whole finding is about")
	Assert(InStr(Collect, "_PrefixSortCandidates") > 0,
		"the union must still be ranked by the engine's own tie-break so the first row is the fire winner")
}
Test("meta hotstrings: the preview keeps no second word anchor of its own",
	_PPEW_PreviewHasNoSecondWordAnchor)
