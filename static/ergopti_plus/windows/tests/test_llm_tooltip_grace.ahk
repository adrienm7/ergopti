; tests/test_llm_tooltip_grace.ahk

; ==============================================================================
; MODULE: LLM Tooltip Minimum-Display (Grace Window) Regression Tests
; DESCRIPTION:
; CI-integrated guard for the "prediction n'a meme pas le temps d'apparaitre"
; bug. On Windows the LLM prediction shares ONE Gui surface with the hotstring
; autocomplete tooltip, so the prediction is exposed to that surface's far more
; aggressive per-keystroke lifecycle AND to in-flight keystrokes that were
; already travelling when the slow model finally answered. The logs showed a
; prediction shown at T and force-hidden at T+27ms by a ResetBuf clobber plus the
; bridge's own keystroke dismiss.
;
; ROOT CAUSE:
; LLM_TooltipShow rendered the prediction but nothing protected it for a minimum
; perceivable time; any incidental hide (ResetBuf / LookupNoMatch / NewShow from
; the shared surface, an in-flight keystroke, stray pointer drift) killed it
; immediately. macOS does not hit this because its prediction lives on its own
; surface, untouched by the hotstring lifecycle.
;
; THE FIX (encoded here):
; A minimum-display window. LLM_TooltipShow stamps _LLM_Tooltip_ShownAt; for
; _LLM_TOOLTIP_MIN_DISPLAY_MS the prediction is immune to incidental hides.
; TooltipHide ignores non-deliberate hides during the window (deliberate "LLM"
; accept/dismiss and "Suspend" bypass it); the bridge's keystroke + pointer
; dismiss paths gate on LLM_Tooltip_InGracePeriod().
;
; WHAT THESE TESTS ENCODE:
; 1. The grace predicate arithmetic: visible AND not loading AND stamped AND
;    within the window. Each falsifying branch returns false.
; 2. Source contract (FileRead, no module load - run_all does not load the LLM
;    tooltip/bridge): the central TooltipHide guard, the show-time stamp, the
;    hide-time reset, and the bridge gating must all stay in place.
;
; NOTE (AHK v2.0): tests register via named functions, not block-body fat arrows
; (a v2.1-only construct that aborts the suite at load on the pinned v2.0 CI).
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================================
; ================================================================
; ======= 1/ Grace Predicate Logic (arithmetic + branches) =======
; ================================================================
; ================================================================

; Mirror of LLM_TooltipInGracePeriod() in lib/tooltip.ahk. The production
; predicate reads four globals; this pure form takes them as parameters so the
; branch logic is testable without loading the Gui engine.
_SimulateInGracePeriod(visible, loading, shownAt, nowTick, windowMs) {
	if (!visible)
		return false
	if (loading)
		return false
	if (shownAt == 0)
		return false
	return (nowTick - shownAt) < windowMs
}




; ===== 1.1) A fresh prediction inside the window is protected =====

_TestGrace_FreshPredictionIsProtected() {
	; Shown at tick 1000, now 1300, window 600 -> 300 ms elapsed -> protected.
	Assert(_SimulateInGracePeriod(true, false, 1000, 1300, 600),
		"a visible, non-loading, freshly-stamped prediction must be inside the window")
}
Test("grace predicate: fresh prediction within the window is protected",
	_TestGrace_FreshPredictionIsProtected)




; ===== 1.2) Once the window elapses, protection ends =====

_TestGrace_WindowElapses() {
	; Shown at 1000, now 1700, window 600 -> 700 ms elapsed -> no longer protected.
	Assert(!_SimulateInGracePeriod(true, false, 1000, 1700, 600),
		"after the window elapses the prediction must dismiss normally")
}
Test("grace predicate: protection ends once the window elapses",
	_TestGrace_WindowElapses)




; ===== 1.3) Loading spinner is never protected =====

_TestGrace_LoadingNotProtected() {
	Assert(!_SimulateInGracePeriod(true, true, 1000, 1100, 600),
		"the violet loading spinner is not a real prediction and must not be protected")
}
Test("grace predicate: loading spinner is never inside the window",
	_TestGrace_LoadingNotProtected)




