; tests/unit/test_preview_picks_engine_winner.ahk

; ==============================================================================
; MODULE: Regression — every preview row must be a canonical engine decision
;         (preview-candidate-set-anchored-at-the-word-boundary)
; DESCRIPTION:
; Typing « la dispo » and pausing offered « disponible » in the tooltip, and the
; magic key then produced « la disposition ». Two legitimate registered
; expansions, one advertised and a different one delivered, with nothing logged
; on either side.
;
; ROOT CAUSE ENCODED: the preview and the engine answered the same question over
; different derivations. The preview first selected rows from a file index, then
; asked a compatibility predicate whether one happened to match. That could not
; discover a different live winner, a same-trigger reload, a boundary-leading
; trigger, or a dispatch gate that declined after matching. The collector must
; now ask HSE_PreviewNextDecision directly and transport that exact decision to
; the visible row.
;
; The cure for a duplicated derivation is to delete the second copy. Thirty-nine
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
		HSE_Register("*", "dispo" . MK, 0,
			Map("Replacement", "disponible", "Category", "magickey", "Section", "preview"))
		LongSpec := HSE_Register("*", "la dispo" . MK, 0,
			Map("Replacement", "la disposition", "Category", "magickey", "Section", "preview"))

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
		Assert(Candidates[1].HasOwnProp("FireDecision")
			and ObjPtr(Candidates[1].FireDecision.Spec) == ObjPtr(LongSpec),
			"the row must transport the exact winning Spec, not a lookalike rebuilt from preview metadata")

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






; ==========================================================
; ==========================================================
; ======= 2/ No second candidate source may reappear =======
; ==========================================================
; ==========================================================

_PPEW_PreviewHasNoSecondWordAnchor() {
	Body := _DriverFuncBody("_LookupAndRender")
	Assert(Body != "", "_LookupAndRender() must exist in the driver source")
	Assert(InStr(Body, "LastTermPos") == 0,
		"the preview must not re-derive its own word anchor — the candidate set has to come from the buffer suffixes the matcher itself probes, or a trigger whose body spans a boundary becomes unreachable on the preview side only")
	Assert(InStr(Body, "_PrefixCollectCandidates") > 0,
		"the render must take its candidates from the single collector")

	Collect := _DriverFuncBody("_PrefixCollectCandidates")
	Assert(Collect != "", "_PrefixCollectCandidates() must exist as that collector")
	Assert(InStr(Collect, "HSE_Buffer") > 0
		and InStr(Collect, "HSE_PreviewNextDecision") > 0,
		"the collector must ask the engine for its complete decision over the engine buffer")
	for Forbidden in ["_PrefixIndex", "_PrefixBuffer", "_PrefixSortCandidates",
			"_PrefixCollectFromProviders", "_PreviewEngineWouldFire"] {
		Assert(InStr(Collect, Forbidden) == 0,
			"the canonical collector must not retain second candidate source: " . Forbidden)
	}
	RowBuilder := _DriverFuncBody("_PrefixCandidateFromDecision")
	Assert(RowBuilder != "", "_PrefixCandidateFromDecision() must exist in the driver source")
	Assert(InStr(RowBuilder, "FireDecision: Decision") > 0,
		"the complete engine decision must cross the collector-to-renderer boundary")
}
Test("meta hotstrings: the preview keeps no second word anchor of its own",
	_PPEW_PreviewHasNoSecondWordAnchor)





; ============================================================
; ============================================================
; ======= 3/ Stale catalogue rows cannot choose output =======
; ============================================================
; ============================================================

_PPEW_StaleIndexCannotShadowLiveSpec() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global _PrefixIndex, _TriggerSet, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	PrevIndex := _PrefixIndex
	PrevSet := _TriggerSet
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	_PrefixIndex := Map()
	_TriggerSet := Map()
	try {
		LiveSpec := HSE_Register("*?", "same" . MK, 0,
			Map("Replacement", "NEW", "Category", "test", "Section", "live"))
		_AddTriggerToIndex("same" . MK, "OLD", "test", "stale", 999)
		Assert(_PrefixIndex.Has("same"),
			"sanity: the stale catalogue row must exist for this regression to prove independence")
		HSE_Buffer := "same"
		HSE_StartIsWordBoundary := true

		Candidates := _PrefixCollectCandidates()
		AssertEqual(1, Candidates.Length,
			"one canonical completion must produce one row even when a stale catalogue copy exists")
		Row := Candidates[1]
		AssertEqual("NEW", Row.Output,
			"a same-trigger OLD catalogue row must never shadow the NEW replacement owned by the live registry")
		Assert(Row.HasOwnProp("FireDecision")
			and ObjPtr(Row.FireDecision.Spec) == ObjPtr(LiveSpec),
			"the row must retain the exact live Spec identity so a same-trigger reload cannot pass by string equality")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
		_PrefixIndex := PrevIndex
		_TriggerSet := PrevSet
	}
}
Test("hotstrings: a stale same-trigger index row cannot shadow the live engine Spec",
	_PPEW_StaleIndexCannotShadowLiveSpec)





