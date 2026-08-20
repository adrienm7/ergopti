; tests/meta/test_tooltip_debounce_is_load_bearing.ahk

; ==============================================================================
; MODULE: The Tooltip Render Debounce Is Load-Bearing
; DESCRIPTION:
; TOOLTIP_RENDER_DEBOUNCE_MS (75 ms) looks like pure, removable latency on the
; hotstring preview path, and the argument for removing it is correct as far as
; it goes: the only preview caller of TooltipShow sits behind
; _PREFIX_RENDER_DEBOUNCE_MS (150 ms), _PrefixRenderFlush disarms itself on
; entry, so two preview renders are always at least 150 ms apart — and 150 > 75,
; which means the one-shot deferral timer can never merge two of them. On that
; path the debounce coalesces exactly nothing.
;
; What that argument misses is that the 75 ms is doing a SECOND job. The tooltip
; only reaches stage 2 of its position cascade (the UIA focused-element probe,
; the only stage that produces a caret anchor in Electron, Chromium, UWP and
; WPF) when A_TimeIdlePhysical has reached TOOLTIP_UIA_IDLE_REQUIRED_MS. A
; preview render happens _PREFIX_RENDER_DEBOUNCE_MS + TOOLTIP_RENDER_DEBOUNCE_MS
; after the last character, so the two debounces together are what satisfies
; that gate. Shorten the second one — including by making it leading-edge, which
; leaves the constant itself untouched — and the gate rejects every preview
; again. That is not a hypothetical regression: it shipped, previews anchored at
; the bottom of the window frame instead of under the caret, and it is why
; test_tooltip_uia_gate_reachable.ahk exists.
;
; ROOT CAUSE ENCODED: the arithmetic guard on the three constants cannot see a
; code change that shortens the EFFECTIVE delay while leaving the constants
; alone. This file closes that hole, and records the margin the relationship
; needs so the next person to reach for the obvious 75 ms saving is told why it
; is not free before they spend a day on it.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
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

	Margin := PrefixMs + RenderMs - IdleMs
	Assert(Margin >= _TDB_MIN_IDLE_MARGIN_MS,
		"a preview render lands " . PrefixMs . " + " . RenderMs . " = " . (PrefixMs + RenderMs) . " ms after the last character and must clear the " . IdleMs . " ms UIA idle gate by at least " . _TDB_MIN_IDLE_MARGIN_MS . " ms (one Windows timer tick); the margin is " . Margin . " ms. Below that the UIA stage of the position cascade fires only sometimes, and the preview anchors at the bottom of the window instead of under the caret in every app without a native caret")

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
		"TooltipShow must arm the deferred render with TOOLTIP_RENDER_DEBOUNCE_MS itself, not with a computed delay. A leading-edge or otherwise shortened delay leaves all three constants untouched, so the arithmetic guard above still passes while the preview render moves back below the UIA idle gate and stage 2 of the position cascade becomes unreachable again")

	; The specific shape that was proposed and rejected: a last-render timestamp
	; used to skip the wait when the previous render is already old. On the
	; preview path the previous render is ALWAYS older than 75 ms, so this is not
	; a coalescing optimisation at all — it deletes the delay outright.
	Assert(InStr(Body, "_LastRenderTick") == 0,
		"TooltipShow must not shorten its deferral based on when the last render happened. Two preview renders are always at least _PREFIX_RENDER_DEBOUNCE_MS apart, so such a check always takes the short branch: the effect is to remove the debounce entirely from the one path it is load-bearing on")
}


Test("meta tooltip-debounce: the render debounce keeps the UIA idle gate reachable with margin",
	_TDB_TheDebounceKeepsTheUiaGateReachable)
Test("meta tooltip-debounce: the deferred render is armed with the named constant, not a computed delay",
	_TDB_TheArmedDelayIsNotComputed)
