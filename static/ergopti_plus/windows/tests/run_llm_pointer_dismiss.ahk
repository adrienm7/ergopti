; static/ergopti_plus/windows/tests/run_llm_pointer_dismiss.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

; ==============================================================================
; MODULE: LLM Pointer-Dismiss Tests
; DESCRIPTION:
; Behavioural guard for the "génération en cours" spinner that lingered through
; user input. Per macOS parity (mouse_tap -> reset_predictions on any click in
; any phase; a keystroke cancels generation via stop_timer) ANY input — keystroke,
; click, or pointer move — must cancel an in-progress generation and hide the
; tooltip. So pointer dismissal gates on LLM_Bridge_HasActivePredictionWork()
; (loading spinner, in-flight generation, OR a shown prediction), NOT only a shown
; prediction. The only protection retained is the minimum-display grace window: a
; REAL prediction in its first 600 ms is shielded so an incidental click / drift
; the instant it renders cannot kill it before the user perceives it (the loading
; spinner has no grace, so it is cancellable immediately). The move watcher still
; dismisses only past the deliberate-move threshold, never on sensor jitter.
; ==============================================================================

#Include test_framework.ahk

; --- Mutable tooltip state the stubs report ---
global _MMP_Visible  := false
global _MMP_Loading  := false
global _MMP_InGrace  := false   ; LLM_Tooltip_InGracePeriod() result (shielded shown prediction)
global _MMP_HideHits := 0   ; counts LLM_Tooltip_Hide() calls (the dismiss signal)

; --- Globals the bridge reads ---
global _LLM_Bridge_Active := true
global _LLM_Engine := Map("reset_on_nav", false)

; --- Dependency stubs (resolved at call time once the bridge is included) ---
LLM_Tooltip_IsVisible()        => _MMP_Visible
LLM_Tooltip_IsLoading()        => _MMP_Loading
LLM_Tooltip_InGracePeriod()    => _MMP_InGrace
LLM_Engine_IsBusy()            => false
LLM_Engine_StopGeneration()    => ""
LLM_Tooltip_MarkChainTimingOnly(NowTick) => ""
LLM_Tooltip_Hide(accepted := false) {
	global _MMP_HideHits
	_MMP_HideHits += 1
}

#Include ../modules/keymap/llm_bridge.ahk

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
; ======= 1/ OnPointerActivity cancels active work ========
; =========================================================

_MMP_DismissDuringLoading() {
	global _MMP_Visible, _MMP_Loading, _MMP_InGrace, _MMP_HideHits
	; The user is waiting for a slow model: loading spinner up, no prediction yet.
	; Per the user's choice + macOS parity, ANY input now cancels it immediately.
	_MMP_Visible := true
	_MMP_Loading := true
	_MMP_InGrace := false
	_MMP_HideHits := 0
	LLM_Bridge_OnPointerActivity()
	AssertEqual(1, _MMP_HideHits, "pointer activity during generation MUST cancel the spinner (input cancels in-progress work)")
}
Test("pointer-dismiss: pointer activity cancels the loading spinner", _MMP_DismissDuringLoading)

_MMP_DismissWhenPredictionShown() {
	global _MMP_Visible, _MMP_Loading, _MMP_InGrace, _MMP_HideHits
	; A real prediction is on screen, past its grace window — pointer dismisses it.
	_MMP_Visible := true
	_MMP_Loading := false
	_MMP_InGrace := false
	_MMP_HideHits := 0
	LLM_Bridge_OnPointerActivity()
	AssertEqual(1, _MMP_HideHits, "pointer activity over a shown prediction must dismiss it")
}
Test("pointer-dismiss: pointer activity dismisses a shown prediction", _MMP_DismissWhenPredictionShown)

_MMP_GraceShieldsShownPrediction() {
	global _MMP_Visible, _MMP_Loading, _MMP_InGrace, _MMP_HideHits
	; A real prediction inside its minimum-display window is shielded: an incidental
	; click / drift the instant it renders must not kill it before the user sees it.
	; (The loading spinner has no grace — see _MMP_DismissDuringLoading.)
	_MMP_Visible := true
	_MMP_Loading := false
	_MMP_InGrace := true
	_MMP_HideHits := 0
	LLM_Bridge_OnPointerActivity()
	AssertEqual(0, _MMP_HideHits, "a shown prediction in its grace window must NOT be dismissed by pointer activity")
}
Test("pointer-dismiss: grace window shields a freshly-shown prediction", _MMP_GraceShieldsShownPrediction)

