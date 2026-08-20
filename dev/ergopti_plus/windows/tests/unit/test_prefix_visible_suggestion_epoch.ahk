; tests/unit/test_prefix_visible_suggestion_epoch.ahk

; ==============================================================================
; MODULE: Prefix Visible-Suggestion Epoch Tests
; DESCRIPTION:
; Exercises the production buffer-generation and immediate-dismiss helpers.
;
; ROOT CAUSE ENCODED:
; A debounce coalesces future work; it does not invalidate pixels already on
; screen. Every text mutation must therefore hide the old answer immediately,
; and an in-flight render must own the exact buffer generation it evaluated.
; ==============================================================================

#Requires AutoHotkey v2.0+

_PVSE_RecordHide(State, Tag, Force) {
	State["calls"] += 1
	State["tag"] := Tag
	State["force"] := Force
}

_PVSE_BufferGenerationRejectsAba() {
	global _PrefixBuffer, _PrefixContentGeneration
	SavedBuffer := _PrefixBuffer
	SavedGeneration := _PrefixContentGeneration
	try {
		_PrefixSetBuffer("att")
		SnapshotGeneration := _PrefixContentGeneration
		AssertTrue(_PrefixRenderStillCurrent("att", SnapshotGeneration))
		_PrefixSetBuffer("attx")
		AssertEqual(false,
			_PrefixRenderStillCurrent("att", SnapshotGeneration),
			"a later physical character must retire the old render")
		_PrefixSetBuffer("att")
		AssertEqual(false,
			_PrefixRenderStillCurrent("att", SnapshotGeneration),
			"restoring the same text must not revive its older render generation")
	} finally {
		_PrefixBuffer := SavedBuffer
		_PrefixContentGeneration := SavedGeneration
	}
}
Test("prefix preview: content generation rejects stale and ABA renders "
	. "(prefix-visible-suggestion-epoch)", _PVSE_BufferGenerationRejectsAba)

_PVSE_FireDecisionEpochRejectsSameTextContextAba() {
	global _PrefixBuffer, _PrefixContentGeneration
	global _PrefixInputContextGeneration
	global HSE_Buffer, HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
	global HSE_RegistryTransitionDepth
	global HSE_RebuildInProgress
	SavedPrefix := _PrefixBuffer
	SavedContent := _PrefixContentGeneration
	SavedContext := _PrefixInputContextGeneration
	SavedEngine := HSE_Buffer
	try {
		_PrefixSetBuffer("a")
		HSE_Buffer := "a"
		DecisionA := {
			RegistryGeneration: HSE_RegistryGeneration,
			RuntimeDecisionGeneration: HSE_RuntimeDecisionGeneration,
			BufferBefore: "a",
			BufferAfterCompletion: "a ",
			EndChar: " ",
			PrefixContentGeneration: _PrefixContentGeneration,
			PrefixInputContextGeneration: _PrefixInputContextGeneration
		}
		AssertTrue(_PrefixFireDecisionStillCurrent(DecisionA),
			"sanity: A owns the exact text and context it evaluated")

		; Home/reset changes the word-boundary context; the user then types the
		; identical text again. Buffer equality is now an ABA false positive.
		_PrefixInputContextGeneration += 1
		_PrefixSetBuffer("")
		_PrefixSetBuffer("a")
		HSE_Buffer := "a"
		AssertEqual(false, _PrefixFireDecisionStillCurrent(DecisionA),
			"A must lose at pixel commit after reset + same-text retype changes its input-context epoch")
		AssertEqual(false,
			HotstringPrefixWatcherDecisionItemsStillCurrent(
				[{ FireDecision: DecisionA }]),
			"the renderer oracle must carry the same ABA fence, not just dispatch claim")
	} finally {
		_PrefixBuffer := SavedPrefix
		_PrefixContentGeneration := SavedContent
		_PrefixInputContextGeneration := SavedContext
		HSE_Buffer := SavedEngine
	}
}
Test("prefix preview: same text in a new input context cannot publish old pixels "
	. "(prefix-visible-suggestion-context-aba)",
	_PVSE_FireDecisionEpochRejectsSameTextContextAba)

_PVSE_ArmedSuggestionHidesImmediately() {
	global _KLLastShownSuggestion
	SavedSuggestion := _KLLastShownSuggestion
	State := Map("calls", 0, "tag", "", "force", false)
	try {
		; Private avoids producing a keylogger row while still exercising the real
		; lifecycle state transition.
		_KLLastShownSuggestion := {
			Trigger: "secret", Output: "secret", Category: "Personal",
			IsPrivate: true
		}
		AssertTrue(_PrefixDismissStaleSuggestion("PrefixChanged",
			_PVSE_RecordHide.Bind(State)))
		AssertEqual(1, State["calls"])
		AssertEqual("PrefixChanged", State["tag"])
		AssertEqual(true, State["force"])
		AssertEqual(false, IsObject(_KLLastShownSuggestion),
			"the retired pixels and suggestion lifecycle must clear together")
	} finally {
		_KLLastShownSuggestion := SavedSuggestion
	}
}
Test("prefix preview: next character immediately retires visible suggestion "
	. "(prefix-visible-suggestion-epoch)",
	_PVSE_ArmedSuggestionHidesImmediately)

_PVSE_NoSuggestionKeepsHotPathEmpty() {
	global _KLLastShownSuggestion
	SavedSuggestion := _KLLastShownSuggestion
	State := Map("calls", 0)
	try {
		_KLLastShownSuggestion := ""
		AssertEqual(false, _PrefixDismissStaleSuggestion("PrefixChanged",
			_PVSE_RecordHide.Bind(State)))
		AssertEqual(0, State["calls"],
			"ordinary no-match typing must not enter tooltip teardown")
	} finally {
		_KLLastShownSuggestion := SavedSuggestion
	}
}
Test("prefix preview: no armed suggestion adds no hide work per keystroke "
	. "(prefix-visible-suggestion-epoch)", _PVSE_NoSuggestionKeepsHotPathEmpty)

