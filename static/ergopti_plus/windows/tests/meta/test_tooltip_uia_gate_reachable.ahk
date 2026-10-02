; tests/meta/test_tooltip_uia_gate_reachable.ahk

; ==============================================================================
; MODULE: Regression — the tooltip UIA stage is reachable on the preview path
;         (tooltip-uia-gate-reachable)
; DESCRIPTION:
; The former fixed render waits also admitted the idle UIA provider. Removing
; those waits without a separate obligation made positioning unreachable.
; Exercise the real idle owner with early pixels, a cold worker, key release,
; and same-surface refinement; keep provider admission off the keyboard path.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================================
; =========================================================================
; ======= 1/ The gate is satisfiable by the debounce in front of it =======
; =========================================================================
; =========================================================================

_TUGR_ConstantFromSource(Name) {
	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "global\s+" . Name . "\s*:=\s*(\d+)", &M) > 0,
		Name . " must be declared as a numeric global in the driver source")
	return M[1] + 0
}

_TUGR_TheIdleGateIsReachable() {
	PrefixMs := _TUGR_ConstantFromSource("_PREFIX_RENDER_DEBOUNCE_MS")
	RenderMs := _TUGR_ConstantFromSource("TOOLTIP_RENDER_DEBOUNCE_MS")
	IdleMs   := _TUGR_ConstantFromSource("TOOLTIP_UIA_IDLE_REQUIRED_MS")

	Assert(PrefixMs + RenderMs < IdleMs,
		"preview pixels must precede provider admission, not wait for it")
	; Reproduce the old unreachable-provider failure with the actual independent
	; owner: early pixels, zero probes before idle, then a cold-worker retry and
	; same-surface refinement without another character.
	_TPR_EarlyPixelsKeepIndependentIdleAdmission()
}





; =========================================================================
; =========================================================================
; ======= 2/ The singleton clamp is not gated on this caller ==============
; =========================================================================
; =========================================================================

_TUGR_TheClampIsNotGatedOnTheProbeDecision() {
	Body := _DriverFuncBody("_TooltipResolvePosition")
	Assert(Body != "", "_TooltipResolvePosition() must exist in the driver source")

	Assert(InStr(Body, "_TooltipScheduleUiaBounds") > 0,
		"_TooltipResolvePosition must still dispatch its bounds request")
	Assert(InStr(Body, "UIA.GetFocusedElement") = 0,
		"the bounds provider call must remain isolated from the resident tooltip callback")
}


Test("meta tooltip-uia-gate-reachable: early pixels retain an independent idle provider owner",
	_TUGR_TheIdleGateIsReachable)
Test("meta tooltip-uia-gate-reachable: the singleton timeout clamp is not gated on the probe decision",
	_TUGR_TheClampIsNotGatedOnTheProbeDecision)
