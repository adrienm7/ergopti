; tests/meta/test_tooltip_uia_gate_reachable.ahk

; ==============================================================================
; MODULE: Regression — the tooltip UIA stage is reachable on the preview path
;         (tooltip-uia-gate-reachable)
; DESCRIPTION:
; Three constants owned by two modules encode one timing contract, and nothing
; checked their sum:
;
;   _PREFIX_RENDER_DEBOUNCE_MS   150   (infra/hotstrings/hotstring_inputhook.ahk)
; + TOOLTIP_RENDER_DEBOUNCE_MS    75   (ui/tooltip/core.ahk)
; = 225 ms of guaranteed physical idle before a preview can ever be rendered
;   TOOLTIP_UIA_IDLE_REQUIRED_MS 250   (ui/tooltip/core.ahk)
;
; The idle gate exists to keep the cross-process UIA round-trip off an in-flight
; typing burst. But the work it guards is only ever reached AFTER that fixed
; debounce chain, so the gate rejected the very render the debounce was waiting
; for: stage 2 of the position cascade never ran on the only path it exists for.
; Every preview in an app without a native caret (Electron, Chromium, UWP, WPF)
; anchored at the bottom of the window frame instead of under the caret, and the
; stage-3 fallback deliberately does not cache, so there was no state to inspect.
;
; Second-order: the lazy UIA timeout clamp sat INSIDE that unreachable branch, so
; the UIA singleton kept Windows' 2000 ms transaction / 20000 ms connection
; defaults for the whole session — including for the sibling probes that share it
; and also run on the keystroke-dispatch thread.
;
; ROOT CAUSE ENCODED: an idle gate placed behind a longer fixed debounce must be
; satisfiable by that debounce, and a clamp on a process-wide singleton must not
; be gated on one caller's decision to use it.
;
; SCOPE: source introspection — the constants are read out of the driver source
; so a future debounce change re-checks the relationship instead of silently
; making the stage unreachable again. Mirrors the sibling inequality already
; pinned by test_audit_2026_07_20_batch4.ahk for TOOLTIP_POSITION_CACHE_MS.
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

	Assert(PrefixMs + RenderMs > IdleMs,
		"a preview render lands _PREFIX_RENDER_DEBOUNCE_MS (" . PrefixMs . ") + TOOLTIP_RENDER_DEBOUNCE_MS (" . RenderMs . ") = " . (PrefixMs + RenderMs) . " ms after the last character. TOOLTIP_UIA_IDLE_REQUIRED_MS (" . IdleMs . ") must stay below that sum, or the UIA stage of the position cascade can never run on the path it exists for and every preview in a caret-less app anchors at the bottom of the window instead of under the caret")
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


Test("meta tooltip-uia-gate-reachable: the idle gate is satisfiable by the preview debounce",
	_TUGR_TheIdleGateIsReachable)
Test("meta tooltip-uia-gate-reachable: the singleton timeout clamp is not gated on the probe decision",
	_TUGR_TheClampIsNotGatedOnTheProbeDecision)
