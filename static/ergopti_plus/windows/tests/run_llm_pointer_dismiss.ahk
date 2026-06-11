; static/ergopti_plus/windows/tests/run_llm_pointer_dismiss.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

; ==============================================================================
; MODULE: LLM Pointer-Dismiss Tests
; DESCRIPTION:
; Behavioural guard for the "prediction disappears the instant it appears" bug.
; The pointer-dismiss watcher used to act whenever HasActivePredictionWork() was
; true — which INCLUDES the loading / generation phase. So mouse drift while a
; slow model was still generating dismissed (or cancelled) the suggestion the
; moment it rendered. The fix gates dismissal on _LLM_Bridge_PredictionShown()
; (a real prediction on screen, NOT the violet loading tooltip), mirroring macOS
; which arms its dismiss watchers only inside show_predictions.
; ==============================================================================

#Include test_framework.ahk

; --- Mutable tooltip state the stubs report ---
global _MMP_Visible  := false
global _MMP_Loading  := false
global _MMP_HideHits := 0   ; counts LLM_Tooltip_Hide() calls (the dismiss signal)

; --- Globals the bridge reads ---
global _LLM_Bridge_Active := true
global _LLM_Engine := Map("reset_on_nav", false)

; --- Dependency stubs (resolved at call time once the bridge is included) ---
LLM_Tooltip_IsVisible()        => _MMP_Visible
LLM_Tooltip_IsLoading()        => _MMP_Loading
LLM_Engine_IsBusy()            => false
LLM_Engine_StopGeneration()    => ""
LLM_Tooltip_MarkChainComplete() => ""
LLM_Tooltip_Hide(accepted := false) {
	global _MMP_HideHits
	_MMP_HideHits += 1
}

#Include ../modules/llm/llm_bridge.ahk

; The include re-declares ``global _LLM_Bridge_Active := false`` at load, which
; overwrites the pre-include value — restore the active state the tests need.
_LLM_Bridge_Active := true

; Isolated suite: bail if a stale lock ever hangs RunTests.
_MmpWatchdog(*) {
	try FileAppend("`n[WATCHDOG] run_llm_pointer_dismiss timed out`n", "*")
	ExitApp(2)
}
SetTimer(_MmpWatchdog, -60000)




; =========================================================
; ======= 1/ _LLM_Bridge_PredictionShown predicate ========
; =========================================================

_MMP_ShownDuringLoading() {
	global _MMP_Visible, _MMP_Loading
	_MMP_Visible := true
	_MMP_Loading := true
	AssertFalse(_LLM_Bridge_PredictionShown(), "loading tooltip must NOT count as a shown prediction")
}
Test("pointer-dismiss: loading tooltip is not a shown prediction", _MMP_ShownDuringLoading)

_MMP_ShownDuringPrediction() {
	global _MMP_Visible, _MMP_Loading
	_MMP_Visible := true
	_MMP_Loading := false
	AssertTrue(_LLM_Bridge_PredictionShown(), "a visible, non-loading tooltip is a shown prediction")
}
Test("pointer-dismiss: visible non-loading tooltip is a shown prediction", _MMP_ShownDuringPrediction)

_MMP_ShownWhenHidden() {
	global _MMP_Visible, _MMP_Loading
	_MMP_Visible := false
	_MMP_Loading := false
	AssertFalse(_LLM_Bridge_PredictionShown(), "no tooltip means no shown prediction")
}
Test("pointer-dismiss: hidden tooltip is not a shown prediction", _MMP_ShownWhenHidden)




; =========================================================
; ======= 2/ OnPointerActivity gates on the phase =========
; =========================================================

