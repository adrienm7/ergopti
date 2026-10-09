; tests/meta/test_preview_engine_single_owner.ahk

; ==============================================================================
; MODULE: Regression — one owner for each shared rule, and no dead code in the
;         preview path (preview-engine-single-owner)
; DESCRIPTION:
; Three findings from the same zone, all consequences of the preview keeping its
; own copy of something the engine already owned.
;
;   L-04  COLLISION PRECEDENCE, WRITTEN TWICE. _PrefixCandidateBeats restated
;         the engine's _HSE_Beats rule and had drifted. Delegating that helper
;         was still insufficient: the preview retained a second candidate set,
;         provider union and post-selection predicate around the shared sort.
;
;   L-32  NEAR-MISS ANALYTICS, BLINDED. The star-fire path re-seeds the preview
;         from HSE_Buffer, so the buffer handed to _CheckNearMiss can hold
;         several words plus the replacement just inserted. Every registered
;         trigger is a single word, so after the first star fire of a sentence
;         no comparison could ever match again. The metric went quiet with no
;         error.
;
;   L-07/L-31  DEAD CODE. _SuffixAfterLastBoundary was orphaned when its only
;         caller was deleted, and TooltipRearmTimer had no callers at all while
;         still being advertised as public API.
;
;   G5  PERSONAL PROVIDER, SECOND MATCHER. The @ provider resolved only its own
;         exact trigger and rebuilt personal output from mutable state. It could
;         therefore advertise a fallback a shorter registered suffix beat, or a
;         newly saved value an old registered Spec could not emit.
;
; ROOT CAUSE ENCODED: a duplicated rule is not fixed by keeping the two copies
; in step — it is fixed by deleting the second one. Convention 5.6 says the same
; about code that is no longer reached.
;
; SCOPE: behavioural for the shared rules; source-level for the absence of the
; dead code, which is the only way to assert that something is gone.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================================
; ================================================================
; ======= 1/ The complete preview decision has one owner ===========
; ================================================================
; ================================================================

; This is deliberately transitive. Checking only the collector body would miss
; a sibling provider registered elsewhere or a compatibility predicate called
; one level above it — the exact incomplete-application pattern this repository
; has shipped repeatedly.
_PESO_CanonicalDecisionOwnsEveryPreviewRule() {
	Src := _DriverSourceNoComments()
	Collect := _StripFullLineComments(_DriverFuncBody("_PrefixCollectCandidates"))
	Oracle := _StripFullLineComments(_DriverFuncBody("HSE_PreviewNextDecision"))
	RowBuilder := _StripFullLineComments(_DriverFuncBody("_PrefixCandidateFromDecision"))
	Assert(Src != "", "the driver source must be readable")
	Assert(Collect != "" and Oracle != "" and RowBuilder != "",
		"the collector, canonical engine oracle and decision-to-row adapter must all exist")

	Assert(InStr(Collect, "HSE_PreviewNextDecision") > 0,
		"the collector must ask the canonical engine decision directly")
	Assert(InStr(Oracle, "HSE_FeedChar") > 0
		and InStr(Oracle, "HSE_TryPersonalInfoCombo") > 0
		and InStr(Oracle, "HSE_TryRepeatKey") > 0
		and InStr(Oracle, "_HSE_PrepareDispatchDecision") > 0,
		"one oracle must own registered matching, ordered fallbacks and every dispatch preflight gate")
	Assert(InStr(RowBuilder, "FireDecision: Decision") > 0,
		"the canonical decision must cross the renderer boundary intact")

	for Removed in ["_PreviewEngineWouldFire(", "_PrefixCandidateBeats(",
			"_PrefixSortCandidates(", "_PrefixCollectFromProviders(",
			"HotstringPrefixWatcherRegisterPreviewProvider(",
			"PersonalInfoPreviewProvider(", "_PrefixPreviewProviders"] {
		Assert(InStr(Src, Removed) == 0,
			"no production sibling may retain a second preview decision path: " . Removed)
	}
	for Forbidden in ["_PrefixIndex", "_PrefixPreviewProviders", "HSE_PreviewNextMatch"] {
		Assert(InStr(Collect, Forbidden) == 0,
			"the production collector must not route around the complete decision: " . Forbidden)
	}
}