_MMP_NoWorkNoDismiss() {
	global _MMP_Visible, _MMP_Loading, _MMP_InGrace, _MMP_HideHits
	; Nothing active — pointer activity is a no-op (no wasteful reset / hide).
	_MMP_Visible := false
	_MMP_Loading := false
	_MMP_InGrace := false
	_MMP_HideHits := 0
	LLM_Bridge_OnPointerActivity()
	AssertEqual(0, _MMP_HideHits, "pointer activity with no active prediction work must do nothing")
}
Test("pointer-dismiss: no active work means no dismiss", _MMP_NoWorkNoDismiss)




; =========================================================
; ======= 2/ Move-tick source contract ====================
; =========================================================

_MMP_MoveTickGatesOnActiveWork() {
	body := FileRead(A_ScriptDir . "\..\modules\llm\llm_bridge.ahk", "UTF-8")
	; The move watcher gates on HasActivePredictionWork (loading spinner, in-flight
	; generation, OR a shown prediction) so a deliberate move cancels during loading
	; too, and drops the baseline while NO work is active so the next cycle starts
	; from a fresh origin.
	AssertContains(body, "if !LLM_Bridge_HasActivePredictionWork() {",
		"move-tick must gate on active prediction work (incl. loading), not only a shown prediction")
	AssertContains(body, "_LLM_PointerWatch_LastX := unset",
		"move-tick must reset the baseline while no prediction work is active")
	; And it must dismiss only past the deliberate-move threshold, never on raw jitter.
	AssertContains(body, "_LLM_PointerMovedEnough(x, y, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY)",
		"move-tick must dismiss only when the cursor moved past the jitter threshold")
	; The retired _LLM_Bridge_PredictionShown predicate must be fully gone — both the
	; click handler and the move-tick now gate on HasActivePredictionWork (no dead code).
	AssertFalse(InStr(body, "_LLM_Bridge_PredictionShown"),
		"_LLM_Bridge_PredictionShown must be removed; both gates now use HasActivePredictionWork")
}
Test("pointer-dismiss: move-tick gates on active work + resets baseline", _MMP_MoveTickGatesOnActiveWork)




; =========================================================
; ======= 3/ Movement threshold (no dismiss on jitter) ====
; =========================================================

_MMP_JitterDoesNotDismiss() {
	; A still mouse drifts a pixel or two from optical-sensor noise — must NOT count.
	AssertFalse(_LLM_PointerMovedEnough(503, 401, 500, 400),
		"a 3 px drift must not count as a deliberate move (regression: prediction vanished while the user sat still)")
	AssertFalse(_LLM_PointerMovedEnough(500, 400, 500, 400),
		"no movement must not dismiss")
}
Test("pointer-threshold: small jitter does not dismiss", _MMP_JitterDoesNotDismiss)

_MMP_HandLiftDoesNotDismiss() {
	; Logged in the wild: lifting a hand off the mouse lurched it dx=12 dy=48 and
	; dismissed an idle prediction the user was reading. A settle of a few dozen px
	; must NOT count — it is "rien touché" from the user's point of view.
	AssertFalse(_LLM_PointerMovedEnough(512, 448, 500, 400),
		"a ~50 px hand-lift settle must not dismiss the prediction")
	AssertFalse(_LLM_PointerMovedEnough(500, 480, 500, 400),
		"an 80 px settle must not dismiss either")
}
Test("pointer-threshold: a hand lifting off the mouse does not dismiss", _MMP_HandLiftDoesNotDismiss)

_MMP_DeliberateMoveDismisses() {
	; Relocating the cursor to click/use something else crosses the screen — far past
	; the threshold on either axis.
	AssertTrue(_LLM_PointerMovedEnough(720, 400, 500, 400),
		"a 220 px horizontal relocation is deliberate and must dismiss")
	AssertTrue(_LLM_PointerMovedEnough(500, 650, 500, 400),
		"a 250 px vertical relocation is deliberate and must dismiss")
}
Test("pointer-threshold: a deliberate relocation dismisses", _MMP_DeliberateMoveDismisses)

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
