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
    Build := _DriverFuncBody("_TooltipBuildGuiLlm")
    Hide := _DriverFuncBody("TooltipHide")
    Assert(Show != "" and Build != "" and Hide != "", "LLM tooltip show/build/hide functions must exist")
    Assert(InStr(Show, "RenderGeneration := _TooltipGeneration + 1") > 0
        and InStr(Show,
            "_TooltipBuildGuiLlm(slots, active_idx, RenderGeneration, Meta)") > 0,
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