; ==================================================================
; ==================================================================
; ======= 2/ The near-miss scan measures the current word ==========
; ==================================================================
; ==================================================================

; The shared "current word" derivation, which is what makes the near-miss scan
; work again on a buffer that holds a whole sentence.
_PESO_WordTailIsTheCurrentWord() {
	AssertEqual("teh", _PrefixWordTail("bonjour le teh"),
		"the current word is the trailing run after the last boundary — a multi-word buffer must not be compared against single-word triggers as a whole")
	AssertEqual("teh", _PrefixWordTail("teh"),
		"a single-word buffer is entirely the current word")
	AssertEqual("", _PrefixWordTail("bonjour "),
		"a buffer ending on a boundary has no current word")
}

_PESO_NearMissMeasuresTheWord() {
	Body := _DriverFuncBody("_CheckNearMiss")
	Assert(Body != "", "_CheckNearMiss() must exist in the driver source")
	Assert(InStr(Body, "_PrefixWordTail") > 0,
		"the near-miss scan must compare the current WORD. The star-fire path re-seeds the preview from HSE_Buffer, so the buffer it receives can hold several words plus a just-inserted replacement — and since every trigger is a single word, a whole-buffer comparison can never match again after the first star fire of a sentence")
	Assert(InStr(Body, "StrLower(Buf)") == 0,
		"the scan must not key off the raw buffer any more — that is the comparison that went permanently blind")
}




; ==================================================================
; ==================================================================
; ======= 3/ The dead code is gone and stays gone ==================
; ==================================================================
; ==================================================================

; Convention 5.6: removed means removed. Both of these sat in the preview path
; looking like live behaviour while nothing could reach them.
_PESO_DeadCodeIsRemoved() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")

	Assert(InStr(Src, "_SuffixAfterLastBoundary") == 0,
		"_SuffixAfterLastBoundary must stay removed — it was orphaned when the buffer-sync block that called it was deleted, and a helper nothing reaches is a standing invitation to reason about behaviour that does not happen")
	Assert(InStr(Src, "TooltipRearmTimer") == 0,
		"TooltipRearmTimer must stay removed — it had no callers while still being advertised as public API, and its one side effect (LLM_Bridge_ScheduleAfterHotstring) is already performed on the live path")
	Assert(InStr(Src, "_TooltipLastItems") == 0,
		"_TooltipLastItems must stay removed — it existed solely to feed TooltipRearmTimer, so leaving it behind would keep a write-only global alive")
}

; The behaviour the dead function claimed to own must still happen where it
; really lives, or "remove the dead code" would have removed a live feature.
_PESO_PostFireLlmSchedulingSurvives() {
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "LLM_Bridge_ScheduleAfterHotstring") > 0,
		"the post-hotstring LLM scheduling must still be invoked from the live prefix-watcher path — removing the dead re-arm helper must not have removed the behaviour it duplicated")
}





; ====================================================================
; ====================================================================
; ======= 4/ Immutable display values cross every boundary ===========
; ====================================================================
; ====================================================================