_PVSE_UnpublishedSameTextOwnerCannotBeReusedOrEraseReplacement() {
	global _KLLastShownSuggestion
	SavedSuggestion := _KLLastShownSuggestion
	SurfaceA := { Name: "surface-a" }
	SurfaceB := { Name: "surface-b" }
	RecordA := {
		Trigger: "att",
		Output: "attention",
		Category: "star",
		IsPrivate: false,
		SurfaceToken: SurfaceA,
		SuggestedPublished: false
	}
	RecordB := {
		Trigger: "att",
		Output: "attention",
		Category: "star",
		IsPrivate: false,
		SurfaceToken: SurfaceB,
		SuggestedPublished: false
	}
	try {
		; A installed its pending metric record and yielded in guarded logging.
		_KLLastShownSuggestion := RecordA
		AssertFalse(_PrefixSuggestionRecordIsPublished(RecordA),
			"B must not borrow A's same-text record before A published it")

		; B wins the same Trigger/Output while A is yielded. A then resumes and
		; runs its failure cleanup; that cleanup must not erase B's owner.
		_KLLastShownSuggestion := RecordB
		AssertFalse(_PrefixClearSuggestionIfOwned(RecordA, SurfaceA),
			"resumed cleanup A must reject replacement record B")
		AssertTrue(IsObject(_KLLastShownSuggestion)
			and ObjPtr(_KLLastShownSuggestion) == ObjPtr(RecordB),
			"same-text replacement B must remain armed after cleanup A")

		; Defense in depth: even if a future fast path mutates an existing record's
		; token in place, the old token may not authorize clearing that record.
		RecordA.SurfaceToken := SurfaceB
		_KLLastShownSuggestion := RecordA
		AssertFalse(_PrefixClearSuggestionIfOwned(RecordA, SurfaceA),
			"cleanup authority must include the immutable surface token")
		AssertTrue(IsObject(_KLLastShownSuggestion),
			"a token-mismatched cleanup must leave the current owner intact")
	} finally {
		_KLLastShownSuggestion := SavedSuggestion
	}
}
Test("prefix metric: yielded same-text publisher cannot erase replacement "
	. "(prefix-suggestion-metric-owner-aba)",
	_PVSE_UnpublishedSameTextOwnerCannotBeReusedOrEraseReplacement)

_PVSE_RecordConsumedHide(State, Tag, Force) {
	global _KLLastShownSuggestion
	State["calls"] += 1
	State["tag"] := Tag
	State["force"] := Force
	State["suggestion_present"] := IsObject(_KLLastShownSuggestion)
	return true
}

_PVSE_ConsumedMetricRetiresBeforeVisibleDecisionHide() {
	global _KLLastShownSuggestion
	SavedSuggestion := _KLLastShownSuggestion
	State := Map("calls", 0, "tag", "", "force", false,
		"suggestion_present", true)
	try {
		_KLLastShownSuggestion := {
			Trigger: "att", Output: "attention", Category: "star",
			IsPrivate: false, SuggestedPublished: true
		}
		AssertTrue(_PrefixRetireConsumedSuggestion("PostFire",
			_PVSE_RecordConsumedHide.Bind(State)))
		AssertEqual(1, State["calls"])
		AssertEqual("PostFire", State["tag"])
		AssertEqual(true, State["force"])
		AssertFalse(State["suggestion_present"],
			"fire consumption must detach the metric before hide clears decisions")
		AssertFalse(IsObject(_KLLastShownSuggestion),
			"a consumed suggestion must stay silent after pixel retirement")
	} finally {
		_KLLastShownSuggestion := SavedSuggestion
	}
}
Test("prefix metric: fire consumes before visible-decision retirement "
	. "(prefix-suggestion-consumed-before-hide)",
	_PVSE_ConsumedMetricRetiresBeforeVisibleDecisionHide)

_PVSE_TooltipOwnerRejectsSurfaceAndRequestAba() {
	global _TooltipGeneration, _TooltipActiveSurface, _TooltipRequestSerial
	SavedGeneration := _TooltipGeneration
	SavedSurface := _TooltipActiveSurface
	SavedRequestSerial := _TooltipRequestSerial
	SurfaceA := { Name: "surface-a" }
	SurfaceB := { Name: "surface-b" }
	try {
		_TooltipGeneration := 41
		_TooltipRequestSerial := 17
		_TooltipActiveSurface := SurfaceA
		OwnerA := _PrefixCaptureTooltipOwner()
		AssertTrue(_PrefixTooltipOwnerStillCurrent(OwnerA))

		; Reusing the same numeric generations cannot revive an old surface.
		_TooltipActiveSurface := SurfaceB
		AssertFalse(_PrefixTooltipOwnerStillCurrent(OwnerA),
			"surface identity must close generation ABA")

		; A pending/replacement request can preempt the same active surface before
		; its pixels commit, so request ownership must be part of the snapshot too.
		_TooltipActiveSurface := SurfaceA
		_TooltipRequestSerial += 1
		AssertFalse(_PrefixTooltipOwnerStillCurrent(OwnerA),
			"request serial must close the pending-request finalizer gap")
	} finally {
		_TooltipGeneration := SavedGeneration
		_TooltipActiveSurface := SavedSurface
		_TooltipRequestSerial := SavedRequestSerial
	}
}
Test("prefix finalizer: exact tooltip owner rejects ABA replacements "
	. "(prefix-finalizer-tooltip-owner-aba)",
	_PVSE_TooltipOwnerRejectsSurfaceAndRequestAba)
