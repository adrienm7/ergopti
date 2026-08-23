; tests/meta/test_tooltip_llm_render_epoch.ahk
;
; ==============================================================================
; MODULE: LLM Tooltip Render Epoch Meta Test
; DESCRIPTION:
; A streaming render can yield while resolving the UIA caret position. If a newer
; render or hide wins during that boundary, the old invocation must not publish
; its Gui, present it, arm a timer, or hide the newer surface.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLRE_LlmRenderIsGenerationFenced() {
    Show := _DriverFuncBody("LLM_TooltipShow")
	Reserve := _DriverFuncBody("_LLM_TooltipReserveLlmRender")
    Build := _DriverFuncBody("_TooltipBuildGuiLlm")
    Hide := _DriverFuncBody("TooltipHide")
	Assert(Show != "" and Reserve != "" and Build != "" and Hide != "",
		"LLM tooltip reserve/show/build/hide functions must exist")
	ShowFlat := RegExReplace(Show, "\s+", " ")
	ReserveCall := InStr(ShowFlat,
		"Reservation := _LLM_TooltipReserveLlmRender(Meta)")
	CaptureGeneration := InStr(ShowFlat,
		'RenderGeneration := Reservation["generation"]')
	CaptureSerial := InStr(ShowFlat,
		'RenderRequestSerial := Reservation["request_serial"]')
	BuildCall := InStr(ShowFlat,
		"_TooltipBuildGuiLlm(slots, active_idx, RenderGeneration, Meta, RenderRequestSerial)")
	Assert(InStr(Reserve, "RenderGeneration := _TooltipGeneration + 1") > 0
		and ReserveCall > 0 and CaptureGeneration > ReserveCall
		and CaptureSerial > CaptureGeneration and BuildCall > CaptureSerial,
        "LLM_TooltipShow must reserve a generation before building and pass that ownership to the renderer")
    Assert(InStr(Build, "if (RenderGeneration != _TooltipGeneration)") > 0
        and InStr(Build, "Pos := _TooltipResolvePosition()") > 0,
        "the LLM renderer must retain an explicit generation comparison around its UIA boundary")
    ResolvePos := InStr(Build, "Pos := _TooltipResolvePosition()")
    ResolveGuard := InStr(Build, "if (RenderGeneration != _TooltipGeneration)", , ResolvePos)
    PresentPos := InStr(Build, "_TooltipPresentStack", , ResolvePos)
    Assert(ResolveGuard > ResolvePos and PresentPos > ResolveGuard,
        "a stale LLM renderer must abort after UIA resolution before presenting its old surface")
    Assert(InStr(Build, "return true") > PresentPos and InStr(Build, "return false") > 0,
        "the renderer must report whether it still owns the generation so callers never arm a stale timer")
    Assert(InStr(Hide, "_TooltipGeneration += 1") > 0,
        "TooltipHide must invalidate a renderer that is currently waiting in UIA/GUI work")
}

Test("tooltip: LLM renders are fenced by a pre-build generation epoch (tooltip-llm-render-epoch)",
    _TLRE_LlmRenderIsGenerationFenced)

_TLRE_LlmRichRenderRetiresDeferredLoadingOwner() {
	Show := _DriverFuncBody("LLM_TooltipShow")
	Reserve := _DriverFuncBody("_LLM_TooltipReserveLlmRender")
	Build := _DriverFuncBody("_TooltipBuildGuiLlm")
	Assert(Show != "" and Reserve != "" and Build != "",
		"LLM rich show/build functions must exist for request-owner fencing")
	ShowFlat := RegExReplace(Show, "\s+", " ")
	ReserveFlat := RegExReplace(Reserve, "\s+", " ")
	BuildFlat := RegExReplace(Build, "\s+", " ")
	BuildCall := InStr(ShowFlat,
		"_TooltipBuildGuiLlm(slots, active_idx, RenderGeneration, Meta, RenderRequestSerial)")
	ReservationCall := InStr(ShowFlat,
		"Reservation := _LLM_TooltipReserveLlmRender(Meta)")
	Guard := InStr(ReserveFlat,
		"LLM_NavEventOwner_LifecycleBarrierActive()")
	OldRequest := InStr(ReserveFlat,
		"OldRequest := _TooltipPendingRequest")
	CancelOld := InStr(ReserveFlat,
		"SetTimer(OldRequest.TimerFn, 0)")
	ClearOld := InStr(ReserveFlat,
		"_TooltipPendingRequest := 0")
	BumpSerial := InStr(ReserveFlat,
		"_TooltipRequestSerial += 1")
	CaptureSerial := InStr(ReserveFlat,
		"RenderRequestSerial := _TooltipRequestSerial")
	Assert(BuildCall > 0 and ReservationCall > 0
		and ReservationCall < BuildCall and Guard > 0
		and OldRequest > Guard and CancelOld > OldRequest
		and ClearOld > CancelOld and BumpSerial > ClearOld
		and CaptureSerial > BumpSerial,
		"lifecycle admission must precede every deferred-owner mutation, then the rich result must capture one request serial before build")
	Present := InStr(BuildFlat,
		"_TooltipPresentStack(Pos, Row, false, [], RenderGeneration, true, RequestSerial, 0, StateCommit)")
	Assert(Present > 0
		and InStr(BuildFlat,
			"RenderGeneration, true, -1, 0, StateCommit") == 0,
		"the rich renderer must carry its exact request serial through the final common pixel commit")
}
Test("tooltip: rich LLM render retires a deferred loading owner before publication (tooltip-llm-render-epoch)",
	_TLRE_LlmRichRenderRetiresDeferredLoadingOwner)

