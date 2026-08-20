; tests/meta/test_llm_presented_record_single_source.ahk

; ==============================================================================
; MODULE: LLM Presented-Record Single-Source Guard
; DESCRIPTION:
; Pins the root invariant that visible pixels and every acceptance semantic live
; on one active surface record. Parallel globals previously let a B build change
; Tab text/index/source while A pixels were still visible.
; ==============================================================================

#Requires AutoHotkey v2.0

_LPRS_VisibleSemanticsHaveOneOwner() {
	DriverSrc := _DriverSourceNoComments()
	for Legacy in ["_LLM_Tooltip_Slots", "_LLM_Tooltip_ActiveIdx",
			"_LLM_Tooltip_Visible", "_LLM_Tooltip_Loading",
			"_LLM_Tooltip_ShownAt", '"rendered_accept_source"'] {
		LegacyPos := InStr(DriverSrc, Legacy, true)
		Assert(LegacyPos == 0,
			"parallel visible-LLM owner must not exist: " . Legacy
			. " near " . SubStr(DriverSrc, Max(1, LegacyPos - 80), 180))
	}

	Commit := _DriverFuncBody("_LLM_TooltipCommitSurfaceState")
	Present := _DriverFuncBody("_TooltipPresentStack")
	Snapshot := _DriverFuncBody("LLM_TooltipGetAcceptSnapshot")
	Claim := _DriverFuncBody("LLM_TooltipClaimAcceptance")
	GetText := _DriverFuncBody("LLM_TooltipGetText")
	HotstringVisible := _DriverFuncBody("TooltipIsVisible")
	Hide := _DriverFuncBody("TooltipHide")
	Assert(InStr(Commit, "SurfaceToken.LlmPresented := Record") > 0,
		"candidate semantics must be attached to the detached surface")
	CommitPos := InStr(Present,
		'CommitFn.Call(PreparedSurface, RetiredSurface)')
	SwapPos := InStr(Present, "_TooltipActiveSurface := PreparedSurface")
	Assert(CommitPos > 0 and SwapPos > CommitPos,
		"surface semantics must attach before the one active-pointer publication")
	Assert(InStr(Snapshot, "Record: Record") > 0
		and InStr(Snapshot, "AcceptSource:") > 0
		and InStr(Snapshot, "ActiveIdx:") > 0,
		"acceptance must receive one tuple rather than independent live getters")
	Assert(InStr(Claim, "ObjPtr(Current) != ObjPtr(ExpectedRecord)") > 0,
		"acceptance must claim the exact record it validated")
	Assert(InStr(GetText, 'Record.Kind != "prediction"') > 0,
		"loading surfaces must expose no acceptable text")
	Assert(InStr(HotstringVisible, 'Critical("On")') > 0
		and InStr(HotstringVisible,
			"_LLM_TooltipPresentedFromSurface(Surface)") > 0
		and InStr(HotstringVisible, "return !IsObject(LlmRecord)") > 0,
		"hotstring visibility must atomically exclude an LLM-owned shared surface")
	RetirePos := InStr(Hide,
		"_LLM_TooltipRetireSurfaceRecord(RetiredSurface)")
	PixelHidePos := InStr(Hide,
		"_TooltipHideSurfaceObjects(RetiredSurface)", true, RetirePos)
	DetachPos := InStr(Hide, "_TooltipActiveSurface := 0", true,
		PixelHidePos)
	Assert(RetirePos > 0 and PixelHidePos > RetirePos
		and DetachPos > PixelHidePos,
		"hide must mask the exact pixels before semantic ownership says hidden")
	Assert(InStr(Hide,
		"ObjPtr(ExpectedSurface) != ObjPtr(_TooltipActiveSurface)") > 0
		and InStr(Hide,
			"and !IsSet(ExpectedSurface)") > 0,
		"an exact visible surface must remain actionable while a newer detached build owns the generation counter")
}

_LPRS_MetricsAndTimeoutFollowCommittedSurface() {
	Commit := _DriverFuncBody("_LLM_TooltipCommitSurfaceState")
	MarkSuggested := _DriverFuncBody("_LLM_TooltipMarkSurfaceSuggested")
	Present := _DriverFuncBody("_TooltipPresentStack")
	Show := _DriverFuncBody("LLM_TooltipShow")
	Assert(InStr(Commit, '_LLM_TooltipQueueMetricUnsafe("suggested"') == 0,
		"candidate attachment must not log a suggestion before pixel publication")
	PublishPos := InStr(Present,
		"Published := _TooltipPublishVisibleDecisions(PublishItems)")
	SuggestPos := InStr(Present,
		"_LLM_TooltipMarkSurfaceSuggested(PreparedSurface)")
	Assert(PublishPos > 0 and SuggestPos > PublishPos,
		"llm_suggested must be committed only after reveal/publication succeeds")
	Assert(InStr(MarkSuggested,
		'_LLM_TooltipQueueMetricUnsafe("suggested", Lifecycle)') > 0,
		"the committed surface lifecycle must own the one suggested event")
	ResolvePos := InStr(Show, 'HotstringsResolve("llm_prediction"')
	BuildPos := InStr(Show, "_TooltipBuildGuiLlm(")
	Assert(ResolvePos > 0 and BuildPos > ResolvePos,
		"the real prediction timeout must be resolved before GUI/UIA preparation")
	Assert(InStr(Present, "LlmPresented.TimeoutRemainingMs") > 0,
		"the common pixel commit must arm the timeout carried by that exact record")
}

Test("LLM presented record is the sole visible semantic owner (llm-presented-record)",
	_LPRS_VisibleSemanticsHaveOneOwner)
Test("LLM metrics and timeout belong to committed pixels (llm-presented-record)",
	_LPRS_MetricsAndTimeoutFollowCommittedSurface)
