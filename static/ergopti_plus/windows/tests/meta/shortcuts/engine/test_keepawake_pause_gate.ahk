; tests/meta/shortcuts/engine/test_keepawake_pause_gate.ahk

; ==============================================================================
; MODULE: Keep-Awake Pause Gate Meta Test
; DESCRIPTION:
; Source guard for the keepawake-bypasses-pause finding, kept only where the
; behaviour cannot be observed safely. SimulateActivity and AwakeReturnToOrigin
; move the physical cursor through MCSetPos, which has no seam: a behavioural
; test of a broken guard would move the user's cursor. The cancellation
; callbacks are observed under a real Suspend in
; tests/unit/shortcuts/engine/test_keepawake_pause_gate.ahk.
;
; Ergopti_OnSuspendEnter runs the whole lifecycle teardown, which releases
; synthetic modifiers and stops every subsystem, so its keep-awake stop is also
; read from the source.
; ==============================================================================

#Requires AutoHotkey v2.0

_KPG_AssertPauseGates() {
	for _, FuncName in ["SimulateActivity", "AwakeReturnToOrigin"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist in the driver source")
		GuardPos := InStr(Body, "if A_IsSuspended")
		MovePos := InStr(Body, "MCSetPos(")
		Assert(GuardPos > 0, FuncName . " must have an early return for A_IsSuspended (keepawake-bypasses-pause)")
		Assert(MovePos > GuardPos, FuncName . " must check A_IsSuspended before it moves the cursor (keepawake-bypasses-pause)")
	}
}

_KPG_AssertOnSuspendEnter() {
	Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Body != "", "Ergopti_OnSuspendEnter must exist in the driver source")
	Assert(InStr(Body, "StopActivitySimulation(") > 0, "Ergopti_OnSuspendEnter must call StopActivitySimulation (keepawake-bypasses-pause)")
}

Test("shortcuts: keep-awake cursor movers have A_IsSuspended gates (keepawake-bypasses-pause)", _KPG_AssertPauseGates)
Test("core: Ergopti_OnSuspendEnter stops activity simulation (keepawake-bypasses-pause)", _KPG_AssertOnSuspendEnter)
