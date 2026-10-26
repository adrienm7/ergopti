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
#Include ../infra/hotpath_profiler.ahk

; The actual public facade and lifecycle owner run in this isolated suite. Only
; detached graphics disposal and model cancellation cross controlled boundaries.
#Include ../ui/tooltip/llm.ahk
#Include ../ui/tooltip/tooltip_llm.ahk

global _MMP_HideHits := 0
global _MMP_StopHits := 0
global _MMP_ExactHits := 0
global _MMP_NextGeneration := 0
global _TooltipActiveSurface := 0

; --- Globals the bridge reads ---
global _LLM_Bridge_Active := true
global _LLM_Engine := Map("reset_on_nav", false)

LLM_Engine_IsBusy() => false
LLM_Engine_StopGeneration() {
	global _MMP_StopHits
	_MMP_StopHits += 1
}

; Observe the genuine facade without replacing its lifecycle decision.
_MMP_ObserveExactHide(Self, Token, accepted := false) {
	global _MMP_ExactHits
	_MMP_ExactHits += 1
	Self.DeleteProp("Call")
	try return Self.Call(Token, accepted)
	finally Self.DefineProp("Call", {Call: _MMP_ObserveExactHide})
}
LLM_Tooltip_HideExact.DefineProp("Call", {Call: _MMP_ObserveExactHide})

