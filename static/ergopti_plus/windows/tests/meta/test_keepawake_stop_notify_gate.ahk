; tests/meta/test_keepawake_stop_notify_gate.ahk

; ==============================================================================
; MODULE: Keep-Awake Stop Notification Gate Meta Test
; DESCRIPTION:
; Regression guard for a false "antiveille desactive" (keep-awake stopped)
; notification firing on every pause. Ergopti_OnSuspendEnter calls
; StopActivitySimulation() unconditionally on every AltGr+Enter / menu /
; gesture pause so keep-awake can never outlive a suspend -- but
; StopActivitySimulation used to fire its TrayTip("keepawake.stopped")
; unconditionally too, so pausing showed the toast even when keep-awake
; (Win+M) had never been turned on.
;
; SCOPE: source introspection of modules/shortcuts/win.ahk, via the shared
; brace-depth-aware _DriverFuncBody helper (test_framework.ahk) -- a naive
; "next line starting with a closing brace" scan would truncate this function
; early at its nested "if IsSet(AwakeInputHook)..." block.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_KASNG_CheckGuardedNotification() {
	Body := _DriverFuncBody("StopActivitySimulation")
	Assert(Body != "", "StopActivitySimulation must be present in modules/shortcuts/win.ahk")

	CapturePos := InStr(Body, "WasActive := ActivitySimulation")
	MutatePos  := InStr(Body, "ActivitySimulation := False")
	GuardPos   := InStr(Body, "if WasActive")
	NotifyPos  := InStr(Body, "keepawake.stopped")

	Assert(CapturePos > 0,
		"StopActivitySimulation must capture the prior ActivitySimulation state before clearing it (keepawake-stop-notify-gate)")
	Assert(MutatePos > CapturePos,
		"The prior state must be captured BEFORE ActivitySimulation is reset to False")
	Assert(GuardPos > 0,
		"StopActivitySimulation must guard its 'stopped' notification on the captured prior state (keepawake-stop-notify-gate)")
	Assert(NotifyPos > GuardPos,
		"The 'keepawake.stopped' TrayTip must sit inside the WasActive guard, not fire unconditionally")
}


Test("shortcuts: StopActivitySimulation only notifies when keep-awake was actually running (keepawake-stop-notify-gate)",
	_KASNG_CheckGuardedNotification)

; F44 (audit 2026-07-20): StartActivitySimulation armed its two CANCELLATION paths
; (mouse hotkeys, keypress InputHook) inside bare try blocks with no catch. A failure
; was masked, leaving keep-awake running with no way for the user to interrupt it —
; the exact "half-armed feature" shape §5.3 forbids swallowing.
_KASNG_ArmingFailuresAreLogged() {
	Body := _DriverFuncBody("StartActivitySimulation")
	Assert(Body != "", "StartActivitySimulation must exist in modules/shortcuts/win.ahk")
	FactoryBody := _DriverFuncBody("AwakeCreateCancellationHook")
	Assert(FactoryBody != "",
		"AwakeCreateCancellationHook must own the production keypress observer")
	Assert(InStr(Body, "Hotkey(") > 0 && InStr(Body, "AwakeCreateCancellationHook()") > 0
		&& InStr(FactoryBody, "InputHook(") > 0,
		"StartActivitySimulation must arm both the mouse and keypress cancellation paths")
	; Each OS-boundary arming block must report its failure rather than swallow it.
	Assert(InStr(Body, "Keep-awake mouse-cancel hook arming failed") > 0,
		"a failed mouse-cancel hook arming must be logged (§5.3), not swallowed by a bare try")
	Assert(InStr(Body, "Keep-awake keypress-cancel InputHook arming failed") > 0,
		"a failed keypress-cancel InputHook arming must be logged (§5.3), not swallowed by a bare try")
}
Test("shortcuts: keep-awake cancellation arming failures are logged, never swallowed",
	_KASNG_ArmingFailuresAreLogged)