; ===== 1.4) No stamp (0) means no window =====

_TestGrace_NoStampNoWindow() {
	Assert(!_SimulateInGracePeriod(true, false, 0, 1100, 600),
		"an unstamped tooltip (ShownAt = 0) must never be treated as inside the window")
}
Test("grace predicate: a zero show-time stamp opens no window",
	_TestGrace_NoStampNoWindow)




; ===== 1.5) Nothing visible means no window =====

_TestGrace_HiddenNoWindow() {
	Assert(!_SimulateInGracePeriod(false, false, 1000, 1100, 600),
		"no tooltip on screen means no window")
}
Test("grace predicate: a hidden tooltip opens no window",
	_TestGrace_HiddenNoWindow)





; ============================================================
; ============================================================
; ======= 2/ Source Contract (cannot silently regress) =======
; ============================================================
; ============================================================

_TestGrace_TooltipCentralGuard() {
	Body := FileRead(A_ScriptDir . "\..\lib\tooltip.ahk", "UTF-8")
	; Incidental hides are ignored while a prediction is in its window; the two
	; authoritative bypass tags (deliberate LLM hide + driver suspend) pass.
	Assert(InStr(Body, 'DbgTag != "LLM" and DbgTag != "Suspend" and LLM_TooltipInGracePeriod()') > 0,
		"TooltipHide must ignore incidental hides while a prediction is in its min-display window")
	; The window opens the instant a real prediction renders.
	Assert(InStr(Body, "_LLM_Tooltip_ShownAt := A_TickCount") > 0,
		"LLM_TooltipShow must stamp the show time so the window can start")
	; The predicate the guard depends on must exist.
	Assert(InStr(Body, "LLM_TooltipInGracePeriod() {") > 0,
		"the LLM_TooltipInGracePeriod predicate must be defined")
	; TooltipShow must ALSO bail during the window. Blocking the NewShow hide is
	; not enough: TooltipShow rebuilds the shared Gui regardless, clobbering the
	; prediction with a hotstring preview lookup. This standalone guard ("if " with
	; no DbgTag prefix, unlike the TooltipHide one) lives only in TooltipShow.
	Assert(InStr(Body, "if LLM_TooltipInGracePeriod()") > 0,
		"TooltipShow must refuse to rebuild the shared surface while a prediction is in its window")
}
Test("grace contract: TooltipHide + TooltipShow guards + show-time stamp + predicate present",
	_TestGrace_TooltipCentralGuard)


_TestGrace_HideResetsStamp() {
	Body := FileRead(A_ScriptDir . "\..\lib\tooltip.ahk", "UTF-8")
	; Hiding the prediction must clear the stamp so a later show starts a fresh
	; window and a stale stamp can never keep a vanished prediction "protected".
	Assert(InStr(Body, "_LLM_Tooltip_ShownAt := 0") > 0,
		"LLM_TooltipHide / LLM_TooltipShowLoading must reset the show-time stamp")
}
Test("grace contract: the show-time stamp is reset on hide / loading",
	_TestGrace_HideResetsStamp)


_TestGrace_BridgeGatesDismiss() {
	Body := FileRead(A_ScriptDir . "\..\modules\llm\llm_bridge.ahk", "UTF-8")
	; Both the keystroke and the pointer dismiss paths must consult the window.
	Assert(InStr(Body, "LLM_Tooltip_InGracePeriod()") > 0,
		"the bridge dismiss paths must gate on the min-display window")
	; Pointer movement must dismiss only past a deliberate-move threshold, so a
	; still mouse's optical jitter cannot blank the prediction "on its own" while
	; the user sits idle (the "arrêté, rien touché" report).
	Assert(InStr(Body, "_LLM_POINTER_MOVE_THRESHOLD_PX") > 0,
		"a pointer movement threshold must exist so jitter does not dismiss")
	Assert(InStr(Body, "_LLM_PointerMovedEnough(x, y, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY)") > 0,
		"the move-tick must dismiss only when the cursor crossed the threshold")
}
Test("grace contract: bridge dismiss paths gate on the min-display window",
	_TestGrace_BridgeGatesDismiss)
