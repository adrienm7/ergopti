; static/ergopti_plus/windows/tests/run_llm_pointer_dismiss.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

; ==============================================================================
; MODULE: LLM Pointer-Dismiss Tests
; DESCRIPTION:
; Predictions run only while the user does nothing (maintainer decision
; 2026-11-06). ANY activity — a click, a wheel turn, any non-zero pointer move, a
; window switch or a key the tooltip does not own — cancels the in-progress
; generation and hides the tooltip at once. Dismissal gates on
; LLM_Bridge_HasActivePredictionWork() (debounce, loading spinner, in-flight
; generation, OR a shown prediction). The minimum-display grace window no longer
; shields a prediction from activity, and the move watcher no longer waits for a
; 100 px travel: only a zero-distance sample is not activity.
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

; The prefix watcher owns the modifier predicate; this isolated suite keeps its
; production membership (Shift, Ctrl, Alt, Win in every sided form).
_PrefixIsModifierVK(VK) {
	return (VK >= 0x10 && VK <= 0x12) || (VK >= 0xA0 && VK <= 0xA5) || VK == 0x5B || VK == 0x5C
}

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

_MMP_GraceNoLongerShields() {
	global _MMP_HideHits, _MMP_StopHits
	; A prediction inside its minimum-display window is hidden all the same: the
	; user moved, so the answer is no longer wanted (2026-11-06).
	_MMP_SetState(true, false, true)
	_MMP_DispatchDeferred()
	_MMP_WaitDismiss(1)
	AssertEqual(1, _MMP_StopHits, "activity cancels generation even inside the grace window")
	AssertEqual(1, _MMP_HideHits, "activity hides a freshly shown prediction at once")
}
Test("pointer-dismiss: the grace window does not shield a prediction from activity", _MMP_GraceNoLongerShields)

_MMP_KeyOutsideTooltipCancels() {
	global _MMP_HideHits, _MMP_StopHits
	; F5 and a letter act on nothing the tooltip owns: the prediction goes.
	for VK in [0x74, 0x41] {
		_MMP_SetState(true, false, false)
		PreviousCritical := Critical("On")
		try AssertTrue(LLM_Bridge_OnKeyActivity(VK), "a key outside the tooltip is activity")
		finally Critical(PreviousCritical)
		_MMP_WaitDismiss(1)
		AssertEqual(1, _MMP_StopHits, "the request in flight is cancelled")
	}
}
Test("key-activity: a key the tooltip does not own cancels and hides", _MMP_KeyOutsideTooltipCancels)

_MMP_TooltipKeysDoNotCancel() {
	global _MMP_HideHits, _MMP_StopHits
	; Tab accepts, the digits select, the modifiers start every chord.
	for VK in [0x09, 0x31, 0x39, 0x61, 0xA0, 0xA2, 0xA4, 0x5B] {
		_MMP_SetState(true, false, false)
		AssertFalse(LLM_Bridge_OnKeyActivity(VK), "a key that operates the tooltip is not activity")
		_MMP_WaitDismiss(0)
		AssertEqual(0, _MMP_StopHits, "accepting or cycling keeps the prediction")
	}
}
Test("key-activity: accept, select and modifier keys keep the prediction", _MMP_TooltipKeysDoNotCancel)

_MMP_IdleKeepsPrediction() {
	global _MMP_HideHits, _MMP_StopHits
	; Nothing happens: the shown prediction stays.
	_MMP_SetState(true, false, false)
	_MMP_WaitDismiss(0)
	AssertEqual(0, _MMP_StopHits, "an idle user keeps the request")
	AssertTrue(LLM_Tooltip_IsVisible(), "an idle user keeps the prediction on screen")
}
Test("idle: a prediction stays while the user does nothing", _MMP_IdleKeepsPrediction)

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
	; Any non-zero travel since the previous sample dismisses; no grace shield.
	AssertContains(body, "_LLM_PointerMoved(x, y, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY)",
		"move-tick must dismiss on any travel since the previous sample")
	AssertFalse(InStr(body, "InGracePeriod"), "move-tick must not shield a prediction in its grace window")
	; The retired _LLM_Bridge_PredictionShown predicate must be fully gone — both the
	; click handler and the move-tick now gate on HasActivePredictionWork (no dead code).
	Source := _DriverSourceNoComments()
	AssertTrue(Source != "", "the retired predicate guard must inspect real source")
	AssertFalse(InStr(Source, "_LLM_Bridge_PredictionShown"),
		"_LLM_Bridge_PredictionShown must be removed; both gates now use HasActivePredictionWork")
}
Test("pointer-dismiss: move-tick gates on active work + resets baseline", _MMP_MoveTickGatesOnActiveWork)




; =========================================================
; ======= 3/ Any non-zero movement is activity ============
; =========================================================

_MMP_ZeroDistanceIsNotActivity() {
	AssertFalse(_LLM_PointerMoved(500, 400, 500, 400),
		"a sample at the same position is not activity")
}
Test("pointer-move: a zero-distance sample does not dismiss", _MMP_ZeroDistanceIsNotActivity)

_MMP_AnyTravelIsActivity() {
	AssertTrue(_LLM_PointerMoved(501, 400, 500, 400), "one pixel horizontally is activity")
	AssertTrue(_LLM_PointerMoved(500, 399, 500, 400), "one pixel vertically is activity")
	AssertTrue(_LLM_PointerMoved(720, 650, 500, 400), "a relocation is activity")
}
Test("pointer-move: any non-zero travel dismisses", _MMP_AnyTravelIsActivity)

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
