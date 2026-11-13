; tests/unit/shortcuts/engine/test_keepawake_pause_gate.ahk

; ==============================================================================
; MODULE: Keep-Awake Pause Gate Tests
; DESCRIPTION:
; Keep-awake runs on SetTimer callbacks, mouse-button hotkeys and an InputHook.
; Native Suspend disarms none of the timer or InputHook paths, so each callback
; must refuse to act while the driver is paused (keepawake-bypasses-pause).
; These cases suspend the process for real, deliver the production callback and
; observe whether the running session was cancelled. Each case resumes and
; delivers the same callback again as a positive control, so a callback that
; never acts cannot pass.
;
; SimulateActivity and AwakeReturnToOrigin move the physical cursor through
; MCSetPos, which has no seam; their gates stay covered by the source scan in
; tests/meta/shortcuts/engine/test_keepawake_pause_gate.ahk so that a broken
; guard never moves the user's cursor during a test run.
; ==============================================================================

#Requires AutoHotkey v2.0




; =========================================
; =========================================
; ======= 1/ Session fixture ==============
; =========================================
; =========================================

; Stands in for the cancellation InputHook: StopActivitySimulation only calls
; Stop() on it, and AwakeCancelOnKeypress only compares its identity.
class _KAPG_FakeHook {
	__New() {
		this.StopCalls := 0
	}

	Stop() {
		this.StopCalls += 1
	}
}

; Runs Body against a running keep-awake session whose timers and hotkeys were
; never armed, so nothing but the delivered callback can cancel it.
_KAPG_WithSession(Body) {
	global ActivitySimulation, AwakeInputHook, AwakeOriginX, AwakeOriginY
	if !IsSet(ActivitySimulation)
		ActivitySimulation := false
	AssertFalse(ActivitySimulation, "the keep-awake pause gate tests require an idle production state")
	Assert(!IsObject(AwakeInputHook), "the keep-awake pause gate tests require no live cancellation hook")
	SavedOriginX := AwakeOriginX, SavedOriginY := AwakeOriginY
	WasSuspended := A_IsSuspended
	Hook := _KAPG_FakeHook()
	try {
		ActivitySimulation := true
		AwakeInputHook := Hook
		Body.Call(Hook)
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		SetTimer(StopActivitySimulation, 0)
		ActivitySimulation := false
		AwakeInputHook := ""
		AwakeOriginX := SavedOriginX, AwakeOriginY := SavedOriginY
	}
}

; Waits for a cancellation queued on a one-shot timer to run.
_KAPG_SettleTimers() {
	Started := A_TickCount
	while A_TickCount - Started < 100
		Sleep(10)
}




; =========================================
; =========================================
; ======= 2/ Pause gate behaviour =========
; =========================================
; =========================================

_KAPG_MouseButtonCancelBody(Hook) {
	global ActivitySimulation
	Suspend(true)
	AwakeCancelOnMouse()
	AssertTrue(ActivitySimulation, "a mouse click while suspended must not cancel keep-awake")
	AssertEqual(0, Hook.StopCalls, "a mouse click while suspended must not stop the cancellation hook")
	Suspend(false)
	AwakeCancelOnMouse()
	AssertFalse(ActivitySimulation, "positive control: the same click cancels keep-awake once resumed")
}
Test("keep-awake: a mouse click while suspended does not cancel the session (keepawake-bypasses-pause)",
	_KAPG_WithSession.Bind(_KAPG_MouseButtonCancelBody))

_KAPG_KeypressCancelBody(Hook) {
	global ActivitySimulation
	Suspend(true)
	AwakeCancelOnKeypress(Hook)
	AssertTrue(ActivitySimulation, "a keypress while suspended must not cancel keep-awake")
	AssertEqual(0, Hook.StopCalls, "a keypress while suspended must not stop the cancellation hook")
	Suspend(false)
	AwakeCancelOnKeypress(Hook)
	AssertFalse(ActivitySimulation, "positive control: the same keypress cancels keep-awake once resumed")
	AssertEqual(1, Hook.StopCalls, "the resumed cancellation stops its hook once")
}
Test("keep-awake: a keypress while suspended does not cancel the session (keepawake-bypasses-pause)",
	_KAPG_WithSession.Bind(_KAPG_KeypressCancelBody))

; The cursor is only read: the origin is placed far from it so the movement
; check sees a user move and would queue the cancellation.
_KAPG_MouseMovedCheckBody(Hook) {
	global ActivitySimulation, AwakeOriginX, AwakeOriginY, AWAKE_JITTER_PX
	Position := MCGetPos()
	AwakeOriginX := Position["x"] + 10 * AWAKE_JITTER_PX
	AwakeOriginY := Position["y"] + 10 * AWAKE_JITTER_PX
	Suspend(true)
	AwakeCheckMouseMoved()
	Suspend(false)
	_KAPG_SettleTimers()
	AssertTrue(ActivitySimulation, "a movement check while suspended must not queue a cancellation")
	AwakeCheckMouseMoved()
	_KAPG_SettleTimers()
	AssertFalse(ActivitySimulation, "positive control: the same movement check cancels once resumed")
}
Test("keep-awake: a movement check while suspended does not cancel the session (keepawake-bypasses-pause)",
	_KAPG_WithSession.Bind(_KAPG_MouseMovedCheckBody))
