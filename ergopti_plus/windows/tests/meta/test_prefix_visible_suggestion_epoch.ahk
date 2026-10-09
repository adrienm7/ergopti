; tests/meta/test_prefix_visible_suggestion_epoch.ahk

; ==============================================================================
; MODULE: Prefix Visible-Suggestion Epoch Structural Guard
; DESCRIPTION:
; Pins the transitive class: every preview-buffer writer goes through the
; generation owner, typed characters hide old pixels before scheduling, and a
; yielded lookup revalidates at the TooltipShow publication boundary.
; ==============================================================================

#Requires AutoHotkey v2.0+

_PVSEM_EveryMutationUsesOneGenerationOwner() {
	Src := FileRead(A_ScriptDir
		. "\..\infra\hotstrings\hotstring_inputhook.ahk", "UTF-8")
	SetBody := _DriverFuncBody("_PrefixSetBuffer")
	Assert(SetBody != "", "_PrefixSetBuffer must remain source-visible")
	AssertContains(SetBody, "_PrefixBuffer := Value",
		"the canonical writer must publish the new preview text")
	AssertContains(SetBody, "_PrefixContentGeneration += 1",
		"the canonical writer must retire every older render")
	; One declaration initializer plus the canonical writer are the only direct
	; assignments permitted. Any sibling assignment would skip the epoch.
	DirectAssignments := 0
	Pos := 1
	while RegExMatch(Src, "m)^\s*(?:global\s+)?_PrefixBuffer\s*:=", &M, Pos) {
		DirectAssignments += 1
		Pos := M.Pos + M.Len
	}
	AssertEqual(2, DirectAssignments,
		"every runtime _PrefixBuffer mutation must route through _PrefixSetBuffer")
}
Test("prefix preview: all buffer writers share one content generation "
	. "(prefix-visible-suggestion-epoch)",
	_PVSEM_EveryMutationUsesOneGenerationOwner)

_PVSEM_TypedCharHidesBeforeItQueuesReplacement() {
	Body := _DriverFuncBody("_PrefixAppendTypedChar")
	HidePos := InStr(Body, "_PrefixDismissStaleSuggestion(", true)
	WritePos := InStr(Body, "_PrefixSetBuffer(", true, HidePos)
	SchedulePos := InStr(Body, "_PrefixScheduleRender()", true, WritePos)
	Assert(HidePos > 0 && WritePos > HidePos && SchedulePos > WritePos,
		"old pixels must hide before the new buffer is published and debounced")
}
Test("prefix preview: append hides old answer before replacement debounce "
	. "(prefix-visible-suggestion-epoch)",
	_PVSEM_TypedCharHidesBeforeItQueuesReplacement)

_PVSEM_RenderRechecksAtPublication() {
	Body := _DriverFuncBody("_LookupAndRender")
	SnapshotPos := InStr(Body, "ContentGeneration := _PrefixContentGeneration",
		true)
	ContextSnapshotPos := InStr(Body,
		"InputContextGeneration := _PrefixInputContextGeneration", true,
		SnapshotPos)
	CollectPos := InStr(Body,
		"_PrefixCollectCandidates(", true, ContextSnapshotPos)
	FirstGuard := InStr(Body, "_PrefixRenderStillCurrent(", true,
		CollectPos)
	DecisionGuard := InStr(Body,
		"HotstringPrefixWatcherDecisionItemsStillCurrent(Items)", true,
		FirstGuard)
	ShowPos := InStr(Body, "TooltipShow(Items)", true, DecisionGuard)
	Present := _DriverFuncBody("_TooltipPresentStack")
	PixelGuard := InStr(Present, "_TooltipDecisionItemsStillCurrent(")
	Reveal := InStr(Present, "_TooltipRevealPreparedSurfaces(", true,
		PixelGuard)
	Assert(SnapshotPos > 0 and ContextSnapshotPos > SnapshotPos
		and CollectPos > ContextSnapshotPos and FirstGuard > CollectPos
		and DecisionGuard > FirstGuard and ShowPos > DecisionGuard
		and PixelGuard > 0 and Reveal > PixelGuard,
		"a yielded lookup must revalidate before queuing, then the renderer must revalidate the immutable decision at pixel commit after its own GUI/UIA yields")
	Candidate := _DriverFuncBody("_PrefixCandidateFromDecision")
	Current := _DriverFuncBody("_PrefixFireDecisionStillCurrent")
	Assert(InStr(Candidate,
		"Decision.PrefixContentGeneration := ContentGeneration") > 0
		and InStr(Candidate,
			"Decision.PrefixInputContextGeneration := InputContextGeneration") > 0,
		"every immutable FireDecision row must carry both lookup epochs across the renderer boundary")
	Assert(InStr(Current,
		"Decision.PrefixContentGeneration != _PrefixContentGeneration") > 0
		and InStr(Current, "Decision.PrefixInputContextGeneration") > 0
		and InStr(Current,
			"Decision.RuntimeDecisionGeneration") > 0,
		"pixel publication and dispatch claim must reject text/context/runtime-source ABA decisions by epoch")
}
Test("prefix preview: stale callbacks cannot publish or resurrect old answer "
	. "(prefix-visible-suggestion-epoch)",
	_PVSEM_RenderRechecksAtPublication)

