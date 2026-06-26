; tests/meta/test_space_hold_suspend_guard.ahk

; ==============================================================================
; MODULE: Space Hold-Modifier InputHook Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for finding space-hold-inputhook-suspend-guard (F-M03).
;
; SpaceTapHold (Space hold = ctrl/shift/alt/alt_gr/win) starts an InputHook and
; blocks in ih.Wait() during the hold. AHK Suspend does NOT stop a live InputHook,
; so a pause arriving mid-hold leaves the hook capturing; ih.Wait() then resolves
; and HoldFn fires a SendInput modifier+char into the foreground app while the
; driver is supposed to be paused — a phantom modified keystroke leak. Every other
; InputHook site (OneShotShift, DeadKey, GestureOnKeyDown) re-checks A_IsSuspended
; after Wait(); this one was missed.
;
; The fix re-checks A_IsSuspended immediately after ih.Wait() and before HoldFn.Call.
; Meta-static because space.ahk registers top-level SC039 hotkeys and cannot be
; #Included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0


_SHSG_AssertSpaceHoldSuspendGuard() {
	Body := _DriverFuncBody("SpaceTapHold")
	Assert(Body != "", "SpaceTapHold(HoldFn) must exist")
	WaitIdx := InStr(Body, "ih.Wait()")
	Assert(WaitIdx > 0, "SpaceTapHold must call ih.Wait()")
	GuardIdx := InStr(Body, "A_IsSuspended", , WaitIdx + 1)
	Assert(GuardIdx > WaitIdx,
		"SpaceTapHold must re-check A_IsSuspended AFTER ih.Wait() — a live InputHook bypasses native Suspend and would leak a phantom modified keystroke (space-hold-inputhook-suspend-guard)")
	CallIdx := InStr(Body, "HoldFn.Call", , WaitIdx + 1)
	Assert(CallIdx > 0 and GuardIdx < CallIdx,
		"SpaceTapHold's A_IsSuspended re-check must precede HoldFn.Call so a paused driver emits nothing (space-hold-inputhook-suspend-guard)")
}
Test("tap-holds: SpaceTapHold re-checks A_IsSuspended after ih.Wait() (space-hold-inputhook-suspend-guard)", _SHSG_AssertSpaceHoldSuspendGuard)
