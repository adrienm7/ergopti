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
; ROOT CAUSE ENCODED: the wrap-safe origin/duration pair must be anchored on the
; event the other side of the contract anchors on, never on "now, once the work is done".
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
	Assert(InStr(Show, "OriginMs: A_TickCount") > 0
		and InStr(Show, "_TooltipPendingRequest := Request") > 0,
		"TooltipShow must stamp the tick at which the render was REQUESTED. Everything after that line — the render debounce, the Gui build, the UIA resolve — is latency the row deadline must not be pushed back by, because the engine's time-activation window keeps running throughout")

	Deferred := _DriverFuncBody("_TooltipDeferredShowFn")
	Assert(Deferred != "", "_TooltipDeferredShowFn() must exist in the driver source")
	Assert(InStr(Deferred, "Request.OriginMs") > 0,
		"_TooltipDeferredShowFn must read the stamped origin from the exact tuple it atomically detached")
	Assert(RegExMatch(Deferred,
		"s)_TooltipShowNow\(.*?Request\.OriginMs") > 0,
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
	Plan := _DriverFuncBody("_TooltipCreateLifecyclePlan")
	Bounds := _DriverFuncBody("_TooltipLifecycleDeadlineBounds")
	Present := _DriverFuncBody("_TooltipPresentStack")
	Assert(Body != "", "_TooltipShowNow() must exist in the driver source")
	Assert(Plan != "" and Bounds != "" and Present != "",
		"the lifecycle plan, deadline resolver and common presenter must exist")
	Assert(InStr(Body, "OriginMs") > 0,
		"_TooltipShowNow must accept and use the request origin")
	Assert(InStr(Body, "if !IsSet(OriginMs)") > 0
		and InStr(Body, "OriginMs > 0") == 0,
		"tick zero is a valid request origin at rollover and must not be mistaken for an omitted origin")

	; Both the per-row and single-timer branches produce immutable wrap-safe
	; origin/duration pairs before GUI/UIA work.
	Assert(InStr(Body, "_TooltipCreateLifecyclePlan(") > 0
		and InStr(Plan, "ExpOriginTick := OriginMs") > 0
		and InStr(Plan, "ExpireOriginTick: OriginMs") > 0,
		"the per-row dequeue interval must preserve the request origin the engine's time gate also reads")
	Assert(InStr(Plan, "ExpOriginTick := Now") == 0,
		"the per-row dequeue deadline must not be recomputed from present time — present time is the request plus both debounces plus the render, so the row outlives the expansion window it is previewing")

	; No remainder is allowed to cross an interruptible call. The common presenter
	; resolves it under the same Critical fence that publishes the timer + pixels.
	Assert(InStr(Bounds, "TickRemaining(") > 0,
		"the timer period must be the current wrap-safe remainder of the original interval")
	CriticalOn := InStr(Present, 'Critical("On")')
	Resolve := InStr(Present, "_TooltipLifecycleDeadlineBounds(", true,
		CriticalOn)
	Timer := InStr(Present, "SetTimer(_TooltipTimerFn", true, Resolve)
	Reveal := InStr(Present, "_TooltipRevealPreparedSurfaces(", true, Timer)
	Assert(CriticalOn > 0 and Resolve > CriticalOn and Timer > Resolve
		and Reveal > Timer,
		"the deadline remainder must be recomputed and armed atomically before its pixels become visible")
}


Test("meta tooltip-expiry-anchored-at-request: the request tick is stamped and carried",
	_TEAR_TheRequestIsStamped)
Test("meta tooltip-expiry-anchored-at-request: both expiry branches anchor on it",
	_TEAR_BothBranchesAnchorOnTheOrigin)