; =========================================================
; =========================================================
; ======= 4/ Boundary-leading triggers stay visible =======
; =========================================================
; =========================================================

_PPEW_BoundaryLeadingTriggerUsesEngineBuffer() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global _PrefixBuffer, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	PrevPrefix := _PrefixBuffer
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		Spec := HSE_Register("*?", " " . MK, 0,
			Map("Replacement", "X", "Category", "test", "Section", "boundary"))
		; The watcher intentionally clears its display buffer on a boundary. The
		; engine buffer still owns that visible Space and is the only valid oracle.
		_PrefixBuffer := ""
		HSE_Buffer := " "
		HSE_StartIsWordBoundary := true

		Candidates := _PrefixCollectCandidates()
		AssertEqual(1, Candidates.Length,
			"a trigger whose body is one Space must remain collectable while _PrefixBuffer is empty")
		AssertEqual(" " . MK, Candidates[1].Trigger,
			"the row must name the boundary-leading trigger the engine will fire")
		Assert(ObjPtr(Candidates[1].FireDecision.Spec) == ObjPtr(Spec),
			"the boundary-leading row must carry the engine's exact Spec")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
		_PrefixBuffer := PrevPrefix
	}
}
Test("hotstrings: a boundary-leading magic trigger is collectable with an empty prefix buffer",
	_PPEW_BoundaryLeadingTriggerUsesEngineBuffer)





; ========================================================
; ========================================================
; ======= 5/ Dispatch declines fail preview closed =======
; ========================================================
; ========================================================

global _PPEW_RawPreviewCalls := 0

_PPEW_RawSideEffect(*) {
	global _PPEW_RawPreviewCalls
	_PPEW_RawPreviewCalls += 1
	return { Fired: true, Bs: 1, Ins: "X" }
}

_PPEW_RawCallbackFailsClosedWithoutRunning() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global _PPEW_RawPreviewCalls, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		_PPEW_RawPreviewCalls := 0
		HSE_Register("*?", "raw" . MK, _PPEW_RawSideEffect,
			Map("RawCallback", true, "Category", "test", "Section", "raw"))
		HSE_Buffer := "raw"
		HSE_StartIsWordBoundary := true

		AssertEqual(0, _PrefixCollectCandidates().Length,
			"a raw callback must fail preview closed because only executing it can reveal its verdict")
		AssertEqual(0, _PPEW_RawPreviewCalls,
			"previewing a raw callback must never execute its side effects")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("hotstrings: a raw callback fails preview closed without executing",
	_PPEW_RawCallbackFailsClosedWithoutRunning)


