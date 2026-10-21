; tests/unit/modules/hotstrings/prefix/test_prefix_visible_suggestion_epoch.ahk

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

; An old empty lookup can yield just as a populated lookup can. Drive both
; real empty branches, retaining the actual pending request and metric owner.
_PEHR_Transition(State) {
	global _PrefixInputContextGeneration, _PrefixDeferredGeneration, _KLLastShownSuggestion
	global _TooltipPendingRequest
	State["transitions"] += 1
	switch State["transition"] {
		case "content": _PrefixSetBuffer("later")
		case "context": _PrefixInputContextGeneration += 1
		case "surface":
			AssertTrue(TooltipShow([{ Text: "replacement", DurationSec: 1 }], 0, false))
		case "pause": Suspend(true)
		case "lifecycle": _PrefixDeferredGeneration += 1
		case "none": return
		default: throw Error("Unknown empty-lookup fixture transition.")
	}
	_KLLastShownSuggestion := State["replacement"]
	State["request"] := _TooltipPendingRequest
}

_PEHR_Collect(State, ContentGeneration, InputContextGeneration) {
	if State["branch"] == "candidates" {
		_PEHR_Transition(State)
		return []
	}
	return [{ Category: "fixture", Section: "filtered" }]
}

_PEHR_Resolve(State, Category, Section) {
	AssertEqual("fixture", Category)
	AssertEqual("filtered", Section)
	_PEHR_Transition(State)
	return { ShowTooltip: false }
}

_PEHR_EmptyLookup(Branch, Transition) {
	global _PrefixBuffer, _PrefixContentGeneration, _PrefixInputContextGeneration, _PrefixDeferredGeneration
	global _KLLastShownSuggestion, _PrefixVisibleFireDecisions
	global _TooltipPendingRequest, _TooltipActiveSurface
	global _TooltipGeneration, _TooltipRequestSerial
	AssertFalse(IsObject(_TooltipPendingRequest), "fixture refuses a pending tooltip owned by another test")
	AssertFalse(IsObject(_TooltipActiveSurface), "fixture refuses an active tooltip owned by another test")
	Saved := { Buffer: _PrefixBuffer, Content: _PrefixContentGeneration,
		Context: _PrefixInputContextGeneration, Lifecycle: _PrefixDeferredGeneration,
		Suggestion: _KLLastShownSuggestion, Decisions: _PrefixVisibleFireDecisions,
		TooltipGeneration: _TooltipGeneration, RequestSerial: _TooltipRequestSerial,
		Suspended: A_IsSuspended }
	PreviousCritical := Critical("On")
	State := Map("branch", Branch, "transition", Transition, "transitions", 0,
		"replacement", { Trigger: "fresh", Output: "new answer", Category: "personal", IsPrivate: true },
		"request", 0)
	try {
		Suspend(false)
		_PrefixSetBuffer("before")
		AssertTrue(TooltipShow([{ Text: "before", DurationSec: 1 }], 0, false))
		_KLLastShownSuggestion := { Trigger: "before", Output: "old answer", Category: "personal", IsPrivate: true }
		State["request"] := _TooltipPendingRequest
		_LookupAndRender(_PEHR_Collect.Bind(State), _PEHR_Resolve.Bind(State))
		AssertEqual(1, State["transitions"], "the actual empty branch must reach its interruptible boundary")
		if Transition == "none" {
			AssertFalse(IsObject(_TooltipPendingRequest), "a current empty answer still retires its own pending pixels")
			AssertFalse(IsObject(_KLLastShownSuggestion), "a current empty answer still dismisses its metric")
		} else {
			AssertTrue(_TooltipPendingRequest == State["request"],
				"an empty answer which lost ownership must not cancel the pending request")
			AssertTrue(_KLLastShownSuggestion == State["replacement"],
				"an empty answer which lost ownership must not dismiss the newer suggestion")
		}
	} finally {
		Suspend(false)
		TooltipHide("EmptyLookupFixture", true)
		_PrefixBuffer := Saved.Buffer
		_PrefixContentGeneration := Saved.Content
		_PrefixInputContextGeneration := Saved.Context
		_PrefixDeferredGeneration := Saved.Lifecycle
		_KLLastShownSuggestion := Saved.Suggestion
		_PrefixVisibleFireDecisions := Saved.Decisions
		_TooltipGeneration := Saved.TooltipGeneration
		_TooltipRequestSerial := Saved.RequestSerial
		Suspend(Saved.Suspended)
		Critical(PreviousCritical)
	}
}

for _PEHR_Branch in ["candidates", "items"] {
	for _PEHR_TransitionName in ["content", "context", "surface", "pause", "lifecycle", "none"]
		Test("prefix preview: empty " . _PEHR_Branch . " lookup after " . _PEHR_TransitionName
			. " keeps exact ownership (prefix-empty-render-owner)",
			_PEHR_EmptyLookup.Bind(_PEHR_Branch, _PEHR_TransitionName))
}