; The field and value snapshot must cross every producer boundary. A renderer
; contract alone is a false green if one registration site silently drops it.
_PESO_PersonalSnapshotCrossesEveryBoundary() {
	Builder := _StripFullLineComments(_DriverFuncBody("CreateHotstring"))
	Registration := _StripFullLineComments(_DriverFuncBody("_HS_RegisterTextExpansionAndDynamic"))
	Fallback := _StripFullLineComments(_DriverFuncBody("HSE_TryPersonalInfoCombo"))
	Display := _StripFullLineComments(_DriverFuncBody("_PrefixDecisionDisplayText"))
	Assert(Builder != "" and Registration != "" and Fallback != "" and Display != "",
		"every personal-preview producer and consumer must be discoverable before checking the snapshot contract")

	Assert(InStr(Builder, "Meta.PreviewFields") > 0 and InStr(Builder, "Meta.PreviewValues") > 0,
		"CreateHotstring must transport both halves of optional preview snapshot metadata onto the registered Spec")
	Assert(InStr(Registration, 'Set("PreviewFields"') > 0
		and InStr(Registration, 'Set("PreviewValues"') > 0,
		"imperative personal-info registrations must attach the fields and values captured with their replacement")
	Assert(InStr(Fallback, "PreviewFields:") > 0 and InStr(Fallback, "PreviewValues:") > 0,
		"the fire-time personal fallback must return the same snapshot shape as a registered personal Spec")
	Assert(InStr(Display, "Spec.PreviewFields") > 0 and InStr(Display, "Spec.PreviewValues") > 0
		and InStr(Display, "PersonalInformation") == 0,
		"the row adapter must render the winning Spec's immutable snapshot and never re-read mutable personal state")
}

; Dynamic replacements may change on every call. The visible-decision claim is
; therefore part of the single-owner invariant: dispatch must reuse the resolved
; base that produced the pixels, not merely ask the same callable again.
_PESO_VisibleDynamicValueCrossesIntoDispatch() {
	Dispatch := _StripFullLineComments(_DriverFuncBody("HSE_DispatchMatch"))
	Claim := _StripFullLineComments(_DriverFuncBody("HotstringPrefixWatcherClaimVisibleDecision"))
	Publish := _StripFullLineComments(_DriverFuncBody("HotstringPrefixWatcherPublishVisibleDecisions"))
	Current := _StripFullLineComments(_DriverFuncBody("_PrefixFireDecisionStillCurrent"))
	Assert(Dispatch != "" and Claim != "" and Publish != "" and Current != "",
		"dispatch and both visible-decision ownership boundaries must exist")
	Assert(InStr(Dispatch, "HotstringPrefixWatcherClaimVisibleDecision") > 0
		and InStr(Dispatch, "VisibleDecision.ResolvedBase") > 0,
		"dispatch must claim and reuse the exact dynamic base that produced the visible row")
	Assert(InStr(Claim, "SpecIdentity") > 0
		and InStr(Claim, "_PrefixFireDecisionStillCurrent") > 0,
		"a visible value may be claimed only by the exact Spec after the shared currency gate")
	Assert(InStr(Current, "BufferAfterCompletion") > 0
		and InStr(Current, "RegistryGeneration") > 0,
		"the shared currency gate must bind the decision to its completed buffer and registry generation")
	Assert(InStr(Publish, "_PrefixFireDecisionStillCurrent") > 0,
		"publication must reject a decision that became stale before pixels committed")
}


Test("meta preview-engine-single-owner: the complete preview decision has one owner",
	_PESO_CanonicalDecisionOwnsEveryPreviewRule)
Test("meta preview-engine-single-owner: the word tail is the current word",
	_PESO_WordTailIsTheCurrentWord)
Test("meta preview-engine-single-owner: the near-miss scan measures the word",
	_PESO_NearMissMeasuresTheWord)
Test("meta preview-engine-single-owner: the dead code is removed",
	_PESO_DeadCodeIsRemoved)
Test("meta preview-engine-single-owner: post-fire LLM scheduling survives",
	_PESO_PostFireLlmSchedulingSurvives)
Test("meta preview-engine-single-owner: personal snapshot crosses every producer boundary",
	_PESO_PersonalSnapshotCrossesEveryBoundary)
Test("meta preview-engine-single-owner: the visible dynamic value crosses into dispatch",
	_PESO_VisibleDynamicValueCrossesIntoDispatch)