; The lifecycle owner must reach this graphics boundary with its exact surface.
; It is never called to decide whether a stale record is still allowed to hide.
TooltipHide(DbgTag := "?", Force := false, ExpectedGeneration := unset,
		ExpectedSurface := unset, ExpectedRequestSerial := unset) {
	global _TooltipActiveSurface, _MMP_HideHits
	AssertEqual("LLM", DbgTag)
	AssertTrue(Force, "the LLM owner must request exact graphics retirement")
	AssertTrue(IsSet(ExpectedGeneration) && IsSet(ExpectedSurface),
		"the real owner must supply both native graphics ownership fences")
	AssertTrue(IsObject(_TooltipActiveSurface) && IsObject(ExpectedSurface))
	AssertEqual(ObjPtr(_TooltipActiveSurface), ObjPtr(ExpectedSurface),
		"graphics disposal must retain the actual current surface")
	AssertEqual(_TooltipActiveSurface.Generation, ExpectedGeneration)
	_MMP_HideHits += 1
	_TooltipActiveSurface := 0
	return true
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




; Pump the actual deferred callback even for absence assertions. A native fence
; proves timers ran; a fixed observation window also catches a delayed bad hide.
_MMP_WaitDismiss(Expected) {
	global _MMP_HideHits
	Fence := {Done: false}
	PreviousCritical := Critical("Off")
	try {
		SetTimer(() => Fence.Done := true, -1)
		loop 20
			Sleep(5)
		AssertTrue(Fence.Done, "the real native timer queue must progress")
		AssertEqual(Expected, _MMP_HideHits, "the deferred hide result must settle")
	} finally {
		Critical(PreviousCritical)
	}
}

_MMP_Record(Loading, Grace, Lifecycle := 0) {
	global _MMP_NextGeneration
	_MMP_NextGeneration += 1
	if !IsObject(Lifecycle)
		Lifecycle := {Outcome: "", Suggested: false}
	return {Kind: Loading ? "loading" : "prediction", Lifecycle: Lifecycle,
		Generation: _MMP_NextGeneration, ShownAt: Grace ? A_TickCount : 0}
}

_MMP_Present(Record) {
	global _TooltipActiveSurface
	_TooltipActiveSurface := IsObject(Record)
		? {Generation: Record.Generation, LlmPresented: Record} : 0
}

_MMP_SetState(Visible, Loading, Grace) {
	global _MMP_HideHits, _MMP_StopHits, _MMP_ExactHits
	_MMP_HideHits := 0
	_MMP_StopHits := 0
	_MMP_ExactHits := 0
	_MMP_Present(Visible || Loading ? _MMP_Record(Loading, Grace) : 0)
}

_MMP_DispatchDeferred() {
	global _MMP_HideHits
	PreviousCritical := Critical("On")
	try {
		Record := LLM_Tooltip_GetPresentedToken()
		LLM_Bridge_OnPointerActivity()
		AssertEqual(0, _MMP_HideHits, "hide must stay outside the pointer callback")
		AssertTrue(Record.WithdrawalPending, "the real owner must withdraw input before the callback returns")
		AssertEqual("dismissed", Record.Lifecycle.Outcome,
			"the actual lifecycle must settle synchronously before graphics disposal")
		AssertEqual(ObjPtr(Record), ObjPtr(LLM_Tooltip_GetPresentedToken()),
			"withdrawal retains the exact visual record until deferred cleanup")
	} finally {
		Critical(PreviousCritical)
	}
}

; =========================================================
; ======= 1/ OnPointerActivity cancels active work ========
; =========================================================

_MMP_DismissDuringLoading() {
	global _MMP_HideHits, _MMP_StopHits
	; The user is waiting for a slow model: loading spinner up, no prediction yet.
	; Per the user's choice + macOS parity, ANY input now cancels it immediately.
	_MMP_SetState(true, true, false)
	_MMP_DispatchDeferred()
	_MMP_WaitDismiss(1)
	AssertEqual(1, _MMP_StopHits, "generation cancellation must respect active work and grace")
	AssertEqual(1, _MMP_HideHits, "pointer activity during generation MUST cancel the spinner (input cancels in-progress work)")
}
Test("pointer-dismiss: pointer activity cancels the loading spinner", _MMP_DismissDuringLoading)

_MMP_DismissWhenPredictionShown() {
	global _MMP_HideHits, _MMP_StopHits
	; A real prediction is on screen, past its grace window — pointer dismisses it.
	_MMP_SetState(true, false, false)
	_MMP_DispatchDeferred()
	_MMP_WaitDismiss(1)
	AssertEqual(1, _MMP_StopHits, "generation cancellation must respect active work and grace")
	AssertEqual(1, _MMP_HideHits, "pointer activity over a shown prediction must dismiss it")
}
Test("pointer-dismiss: pointer activity dismisses a shown prediction", _MMP_DismissWhenPredictionShown)

_MMP_GraceShieldsShownPrediction() {
	global _MMP_HideHits, _MMP_StopHits
	; A real prediction inside its minimum-display window is shielded: an incidental
	; click / drift the instant it renders must not kill it before the user sees it.
	; (The loading spinner has no grace — see _MMP_DismissDuringLoading.)
	_MMP_SetState(true, false, true)
	LLM_Bridge_OnPointerActivity()
	_MMP_WaitDismiss(0)
	AssertEqual(0, _MMP_StopHits, "generation cancellation must respect active work and grace")
	AssertEqual(0, _MMP_HideHits, "a shown prediction in its grace window must NOT be dismissed by pointer activity")
}
Test("pointer-dismiss: grace window shields a freshly-shown prediction", _MMP_GraceShieldsShownPrediction)

_MMP_NoWorkNoDismiss() {
	global _MMP_HideHits, _MMP_StopHits
	; Nothing active — pointer activity is a no-op (no wasteful reset / hide).
	_MMP_SetState(false, false, false)
	LLM_Bridge_OnPointerActivity()
	_MMP_WaitDismiss(0)
	AssertEqual(0, _MMP_StopHits, "generation cancellation must respect active work and grace")
	AssertEqual(0, _MMP_HideHits, "pointer activity with no active prediction work must do nothing")
}
Test("pointer-dismiss: no active work means no dismiss", _MMP_NoWorkNoDismiss)




; =========================================================
; ======= 2/ Move-tick source contract ====================
; =========================================================

_MMP_MoveTickGatesOnActiveWork() {
	body := _DriverFuncBody("_LLM_PointerWatch_OnMoveTick")
	AssertTrue(body != "", "the real movement owner source must exist")
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
	Source := _DriverSourceNoComments()
	AssertTrue(Source != "", "the retired predicate guard must inspect real source")
	AssertFalse(InStr(Source, "_LLM_Bridge_PredictionShown"),
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

_MMP_StaleHideKeepsReplacement() {
	global _MMP_ExactHits
	_MMP_SetState(true, false, false)
	PreviousCritical := Critical("On")
	try {
		_MMP_DispatchDeferred()
		Replacement := _MMP_Record(false, false)
		_MMP_Present(Replacement)
	} finally {
		Critical(PreviousCritical)
	}
	_MMP_WaitDismiss(0)
	AssertEqual(1, _MMP_ExactHits, "the old exact callback must actually execute")
	AssertTrue(LLM_Tooltip_IsVisible(), "a stale callback must leave replacement visible")
	AssertEqual(ObjPtr(Replacement), ObjPtr(LLM_Tooltip_GetPresentedToken()), "replacement identity must remain active")
}
Test("pointer-dismiss: stale deferred hide preserves replacement identity", _MMP_StaleHideKeepsReplacement)

_MMP_HideAllowsSameLifecycle() {
	global _MMP_ExactHits
	_MMP_SetState(true, false, false)
	PreviousCritical := Critical("On")
	try {
		Lifecycle := LLM_Tooltip_GetPresentedToken().Lifecycle
		_MMP_DispatchDeferred()
		_MMP_Present(_MMP_Record(false, false, Lifecycle))
	} finally {
		Critical(PreviousCritical)
	}
	_MMP_WaitDismiss(1)
	AssertEqual(1, _MMP_ExactHits, "the actual owner must preserve same-lifecycle graphics continuity")
}
Test("pointer-dismiss: same lifecycle accepts the deferred exact hide", _MMP_HideAllowsSameLifecycle)

_MMP_StaleWithdrawalKeepsReplacement() {
	global _MMP_ExactHits
	_MMP_SetState(true, false, false)
	Retired := LLM_Tooltip_GetPresentedToken()
	Replacement := _MMP_Record(false, false)
	_MMP_Present(Replacement)
	AssertFalse(LLM_Bridge_DeferTooltipHide(false, Retired),
		"the real withdrawal facade must refuse a record which lost its surface")
	_MMP_WaitDismiss(0)
	AssertEqual(0, _MMP_ExactHits, "a refused withdrawal must not enqueue graphics cleanup")
	AssertEqual("", Retired.Lifecycle.Outcome, "a stale request cannot retire an old lifecycle")
	AssertEqual("", Replacement.Lifecycle.Outcome, "a stale request cannot retire its replacement")
	AssertEqual(ObjPtr(Replacement), ObjPtr(LLM_Tooltip_GetPresentedToken()))
}
Test("pointer-dismiss: stale withdrawal preserves the actual replacement owner", _MMP_StaleWithdrawalKeepsReplacement)

RunTests()