_TLRE_LlmRequestIdentityOwnsReservationAndCommit() {
	Engine := _StripFullLineComments(
		_DriverFuncBody("LLM_Engine_OnResults"))
	LoadingEngine := _StripFullLineComments(
		_DriverFuncBody("_LLM_Engine_ShowLoadingTooltip"))
	Reserve := _StripFullLineComments(
		_DriverFuncBody("_LLM_TooltipReserveLlmRender"))
	Commit := _StripFullLineComments(
		_DriverFuncBody("_LLM_TooltipCommitSurfaceState"))
	CommitLoading := _StripFullLineComments(
		_DriverFuncBody("_LLM_TooltipCommitLoadingState"))
	Show := _StripFullLineComments(_DriverFuncBody("LLM_TooltipShow"))
	Present := _StripFullLineComments(_DriverFuncBody("_TooltipPresentStack"))
	Assert(Engine != "" and LoadingEngine != "" and Reserve != ""
			and Commit != "" and CommitLoading != ""
			and Show != "" and Present != "",
		"the engine, both publication fences, and typed drop path must be readable")
	EngineGuard := InStr(Engine, 'PresentationMeta["render_guard"]')
	EngineShow := InStr(Engine,
		"LLM_Tooltip_Show(display_slots, active, is_final, PresentationMeta)")
	Assert(EngineGuard > 0 and EngineShow > EngineGuard,
		"an identified engine render must carry its immutable guard into the tooltip")
	Assert(InStr(LoadingEngine, '"render_guard"') > 0,
		"the deferred loading tuple must carry the same immutable request guard")
	ReserveGuard := InStr(Reserve,
		"_LLM_TooltipRenderGuardIsCurrent(PresentationMeta)")
	ReserveMutation := InStr(Reserve, "OldRequest := _TooltipPendingRequest")
	PreserveDeadline := InStr(Reserve,
		"_LLM_TooltipPreserveActiveDeadline()")
	CancelTimer := InStr(Reserve, "SetTimer(_TooltipTimerFn, 0)")
	Assert(ReserveGuard > 0 and ReserveMutation > ReserveGuard
			and PreserveDeadline > ReserveMutation
			and CancelTimer > PreserveDeadline,
		"request identity must lose before reservation mutations, while A's exact deadline survives a detached build")
	CommitGuard := InStr(Commit,
		"_LLM_TooltipRenderGuardIsCurrent(Meta)")
	CommitPrevious := InStr(Commit,
		"Previous := _LLM_TooltipPresentedFromSurface(RetiredSurface)")
	CommitAttach := InStr(Commit, "SurfaceToken.LlmPresented := Record")
	Assert(CommitGuard > 0 and CommitPrevious > CommitGuard
			and CommitAttach > CommitPrevious,
		"a request superseded during GUI/UIA work must lose before reading or mutating the visible lifecycle")
	LoadingCommitGuard := InStr(CommitLoading,
		"_LLM_TooltipRenderGuardIsCurrent(Meta)")
	LoadingAttach := InStr(CommitLoading, "SurfaceToken.LlmPresented :=")
	Assert(LoadingCommitGuard > 0 and LoadingAttach > LoadingCommitGuard,
		"a cancelled deferred spinner must lose before attaching its tokenless loading record")
	Assert(InStr(Show, "_llm_build_err is TooltipLlmStaleRenderError") > 0
			and InStr(Present,
				"CommitError is TooltipLlmStaleRenderError") > 0,
		"a stale render must dispose only its detached candidate without generic hiding of A")
}

Test("tooltip: request identity is revalidated at reservation and pixel commit (ahk026-render-identity-boundary)",
	_TLRE_LlmRequestIdentityOwnsReservationAndCommit)

