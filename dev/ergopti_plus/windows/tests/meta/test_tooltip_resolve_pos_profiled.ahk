; tests/meta/test_tooltip_resolve_pos_profiled.ahk

; ===============================================================================
; MODULE: Tooltip ResolvePos HotPath Profiling Guard
; DESCRIPTION:
; Regression guard for AHK-34: _TooltipResolvePosition() performs a blocking
; cross-process UIA COM call (GetFocusedElement + BoundingRectangle) whenever
; CaretGetPos fails — the normal case in Chromium/Electron editors. It is
; called on every keystroke during hotstring candidate rendering. The Build
; and Present sub-segments in TooltipShow were wrapped in HotPath_LogIfSlow,
; but the ResolvePosition call sandwiched between them was not, so a slow
; UIA/COM resolve was invisible in HotPath slow-segment logs (G4 violation).
;
; Fix (AHK-34): wrap the _TooltipResolvePosition() call in both render call sites
; (ui/tooltip/core.ahk: _TooltipShowNow; ui/tooltip/llm.ahk: _TooltipBuildGuiLlm)
; with HotPath_Now()/HotPath_LogIfSlow("Tooltip.ResolvePos", ...) to match the
; existing Build/Present instrumentation.
;
; This test asserts (source introspection):
;   _TooltipShowNow and _TooltipBuildGuiLlm bodies must contain
;   HotPath_LogIfSlow with the "Tooltip.ResolvePos" label so the hottest
;   blocking call cannot silently drop off the profiler again.
; ===============================================================================

#Requires AutoHotkey v2.0





; ===================================================================
; ===================================================================
; ======= 1/ ResolvePos is profiled in both tooltip renderers =======
; ===================================================================
; ===================================================================

_TTRPP_CheckResolvePosProfiled() {
	; _TooltipShowNow (core.ahk): the UIA COM segment must be in the HotPath
	Body := _DriverFuncBody("_TooltipShowNow")
	Assert(Body != "", "_TooltipShowNow() must exist in ui/tooltip/core.ahk")
	Assert(InStr(Body, "HotPath_LogIfSlow(" . Chr(0x22) . "Tooltip.ResolvePos" . Chr(0x22)) > 0,
		"AHK-34: _TooltipShowNow must wrap _TooltipResolvePosition() in a HotPath_LogIfSlow segment so a slow UIA/COM call surfaces in slow-segment logs (G4)")

	; _TooltipBuildGuiLlm (llm.ahk): the same gate for the LLM render path
	Body := _DriverFuncBody("_TooltipBuildGuiLlm")
	Assert(Body != "", "_TooltipBuildGuiLlm() must exist in ui/tooltip/llm.ahk")
	Assert(InStr(Body, "HotPath_LogIfSlow(" . Chr(0x22) . "Tooltip.ResolvePos" . Chr(0x22)) > 0,
		"AHK-34: _TooltipBuildGuiLlm must wrap _TooltipResolvePosition() in a HotPath_LogIfSlow segment so the LLM render path is also profiled (G4)")
}


Test("meta ahk-34: _TooltipResolvePosition is profiled in both tooltip renderers so slow UIA/COM resolves surface in HotPath logs",
	_TTRPP_CheckResolvePosProfiled)
