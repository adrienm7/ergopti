; static/ergopti_plus/windows/tests/run_llm_tooltip_grace.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

; ==============================================================================
; MODULE: LLM Tooltip Minimum-Display (Grace Window) Tests
; DESCRIPTION:
; Behavioural guard for the "prediction n'a meme pas le temps d'apparaitre" bug.
; On Windows the LLM prediction shares ONE Gui surface with the hotstring
; autocomplete tooltip, so the prediction is exposed to that surface's far more
; aggressive per-keystroke lifecycle (ResetBuf / LookupNoMatch / new lookup) AND
; to in-flight keystrokes that were already travelling when the slow model finally
; answered. The logs showed a prediction shown at T and killed at T+27ms by a
; ResetBuf force-hide plus the bridge's own keystroke dismiss.
;
; The fix is a minimum-display window: for _LLM_TOOLTIP_MIN_DISPLAY_MS after a
; real prediction renders, incidental dismissals (keystroke, pointer drift, the
; shared-surface clobber) are ignored. Deliberate accept/dismiss still works.
;
; These tests lock the bridge-side behaviour (keystroke + pointer dismiss respect
; the window) and assert the central TooltipHide guard + the show-time stamp stay
; in place so the regression cannot silently return.
; ==============================================================================

#Include test_framework.ahk

; --- Mutable tooltip state the stubs report ---
global _MMG_Visible  := false
global _MMG_Loading  := false
global _MMG_Grace    := false   ; controls LLM_Tooltip_InGracePeriod()
global _MMG_HideHits := 0        ; counts LLM_Tooltip_Hide() calls (the dismiss signal)

; --- Globals the bridge reads ---
global _LLM_Bridge_Active := true
global _LLM_Engine := Map("reset_on_nav", false)

; --- Dependency stubs (resolved at call time once the bridge is included) ---
TooltipIsVisible()              => false   ; hotstring overlay not on screen
LLM_Tooltip_IsVisible()         => _MMG_Visible
LLM_Tooltip_IsLoading()         => _MMG_Loading
LLM_Tooltip_InGracePeriod()     => _MMG_Grace
LLM_Engine_OnKeystroke(buf)     => ""
LLM_Engine_IsBusy()             => false
LLM_Engine_StopGeneration()     => ""
LLM_Tooltip_MarkChainComplete() => ""
LLM_Tooltip_Hide(accepted := false) {
	global _MMG_HideHits
	_MMG_HideHits += 1
}

#Include ../modules/llm/llm_bridge.ahk

; The include re-declares ``global _LLM_Bridge_Active := false`` at load, which
; overwrites the pre-include value - restore the active state the tests need.
_LLM_Bridge_Active := true

; Isolated suite: bail if a stale lock ever hangs RunTests.
_MmgWatchdog(*) {
	try FileAppend("`n[WATCHDOG] run_llm_tooltip_grace timed out`n", "*")
	ExitApp(2)
}
SetTimer(_MmgWatchdog, -60000)




; =========================================================
; ======= 1/ Keystroke dismiss respects the window ========
; =========================================================

_MMG_KeystrokeKeptDuringGrace() {
	global _MMG_Visible, _MMG_Loading, _MMG_Grace, _MMG_HideHits, _LLM_Bridge_Buffer
	; Prediction freshly on screen, still inside its minimum-display window.
	_MMG_Visible := true
	_MMG_Loading := false
	_MMG_Grace   := true
	_MMG_HideHits := 0
	_LLM_Bridge_Buffer := ""
	LLM_Bridge_OnChar("x")
	AssertEqual(0, _MMG_HideHits, "a keystroke inside the min-display window must NOT dismiss the prediction (regression: prediction vanished on appear)")
}
Test("grace: keystroke during the min-display window keeps the prediction", _MMG_KeystrokeKeptDuringGrace)

_MMG_KeystrokeDismissesAfterGrace() {
	global _MMG_Visible, _MMG_Loading, _MMG_Grace, _MMG_HideHits, _LLM_Bridge_Buffer
	; Same prediction, but the window has elapsed - typing dismisses as usual.
	_MMG_Visible := true
	_MMG_Loading := false
	_MMG_Grace   := false
	_MMG_HideHits := 0
	_LLM_Bridge_Buffer := ""
	LLM_Bridge_OnChar("x")
	AssertEqual(1, _MMG_HideHits, "a keystroke after the window must dismiss the prediction (normal behaviour preserved)")
}
Test("grace: keystroke after the min-display window dismisses the prediction", _MMG_KeystrokeDismissesAfterGrace)




; =========================================================
; ======= 2/ Pointer dismiss respects the window ==========
; =========================================================

_MMG_PointerKeptDuringGrace() {
	global _MMG_Visible, _MMG_Loading, _MMG_Grace, _MMG_HideHits
	_MMG_Visible := true
	_MMG_Loading := false
	_MMG_Grace   := true
	_MMG_HideHits := 0
	LLM_Bridge_OnPointerActivity()
	AssertEqual(0, _MMG_HideHits, "pointer drift inside the min-display window must NOT dismiss the prediction")
}
Test("grace: pointer activity during the min-display window keeps the prediction", _MMG_PointerKeptDuringGrace)

_MMG_PointerDismissesAfterGrace() {
	global _MMG_Visible, _MMG_Loading, _MMG_Grace, _MMG_HideHits
	_MMG_Visible := true
	_MMG_Loading := false
	_MMG_Grace   := false
	_MMG_HideHits := 0
	LLM_Bridge_OnPointerActivity()
	AssertEqual(1, _MMG_HideHits, "pointer activity after the window must dismiss the prediction")
}
Test("grace: pointer activity after the min-display window dismisses the prediction", _MMG_PointerDismissesAfterGrace)




; =========================================================
; ======= 3/ Source contract (cannot silently regress) ====

_MMG_TooltipCentralGuardExists() {
	body := FileRead(A_ScriptDir . "\..\lib\tooltip.ahk", "UTF-8")
	; The shared-surface hide must be gated on the grace predicate, with the two
	; authoritative bypass tags (deliberate LLM hide + driver suspend).
	AssertContains(body, 'DbgTag != "LLM" and DbgTag != "Suspend" and LLM_TooltipInGracePeriod()',
		"TooltipHide must ignore incidental hides while a prediction is in its min-display window")
	; The window opens the instant a real prediction renders.
	AssertContains(body, "_LLM_Tooltip_ShownAt := A_TickCount",
		"LLM_TooltipShow must stamp the show time so the grace window can start")
}
Test("grace: TooltipHide central guard + show-time stamp are present", _MMG_TooltipCentralGuardExists)

_MMG_BridgeGatesDismissOnGrace() {
	body := FileRead(A_ScriptDir . "\..\modules\llm\llm_bridge.ahk", "UTF-8")
	; Both the keystroke and the pointer dismiss paths must consult the window.
	AssertContains(body, "LLM_Tooltip_InGracePeriod()",
		"the bridge dismiss paths must gate on the min-display window")
}
Test("grace: bridge dismiss paths gate on the min-display window", _MMG_BridgeGatesDismissOnGrace)

RunTests()