_MMP_NoDismissDuringLoading() {
	global _MMP_Visible, _MMP_Loading, _MMP_HideHits
	; The user is waiting for a slow model: loading tooltip up, no prediction yet.
	_MMP_Visible := true
	_MMP_Loading := true
	_MMP_HideHits := 0
	LLM_Bridge_OnPointerActivity()
	AssertEqual(0, _MMP_HideHits, "pointer activity during generation must NOT dismiss (regression: prediction vanished on appear)")
}
Test("pointer-dismiss: pointer activity is ignored during loading/generation", _MMP_NoDismissDuringLoading)

_MMP_DismissWhenPredictionShown() {
	global _MMP_Visible, _MMP_Loading, _MMP_HideHits
	; A real prediction is on screen — now pointer activity dismisses it.
	_MMP_Visible := true
	_MMP_Loading := false
	_MMP_HideHits := 0
	LLM_Bridge_OnPointerActivity()
	AssertEqual(1, _MMP_HideHits, "pointer activity over a shown prediction must dismiss it")
}
Test("pointer-dismiss: pointer activity dismisses a shown prediction", _MMP_DismissWhenPredictionShown)




; =========================================================
; ======= 3/ Move-tick source contract ====================
; =========================================================

_MMP_MoveTickGatesOnShown() {
	body := FileRead(A_ScriptDir . "\..\modules\llm\llm_bridge.ahk", "UTF-8")
	; The move watcher must gate on the shown-prediction predicate, not on the
	; broader HasActivePredictionWork (which includes loading), and must drop the
	; baseline while no prediction is shown so the next one starts from a fresh origin.
	AssertContains(body, "if !_LLM_Bridge_PredictionShown() {",
		"move-tick must gate dismissal on a shown prediction, not on loading/generation")
	AssertContains(body, "_LLM_PointerWatch_LastX := unset",
		"move-tick must reset the baseline while no prediction is shown")
	; And it must dismiss only past the deliberate-move threshold, never on raw jitter.
	AssertContains(body, "_LLM_PointerMovedEnough(x, y, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY)",
		"move-tick must dismiss only when the cursor moved past the jitter threshold")
}
Test("pointer-dismiss: move-tick gates on shown prediction + resets baseline", _MMP_MoveTickGatesOnShown)




; =========================================================
; ======= 4/ Movement threshold (no dismiss on jitter) ====
; =========================================================

_MMP_JitterDoesNotDismiss() {
	; A still mouse drifts a pixel or two from optical-sensor noise — must NOT count.
	AssertFalse(_LLM_PointerMovedEnough(503, 401, 500, 400),
		"a 3 px drift must not count as a deliberate move (regression: prediction vanished while the user sat still)")
	AssertFalse(_LLM_PointerMovedEnough(500, 400, 500, 400),
		"no movement must not dismiss")
}
Test("pointer-threshold: small jitter does not dismiss", _MMP_JitterDoesNotDismiss)

_MMP_DeliberateMoveDismisses() {
	; Reaching to click elsewhere crosses far more than the threshold on either axis.
	AssertTrue(_LLM_PointerMovedEnough(560, 400, 500, 400),
		"a 60 px horizontal move is deliberate and must dismiss")
	AssertTrue(_LLM_PointerMovedEnough(500, 480, 500, 400),
		"an 80 px vertical move is deliberate and must dismiss")
}
Test("pointer-threshold: a deliberate move dismisses", _MMP_DeliberateMoveDismisses)

_MMP_ThresholdBoundary() {
	global _LLM_POINTER_MOVE_THRESHOLD_PX
	; Exactly at the threshold does not dismiss (strict greater-than); one past does.
	t := _LLM_POINTER_MOVE_THRESHOLD_PX
	AssertFalse(_LLM_PointerMovedEnough(500 + t, 400, 500, 400),
		"movement exactly at the threshold must not dismiss")
	AssertTrue(_LLM_PointerMovedEnough(500 + t + 1, 400, 500, 400),
		"movement one pixel past the threshold must dismiss")
}
Test("pointer-threshold: boundary is strict greater-than", _MMP_ThresholdBoundary)

RunTests()
