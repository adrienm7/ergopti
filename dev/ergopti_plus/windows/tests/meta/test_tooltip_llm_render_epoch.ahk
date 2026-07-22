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
        and InStr(Show, "_TooltipBuildGuiLlm(slots, _LLM_Tooltip_ActiveIdx, RenderGeneration)") > 0,
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