_PPEW_ExpiredTimeGateFailsPreviewClosed() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global LastSentCharacterKeyTime, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	SavedTimes := LastSentCharacterKeyTime
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		HSE_Register("*?", "ab" . MK, 0,
			Map("Replacement", "X", "TimeActivationSeconds", 0.001,
				"PrevCharKey", "b", "Category", "test", "Section", "time"))
		LastSentCharacterKeyTime := Map("b", A_TickCount - 1000)
		HSE_Buffer := "ab"
		HSE_StartIsWordBoundary := true

		AssertEqual(0, _PrefixCollectCandidates().Length,
			"a matcher winner whose activation window expired must not become a visible promise")
	} finally {
		LastSentCharacterKeyTime := SavedTimes
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("hotstrings: an expired activation gate fails preview closed",
	_PPEW_ExpiredTimeGateFailsPreviewClosed)


_PPEW_MixedCaseGateFailsPreviewClosed() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global ScriptInformation
	MK := ScriptInformation["MagicKey"]
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		HSE_Register("*?", "abc" . MK, 0,
			Map("Replacement", "expanded", "CaseConform", true,
				"Category", "test", "Section", "case"))
		HSE_Buffer := "aBc"
		HSE_StartIsWordBoundary := true

		AssertEqual(0, _PrefixCollectCandidates().Length,
			"a mixed-case conform verdict must fail preview closed exactly as dispatch does")
	} finally {
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("hotstrings: a mixed-case conform decline fails preview closed",
	_PPEW_MixedCaseGateFailsPreviewClosed)





; =================================================================
; =================================================================
; ======= 6/ Registry publication is one visible generation =======
; =================================================================
; =================================================================

_PPEW_RegistryTransitionFencesEveryDecisionSource() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global HSE_RegistryGeneration, HSE_RegistryTransitionDepth
	global HSE_RepeatEnabled, HSE_PersonalInfoCombosEnabled
	global PersonalInformation, PersonalInformationLetters, ScriptInformation
	MK := ScriptInformation["MagicKey"]
	SavedRepeat := HSE_RepeatEnabled
	SavedCombos := HSE_PersonalInfoCombosEnabled
	InfoWasSet := IsSet(PersonalInformation)
	LettersWereSet := IsSet(PersonalInformationLetters)
	SavedInfo := InfoWasSet ? PersonalInformation : 0
	SavedLetters := LettersWereSet ? PersonalInformationLetters : 0
	AssertEqual(0, HSE_RegistryTransitionDepth,
		"precondition: no earlier test may leak a registry-transition owner")
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	try {
		HSE_RepeatEnabled := true
		HSE_PersonalInfoCombosEnabled := true
		PersonalInformation := Map("first_name", "Ada")
		PersonalInformationLetters := Map("p", "first_name")
		OldSpec := HSE_Register("*?", "pub" . MK, 0,
			Map("Replacement", "OLD", "Category", "test", "Section", "old"))
		OldGeneration := HSE_RegistryGeneration
		HSE_Buffer := "pub"
		HSE_StartIsWordBoundary := true
		OldDecision := HSE_PreviewNextDecision(HSE_Buffer, MK)
		Assert(IsObject(OldDecision)
			and ObjPtr(OldDecision.Spec) == ObjPtr(OldSpec),
			"sanity: the pre-transition decision must belong to the old Spec")

		HSE_BeginRegistryTransition()
		try {
			Assert(HSE_RegistryTransitionDepth > 0,
				"the batch writer must raise its matcher fence before changing the registry")
			AssertEqual(0, _PrefixCollectCandidates().Length,
				"a registered match must not leak from a partially published registry")

			HSE_Buffer := "ab" . MK
			HSE_StartIsWordBoundary := true
			Assert(!IsObject(HSE_TryRepeatKey(MK)),
				"the repeat fallback must also decline while the registry cannot answer")

			HSE_Buffer := "@p" . MK
			HSE_StartIsWordBoundary := true
			Assert(!IsObject(HSE_TryPersonalInfoCombo(MK)),
				"the personal fallback must also decline while the registry cannot answer")

			HSE_RegistryClear()
			NewSpec := HSE_Register("*?", "pub" . MK, 0,
				Map("Replacement", "NEW", "Category", "test", "Section", "new"))
			HSE_Buffer := "pub"
			HSE_StartIsWordBoundary := true
			AssertEqual(0, _PrefixCollectCandidates().Length,
				"even a fully inserted new Spec remains invisible until the batch owner publishes it")
		} finally {
			HSE_EndRegistryTransition()
		}

		AssertEqual(0, HSE_RegistryTransitionDepth,
			"the outermost transition end must release the matcher fence exactly once")
		HSE_Buffer := "ab" . MK
		HSE_StartIsWordBoundary := true
		Assert(IsObject(HSE_TryRepeatKey(MK)),
			"sanity: the repeat fixture must become fireable once the transition fence is released")
		HSE_Buffer := "@p" . MK
		HSE_StartIsWordBoundary := true
		Assert(IsObject(HSE_TryPersonalInfoCombo(MK)),
			"sanity: the personal fixture must become fireable once the transition fence is released")
		HSE_Buffer := "pub"
		HSE_StartIsWordBoundary := true
		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length,
			"after publication the rebuilt registry must expose one canonical decision")
		AssertEqual("NEW", Rows[1].Output,
			"the post-transition row must expose only the new replacement")
		Assert(ObjPtr(Rows[1].FireDecision.Spec) == ObjPtr(NewSpec),
			"the post-transition row must carry the new Spec's exact identity")
		Assert(!_PrefixFireDecisionStillCurrent(OldDecision),
			"a decision captured before the transition must remain invalid even when the new registry reuses its trigger")
		Assert(HSE_RegistryGeneration > OldGeneration,
			"publishing the rebuilt registry must advance its monotonic generation")
	} finally {
		if HSE_RegistryTransitionDepth > 0
			HSE_EndRegistryTransition()
		HSE_RepeatEnabled := SavedRepeat
		HSE_PersonalInfoCombosEnabled := SavedCombos
		if InfoWasSet
			PersonalInformation := SavedInfo
		else
			PersonalInformation := unset
		if LettersWereSet
			PersonalInformationLetters := SavedLetters
		else
			PersonalInformationLetters := unset
		HSE_RegistryClear()
		HSE_HardReset()
	}
}
Test("hotstrings: a registry transition fences matcher and fallbacks until one new decision publishes",
	_PPEW_RegistryTransitionFencesEveryDecisionSource)


_PPEW_RegistryClearNeverReusesGenerationZero() {
	global HSE_RegistryGeneration
	BeforeClear := HSE_RegistryGeneration
	HSE_RegistryClear()
	AfterFirstClear := HSE_RegistryGeneration
	HSE_RegistryClear()
	AfterSecondClear := HSE_RegistryGeneration
	Assert(AfterFirstClear > BeforeClear and AfterSecondClear > AfterFirstClear,
		"each registry clear must increase the generation; resetting it permits an ABA-stale tooltip decision to become current again")
	Assert(AfterFirstClear != 0 and AfterSecondClear != 0,
		"HSE_RegistryClear must never reuse generation zero after the process has begun publishing registries")
}
Test("hotstrings: registry clear advances the generation instead of resetting it",
	_PPEW_RegistryClearNeverReusesGenerationZero)
