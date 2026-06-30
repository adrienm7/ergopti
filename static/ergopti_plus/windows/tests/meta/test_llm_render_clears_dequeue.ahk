; tests/meta/test_llm_render_clears_dequeue.ahk

; ==============================================================================
; MODULE: LLM Render Clears Dequeue State Meta Test
; DESCRIPTION:
; Regression guard for AHK-17: _TooltipBuildGuiLlm (the LLM prediction render
; path) did not clear the hotstring dequeue cycle state before rendering. When
; a hotstring expansion was in progress (_TooltipDequeueActive=true, with the
; 100ms _TooltipDequeuePollFn timer armed), a freshly-shown LLM prediction
; would be force-hidden or clobbered within 100ms by the next dequeue poll
; tick calling _TooltipDequeueRebuild with the hotstring items.
;
; The fix adds `_TooltipDequeueActive := false` and `_TooltipDequeueItems := 0`
; at the top of _TooltipBuildGuiLlm, before _TooltipSuspendSurfaces(). The
; dequeue poll bails immediately when both dequeue state variables are cleared
; (it checks items == 0 and !DequeueActive), so no clobber can occur.
;
; This test asserts (source introspection):
;   (a) _TooltipBuildGuiLlm body clears _TooltipDequeueActive.
;   (b) _TooltipBuildGuiLlm body clears _TooltipDequeueItems.
;   (c) Both clears appear BEFORE _TooltipSuspendSurfaces so the dequeue
;       poll cannot fire between teardown and GUI creation.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TLRCD_CheckLlmRenderClearsDequeue() {
	Body := _DriverFuncBody("_TooltipBuildGuiLlm")
	Assert(Body != "", "_TooltipBuildGuiLlm must exist in ui/tooltip/llm.ahk")

	; (a) Must clear _TooltipDequeueActive
	Assert(InStr(Body, "_TooltipDequeueActive := false"),
		"AHK-17: _TooltipBuildGuiLlm must set _TooltipDequeueActive := false before rendering so the 100 ms poll timer cannot clobber a freshly-shown LLM prediction")

	; (b) Must clear _TooltipDequeueItems
	Assert(InStr(Body, "_TooltipDequeueItems"),
		"AHK-17: _TooltipBuildGuiLlm must reset _TooltipDequeueItems to 0 before rendering so the dequeue poll sees an empty item list and bails immediately")

	; (c) Both clears must precede _TooltipSuspendSurfaces (the start of teardown)
	DequeueActivePos := InStr(Body, "_TooltipDequeueActive := false")
	DequeueItemsPos  := InStr(Body, "_TooltipDequeueItems")
	SuspendPos       := InStr(Body, "_TooltipSuspendSurfaces")
	Assert(DequeueActivePos > 0 && SuspendPos > 0 && DequeueActivePos < SuspendPos,
		"AHK-17: _TooltipDequeueActive := false must appear BEFORE _TooltipSuspendSurfaces in _TooltipBuildGuiLlm — the dequeue poll can fire in the gap between teardown and GUI creation")
	Assert(DequeueItemsPos > 0 && SuspendPos > 0 && DequeueItemsPos < SuspendPos,
		"AHK-17: _TooltipDequeueItems reset must appear BEFORE _TooltipSuspendSurfaces in _TooltipBuildGuiLlm")
}


Test("meta ahk-17: _TooltipBuildGuiLlm clears dequeue state before render to prevent 100ms poll clobber",
	_TLRCD_CheckLlmRenderClearsDequeue)
