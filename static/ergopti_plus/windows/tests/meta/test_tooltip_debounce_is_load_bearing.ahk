; tests/meta/test_tooltip_debounce_is_load_bearing.ahk

; ==============================================================================
; MODULE: The Tooltip Render Debounce Is Load-Bearing
; DESCRIPTION:
; The former fixed render waits also admitted the idle UIA provider. Removing
; those waits without a separate obligation made positioning unreachable.
; Exercise the real idle owner with early pixels, a cold worker, key release,
; and same-surface refinement; keep provider admission off the keyboard path.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Minimum slack between the preview render and the idle gate it must clear.
; Windows timer resolution is ~15.6 ms and A_TimeIdlePhysical is quantised the
; same way, so a margin thinner than one tick makes the UIA stage fire or not
; fire at random — which is worse than either outcome, because the tooltip would
; then anchor under the caret only some of the time and the bug would read as
; "flaky in Electron" rather than as a timing relationship.
global _TDB_MIN_IDLE_MARGIN_MS := 16





; ===================================
; ===================================
; ======= 2/ The relationship =======
; ===================================
; ===================================

_TDB_Constant(Name) {
	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "m)^global\s+" . Name . "\s*:=\s*(\d+)", &M) > 0,
		Name . " must be declared as a numeric global in the driver source")
	return M[1] + 0
}

_TDB_TheDebounceKeepsTheUiaGateReachable() {
	global _TDB_MIN_IDLE_MARGIN_MS
	PrefixMs := _TDB_Constant("_PREFIX_RENDER_DEBOUNCE_MS")
	RenderMs := _TDB_Constant("TOOLTIP_RENDER_DEBOUNCE_MS")
	IdleMs := _TDB_Constant("TOOLTIP_UIA_IDLE_REQUIRED_MS")

	Assert(PrefixMs + RenderMs < _TDB_MIN_IDLE_MARGIN_MS,
		"preview scheduling must not introduce a deliberate typing pause")
	_TPR_EarlyPixelsKeepIndependentIdleAdmission()

	; The reason the margin cannot simply be bought by lowering the gate: the gate
	; is what keeps a cross-process COM round-trip off an in-flight typing burst,
	; and a burst at a comfortable 6 characters per second leaves ~167 ms gaps.
	Assert(IdleMs >= 150,
		"TOOLTIP_UIA_IDLE_REQUIRED_MS (" . IdleMs . " ms) must stay above the gap between keystrokes in a normal typing burst (~167 ms at 6 char/s). Lowering it to buy margin for a shorter render debounce would put the cross-process UIA round-trip back inside the burst it exists to avoid, which is the 2560 ms stall this driver already measured once")
}





; =====================================================
; =====================================================
; ======= 3/ The delay armed is the delay named =======
; =====================================================
; =====================================================

_TDB_TheArmedDelayIsNotComputed() {
	Body := _DriverFuncBody("TooltipShow")
	Assert(Body != "", "TooltipShow() must exist in the driver source")

	Assert(InStr(Body,
		"Request.TimerFn := _TooltipDeferredShowFn.Bind(Request.Serial)") > 0
		and RegExMatch(Body,
			"SetTimer\(Request\.TimerFn,\s*-TOOLTIP_RENDER_DEBOUNCE_MS\s*\)") > 0,
		"TooltipShow must arm the next-turn render with its named delay; provider admission has a separate owner")

	; The specific shape that was proposed and rejected: a last-render timestamp
	; used to skip the wait when the previous render is already old. On the
	; preview path the previous render is ALWAYS older than 75 ms, so this is not
	; a coalescing optimisation at all — it deletes the delay outright.
	Assert(InStr(Body, "_LastRenderTick") == 0,
		"TooltipShow must not shorten its deferral based on when the last render happened. Two preview renders are always at least _PREFIX_RENDER_DEBOUNCE_MS apart, so such a check always takes the short branch: the effect is to remove the debounce entirely from the one path it is load-bearing on")
}


Test("meta tooltip-debounce: next-turn pixels retain independent idle admission",
	_TDB_TheDebounceKeepsTheUiaGateReachable)
Test("meta tooltip-debounce: the deferred render is armed with the named constant, not a computed delay",
	_TDB_TheArmedDelayIsNotComputed)
