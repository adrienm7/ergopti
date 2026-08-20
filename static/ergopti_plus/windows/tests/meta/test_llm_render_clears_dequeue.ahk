; tests/meta/test_llm_render_clears_dequeue.ahk

; ==============================================================================
; MODULE: LLM Render Clears Dequeue State Meta Test
; DESCRIPTION:
; Regression guard for AHK-17: the LLM prediction render path did not clear the
; hotstring dequeue cycle state before rendering. When
; a hotstring expansion was in progress (_TooltipDequeueActive=true, with the
; 100ms _TooltipDequeuePollFn timer armed), a freshly-shown LLM prediction
; would be force-hidden or clobbered within 100ms by the next dequeue poll
; tick calling _TooltipDequeueRebuild with the hotstring items.
;
; The fix cancels both dequeue variables in LLM_TooltipShow's short generation
; reservation transaction, before the detached rich builder can pump messages.
; Clearing only at final surface commit is too late: the 100 ms poll can run
; during GUI/UIA preparation, advance the generation and starve the prediction.
;
; This test asserts (source introspection):
;   (a) the owner reservation clears _TooltipDequeueActive and Items together;
;   (b) both writes are inside the same Critical generation reservation;
;   (c) the transaction ends before _TooltipBuildGuiLlm begins expensive work.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TLRCD_CheckLlmRenderClearsDequeue() {
	Body := _DriverFuncBody("LLM_TooltipShow")
	Assert(Body != "", "LLM_TooltipShow must exist in ui/tooltip/llm.ahk")

	DequeueActivePos := InStr(Body, "_TooltipDequeueActive := false")
	DequeueItemsPos := InStr(Body, "_TooltipDequeueItems := 0")
	CriticalOn := InStr(Body, 'Critical("On")')
	CriticalOff := InStr(Body, "Critical(PreviousCritical)", true,
		Max(DequeueActivePos, DequeueItemsPos))
	BuildPos := InStr(Body, "_TooltipBuildGuiLlm(", true, CriticalOff)
	Assert(CriticalOn > 0 and DequeueActivePos > CriticalOn
		and DequeueItemsPos > CriticalOn,
		"AHK-17: both dequeue variables must clear inside the LLM generation reservation so the poll cannot observe a half-cancelled cycle")
	Assert(CriticalOff > DequeueActivePos and CriticalOff > DequeueItemsPos
		and BuildPos > CriticalOff,
		"AHK-17: dequeue cancellation must commit before detached GUI/UIA preparation can pump the always-armed 100 ms poll")
}


Test("meta ahk-17: LLM owner reservation clears dequeue before rich render",
	_TLRCD_CheckLlmRenderClearsDequeue)
