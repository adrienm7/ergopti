; static/ergopti_plus/windows/tests/meta/test_llm_loading_tooltip_no_safety_deadline.ahk

; ==============================================================================
; MODULE: LLM Loading Spinner Safety-Deadline Meta Test
; DESCRIPTION:
; Static source guard for findings F-05 and F-20 (audit 2026-07-20 second pass).
;
; LLM_TooltipShowLoading opted out of the 3 s _TOOLTIP_SAFETY_SEC auto-hide by
; calling TooltipShow(...) and then immediately SetTimer(_TooltipTimerFn, 0).
; That worked only while TooltipShow rendered SYNCHRONOUSLY. Commit 76fda09de
; ("perf(tooltip): debounce render work off hot path") made it store the payload
; and arm _TooltipDeferredShowFn instead, so the safety timer is now armed
; TOOLTIP_RENDER_DEBOUNCE_MS (75 ms) LATER, by _TooltipPresentStack. The cancel
; therefore runs BEFORE the arm and cancels nothing: the spinner is force-hidden
; ~3 s in, mid-inference, while an Ollama cold start is granted 8 s. The user
; sees the spinner vanish and nothing at all until the prediction lands.
;
; ROOT CAUSE (what this test pins): the opt-out was an ORDERING ASSUMPTION
; across a boundary that later became asynchronous, with no assertion and no
; log to notice it. The fix makes it an explicit ARGUMENT threaded through the
; debounce (_TooltipPendingArmSafety), so it cannot be broken by moving work
; behind a timer again.
;
; F-20 is the enabling defect: _TooltipPresentStack already took an ArmSafety
; parameter, but every path reachable from TooltipShow hardcoded `true`, so no
; caller could opt out at all — which is why the fragile cancel existed.
; ==============================================================================

#Requires AutoHotkey v2.0






; ====================================================================
; ====================================================================
; ======= 1/ The spinner opts out by ARGUMENT, never by cancel =======
; ====================================================================
; ====================================================================

_LLTS_SpinnerOptsOutExplicitly() {
	Body := _DriverFuncBody("LLM_TooltipShowLoading")
	Assert(Body != "", "LLM_TooltipShowLoading must exist in ui/tooltip/llm.ahk")

	Assert(InStr(Body, "SetTimer(_TooltipTimerFn, 0)") = 0,
		"LLM_TooltipShowLoading must NOT cancel _TooltipTimerFn inline — TooltipShow defers rendering by TOOLTIP_RENDER_DEBOUNCE_MS, so the safety timer is armed AFTER this call returns and the cancel is a silent no-op that lets the spinner vanish mid-inference")

	Assert(RegExMatch(Body, "TooltipShow\([^\n]*,\s*0\s*,\s*false\s*\)") > 0,
		"LLM_TooltipShowLoading must opt out of the safety deadline via TooltipShow's ArmSafety argument (DurationSec 0, ArmSafety false) rather than racing the timer")
}
Test("llm-tooltip: the loading spinner opts out of the safety deadline by argument (F-05)", _LLTS_SpinnerOptsOutExplicitly)






; =========================================================
; =========================================================
; ======= 2/ ArmSafety survives the render debounce =======
; =========================================================
; =========================================================

; The argument is worthless unless it is carried across the deferred boundary.
; This is the F-20 half: _TooltipPresentStack always had the parameter, but the
; deferred path hardcoded `true`, so the opt-out could never reach it.
_LLTS_ArmSafetyIsThreaded() {
	Show := _DriverFuncBody("TooltipShow")
	Assert(Show != "", "TooltipShow must exist in ui/tooltip/core.ahk")
	Assert(InStr(Show, "ArmSafety") > 0,
		"TooltipShow must accept an ArmSafety parameter so a caller can opt out of the auto-hide deadline")
	Assert(InStr(Show, "_TooltipPendingArmSafety") > 0,
		"TooltipShow must stash ArmSafety in _TooltipPendingArmSafety — the render is deferred, so the choice has to survive until _TooltipDeferredShowFn runs")

	Deferred := _DriverFuncBody("_TooltipDeferredShowFn")
	Assert(Deferred != "", "_TooltipDeferredShowFn must exist")
	Assert(InStr(Deferred, "_TooltipPendingArmSafety") > 0,
		"_TooltipDeferredShowFn must read _TooltipPendingArmSafety back")
	Assert(RegExMatch(Deferred, "_TooltipShowNow\([^\n]*ArmSafety") > 0,
		"_TooltipDeferredShowFn must forward ArmSafety to _TooltipShowNow")

	Now := _DriverFuncBody("_TooltipShowNow")
	Assert(Now != "", "_TooltipShowNow must exist")
	Assert(InStr(Now, "ArmSafety") > 0,
		"_TooltipShowNow must accept ArmSafety")
	Assert(RegExMatch(Now, "_TooltipPresentStack\([^\n]*ArmSafety\s*\)") > 0,
		"_TooltipShowNow must pass ArmSafety through to _TooltipPresentStack instead of hardcoding true — hardcoding it is what made the parameter unreachable and forced the fragile inline cancel (F-20)")
}
Test("tooltip: ArmSafety is threaded across the render debounce (F-20)", _LLTS_ArmSafetyIsThreaded)
