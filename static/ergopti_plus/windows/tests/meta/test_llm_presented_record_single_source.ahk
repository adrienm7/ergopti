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

_LPRS_StaleNavigationRepaintNeverHidesCurrentPixels() {
	; Function bodies stay contiguous under the move-resilient source helper, so
	; relative positions prove the stale-repaint branch precedes every pixel
	; retirement/reveal without pinning either production file path.
	Present := _StripFullLineComments(
		_DriverFuncBody("_TooltipPresentStack"))
	Show := _StripFullLineComments(_DriverFuncBody("LLM_TooltipShow"))
	Commit := _StripFullLineComments(
		_DriverFuncBody("_LLM_TooltipCommitSurfaceState"))
	Render := _StripFullLineComments(
		_DriverFuncBody("_LLM_TooltipRenderOwnedNavigation"))
	ScheduleDrain := _StripFullLineComments(
		_DriverFuncBody("LLM_NavEventOwner_ScheduleDrain"))
	RetryDrain := _StripFullLineComments(
		_DriverFuncBody("_LLM_NavEventOwnerRetryDrain"))
	Service := _StripFullLineComments(
		_DriverFuncBody("_LLM_NavEventOwnerService"))
	Assert(Present != "" and Show != "" and Commit != "" and Render != ""
		and ScheduleDrain != "" and RetryDrain != "" and Service != "",
		"navigation repaint ownership bodies must remain discoverable")

	BeginPos := InStr(Present, "LLM_NavEventOwner_BeginSurfaceSwap(")
	RetryPos := InStr(Present, 'NavSwap.Get("retry", false)', true, BeginPos)
	RetirePos := InStr(Present,
		"_LLM_TooltipRetireSurfaceRecord(RetiredSurface", true, RetryPos)
	HidePos := InStr(Present,
		"_TooltipHideSurfaceObjects(RetiredSurface)", true, RetryPos)
	SwapPos := InStr(Present,
		"_TooltipActiveSurface := PreparedSurface", true, RetryPos)
	RevealPos := InStr(Present,
		"_TooltipRevealPreparedSurfaces(PreparedSurface)", true, RetryPos)
	Assert(BeginPos > 0 and RetryPos > BeginPos
		and RetirePos > RetryPos and HidePos > RetryPos
		and SwapPos > RetryPos and RevealPos > RetryPos,
		"a stale navigation repaint must abort before semantics, pixels, pointer, or reveal can leave A")
	TypedRethrowPos := InStr(Present,
		"if CommitError is TooltipNavOwnerRetryError")
	ReportPos := InStr(Present, "_UiOracleReportError(", true,
		TypedRethrowPos)
	Assert(TypedRethrowPos > 0 and ReportPos > TypedRethrowPos,
		"the normal repaint race must rethrow without entering generic UI error reporting")

	RetryCatchPos := InStr(Show,
		"if _llm_build_err is TooltipNavOwnerRetryError")
	ServicePos := InStr(Show,
		"LLM_NavEventOwner_ScheduleDrain()", true, RetryCatchPos)
	RetryReturnPos := InStr(Show, "return false", true, ServicePos)
	GenericLogPos := InStr(Show, 'LoggerError("LLM.tt"', true,
		RetryReturnPos)
	GenericHidePos := InStr(Show, "LLM_TooltipHide(false", true,
		RetryReturnPos)
	Assert(RetryCatchPos > 0 and ServicePos > RetryCatchPos
		and RetryReturnPos > ServicePos and GenericLogPos > RetryReturnPos
		and GenericHidePos > RetryReturnPos,
		"stale repaint retry must keep A visible, schedule its receipt drain, and bypass generic hide/log")
	Assert(InStr(Commit, "NavOwnerRequireExactIndex:") > 0
		and InStr(Commit,
			"SurfaceToken.RenderedActiveIdx := Record.ActiveIdx") > 0
		and InStr(Render, '"nav_owner_exact_index", true') > 0,
		"repaint records must carry both exact native-index matching and an immutable painted-index oracle")
	GetText := _StripFullLineComments(_DriverFuncBody("LLM_TooltipGetText"))
	Snapshot := _StripFullLineComments(
		_DriverFuncBody("LLM_TooltipGetAcceptSnapshot"))
	Assert(InStr(GetText,
		"_LLM_TooltipPresentationIndexIsPainted(Presentation)") > 0
		and InStr(Snapshot,
			"_LLM_TooltipPresentationIndexIsPainted(Presentation)") > 0,
		"text and Tab acceptance must fail open until native semantics equal painted pixels")
	Assert(InStr(ScheduleDrain,
		"SetTimer(_LLM_NavEventOwnerRetryDrain, -1)") > 0,
		"one-shot retry must schedule the distinct drain callback")
	Assert(InStr(RetryDrain, "_LLM_NavEventOwnerDrain()") > 0,
		"the distinct one-shot callback must drain navigation receipts")
	Assert(InStr(Service, "_LLM_NavEventOwnerDrain(RenderFn)") > 0,
		"the repeating service callback must retain its injectable receipt drain")
	Assert(InStr(Show, "SetTimer(_LLM_NavEventOwnerService, -1)") == 0,
		"a repaint retry must not overwrite the repeating service timer")
}

Test("LLM presented record is the sole visible semantic owner (llm-presented-record)",
	_LPRS_VisibleSemanticsHaveOneOwner)
Test("LLM metrics and timeout belong to committed pixels (llm-presented-record)",
	_LPRS_MetricsAndTimeoutFollowCommittedSurface)
Test("LLM stale navigation repaint never hides current pixels (llm-presented-record)",
	_LPRS_StaleNavigationRepaintNeverHidesCurrentPixels)