_PVSEM_MetricPublicationOwnsRecordAndSurface() {
	Shown := _StripFullLineComments(
		_DriverFuncBody("_NotifySuggestionShownForSurface"))
	Cleanup := _StripFullLineComments(
		_DriverFuncBody("_PrefixClearSuggestionIfOwned"))
	ReuseGuard := InStr(Shown, "_PrefixSuggestionRecordIsPublished(Prev)")
	Install := InStr(Shown, "_KLLastShownSuggestion := Record", true,
		ReuseGuard)
	CleanupCall := InStr(Shown,
		"_PrefixClearSuggestionIfOwned(Record, SurfaceToken)", true, Install)
	Identity := InStr(Cleanup,
		"ObjPtr(_KLLastShownSuggestion) == ObjPtr(Record)")
	Surface := InStr(Cleanup,
		"_PrefixSuggestionRecordOwnsSurface(Record, SurfaceToken)", true,
		Identity)
	Assert(ReuseGuard > 0 and Install > ReuseGuard and CleanupCall > Install,
		"same-text reuse must reject unpublished records and failed publisher cleanup must keep its original owner")
	Assert(Identity > 0 and Surface > Identity,
		"failed publisher cleanup must require both record identity and exact surface token")
}
Test("prefix metric: publisher cleanup is record-and-surface owned "
	. "(prefix-suggestion-metric-owner-aba)",
	_PVSEM_MetricPublicationOwnsRecordAndSurface)

_PVSEM_FireRetiresPixelsAndMetricBeforeCascadeMutation() {
	PostFire := _StripFullLineComments(
		_DriverFuncBody("_PrefixCommitPostFireEffect"))
	Reset := _StripFullLineComments(_DriverFuncBody("_ResetPrefixBuffer"))
	Retire := _StripFullLineComments(
		_DriverFuncBody("_PrefixRetireConsumedSuggestion"))

	PostRetire := InStr(PostFire,
		'_PrefixRetireConsumedSuggestion("PostFire")')
	PostWrite := InStr(PostFire, "_PrefixSetBuffer(Decision.Buffer)", true,
		PostRetire)
	PostSchedule := InStr(PostFire, "_PrefixScheduleRender()", true,
		PostWrite)
	Assert(PostRetire > 0 and PostWrite > PostRetire
		and PostSchedule > PostWrite,
		"a non-reset fire must retire old pixels/decisions before publishing and debouncing its cascade buffer")

	ConsumedBranch := InStr(Reset, "if ConsumedByFire")
	ResetRetire := InStr(Reset,
		'_PrefixRetireConsumedSuggestion("ResetBuf")', true,
		ConsumedBranch)
	DismissedHide := InStr(Reset, 'TooltipHide("ResetBuf", true)', true,
		ResetRetire)
	Assert(ConsumedBranch > 0 and ResetRetire > ConsumedBranch
		and DismissedHide > ResetRetire,
		"the reset fire branch must consume silently before any decision-clearing hide")

	Consume := InStr(Retire, "_NotifySuggestionConsumed()")
	InjectedHide := InStr(Retire, "HideFn.Call(DbgTag, true)", true,
		Consume)
	ProductionHide := InStr(Retire, "TooltipHide(DbgTag, true)", true,
		Consume)
	Assert(Consume > 0 and InjectedHide > Consume and ProductionHide > Consume,
		"every consumed retirement path must detach its metric before hiding visible decisions")
}
Test("prefix fire: consumed owner retires before cascade publication "
	. "(prefix-suggestion-consumed-before-hide)",
	_PVSEM_FireRetiresPixelsAndMetricBeforeCascadeMutation)