_TLRE_LoadingPauseDropNeverRetiresVisiblePrediction() {
	Show := _StripFullLineComments(_DriverFuncBody("TooltipShow"))
	ShowNow := _StripFullLineComments(_DriverFuncBody("_TooltipShowNow"))
	CommitLoading := _StripFullLineComments(
		_DriverFuncBody("_LLM_TooltipCommitLoadingState"))
	BeginSwap := _StripFullLineComments(
		_DriverFuncBody("LLM_NavEventOwner_BeginSurfaceSwap"))
	Assert(Show != "" and ShowNow != "" and CommitLoading != ""
		and BeginSwap != "",
		"loading admission, final commit, presenter and native fence must be readable")
	ShowBarrier := InStr(Show,
		"LLM_NavEventOwner_LifecycleBarrierActive()")
	ShowMutation := InStr(Show, "OldRequest := _TooltipPendingRequest")
	Assert(ShowBarrier > 0 and ShowMutation > ShowBarrier,
		"owned loading admission must lose the pause fence before request/timer mutation")
	CommitBarrier := InStr(CommitLoading,
		"LLM_NavEventOwner_LifecycleBarrierActive()")
	CommitAttach := InStr(CommitLoading, "SurfaceToken.LlmPresented :=")
	Assert(CommitBarrier > 0 and CommitAttach > CommitBarrier,
		"a pre-built loading candidate must recheck pause before semantic attachment")
	BeginRecordGuard := InStr(BeginSwap, "if IsObject(NewRecord)")
	NativeBegin := InStr(BeginSwap,
		'_LLM_NavEventOwnerCall("begin_swap"')
	Assert(BeginRecordGuard > 0 and NativeBegin > BeginRecordGuard,
		"tokenless LLM records must be fenced before native Begin while true hides remain allowed")
	RetryCatch := InStr(ShowNow,
		"if PresentError is TooltipNavOwnerRetryError")
	ShowFailHide := InStr(ShowNow, 'TooltipHide("ShowFail"')
	Assert(RetryCatch > 0 and ShowFailHide > RetryCatch,
		"the presenter must absorb a pause retry before generic ShowFail hiding can retire A")
}

Test("tooltip: tokenless loading cannot cross the navigation pause fence (llm-loading-pause-fence)",
	_TLRE_LoadingPauseDropNeverRetiresVisiblePrediction)

_TLRE_AcceptStatePublishesWithPixels() {
	Show := _DriverFuncBody("LLM_TooltipShow")
	Build := _DriverFuncBody("_TooltipBuildGuiLlm")
	Commit := _DriverFuncBody("_LLM_TooltipCommitSurfaceState")
	Present := _DriverFuncBody("_TooltipPresentStack")
	Current := _DriverFuncBody("_LLM_TooltipGetCurrentPresentation")
	Assert(Show != "" and Build != "" and Commit != "" and Present != "",
		"LLM show/build/state commit and common presenter must exist")
	Reservation := SubStr(Show, 1, InStr(Show, "_TooltipBuildGuiLlm("))
	Assert(InStr(Reservation, "_LLM_Tooltip_Slots := slots") == 0
		and InStr(Reservation, "_LLM_Tooltip_Visible := true") == 0
		and InStr(Reservation, "_LLM_Tooltip_ShownAt := A_TickCount") == 0,
		"detached B preparation must leave A's Tab/accept state visible until B wins the pixel commit")
	Assert(InStr(Commit, "Slots: slots.Clone()") > 0
		and InStr(Commit, "ActiveIdx:") > 0
		and InStr(Commit, "ShownAt:") > 0
		and InStr(Commit, "SurfaceToken.LlmPresented := Record") > 0,
		"the exact pixel-owner callback must attach every value Tab reads to one detached surface record")
	Assert(InStr(Build, "_LLM_TooltipCommitSurfaceState.Bind(") > 0
		and InStr(Build, "StateCommit") > 0,
		"the detached LLM builder must carry its pending state to the common commit")
	StateCommit := InStr(Present,
		"CommitFn.Call(PreparedSurface, RetiredSurface)")
	SurfaceSwap := InStr(Present, "_TooltipActiveSurface := PreparedSurface")
	Reveal := InStr(Present, "_TooltipRevealPreparedSurfaces(")
	Assert(StateCommit > 0 and SurfaceSwap > StateCommit and Reveal > SurfaceSwap,
		"LLM acceptance state must attach before the single surface publication and B reveal")
	Assert(InStr(Current, "Record.Generation != Surface.Generation") > 0
		and InStr(Current, "Surface.Generation != _TooltipGeneration") == 0,
		"candidate B's reserved build generation must not invalidate still-visible surface A semantics")
}
Test("tooltip: Tab sees A until B pixels and accept state commit together (llm-presented-record)",
	_TLRE_AcceptStatePublishesWithPixels)
