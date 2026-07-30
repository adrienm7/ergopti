; tests/meta/test_tooltip_expiry_anchored_at_request.ahk

; ==============================================================================
; MODULE: Regression — the tooltip row deadline is anchored at the request
;         (tooltip-expiry-anchored-at-request)
; DESCRIPTION:
; Two clocks measured one deadline from two different events.
;
;   ENGINE  — IsTimeActivationExpired compares against LastSentCharacterKeyTime,
;             i.e. the tick at which the previous character was emitted.
;   TOOLTIP — _TooltipShowNow read A_TickCount as the row's start, which is the
;             keystroke PLUS the preview debounce, PLUS the tooltip render
;             debounce, PLUS the Gui build and the UIA position resolve.
;
; _TOOLTIP_TIMEOUT_DECREMENT_SEC exists to make the preview vanish a beat BEFORE
; the expansion window closes. It is a fixed 0.2 s, and it was being asked to
; absorb a latency that is variable and larger: the render alone has been
; measured at up to 113 ms. The tooltip therefore outlived the engine's window —
; the user saw the suggestion, pressed the magic key inside the dead interval,
; and nothing at all was emitted. No exception, no log line, nothing to see.
;
; ROOT CAUSE ENCODED: an absolute deadline must be anchored on the event the
; other side of the contract anchors on, never on "now, once the work is done".
; Raising the decrement is NOT a fix — it is a shared cross-driver constant, and
; a fixed number cannot cover a variable render cost.
;
; SCOPE: source introspection. _TooltipShowNow builds real Gui surfaces and
; resolves screen position through UIA, so it cannot be driven headlessly.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ The origin is captured and carried across ==============
; ==================================================================
; ==================================================================

; The stamp has to be taken by the entry point, before the debounce — taking it
; inside the deferred callback would re-introduce the very latency it removes.
_TEAR_TheRequestIsStamped() {
	Show := _DriverFuncBody("TooltipShow")
	Assert(Show != "", "TooltipShow() must exist in the driver source")
	Assert(InStr(Show, "_TooltipPendingOriginMs := A_TickCount") > 0,
		"TooltipShow must stamp the tick at which the render was REQUESTED. Everything after that line — the render debounce, the Gui build, the UIA resolve — is latency the row deadline must not be pushed back by, because the engine's time-activation window keeps running throughout")

	Deferred := _DriverFuncBody("_TooltipDeferredShowFn")
	Assert(Deferred != "", "_TooltipDeferredShowFn() must exist in the driver source")
	Assert(InStr(Deferred, "_TooltipPendingOriginMs") > 0,
		"_TooltipDeferredShowFn must read the stamped origin back — the render is deferred, so the value has to survive the debounce boundary")
	Assert(RegExMatch(Deferred, "_TooltipShowNow\([^\r\n]*OriginMs") > 0,
		"_TooltipDeferredShowFn must forward the origin to _TooltipShowNow, or the stamp is dead state")
}





; ==================================================================
; ==================================================================
; ======= 2/ Both expiry branches use it ============================
; ==================================================================
; ==================================================================

; _TooltipShowNow has TWO deadline branches — the per-row dequeue path and the
; single-timer path — and fixing one of them would leave the other anchored at
; present time. Both are asserted, in both directions.
_TEAR_BothBranchesAnchorOnTheOrigin() {
	Body := _DriverFuncBody("_TooltipShowNow")
	Assert(Body != "", "_TooltipShowNow() must exist in the driver source")
	Assert(InStr(Body, "OriginMs") > 0,
		"_TooltipShowNow must accept and use the request origin")

	; Dequeue path: the per-row absolute deadline.
	Assert(InStr(Body, "ExpMs := OriginMs + Round(") > 0,
		"the per-row dequeue deadline must be computed from the request origin the engine's time gate also reads")
	Assert(InStr(Body, "ExpMs := Now + Round(") == 0,
		"the per-row dequeue deadline must not be recomputed from present time — present time is the request plus both debounces plus the render, so the row outlives the expansion window it is previewing")

	; Single-timer path: the period must be what is LEFT of the deadline, not the
	; whole duration measured again from the moment the render happened to finish.
	Assert(RegExMatch(Body, "SetTimer\(_TooltipTimerFn, -Round\(Effective \* 1000\)\)") == 0,
		"the single-timer path must not arm the full duration from present time — that restarts the clock after the debounce and the render, which is exactly the drift this fix removes")
	Assert(RegExMatch(Body, "SetTimer\(_TooltipTimerFn, -Max\([^\r\n]*ExpMs - A_TickCount\)") > 0,
		"the single-timer path must arm the REMAINDER of an absolute deadline, with a positive floor — a non-positive SetTimer period is read as -disable-, which would leave the surface with no auto-hide at all")
}


Test("meta tooltip-expiry-anchored-at-request: the request tick is stamped and carried",
	_TEAR_TheRequestIsStamped)
Test("meta tooltip-expiry-anchored-at-request: both expiry branches anchor on it",
	_TEAR_BothBranchesAnchorOnTheOrigin)