_PVSEM_FinalizersValidateAndHideOneExactOwnerTransaction() {
	ContextCommit := _StripFullLineComments(
		_DriverFuncBody("_PrefixCommitInputContext"))
	ContextCurrent := _StripFullLineComments(
		_DriverFuncBody("_PrefixInputCommitStillCurrent"))
	ContextFinish := _StripFullLineComments(
		_DriverFuncBody("_PrefixFinishInputContext"))
	BackspaceCommit := _StripFullLineComments(
		_DriverFuncBody("_PrefixCommitBackspace"))
	BackspaceCurrent := _StripFullLineComments(
		_DriverFuncBody("_PrefixBackspaceCommitStillCurrent"))
	BackspaceFinish := _StripFullLineComments(
		_DriverFuncBody("_PrefixFinishBackspace"))

	Assert(InStr(ContextCommit,
		"TooltipOwner: _PrefixCaptureTooltipOwner()") > 0
		and InStr(ContextCurrent,
			"_PrefixTooltipOwnerStillCurrent(Commit.TooltipOwner)") > 0,
		"input-context commits must capture and revalidate the exact tooltip owner")
	ContextCritical := InStr(ContextFinish, 'Critical("On")')
	ContextCheck := InStr(ContextFinish,
		"_PrefixInputCommitStillCurrent(Commit)", true, ContextCritical)
	ContextHide := InStr(ContextFinish,
		"_ResetPrefixBuffer(false, Commit.ClearedBuffer)", true,
		ContextCheck)
	ContextRestore := InStr(ContextFinish,
		"Critical(PreviousCritical)", true, ContextHide)
	Assert(ContextCritical > 0 and ContextCheck > ContextCritical
		and ContextHide > ContextCheck and ContextRestore > ContextHide,
		"input-context owner check and tooltip retirement must share one Critical transaction")

	Assert(InStr(BackspaceCommit,
		"TooltipOwner: _PrefixCaptureTooltipOwner()") > 0
		and InStr(BackspaceCurrent,
			"_PrefixTooltipOwnerStillCurrent(Commit.TooltipOwner)") > 0,
		"backspace commits must capture and revalidate the exact tooltip owner")
	BackspaceCritical := InStr(BackspaceFinish, 'Critical("On")')
	BackspaceCheck := InStr(BackspaceFinish,
		"_PrefixBackspaceCommitStillCurrent(Commit)", true,
		BackspaceCritical)
	BackspaceHide := InStr(BackspaceFinish,
		'TooltipHide("Backspace", true)', true, BackspaceCheck)
	BackspaceRestore := InStr(BackspaceFinish,
		"Critical(PreviousCritical)", true, BackspaceHide)
	Assert(BackspaceCritical > 0 and BackspaceCheck > BackspaceCritical
		and BackspaceHide > BackspaceCheck
		and BackspaceRestore > BackspaceHide,
		"backspace owner check and tooltip retirement must share one Critical transaction")
}
Test("prefix finalizer: exact tooltip owner check and hide are atomic "
	. "(prefix-finalizer-tooltip-owner-aba)",
	_PVSEM_FinalizersValidateAndHideOneExactOwnerTransaction)
